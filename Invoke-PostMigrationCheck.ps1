<#
.SYNOPSIS
    Post-migration alignment check for ESXi -> Hyper-V cutover. READ-ONLY.
    Run INSIDE the guest VM after it boots on Hyper-V (via VMConnect console).

.DESCRIPTION
    Compares the live machine against C:\migration\baseline.json (written by
    Invoke-PreMigration.ps1) and reports PASS / WARN / FAIL per check, with a
    suggested 'fix:' command for anything that failed. Makes NO changes.

    Checks: platform + generation + sizing, ghost VMware adapters, IP config
    vs baseline, reachability, DNS record, domain trust, volumes/drive letters,
    auto-start services that were running before, listening ports, shares,
    printers, Hyper-V integration services, VMware leftovers.

    Run once with the vSwitch disconnected (network checks will be skipped),
    apply the fixes you agree with, connect the vSwitch, run again.

    Writes C:\migration\post-summary.txt (and post-ipconfig-<timestamp>.txt).

.NOTES
    Run as administrator. Works on PS 4.0 (2012 R2) and up.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'
$dir  = 'C:\migration'
$json = "$dir\baseline.json"

# ---------------------------------------------------------------------------
# helpers - every result is recorded so the summary file matches the screen
# ---------------------------------------------------------------------------
$script:results = @()
function Rec ($lvl, $msg) {
    $script:results += [pscustomobject]@{ Level = $lvl; Msg = $msg }
    $color = switch ($lvl) { 'PASS' {'Green'} 'WARN' {'Yellow'} 'FAIL' {'Red'} 'INFO' {'Gray'} 'FIX' {'Magenta'} }
    $tag   = if ($lvl -eq 'FIX') { '       fix:' } else { "  [$lvl]" }
    Write-Host "$tag $msg" -ForegroundColor $color
}
function Pass ($m) { Rec 'PASS' $m }
function Warn ($m) { Rec 'WARN' $m }
function Fail ($m) { Rec 'FAIL' $m }
function Info ($m) { Rec 'INFO' $m }
function Fix  ($m) { Rec 'FIX'  $m }
function Section ($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan; $script:results += [pscustomobject]@{ Level='SECTION'; Msg=$t } }

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
Write-Host "== Post-migration check: $env:COMPUTERNAME  ($stamp) ==" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 0. Baseline
# ---------------------------------------------------------------------------
Section 'Baseline'
$b = $null
if (-not (Test-Path $json)) {
    Fail "No baseline at $json - was Invoke-PreMigration.ps1 run before shutdown? Alignment checks will be skipped."
} else {
    $b = Get-Content $json -Raw | ConvertFrom-Json
    Pass "Baseline from $($b.CapturedAt) for $($b.ComputerName)"
    if ($b.ComputerName -ne $env:COMPUTERNAME) { Fail "Baseline hostname ($($b.ComputerName)) != this machine ($env:COMPUTERNAME)" }
}
$domainJoined = [bool]$env:USERDNSDOMAIN

# ---------------------------------------------------------------------------
# 1. Platform / generation / sizing
# ---------------------------------------------------------------------------
Section 'Platform'
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
if ($cs.Manufacturer -match 'Microsoft' -and $cs.Model -match 'Virtual') { Pass "Running on Hyper-V ($($cs.Model))" }
else { Warn "Manufacturer/Model = '$($cs.Manufacturer) / $($cs.Model)' - does not look like Hyper-V" }

$fw = 'Unknown'
switch ("$env:firmware_type") { 'UEFI' { $fw = 'Uefi' } 'Legacy' { $fw = 'Bios' } }   # avoid Get-ComputerInfo - very slow on 2016+
if ($fw -eq 'Unknown') {
    $bcd = & cmd /c 'bcdedit /enum {current} 2>&1'
    if ($bcd -match 'winload\.efi') { $fw = 'Uefi' } elseif ($bcd -match 'winload\.exe') { $fw = 'Bios' }
}
if ($b -and $b.Firmware -ne 'Unknown') {
    if ($fw -eq $b.Firmware) { Pass "Firmware $fw matches baseline (Gen $(if ($fw -eq 'Uefi') {2} else {1}))" }
    else { Fail "Firmware is $fw but baseline was $($b.Firmware) - VM generation is probably wrong" }
} else { Info "Firmware type: $fw" }

$cores = (@(Get-CimInstance Win32_Processor) | Measure-Object NumberOfLogicalProcessors -Sum).Sum
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
if ($b) {
    if ($cores -eq $b.Cores) { Pass "$cores vCPU matches baseline" } else { Warn "vCPU: live=$cores baseline=$($b.Cores) - adjust in Hyper-V VM settings (VM must be off)" }
    if ([math]::Abs($ramGB - $b.RamGB) -lt 0.5) { Pass "$ramGB GB RAM matches baseline" } else { Warn "RAM: live=$ramGB GB baseline=$($b.RamGB) GB - adjust in Hyper-V VM settings" }
} else { Info "$cores vCPU / $ramGB GB RAM" }

$uptimeMin = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes)
Info "Booted $uptimeMin minutes ago"

# ---------------------------------------------------------------------------
# 2. Ghost VMware adapters
# ---------------------------------------------------------------------------
Section 'Ghost adapters'
if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    $ghosts = @(Get-PnpDevice -Class Net | Where-Object Status -eq 'Unknown')
    if ($ghosts) {
        foreach ($g in $ghosts) { Fail "Ghost adapter present: $($g.FriendlyName)"; Fix "pnputil /remove-device `"$($g.InstanceId)`"" }
        Info 'Or all at once:'
        Fix 'Get-PnpDevice -Class Net | ? Status -eq "Unknown" | % { pnputil /remove-device $_.InstanceId }'
    } else { Pass 'No ghost (nonpresent) network adapters' }
} else {
    # 2012 R2 fallback: the network class registry keeps entries for nonpresent NICs
    $netClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $vmNics = @(Get-ChildItem $netClass -ErrorAction SilentlyContinue | ForEach-Object {
        $d = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc
        if ($d -match 'vmxnet|VMware') { $d }
    })
    $liveDescs = @((Get-NetAdapter).InterfaceDescription)
    $ghostDescs = @($vmNics | Where-Object { $liveDescs -notcontains $_ })
    if ($ghostDescs) {
        foreach ($g in $ghostDescs) { Fail "Ghost adapter likely present: $g" }
        Info 'Get-PnpDevice unavailable on this OS - remove via Device Manager:'
        Fix '$env:DEVMGR_SHOW_NONPRESENT_DEVICES=1; devmgmt.msc   (View > Show hidden devices > Network adapters > uninstall greyed VMware NIC)'
    } else { Pass 'No VMware adapter entries found in the network class registry' }
}

# ---------------------------------------------------------------------------
# 3. Network config vs baseline
# ---------------------------------------------------------------------------
Section 'Network configuration'
$live = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' })
if (-not $live) { Fail 'No network adapters in Up or Disconnected state' }
$base = if ($b) { $b.Adapters | Select-Object -First 1 } else { $null }
if ($b -and @($b.Adapters).Count -gt 1) { Warn "Baseline had $(@($b.Adapters).Count) adapters - comparing against the first ($($base.Name)); review others manually" }

foreach ($nic in $live) {
    $ipcfg = Get-NetIPConfiguration -InterfaceIndex $nic.ifIndex
    $v4    = $ipcfg.IPv4Address | Select-Object -First 1
    $gw    = $ipcfg.IPv4DefaultGateway | Select-Object -First 1
    $dns   = @(($ipcfg.DNSServer | Where-Object AddressFamily -eq 2).ServerAddresses)
    $dhcp  = (Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).Dhcp
    $reg   = (Get-DnsClient -InterfaceIndex $nic.ifIndex).RegisterThisConnectionsAddress

    Info "Adapter '$($nic.Name)' [$($nic.MacAddress)] status=$($nic.Status) dhcp=$dhcp"
    Info "  IPv4=$($v4.IPAddress)/$($v4.PrefixLength) gw=$($gw.NextHop) dns=$($dns -join ',')"
    if ($nic.InterfaceDescription -notmatch 'Hyper-V') { Warn "  Not a Hyper-V synthetic NIC: $($nic.InterfaceDescription)" }
    if (-not $base) { continue }

    if ($base.Dhcp -eq 'Enabled') {
        if ($dhcp -eq 'Enabled') { Pass '  Baseline was DHCP, live is DHCP - nothing to reapply' } else { Warn '  Baseline was DHCP but live is static' }
        continue
    }
    if ($dhcp -eq 'Enabled') { Fail '  Adapter is on DHCP but baseline was STATIC (the DNS-scavenging trap)' }

    if ($v4.IPAddress -eq $base.IPAddress -and $v4.PrefixLength -eq $base.PrefixLength) { Pass "  IP $($base.IPAddress)/$($base.PrefixLength) matches baseline" }
    else {
        Fail "  IP: live=$($v4.IPAddress)/$($v4.PrefixLength) baseline=$($base.IPAddress)/$($base.PrefixLength)"
        Fix  "New-NetIPAddress -InterfaceIndex $($nic.ifIndex) -IPAddress $($base.IPAddress) -PrefixLength $($base.PrefixLength) -DefaultGateway $($base.Gateway)"
    }
    if ($gw.NextHop -eq $base.Gateway) { Pass "  Gateway $($base.Gateway) matches baseline" }
    elseif ($v4.IPAddress -ne $base.IPAddress) { Info '  (gateway is set by the New-NetIPAddress fix above)' }
    else { Fail "  Gateway: live=$($gw.NextHop) baseline=$($base.Gateway)"; Fix "Remove-NetRoute -InterfaceIndex $($nic.ifIndex) -DestinationPrefix 0.0.0.0/0 -Confirm:`$false; New-NetRoute -InterfaceIndex $($nic.ifIndex) -DestinationPrefix 0.0.0.0/0 -NextHop $($base.Gateway)" }

    $bdns = @($base.DnsServers)
    if (($dns -join ',') -eq ($bdns -join ',')) { Pass "  DNS servers match baseline ($($bdns -join ', '))" }
    else { Fail "  DNS servers: live=$($dns -join ',') baseline=$($bdns -join ',')"; Fix "Set-DnsClientServerAddress -InterfaceIndex $($nic.ifIndex) -ServerAddresses $($bdns -join ',')" }

    if ($domainJoined) {
        if ($reg) { Pass '  DNS registration enabled on adapter' }
        else { Fail '  DNS registration DISABLED on adapter'; Fix "Set-DnsClient -InterfaceIndex $($nic.ifIndex) -RegisterThisConnectionsAddress `$true" }
    }
    if ($nic.MacAddress -ne $base.MacAddress) { Info "  MAC changed $($base.MacAddress) -> $($nic.MacAddress) (only matters for MAC-based reservations/licensing)" }
}

# ---------------------------------------------------------------------------
# 4. Reachability
# ---------------------------------------------------------------------------
Section 'Reachability'
$anyUp = @(Get-NetAdapter | Where-Object Status -eq 'Up').Count -gt 0
if (-not $anyUp) {
    Warn 'No adapter is Up - vSwitch probably still disconnected. Connect it and rerun; network/DNS/domain/port checks skipped this pass.'
} else {
    $defRoute = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($defRoute) {
        if (Test-Connection $defRoute.NextHop -Count 2 -Quiet) { Pass "Gateway $($defRoute.NextHop) responds to ping" }
        else { Warn "Gateway $($defRoute.NextHop) no ping reply (ICMP may be filtered; also check VLAN on the vSwitch port)" }
    } else { Fail 'No default route' }
    $dnsSrv = @((Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses).ServerAddresses | Select-Object -First 1)
    if ($dnsSrv) {
        if (Test-NetConnection $dnsSrv[0] -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue) { Pass "DNS server $($dnsSrv[0]) reachable on 53" }
        else { Fail "DNS server $($dnsSrv[0]) NOT reachable on 53" }
    }
    if ($domainJoined) {
        $dc = Resolve-DnsName $env:USERDNSDOMAIN -Type A -ErrorAction SilentlyContinue
        if ($dc) { Pass "Domain $env:USERDNSDOMAIN resolves" } else { Fail "Cannot resolve domain $env:USERDNSDOMAIN" }
    }
}

# ---------------------------------------------------------------------------
# 5. DNS record + domain trust (domain-joined only)
# ---------------------------------------------------------------------------
Section 'DNS record / domain trust'
if (-not $domainJoined) { Info 'Not domain-joined - clients reach this box by IP; no DNS record or trust to verify' }
elseif (-not $anyUp) { Warn 'Skipped - no network' }
else {
    $myIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
    $fqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
    $rec  = @(Resolve-DnsName $fqdn -Type A -ErrorAction SilentlyContinue | Where-Object Type -eq 'A')
    if (-not $rec) { Fail "No A record for $fqdn - this is what breaks UNC-by-name"; Fix 'ipconfig /registerdns   (wait ~15s, rerun this check)' }
    elseif ($rec.IPAddress -contains $myIp) {
        Pass "A record $fqdn -> $myIp is correct"
        if ($rec.Count -gt 1) { Warn "Multiple A records: $($rec.IPAddress -join ', ') - stale DHCP-era record? delete the wrong one in the DNS console" }
    } else { Fail "A record $fqdn -> $($rec.IPAddress -join ', ') but this machine is $myIp (stale)"; Fix 'ipconfig /registerdns   (delete the stale record in DNS if it lingers)' }

    $sc = & cmd /c "nltest /sc_verify:$env:USERDNSDOMAIN 2>&1"
    if ($sc -match 'Trust Verification Status = 0') { Pass "Secure channel to $env:USERDNSDOMAIN verified" }
    else { Fail "Secure channel check failed: $(($sc | Select-Object -Last 2) -join ' | ')"; Fix 'Test-ComputerSecureChannel -Repair   (only after network is confirmed good)' }
}

# ---------------------------------------------------------------------------
# 6. Volumes / drive letters
# ---------------------------------------------------------------------------
Section 'Volumes'
$vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 -and $_.DriveType -eq 'Fixed' } | ForEach-Object { [pscustomobject]@{ Letter="$($_.DriveLetter)"; Label=$_.FileSystemLabel; SizeGB=[math]::Round($_.Size/1GB,1) } })
Info "Live: $(($vols | ForEach-Object { "$($_.Letter): $($_.SizeGB)GB" }) -join ', ')"
if ($b -and $b.Volumes) {
    foreach ($bv in $b.Volumes) {
        $lv = $vols | Where-Object Letter -eq $bv.Letter
        if (-not $lv) { Fail "Volume $($bv.Letter): ($($bv.SizeGB)GB, '$($bv.Label)') is MISSING - check Disk Management for an offline disk or shifted letter"; Fix 'diskmgmt.msc   (bring disk online / change drive letter to match baseline)' }
        elseif ([math]::Abs($lv.SizeGB - $bv.SizeGB) -gt 1) { Warn "Volume $($bv.Letter): size changed $($bv.SizeGB)GB -> $($lv.SizeGB)GB" }
        else { Pass "Volume $($bv.Letter): present, $($lv.SizeGB)GB" }
    }
    $extra = $vols | Where-Object { @($b.Volumes.Letter) -notcontains $_.Letter }
    foreach ($e in $extra) { Warn "New volume $($e.Letter): ($($e.SizeGB)GB) not in baseline" }
}
$offline = @(Get-Disk | Where-Object OperationalStatus -ne 'Online')
foreach ($d in $offline) { Fail "Disk $($d.Number) ($([math]::Round($d.Size/1GB))GB) is $($d.OperationalStatus)"; Fix "Set-Disk -Number $($d.Number) -IsOffline `$false" }

# ---------------------------------------------------------------------------
# 7. Services that were running before
# ---------------------------------------------------------------------------
Section 'Services'
if ($b -and $b.AutoServices) {
    $notRunning = @()
    foreach ($svcName in $b.AutoServices) {
        if ($svcName -match '^VM|VGAuth') { continue }   # VMware services are expected to be gone
        $s = Get-Service $svcName -ErrorAction SilentlyContinue
        if (-not $s) { Warn "Service '$svcName' was running before and is now NOT INSTALLED" }
        elseif ($s.Status -ne 'Running') { $notRunning += $s }
    }
    if ($notRunning) {
        foreach ($s in $notRunning) { Fail "Service '$($s.Name)' ($($s.DisplayName)) was running before, now $($s.Status)"; Fix "Start-Service $($s.Name)" }
        Info 'Some services start delayed - if the box booted <5 min ago, wait and rerun before acting'
    } else { Pass "All $($b.AutoServices.Count) auto-start services that were running before are running now" }
} else { Info 'No service baseline' }

# ---------------------------------------------------------------------------
# 8. Listening ports
# ---------------------------------------------------------------------------
Section 'Listening ports'
if ($b -and $b.ListeningPorts) {
    if (-not $anyUp) { Warn 'Skipped - no network' }
    else {
        $livePorts = @((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue).LocalPort | Sort-Object -Unique)
        $missing = @($b.ListeningPorts | Where-Object { $livePorts -notcontains $_ })
        if ($missing) { Warn "Ports listening before but not now: $($missing -join ', ') - map to a service via netstat -ano" }
        else { Pass "All $($b.ListeningPorts.Count) previously listening TCP ports are listening" }
    }
} else { Info 'No port baseline' }

# ---------------------------------------------------------------------------
# 9. Shares / printers
# ---------------------------------------------------------------------------
Section 'Shares and printers'
if ($b -and $b.Shares) {
    $liveShares = @((Get-SmbShare -ErrorAction SilentlyContinue).Name)
    $missing = @($b.Shares | Where-Object { $liveShares -notcontains $_ })
    if ($missing) { Fail "Shares missing: $($missing -join ', ')" } else { Pass "All $($b.Shares.Count) shares present" }
} else { Info 'No shares in baseline' }

if ($b -and $b.Printers) {
    $livePrinters = @(Get-Printer -ErrorAction SilentlyContinue)
    $missing = @($b.Printers | Where-Object { $livePrinters.Name -notcontains $_ })
    if ($missing) { Fail "Printers missing: $($missing -join ', ')" } else { Pass "All $($b.Printers.Count) printers present" }
    $bad = @($livePrinters | Where-Object { @('Normal','Idle','Printing') -notcontains "$($_.PrinterStatus)" })
    foreach ($p in $bad) { Warn "Printer '$($p.Name)' status: $($p.PrinterStatus)" }
    $spooler = Get-Service Spooler
    if ($spooler.Status -ne 'Running') { Fail 'Print Spooler is not running'; Fix 'Start-Service Spooler' }
} else { Info 'No printers in baseline' }

# ---------------------------------------------------------------------------
# 10. Hyper-V integration + VMware leftovers
# ---------------------------------------------------------------------------
Section 'Integration services / VMware leftovers'
$ic = @(Get-Service vmic* -ErrorAction SilentlyContinue)
if ($ic) {
    $icDown = @($ic | Where-Object { $_.StartType -ne 'Disabled' -and $_.Status -ne 'Running' })
    if ($icDown) { foreach ($s in $icDown) { Warn "Hyper-V integration service $($s.Name) is $($s.Status)" } }
    else { Pass "Hyper-V integration services present ($($ic.Count))" }
} else { Warn 'No Hyper-V integration services (vmic*) found - old OS may need Integration Services installed from the host' }

$vmSvcs = @(Get-Service | Where-Object { $_.Name -match '^VM|VGAuth' -and $_.DisplayName -match 'VMware' })
if ($vmSvcs) { foreach ($s in $vmSvcs) { Warn "VMware service still installed: $($s.DisplayName) [$($s.Status)]" }; Info 'Uninstall VMware Tools via Programs and Features; if it refuses, sc delete <name>' }
else { Pass 'No VMware Tools services present' }
$vmSw = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') |
    ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } | Where-Object DisplayName -match 'VMware Tools'
if ($vmSw) { Warn "VMware Tools $($vmSw.DisplayVersion) still listed in installed programs" }

# ---------------------------------------------------------------------------
# Summary + files
# ---------------------------------------------------------------------------
$fails = @($script:results | Where-Object Level -eq 'FAIL')
$warns = @($script:results | Where-Object Level -eq 'WARN')
$passes = @($script:results | Where-Object Level -eq 'PASS')
Write-Host ''
if ($fails.Count -eq 0 -and $warns.Count -eq 0) { Write-Host '== ALIGNED - no failures or warnings ==' -ForegroundColor Green }
elseif ($fails.Count -eq 0) { Write-Host "== No failures, $($warns.Count) warning(s) - review above ==" -ForegroundColor Yellow }
else { Write-Host "== $($fails.Count) FAILURE(S), $($warns.Count) warning(s) - review the 'fix:' lines ==" -ForegroundColor Red }

$out = @()
$out += "POST-MIGRATION CHECK: $env:COMPUTERNAME"
$out += "Run at        : $stamp"
$out += "Result        : $($fails.Count) fail / $($warns.Count) warn / $($passes.Count) pass"
$out += "Network up    : $anyUp"
$out += ''
$out += '=== FAILURES ==='
$out += if ($fails) { $fails | ForEach-Object { "  - $($_.Msg)" } } else { '  (none)' }
$out += ''
$out += '=== WARNINGS ==='
$out += if ($warns) { $warns | ForEach-Object { "  - $($_.Msg)" } } else { '  (none)' }
$out += ''
$out += '=== SUGGESTED FIXES (not applied) ==='
$fixes = @($script:results | Where-Object Level -eq 'FIX')
$out += if ($fixes) { $fixes | ForEach-Object { "  $($_.Msg)" } } else { '  (none)' }
$out += ''
$out += '=== FULL LOG ==='
foreach ($r in $script:results) {
    if ($r.Level -eq 'SECTION') { $out += ''; $out += "-- $($r.Msg) --" }
    elseif ($r.Level -eq 'FIX') { $out += "       fix: $($r.Msg)" }
    else { $out += "  [$($r.Level)] $($r.Msg)" }
}
$out | Out-File "$dir\post-summary.txt" -Encoding UTF8
ipconfig /all | Out-File "$dir\post-ipconfig-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
Write-Host "Summary written to $dir\post-summary.txt" -ForegroundColor Green
