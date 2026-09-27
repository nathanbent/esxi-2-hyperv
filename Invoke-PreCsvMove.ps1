<#
.SYNOPSIS
    READ-ONLY pre-move check for moving VMs from standalone SAN volumes (M:, N:) to a CSV.
    Run on SPS-HV-1 (where the VMs currently live). Makes NO changes - only reports and prints suggested commands.
#>
param(
    [string]  $CsvName     = 'hv-csv-1',
    [string]  $CsvPath     = 'C:\ClusterStorage\hv-csv-1\VMs',
    [string]  $PartnerNode = 'SPS-HV-2',
    [string[]]$SourceDrives = @('M','N'),
    [string[]]$DCs         = @('NEW-DC1','NEW-DC2','DC3')
)

Write-Host "`n=== CSV access per node (want: Direct on both) ===" -ForegroundColor Cyan
Get-ClusterSharedVolumeState -Name $CsvName |
    Select-Object Node, StateInfo, FileSystemRedirectedIOReason, BlockRedirectedIOReason |
    Format-Table -AutoSize

Write-Host "=== Host CPUs (different models = VMs need processor compatibility for live migration) ===" -ForegroundColor Cyan
Invoke-Command -ComputerName $env:COMPUTERNAME, $PartnerNode {
    [pscustomobject]@{ Host = $env:COMPUTERNAME; CPU = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() }
} | Select-Object Host, CPU | Format-Table -AutoSize

$csv       = Get-ClusterSharedVolume -Name $CsvName
$csvFreeGB = [math]::Round($csv.SharedVolumeInfo.Partition.FreeSpace / 1GB)
$srcRegex  = '^(' + ($SourceDrives -join '|') + '):\\'

$report = foreach ($vm in Get-VM) {
    $disks    = @(Get-VMHardDiskDrive -VM $vm)
    $vhdPaths = @($disks | Where-Object Path | Select-Object -ExpandProperty Path)
    $bytes    = ($vhdPaths | ForEach-Object { (Get-Item $_ -ErrorAction SilentlyContinue).Length } | Measure-Object -Sum).Sum
    $isos     = @(Get-VMDvdDrive -VM $vm | Where-Object Path | Select-Object -ExpandProperty Path)
    $cps      = @(Get-VMSnapshot -VM $vm)
    $passThru = @($disks | Where-Object { $null -ne $_.DiskNumber })
    $offPaths = @(@($vm.Path) + $vhdPaths | Where-Object { $_ -notmatch $srcRegex })
    $isDC     = $DCs -contains $vm.Name

    $issues = @(); $fixes = @()
    if ($isos.Count)     { $issues += "ISO mounted";                 $fixes += "Get-VMDvdDrive -VMName '$($vm.Name)' | Set-VMDvdDrive -Path `$null" }
    if ($cps.Count)      { $issues += "$($cps.Count) checkpoint(s)"; $fixes += "Get-VMSnapshot -VMName '$($vm.Name)' | Remove-VMSnapshot   # merges into parent" }
    if ($passThru.Count) { $issues += "PASS-THROUGH DISK (cannot live migrate)" }
    if ($offPaths.Count) { $issues += "files outside $($SourceDrives -join '/'): $($offPaths -join ', ')" }

    [pscustomobject]@{
        VM          = $vm.Name
        State       = $vm.State
        Gen         = $vm.Generation
        MemGB       = [math]::Round($vm.MemoryStartup / 1GB, 1)
        DiskGB      = [math]::Round($bytes / 1GB, 1)
        IsDC        = $isDC
        ProcCompat  = (Get-VMProcessor -VM $vm).CompatibilityForMigrationEnabled
        Issues      = ($issues -join '; ')
        Fixes       = $fixes
    }
}

Write-Host "`n=== VM readiness ===" -ForegroundColor Cyan
$report | Sort-Object DiskGB |
    Format-Table VM, State, Gen, MemGB, DiskGB, IsDC, ProcCompat, Issues -AutoSize -Wrap

$totalGB = [math]::Round(($report | Measure-Object DiskGB -Sum).Sum)
Write-Host ("Total VHD data to move: {0:N0} GB   CSV free: {1:N0} GB" -f $totalGB, $csvFreeGB) -ForegroundColor Yellow
if ($totalGB -gt $csvFreeGB * 0.9) { Write-Host "WARNING: moves would leave the CSV >90% full" -ForegroundColor Red }

$needFix = $report | Where-Object { $_.Fixes.Count }
if ($needFix) {
    Write-Host "`n=== Suggested fixes (review, then run yourself) ===" -ForegroundColor Cyan
    $needFix | ForEach-Object { $_.Fixes }
}

Write-Host "`n=== Suggested move order (smallest non-DC first, DCs last, one at a time) ===" -ForegroundColor Cyan
$report | Sort-Object IsDC, DiskGB | ForEach-Object {
    "Move-VMStorage -VMName '$($_.VM)' -DestinationStoragePath '$CsvPath\$($_.VM)'"
    "Add-ClusterVirtualMachineRole -VMName '$($_.VM)'"
    ""
}
