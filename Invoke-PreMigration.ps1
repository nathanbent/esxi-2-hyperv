<#
.SYNOPSIS
    Pre-migration capture for ESXi -> Hyper-V cutover.
    Run INSIDE the guest VM while it is still running on ESXi.

.DESCRIPTION
    Captures the network configuration and machine identity to C:\migration
    as both human-readable text and a machine-readable baseline.json that
    Invoke-PostMigration.ps1 consumes to reapply settings automatically.

    Safe to run repeatedly; each run overwrites the previous baseline.

.NOTES
    Run as administrator. PowerShell 5.1+ (Server 2012 R2 needs WMF update;
    2016+ works out of the box).
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$dir = 'C:\migration'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

Write-Host "== Pre-migration capture: $env:COMPUTERNAME ==" -ForegroundColor Cyan
function Step ($t) { Write-Host "  ... $t" -ForegroundColor DarkGray }
Step 'network / DNS / secure channel'

# ---------------------------------------------------------------------------
# 1. Raw human-readable captures (belt and suspenders)
# ---------------------------------------------------------------------------
# Native commands write to stderr on failure (e.g. nslookup "can't find"),
# which PowerShell treats as terminating under 'Stop' - so relax it here.
# A failed lookup is itself useful data and should land in the file, not kill the run.
$ErrorActionPreference = 'Continue'
ipconfig /all               | Out-File "$dir\pre-ipconfig.txt"
route print                 | Out-File "$dir\pre-routes.txt"
& cmd /c "nslookup $env:COMPUTERNAME 2>&1" | Out-File "$dir\pre-dns-record.txt"
if ($env:USERDNSDOMAIN) {
    & cmd /c "nltest /sc_verify:$env:USERDNSDOMAIN 2>&1" | Out-File "$dir\pre-securechannel.txt"
} else {
    'Not domain-joined' | Out-File "$dir\pre-securechannel.txt"
}
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 2. Structured baseline for the post-migration script
# ---------------------------------------------------------------------------
Step 'firmware and adapters'
# NOTE: deliberately NOT using Get-ComputerInfo - it can take minutes on 2016+.
$firmware = 'Unknown'
switch ("$env:firmware_type") {            # set by Windows 8 / 2012 and later
    'UEFI'   { $firmware = 'Uefi' }
    'Legacy' { $firmware = 'Bios' }
}
if ($firmware -eq 'Unknown') {
    $bcd = & cmd /c 'bcdedit /enum {current} 2>&1'
    if ($bcd -match 'winload\.efi') { $firmware = 'Uefi' } elseif ($bcd -match 'winload\.exe') { $firmware = 'Bios' }
}

$adapters = @()
foreach ($nic in (Get-NetAdapter | Where-Object Status -eq 'Up')) {
    $ipcfg = Get-NetIPConfiguration -InterfaceIndex $nic.ifIndex

    $v4    = $ipcfg.IPv4Address | Select-Object -First 1
    $gw    = $ipcfg.IPv4DefaultGateway | Select-Object -First 1
    $dns   = ($ipcfg.DNSServer | Where-Object AddressFamily -eq 2).ServerAddresses
    $dhcp  = (Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).Dhcp

    $adapters += [pscustomobject]@{
        Name         = $nic.Name
        Description  = $nic.InterfaceDescription
        MacAddress   = $nic.MacAddress
        Dhcp         = $dhcp.ToString()          # 'Enabled' means DHCP client
        IPAddress    = $v4.IPAddress
        PrefixLength = $v4.PrefixLength
        Gateway      = $gw.NextHop
        DnsServers   = @($dns)
    }
}


# ---------------------------------------------------------------------------
# 2b. System state captures
#     Each block is isolated so a cmdlet missing on older OSes (2012 R2)
#     skips that section instead of killing the run.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$flags    = @()   # act on these BEFORE shutdown
$warnings = @()   # be aware, not blockers

function Capture ($name, [scriptblock]$block) {
    try   { & $block | Out-File "$dir\pre-$name.txt" -Width 300 }
    catch { "CAPTURE FAILED: $($_.Exception.Message)" | Out-File "$dir\pre-$name.txt"; $script:warnings += "Capture '$name' failed: $($_.Exception.Message)" }
}

Step 'system info'
# -- System / sizing / boot risks --
$os   = Get-CimInstance Win32_OperatingSystem
$cs   = Get-CimInstance Win32_ComputerSystem
$cpu  = @(Get-CimInstance Win32_Processor)
$sys  = [pscustomobject]@{
    OSName        = $os.Caption
    OSVersion     = $os.Version
    LastBoot      = $os.LastBootUpTime.ToString('s')
    UptimeDays    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    Cores         = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    RamGB         = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Manufacturer  = $cs.Manufacturer
    Model         = $cs.Model
    PartOfDomain  = $cs.PartOfDomain
}
Capture 'system' { $sys | Format-List }

$pendingReboot = $false
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pendingReboot = $true }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pendingReboot = $true }
if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue) { $pendingReboot = $true }
if ($pendingReboot) { $flags += 'PENDING REBOOT detected - reboot before the final shutdown so updates finish on ESXi, not on first Hyper-V boot' }

# -- Adapter / identity sanity --
if (-not $adapters) { $flags += 'No adapters in Up state were found - network baseline is EMPTY' }
if ($adapters.Count -gt 1) { $warnings += "Multi-homed: $($adapters.Count) active adapters - post-check compares only the first; review manually" }
if ($env:COMPUTERNAME -match '^WIN-[A-Z0-9]{11}$') { $warnings += 'Hostname is a default auto-generated name - consider renaming as part of the migration' }
if ($sys.UptimeDays -gt 180) { $warnings += "Uptime is $($sys.UptimeDays) days - a long-unrebooted box may have surprises on first boot; consider a test reboot on ESXi first" }

Step 'disks and volumes'
# -- Disks / volumes / partition style / drive letters --
Capture 'disks'   { Get-Disk | Select Number, FriendlyName, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, PartitionStyle, IsBoot, IsSystem, OperationalStatus | Format-Table -AutoSize }
Capture 'volumes' { Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort DriveLetter | Select DriveLetter, FileSystemLabel, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} | Format-Table -AutoSize }
$volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 -and $_.DriveType -eq 'Fixed' } | ForEach-Object { [pscustomobject]@{ Letter = "$($_.DriveLetter)"; Label = $_.FileSystemLabel; SizeGB = [math]::Round($_.Size/1GB,1) } })
$bootDisk = Get-Disk | Where-Object IsBoot
if ($bootDisk -and $bootDisk.PartitionStyle -eq 'GPT' -and $firmware -eq 'Bios') { $flags += 'Boot disk is GPT but firmware reports BIOS - double-check generation choice' }

# -- BitLocker (the first-boot recovery-prompt trap) --
$bitlocker = @()
try {
    $bitlocker = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object ProtectionStatus -eq 'On' | Select MountPoint, VolumeStatus, EncryptionPercentage)
    Capture 'bitlocker' { $bitlocker | Format-Table -AutoSize }
    if ($bitlocker) { $flags += "BITLOCKER ON for $(($bitlocker.MountPoint) -join ', ') - have recovery keys ready; expect a recovery prompt on first Hyper-V boot" }
} catch { 'BitLocker cmdlets not available (feature not installed) - almost certainly not encrypted' | Out-File "$dir\pre-bitlocker.txt" }

Step 'services and ports'
# -- Services: Automatic ones and whether they're running --
# Exclude per-user service instances (Name_<hex>) - they exist only while a session is logged in
$autoSvcs = @(Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Name -notmatch '_[0-9a-f]{5,8}$' } | Sort Name | Select Name, DisplayName, Status)
Capture 'services-auto' { $autoSvcs | Format-Table -AutoSize }
Capture 'services-all'  { Get-Service | Sort Name | Select Name, DisplayName, Status, StartType | Format-Table -AutoSize }
$autoNotRunning = @($autoSvcs | Where-Object Status -ne 'Running')
if ($autoNotRunning) { $warnings += "$($autoNotRunning.Count) Automatic service(s) NOT running pre-migration (normal for some, but note them so you don't chase them later): $(($autoNotRunning.Name) -join ', ')" }

# -- Listening ports --
$listen = @()
try {
    # Exclude the ephemeral range (49152+) - RPC picks new ones every boot
    $listen = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -lt 49152 | Sort LocalPort -Unique | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        [pscustomobject]@{ Port = $_.LocalPort; Process = $p.ProcessName }
    })
    Capture 'listening-ports' { $listen | Format-Table -AutoSize }
} catch { Capture 'listening-ports' { netstat -ano | Select-String LISTENING } }

Step 'roles and features (can take ~15s)'
# -- Roles / features --
Capture 'roles-features' { Get-WindowsFeature | Where-Object Installed | Select Name, DisplayName | Format-Table -AutoSize }
$roles = @()
try { $roles = @((Get-WindowsFeature | Where-Object { $_.Installed -and $_.FeatureType -eq 'Role' }).Name) } catch {}

Step 'shares, printers, tasks, software'
# -- Shares --
$shares = @()
try {
    $shares = @(Get-SmbShare | Where-Object { $_.Name -notmatch '^\w\$$|^ADMIN\$$|^IPC\$$' } | Select Name, Path)
    Capture 'shares' { $shares | Format-Table -AutoSize }
} catch { Capture 'shares' { net share } }

# -- Printers (only meaningful on print servers, cheap everywhere) --
$printers = @()
try {
    # Exclude RDP-redirected printers "(redirected N)" - they belong to someone's remote session, not this server
    $printers = @(Get-Printer | Where-Object Name -notmatch '\(redirected \d+\)$' | Select Name, DriverName, PortName, Shared, ShareName, PrinterStatus)
    Capture 'printers'      { $printers | Format-Table -AutoSize }
    Capture 'printer-ports' { Get-PrinterPort | Select Name, PrinterHostAddress, PortNumber | Format-Table -AutoSize }
} catch {}

# -- Scheduled tasks (non-Microsoft) --
try {
    Capture 'scheduled-tasks' { Get-ScheduledTask | Where-Object { $_.TaskPath -notmatch '^\\Microsoft' } | Select TaskPath, TaskName, State | Format-Table -AutoSize }
} catch { Capture 'scheduled-tasks' { schtasks /query /fo LIST } }

# -- Installed software (registry - fast, no WMI Win32_Product side effects) --
$sw = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') |
      ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
      Where-Object DisplayName | Sort DisplayName -Unique | Select DisplayName, DisplayVersion, Publisher
Capture 'software' { $sw | Format-Table -AutoSize }
$vmwareTools = $sw | Where-Object DisplayName -match 'VMware Tools'
if ($vmwareTools) { $flags += "VMware Tools $($vmwareTools.DisplayVersion) installed - uninstall it as the LAST step before shutdown" }

Step 'time, pagefile, hosts, firewall'
# -- Time, page file, hosts, firewall --
Capture 'time-source' { & cmd /c 'w32tm /query /source 2>&1'; & cmd /c 'w32tm /query /status 2>&1' }
Capture 'pagefile'    { Get-CimInstance Win32_PageFileSetting | Select Name, InitialSize, MaximumSize | Format-Table -AutoSize; Get-CimInstance Win32_PageFileUsage | Select Name, AllocatedBaseSize | Format-Table -AutoSize }
$pf = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -notmatch '^C:' }
if ($pf) { $warnings += "Page file is on $($pf.Name) - a drive letter shift after restore would break it" }
Capture 'hosts-file'  { Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() } }
$hostsCustom = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() }
if ($hostsCustom) { $warnings += "hosts file has $(@($hostsCustom).Count) custom entr(ies) - review pre-hosts-file.txt" }
Capture 'firewall'    { Get-NetFirewallProfile | Select Name, Enabled, DefaultInboundAction | Format-Table -AutoSize }

Step 'event log (last 7 days of errors)'
# -- Recent errors (baseline the normal noise) --
Capture 'eventlog-errors' { Get-WinEvent -FilterHashtable @{LogName='System','Application'; Level=1,2; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 200 -ErrorAction SilentlyContinue | Select TimeCreated, LogName, ProviderName, Id, @{n='Message';e={$_.Message -replace "`r?`n",' ' | % { $_.Substring(0,[math]::Min(150,$_.Length)) }}} | Format-Table -AutoSize }

$ErrorActionPreference = 'Stop'

$baseline = [pscustomobject]@{
    ComputerName    = $env:COMPUTERNAME
    Domain          = $env:USERDNSDOMAIN
    Firmware        = $firmware                     # Bios -> Gen1, Uefi -> Gen2
    CapturedAt      = (Get-Date).ToString('s')
    OS              = $sys.OSName
    Cores           = $sys.Cores
    RamGB           = $sys.RamGB
    PendingReboot   = $pendingReboot
    BitLockerOn     = @($bitlocker.MountPoint)
    Adapters        = $adapters
    Volumes         = $volumes
    Roles           = $roles
    AutoServices    = @($autoSvcs | Where-Object Status -eq 'Running' | ForEach-Object { $_.Name })
    ListeningPorts  = @($listen.Port)
    Shares          = @($shares.Name)
    Printers        = @($printers.Name)
}

$baseline | ConvertTo-Json -Depth 4 | Out-File "$dir\baseline.json" -Encoding UTF8

# ---------------------------------------------------------------------------
# 3. Summary - built once, shown on screen AND written to pre-summary.txt
# ---------------------------------------------------------------------------
$genHint = if ($firmware -eq 'Uefi') { 'restore as Generation 2' }
           elseif ($firmware -eq 'Bios') { 'restore as Generation 1' }
           else { 'UNKNOWN - check manually: bcdedit | findstr path  (winload.efi=Gen2, winload.exe=Gen1)' }
if ($firmware -eq 'Unknown') { $warnings += 'Could not determine firmware type - verify generation before restore' }

$summary = @()
$summary += "PRE-MIGRATION SUMMARY: $env:COMPUTERNAME"
$summary += "Captured      : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$summary += "Domain        : $(if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { '(not domain-joined)' })"
$summary += "OS            : $($sys.OSName) ($($sys.OSVersion))"
$summary += "Sizing        : $($sys.Cores) vCPU / $($sys.RamGB) GB RAM  - match this on the Hyper-V VM"
$summary += "Uptime        : $($sys.UptimeDays) days"
$summary += "Firmware type : $firmware  -> $genHint"
$summary += "Boot disk     : $($bootDisk.PartitionStyle) $([math]::Round($bootDisk.Size/1GB)) GB"
$summary += "Volumes       : $(($volumes | ForEach-Object { "$($_.Letter): $($_.SizeGB)GB" }) -join ', ')"
$summary += "Roles         : $(if ($roles) { $roles -join ', ' } else { '(none)' })"
$summary += "Auto services : $($autoSvcs.Count) total, $(@($autoSvcs | ? Status -eq 'Running').Count) running"
$summary += "Listening     : $($listen.Count) TCP ports"
$summary += "Shares        : $($shares.Count)   Printers: $($printers.Count)"
$summary += "BitLocker     : $(if ($bitlocker) { 'ON - ' + ($bitlocker.MountPoint -join ', ') } else { 'off' })"
$summary += "VMware Tools  : $(if ($vmwareTools) { 'installed (' + $vmwareTools.DisplayVersion + ')' } else { 'not installed' })"
$summary += ''
foreach ($a in $adapters) {
    $summary += "Adapter       : $($a.Name)  [$($a.MacAddress)]"
    $summary += "  DHCP        : $($a.Dhcp)"
    $summary += "  IPv4        : $($a.IPAddress)/$($a.PrefixLength)"
    $summary += "  Gateway     : $($a.Gateway)"
    $summary += "  DNS         : $($a.DnsServers -join ', ')"
}

# --- print to console ---
Write-Host ''
foreach ($line in $summary) {
    $color = if ($line -match '^Firmware') { 'Yellow' } else { 'White' }
    Write-Host $line -ForegroundColor $color
}

if ($flags) {
    Write-Host ''
    Write-Host '!! ATTENTION - act on these BEFORE shutdown !!' -ForegroundColor Red
    foreach ($f in $flags) { Write-Host "  - $f" -ForegroundColor Red }
}
if ($warnings) {
    Write-Host ''
    Write-Host 'WARNINGS - be aware of these' -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
}
if (-not $flags -and -not $warnings) {
    Write-Host ''
    Write-Host 'No attention items or warnings.' -ForegroundColor Green
}

# --- write summary file ---
$out = @()
$out += $summary
$out += ''
$out += '=== ATTENTION - act on these BEFORE shutdown ==='
$out += if ($flags)    { $flags    | ForEach-Object { "  - $_" } } else { '  (none)' }
$out += ''
$out += '=== WARNINGS ==='
$out += if ($warnings) { $warnings | ForEach-Object { "  - $_" } } else { '  (none)' }
$out += ''
$out += '=== FILES ==='
$out += Get-ChildItem $dir -Filter 'pre-*.txt' | ForEach-Object { "  $($_.Name)  ($($_.Length) bytes)" }
$out += "  baseline.json"
$out | Out-File "$dir\pre-summary.txt" -Encoding UTF8

Write-Host ''
Write-Host "Summary written to $dir\pre-summary.txt" -ForegroundColor Green
Write-Host "Baseline written to $dir\baseline.json" -ForegroundColor Green
Write-Host 'Next steps: address ATTENTION items, uninstall VMware Tools, clean shutdown, final Veeam incremental.' -ForegroundColor Green
