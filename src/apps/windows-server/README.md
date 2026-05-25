# windows-server

Barebone Windows Server 2025 VM — no roles, no application software. A clean starting point for any Windows-based service on TAPPaaS.

## What you get

- Windows Server 2025 Standard (Desktop Experience), fully patched (security updates only)
- VirtIO paravirtual drivers (storage, network, balloon memory, guest agent)
- QEMU-GA: Proxmox can snapshot, quiesce, report IP, and gracefully shut down
- SSH server (OpenSSH for Windows) with key auth — `tappaas` account pre-configured
- C: volume extended to the full `diskSize` from the module JSON
- RDP disabled by default (enable via `windows.enableRDP: true`)

## Prerequisites

### 1. TAPPaaS foundation
The standard foundation modules must be installed: `cluster`, `firewall`, `backup`.
The `tappaas-cicd.pub` SSH key (deployed to the Proxmox node by the `tappaas-cicd` install) is injected into the VM during OOBE and is required for SSH access.

### 2. Windows Server 2025 template (VMID 8081)
Built automatically if missing — `install-module.sh windows-server` detects a missing template and runs the full build (~30 min) before proceeding with the clone.

For the auto-build to succeed, the Proxmox node needs:
- **Windows Server 2025 evaluation ISO** in `/var/lib/vz/template/iso/` — filename must match `image` in `src/foundation/templates/tappaas-winserver.json`
- **VirtIO drivers ISO** (`virtio-win-*.iso`) in `/var/lib/vz/template/iso/` — used to load the SCSI driver during Windows Setup

### 3. Storage: `local-zfs` on the target node
The template VM requires `local-zfs` for its EFI and TPM disks. This is not configurable — Proxmox must create and write the OVMF VARS in a single operation, which only works reliably on `local-zfs`. If `local-zfs` doesn't exist, the template build will fail with a boot loop.

See `src/foundation/templates/winserver/README.md` for the technical explanation.

### 4. Internet access from the VM
The baseline installer downloads resources if they weren't baked into the template:
- **VirtIO guest tools** — from `fedorapeople.org` if QEMU-GA is not already running
- **Windows security updates** — from Windows Update (PSWindowsUpdate / WSUS)

## Installation

```bash
# From tappaas-cicd
install-module.sh windows-server
```

The installer:
1. Clones the Windows Server template into a new VM
2. Boots the VM — OOBE configuration is injected via QEMU guest agent (tappaas account, SSH key, firewall rule, Administrator password); VM reboots once to finalise
3. Waits for SSH to become available (~3–5 min after the OOBE reboot)
4. Renames the VM hostname to match `vmname` from the JSON (requires a second reboot)
5. Extends C: to the configured `diskSize` (removes Recovery Partition first)
6. Verifies / installs VirtIO guest tools
7. Applies security-only Windows Updates (runs as SYSTEM via Scheduled Task, ~5–15 min)
8. Configures RDP per `windows.enableRDP`
9. Verifies the `tappaas` account

## Configuration

Edit `windows-server.json` before installing:

```json
{
  "vmname": "windows-server",
  "vmid": 500,
  "cores": 4,
  "memory": "4096",
  "diskSize": "64G",
  "zone0": "srv",
  "windows": {
    "enableRDP": false
  }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `vmname` | `"windows-server"` | VM hostname and DNS name — must be unique. Becomes `<vmname>.srv.internal`. |
| `vmid` | 500 | Proxmox VM ID — must be unique in your cluster |
| `cores` | 4 | vCPU count |
| `memory` | `"4096"` | RAM in MB |
| `diskSize` | `"64G"` | Disk size; C: is extended to fill it |
| `zone0` | `"srv"` | Network zone (see `zones.json`) |
| `windows.enableRDP` | `false` | Enable Remote Desktop Protocol |

### Multiple instances

Use `deploy-instances.sh` to spin up several Windows Server VMs from the same base config.
It auto-assigns names (`windows-server`, `windows-server-2`, `windows-server-3`, …) and
finds the next free VMIDs within the 500–599 block:

```bash
deploy-instances.sh windows-server 3
```

Before installing anything it prints a confirmation table showing each planned instance, its
VMID, and whether it will be created or skipped (already installed). Already-running instances
are never touched.

To give an instance a completely custom name, copy the JSON and set `vmname` + `vmid` manually:

```bash
cp config/windows-server.json config/fileserver.json
# edit vmname → "fileserver", vmid → 501
install-module.sh fileserver
```

Either way, the VM gets its hostname, DNS record, and SSH address from `vmname`.

## Accessing the VM

### SSH (always available)

```bash
ssh tappaas@windows-server.srv.internal
```

### Run a PowerShell command

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -Command "Get-ComputerInfo | Select-Object WindowsProductName,TotalPhysicalMemory"'
```

### Run a script file

```bash
scp my-setup.ps1 tappaas@windows-server.srv.internal:~/
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/tappaas/my-setup.ps1'
```

### Enter-PSSession (from Windows, SSH transport)

```powershell
Enter-PSSession -HostName windows-server.srv.internal -UserName tappaas -SSHTransport
```

### RDP (if enabled)

Enable in the JSON and re-run `install-module.sh windows-server`, then connect with:

```
mstsc /v:windows-server.srv.internal
```

Username: `tappaas`

## Diagnostics

### Installed patches

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -Command "Get-HotFix | Sort-Object InstalledOn | Format-Table InstalledOn,HotFixID,Description -AutoSize"'
```

### Updates available right now (live check against Microsoft)

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module PSWindowsUpdate; Get-WindowsUpdate -IgnoreReboot | Select-Object KB,Title,Size | Format-Table -AutoSize"'
```

### Full Windows Update history

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module PSWindowsUpdate; Get-WUHistory -Last 20 | Format-Table Date,KB,Title,Result -AutoSize | Out-String -Width 200"'
```

### Windows Update service status

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -Command "Get-Service wuauserv | Format-List Name,Status,StartType"'
```

### Recent system/application errors (Event Log)

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -Command "
Get-EventLog -LogName System -EntryType Error,Warning -Newest 20 |
  Format-Table TimeGenerated,Source,Message -AutoSize | Out-String -Width 200"'
```

### TAPPaaS setup log (written during OOBE + install)

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -Command "Get-Content C:\tappaas-setup.log -ErrorAction SilentlyContinue"'
```

### Disk usage

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -Command "
Get-PSDrive C | Select-Object Name,
  @{N=\"Used(GB)\";E={[math]::Round(($_.Used/1GB),1)}},
  @{N=\"Free(GB)\";E={[math]::Round(($_.Free/1GB),1)}},
  @{N=\"Total(GB)\";E={[math]::Round(($_.Used+$_.Free)/1GB,1)}} | Format-Table"'
```

### QEMU guest agent alive (from tappaas-cicd)

```bash
ssh root@tappaas1.mgmt.internal \
  "qm agent 500 ping && echo 'QEMU-GA: alive' || echo 'QEMU-GA: not responding'"
```

### Live console screenshot (from tappaas-cicd, useful during install)

```bash
capture.sh 500 tappaas1
```

### Running services

```bash
ssh tappaas@windows-server.srv.internal \
  'powershell -NoProfile -Command "Get-Service | Where-Object Status -eq Running | Sort-Object Name | Format-Table Name,DisplayName -AutoSize"'
```

## Updates

Security-only Windows Updates (no feature packs or driver updates):

```bash
update-module.sh windows-server
```

`update-module.sh` creates a Proxmox snapshot before starting, so the VM can be rolled back if an update causes problems.

## Building on top of this module

To create a module that adds software on top of the generic Windows baseline:

1. Copy `src/apps/windows-server/` to `src/apps/my-windows-app/`
2. Rename `windows-server.json` → `my-windows-app.json`, update `vmname` and `vmid`
3. In `install.sh`, after calling `windows-server/install-service.sh`, add your app-specific steps

```bash
# install.sh
"${WINDOWS_GENERIC}" "${MODULE_NAME}"

# Add your application setup here:
# run_ps1 "my_app_install" '...'
```

### Key JSON fields for Windows modules

Two fields must be set correctly in every Windows module JSON — they are not optional:

| Field | Required value | Why |
|-------|---------------|-----|
| `ostype` | `"win11"` | Tells the hypervisor to use the Windows hardware profile: local-time clock, Windows ACPI, Hyper-V enlightenments, TPM 2.0. Windows Server 2025 requires this — using `l26` (the Linux default) breaks the clock and disables TPM. |
| `os` | `"windows"` | Tells TAPPaaS the OS family. `cluster:vm` injects OOBE configuration (tappaas account, SSH key, firewall rule) via QEMU guest agent after cloning. Without this, OOBE requires manual intervention. |
| `cloudInit` | `false` | **Required.** Windows does not use cloud-init. Without this, `Create-TAPPaaS-VM.sh` runs `qm cloudinit update` on a VM with no cloud-init drive, which exits non-zero and aborts the entire install. |

**`l26` is for Linux** — it is the letter L (Linux kernel), not the digit 1. Setting `ostype: "l26"` on a Windows VM is the most common mistake and causes clock drift and broken power management.

See `src/foundation/templates/services/windows/README.md` for the `run_ps1` pattern and all Phase 2 steps.
