# health-manager — design notes

## Language and build

- **Language:** TypeScript (ADR-007 §Health / Remaining-outstanding #3), built
  with `tsc` and zero npm dependencies (the shared ambient
  `../../lib/ts/src/env.d.ts` declares the Node built-ins used). `default.nix`
  is a thin import of the shared `../../lib/nix/ts-manager.nix` builder, which
  compiles + wraps a `bin/health-manager` Node entry. Shared CLI plumbing
  (colors/`die`/`guarded`, the `--help` renderer) and the ssh/pvesh cluster
  helpers come from `../../lib/ts/src/`. The legacy
  `*.sh` scripts stay live and on `PATH`; **`install.sh` is not yet wired to the
  nix build** (deliberate, this pass).
- **`update.sh`** re-runs `install.sh` (idempotent relink of the `*.sh`).

## Verb surface (read-only manager)

health-manager owns **no config domain** — it reads existing module/zone config
and the live cluster — so the CRUD verbs (`add`/`modify`/`delete`/`reconcile`)
are **N/A**. The surface:

| Verb | Maps to | Notes |
|------|---------|-------|
| `list vm` | — | **MOVED out of health-manager** (was the port of the retired `inspect-cluster.sh`) |
| `list vm --diff` | — | **MOVED** → `module-manager list --diff` (per-module drift rollup) |
| `show vm <name>` | — | **MOVED** → `module-manager reconcile <m>` (read-only), native `module-manager/src/inspect.ts` |
| `validate` | the `check-*.sh` gates | **special**: asserts the *live* system is healthy (below) |
| `update-os <name> <vmid> <node>` | `update-os.sh` | special **action**; thin pass-through to the script |

Common options: `--config-dir DIR` (config root), `--json` (machine output for
`list`/`show`), `--diff` (`list vm` rollup), `--threshold PCT` (`validate` disk
gate). `--json` emits the typed result object (`ClusterInspection` /
`ClusterDiff` / `VmInspection`) so the verbs are scriptable.

### `validate` — the health gate (special meaning)

For the config managers `validate` means "config is well-formed". For **health**
it means "**the live system is healthy**": `validate` aggregates gates against
the running cluster and **exits non-zero if any FAIL**.

| Gate | Source | FAIL condition | SKIP condition |
|------|--------|----------------|----------------|
| `service-liveness` | `pvesh /cluster/resources` | a managed config module's VM is not `running` | — |
| `disk-threshold` | SSH `df /` per managed guest | reachable guest `/` usage ≥ threshold (default **80%**) | no guest reachable |
| `memory-commitment` | one `pvesh /cluster/resources` | a node's memory committed to RUNNING guests ≥ threshold of its physical RAM (default **100%**) | cluster unreachable / no nodes |
| `guest-memory` | `pvesh` + one `ps` / `qm status` per node | a module using ≥ 90% of its declared memory (WARN ≥ 75%), or allocated above the declared limit | cluster unreachable / nothing running |
| `backup-status` | `backup-manager list --json` | a module disabled, or enabled-but-not-in-PBS-job | backup tooling absent / unparseable |

`--threshold` (default 80) and `--memory-threshold` (default 100) apply
cluster-wide. The disk gate is **read-only**: the 50%-auto-grow that
`check-disk-threshold.sh` performs is a *mutation* and stays in the script — it
is not part of the health assertion. The gate order is service-liveness →
disk-threshold → memory-commitment → guest-memory → backup-status; `validate`
returns 0 only when zero gates FAIL (SKIP does not fail the assertion).

`guest-memory` renders one row per module beneath its own line (`CheckResult.rows`),
ordered by reclaimable gap and totalled per column. Its row status measures a
module against ITS OWN declaration — short of memory is a fault, over-declared is
not — while the gap column measures what ballooning could return. Those are
different questions and a single number cannot answer both. `warn` is a status
that reports without failing the assertion.

**Why the two thresholds differ.** A full disk stops a guest, so 80% leaves
runway to act. Committed memory at 100% is not yet a fault: a node may promise
every byte it physically has. It becomes one past that, where the node has
promised memory it does not own — which is why the memory gate accepts 1..500
rather than 1..99. A site running deliberate overcommit with ballooning can say
so (`--memory-threshold 150`) instead of switching the gate off.

**Committed, not used**, and the distinction is load-bearing: without ballooning
a guest's declared memory is pinned by the host whether the guest wants it or
not, so committed is what decides whether another guest fits. A node's *used*
figure may legitimately exceed its committed one, because ZFS ARC and host
overhead are not guest memory — a gate written against `used` would fail a
healthy node with a warm cache. Stopped guests are excluded (they hold nothing),
and an idle node is reported at 0% rather than omitted, so an empty node beside
a full one shows up as the placement problem it is.

## Architecture (TS modules)

- `src/types.ts` — entity model (`RunningGuest`, `ConfigModule`, `ClusterRow`,
  `DriftRow`, `VmInspection`, `ClusterDiff`, `CheckResult`, `HealthReport`) +
  the **`ClusterClient`** interface (the Proxmox/cluster boundary).
- `src/config.ts` — loads module JSONs from `config/` (skips non-module configs
  with no `vmid`), resolves the git source JSON via `location`, and reads the
  `site.json` node list (`siteNodeHostnames`).
- `src/inspect.ts` — pure inspection logic: `inspectCluster` (`list vm`),
  `inspectVm` (`show vm` three-way), `clusterDiff` (`list vm --diff` rollup).
- `src/checks.ts` — the health gates + `runHealthGates` aggregation.
- `src/client.ts` — `CliClusterClient`: the real `ssh`/`ping`/`pvesh`/`qm`
  shell-out FFI. Inspection + gate logic depend only on `ClusterClient`, so unit
  tests inject `FakeClusterClient` and never touch SSH.
- `src/main.ts` — verb dispatch, option parsing, table/JSON rendering, entry guard.

## State it reads

- **Module config** `config/<module>.json` (vmid, node, zone, diskSize, vmname,
  location, the `status` field — `archived` / `external` / implicit-active).
- **Site config** `config/site.json` — `.hardware.nodes[].name` for the cluster
  node list (with a `tappaas1..9` scan fallback).
- **Zone config** `config/zones.json` — for the NIC-drift VLAN mapping (consumed
  by the deferred NIC follow-up, not the scalar diff in this pass).
- **The git source JSON** (via the module's `location`) for the Released column.
- **Live cluster state** via Proxmox over SSH.

## How it talks to the cluster

Directly over SSH to the Proxmox nodes (`root@<node>.mgmt.internal`), with `ping`
reachability probes against the `site.json` node list. `pvesh get
/cluster/resources` enumerates VMs/CTs; `qm config` / `qm status` give live VM
detail; the disk gate SSHes to the guest (`tappaas@<vmname>.<zone0>.internal`)
and reads `df /`. It drives no control-plane controller.

## Testing

- **`test.sh`** keeps the fast bash smoke (every `*.sh` parses + resolves on
  `PATH`) and adds the TS unit tier: `tsc --noEmit` on `src` and the unit
  tsconfig, then runs the offline unit suite.
- **`test/unit/inspect.test.ts`** — offline unit tests (no SSH, no Proxmox) with
  an injected `FakeClusterClient`: cluster classification, the three-way `show vm`
  drift levels, the `--diff` rollup (managed-only, unreachable degradation), the
  health gates (pass/fail/skip), and the `site.json` node source. 23 assertions,
  no deep/live tier (the live tooling has no self-contained disruptive test).

## Deferred follow-ups (coordinator-approved, TODOs in source)

- **NIC-drift rows** (`show vm` / rollup): port `cluster/lib/vm-net.sh`
  (`vmnet_parse` / `vmnet_resolve_trunks` / `vmnet_zone_vlantag`) for the
  bridge/zone/VLAN/trunks/MAC rows + the `ALL` trunk-sentinel expansion; HANode /
  description rows fold in here.
- **Nested-config normalizer** — the bash `normalize_module_config`
  ("Pattern A → flat"); the TS port reads flat keys only for now.
- **`cluster` / `node` entities** — ADR-007 lists them alongside `vm`; entity
  model TBD.
- **Guest-agent liveness** — extend `service-liveness` with `qm guest cmd <vmid>
  ping` beyond `pvesh` running-state.
- **Full `update-os` TS port** — today the verb pass-throughs to `update-os.sh`.
- **`install.sh` → nix build** — link the compiled `health-manager` bin (kept on
  the `.sh` link path for now).
