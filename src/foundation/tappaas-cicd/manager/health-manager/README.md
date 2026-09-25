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
`lib/ts/src/cluster.ts` choke-point; its two write paths (`update-os` and
`reboot`) are documented delegations to `update-os.sh` and `reboot-guest.sh`,
pending the `update-os.sh` port.

## Verb surface

```
health-manager validate [--threshold PCT] [--memory-threshold PCT] [--config-dir DIR]
health-manager update-os <name> <vmid> <node>
health-manager reboot <module>
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
the module's `moduleSource`), **Desired** (`config/<module>.json`), and **Actual**
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
| `guest-memory` | `pvesh` + one `ps`/`qm status` per node | a module **using ≥ 90%** of its declared memory (**WARN** at 75%), or one whose allocated memory exceeds its declared limit |
| `backup-status` | `backup-manager list --json` | a module is backup-disabled, or enabled but not in the PBS job |
| `pending-reboot` | one SSH probe per guest | never — **WARN** when a guest is waiting for a reboot (see below) |

A gate with nothing to check (e.g. no reachable guests, backup tooling absent)
reports **SKIP**, not FAIL. `--threshold` applies cluster-wide. The disk gate is
### `guest-memory` — three numbers, because two mislead

Per module it reports **declared → allocated → used**:

- `declared − allocated` is memory the guest has **never touched**. QEMU backs a
  page on first write, so this costs nothing and there is nothing to reclaim.
- `allocated − used` is memory the guest **touched and then freed**. The host was
  never told, so it still holds it. This — and only this — is what a balloon
  driver could give back.

Measured on a live estate: 60G declared, 31.9G allocated, ~20G used. A report
with only declared-and-used would have said "reclaim 40G"; the third column says
most of it was never taken.

It prints **one row per module, largest gap first**, and totals each column at
the end. The row status answers a different question from the gap: **is this
module short of memory?** — `used` against its own declaration, WARN at 75% and
FAIL at 90%. Over-declaring is waste and never fails; running out is a fault and
does. The first live run found `litellm` at 93% of 4G, which no amount of
looking at the reclaimable column would have surfaced.

**Unmeasured guests are named, never numbered.** The signal is whether the
balloon statistics carry `free_mem`, *not* whether a guest agent answers: the
FreeBSD agent on an OPNsense firewall answers `ping` and `get-osinfo` while
providing no memory statistics, and Proxmox then reports the host's own view as
the guest's usage. That firewall read as 8.0G of 8.0G — "full" — while using
1.15G, with its reported `mem` exceeding its own `maxmem`, which no genuine
guest figure can do. Printing that number would steer an operator away from the
one VM on the system with real memory to reclaim.

LXC containers need no agent: their memory is the host's own accounting. Their
declared figure is a **limit** they may never reach, not an allocation the host
must find — so the report totals **VMs and LXC separately**. Summing them would
describe nothing: on a live estate the combined figure read 106G where the VMs
had actually been promised 60G.

PVE **templates are excluded**: a template is the image a module is cloned from,
holds no memory, and listing it as a stopped guest is noise.

### `pending-reboot` — guests whose update is waiting for a reboot

`update-os` does not always reboot after a rebuild: not with `automaticReboot`
off, not while a backup holds the VM, and never the controller that runs it.
Each of those prints a `DEFERRED:` line that the update sweep collects into
`deferred_changes` — but that record belongs to one run. This gate answers
"which guests are waiting **now**", from the guests themselves:

- **NixOS:** the booted system (`/run/booted-system`) is not the system profile
  (`/nix/var/nix/profiles/system`). When the two differ in release, the row says
  so: since #728 a nixpkgs release move is *staged* for the next boot, so a
  guest in that state still **runs the old release** — `release move 25.11 ->
  26.05 staged, still running 25.11`. One that was switched instead (the
  controller, which updates itself) runs the new release on the old kernel —
  `release move 25.11 -> 26.05 active, still on the 25.11 kernel`. Otherwise it
  is a newer generation of the same release (a kernel, a bootloader change) and
  the row names both builds.
- **Debian:** `/var/run/reboot-required`.

Nothing is stored: a flag in a module's config would go stale the moment
someone reboots by hand, the derived state cannot. The gate **WARNs and never
fails** — a pending reboot is debt, not an outage, and a site that reboots in
its own window is healthy while it waits. Take one with `health-manager reboot
<module>`, or with the update itself: `module-manager module update <module>
--allow-disruption`.

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

**When it reboots.** After a NixOS rebuild `update-os` reboots the guest and
waits until the module can serve (not merely until sshd answers) when
`automaticReboot` is on in `site.json`, **or** when the run was authorized with
`--allow-disruption` — `module-manager module update <m> --allow-disruption`
exports `TAPPAAS_ALLOW_DISRUPTION=1` (ADR-020 D8). Otherwise the reboot is not
taken, and so is it when a backup holds the VM (#686) or the VM is the
controller running the update. All three print a `DEFERRED:` line naming what
is waiting — the new generation, or a staged release move — which the update
sweep collects into its result (#730).

### `reboot <module>` — take a pending reboot (special)

```
health-manager reboot nextcloud
```

Reboots the module's VM and waits until the module can serve again: the same
reboot path `update-os` takes after a rebuild (`reboot_guest` in `update-os.sh`
— wait out a backup lock, `qm reboot`, SSH, then the module's readiness), on
demand and **without updating**. The manager resolves the module to its VMID
and to the node the VM **actually runs on** (HA may have moved it), reads the
guest's pending state before and after, and hands the reboot to
`reboot-guest.sh` (overridable via `REBOOT_BIN`):

```
  pending: booted 25.11.20260522.b77b3de, next boot 26.05.20260922.1bc55b9
  … reboot, readiness …
✓ nextcloud runs 26.05.20260922.1bc55b9
```

- Exit **0** when the guest came back ready; **1** on an error, a refusal, or a
  reboot that did not take the new system (it names what it still boots);
  **3** when a backup still holds the VM after the wait — nothing was rebooted.
- **Refused:** the controller itself (rebooting it would kill the command — the
  message gives the `qm reboot` to run from a node), a container (`pct reboot`),
  and a module with no VM.
- The reboot is the operator's explicit act, so it needs no `automaticReboot` or
  `rebootOk` — that is what separates it from the update sweep.

## Common options

- `--config-dir DIR` — config root (default: `$CONFIG_DIR` or
  `/home/tappaas/config`). The one true common option across managers.
- `--json` — machine-readable output for `list` / `show` (the typed result
  object, pretty-printed). Scriptable; `validate`/`update-os` are unaffected.
- `--diff` — `list vm` only: the per-VM three-way rollup.
- `--threshold PCT` — `validate` only: the disk-usage gate threshold (1–99).
- `--memory-threshold PCT` — `validate` only: committed memory as a percent of a
  node's physical RAM before the gate fails (1–500, default 100).

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

## What `update-os` puts on a guest before it rebuilds

Beyond the module's own `.nix`, its siblings and its companion JSON, one
generated file lands in `/etc/nixos` on every NixOS update (#472):

- **`tappaas-site.nix`** — from `config/site.json` via `lib/site-locale.sh`: time
  zone, locale, console keymap, and the zone gateway as the time source (#87).
  The module's `.nix` imports it.

The shared baseline `tappaas-common.nix` is deliberately **not** shipped: modules
still inline their own copies of it, so importing it fails the build on
conflicting definitions (#324).

A Debian guest has no fragment to import, so the same facts are *converged* there
instead — `timedatectl`, `localectl` and a `systemd-timesyncd` drop-in — and each
change is logged rather than made silently. Neither path invents a value: a site
that records nothing leaves the guest as it is.
