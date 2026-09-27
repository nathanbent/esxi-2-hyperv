<#
.SYNOPSIS
    Proposes (and optionally performs) a balanced placement of clustered VMs across the Up nodes (by assigned RAM),
    keeping anti-affinity groups apart and moving as few VMs as possible.
    Prints the moves as commands. DRY RUN by default; -Execute performs them (verified, one at a time).

.DESCRIPTION
    - Balances running clustered VMs by MemoryAssigned (add -IncludeOff to also place VMs that are off).
    - Respects existing AntiAffinityClassNames (e.g. your DCs) plus any -KeepApart sets you pass.
    - Leaves a VM where it is if its current node is within -ToleranceGB of the best choice.
    - Prints: before/after RAM per node, the moves, anti-affinity commands for new -KeepApart sets,
      and (with -ShowPreferredOwners) Set-ClusterOwnerNode commands to record each VM's "home" node.

.EXAMPLE
    .\Get-BalancePlan.ps1
    .\Get-BalancePlan.ps1 -KeepApart 'SPS-PS1,SPS-PS2','RG-01,RG-02'
    .\Get-BalancePlan.ps1 -KeepApart 'SPS-PS1,SPS-PS2' -ToleranceGB 16 -ShowPreferredOwners
    .\Get-BalancePlan.ps1 -KeepApart 'SPS-PS1,SPS-PS2' -Execute -ApplyAntiAffinity
#>
[CmdletBinding()]
param(
    [string[]]$KeepApart   = @(),   # each entry is a comma-separated set of VM names to keep on different nodes
    [double]  $ToleranceGB = 8,     # keep a VM on its current node if that's within this much of the best node
    [switch]  $IncludeOff,
    [switch]  $ShowPreferredOwners,
    [switch]  $Execute,             # perform the moves (one at a time, verified, stops on first failure)
    [switch]  $ApplyAntiAffinity,   # with -Execute: also set anti-affinity for new -KeepApart groups
    [string]  $OverrideFile = (Join-Path $PSScriptRoot 'ping-overrides.csv'),
    [string]  $LogDir       = 'C:\temp\csv-move'
)

$ErrorActionPreference = 'Stop'
function Section ($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

$nodes = @(Get-ClusterNode | Where-Object State -eq 'Up' | ForEach-Object { $_.Name } | Sort-Object)
foreach ($p in @(Get-ClusterNode | Where-Object State -ne 'Up')) {
    Write-Warning "$($p.Name) is $($p.State) - not used as a target. If it's Paused: Resume-ClusterNode -Name '$($p.Name)' -Failback NoFailback"
}
if ($nodes.Count -lt 2) { throw "Need at least 2 Up nodes to balance (Up: $($nodes -join ', '))" }

# ---------- gather ----------
$classes = @{}   # VM name -> list of anti-affinity classes (existing + KeepApart)
function Add-Class ($VM, $Class) {
    if (-not $classes.ContainsKey($VM)) { $classes[$VM] = New-Object System.Collections.Generic.List[string] }
    if (-not $classes[$VM].Contains($Class)) { $classes[$VM].Add($Class) }
}

$vms = @(foreach ($g in @(Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine')) {
    $node = $g.OwnerNode.Name
    $vm   = Get-VM -Name $g.Name -ComputerName $node -ErrorAction SilentlyContinue
    if (-not $vm) { continue }
    if ($vm.State -ne 'Running' -and -not $IncludeOff) { continue }
    $mem = if ($vm.State -eq 'Running') { $vm.MemoryAssigned } else { $vm.MemoryStartup }
    $existing = @($g.AntiAffinityClassNames | Where-Object { $_ })
    foreach ($c in $existing) { Add-Class $g.Name $c }
    [pscustomobject]@{ VM = $g.Name; Node = $node; State = [string]$vm.State; MemGB = [math]::Round($mem / 1GB, 1); Existing = $existing }
})

$newClassFor = @{}   # VM -> KeepApart classes that aren't set in the cluster yet
foreach ($set in $KeepApart) {
    $names = @($set -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $cls = 'Apart: ' + ($names -join '+')
    foreach ($n in $names) {
        if ($vms.VM -notcontains $n) { Write-Warning "KeepApart: '$n' is not a clustered VM being placed - ignored"; continue }
        Add-Class $n $cls
        if ((($vms | Where-Object VM -eq $n).Existing) -notcontains $cls) {
            if (-not $newClassFor.ContainsKey($n)) { $newClassFor[$n] = @() }
            $newClassFor[$n] += $cls
        }
    }
}

# ---------- before ----------
Section 'Current RAM per node (placed VMs)'
foreach ($n in $nodes) {
    $gb = [math]::Round((@($vms | Where-Object Node -eq $n) | Measure-Object MemGB -Sum).Sum, 1)
    '{0,-12} {1,7:N1} GB  ({2} VMs)' -f $n, $gb, @($vms | Where-Object Node -eq $n).Count
}

# ---------- plan (largest first, fewest anti-affinity conflicts, then lowest load; prefer staying put) ----------
$load = @{}; $onNode = @{}
foreach ($n in $nodes) { $load[$n] = 0.0; $onNode[$n] = New-Object System.Collections.Generic.List[string] }

$plan = @(foreach ($v in ($vms | Sort-Object MemGB -Descending)) {
    $cls = if ($classes.ContainsKey($v.VM)) { @($classes[$v.VM]) } else { @() }
    $scored = @(foreach ($n in $nodes) {
        [pscustomobject]@{ Node = $n; Conflicts = @($cls | Where-Object { $onNode[$n].Contains($_) }).Count; Load = $load[$n] }
    })
    $best = $scored | Sort-Object Conflicts, Load | Select-Object -First 1
    $cur  = $scored | Where-Object Node -eq $v.Node
    $to = if ($cur -and $cur.Conflicts -le $best.Conflicts -and ($cur.Load - $best.Load) -le $ToleranceGB) { $v.Node } else { $best.Node }
    $load[$to] += $v.MemGB
    foreach ($c in $cls) { $onNode[$to].Add($c) }
    [pscustomobject]@{ VM = $v.VM; State = $v.State; MemGB = $v.MemGB; From = $v.Node; To = $to; Move = ($to -ne $v.Node); Groups = ($cls -join '; ') }
})

# ---------- after ----------
Section 'Proposed RAM per node'
foreach ($n in $nodes) {
    '{0,-12} {1,7:N1} GB  ({2} VMs)' -f $n, $load[$n], @($plan | Where-Object To -eq $n).Count
}
$conflicts = foreach ($n in $nodes) {
    $onNode[$n] | Group-Object | Where-Object Count -gt 1 | ForEach-Object { "$($_.Name) has $($_.Count) VMs on $n" }
}
foreach ($c in @($conflicts)) { Write-Host "  NOTE: $c (more VMs in the group than nodes)" -ForegroundColor Yellow }

$moves = @($plan | Where-Object Move)
Section "Moves ($($moves.Count)) - largest first"
if (-not $moves.Count) { Write-Host '  Already balanced within tolerance - nothing to move.' -ForegroundColor Green }
else {
    $moves | Format-Table VM, State, MemGB, From, To, Groups -AutoSize | Out-Host
    Write-Host 'Commands (review, then run - the cluster migrates 2 at a time by default):' -ForegroundColor Cyan
    foreach ($m in $moves) {
        if ($m.State -eq 'Running') { "Move-ClusterVirtualMachineRole -Name '$($m.VM)' -Node '$($m.To)' -MigrationType Live" }
        else                        { "Move-ClusterGroup -Name '$($m.VM)' -Node '$($m.To)'   # VM is $($m.State)" }
    }
}

if ($newClassFor.Count) {
    Section 'Make the -KeepApart groups permanent (anti-affinity)'
    foreach ($vmName in $newClassFor.Keys) {
        $all = @((($vms | Where-Object VM -eq $vmName).Existing) + $newClassFor[$vmName] | Select-Object -Unique)
        $list = ($all | ForEach-Object { "'$_'" }) -join ','
        "`$c = New-Object System.Collections.Specialized.StringCollection; $list | ForEach-Object { [void]`$c.Add(`$_) }; (Get-ClusterGroup '$vmName').AntiAffinityClassNames = `$c"
    }
}

if ($ShowPreferredOwners) {
    Section 'Optional: record each VM''s home node as its preferred owner'
    foreach ($p in $plan) {
        $order = @($p.To) + @($nodes | Where-Object { $_ -ne $p.To })
        "Set-ClusterOwnerNode -Group '$($p.VM)' -Owners $(($order | ForEach-Object { "'$_'" }) -join ',')"
    }
}

# ================= execute (only with -Execute) =================
if (-not $Execute) {
    Write-Host "`nDRY RUN - nothing changed. Re-run with -Execute to perform these moves." -ForegroundColor Yellow
    return
}
$doAA = $ApplyAntiAffinity -and $newClassFor.Count
if (-not $moves.Count -and -not $doAA) { return }

$what = @()
if ($moves.Count) { $what += "live-migrate $($moves.Count) VM(s)" }
if ($doAA)        { $what += "set anti-affinity on $($newClassFor.Count) VM(s)" }
if ((Read-Host "`nType YES to $($what -join ' and ')") -cne 'YES') { Write-Host 'Cancelled.'; return }

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$logCsv = Join-Path $LogDir 'balance.csv'
$ov = @{}
if (Test-Path $OverrideFile) { Import-Csv $OverrideFile | ForEach-Object { $ov[$_.VM] = $_.IP } }

if ($doAA) {
    Section 'Applying anti-affinity'
    foreach ($vmName in $newClassFor.Keys) {
        $c = New-Object System.Collections.Specialized.StringCollection
        foreach ($x in @((($vms | Where-Object VM -eq $vmName).Existing) + $newClassFor[$vmName] | Select-Object -Unique)) { [void]$c.Add($x) }
        (Get-ClusterGroup -Name $vmName).AntiAffinityClassNames = $c
        Write-Host "  OK   $vmName -> $($c -join '; ')" -ForegroundColor Green
    }
}

Section 'Moving'
$i = 0
foreach ($m in $moves) {
    $i++
    Write-Host ("[{0}/{1}] {2} ({3} GB) {4} -> {5}" -f $i, $moves.Count, $m.VM, $m.MemGB, $m.From, $m.To) -ForegroundColor Magenta
    $row = [ordered]@{ Time = Get-Date -Format s; VM = $m.VM; From = $m.From; To = $m.To; MemGB = $m.MemGB; Seconds = ''; Status = 'FAILED'; Error = '' }
    try {
        $running = $m.State -eq 'Running'
        $hb0 = ''; $pingIPs = @()
        if ($running) {
            $hb0 = (Get-VMIntegrationService -VMName $m.VM -ComputerName $m.From -Name 'Heartbeat').PrimaryStatusDescription
            $ips = if ($ov.ContainsKey($m.VM)) { @($ov[$m.VM]) } else {
                @((Get-VMNetworkAdapter -VMName $m.VM -ComputerName $m.From).IPAddresses |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' })
            }
            $pingIPs = @($ips | Where-Object { $_ -and (Test-Connection -ComputerName $_ -Count 2 -Quiet) })
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ($running) { Move-ClusterVirtualMachineRole -Name $m.VM -Node $m.To -MigrationType Live | Out-Null }
        else          { Move-ClusterGroup -Name $m.VM -Node $m.To | Out-Null }
        $sw.Stop(); $row.Seconds = [math]::Round($sw.Elapsed.TotalSeconds)

        $owner = (Get-ClusterGroup -Name $m.VM).OwnerNode.Name
        if ($owner -ne $m.To) { throw "owner is $owner, expected $($m.To)" }

        $checks = @("on $owner")
        if ($running) {
            $vm = Get-VM -Name $m.VM -ComputerName $m.To
            if ($vm.State -ne 'Running') { throw "VM is $($vm.State) after migration" }
            if ($hb0 -eq 'OK') {
                $hb = $null
                foreach ($k in 1..12) { $hb = (Get-VMIntegrationService -VM $vm -Name 'Heartbeat').PrimaryStatusDescription; if ($hb -eq 'OK') { break }; Start-Sleep -Seconds 5 }
                if ($hb -ne 'OK') { throw "heartbeat '$hb' after migration" }
                $checks += 'heartbeat OK'
            }
            if ($pingIPs.Count) {
                $up = @()
                foreach ($k in 1..6) {
                    $up = @($pingIPs | Where-Object { Test-Connection -ComputerName $_ -Count 2 -Quiet })
                    if ($up.Count -eq $pingIPs.Count) { break }
                    Start-Sleep -Seconds 5
                }
                if ($up.Count -ne $pingIPs.Count) { throw "not answering ping after ~30s: $(@($pingIPs | Where-Object { $_ -notin $up }) -join ', ')" }
                $checks += "ping OK ($($pingIPs -join ','))"
            } else { $checks += 'ping n/a' }
        }
        $row.Status = 'OK'
        Write-Host "     OK   $($row.Seconds)s - $($checks -join ', ')" -ForegroundColor Green
    }
    catch {
        $row.Error = $_.Exception.Message
        Write-Host "     FAILED: $($row.Error)" -ForegroundColor Red
    }
    finally {
        [pscustomobject]$row | Export-Csv -Path $logCsv -Append -NoTypeInformation
    }
    if ($row.Status -ne 'OK') { Write-Host 'Stopping - remaining moves not attempted. Re-run the plan to recalculate.' -ForegroundColor Red; break }
}

Section 'Result'
foreach ($n in $nodes) {
    $gb = 0.0
    foreach ($g in @(Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VirtualMachine' -and $_.OwnerNode.Name -eq $n })) {
        $v = Get-VM -Name $g.Name -ComputerName $n -ErrorAction SilentlyContinue
        if ($v -and ($v.State -eq 'Running' -or $IncludeOff)) { $gb += $v.MemoryAssigned / 1GB }
    }
    '{0,-12} {1,7:N1} GB' -f $n, $gb
}
Write-Host "Log: $logCsv" -ForegroundColor Cyan
