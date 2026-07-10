# windows-server

Primary audience: TAPPaaS admin (a base VM for building Windows-based services, not an
end-user app).

Barebone Windows Server 2025 VM — no roles, no application software. A clean starting point
for any Windows-based service on TAPPaaS.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Windows Server 2025 Standard (Desktop Experience), security-patched | — | provisioned automatically from template 8081 |
| SSH with key auth (`tappaas` account, OpenSSH for Windows) | `srvWork` zone / tappaas-cicd | `ssh tappaas@windows-server.srvWork.internal` |
| Remote PowerShell execution | tappaas-cicd / admin | `ssh … 'powershell -NoProfile -Command "…"'` or `Enter-PSSession -SSHTransport` |
| RDP (disabled by default) | `srvWork` zone | set `windows.enableRDP: true`, then `mstsc /v:windows-server.srvWork.internal` |
| Proxmox integration (QEMU-GA: snapshot, quiesce, IP report, shutdown) | Proxmox / cicd | `qm agent <vmid> ping` |
| VirtIO paravirtual drivers (storage, network, balloon, guest agent) | in-VM | installed by the baseline |
| C: volume extended to the configured `diskSize` | in-VM | automatic during install |
| Security-only Windows Updates on demand | tappaas-cicd | `update-module.sh windows-server` (snapshots first) |

## What is not included

- No Windows server roles (no AD, DNS, file server, IIS, …) and no application software —
  add those in a module built on top of this one (see [DESIGN.md](./DESIGN.md)).
- No feature packs or driver updates — updates are security-only.
- No public exposure — the VM lives in the `srvWork` zone.

## Requirements

- Windows Server 2025 evaluation ISO on the Proxmox node (`/var/lib/vz/template/iso/`),
  filename matching `image` in `src/foundation/templates/tappaas-winserver.json`.
- VirtIO drivers ISO (`virtio-win-*.iso`) in the same directory.
- `local-zfs` storage on the target node (required for the template's EFI and TPM disks).
- Internet access from the VM (VirtIO guest tools download, Windows Update).
- Sizing defaults: 4 cores, 4096 MB RAM, 64G disk (VMID 500, zone `srvWork`).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | Clones the template into a VM and injects OOBE config via QEMU guest agent |
| `templates:windows` | Windows Server 2025 template (8081) and the Windows baseline service |
| `backup:vm` | Registers the VM in the managed PBS backup job |
| `network:proxy` | Reverse-proxy wiring (Caddy) |

For installation steps see [INSTALL.md](./INSTALL.md).
