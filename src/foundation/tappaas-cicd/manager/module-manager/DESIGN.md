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
| `resolve` | TS (config) | `src/resolve.ts` — the desired-state document: config + `module-fields.json` defaults + the `.orig` flags (ADR-020 D1) |
| `validate` | TS (config) | tier/source lint (ported from `validate-module-tier-source.sh`) + the ADR-020 service field-manifest lint |
| `add` | bash | `install-module.sh` |
| `modify` | bash | `update-module.sh` (release update) |
| `delete` | bash | `delete-module.sh` |
| `reconcile` | TS (lifecycle) | `src/inspect.ts` + `src/services.ts` (read-only drift report, default) / `src/reconcile.ts` (`--apply`: leaf converge) — see below |
| `test` | bash | `test-module.sh` |
| `snapshot-vm` | bash | `snapshot-vm.sh` (special VM op) |

Common options: `--config-dir`, `--json` (list/show/resolve/validate). The
`module` entity keyword is optional.

### The one desired-state resolver (ADR-020 D1)

`lib/ts/src/desired.ts` holds the ONLY answer to "what is field *f*'s desired
value for module *m*?": the literal value in the deployed config, else the
`module-fields.json` default — and only when the schema's `usedBy` says that
default applies to this module. `inspect` consumes it; `module resolve` is its
verb form; from ADR-020 P3 the converge consumes it too, and the service scripts
stop carrying `cfg()` default ladders of their own.

That single home is the point. #550 was two resolvers disagreeing — `inspect.ts`
rendered an undeclared `cputype` as `-`, `cluster:vm/update-service.sh` defaulted
it to `host` — so the reported desired value and the applied one were different.
The unit suites assert the agreement structurally: mutate the resolver and both
`inspect.test.ts` and `resolve.test.ts` go red.

`ResolvedField` keeps `value` and `literal` apart on purpose. "Declared as the
same thing as the default" and "not declared at all" are different facts, and a
consumer that must preserve an acting-path sentinel (cluster:vm treats an
undeclared `bridge1` as *no second NIC*, not as the schema's `lan`) needs the
second one.

### The one differ, and where actual state comes from (ADR-020 D7)

`inspect` no longer runs `qm config` or parses it. ACTUAL state comes from the
provider's own **`services/<svc>/report-service.sh`** (`src/report.ts` is the
manager-side client), which locates the guest cluster-wide, reads it on the node
it is really on, and returns one flat JSON object keyed by the manifest's
`liveKey`s. Each NIC is reported both whole and split into
`net0.bridge`/`.tag`/`.trunks`/`.mac`, so nothing above the provider decodes a
netopts string (Resolved Question 11).

That removed a twin that had already drifted: the bash netopts parser could not
read a container's `hwaddr=` MAC while its TypeScript port could, and the two tag
normalizers disagreed about duplicates and whitespace. Normalization now lives
once, in `lib/ts/src/drift.ts`, and is applied to BOTH sides of every
comparison — `computeDrift` is the single differ that `inspect` renders and (from
P4) `modify` applies.

The reporter's exit codes are part of the contract: 4 cluster-unreachable, 5
guest-absent, 6 located-but-unreadable. #526 was one message standing for all
three, so they stay separable end to end.

### The converge: how a drift record becomes actions (ADR-020 P3)

`cluster:vm/update-service.sh` no longer computes drift. It asks the manager for
a record (`module drift <m> --service cluster:vm --json`) and hands it to
`tappaas-cicd/lib/converge-lib.sh`, the one runner:

- every `set` field is batched into ONE `qm set`, as before;
- each `hook` unit goes to `update-net.sh` / `update-disk.sh` / `update-node.sh`
  over a uniform CLI (`--unit <file>`, exit `0`/`10`/`20`/`1`), so each is
  runnable and testable on its own;
- a `migrate` unit runs LAST — it relocates the guest, and `qm set` is
  node-local;
- side effects are sequenced ONCE across the record, reboot → wait-ip → dns, so
  two changed NICs still produce one reboot and one DNS pass.

What stayed in `update-service.sh` is what is genuinely cluster:vm's and is not
field drift: the provider callbacks (`converge_apply_set`,
`converge_side_effect_*`) that know how to reach Proxmox, wait for a DHCP lease
in the target subnet, and register DNS. That is ADR-020 D7's migration
discipline — extract the drift loop, keep everything else — and it is why the
script shrank from 460 lines to ~285 rather than disappearing.

The record carries the `actual` state it was computed from, which is how a hook
gets the values no module field declares: the MAC to preserve when the module
pins none, and the `queues` that must never be hot-changed on a running NIC
(#194).

### Changing a field: the pre-gate and the disruption gate (ADR-020 P4)

`modify --set field=value` adds exactly one step in front of the existing
algorithm: write the value into the deployed config (`set-module-field.sh` —
Pattern-A aware, typed from the schema, run as the operator so the file never
becomes root-owned, #525), then converge as usual.

Two gates, and the division between them is the whole design:

- The **static pre-gate** (`preGateSet` in `src/converge.ts`) refuses only what
  the schema alone can settle — `immutable` and `recreate` — because writing
  those would leave config claiming something reality can never match. A mixed
  `--set` is rejected whole: no partial write across one modify.
- Everything whose refusal needs LIVE state — is this size change a shrink? does
  this migrate need downtime? — passes the gate and is decided by the converge,
  where the snapshot wrapper can roll back.

The **disruption gate** is separate again: a class says a change *needs*
downtime, `--force` or `rebootOk` + `TAPPAAS_SCHEDULED_PASS` says we are
*allowed* to cause it. Unauthorized disruptive drift is deferred, reported, and
exits 0.

### Service field manifests (ADR-020 D3/D4)

Each provider service declares the change semantics of the fields it owns in
`services/<service>/fields.json`: per field, a **change class** (what changing it
costs after install) and how the change is **applied**. The vocabulary and the
document lint live in `lib/ts/src/service-fields.ts`, the JSON schema in
`schemas/service-fields.json`, and `module validate` enforces coverage — a
service that ships a manifest must classify every field `module-fields.json`
says it owns. A service with no manifest has not been migrated yet and is
skipped, so the lint is usable throughout the rollout.

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
  P10 `validate.sh` delegates straight to the TS verb. dependsOn/integratesWith
  **reference-integrity** and the ADR-020 **field-manifest coverage** lint are
  implemented; still **not** ported: a full JSON **schema** check of every field
  against `module-fields.json` (flagged in `src/validate.ts`).
- **ADR-020 is partly built.** P0 (manifests + `rebootOk` + the coverage lint),
  P1 (the one resolver + `module resolve`), P2 (`report-service.sh` for
  cluster:vm and cluster:lxc, the shared normalizers + differ, `inspect` off its
  own `qm config` parsing), P3 (`converge-lib.sh`, `--apply-drift`, the three
  `update-<field>.sh` hooks, the `cfg()` ladder deleted) and P4 (`modify --set`
  + the static pre-gate, the armed `--force`/`rebootOk` disruption gate, the
  sweep's deferral summary) are in — **#498 and #557 are closed for
  cluster:vm**. Not yet: the rollout to the other 23 services and
  `network-manager` (P5); the dead-code sweep (P6).
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
