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

# ---------------------------------------------------------------------------
# 1. Raw human-readable captures (belt and suspenders)
# ---------------------------------------------------------------------------
ipconfig /all               | Out-File "$dir\pre-ipconfig.txt"
route print                 | Out-File "$dir\pre-routes.txt"
nslookup $env:COMPUTERNAME 2>&1 | Out-File "$dir\pre-dns-record.txt"
nltest /sc_verify:$env:USERDNSDOMAIN 2>&1 | Out-File "$dir\pre-securechannel.txt"

# ---------------------------------------------------------------------------
# 2. Structured baseline for the post-migration script
# ---------------------------------------------------------------------------
$firmware = 'Unknown'
try { $firmware = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType.ToString() } catch {}

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

if (-not $adapters) {
    Write-Warning 'No adapters in Up state were found - baseline will be empty!'
}

$baseline = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    Domain       = $env:USERDNSDOMAIN
    Firmware     = $firmware                     # Bios -> Gen1, Uefi -> Gen2
    CapturedAt   = (Get-Date).ToString('s')
    Adapters     = $adapters
}

$baseline | ConvertTo-Json -Depth 4 | Out-File "$dir\baseline.json" -Encoding UTF8

# ---------------------------------------------------------------------------
# 3. Summary to screen
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Firmware type : $firmware  ($(if ($firmware -eq 'Uefi') {'restore as Generation 2'} elseif ($firmware -eq 'Bios') {'restore as Generation 1'} else {'check manually!'}))" -ForegroundColor Yellow

foreach ($a in $adapters) {
    Write-Host ''
    Write-Host "Adapter       : $($a.Name)  [$($a.MacAddress)]"
    Write-Host "  DHCP        : $($a.Dhcp)"
    Write-Host "  IPv4        : $($a.IPAddress)/$($a.PrefixLength)"
    Write-Host "  Gateway     : $($a.Gateway)"
    Write-Host "  DNS         : $($a.DnsServers -join ', ')"
}

Write-Host ''
Write-Host "Baseline written to $dir\baseline.json" -ForegroundColor Green
Write-Host 'Next steps: uninstall VMware Tools, clean shutdown, final Veeam incremental.' -ForegroundColor Green
