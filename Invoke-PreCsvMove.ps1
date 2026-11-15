<#
.SYNOPSIS
    READ-ONLY readiness report for moving this node's VMs onto a Cluster Shared Volume.
    Run on the Hyper-V node where the VMs currently live. Makes NO changes - only reports and prints suggested commands.

.DESCRIPTION
    - CSV access state per node (want Direct everywhere)
    - Host CPU model per Up node (different models = VMs need processor compatibility for live migration)
    - Per VM on this node: size, generation, DC or not, ISOs, checkpoints, pass-through disks,
      files outside -SourceDrives (when given)
    - Total data vs CSV free space, suggested fixes, suggested move order (smallest non-DC first, DCs last)

    Defaults come from mover-config.json (same file Start-VMMover.ps1 uses) when present; DCs are also
    auto-detected from AD.

.EXAMPLE
    .\Invoke-PreCsvMove.ps1
    .\Invoke-PreCsvMove.ps1 -CsvName 'Cluster Disk 2' -SourceDrives M,N
#>
[CmdletBinding()]
param(
    [string]  $CsvName,                          # default: DefaultCsv from config, else the only/first CSV
    [string]  $CsvSubfolder,                     # default: CsvSubfolder from config, else 'VMs'
    [string[]]$SourceDrives = @(),               # e.g. M,N - flag VM files that live anywhere else
    [string[]]$DCNames      = @(),               # Hyper-V VM names of DCs, in addition to config + AD
    [string]  $ConfigFile   = (Join-Path $PSScriptRoot 'mover-config.json')
)

$ErrorActionPreference = 'Stop'

$cfg = $null
if (Test-Path $ConfigFile) { try { $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch { } }
if (-not $CsvSubfolder) { $CsvSubfolder = if ($cfg -and $cfg.CsvSubfolder) { $cfg.CsvSubfolder } else { 'VMs' } }
if ($cfg -and $cfg.DCNames) { $DCNames += @($cfg.DCNames) }
try {
    $DCNames += @([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers |
                  ForEach-Object { ($_.Name -split '\.')[0] })
} catch { }
$DCNames = @($DCNames | Where-Object { $_ } | Select-Object -Unique)

$allCsv = @(Get-ClusterSharedVolume | Sort-Object Name)
if (-not $allCsv.Count) { throw 'No Cluster Shared Volumes found in this cluster.' }
if (-not $CsvName) {
    $CsvName = if ($cfg -and $cfg.DefaultCsv -and ($allCsv.Name -contains $cfg.DefaultCsv)) { $cfg.DefaultCsv } else { $allCsv[0].Name }
}
$csv = $allCsv | Where-Object Name -eq $CsvName
if (-not $csv) { throw "No CSV named '$CsvName' (have: $($allCsv.Name -join ', '))" }
$CsvMount  = $csv.SharedVolumeInfo[0].FriendlyVolumeName
$CsvPath   = Join-Path $CsvMount $CsvSubfolder
$csvFreeGB = [math]::Round($csv.SharedVolumeInfo[0].Partition.FreeSpace / 1GB)
$upNodes   = @(Get-ClusterNode | Where-Object State -eq 'Up' | ForEach-Object { $_.Name })

Write-Host "`n=== CSV access per node for $CsvName (want: Direct on all) ===" -ForegroundColor Cyan
Get-ClusterSharedVolumeState -Name $CsvName |
    Select-Object Node, StateInfo, FileSystemRedirectedIOReason, BlockRedirectedIOReason |
    Format-Table -AutoSize

Write-Host "=== Host CPUs (different models = VMs need processor compatibility for live migration) ===" -ForegroundColor Cyan
Invoke-Command -ComputerName $upNodes {
    [pscustomobject]@{ Host = $env:COMPUTERNAME; CPU = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() }
} | Select-Object Host, CPU | Format-Table -AutoSize

$srcRegex = if ($SourceDrives.Count) { '^(' + (($SourceDrives | ForEach-Object { $_.TrimEnd(':') }) -join '|') + '):\\' }

$report = foreach ($vm in Get-VM | Where-Object { $_.Path -notlike "$CsvMount\*" }) {
    $disks    = @(Get-VMHardDiskDrive -VM $vm)
    $vhdPaths = @($disks | Where-Object Path | Select-Object -ExpandProperty Path)
    $bytes    = ($vhdPaths | ForEach-Object { (Get-Item $_ -ErrorAction SilentlyContinue).Length } | Measure-Object -Sum).Sum
    $isos     = @(Get-VMDvdDrive -VM $vm | Where-Object Path | Select-Object -ExpandProperty Path)
    $cps      = @(Get-VMSnapshot -VM $vm)
    $passThru = @($disks | Where-Object { $null -ne $_.DiskNumber })
    $offPaths = if ($srcRegex) { @(@($vm.Path) + $vhdPaths | Where-Object { $_ -notmatch $srcRegex }) } else { @() }

    $issues = @(); $fixes = @()
    if ($isos.Count)     { $issues += "ISO mounted";                 $fixes += "Get-VMDvdDrive -VMName '$($vm.Name)' | Set-VMDvdDrive -Path `$null" }
    if ($cps.Count)      { $issues += "$($cps.Count) checkpoint(s)"; $fixes += "Get-VMSnapshot -VMName '$($vm.Name)' | Remove-VMSnapshot   # merges into parent" }
    if ($passThru.Count) { $issues += "PASS-THROUGH DISK (cannot live migrate)" }
    if ($offPaths.Count) { $issues += "files outside $($SourceDrives -join '/'): $($offPaths -join ', ')" }

    [pscustomobject]@{
        VM          = $vm.Name
        State       = $vm.State
        Clustered   = $vm.IsClustered
        Gen         = $vm.Generation
        MemGB       = [math]::Round($vm.MemoryStartup / 1GB, 1)
        DiskGB      = [math]::Round($bytes / 1GB, 1)
        IsDC        = $DCNames -contains $vm.Name
        ProcCompat  = (Get-VMProcessor -VM $vm).CompatibilityForMigrationEnabled
        Issues      = ($issues -join '; ')
        Fixes       = $fixes
    }
}
$report = @($report)
if (-not $report.Count) { Write-Host "Every VM on $env:COMPUTERNAME is already on $CsvName." -ForegroundColor Green; return }

Write-Host "`n=== VM readiness ($env:COMPUTERNAME -> $CsvName) ===" -ForegroundColor Cyan
$report | Sort-Object DiskGB |
    Format-Table VM, State, Clustered, Gen, MemGB, DiskGB, IsDC, ProcCompat, Issues -AutoSize -Wrap

$totalGB = [math]::Round(($report | Measure-Object DiskGB -Sum).Sum)
Write-Host ("Total VHD data to move: {0:N0} GB   CSV free: {1:N0} GB" -f $totalGB, $csvFreeGB) -ForegroundColor Yellow
if ($totalGB -gt $csvFreeGB * 0.9) { Write-Host "WARNING: moves would leave the CSV >90% full" -ForegroundColor Red }

$needFix = $report | Where-Object { $_.Fixes.Count }
if ($needFix) {
    Write-Host "`n=== Suggested fixes (review, then run yourself) ===" -ForegroundColor Cyan
    $needFix | ForEach-Object { $_.Fixes }
}

Write-Host "`n=== Suggested move order (smallest non-DC first, DCs last, one at a time) ===" -ForegroundColor Cyan
Write-Host "Or let Move-VMToCsv.ps1 / Start-VMMover.ps1 do it with health checks." -ForegroundColor DarkGray
$report | Sort-Object IsDC, DiskGB | ForEach-Object {
    "Move-VMStorage -VMName '$($_.VM)' -DestinationStoragePath '$CsvPath\$($_.VM)'"
    if (-not $_.Clustered) { "Add-ClusterVirtualMachineRole -VMName '$($_.VM)'" }
    ""
}
