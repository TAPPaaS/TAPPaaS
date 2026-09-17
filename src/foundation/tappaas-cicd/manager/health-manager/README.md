# health-manager

Cluster / VM / disk / OS **health and maintenance** for TAPPaaS. health-manager
is a **read-only** manager: it surfaces the live cluster against the deployed
module config; it never authors a config domain of its own and never reconciles.
Because of that, the CRUD verbs (`add`/`modify`/`delete`/`reconcile`) are **N/A**
here, and `validate` carries a special meaning (see below).

This is the port (ADR-007 §Health). The
remaining bash scripts (`check-disk-threshold.sh` — its auto-grow is not
yet ported — and `update-os.sh`) remain in
place and working; the manager re-implements the unambiguous read verbs on top
of a thin `ssh`/`pvesh`/`qm` shell-out boundary (no Proxmox logic is
re-implemented). health-manager is a **read-mostly orchestrator** under the
F12 runtime-state rule (see the "Runtime-state access rule" section in
`tappaas-cicd/README.md`): its cluster reads go through the shared
`lib/ts/src/cluster.ts` choke-point; its one write path (`update-os`) is a
documented delegation pending the `update-os.sh` port.

## Verb surface

```
health-manager validate [--threshold PCT] [--config-dir DIR]
health-manager update-os <name> <vmid> <node>
```

> **MOVED (ADR-007):** the per-VM three-way drift inspect is no longer a
> health-manager verb. It is now `module-manager reconcile <m>` (the read-only
> report for one module) and `module-manager list --diff` (the rollup), native
> in `module-manager/src/inspect.ts` — the port of the retired `inspect-vm.sh`.
> The three sections below describe that behaviour and are kept here until the
> prose is relocated to module-manager's README.

### `list vm` — cluster overview (moved; was the port of the retired inspect-cluster.sh)

Read-only. Lists every running guest (VM/CT) across the Proxmox cluster (VMID,
name, node, type, status) and classifies each against the module configs in
`config/`: `managed` (in config), `[external]` (unmanaged guest), or
`NOT IN CONFIG`. It also lists configured modules whose VM is **not** running,
distinguishing genuinely-missing from `[archived]` and `[external]`-down.
This is a **report** — it does not exit non-zero on a discrepancy (that is what
`validate` is for).

### `list vm --diff` — per-VM three-way rollup (moved; now `module-manager list --diff`)

Runs the `show vm` three-way comparison (**orig/config/running**) for **every
managed module** and rolls up the drift, printing only the fields that differ per
VM plus cluster-wide warn/error totals. A VM that cannot be queried (node down,
not yet provisioned) is reported as *unreachable* rather than aborting the whole
rollup. Bare `list vm` stays the running-vs-config basics; `--diff` is the
drift view.

### `show vm <name>` — three-way diff for one module (moved; now `module-manager reconcile <m>`)

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
| `memory-commitment` | one `pvesh /cluster/resources` | a node's COMMITTED memory ≥ threshold of its physical RAM (default **100%**, `--memory-threshold PCT`) |
| `backup-status` | `backup-manager list --json` | a module is backup-disabled, or enabled but not in the PBS job |

A gate with nothing to check (e.g. no reachable guests, backup tooling absent)
reports **SKIP**, not FAIL. `--threshold` applies cluster-wide. The disk gate is
### What `memory-commitment` counts, and what it deliberately does not

It reports, per node, the memory **committed to running guests** against the
node's physical RAM — the number that answers "will another guest fit". Three
choices are worth knowing:

- **Committed, not used.** Without ballooning a guest's declared memory is
  pinned by the host whether the guest wants it or not, so committed is what
  constrains placement. A node's *used* figure can exceed its committed one
  perfectly legitimately, because ZFS ARC and host overhead are not guest
  memory — a gate written against `used` would fail a healthy node with a warm
  cache.
- **Stopped guests hold nothing.** A stopped guest is not counted; counting it
  would report an overcommit the node is not living with.
- **An idle node is reported at 0%, not hidden.** An empty node beside a full
  one is a placement problem, and the report is where you see it.

**read-only** here — the auto-resize that `check-disk-threshold.sh` performs is a
mutation and stays in the script (it is not part of the health assertion).

### `update-os <name> <vmid> <node>` — OS-patch action (special)

`update-os` stays a distinct **action** verb (it patches the OS; not CRUD). The
manager is a thin pass-through: it forwards `<name> <vmid> <node>` to
`update-os.sh` (overridable via `UPDATE_OS_BIN`) and propagates its exit code.
The OS-patch logic (NixOS rebuild / apt, IP+SSH wait, DHCP-hostname fix,
reboot guards, controller-self-reboot protection) lives in `update-os.sh` and is
not re-implemented here.

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
ping-probed and only reachable nodes are used.

## Build

Built as `bin/health-manager` via `default.nix`. The CLI plumbing (colors,
`info`/`die`, the `guarded()` error guard, the `--help` renderer) and the
cluster ssh/pvesh helpers come from `../../lib/ts/src/` (`cli.ts`, `help.ts`,
`cluster.ts`, `config-io.ts`).

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
- **Nested-config normalizer** — the retired `inspect-vm.sh` ran each JSON through
  the bash `normalize_module_config` ("Pattern A → flat"); the port reads flat
  keys only, so nested/variant-shaped configs are not yet flattened.
- **`cluster` / `node` entities** — ADR-007 lists them alongside `vm`; their
  entity model (a node/cluster resource summary) is not yet defined.
- **Guest-agent liveness** — the `service-liveness` gate currently checks
  `pvesh` running-state only; adding `qm guest cmd <vmid> ping` is a follow-up.
- **Full `update-os` port** — today the verb shells out to `update-os.sh`.
