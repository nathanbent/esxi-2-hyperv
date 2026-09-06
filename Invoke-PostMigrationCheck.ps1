<#
.SYNOPSIS
    Post-migration alignment check for ESXi -> Hyper-V cutover. READ-ONLY.
    Run INSIDE the guest VM after it boots on Hyper-V (via VMConnect console).

.DESCRIPTION
    Compares the live machine state against C:\migration\baseline.json
    (written by Invoke-PreMigration.ps1) and reports:
      - ghost VMware adapters still present
      - whether the new adapter's IP / gateway / DNS match the baseline
      - whether the network is reachable (gateway, domain)
      - whether the machine's DNS A record exists and points at the right IP
      - domain secure channel health
      - leftover VMware Tools services

    It makes NO changes. Where something is off, it prints the command
    that would fix it so you can review and run it yourself.

    Safe to run repeatedly - run once with the NIC disconnected (expect
    network checks to fail), fix the IP, connect the vSwitch, run again.

.NOTES
    Run as administrator.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'
$dir  = 'C:\migration'
$json = "$dir\baseline.json"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
$script:issues = 0
function Pass ($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Warn ($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Fail ($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:issues++ }
function Info ($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Gray }
function Fix  ($cmd) { Write-Host "         fix: $cmd" -ForegroundColor Magenta }
function Section ($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

Write-Host "== Post-migration check: $env:COMPUTERNAME  ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ==" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 0. Baseline
# ---------------------------------------------------------------------------
Section 'Baseline'
if (-not (Test-Path $json)) {
    Fail "No baseline found at $json - was Invoke-PreMigration.ps1 run before shutdown?"
    Info 'Continuing with live-state checks only; alignment comparisons will be skipped.'
    $baseline = $null
} else {
    $baseline = Get-Content $json -Raw | ConvertFrom-Json
    Pass "Baseline captured $($baseline.CapturedAt) for $($baseline.ComputerName)"
    if ($baseline.ComputerName -ne $env:COMPUTERNAME) {
        Fail "Baseline hostname ($($baseline.ComputerName)) does not match this machine ($env:COMPUTERNAME)!"
    }
}

# ---------------------------------------------------------------------------
# 1. Hypervisor sanity - are we actually on Hyper-V, right generation?
# ---------------------------------------------------------------------------
Section 'Platform'
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.Manufacturer -match 'Microsoft' -and $cs.Model -match 'Virtual') {
    Pass "Running on Hyper-V ($($cs.Model))"
} else {
    Warn "Manufacturer/Model = '$($cs.Manufacturer) / $($cs.Model)' - does not look like Hyper-V"
}

$fw = 'Unknown'
try { $fw = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType.ToString() } catch {}
if ($baseline -and $baseline.Firmware -ne 'Unknown') {
    if ($fw -eq $baseline.Firmware) { Pass "Firmware type $fw matches baseline" }
    else { Fail "Firmware is $fw but baseline was $($baseline.Firmware) - VM generation may be wrong" }
} else {
    Info "Firmware type: $fw"
}

# ---------------------------------------------------------------------------
# 2. Ghost VMware adapters
# ---------------------------------------------------------------------------
Section 'Ghost adapters'
$ghosts = Get-PnpDevice -Class Net | Where-Object Status -eq 'Unknown'
if ($ghosts) {
    foreach ($g in $ghosts) {
        Fail "Ghost adapter present: $($g.FriendlyName)"
        Fix  "pnputil /remove-device `"$($g.InstanceId)`""
    }
    Info 'Or remove all at once:'
    Fix  'Get-PnpDevice -Class Net | ? Status -eq "Unknown" | % { pnputil /remove-device $_.InstanceId }'
} else {
    Pass 'No ghost (nonpresent) network adapters'
}

$vmwareDrivers = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'vmxnet|VMware' -and $_.Status -eq 'OK' }
if ($vmwareDrivers) {
    foreach ($d in $vmwareDrivers) { Warn "Active VMware device still present: $($d.FriendlyName)" }
}

# ---------------------------------------------------------------------------
# 3. Live adapter config vs baseline
# ---------------------------------------------------------------------------
Section 'Network configuration'
$live = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' }
if (-not $live) { Fail 'No network adapters found in Up or Disconnected state' }

foreach ($nic in $live) {
    $ipcfg = Get-NetIPConfiguration -InterfaceIndex $nic.ifIndex
    $v4    = $ipcfg.IPv4Address | Select-Object -First 1
    $gw    = $ipcfg.IPv4DefaultGateway | Select-Object -First 1
    $dns   = ($ipcfg.DNSServer | Where-Object AddressFamily -eq 2).ServerAddresses
    $dhcp  = (Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).Dhcp
    $reg   = (Get-DnsClient -InterfaceIndex $nic.ifIndex).RegisterThisConnectionsAddress

    Info "Adapter '$($nic.Name)' [$($nic.MacAddress)] status=$($nic.Status) dhcp=$dhcp"
    Info "  IPv4=$($v4.IPAddress)/$($v4.PrefixLength) gw=$($gw.NextHop) dns=$($dns -join ',')"

    if ($nic.InterfaceDescription -notmatch 'Hyper-V') {
        Warn "  Adapter is not a Hyper-V synthetic NIC ($($nic.InterfaceDescription))"
    }

    if (-not $baseline) { continue }

    # Match against baseline adapter. Single-NIC VMs: just use the first.
    $base = $baseline.Adapters | Select-Object -First 1
    if ($baseline.Adapters.Count -gt 1) {
        Warn "  Baseline had $($baseline.Adapters.Count) adapters - comparing against the first ($($base.Name)); review manually"
    }

    if ($base.Dhcp -eq 'Enabled') {
        if ($dhcp -eq 'Enabled') { Pass '  Baseline was DHCP and live is DHCP - nothing to reapply' }
        else { Warn '  Baseline was DHCP but live is static' }
        continue
    }

    # Baseline was static: compare each field
    if ($dhcp -eq 'Enabled') {
        Fail '  Adapter is on DHCP but baseline was STATIC - this is the DNS-scavenging trap'
    }

    if ($v4.IPAddress -eq $base.IPAddress -and $v4.PrefixLength -eq $base.PrefixLength) {
        Pass "  IP $($base.IPAddress)/$($base.PrefixLength) matches baseline"
    } else {
        Fail "  IP mismatch: live=$($v4.IPAddress)/$($v4.PrefixLength) baseline=$($base.IPAddress)/$($base.PrefixLength)"
        Fix  "New-NetIPAddress -InterfaceIndex $($nic.ifIndex) -IPAddress $($base.IPAddress) -PrefixLength $($base.PrefixLength) -DefaultGateway $($base.Gateway)"
    }

    if ($gw.NextHop -eq $base.Gateway) {
        Pass "  Gateway $($base.Gateway) matches baseline"
    } elseif ($v4.IPAddress -ne $base.IPAddress) {
        Info '  (gateway will be set by the New-NetIPAddress fix above)'
    } else {
        Fail "  Gateway mismatch: live=$($gw.NextHop) baseline=$($base.Gateway)"
        Fix  "Remove-NetRoute -InterfaceIndex $($nic.ifIndex) -DestinationPrefix 0.0.0.0/0 -Confirm:`$false; New-NetRoute -InterfaceIndex $($nic.ifIndex) -DestinationPrefix 0.0.0.0/0 -NextHop $($base.Gateway)"
    }

    $baseDns = @($base.DnsServers)
    if ((@($dns) -join ',') -eq ($baseDns -join ',')) {
        Pass "  DNS servers match baseline ($($baseDns -join ', '))"
    } else {
        Fail "  DNS mismatch: live=$(@($dns) -join ',') baseline=$($baseDns -join ',')"
        Fix  "Set-DnsClientServerAddress -InterfaceIndex $($nic.ifIndex) -ServerAddresses $($baseDns -join ',')"
    }

    if ($reg) { Pass '  "Register this connection in DNS" is enabled' }
    else {
        Fail '  DNS registration is DISABLED on this adapter'
        Fix  "Set-DnsClient -InterfaceIndex $($nic.ifIndex) -RegisterThisConnectionsAddress `$true"
    }

    if ($nic.MacAddress -ne $base.MacAddress) {
        Info "  MAC changed ($($base.MacAddress) -> $($nic.MacAddress)) - only matters for MAC-based reservations/licensing"
    }
}

# ---------------------------------------------------------------------------
# 4. Reachability (expected to FAIL if vSwitch is still disconnected)
# ---------------------------------------------------------------------------
Section 'Reachability'
$anyUp = Get-NetAdapter | Where-Object Status -eq 'Up'
if (-not $anyUp) {
    Warn 'No adapter is Up - vSwitch probably still disconnected. Connect it and rerun for the checks below.'
} else {
    $gwTest = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gwTest) {
        if (Test-Connection $gwTest.NextHop -Count 2 -Quiet) { Pass "Gateway $($gwTest.NextHop) responds to ping" }
        else { Warn "Gateway $($gwTest.NextHop) did not respond to ping (may be ICMP-filtered; check VLAN on vSwitch port)" }
    } else { Fail 'No default route present' }

    if ($env:USERDNSDOMAIN) {
        $dc = Resolve-DnsName $env:USERDNSDOMAIN -ErrorAction SilentlyContinue
        if ($dc) { Pass "Domain $env:USERDNSDOMAIN resolves ($(($dc | ? Type -eq 'A' | Select -First 1).IPAddress))" }
        else { Fail "Cannot resolve domain $env:USERDNSDOMAIN - DNS servers unreachable or wrong" }
    }
}

# ---------------------------------------------------------------------------
# 5. My DNS record
# ---------------------------------------------------------------------------
Section 'DNS registration'
if ($anyUp) {
    $myIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
    $fqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
    $rec  = Resolve-DnsName $fqdn -Type A -ErrorAction SilentlyContinue | Where-Object Type -eq 'A'
    if (-not $rec) {
        Fail "No A record for $fqdn - this is what breaks UNC-by-name"
        Fix  'ipconfig /registerdns      (then wait ~15s and rerun this check)'
    } elseif ($rec.IPAddress -contains $myIp) {
        Pass "A record $fqdn -> $myIp is correct"
        if ($rec.Count -gt 1) { Warn "Multiple A records exist: $($rec.IPAddress -join ', ') - stale DHCP-era record? clean up in DNS console" }
    } else {
        Fail "A record $fqdn -> $($rec.IPAddress -join ', ') but this machine is $myIp (stale record)"
        Fix  'ipconfig /registerdns      (then verify old record is gone; delete manually in DNS if it lingers)'
    }
} else { Warn 'Skipped - no network' }

# ---------------------------------------------------------------------------
# 6. Domain secure channel
# ---------------------------------------------------------------------------
Section 'Domain trust'
if ($anyUp -and $env:USERDNSDOMAIN) {
    $sc = nltest /sc_verify:$env:USERDNSDOMAIN 2>&1
    if ($sc -match 'Trust Verification Status = 0') { Pass "Secure channel to $env:USERDNSDOMAIN verified" }
    else { Fail "Secure channel check failed: $($sc -join ' | ')"; Fix 'Test-ComputerSecureChannel -Repair   (only if network is confirmed good first)' }
} elseif (-not $env:USERDNSDOMAIN) { Info 'Not domain-joined' }
else { Warn 'Skipped - no network' }

# ---------------------------------------------------------------------------
# 7. VMware leftovers
# ---------------------------------------------------------------------------
Section 'VMware leftovers'
$svcs = Get-Service | Where-Object { $_.Name -match '^VM|VGAuth' -and $_.DisplayName -match 'VMware' }
if ($svcs) {
    foreach ($s in $svcs) { Warn "Service still installed: $($s.DisplayName) [$($s.Status)]" }
    Info 'Uninstall VMware Tools from Programs and Features; if the uninstaller refuses, remove with sc delete <name>'
} else { Pass 'No VMware Tools services present' }

# ---------------------------------------------------------------------------
# Summary + save
# ---------------------------------------------------------------------------
Write-Host ''
if ($script:issues -eq 0) { Write-Host "== $script:issues issues - looks aligned ==" -ForegroundColor Green }
else { Write-Host "== $script:issues issue(s) flagged above - review the 'fix:' lines ==" -ForegroundColor Red }

# Keep a copy of the raw post state alongside the pre-migration captures
if (Test-Path $dir) {
    ipconfig /all | Out-File "$dir\post-ipconfig-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
}
