<#
.SYNOPSIS
    READ-ONLY health check for a Hyper-V failover cluster and its clustered VMs.
    Run on any cluster node as a domain admin. Makes NO changes - prints suggested fixes to review.

.DESCRIPTION
    Cluster:   nodes, quorum/witness, networks, live-migration network order, CSV space + Direct I/O
    Per VM:    group/resource state, every file on a CSV, pass-through disks, ISOs on non-shared paths,
               vSwitch present on every node, heartbeat, checkpoints, automatic start action,
               DC priority + anti-affinity
    Capacity:  can each node run every clustered VM by itself (N+1)?
    Leftovers: VMs not yet clustered, per node
    Events:    FailoverClustering (System) + Hyper-V-VMMS-Admin errors/warnings, last N hours

.EXAMPLE
    .\Test-ClusterVMHealth.ps1
    .\Test-ClusterVMHealth.ps1 -EventHours 72
#>
[CmdletBinding()]
param(
    [string[]]$DCNames             = @(),     # Hyper-V VM names of DCs (also read from mover-config.json + AD)
    [string]  $DCAntiAffinityClass = 'DCs',
    [int]     $HostReserveGB       = 8,       # RAM to leave for the host OS in the capacity check
    [int]     $CsvWarnFreePct      = 15,
    [int]     $EventHours          = 24,
    [string]  $ConfigFile          = (Join-Path $PSScriptRoot 'mover-config.json')
)

$ErrorActionPreference = 'Stop'

if (Test-Path $ConfigFile) {
    try { $DCNames += @((Get-Content $ConfigFile -Raw | ConvertFrom-Json).DCNames) } catch { }
}
try {
    $DCNames += @([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers |
                  ForEach-Object { ($_.Name -split '\.')[0] })
} catch { }
$DCNames = @($DCNames | Where-Object { $_ } | Select-Object -Unique)

$Fixes = New-Object System.Collections.Generic.List[string]
function Section ($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Say ($Level, $Msg) {
    $c = @{ PASS = 'Green'; INFO = 'Gray'; WARN = 'Yellow'; FAIL = 'Red' }[$Level]
    Write-Host ("  [{0}] {1}" -f $Level, $Msg) -ForegroundColor $c
}

# ---------------- cluster ----------------
Section "Cluster $((Get-Cluster).Name)"
$nodes   = @(Get-ClusterNode)
$upNodes = @($nodes | Where-Object State -eq 'Up' | ForEach-Object { $_.Name })
foreach ($n in $nodes) {
    if ($n.State -eq 'Up') { Say PASS "Node $($n.Name) Up" }
    else {
        Say FAIL "Node $($n.Name) is $($n.State)"
        if ($n.State -eq 'Paused') { $Fixes.Add("Resume-ClusterNode -Name '$($n.Name)'   # node is paused/drained") }
    }
}

$q = Get-ClusterQuorum
if ($q.QuorumResource) {
    $wState = (Get-ClusterResource -Name $q.QuorumResource.Name).State
    Say $(if ($wState -eq 'Online') {'PASS'} else {'FAIL'}) "Quorum $($q.QuorumType), witness '$($q.QuorumResource.Name)' $wState"
} else { Say WARN "Quorum $($q.QuorumType) with no witness" }

$nets = @(Get-ClusterNetwork)
foreach ($net in $nets) {
    Say $(if ($net.State -eq 'Up') {'PASS'} else {'FAIL'}) ("Network '{0}' {1}/{2} role {3} - {4}" -f $net.Name, $net.Address, $net.AddressMask, $net.Role, $net.State)
}
if (@($nets | Where-Object { $_.Role -ne 'None' -and $_.State -eq 'Up' }).Count -lt 2) {
    Say WARN 'Only one usable cluster network - no redundant heartbeat path'
}
try {
    $order = (Get-ClusterResourceType 'Virtual Machine' | Get-ClusterParameter MigrationNetworkOrder).Value
    $names = ($order -split ';' | ForEach-Object { $id = $_; ($nets | Where-Object Id -eq $id).Name } | Where-Object { $_ }) -join ' > '
    Say INFO "Live migration network order: $names"
} catch { }

# ---------------- CSVs ----------------
Section 'Cluster Shared Volumes'
$csvs = @(Get-ClusterSharedVolume)
$csvMounts = @($csvs | ForEach-Object { $_.SharedVolumeInfo[0].FriendlyVolumeName })
foreach ($c in $csvs) {
    $p = $c.SharedVolumeInfo[0].Partition
    $msg = "{0}: {1:N0} GB free of {2:N0} GB ({3:N0}% free), owner {4}" -f $c.Name, ($p.FreeSpace/1GB), ($p.Size/1GB), $p.PercentFree, $c.OwnerNode.Name
    Say $(if ($c.State -ne 'Online') {'FAIL'} elseif ($p.PercentFree -lt $CsvWarnFreePct) {'WARN'} else {'PASS'}) $msg
}
foreach ($s in @(Get-ClusterSharedVolumeState)) {
    if ($s.StateInfo -ne 'Direct') {
        Say FAIL "$($s.Name) on $($s.Node): $($s.StateInfo) (FS: $($s.FileSystemRedirectedIOReason), Block: $($s.BlockRedirectedIOReason))"
    }
}
if (-not @(Get-ClusterSharedVolumeState | Where-Object StateInfo -ne 'Direct').Count) { Say PASS 'All CSVs Direct on all nodes' }

function Test-OnCsv ($Path) {
    foreach ($m in $csvMounts) { if ($Path -eq $m -or $Path -like "$m\*") { return $true } }
    $false
}

# ---------------- clustered VMs ----------------
Section 'Clustered VMs'
$switchByNode = @{}
foreach ($n in $upNodes) { $switchByNode[$n] = @(Get-VMSwitch -ComputerName $n | ForEach-Object { $_.Name }) }
$prioName = @{ 3000 = 'High'; 2000 = 'Medium'; 1000 = 'Low'; 0 = 'NoAutoStart' }

$rows = foreach ($g in @(Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine' | Sort-Object Name)) {
    $node   = $g.OwnerNode.Name
    $issues = New-Object System.Collections.Generic.List[string]
    $vm     = Get-VM -Name $g.Name -ComputerName $node -ErrorAction SilentlyContinue
    if (-not $vm) {
        $issues.Add("FAIL: VM '$($g.Name)' not found on owner $node")
        [pscustomobject]@{ VM = $g.Name; Owner = $node; State = '?'; Group = $g.State; MemGB = 0; Priority = ''; IsDC = $false; Result = 'FAIL'; Issues = $issues }
        continue
    }
    $running = $vm.State -eq 'Running'
    $q1 = "-ComputerName '$node'"

    # group + resources
    if ($running -and $g.State -ne 'Online') { $issues.Add("FAIL: VM running but cluster group is $($g.State)") }
    if (-not $running) { $issues.Add("INFO: VM is $($vm.State)") }
    $res = @($g | Get-ClusterResource)
    foreach ($r in $res) {
        if ($r.State -eq 'Failed') { $issues.Add("FAIL: resource '$($r.Name)' Failed") }
        elseif ($running -and $r.State -ne 'Online') { $issues.Add("WARN: resource '$($r.Name)' $($r.State)") }
    }

    # storage
    $vhds  = @(Get-VMHardDiskDrive -VM $vm)
    $paths = @($vm.ConfigurationLocation, $vm.SnapshotFileLocation, $vm.SmartPagingFilePath) + @($vhds | Where-Object Path | ForEach-Object { $_.Path })
    $off   = @($paths | Where-Object { $_ -and -not (Test-OnCsv $_) } | Select-Object -Unique)
    if ($off.Count) { $issues.Add("FAIL: not on a CSV (breaks failover): $($off -join ', ')") }
    if ($vhds | Where-Object { $null -ne $_.DiskNumber }) { $issues.Add('FAIL: pass-through disk') }

    foreach ($d in @(Get-VMDvdDrive -VM $vm | Where-Object Path)) {
        if (-not (Test-OnCsv $d.Path)) {
            $issues.Add("WARN: ISO on non-shared path ($($d.Path)) - can block migration")
            $Fixes.Add("Get-VMDvdDrive -VMName '$($vm.Name)' $q1 | Set-VMDvdDrive -Path `$null   # eject ISO")
        }
    }

    # networking
    foreach ($a in @(Get-VMNetworkAdapter -VM $vm)) {
        if (-not $a.SwitchName) { $issues.Add("WARN: adapter '$($a.Name)' not connected to a switch"); continue }
        foreach ($n in $upNodes) {
            if ($switchByNode[$n] -notcontains $a.SwitchName) { $issues.Add("FAIL: vSwitch '$($a.SwitchName)' missing on $n") }
        }
    }

    # guest
    if ($running) {
        $hb = (Get-VMIntegrationService -VM $vm -Name 'Heartbeat').PrimaryStatusDescription
        if ($hb -ne 'OK') { $issues.Add("WARN: heartbeat '$hb'") }
    }
    $cps = @(Get-VMSnapshot -VM $vm)
    if ($cps.Count) {
        $issues.Add("WARN: $($cps.Count) checkpoint(s)")
        $Fixes.Add("Get-VMSnapshot -VMName '$($vm.Name)' $q1 | Remove-VMSnapshot   # merges - confirm nobody needs them")
    }
    if ([string]$vm.AutomaticStartAction -ne 'Nothing') {
        $issues.Add("INFO: AutomaticStartAction=$($vm.AutomaticStartAction) (cluster manages startup)")
        $Fixes.Add("Set-VM -Name '$($vm.Name)' $q1 -AutomaticStartAction Nothing   # optional: let the cluster own startup")
    }

    # DCs
    $isDC = $DCNames -contains $g.Name
    if ($isDC) {
        if ($g.Priority -lt 3000) {
            $issues.Add("WARN: DC priority is $($prioName[[int]$g.Priority])")
            $Fixes.Add("(Get-ClusterGroup '$($g.Name)').Priority = 3000")
        }
        if (@($g.AntiAffinityClassNames) -notcontains $DCAntiAffinityClass) {
            $issues.Add("WARN: DC missing anti-affinity class '$DCAntiAffinityClass'")
            $Fixes.Add("`$aa = New-Object System.Collections.Specialized.StringCollection; [void]`$aa.Add('$DCAntiAffinityClass'); (Get-ClusterGroup '$($g.Name)').AntiAffinityClassNames = `$aa")
        }
    }

    $result = if ($issues | Where-Object { $_ -like 'FAIL*' }) { 'FAIL' } elseif ($issues | Where-Object { $_ -like 'WARN*' }) { 'WARN' } else { 'PASS' }
    [pscustomobject]@{
        VM = $vm.Name; Owner = $node; State = [string]$vm.State; Group = [string]$g.State
        MemGB = [math]::Round($vm.MemoryAssigned / 1GB, 1); Priority = $prioName[[int]$g.Priority]
        IsDC = $isDC; Result = $result; Issues = $issues
    }
}
$rows = @($rows)

$rows | Format-Table VM, Owner, State, Group, MemGB, Priority, IsDC, Result -AutoSize | Out-Host
$cnt = $rows | Group-Object Result | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host "  $($rows.Count) clustered VMs - $($cnt -join ', ')"
foreach ($r in $rows | Where-Object { $_.Result -ne 'PASS' -or ($_.Issues | Where-Object { $_ -like 'INFO*' -and $_ -notlike '*AutomaticStartAction*' }) }) {
    foreach ($i in $r.Issues) {
        $lvl = ($i -split ':')[0]
        if ($lvl -eq 'INFO' -and $i -like '*AutomaticStartAction*') { continue }
        Say $lvl "$($r.VM): $($i.Substring($lvl.Length + 2))"
    }
}
$asa = @($rows | Where-Object { $_.Issues -like '*AutomaticStartAction*' })
if ($asa.Count) { Say INFO "$($asa.Count) clustered VM(s) still have a host AutomaticStartAction set (see fixes)" }

# DC spread
$dcRun = @($rows | Where-Object { $_.IsDC -and $_.State -eq 'Running' })
if ($dcRun.Count -gt 1 -and $upNodes.Count -gt 1) {
    $dcNodes = @($dcRun | Select-Object -ExpandProperty Owner -Unique)
    if ($dcNodes.Count -eq 1) {
        Say WARN "All running DCs are on $($dcNodes[0]) - fine while the other node is drained, otherwise move one"
        $Fixes.Add("Move-ClusterVirtualMachineRole -Name '$($dcRun[0].VM)' -Node '$(@($upNodes | Where-Object { $_ -ne $dcNodes[0] })[0])' -MigrationType Live   # spread DCs")
    } else { Say PASS "DCs spread across: $($dcNodes -join ', ')" }
}

# ---------------- capacity ----------------
Section 'Failover capacity (can any one node run every VM?)'
$allRunning = @(foreach ($n in $upNodes) {
    Get-VM -ComputerName $n | Where-Object State -eq 'Running' |
        Select-Object @{n='Node';e={$n}}, Name, IsClustered, @{n='MemGB';e={[math]::Round($_.MemoryAssigned/1GB,1)}}
})
$allGB  = [math]::Round(($allRunning | Measure-Object MemGB -Sum).Sum, 1)
$needGB = $allGB + $HostReserveGB
Say INFO "All running VMs use ~$allGB GB; any node taking over everything needs ~$needGB GB (incl. $HostReserveGB GB host reserve)"
foreach ($n in $upNodes) {
    $totalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ComputerName $n).TotalPhysicalMemory / 1GB)
    Say $(if ($needGB -le $totalGB) {'PASS'} else {'WARN'}) ("{0}: {1} GB RAM - {2}" -f $n, $totalGB,
        $(if ($needGB -le $totalGB) { "can run every VM ({0:N0} GB headroom)" -f ($totalGB - $needGB) } else { "short by {0:N0} GB" -f ($needGB - $totalGB) }))
}
foreach ($grp in @($allRunning | Where-Object { -not $_.IsClustered } | Group-Object Node)) {
    $gb = [math]::Round(($grp.Group | Measure-Object MemGB -Sum).Sum, 1)
    Say WARN "$($grp.Name) runs $($grp.Count) non-clustered VM(s) ($gb GB) - they go down with $($grp.Name) and can't fail over, regardless of RAM"
}

# ---------------- leftovers ----------------
Section 'VMs not yet clustered'
$left = foreach ($n in $upNodes) {
    Get-VM -ComputerName $n | Where-Object { -not $_.IsClustered } |
        Select-Object @{n='Node';e={$n}}, Name, State, @{n='MemGB';e={[math]::Round($_.MemoryAssigned/1GB,1)}}, Path
}
$left = @($left)
if ($left.Count) {
    Say INFO "$($left.Count) VM(s) not clustered - they will NOT move during a drain and stop if their node goes down"
    $left | Sort-Object Node, Name | Format-Table -AutoSize | Out-Host
} else { Say PASS 'Every VM is clustered' }

# ---------------- events ----------------
Section "Cluster / Hyper-V errors and warnings, last $EventHours h"
$since  = (Get-Date).AddHours(-$EventHours)
$events = foreach ($n in $upNodes) {
    $filters = @(
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-FailoverClustering'; Level = 1,2,3; StartTime = $since },
        @{ LogName = 'Microsoft-Windows-Hyper-V-VMMS-Admin'; Level = 1,2,3; StartTime = $since }
    )
    foreach ($f in $filters) {
        try {
            Get-WinEvent -ComputerName $n -FilterHashtable $f -ErrorAction Stop |
                Select-Object @{n='Node';e={$n}}, @{n='Log';e={$f.LogName -replace 'Microsoft-Windows-',''}},
                              Id, LevelDisplayName, TimeCreated, @{n='Msg';e={ ($_.Message -split "`r?`n")[0] }}
        } catch { }   # no matching events
    }
}
$events = @($events)
if ($events.Count) {
    $events | Group-Object Node, Log, Id | ForEach-Object {
        $latest = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
        [pscustomobject]@{ Node = $latest.Node; Log = $latest.Log; Id = $latest.Id; Level = $latest.LevelDisplayName
                           Count = $_.Count; Latest = $latest.TimeCreated; Message = $latest.Msg }
    } | Sort-Object Latest -Descending | Format-Table -AutoSize -Wrap | Out-Host
    Say INFO 'Events during your own moves/migrations are expected - look for ones that repeat or are newer than your last change'
} else { Say PASS 'No errors or warnings' }

# ---------------- fixes ----------------
Section 'Suggested fixes (review, then run yourself)'
if ($Fixes.Count) { $Fixes | Select-Object -Unique | ForEach-Object { "  $_" } } else { Say PASS 'Nothing to fix' }
