# proxmox-controller — design notes

## Language & build

**Bash.** No compile step. `install.sh` symlinks every executable regular file
in this directory (except the verb scripts `install.sh`/`update.sh`/`test.sh`,
`README.md`, and `test-*.sh`) into `/home/tappaas/bin/`, making the symlinks
idempotent with `ln -sfn`. `update.sh` just `exec`s `install.sh`.

Linked entry points:

- `proxmox-controller` — the main reconciler.
- `migrate-vm.sh`, `migrate-node.sh`, `resize-disk.sh` — operator helpers.
- `proxmox-manager` — compatibility alias symlink to `proxmox-controller`
  (kept so older callers/tests still resolve; intended to be dropped at a later
  cutover).

## Internal structure

`proxmox-controller` sources two shared libraries:

- `common-install-routines.sh` — logging helpers (`info`/`warn`/`die`),
  `get_primary_node_fqdn`, `normalize_module_config`, and `CONFIG_DIR`.
- `cluster/lib/vm-net.sh` — the VLAN/trunk resolution helpers
  (`vmnet_resolve_trunks`, `vmnet_parse`, `vmnet_build_netopts`,
  `vmnet_all_active_tags`). This is the *same* logic the cluster VM-create path
  uses to build NICs, so reconcile and provisioning agree by construction.

Reconciliation pattern (the standard controller shape: read desired, read
actual, diff, optionally apply):

- **Desired** is computed on the fly: per-VM trunk lists are resolved from each
  module's JSON (`trunks0`/`trunks1`) against `zones.json`; the node bridge VLAN
  set is the active VLAN set from `zones.json`.
- **Actual** is interrogated live over SSH: `pvesh get /cluster/resources` to
  map VMID → node, and `qm config <vmid>` to read each NIC's current `trunks=`.
- **Delta + apply:** mismatched NICs are re-applied with `qm set` (preserving
  MAC/tag/queues); node bridge drift is reported, and applied only via the
  operator-gated `bridge-vids --apply`.

Counters (`DRIFT`, `CHANGED`, `ERRORS`) drive the summary and the exit code, so
a non-zero exit means "drift remains".

## How a manager calls it

The network manager (which owns `zones.json`) calls `proxmox-controller
reconcile --apply` after it has validated and applied the zone config, to push
the resulting VLAN topology down onto the hypervisor. Node bridge changes are
reported but left for the operator to apply with `bridge-vids --apply` because
rewriting a live node's interfaces is disruptive.

## Tests

`test.sh` runs every co-located `test-*.sh` (currently `test-proxmox-manager.sh`)
and exits non-zero on any failure. These are offline unit tests of the
resolution/diff logic — they do not touch a live cluster.

## Pending / not yet implemented

- **`bridge-vids` apply is report-first.** The least-privilege node bridge VLAN
  set is computed and reported on every `reconcile`, but applying it is
  operator-gated behind a separate `bridge-vids --apply` because the `ifreload`
  is disruptive — it is intentionally not part of the routine `reconcile
  --apply`.
- **`proxmox-manager` alias** is a temporary compatibility symlink to be removed
  at a later cutover.
