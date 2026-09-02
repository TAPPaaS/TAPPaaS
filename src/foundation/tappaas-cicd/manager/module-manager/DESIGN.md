# module-manager — design notes

## Language and build

- **Front door:** the `module-manager` **TypeScript** CLI (ADR-007 #3 verb
  alignment) — a thin orchestrator mirroring `people-manager` / `network-manager`
  (zero npm deps, shared `lib/ts` helpers + ambient `lib/ts/src/env.d.ts`, built
  by `tsc` via the shared `lib/nix/ts-manager.nix` through `default.nix` into
  `result/bin/module-manager`). It owns the CONFIG-layer verbs in-process and
  delegates the LIFECYCLE verbs to the bash scripts.
- **Underlying lifecycle scripts:** Bash, unchanged. `install-module.sh`,
  `update-module.sh`, `delete-module.sh`,
  `test-module.sh`, `snapshot-vm.sh` + helpers (`copy-update-json.sh`,
  `module-format.sh`, `validate-module-tier-source.sh`,
  `test-validate-module-tier-source.sh`). They stay the source of truth until a
  later retire phase; the TS verbs orchestrate them.
- **`install.sh`** links every `*.sh` (except the verb scripts) into `~/bin`
  (`${TAPPAAS_BIN:-/home/tappaas/bin}`). NOTE (next phase, NOT done here): it does
  not yet `nix-build` + link the `module-manager` TS bin — that is deferred.
- **`update.sh`** re-runs `install.sh` (idempotent relink).

## Standardized verbs (ADR-007 #3)

`module-manager` presents the canonical verbs on entity `module`. CONFIG-layer
verbs are pure TS (read `config/*.json`); LIFECYCLE verbs shell out via an
injected `ModuleClient` (production `CliModuleClient`; tests inject a fake):

| Verb | Layer | Maps to |
|------|-------|---------|
| `list` / `show` | TS (config) | enumerate / detail deployed modules (`--json`) |
| `validate` | TS (config) | tier/source lint (ported from `validate-module-tier-source.sh`) |
| `add` | bash | `install-module.sh` |
| `modify` | bash | `update-module.sh` (release update) |
| `delete` | bash | `delete-module.sh` |
| `reconcile` | TS (lifecycle) | `src/inspect.ts` + `src/services.ts` (read-only drift report, default) / `src/reconcile.ts` (`--apply`: leaf converge) — see below |
| `test` | bash | `test-module.sh` |
| `snapshot-vm` | bash | `snapshot-vm.sh` (special VM op) |

Common options: `--config-dir`, `--json` (list/show/validate). The `module`
entity keyword is optional.

### Module identity — the `kind` tag

`install-module.sh` stamps `"kind":"module"` onto every deployed config (via the
Pattern-A-aware `jq_module_write`). `module list`/`show` select on
`.kind=="module"` — the authoritative way to distinguish a deployed module from
the co-located state files (`zones.json`, `site.json`, `module-fields.json`,
`switch-configuration-*`, `cert-refids.json`). For configs not yet re-installed
(pre-tag) a **heuristic** fallback applies: any of `dependsOn`/`integratesWith`/
`provides`/`location` present. The heuristic intentionally does **not** require `vmname`, so
provider-only modules (e.g. `templates`: `provides:["nixos","debian"]`, no
vmid/vmname) are still enumerated (shown without vmid/node, not filtered out).

### `reconcile` — the read-only report (default) and its scope

`reconcile <module>` without `--apply` is the READ-ONLY inspect (`src/inspect.ts`).
It reports two things, and the summary states which of them it actually covered:

- the **config-field** diff (`Released[git]` / `Desired[~/config]` /
  `Actual[running VM]`; Actual is N/A for a module with no `vmid`), and
- the **dependency-service state** (`src/services.ts`): for each `dependsOn`
  and `integratesWith` entry (#501), that provider's read-only
  `services/<service>/test-service.sh <module>` —
  the same verifier `test-module.sh` Step 3 runs, delegated to rather than
  reimplemented, so `rules-manager verify-rules` and friends stay the single
  source of truth for what "no drift" means on each plane.

The second part exists because the field diff alone described almost nothing about
a **policy-only** module — no VM, all state provisioned by its providers (firewall
rules, NAT rules, discovery relays) — and so reported a confident clean while
declared rules were missing (#458).

Contracts worth keeping in mind:

- **Drift exits 0.** The inspect is a report; `list --diff` and the
  `site/environment reconcile --deep` cascade propagate its rc, so drift must not
  fail them. A check that could not RUN exits 1 (unknown ≠ clean), the same rule
  already applied to an unreachable Proxmox node.
- **Never a silent pass.** A provider with no `test-service.sh` (today:
  `backup:external`, `backup:push`, `backup:remote`, `identity:accessControl`,
  `templates:debian`, `coturn:turn`, `vllm-amd:inference`) renders as *NOT
  checked*, and a report that skipped the checks entirely names the deps it left
  uncovered instead of printing a bare "no discrepancies found".
- **Who pays.** One child process (usually one firewall API round-trip) per
  dependency: ON for a single `reconcile <module>`, OFF for `list --diff`
  (`--services` opts in, and the header says so when it did not) and for the
  `environment reconcile` PREVIEW cascade (which passes `--no-services`).

### `reconcile` vs `modify` — two distinct verbs

`reconcile` (`src/reconcile.ts`) is the **leaf converge** the
`site/environment reconcile --deep` cascade walks down to: it re-applies the
module's **current** config to its VM/service — running each dependency's
`update-service.sh`, then the module's own `update.sh`/`install.sh`, both from
the module directory — with **no snapshot, no pre/post tests, no 3-way merge,
and no `updateTime` bump**. Because it mutates no config and is idempotent,
re-running it (or a shared dependency) anytime is safe.

`modify` (`update-module.sh`) *changes* the config via a release update and then
performs the **same** apply by calling `module-manager reconcile --apply`,
wrapped in snapshot + pre/post tests + rollback + the `updateTime` bump. There is
exactly one apply implementation, exercised by both verbs — before #495 there
were two, and only the `modify` one worked.

**Service contract.** `services/<svc>/update-service.sh` is the converge and
every service must ship one (enforced by `test.sh`); `install-service.sh` holds
only create-only prerequisites and `exec`s `update-service.sh` when it has none.
Reconcile never falls back from one to the other: `install-service.sh` has create
semantics — `cluster:vm`'s runs `Create-TAPPaaS-VM.sh`, which refuses an existing
VMID — which is exactly why reconcile failed on every VM-backed module until #495.

**Step 3 always runs.** A Step 2 (dependency) failure no longer aborts before the
module's own re-apply. Some providers perform destructive re-applies — a NixOS
rebuild rewrites in-VM state that only the module's `update.sh` restores — so
bailing out mid-way left instances *less* converged than before the command ran.
Failures are accumulated and reported after Step 3, and still exit non-zero.

**`integratesWith` — optional dependencies (#501).** A soft sibling of `dependsOn`:
identical `provider:service` coordinates and the same `install/update/delete-service.sh`
wiring, but with the guard **inverted from hard-fail to silent-skip**. The differences,
all reusing the `dependsOn` machinery rather than forking it:

- *Install/reconcile*: a provider that is not installed is skipped without error
  (`applyConverge(dep, optional=true)` in `reconcile.ts`; the soft loops in
  `install-module.sh` / `update-module.sh`). An installed provider wires identically.
- *Reverse auto-wire*: when a module that `provides: X` is installed, `install-module.sh`
  Step 7 scans installed configs for `integratesWith: <this>:X` (`find_integrateswith_consumers`,
  env-aware) and runs the provider's `install-service.sh` on each pre-existing integrator —
  so install order does not matter.
- *Migration is a no-op*: `update-module.sh` computes its lifecycle delta over the
  **union** of `dependsOn` + `integratesWith`, so reclassifying a coordinate between the two
  (e.g. moving `vllm-amd:inference` to optional) neither tears down nor recreates the wiring
  already in place — only the guard semantics change.
- *Delete*: `integratesWith` consumers never block a provider's deletion (unlike `dependsOn`);
  they are un-wired first via the provider's `delete-service.sh`. A module's own optional
  integrations are torn down alongside its hard deps.
- *Validate*: `validateIntegratesWith` reports a malformed coordinate or one listed in **both**
  fields as errors, an installed-but-unwireable provider as a warning, and a not-installed
  provider as **nothing at all** — the whole point of an optional integration.

## Config state

- **`config/<module>.json`** — the effective module config (`<module>-<env>.json`
  for non-default environments). Fields are validated against
  `src/foundation/schemas/module-fields.json`, which also defines the `usedBy` grouping
  used for the canonical config-block ("Pattern A") form.
- **`config/<module>.json.orig`** — the pre-image used for a 3-way merge so
  operator customizations survive a release update.
- **Classification:** `tier` (`foundation` | `app`) and `source`
  (`official` | `community` | `private` | `local`) on each module JSON, with the
  rule `tier:foundation` ⇒ `source:official` (override `--allow-fork`).
- **Environment:** `--environment` resolves the VM name and the zone from the
  target environment's `network.zone` (`config/environments/<env>.json`); the
  chosen environment is persisted on the module JSON so update/delete resolve the
  right source.

## How it talks to the cluster

It does not drive a control-plane controller; it operates Proxmox directly over
SSH (`root@<node>.mgmt.internal`): `pvesh get /cluster/resources` to discover
VMs, `qm config` / `qm status`, `qm snapshot` / `delsnapshot` / `rollback` for
snapshots, and `qm guest cmd ... ping` for guest-agent health. NixOS modules are
rebuilt locally **on the VM** (not via `--target-host`) so the hardware config
matches, after waiting for cloud-init + passwordless sudo to be ready. Heavy `jq`
parsing throughout.

## Testing

`test.sh` — **fast (default), no provisioning, temp fixtures:** entry-script
smoke (parse + on-PATH); the `resolve_default_zone` helper (explicit zone0 wins,
then `site.json` fallback, then a single non-mgmt environment, then `mgmt`);
the environment/zone/vmname resolution; tier/source lint cases (foundation+official
pass, foundation+community fail, app+any pass, invalid enums fail, `--allow-fork`
override); the foundation→non-mgmt and foundation+community rejections; the
`--variant`→`--environment` alias; the delete-foundation `--force` gate; and
back-compat (a tier-less app module with no site/environments). It folds in the
standalone `test-validate-module-tier-source.sh` lint suite, and it now also
compiles and runs the **TypeScript unit tests** (`test/unit/module.test.ts`,
`test/unit/inspect.test.ts` — the inspect report, the dependency-service drift
check, and the CLI wiring that decides who pays for it) via the same
`run_ts`/`dist-test` pattern `people-manager/test.sh` uses; before that they
existed but were never executed by `test.sh`. The **deep**
(`TAPPAAS_TEST_DEEP=1`) path currently runs the same checks — no live provisioning
tier has been added yet.

## Pending / not yet implemented

- **`validate` is real (in the TS verb).** `module validate` ports the ADR-007b
  tier/source lint into `src/validate.ts` (foundation⇒official, enum checks,
  community warn, `--allow-fork`) and runs it over one or every deployed config.
  The legacy `validate-module.sh` wrapper name was retired (Phase 7.1); the
  P10 `validate.sh` delegates straight to the TS verb. Still **not** ported: a JSON **schema** check
  against `module-fields.json` and dependsOn **reference-integrity** (do the
  named providers exist among deployed modules) — both flagged in
  `src/validate.ts` as future work.
- **`install.sh` does not build/link the TS bin yet** (next phase). Today it
  only relinks the `*.sh` scripts; the `module-manager` bin is built manually via
  `default.nix`.
- **No deep test tier yet.** `test.sh` does not add live cluster/VM provisioning
  probes under `TAPPAAS_TEST_DEEP=1`.
- **Operational guards** carried in the scripts (worth knowing): `snapshot-vm.sh`
  and `update-module.sh` refuse to snapshot the controller's own host (it would
  freeze its own root FS); `--reinstall` recovers from a failed partial install;
  `copy-update-json.sh` searches both `src/module-catalog.json` and the legacy
  `src/modules.json` for back-compat.
