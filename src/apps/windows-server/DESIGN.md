# windows-server — Design notes

Implementation and extension detail displaced from the old README during the Diataxis
restructure (issue #247). User-facing catalog info is in [README.md](./README.md); install
steps in [INSTALL.md](./INSTALL.md).

## Module mechanics

The module itself is nearly empty — the work is done by its dependencies:

- `cluster:vm` clones the Windows template and injects OOBE configuration (tappaas
  account, SSH key, firewall rule, Administrator password) via QEMU guest agent.
- `templates:windows` (`src/foundation/templates/services/windows/install-service.sh`)
  applies the full baseline: disk extension, VirtIO agent, security updates, RDP,
  tappaas account verification.
- The module's own `install.sh` runs after those and only prints the access hint.
- `update.sh` and `test.sh` delegate to the templates module's
  `services/windows/update-service.sh` / `test-service.sh`.

Updates are security-only Windows Updates (no feature packs or driver updates), run via
`update-module.sh windows-server`, which creates a Proxmox snapshot first for rollback.

## Building on top of this module

To create a module that adds software on top of the generic Windows baseline:

1. Copy `src/apps/windows-server/` to `src/apps/my-windows-app/`.
2. Rename `windows-server.json` → `my-windows-app.json`, update `vmname` and `vmid`.
3. In `install.sh`, after calling the Windows generic install-service, add your
   app-specific steps:

```bash
# install.sh
"${WINDOWS_GENERIC}" "${MODULE_NAME}"

# Add your application setup here:
# run_ps1 "my_app_install" '...'
```

See `src/foundation/templates/services/windows/README.md` for the `run_ps1` pattern and
all Phase 2 steps.

### Key JSON fields for Windows modules

Three fields must be set correctly in every Windows module JSON — they are not optional:

| Field | Required value | Why |
|-------|---------------|-----|
| `ostype` | `"win11"` | Tells the hypervisor to use the Windows hardware profile: local-time clock, Windows ACPI, Hyper-V enlightenments, TPM 2.0. Windows Server 2025 requires this — using `l26` (the Linux default) breaks the clock and disables TPM. |
| `os` | `"windows"` | Tells TAPPaaS the OS family. `cluster:vm` injects OOBE configuration (tappaas account, SSH key, firewall rule) via QEMU guest agent after cloning. Without this, OOBE requires manual intervention. |
| `cloudInit` | `false` | **Required.** Windows does not use cloud-init. Without this, `Create-TAPPaaS-VM.sh` runs `qm cloudinit update` on a VM with no cloud-init drive, which exits non-zero and aborts the entire install. |

**`l26` is for Linux** — it is the letter L (Linux kernel), not the digit 1. Setting
`ostype: "l26"` on a Windows VM is the most common mistake and causes clock drift and
broken power management.

## Configuration reference

| Field | Default | Description |
|-------|---------|-------------|
| `vmname` | `"windows-server"` | VM hostname and DNS name — must be unique. Becomes `<vmname>.<zone0>.internal`. |
| `vmid` | 500 | Proxmox VM ID — must be unique in your cluster |
| `cores` | 4 | vCPU count |
| `memory` | `"4096"` | RAM in MB |
| `diskSize` | `"64G"` | Disk size; C: is extended to fill it |
| `zone0` | `"srvWork"` | Network zone (see `zones.json`) |
| `windows.enableRDP` | `false` | Enable Remote Desktop Protocol |

## Accessing the VM — command patterns

SSH (always available):

    ssh tappaas@windows-server.srvWork.internal

Run a PowerShell command:

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "Get-ComputerInfo | Select-Object WindowsProductName,TotalPhysicalMemory"'

Run a script file:

    scp my-setup.ps1 tappaas@windows-server.srvWork.internal:~/
    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/tappaas/my-setup.ps1'

Enter-PSSession (from Windows, SSH transport):

    Enter-PSSession -HostName windows-server.srvWork.internal -UserName tappaas -SSHTransport

RDP (if enabled): `mstsc /v:windows-server.srvWork.internal`, username `tappaas`.

## Diagnostics cookbook

Installed patches:

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "Get-HotFix | Sort-Object InstalledOn | Format-Table InstalledOn,HotFixID,Description -AutoSize"'

Updates available right now (live check against Microsoft):

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module PSWindowsUpdate; Get-WindowsUpdate -IgnoreReboot | Select-Object KB,Title,Size | Format-Table -AutoSize"'

Full Windows Update history:

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module PSWindowsUpdate; Get-WUHistory -Last 20 | Format-Table Date,KB,Title,Result -AutoSize | Out-String -Width 200"'

Windows Update service status:

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "Get-Service wuauserv | Format-List Name,Status,StartType"'

Recent system/application errors (Event Log):

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "
    Get-EventLog -LogName System -EntryType Error,Warning -Newest 20 |
      Format-Table TimeGenerated,Source,Message -AutoSize | Out-String -Width 200"'

TAPPaaS setup log (written during OOBE + install):

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "Get-Content C:\tappaas-setup.log -ErrorAction SilentlyContinue"'

Disk usage:

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "
    Get-PSDrive C | Select-Object Name,
      @{N=\"Used(GB)\";E={[math]::Round(($_.Used/1GB),1)}},
      @{N=\"Free(GB)\";E={[math]::Round(($_.Free/1GB),1)}},
      @{N=\"Total(GB)\";E={[math]::Round(($_.Used+$_.Free)/1GB,1)}} | Format-Table"'

QEMU guest agent alive (from tappaas-cicd):

    ssh root@tappaas1.mgmt.internal \
      "qm agent 500 ping && echo 'QEMU-GA: alive' || echo 'QEMU-GA: not responding'"

Live console screenshot (from tappaas-cicd, useful during install):

    capture.sh 500 tappaas1

Running services:

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "Get-Service | Where-Object Status -eq Running | Sort-Object Name | Format-Table Name,DisplayName -AutoSize"'
