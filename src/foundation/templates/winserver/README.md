# Windows Server 2025 Template (`tappaas-winserver`, VMID 8081)

This module builds a sysprep'd Windows Server 2025 Proxmox template.
Every Windows-based app module (`windows-server`, future modules) clones from this template.
The build is fully automated — you do not click through any installer.

---

## Quick start

```bash
cd /home/tappaas/TAPPaaS/src/foundation/templates
install-module.sh tappaas-winserver
```

Takes about **30 minutes**. The VM installs itself, runs sysprep, shuts down, and becomes a Proxmox template ready for cloning.

If you install a module that depends on Windows (e.g. `windows-server`) and the template doesn't exist yet, it is built automatically before the clone is created.

---

## Prerequisites — ISO files

Three ISO files must be present on the Proxmox node **before** running the install:

| ISO | Where to put it | Notes |
|-----|----------------|-------|
| Windows Server 2025 Evaluation | `/var/lib/vz/template/iso/` on `tappaas1` | Exact filename configured in `tappaas-winserver.json` → `"image"` field |
| VirtIO drivers | `/var/lib/vz/template/iso/` on `tappaas1` | Any `virtio-win-*.iso` — the script picks the latest one automatically |
| Config ISO | Built automatically during install | Do not copy manually |

**Windows ISO — current filename:**
```
26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso
```
Download from [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025). If you use a different build, update the `"image"` field in [tappaas-winserver.json](../tappaas-winserver.json).

**VirtIO drivers:**
Download the latest stable `virtio-win.iso` from [fedorapeople.org](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso).

---

## What happens during the build

1. `Create-TAPPaaS-VM.sh` creates the VM hardware on `tappaas1`
2. Three ISOs are attached: Windows, VirtIO drivers, and a small config ISO containing `autounattend.xml`
3. The VM boots — Windows Setup reads `autounattend.xml` and installs without any user input
4. After install: VirtIO guest tools and OpenSSH Server are installed automatically
5. Sysprep runs (`/generalize /oobe /shutdown`) — wipes the SID and shuts the VM down
6. The install script removes the ISOs and converts the VM to a Proxmox template

Cloned VMs get a fresh SID and can be renamed/configured independently.

---

## VM hardware — what matters and why

| Setting | Value | Why it matters |
|---------|-------|----------------|
| Machine type | `q35` | Required for TPM 2.0 and modern UEFI |
| BIOS | OVMF (EFI) | Required for Windows 11/2025 |
| EFI firmware | `efitype=4m, ms-cert=2023k, pre-enrolled-keys=1` | See note below |
| EFI disk | `tanka1` | Stores UEFI boot variables |
| TPM | v2.0 on `local-zfs` | Required by Windows Server 2025; kept on fast local storage |
| OS disk | `tanka1`, 32 GB | VirtIO SCSI, discard+SSD flags enabled |
| VGA | `std` (standard VGA) | **Must be `std`** — `qxl` makes the console invisible during install |
| SCSI controller | `virtio-scsi-pci` | |
| Boot order | `scsi0` first, then `ide2` | OVMF tries the empty disk, falls through to the Windows ISO |

### EFI / boot quirks (important for troubleshooting)

On **Proxmox 9 with QEMU 10.x**, the EFI NVRAM disk is not auto-populated when the VM is created. `Create-TAPPaaS-VM.sh` copies the OVMF vars template (`OVMF_VARS_4M.ms.fd`) directly onto the disk immediately after allocation. Without this step, OVMF starts but never initialises the display — the Proxmox console shows a blank screen forever.

The Windows ISO EFI bootloader shows a **"Press any key to boot from CD or DVD......"** prompt for 6 seconds after OVMF POST. The install script sends keystrokes automatically from ~12 s to ~28 s after VM start to catch this window. If the VM is ever started manually outside the install flow, you need to press a key in the Proxmox console yourself during that prompt.

### IDE assignments

| Drive | Content |
|-------|---------|
| `ide1` | `tappaas-winconfig.iso` — config ISO with `autounattend.xml` |
| `ide2` | Windows Server 2025 ISO — primary boot device |
| `ide3` | VirtIO drivers ISO |

The boot order has `ide2` after `scsi0` so the first boot finds the ISO, but all subsequent boots (after install) boot from the OS disk (`scsi0`) automatically.

---

## Monitoring

Take a screenshot of the VM at any time:

```bash
capture.sh 8081 tappaas1
# or, if capture.sh is on PATH:
capture 8081 tappaas1
```

Typical progression:

| Time | What you see |
|------|-------------|
| 0–15 s | Blank screen (OVMF POST + boot device scan) |
| ~15 s | "Press any key to boot from CD or DVD......" |
| ~20 s | "Loading files..." progress bar |
| ~2 min | Windows Setup "License terms" loading |
| 2–15 min | "Installing Windows Server — X% complete" |
| ~15 min | First reboot, then account setup and tool installs |
| ~25–30 min | Sysprep starts, VM shuts down |

If the Proxmox console shows a **blank screen for more than 5 minutes** and `capture.sh` returns a 640×480 stub image (tiny file, ~900 KB), the EFI NVRAM was not initialised correctly. Destroy the VM and re-run `install-module.sh tappaas-winserver` — the script now handles this automatically.

---

## Files in this directory

| File | Purpose |
|------|---------|
| `autounattend.xml` | Windows Setup answer file — fully unattended install, VirtIO drivers, OpenSSH, sysprep |
| `oobe-unattend.xml` | Legacy reference — kept for documentation. **Not deployed to clones.** OOBE configuration (tappaas account, SSH key, hostname) is now injected via QEMU guest agent by `cluster:vm/install-service.sh`, which is more reliable than CDROMs post-sysprep. |
| `build-template.sh` | Deprecated manual build script — kept as reference only |
