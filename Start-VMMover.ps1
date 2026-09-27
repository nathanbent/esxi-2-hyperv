<#
.SYNOPSIS
    Menu front-end for Move-VMToCsv.ps1: pick VMs from a grid, pick a target CSV, preflight, move.

.DESCRIPTION
    Keep next to Move-VMToCsv.ps1 and run on any cluster node:  .\Start-VMMover.ps1
    - Lists clustered VMs on every node plus non-clustered VMs on this node, with where their storage
      lives, full checkpoint-chain size, and known IP. VMs already on the target CSV are hidden.
    - Target CSV and "leave-on" node are chosen in the menu (discovered from the cluster).
    - Site settings live in mover-config.json (created with generic defaults if missing).
    - Ping IPs for VMs that don't report one are saved to ping-overrides.csv.
    - Moves require typing YES; every move runs the mover's own preflight first.
#>
[CmdletBinding()]
param(
    [string]$MoveScript   = (Join-Path $PSScriptRoot 'Move-VMToCsv.ps1'),
    [string]$ConfigFile   = (Join-Path $PSScriptRoot 'mover-config.json'),
    [string]$OverrideFile = (Join-Path $PSScriptRoot 'ping-overrides.csv')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $MoveScript)) { throw "Can't find $MoveScript - keep both scripts in the same folder." }

# ---------- config ----------
if (-not (Test-Path $ConfigFile)) {
    [ordered]@{ DefaultCsv = ''; CsvSubfolder = 'VMs'; DCNames = @(); LogDir = 'C:\temp\csv-move'; DefaultLeaveOnNode = '' } |
        ConvertTo-Json | Set-Content $ConfigFile
    Write-Host "Created $ConfigFile with defaults - add DCNames (Hyper-V VM names) if they differ from AD names." -ForegroundColor Yellow
}
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
function Get-Cfg ($Name, $Default) { if ($cfg.PSObject.Properties[$Name] -and $cfg.$Name) { $cfg.$Name } else { $Default } }
$CsvSubfolder = Get-Cfg 'CsvSubfolder' 'VMs'
$DCNames      = @(Get-Cfg 'DCNames' @())
$LogDir       = Get-Cfg 'LogDir' 'C:\temp\csv-move'
$ResultsCsv   = Join-Path $LogDir 'moves.csv'

# ---------- state ----------
$allCsv = @(Get-ClusterSharedVolume | Sort-Object Name)
if (-not $allCsv.Count) { throw 'No Cluster Shared Volumes found in this cluster.' }
$defCsv = Get-Cfg 'DefaultCsv' ''
$script:TargetCsv = if ($defCsv -and ($allCsv.Name -contains $defCsv)) { $defCsv } else { $allCsv[0].Name }

$upNodes = @(Get-ClusterNode | Where-Object State -eq 'Up' | ForEach-Object { $_.Name })
$defNode = Get-Cfg 'DefaultLeaveOnNode' ''
$script:LeaveNode = if ($defNode -and ($upNodes -contains $defNode)) { $defNode }
                    else { ($upNodes | Where-Object { $_ -ne $env:COMPUTERNAME } | Select-Object -First 1) }
if (-not $script:LeaveNode) { $script:LeaveNode = $env:COMPUTERNAME }
$script:Selected = @()

# ---------- helpers ----------
function Get-CsvMap {
    Get-ClusterSharedVolume | Sort-Object Name | ForEach-Object {
        $p = $_.SharedVolumeInfo[0].Partition
        [pscustomobject]@{
            Name   = $_.Name
            Mount  = $_.SharedVolumeInfo[0].FriendlyVolumeName
            SizeGB = [math]::Round($p.Size / 1GB)
            FreeGB = [math]::Round($p.FreeSpace / 1GB)
            UsedPct = [math]::Round(100 - $p.PercentFree)
            Owner  = $_.OwnerNode.Name
        }
    }
}

function Get-Location ($Path, $Map) {
    $m = $Map | Where-Object { $Path -like "$($_.Mount)\*" } | Select-Object -First 1
    if ($m) { $m.Name } else { ($Path -split '\\')[0] }
}

function Get-ChainBytes ($Path, $Node) {
    $total = 0; $p = $Path
    while ($p) { $v = Get-VHD -Path $p -ComputerName $Node; $total += $v.FileSize; $p = $v.ParentPath }
    $total
}

function Get-Overrides {
    $h = @{}
    if (Test-Path $OverrideFile) { Import-Csv $OverrideFile | ForEach-Object { $h[$_.VM] = $_.IP } }
    $h
}

function New-InvRow ($VM, $Node, $Clustered, $Map, $Ov) {
    $bytes = (Get-VMHardDiskDrive -VM $VM | Where-Object Path |
                ForEach-Object { Get-ChainBytes $_.Path $Node } | Measure-Object -Sum).Sum
    $ips = @((Get-VMNetworkAdapter -VM $VM).IPAddresses |
                Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' })
    [pscustomobject]@{
        VM          = $VM.Name
        Node        = $Node
        Clustered   = $Clustered
        Location    = Get-Location $VM.Path $Map
        State       = [string]$VM.State
        SizeGB      = [math]::Round($bytes / 1GB, 1)
        Checkpoints = @(Get-VMSnapshot -VM $VM).Count
        ReportedIP  = $ips -join ','
        SavedPingIP = $Ov[$VM.Name]
    }
}

function Get-VMInventory {
    $ov = Get-Overrides; $map = @(Get-CsvMap); $rows = @()
    foreach ($g in @(Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine')) {
        $node = $g.OwnerNode.Name
        $vm = Get-VM -Name $g.Name -ComputerName $node -ErrorAction SilentlyContinue
        if ($vm) { $rows += New-InvRow $vm $node $true $map $ov }
    }
    foreach ($vm in @(Get-VM | Where-Object { -not $_.IsClustered })) {
        $rows += New-InvRow $vm $env:COMPUTERNAME $false $map $ov
    }
    $rows | Sort-Object SizeGB
}

function Read-Choice ($Prompt, $Items, $Label) {
    for ($i = 0; $i -lt $Items.Count; $i++) { ('{0,3}) {1}' -f ($i + 1), (& $Label $Items[$i])) | Out-Host }
    $n = 0
    $raw = Read-Host $Prompt
    if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
    $null
}

function Select-FromConsole ($List) {
    for ($i = 0; $i -lt $List.Count; $i++) {
        '{0,3}) {1,-24} {2,9} GB  {3,-10} {4,-10} {5}' -f ($i + 1), $List[$i].VM, $List[$i].SizeGB,
            $List[$i].Location, $List[$i].Node, $List[$i].State | Out-Host
    }
    $raw = Read-Host 'Numbers, comma-separated (blank = cancel)'
    if (-not $raw) { return @() }
    $raw -split ',' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $List.Count) { $List[$n - 1] }
    }
}

# ---------- menu actions ----------
function Select-VMs {
    Write-Host 'Gathering VMs from all nodes...' -ForegroundColor DarkGray
    $list = @(Get-VMInventory | Where-Object { $_.Location -ne $script:TargetCsv })
    if (-not $list.Count) { Write-Host "Nothing to move - every VM is already on $($script:TargetCsv)." -ForegroundColor Green; return }
    try {
        $pick = $list | Out-GridView -Title "Select VMs to move to $($script:TargetCsv) (filter, Ctrl/Shift-click, OK)" -PassThru
    } catch {
        $pick = Select-FromConsole $list
    }
    $script:Selected = @($pick | Where-Object { $_ })
    $noPing = @($script:Selected | Where-Object { $_.State -eq 'Running' -and -not $_.ReportedIP -and -not $_.SavedPingIP })
    if ($noPing.Count) { Write-Host "No IP known for: $($noPing.VM -join ', ') - use option 8 for ping tests." -ForegroundColor Yellow }
}

function Select-TargetCsv {
    $map = @(Get-CsvMap)
    $c = Read-Choice 'Target CSV number' $map { param($x) '{0,-14} {1,6:N0} GB free of {2,6:N0} GB ({3}% used)' -f $x.Name, $x.FreeGB, $x.SizeGB, $x.UsedPct }
    if ($c) { $script:TargetCsv = $c.Name; $script:Selected = @(); Write-Host "Target CSV: $($c.Name) (selection cleared)" -ForegroundColor Green }
}

function Select-LeaveNode {
    $nodes = @(Get-ClusterNode | Where-Object State -eq 'Up' | ForEach-Object { $_.Name })
    $n = Read-Choice 'Leave-on node number' $nodes { param($x) $x }
    if ($n) { $script:LeaveNode = $n; Write-Host "Leave-on node: $n" -ForegroundColor Green }
}

function Save-PingOverride ($Name, $IP) {
    $ov = Get-Overrides
    if ($IP) { $ov[$Name] = $IP } else { $ov.Remove($Name) }
    if ($ov.Count) {
        $ov.GetEnumerator() | ForEach-Object { [pscustomobject]@{ VM = $_.Key; IP = $_.Value } } |
            Export-Csv $OverrideFile -NoTypeInformation
    } elseif (Test-Path $OverrideFile) { Remove-Item $OverrideFile }
}

function Set-PingOverride {
    $name = Read-Host 'VM name (exact, as shown in Hyper-V)'
    $known = (Get-ClusterGroup -Name $name -ErrorAction SilentlyContinue) -or (Get-VM -Name $name -ErrorAction SilentlyContinue)
    if (-not $known) { Write-Host "No VM named '$name' in the cluster or on this node." -ForegroundColor Red; return }
    $ip = Read-Host 'IP to ping (blank = remove saved IP)'
    if ($ip -and $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Host 'Not an IPv4 address.' -ForegroundColor Red; return }
    Save-PingOverride $name $ip
    Write-Host 'Saved.' -ForegroundColor Green
}

function Get-VMNode ($Name) {
    $g = Get-ClusterGroup -Name $Name -ErrorAction SilentlyContinue
    if ($g -and $g.GroupType -eq 'VirtualMachine') { $g.OwnerNode.Name } else { $env:COMPUTERNAME }
}

function Get-PingPlan {
    $ov = Get-Overrides
    foreach ($s in $script:Selected) {
        $node = Get-VMNode $s.VM
        $vm   = Get-VM -Name $s.VM -ComputerName $node
        $src  = 'None'; $ips = @()
        if ($ov.ContainsKey($s.VM)) { $src = 'Saved'; $ips = @($ov[$s.VM]) }
        else {
            $ips = @((Get-VMNetworkAdapter -VMName $s.VM -ComputerName $node).IPAddresses |
                     Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' })
            if ($ips.Count) { $src = 'Reported' }
        }
        $ok = @($ips | Where-Object { $_ -and (Test-Connection -ComputerName $_ -Count 2 -Quiet) })
        [pscustomobject]@{
            VM         = $s.VM
            State      = [string]$vm.State
            Source     = $src
            IPs        = $ips -join ','
            Responding = $ok -join ','
            PingTests  = if ($vm.State -ne 'Running') { 'n/a (off)' } elseif ($ok.Count) { 'YES' } else { 'NO' }
        }
    }
}

function Confirm-PingPlan {
    Write-Host "`nChecking which IP each VM will be ping-tested on..." -ForegroundColor DarkGray
    $plan = @(Get-PingPlan)
    $plan | Format-Table VM, State, Source, IPs, Responding, PingTests -AutoSize | Out-Host
    $changed = $false
    foreach ($p in @($plan | Where-Object PingTests -eq 'NO')) {
        $ip = Read-Host "No responding IP for '$($p.VM)'. Enter an IP to ping (blank = move without ping tests)"
        if (-not $ip) { continue }
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Host 'Not an IPv4 address - skipping.' -ForegroundColor Red; continue }
        Save-PingOverride $p.VM $ip
        $changed = $true
    }
    if ($changed) {
        Write-Host 'Re-checking...' -ForegroundColor DarkGray
        Get-PingPlan | Format-Table VM, State, Source, IPs, Responding, PingTests -AutoSize | Out-Host
    }
}

function Invoke-Mover ([switch]$Execute, [switch]$LiveMigrate, [switch]$Leave) {
    if (-not $script:Selected.Count) { Write-Host 'Pick VMs first (option 1).' -ForegroundColor Yellow; return }
    $names = @($script:Selected.VM)
    $p = @{
        VMName = $names; CsvName = $script:TargetCsv; CsvSubfolder = $CsvSubfolder
        DCNames = $DCNames; LogDir = $LogDir; PingOverride = (Get-Overrides)
    }
    if ($Execute) {
        Confirm-PingPlan
        $p.PingOverride = Get-Overrides
        $gb = [math]::Round(($script:Selected | Measure-Object SizeGB -Sum).Sum, 1)
        $what = if ($Leave) { "move to $($script:TargetCsv), cluster and LEAVE ON $($script:LeaveNode)" }
                elseif ($LiveMigrate) { "move to $($script:TargetCsv), cluster and live-migration test" }
                else { "move to $($script:TargetCsv) and cluster" }
        if ((Read-Host "Type YES to $what - $($names.Count) VM(s), $gb GB") -cne 'YES') { Write-Host 'Cancelled.'; return }
        $p.Execute = $true
        if ($names.Count -gt 1) { $p.PauseBetween = $true }
    }
    if ($LiveMigrate) { $p.TestLiveMigration = $true }
    if ($Leave)       { $p.LeaveOnNode = $script:LeaveNode }
    & $MoveScript @p
    if ($Execute) { $script:Selected = @() }
}

function Show-Status {
    Get-CsvMap | Format-Table Name, Mount, SizeGB, FreeGB, @{n='Used%';e={$_.UsedPct}}, Owner -AutoSize | Out-Host
    $inv = @(Get-VMInventory)
    $inv | Group-Object Location | Sort-Object Name |
        Format-Table @{n='Storage';e={$_.Name}}, @{n='VMs';e={$_.Count}},
                     @{n='GB';e={[math]::Round(($_.Group | Measure-Object SizeGB -Sum).Sum)}} -AutoSize | Out-Host
    $inv | Sort-Object Location, VM | Format-Table VM, Location, Node, Clustered, State, SizeGB -AutoSize | Out-Host
}

function Show-Results {
    if (Test-Path $ResultsCsv) {
        Import-Csv $ResultsCsv | Select-Object -Last 15 |
            Format-Table Time, VM, TargetCsv, SizeGB, MoveMin, MoveLoss, LMToOutageSec, LMBackOutageSec, FinalNode, Status, Error -AutoSize -Wrap | Out-Host
    } else { Write-Host "No results yet ($ResultsCsv)." }
}

# ---------- main loop ----------
while ($true) {
    $t = Get-CsvMap | Where-Object Name -eq $script:TargetCsv
    Write-Host "`n==== VM mover ($env:COMPUTERNAME) ====" -ForegroundColor Cyan
    Write-Host ("Target CSV : {0}  ({1:N0} GB free)     Leave-on node: {2}" -f $t.Name, $t.FreeGB, $script:LeaveNode)
    if ($script:Selected.Count) {
        $gb = [math]::Round(($script:Selected | Measure-Object SizeGB -Sum).Sum, 1)
        Write-Host "Selected   : $($script:Selected.VM -join ', ')  [$gb GB]" -ForegroundColor Yellow
    } else { Write-Host 'Selected   : (none)' -ForegroundColor DarkGray }
    Write-Host @'
 1) Pick VMs                (anything not already on the target CSV)
 2) Preflight selected      (dry run - no changes)
 3) Move + cluster          (VM stays on its current node)
 4) Move + cluster + live-migration round trip
 5) Move + cluster + migrate to leave-on node and leave it there
 6) Change target CSV
 7) Change leave-on node
 8) Set / clear ping IP for a VM
 S) Status    R) Recent results    Q) Quit
'@
    try {
        switch ((Read-Host 'Choice').Trim().ToUpper()) {
            '1' { Select-VMs }
            '2' { Invoke-Mover }
            '3' { Invoke-Mover -Execute }
            '4' { Invoke-Mover -Execute -LiveMigrate }
            '5' { Invoke-Mover -Execute -Leave }
            '6' { Select-TargetCsv }
            '7' { Select-LeaveNode }
            '8' { Set-PingOverride }
            'S' { Show-Status }
            'R' { Show-Results }
            'Q' { return }
            default { Write-Host 'Pick 1-8, S, R or Q.' }
        }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
