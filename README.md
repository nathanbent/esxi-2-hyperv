# ESXi to Hyper-V Migration Procedure

Per-VM procedure for moving Windows guests from ESXi to Hyper-V using Veeam
backup/restore, plus tooling for getting the restored VMs onto a Hyper-V
failover cluster's Cluster Shared Volumes (CSVs) and checking the cluster's
health afterwards.

Everything is **read-only** unless stated otherwise - the scripts gather,
compare, and suggest fixes, and changes are made by hand after review. The
one exception is `Move-VMToCsv.ps1` (and its menu, `Start-VMMover.ps1`),
which is a dry run unless given `-Execute`.

## Scripts

### Guest-side (per VM)

| Script | Runs where | Does what |
|---|---|---|
| `Invoke-PreMigration.ps1` | Inside the guest, on ESXi, before shutdown | Captures network config, sizing, firmware type, volumes, services, ports, shares, printers, etc. to `C:\migration\`. Flags things to fix before shutdown. |
| `Invoke-PostMigrationCheck.ps1` | Inside the guest, on Hyper-V, after restore | Compares live state to the baseline. Reports PASS / WARN / FAIL with a suggested fix for each failure. Changes nothing. |

Both write to `C:\migration\`. Read `pre-summary.txt` and `post-summary.txt`;
everything else is reference.

Works on PowerShell 4.0+ (Server 2012 R2 and newer).

### Host-side (Hyper-V cluster)

Run on a cluster node as a domain admin, with the FailoverClusters and
Hyper-V PowerShell modules. Nothing site-specific is hardcoded - CSVs, nodes
and domain controllers are discovered from the cluster and AD.

| Script | Does what |
|---|---|
| `Invoke-PreCsvMove.ps1` | Read-only readiness report for the VMs on this node: CSV I/O mode per node, host CPU models, per-VM size / generation / checkpoints / ISOs / pass-through disks, CSV free space, suggested move order. |
| `Move-VMToCsv.ps1` | Moves VM storage onto a CSV and makes the VM highly available, with ping + heartbeat checks at every step. Also re-homes clustered VMs between CSVs. Optional live-migration round trip. **Dry run unless `-Execute`.** Logs to `moves.csv` + a transcript. |
| `Start-VMMover.ps1` | Menu front-end for `Move-VMToCsv.ps1`: pick VMs from a grid, pick the target CSV, preflight, move. Keep it in the same folder as `Move-VMToCsv.ps1`. |
| `Test-ClusterVMHealth.ps1` | Read-only cluster health check: nodes, quorum, networks, CSV space and Direct I/O, per-VM storage / vSwitch / heartbeat / checkpoints, DC priority and anti-affinity, N+1 memory capacity, non-clustered VMs, recent cluster / Hyper-V errors. |

#### Configuration

`Start-VMMover.ps1`, `Invoke-PreCsvMove.ps1` and `Test-ClusterVMHealth.ps1`
read optional site settings from `mover-config.json` next to the scripts.
Copy `mover-config.example.json` to `mover-config.json` and edit it, or let
`Start-VMMover.ps1` create one with defaults on first run. The real file is
git-ignored, as is `ping-overrides.csv` (saved ping IPs for VMs that don't
report one through integration services).

| Setting | Meaning |
|---|---|
| `DefaultCsv` | CSV name (as in `Get-ClusterSharedVolume`) to target by default. Blank = first CSV. |
| `CsvSubfolder` | Folder on the CSV that holds VM folders. Default `VMs`. |
| `DCNames` | Hyper-V VM names of domain controllers, if they differ from their AD names. DCs are also auto-detected from AD. |
| `LogDir` | Where `Move-VMToCsv.ps1` writes `moves.csv` and transcripts. |
| `DefaultLeaveOnNode` | Node to migrate VMs to with the "leave on node" option. Blank = first other Up node. |

DCs get cluster priority High and an anti-affinity class (`DCs` by default)
when clustered, so the cluster keeps them on separate nodes.

## Getting the scripts onto a VM

```powershell
mkdir C:\migration
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nathanbent/esxi-2-hyperv/refs/heads/main/Invoke-PreMigration.ps1" -OutFile "C:\migration\Invoke-PreMigration.ps1" -UseBasicParsing
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nathanbent/esxi-2-hyperv/refs/heads/main/Invoke-PostMigrationCheck.ps1" -OutFile "C:\migration\Invoke-PostMigrationCheck.ps1" -UseBasicParsing
```

The TLS line is required on 2012 R2 / 2016. Add `?nocache=$(Get-Random)` to
the URL if GitHub serves a stale copy. No internet from the server VLAN?
Paste the file through the VMConnect clipboard or copy from a share.

Run from an elevated PowerShell window:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; C:\migration\Invoke-PreMigration.ps1
```

## Before starting a VM

- Know the local Administrator password (or a domain account that has
  logged in to that box before - cached credentials work at the console).
- Know which vSwitch / VLAN the VM belongs on.
- Warn the service owner about the outage window.

## Procedure

### 1. Run the pre-migration script (VM running on ESXi)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; C:\migration\Invoke-PreMigration.ps1
```

Read the **ATTENTION** block. Act on these before going further:

- **Pending reboot** - reboot the VM on ESXi first so updates finish there,
  not on first Hyper-V boot.
- **BitLocker on** - have the recovery key in hand; expect a recovery
  prompt on first boot.
- **VMware Tools installed** - handled in step 3.

Note the **Firmware type** line - it tells you Generation 1 (BIOS) or
Generation 2 (UEFI) for the restore. Note vCPU / RAM for sizing.

### 2. Create a backup (VM still running)

Run a full Veeam backup of the VM. This is the bulk data transfer and
happens with no downtime. The outage clock has not started.

### 3. Remove VMware Tools and other cleanup

Still on ESXi, as the last steps before shutdown:

- Uninstall VMware Tools from Programs and Features. It uninstalls cleanly
  here; after migration it fights back.
- Disconnect any mounted ISO in the VM's CD/DVD settings.
- Address anything else the pre-migration WARNINGS raised.

### 4. Power down

Clean shutdown from inside the guest. **Outage starts here.**

Do not delete or unregister the source VM. It is the rollback.

### 5. Run backup again

Run a Veeam incremental. With the VM powered off this captures a small,
perfectly consistent final state.

### 6. Restore to Hyper-V with no vNIC

Veeam: Restore > Entire VM restore > Restore to Hyper-V.

- Target: the Hyper-V host and the volume for VHDX storage.
- Generation: match the firmware type from step 1.
- Network: **do not connect a network adapter** (or set it to not
  connected). This prevents the VM from taking a DHCP lease on first boot,
  which is what causes DNS records to be deleted later.

Power on and open the console (VMConnect).

### 7. Remove the old vNIC from Device Manager

Log in at the console (cached domain creds or local admin).

Server 2016+:

```powershell
Get-PnpDevice -Class Net | ? Status -eq "Unknown" | % { pnputil /remove-device $_.InstanceId }
```

Server 2012 R2 (no `Get-PnpDevice`):

```powershell
$env:DEVMGR_SHOW_NONPRESENT_DEVICES=1; devmgmt.msc
```

View > Show hidden devices > Network adapters > uninstall the greyed-out
VMware adapter (vmxnet3 or Intel 82574L / e1000).

### 8. Add the vNIC

In Hyper-V Manager, add a network adapter to the VM and attach it to the
correct vSwitch and VLAN. Or from the host:

```powershell
Add-VMNetworkAdapter -VMName "<name>" -SwitchName "<vSwitch>"
Set-VMNetworkAdapterVlan -VMName "<name>" -Access -VlanId <id>   # if applicable
```

If anything depends on the old MAC (DHCP reservation, license activation),
set it statically now from `pre-adapters.txt`:

```powershell
Set-VMNetworkAdapter -VMName "<name>" -StaticMacAddress "<old MAC>"
```

### 9. Configure the vNIC to match, register DNS

Back at the console. `C:\migration\pre-summary.txt` has the IP, mask,
gateway, and DNS servers. Apply them to the new adapter (GUI or PowerShell):

```powershell
$if = (Get-NetAdapter | ? Status -eq Up).ifIndex
New-NetIPAddress -InterfaceIndex $if -IPAddress <ip> -PrefixLength <bits> -DefaultGateway <gw>
Set-DnsClientServerAddress -InterfaceIndex $if -ServerAddresses <dns1>,<dns2>
```

Then, on domain-joined machines:

```powershell
ipconfig /registerdns
```

### 10. Run the post-migration check

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; C:\migration\Invoke-PostMigrationCheck.ps1
```

Review the output. Each FAIL has a `fix:` line - review and run the ones
you agree with, then run the check again. Repeat until clean. Give it a
few minutes after boot before trusting service results; delayed-start
services show as not running on a fresh box.

Then verify the actual service from a third machine - for a print server:

```powershell
nslookup <name>
Test-NetConnection <name> -Port 445
Get-Printer -ComputerName <name>
```

Print a test page. **Outage ends here.**

## After the migration

- Leave the source VM powered off on ESXi for a soak period (days to a
  week depending on how critical it is). Then remove from inventory and
  delete.
- Add the new VM to your backup / storage snapshot / replication jobs.
- On a cluster: if the VM was restored to standalone storage, move it onto
  a CSV and make it highly available with `Move-VMToCsv.ps1` (or
  `Start-VMMover.ps1`), then run `Test-ClusterVMHealth.ps1`.
- Keep `C:\migration\` on the guest - the pre and post summaries are the
  record of what the box looked like before and after.

## Rollback

Power off the Hyper-V VM. Power on the original on ESXi. If the ESXi copy
had its IP re-registered by another machine in the meantime, run
`ipconfig /registerdns` on it. Nothing else changed.

## Domain controllers

Migrate last, one at a time, with another DC online throughout. Never run
the ESXi copy and the Hyper-V copy at the same time, and never boot the
ESXi copy again once the Hyper-V copy has started - treat it as destroyed.
After first boot on Hyper-V, check DNS SRV records with
`nltest /dsregdns` and `dcdiag /test:dns`.

## Known issues

- **DNS records deleted hours after migration** - caused by the VM taking
  a DHCP lease on first boot; when the DHCP server later cleans up the
  lease it deletes the hostname's records. Step 6 (restore with no vNIC)
  prevents it. For servers already migrated the old way:
  `ipconfig /registerdns` on the server, then delete the stale lease on
  the DHCP server.
- **"IP already assigned to another adapter"** - the ghost NIC still
  exists. Do step 7 before step 9.
- **VM won't boot / blank EFI shell / 0xc000000e** - wrong generation.
  Re-restore with the generation from the pre-migration summary.
- **Every SAN disk shows twice on the host** - MPIO not enabled on the
  Hyper-V host. Host-side issue, not a VM issue.
