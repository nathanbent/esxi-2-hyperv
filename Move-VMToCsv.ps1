<#
.SYNOPSIS
    Moves Hyper-V VMs onto a Cluster Shared Volume and makes them highly available, with ping +
    heartbeat checks at every stage. Also re-homes already-clustered VMs from one CSV to another.

.DESCRIPTION
    DRY RUN BY DEFAULT: without -Execute it only runs preflight checks and prints the plan.
    One VM at a time; stops at the first failure; aborts before any change if any VM fails preflight.
    Run on any cluster node as a domain admin. Nothing site-specific is hardcoded: the CSV path,
    nodes and DCs are discovered from the cluster/domain (plus optional -DCNames).

    Handles:
      - Non-clustered VMs on THIS node (standalone SAN / local storage)  -> CSV, then clustered
      - Clustered VMs on ANY node, one CSV -> another CSV (storage-only; VM keeps running where it is)

    Per VM (with -Execute):
      1. Continuous ping during Move-VMStorage (expect zero loss)
      2. Verify every VM file is under the target CSV; Get-VHD each disk
      3. Verify VM still Running, heartbeat OK, ping OK
      4. Add-ClusterVirtualMachineRole if not clustered yet; DCs get High priority + anti-affinity
      5. Optional: -TestLiveMigration (round trip to another node and back) or
                   -LeaveOnNode <node> (migrate there and leave it)

    Logs: transcript + moves.csv in $LogDir.

.EXAMPLE
    .\Move-VMToCsv.ps1 -VMName 'SMTP Server' -CsvName hv-csv-1                          # preflight only
    .\Move-VMToCsv.ps1 -VMName 'SMTP Server' -CsvName hv-csv-1 -Execute -TestLiveMigration
    .\Move-VMToCsv.ps1 -VMName 'RG-01' -CsvName hv-csv-1 -Execute -LeaveOnNode SPS-HV-2
    .\Move-VMToCsv.ps1 -VMName 'SPS-SQL' -CsvName hv-csv-2 -Execute                       # re-home a clustered VM
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$VMName,
    [Parameter(Mandatory)][string]  $CsvName,
    [string]   $CsvSubfolder        = 'VMs',
    [string[]] $DCNames             = @(),       # Hyper-V VM names of DCs, in addition to auto-detected ones
    [string]   $DCAntiAffinityClass = 'DCs',
    [hashtable]$PingOverride        = @{},       # for VMs that don't report IPs via integration services
    [int]      $MaxOutageSec        = 5,         # max acceptable ping outage during a live migration
    [int]      $CsvReservePct       = 10,        # refuse a move that leaves the CSV with less free than this
    [switch]   $Execute,
    [switch]   $TestLiveMigration,
    [string]   $LeaveOnNode,                     # migrate to this node and leave it there
    [switch]   $PauseBetween,
    [string]   $LogDir              = 'C:\temp\csv-move'
)

$ErrorActionPreference = 'Stop'
$LocalNode = $env:COMPUTERNAME

# ---------- discover environment ----------
$CsvMount = (Get-ClusterSharedVolume -Name $CsvName).SharedVolumeInfo[0].FriendlyVolumeName
$CsvRoot  = Join-Path $CsvMount $CsvSubfolder
$UpNodes  = @(Get-ClusterNode | Where-Object State -eq 'Up' | ForEach-Object { $_.Name })
if ($LeaveOnNode -and ($UpNodes -notcontains $LeaveOnNode)) {
    throw "LeaveOnNode '$LeaveOnNode' is not an Up cluster node (Up: $($UpNodes -join ', '))"
}
$AdDcNames = @()
try {
    $AdDcNames = @([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers |
                   ForEach-Object { ($_.Name -split '\.')[0] })
} catch { }

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$ResultsCsv = Join-Path $LogDir 'moves.csv'
Start-Transcript -Path (Join-Path $LogDir "move-$Stamp.log") | Out-Null

# ---------- helpers ----------
function Write-Step ($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "     OK   $m" -ForegroundColor Green }
function Write-Wrn  ($m) { Write-Host "     WARN $m" -ForegroundColor Yellow }

function Test-IsDC ($Name) { ($DCNames -contains $Name) -or ($AdDcNames -contains $Name) }

function Find-VM ($Name) {
    $grp = Get-ClusterGroup -Name $Name -ErrorAction SilentlyContinue
    if ($grp -and $grp.GroupType -eq 'VirtualMachine') {
        $node = $grp.OwnerNode.Name
        return [pscustomobject]@{ VM = (Get-VM -Name $Name -ComputerName $node); Node = $node; Clustered = $true }
    }
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($vm) { return [pscustomobject]@{ VM = $vm; Node = $LocalNode; Clustered = $false } }
    $null
}

function Get-ChainBytes ($Path, $Node) {
    $total = 0; $p = $Path
    while ($p) { $v = Get-VHD -Path $p -ComputerName $Node; $total += $v.FileSize; $p = $v.ParentPath }
    $total
}

function Get-VMIPv4 ($Name, $Node) {
    if ($PingOverride.ContainsKey($Name)) { return @($PingOverride[$Name]) }
    @((Get-VMNetworkAdapter -VMName $Name -ComputerName $Node).IPAddresses |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' })
}

function Get-RespondingIPs ($IPs) {
    @($IPs | Where-Object { $_ -and (Test-Connection -ComputerName $_ -Count 2 -Quiet) })
}

function Get-Heartbeat ($Name, $Node) {
    (Get-VMIntegrationService -VMName $Name -ComputerName $Node -Name 'Heartbeat').PrimaryStatusDescription
}

function Get-FreeRamGB ($Node) {
    [math]::Floor((Get-CimInstance Win32_OperatingSystem -ComputerName $Node).FreePhysicalMemory / 1MB)
}

function Start-PingMonitor ($IP) {
    $job = Start-Job -ArgumentList $IP -ScriptBlock {
        param($IP)
        while ($true) {
            [pscustomobject]@{ T = Get-Date; Ok = [bool](Test-Connection -ComputerName $IP -Count 1 -Quiet) }
            Start-Sleep -Milliseconds 500
        }
    }
    Start-Sleep -Seconds 3
    $job
}

function Stop-PingMonitor ($Job) {
    Start-Sleep -Seconds 5
    Stop-Job $Job
    $r = @(Receive-Job $Job); Remove-Job $Job
    $maxGap = 0; $gapStart = $null
    foreach ($p in $r) {
        if (-not $p.Ok) {
            if (-not $gapStart) { $gapStart = $p.T }
            $gap = ($p.T - $gapStart).TotalSeconds + 1
            if ($gap -gt $maxGap) { $maxGap = $gap }
        } else { $gapStart = $null }
    }
    [pscustomobject]@{ Sent = $r.Count; Lost = @($r | Where-Object { -not $_.Ok }).Count; MaxOutageSec = [math]::Round($maxGap, 1) }
}

function Test-VMHealthy ($Pf, $Node, $Stage) {
    $vm = Get-VM -Name $Pf.VM -ComputerName $Node
    if ($vm.State -ne 'Running') { throw "[$Stage] VM is $($vm.State) on $Node" }
    if ($Pf.Heartbeat -eq 'OK') {
        $hb = $null
        foreach ($i in 1..12) { $hb = Get-Heartbeat $Pf.VM $Node; if ($hb -eq 'OK') { break }; Start-Sleep -Seconds 5 }
        if ($hb -ne 'OK') { throw "[$Stage] heartbeat is '$hb' on $Node" }
    }
    if ($Pf.PingIPs.Count) {
        $up = @()
        foreach ($i in 1..6) {   # routers/appliances may rate-limit ICMP right after a burst
            $up = @(Get-RespondingIPs $Pf.PingIPs)
            if ($up.Count -eq $Pf.PingIPs.Count) { break }
            Start-Sleep -Seconds 5
        }
        if ($up.Count -ne $Pf.PingIPs.Count) {
            throw "[$Stage] not responding after ~30s: $((@($Pf.PingIPs | Where-Object { $_ -notin $up })) -join ', ')"
        }
    }
    Write-Ok "[$Stage] running on $Node, heartbeat $(if ($Pf.Heartbeat -eq 'OK') {'OK'} else {'n/a'}), ping $(if ($Pf.PingIPs.Count) {'OK'} else {'n/a'})"
}

function Invoke-LM ($Pf, $Res, $Target, $Leg) {
    $name    = $Pf.VM
    $current = (Get-ClusterGroup -Name $name).OwnerNode.Name
    $needGB  = [math]::Ceiling((Get-VM -Name $name -ComputerName $current).MemoryAssigned / 1GB) + 4
    $freeGB  = Get-FreeRamGB $Target
    if ($freeGB -lt $needGB) {
        Write-Wrn "$Target has $freeGB GB free RAM, VM needs ~$needGB GB - skipping live migration, VM stays on $current"
        $Res.Error = "NOTE: live migration skipped, $Target free RAM $freeGB GB < $needGB GB"
        return $false
    }
    Write-Step "live migrate $current -> $Target"
    $ping = $Pf.PingIPs | Select-Object -First 1
    $mon  = if ($ping) { Start-PingMonitor $ping }
    Move-ClusterVirtualMachineRole -Name $name -Node $Target -MigrationType Live | Out-Null
    $owner = (Get-ClusterGroup -Name $name).OwnerNode.Name
    if ($owner -ne $Target) { throw "owner is $owner after migration to $Target" }
    if ($mon) {
        $m = Stop-PingMonitor $mon
        $Res["LM$($Leg)OutageSec"] = $m.MaxOutageSec
        if ($m.MaxOutageSec -gt $MaxOutageSec) { throw "ping outage ~$($m.MaxOutageSec)s exceeds $MaxOutageSec s" }
        Write-Ok "migrated; ping lost $($m.Lost)/$($m.Sent), longest outage ~$($m.MaxOutageSec)s"
    } else { Write-Ok 'migrated' }
    Test-VMHealthy $Pf $Target "on $Target"
    $true
}

# ---------- preflight ----------
function Invoke-Preflight ($Name) {
    $pf = [pscustomobject]@{
        VM = $Name; Pass = $true; Node = ''; Clustered = $false; State = ''; IsDC = (Test-IsDC $Name)
        SizeGB = 0; IPs = @(); PingIPs = @(); Heartbeat = ''; Notes = @()
    }
    $f = Find-VM $Name
    if (-not $f) { $pf.Pass = $false; $pf.Notes += "not a clustered VM and not on $LocalNode"; return $pf }
    $vm = $f.VM; $pf.Node = $f.Node; $pf.Clustered = $f.Clustered; $pf.State = [string]$vm.State

    if ($vm.Path -like "$CsvMount\*") { $pf.Pass = $false; $pf.Notes += "already on $CsvName" }

    $disks = @(Get-VMHardDiskDrive -VM $vm)
    if ($disks | Where-Object { $null -ne $_.DiskNumber }) { $pf.Pass = $false; $pf.Notes += 'pass-through disk' }

    $bytes = ($disks | Where-Object Path | ForEach-Object { Get-ChainBytes $_.Path $f.Node } | Measure-Object -Sum).Sum
    $pf.SizeGB = [math]::Round($bytes / 1GB, 1)
    $part = (Get-ClusterSharedVolume -Name $CsvName).SharedVolumeInfo[0].Partition
    if (($part.FreeSpace - $bytes) -lt ($part.Size * $CsvReservePct / 100)) {
        $pf.Pass = $false; $pf.Notes += "would leave $CsvName under $CsvReservePct% free"
    }

    $dest = Join-Path $CsvRoot $Name
    if ((Test-Path $dest) -and (Get-ChildItem $dest -Force)) { $pf.Pass = $false; $pf.Notes += "destination not empty: $dest" }
    if (-not (Test-Path $CsvRoot)) { $pf.Notes += "will create $CsvRoot" }

    $cps = @(Get-VMSnapshot -VM $vm)
    if ($cps.Count) { $pf.Notes += "$($cps.Count) checkpoint(s) will move with it" }
    Get-VMDvdDrive -VM $vm | Where-Object Path | ForEach-Object { $pf.Notes += "ISO stays at $($_.Path)" }

    if ($vm.State -eq 'Running') {
        $pf.IPs       = @(Get-VMIPv4 $Name $f.Node)
        $pf.PingIPs   = @(Get-RespondingIPs $pf.IPs)
        $pf.Heartbeat = Get-Heartbeat $Name $f.Node
        if (-not $pf.IPs.Count)         { $pf.Notes += 'no IPv4 reported - set a ping IP for ping tests' }
        elseif (-not $pf.PingIPs.Count) { $pf.Notes += 'no IP answers ping - network checks skipped' }
        if ($pf.Heartbeat -ne 'OK')     { $pf.Notes += "heartbeat '$($pf.Heartbeat)' - heartbeat checks skipped" }
    } else {
        $pf.Notes += 'not running - no ping/heartbeat/live-migration tests'
    }
    if ($LeaveOnNode -and $f.Node -eq $LeaveOnNode) { $pf.Notes += "already on $LeaveOnNode" }
    $pf
}

# ---------- execute one VM ----------
function Invoke-Move ($Pf) {
    $name    = $Pf.VM
    $f       = Find-VM $name                       # refresh owner in case it changed since preflight
    $node    = $f.Node
    $dest    = Join-Path $CsvRoot $name
    $running = $Pf.State -eq 'Running'
    $ping    = $Pf.PingIPs | Select-Object -First 1
    $res = [ordered]@{
        Time = Get-Date -Format s; VM = $name; FromNode = $node; TargetCsv = $CsvName; SizeGB = $Pf.SizeGB
        MoveMin = ''; MoveLoss = ''; Clustered = $f.Clustered; LMToOutageSec = ''; LMBackOutageSec = ''
        FinalNode = ''; Status = 'FAILED'; Error = ''
    }
    try {
        Write-Host "`n=== $name ($($Pf.SizeGB) GB) on $node -> $CsvName ===" -ForegroundColor Magenta
        if (-not (Test-Path $CsvRoot)) { New-Item -ItemType Directory -Path $CsvRoot | Out-Null }

        # 1. storage move (runs on whichever node owns the VM)
        Write-Step "Move-VMStorage -> $dest"
        $mon = if ($ping) { Start-PingMonitor $ping }
        $sw  = [Diagnostics.Stopwatch]::StartNew()
        Move-VMStorage -ComputerName $node -VMName $name -DestinationStoragePath $dest
        $sw.Stop()
        $res.MoveMin = [math]::Round($sw.Elapsed.TotalMinutes, 1)
        if ($mon) {
            $m = Stop-PingMonitor $mon
            $res.MoveLoss = "$($m.Lost)/$($m.Sent)"
            if ($m.Lost) { Write-Wrn "ping loss during storage move: $($res.MoveLoss) (not expected - investigate)" }
            else { Write-Ok "storage move done in $($res.MoveMin) min, no ping loss" }
        } else { Write-Ok "storage move done in $($res.MoveMin) min" }

        # 2. verify files
        $vm    = Get-VM -Name $name -ComputerName $node
        $vhds  = @(Get-VMHardDiskDrive -VM $vm | Where-Object Path)
        $paths = @($vm.Path, $vm.ConfigurationLocation, $vm.SnapshotFileLocation, $vm.SmartPagingFilePath) + $vhds.Path
        $off   = @($paths | Where-Object { $_ -and ($_ -notlike "$CsvRoot\*") -and ($_ -ne $CsvRoot) })
        if ($off.Count) { throw "files outside $CsvRoot : $($off -join ', ')" }
        foreach ($d in $vhds) { Get-VHD -Path $d.Path -ComputerName $node | Out-Null }
        Write-Ok "all files on $CsvName, $($vhds.Count) VHD(s) readable"

        # 3. health after move
        if ($running) { Test-VMHealthy $Pf $node 'post-move' }

        # 4. cluster it (if needed) + DC settings
        if (-not $f.Clustered) {
            Write-Step 'Add-ClusterVirtualMachineRole'
            Add-ClusterVirtualMachineRole -VMName $name | Out-Null
        }
        $grp = Get-ClusterGroup -Name $name
        if ($running -and $grp.State -ne 'Online') { throw "cluster group state is $($grp.State)" }
        if ($Pf.IsDC) {
            $aa = New-Object System.Collections.Specialized.StringCollection
            [void]$aa.Add($DCAntiAffinityClass)
            $grp.AntiAffinityClassNames = $aa
            $grp.Priority = 3000
            Write-Ok "DC: priority High, anti-affinity class '$DCAntiAffinityClass'"
        }
        $res.Clustered = $true
        Write-Ok "clustered, owner $($grp.OwnerNode.Name)"

        # 5. live migration
        if ($running) {
            $origin = $grp.OwnerNode.Name
            if ($LeaveOnNode) {
                if ($origin -eq $LeaveOnNode) { Write-Ok "already on $LeaveOnNode" }
                else { [void](Invoke-LM $Pf $res $LeaveOnNode 'To') }
            }
            elseif ($TestLiveMigration) {
                $other = $UpNodes | Where-Object { $_ -ne $origin } | Select-Object -First 1
                if (-not $other) { Write-Wrn 'no other Up node - live migration test skipped' }
                elseif (Invoke-LM $Pf $res $other 'To') { [void](Invoke-LM $Pf $res $origin 'Back') }
            }
        }

        $res.FinalNode = (Get-ClusterGroup -Name $name).OwnerNode.Name
        $res.Status = 'OK'
        Write-Host "=== $name OK - on $CsvName, running on $($res.FinalNode) ===" -ForegroundColor Green
    }
    catch {
        $res.Error = $_.Exception.Message
        Write-Host "=== $name FAILED: $($res.Error) ===" -ForegroundColor Red
    }
    finally {
        Get-Job | Where-Object State -eq 'Running' | Stop-Job -PassThru | Remove-Job -ErrorAction SilentlyContinue
        [pscustomobject]$res | Export-Csv -Path $ResultsCsv -Append -NoTypeInformation
    }
    return ($res.Status -eq 'OK')
}

# ---------- main ----------
Write-Host "`n=== Preflight (target $CsvName -> $CsvRoot) ===" -ForegroundColor Cyan
$preflights = @(foreach ($n in $VMName) { Invoke-Preflight $n })
$preflights | Format-Table VM, Pass, Node, Clustered, State, SizeGB, IsDC,
    @{n='PingIPs'; e={ $_.PingIPs -join ',' }}, Heartbeat,
    @{n='Notes';   e={ $_.Notes -join '; ' }} -AutoSize -Wrap

if ($preflights | Where-Object { -not $_.Pass }) {
    Write-Host 'Preflight FAILED for at least one VM - nothing changed. Fix or remove it from -VMName.' -ForegroundColor Red
    Stop-Transcript | Out-Null; return
}
if (-not $Execute) {
    Write-Host 'DRY RUN - nothing changed. Re-run with -Execute.' -ForegroundColor Yellow
    Stop-Transcript | Out-Null; return
}

for ($i = 0; $i -lt $preflights.Count; $i++) {
    if (-not (Invoke-Move $preflights[$i])) {
        Write-Host 'Stopping - remaining VMs untouched. See the log and moves.csv.' -ForegroundColor Red
        break
    }
    if ($PauseBetween -and $i -lt $preflights.Count - 1) {
        if ((Read-Host "Continue with $($preflights[$i+1].VM)? (y/N)") -ne 'y') { break }
    }
}

Write-Host "`nResults: $ResultsCsv" -ForegroundColor Cyan
Stop-Transcript | Out-Null
