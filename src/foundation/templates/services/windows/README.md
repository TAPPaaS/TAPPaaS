# templates:windows

Generic Windows VM lifecycle service — handles everything from OOBE completion
to a fully baseline-configured VM accessible via SSH.

## Phases

### Phase 1 — OOBE handoff
`cluster:vm` injects OOBE configuration via the QEMU guest agent immediately after the VM is
cloned and started (no answer ISO). The injection skips the OOBE wizard, creates the `tappaas`
local admin account, writes the SSH authorised key, starts sshd, and adds a `netsh advfirewall`
rule allowing port 22 on all network profiles. The VM reboots once to finalise OOBE.

Phase 1 of `templates:windows` waits for SSH to become available on the new VM (typically
under 5 minutes after the reboot).

### Phase 2 — Generic Windows baseline

| Step | What it does |
|------|-------------|
| 0 | **Hostname + network** — renames the VM to match `vmname` in the module JSON (requires reboot); sets network profile to Private and the built-in OpenSSH firewall rule to Any profile |
| 1 | **Disk extension** — disables WinRE, removes Recovery Partition, extends C: to full disk size |
| 2 | **VirtIO guest agent** — verifies QEMU-GA is running; installs from fedorapeople.org if missing |
| 3 | **Security-only Windows Updates** — installs PSWindowsUpdate, runs updates as SYSTEM via Scheduled Task, disables auto-update |
| 4 | **RDP setup** — enables or disables Remote Desktop based on `windows.enableRDP` in module JSON (default: disabled) |
| 5 | **tappaas account** — verifies the account is enabled, in local Administrators, and SSH-accessible |

## Module JSON fields

```json
{
  "windows": {
    "enableRDP": false
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `windows.enableRDP` | boolean | `false` | Enable Remote Desktop. SSH is always the primary access method. |

## Service files

| File | Purpose |
|------|---------|
| `install-service.sh` | Full lifecycle: Phase 1 OOBE wait + Phase 2 baseline |
| `update-service.sh` | Security-only Windows Updates (run by `update-module.sh`) |
| `test-service.sh` | Checks SSH, QEMU-GA, tappaas account, and RDP state |

## Remote access

### SSH

```bash
ssh tappaas@<vmname>.srv.internal
```

### One-liner PowerShell command

```bash
ssh tappaas@<vmname>.srv.internal \
  'powershell -NoProfile -Command "Get-Service | Where-Object Status -eq Running"'
```

### Run a script file

```bash
scp myscript.ps1 tappaas@<vmname>.srv.internal:~/
ssh tappaas@<vmname>.srv.internal \
  'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/tappaas/myscript.ps1'
```

### Enter-PSSession (from Windows, requires SSH transport)

```powershell
Enter-PSSession -HostName <vmname>.srv.internal -UserName tappaas -SSHTransport
```

### From a module's install.sh (bash → PowerShell)

Use the `run_ps1` pattern to write, SCP, and execute `.ps1` files atomically.
This avoids shell variable expansion issues with inline PowerShell via `-Command`.

```bash
run_ps1 "my_step" '
$ErrorActionPreference = "Stop"
# ... your PowerShell here
Write-Output "done"
'
```

## Building on top of this service

This service is called automatically via `dependsOn: templates:windows` in the module JSON.
Application-specific steps (IIS, SQL Server, etc.) go directly in the module's `install.sh`
and run after this service completes.

```bash
# module install.sh — add roles after the baseline is applied
run_ps1 "install_iis" '
Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Write-Output "IIS installed"
'
```
