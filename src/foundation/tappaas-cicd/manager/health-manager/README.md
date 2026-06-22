# health-manager

Cluster / VM / disk / OS **health and maintenance** utilities. These are
operational, read-mostly tools that inspect the cluster against its config and
keep VMs healthy. Unlike the other managers, health-manager does not author a
config domain of its own, so it has **no `validate` operation** — it reads the
existing module/zone config and the live cluster.

## Commands

All bash, linked onto `PATH` by `install.sh`.

### `inspect-cluster.sh` — cluster vs config overview

```
inspect-cluster.sh
```

Read-only. Lists every running VM/container across the Proxmox cluster (VMID,
name, node, type, status) and compares it to the module configs in `config/`. It
flags VMs running with no config (`NOT IN CONFIG`), unmanaged guests
(`[external]`), and modules whose config exists but VM was removed
(`[archived]`).

### `inspect-vm.sh` — three-way diff for one module

```
inspect-vm.sh <module-name>
```

Prints a 3-column table for a module's VM: **Released** (the git source JSON),
**Desired** (`config/<module>.json`), and **Actual** (the running VM, via
Proxmox). Highlights config-vs-git drift and actual-vs-config drift across cores,
memory, disk, storage, BIOS, CPU type, NICs (bridge / zone / VLAN / trunks /
MAC), HA node, etc.

### `check-disk-threshold.sh` — grow a disk over a threshold

```
check-disk-threshold.sh <vmname> <threshold>
```

- `<vmname>` — module name (config in `config/`).
- `<threshold>` — disk-usage percentage (1–99).

SSHes to the VM, reads disk usage, and if it exceeds `<threshold>` expands the
disk by 50%. Logs to `~/logs/disk-resize.log`.

```bash
check-disk-threshold.sh nextcloud 80
```

### `update-os.sh` — update a VM's OS

```
update-os.sh <vmname> <vmid> <node>
```

- `<vmname>` — module name.
- `<vmid>` — Proxmox VM ID.
- `<node>` — node hostname (e.g. `tappaas1`).

Detects the OS and updates it: NixOS via `nixos-rebuild` (using `./<vmname>.nix`,
with a variant fallback), Debian/Ubuntu via `apt update/upgrade`. Waits for the
VM's IP and SSH, fixes the DHCP hostname, and auto-reboots when the site's
`automaticReboot` is enabled (with a guard against rebooting the controller VM
that is running the update).

```bash
update-os.sh nextcloud 312 tappaas1
```
