# health-manager — design notes

## Language and build

- **Language:** TypeScript (ADR-007 §Health / Remaining-outstanding #3), built
  with `tsc` and zero npm dependencies (ambient `src/env.d.ts` declares only the
  Node built-ins used). `default.nix` compiles + wraps a `bin/health-manager`
  Node entry — the people-manager / switch-controller pilot pattern. The legacy
  `*.sh` scripts stay live and on `PATH`; **`install.sh` is not yet wired to the
  nix build** (deliberate, this pass).
- **`update.sh`** re-runs `install.sh` (idempotent relink of the `*.sh`).

## Verb surface (read-only manager)

health-manager owns **no config domain** — it reads existing module/zone config
and the live cluster — so the CRUD verbs (`add`/`modify`/`delete`/`reconcile`)
are **N/A**. The surface:

| Verb | Maps to | Notes |
|------|---------|-------|
| `list vm` | `inspect-cluster.sh` | running-guest-vs-config overview (basics) |
| `list vm --diff` | per-VM `show vm` rollup | orig/config/running drift across every managed module |
| `show vm <name>` | `inspect-vm.sh` | three-way drift table for one module |
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
| `backup-status` | `backup-status.sh --json` | a module disabled, or enabled-but-not-in-PBS-job | backup tooling absent / unparseable |

`--threshold` (default 80) applies cluster-wide. The disk gate is **read-only**:
the 50%-auto-grow that `check-disk-threshold.sh` performs is a *mutation* and
stays in the script — it is not part of the health assertion. The gate order is
service-liveness → disk-threshold → backup-status; `validate` returns 0 only when
zero gates FAIL (SKIP does not fail the assertion).

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
