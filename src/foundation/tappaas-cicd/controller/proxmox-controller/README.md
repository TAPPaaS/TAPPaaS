# proxmox-controller

The **Proxmox hypervisor network controller** for TAPPaaS. It reconciles the
Proxmox L2 (VLAN) layer to `zones.json` — the single source of truth — and ships
a few hands-on helpers for moving VMs around and growing disks.

It owns two control points that otherwise have to be correct by hand:

1. **Per-VM NIC trunks.** Every VM whose module JSON declares a `trunks0` /
   `trunks1` list has its live `qm config netN ...,trunks=` recomputed from
   `zones.json` (including the `ALL` / `*` sentinel) and idempotently
   re-applied, preserving the NIC's MAC, tag and queue settings. This is
   data-driven across *all* trunk-bearing VMs, so a zone added after a VM was
   provisioned still reaches that VM's trunk list (otherwise guests on the new
   VLAN get no IP).
2. **Node `lan` bridge VLAN set.** The VLAN-aware `lan` bridge on each cluster
   node. The controller computes the least-privilege active VLAN set from
   `zones.json` and compares it to what the node actually carries.

## CLI: `proxmox-controller`

```
proxmox-controller <command> [--apply]
```

Without `--apply` every command is a **dry-run** that only reports drift. The
exit code is non-zero if drift remains after the command, so callers and CI can
gate on convergence.

| Command | What it does |
|---------|--------------|
| `reconcile [--apply]` | Reconcile per-VM trunks (applied with `--apply`) **and** report node bridge-vids drift. The everyday command. |
| `trunks [--apply]` | Reconcile per-VM `trunks=` for all trunk-bearing VMs only. |
| `bridge-vids [--apply]` | Reconcile each node's `lan` bridge VLAN set. **Apply is operator-gated** — applying rewrites a live node's interfaces and runs `ifreload`, which is disruptive. |
| `show <vmname>` | Show the resolved-vs-actual trunk list for one VM (read-only). |

A compatibility alias `proxmox-manager` is linked to the same binary.

### Examples

```bash
# See what's drifted, change nothing:
proxmox-controller reconcile

# Converge all VM trunks; report (but don't touch) node bridges:
proxmox-controller reconcile --apply

# Inspect one VM's trunk situation:
proxmox-controller show firewall

# Apply the node bridge VLAN set (disruptive — operator-gated):
proxmox-controller bridge-vids --apply
```

## Helper scripts

These are linked onto `PATH` alongside the main controller. They perform
one-off, operator-driven changes to the hypervisor.

### `migrate-vm.sh` — move VMs between nodes

```
migrate-vm.sh <module-name>        # migrate the module's VM to its HA node
migrate-vm.sh --node <node-name>   # migrate every VM that belongs on <node> back to it
```
Options: `--offline` (skip the live-migration attempt and go straight to
shutdown → migrate → start), `-h`/`--help`. It attempts a live migration first
and falls back to offline if that fails.

### `migrate-node.sh` — evacuate / repopulate a node

```
migrate-node.sh <node-name>            # evacuate all VMs from <node> (for maintenance)
migrate-node.sh --return <node-name>   # bring every VM that belongs on <node> back
migrate-node.sh --list <node-name>     # dry-run: list VMs and the planned actions
```
Options: `--offline` (offline migration only).

### `resize-disk.sh` — grow a VM disk

```
resize-disk.sh <vmname> <new-size>     # e.g. resize-disk.sh nextcloud 50G
```
Resizes the disk in Proxmox and then grows the filesystem inside the guest.

## Requirements

Runs on the mothership and reaches the cluster over SSH (`root@tappaasN.mgmt.internal`),
using Proxmox CLIs (`qm`, `pvesh`). It reads `zones.json` from the live config
directory and the per-module JSON files for the `trunks*` declarations.
