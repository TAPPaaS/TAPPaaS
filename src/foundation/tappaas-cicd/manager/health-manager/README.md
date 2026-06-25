# health-manager

Cluster / VM / disk / OS **health and maintenance** for TAPPaaS. health-manager
is a **read-only** manager: it surfaces the live cluster against the deployed
module config; it never authors a config domain of its own and never reconciles.
Because of that, the CRUD verbs (`add`/`modify`/`delete`/`reconcile`) are **N/A**
here, and `validate` carries a special meaning (see below).

This is the TypeScript port (ADR-007 §Health, Remaining-outstanding #3). The
original bash scripts (`inspect-cluster.sh`, `inspect-vm.sh`,
`check-disk-threshold.sh`, `check-backup-status.sh`, `update-os.sh`) remain in
place and working; the TS manager re-implements the unambiguous read verbs on top
of a thin `ssh`/`pvesh`/`qm` shell-out boundary (no Proxmox logic is
re-implemented).

## Verb surface

```
health-manager list vm [--diff] [--json] [--config-dir DIR]
health-manager show vm <name> [--json] [--config-dir DIR]
health-manager validate [--threshold PCT] [--config-dir DIR]
health-manager update-os <name> <vmid> <node>
```

### `list vm` — cluster overview (= inspect-cluster.sh)

Read-only. Lists every running guest (VM/CT) across the Proxmox cluster (VMID,
name, node, type, status) and classifies each against the module configs in
`config/`: `managed` (in config), `[external]` (unmanaged guest, #216), or
`NOT IN CONFIG`. It also lists configured modules whose VM is **not** running,
distinguishing genuinely-missing from `[archived]` (#215) and `[external]`-down.
This is a **report** — it does not exit non-zero on a discrepancy (that is what
`validate` is for).

### `list vm --diff` — per-VM three-way rollup

Runs the `show vm` three-way comparison (**orig/config/running**) for **every
managed module** and rolls up the drift, printing only the fields that differ per
VM plus cluster-wide warn/error totals. A VM that cannot be queried (node down,
not yet provisioned) is reported as *unreachable* rather than aborting the whole
rollup. Bare `list vm` stays the running-vs-config basics; `--diff` is the
drift view.

### `show vm <name>` — three-way diff for one module (= inspect-vm.sh)

Prints a 3-column table for a module's VM: **Released** (the git source JSON via
the module's `location`), **Desired** (`config/<module>.json`), and **Actual**
(the running VM, via Proxmox). Yellow = config-vs-git drift; red = actual-vs-config
drift. This pass covers the scalar fields (identity, cores, memory, disk,
storage, BIOS, CPU type, tags). NIC drift rows are a deferred follow-up (below).

### `validate` — assert the live system is healthy (special)

Unlike the config managers (where `validate` = "config is well-formed"),
**health `validate` asserts the *live* system is healthy**. It aggregates the
health gates against the running cluster and **exits non-zero if any gate
fails**:

| Gate | Source | FAIL when |
|------|--------|-----------|
| `service-liveness` | `pvesh /cluster/resources` | a managed config module's VM is not `running` |
| `disk-threshold` | SSH `df /` per guest | a reachable guest's `/` usage ≥ threshold (default **80%**, `--threshold PCT`) |
| `backup-status` | `backup-status.sh --json` | a module is backup-disabled, or enabled but not in the PBS job |

A gate with nothing to check (e.g. no reachable guests, backup tooling absent)
reports **SKIP**, not FAIL. `--threshold` applies cluster-wide. The disk gate is
**read-only** here — the auto-resize that `check-disk-threshold.sh` performs is a
mutation and stays in the script (it is not part of the health assertion).

### `update-os <name> <vmid> <node>` — OS-patch action (special)

`update-os` stays a distinct **action** verb (it patches the OS; not CRUD). The
TS manager is a thin pass-through: it forwards `<name> <vmid> <node>` to
`update-os.sh` (overridable via `UPDATE_OS_BIN`) and propagates its exit code.
The OS-patch logic (NixOS rebuild / apt, IP+SSH wait, DHCP-hostname fix,
reboot guards, controller-self-reboot protection) lives in `update-os.sh` and is
not re-implemented in TS.

## Common options

- `--config-dir DIR` — config root (default: `$CONFIG_DIR` or
  `/home/tappaas/config`). The one true common option across managers.
- `--json` — machine-readable output for `list` / `show` (the typed result
  object, pretty-printed). Scriptable; `validate`/`update-os` are unaffected.
- `--diff` — `list vm` only: the per-VM three-way rollup.
- `--threshold PCT` — `validate` only: the disk-usage gate threshold (1–99).

## Node source

The cluster node list is read from `site.json` (`.hardware.nodes[].name`, the
`get_all_node_hostnames` equivalent). When `site.json` yields no nodes,
health-manager falls back to scanning `tappaas1..9`. Either way each candidate is
ping-probed and only reachable nodes are used — matching inspect-cluster.sh.

## Build

TypeScript, built with `tsc` (zero npm dependencies; ambient `src/env.d.ts`),
wrapped as a Node `bin/health-manager` via `default.nix` — mirroring
people-manager / the switch-controller pilot.

```
nix-build -A default default.nix
ln -sf "$PWD/result/bin/health-manager" /home/tappaas/bin/health-manager
```

> The legacy `*.sh` scripts are still linked onto `PATH` by `install.sh` and stay
> live; wiring `install.sh` to the nix build is intentionally **not** done in this
> pass.

## Deferred follow-ups (coordinator-approved)

These are intentionally **not** built in this pass — clean TODOs mark them in the
source:

- **NIC-drift rows** in `show vm` / the diff rollup (bridge / zone / VLAN /
  trunks / MAC) — requires porting `cluster/lib/vm-net.sh` (`vmnet_parse`,
  `vmnet_resolve_trunks`, `vmnet_zone_vlantag`: zone→VLAN resolution + `ALL`
  trunk-sentinel expansion). HANode / description rows fold in here too.
- **Nested-config normalizer** — `inspect-vm.sh` runs each JSON through the bash
  `normalize_module_config` ("Pattern A → flat"); the TS port reads flat keys
  only, so nested/variant-shaped configs are not yet flattened.
- **`cluster` / `node` entities** — ADR-007 lists them alongside `vm`; their
  entity model (a node/cluster resource summary) is not yet defined.
- **Guest-agent liveness** — the `service-liveness` gate currently checks
  `pvesh` running-state only; adding `qm guest cmd <vmid> ping` is a follow-up.
- **Full `update-os` TS port** — today the verb shells out to `update-os.sh`.
