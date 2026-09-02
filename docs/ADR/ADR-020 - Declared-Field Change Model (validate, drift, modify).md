# ADR-020 — Declared-Field Change Model (validate · drift · modify)

| | |
|---|---|
| **Status** | **Proposed** — design pass for #498, all open questions resolved; realization + phased implementation/test plan + documentation impact detailed (v0.5). No code yet; this is the "decide in writing first" artifact, ready to implement. |
| **Version** | 0.5 |
| **Date** | 2026-09-02 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007f Realization](<ADR-007f - Realization.md>) (managers orchestrate / **plan**; controllers + service scripts do the imperative **act**) |
| **Refines** | [ADR-004 Module catalog & config cascade](<ADR-004-module-catalog-config-cascade.md>) (where a field's desired value comes from), [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates — the unit that owns a field's change semantics) |
| **Instantiated by** | [ADR-019 HA and Cross-Node VM Migration Policy](<ADR-019 - HA and Cross-Node VM Migration Policy.md>) — the `cluster:vm` `node`/`HANode` change is the first and hardest concrete change-hook; ADR-019 defines its policy, this ADR defines the frame it plugs into. |
| **Closes / addresses** | **#498** (modify cannot change config values — the parent design issue), **#557** (modify edits only `--environment`; deployed config is authoritative; reconcile --apply is all-or-nothing across `dependsOn`), **#538** (network-manager has no `modify` for a zone's policy fields — the sibling-manager instance of the same gap). Builds on the just-closed **#549** (validate must enforce the same rules as reconcile) and **#550** (one schema-driven desired-state resolver, done on the *reporting* side — this ADR extends it to the *acting* side, exactly as #550's closing note deferred to #498). |
| **Numbering note** | ADR-018 reserved by the SSH-identity PR #523; ADR-019 is HA/migration. This is **020**. |
| **Changelog** | v0.1 initial draft: the planner/actor split, the change-class taxonomy, the per-service field-change hook contract. v0.2 (operator decision): **one** `modify` verb — `--set` writes the field into config first, then the *unchanged* core modify algorithm runs (3-way merge → converge via the module's own `update.sh` + every `dependsOn` `update-service.sh`). ADR-020's job is to make that converge field-change-aware, not to add a second scoped apply path. v0.3 (operator resolved the 7 open questions): manifest = `services/<service>/fields.json`; change class keyed by the (field, service) **pair**; `modify` **never** writes back to the repo/release source (deployed-config-only, Released-drift is expected); a **static pre-gate** rejects an immutable/recreate `--set` before writing; a mixed `--set` set is **rejected whole**; the never-converge-provider edge is **out of scope for v1**; the resolver/converge core is **shared** in `lib/ts`. Status → Proposed. v0.4 (realization detailed — D7/D8): the **manager owns the single drift computation** (services only *report* actual and *apply* the drift the manager hands them); a per-service **`report-service.sh`** reports actual state (reused by test/health/update); provider-specific parse deleted from `inspect.ts`; disruption (reboot/offline-migrate) is authorized by a per-module **`rebootOk`** (default false) + an explicit `modify --force`, decoupled from `update-tappaas --force` ("run now"), and an unauthorized disruptive change is **deferred with a warning, exit 0**; every existing `update-service.sh` is migrated with **semantics preserved** (non-field-update logic stays put). v0.5: added a **phased implementation plan** (P0–P6, scoped to the measured inventory: 25 `update-service.sh` scripts, resolver embryo in `inspect.ts`, `cfg()` ladder in `cluster:vm`), a **test plan** tied to the existing suites + mutation discipline, and a **documentation-impact** analysis (which `.md` files carry it, per ADR-013). |

## Context

Four code paths in `module-manager` reason about **the same module fields**, independently:

| Path | File | What it does with a field | Cluster contact |
|---|---|---|---|
| **validate** | `validate.ts` | static lint (tier/source, config-block ↔ dependsOn, dependsOn integrity) | none |
| **drift / inspect** | `inspect.ts` | 3-way report: Released (git) · Desired (config) · Actual (live) | read |
| **reconcile --apply** | `reconcile.ts` | re-apply the *current* config, calling each `dependsOn` provider's `update-service.sh` | write (converge) |
| **modify** | `update-module.sh` | today: merge a new *release* into config, re-apply; can change **only `--environment`** (#557) | write |

Two structural problems follow from four independent paths:

1. **They can disagree about the same field.** #549: `validate` did not enforce the config-block rule that `reconcile` did — two enforcers of one schema, the one named `validate` the weaker. #550: `cluster:vm/update-service.sh` (acting) defaults an undeclared `cputype` to `host` via `cfg()`, while `inspect` (reporting) rendered it `-` — the reported desired value and the value the update path would actually use were different. Both were fixed *locally*; the shared cause — no single desired-state resolver — was not.

2. **There is no sanctioned way to change a field, and no place the change *semantics* live.** #557: to correct `dependsOn` (or any field but `environment`) the operator hand-edits `${CONFIG_DIR}/<module>.json` or does delete+add (a reinstall). And because `reconcile` reads the **deployed** config as authoritative (`reconcile.ts:195`, "the persisted field is the authority either way"), editing the module in git changes nothing until the deployed file changes. Meanwhile the knowledge of *how* to change a field on a running guest — `cores`/`memory` are a live `qm set`; `diskSize` grows but never shrinks; `node` means migrate (ADR-019); `vmid`/`bios` cannot change in place — is hardcoded in exactly one file, `cluster/services/vm/update-service.sh`, as an imperative drift loop. Nothing declares it; no other provider has an equivalent; validate/reconcile/inspect/modify each re-reason about it separately.

3. **`reconcile --apply` is all-or-nothing across `dependsOn` (#557).** It re-applies *every* provider of the module. A module carrying unrelated pre-existing drift in one provider cannot have a second provider re-applied without also re-applying the drifted one — which, in the reported case, meant a converge attempting to provision a hand-configured appliance that was powered off.

The same gap exists one manager over: #538 — `network-manager` has `add`/`delete`/`bind`/`reconcile` but no `modify` for a zone's *policy* fields (`access-to`, `pinhole-allowed-from`, `description`); the only paths are delete-and-re-add or hand-editing `zones.json`, the anti-pattern ADR-014 D1 set out to close.

**This ADR unifies the four paths behind one model and gives every `<provider>:<service>` a systematic, declared way to change (or refuse to change) the fields it owns.** It is deliberately manager-agnostic: `module-manager` and `network-manager` are the first two implementers.

## Decision — the model

### D1. One desired-state resolver, consumed by all four paths

There is exactly **one** function that answers "what is field *f*'s desired value for module *m*?", and validate / drift / reconcile / modify all call it. It already exists in embryo as `appliedDefault()` + `resolveField()` in `inspect.ts` (#550): the literal config value, else the `module-fields.json` `default` gated by the field's `usedBy`, plus the `.orig` 3-way flag ("Desired was overwritten at install on purpose, so it is not tracking Released"). This ADR **lifts that resolver out of `inspect.ts` into shared code** (`module-manager/src/desired.ts`, or `lib/ts` if network-manager shares it) and makes it the single definition.

Crucially, the **acting** path stops defaulting on its own. Today `update-service.sh` has its private `cfg 'cputype' 'host'` ladder — the second copy of the defaults that #550 could only fix on the reporting side. Under this ADR the **manager resolves desired state once and hands each service its owned fields already resolved**; the service scripts no longer carry `cfg()` default ladders. This closes #550 at the root: there is one resolved value, computed once, and reporting and acting read the same one.

The resolver is exposed as a subcommand — **`module-manager module resolve <name>`** (the module name is the verb's argument; `module-manager` takes no name before the verb) — which prints the resolved desired document: the *deployed* `config/<name>.json` (which, after the modify 3-way merge, already **is** the true desired state) **plus** the schema defaults for fields it does not declare, plus the `.orig` "not tracking release" flags. `resolve` does **not** run the merge (that is a modify step); it is a pure read+default, so `inspect` (no merge) and `modify` (post-merge) get the same answer. D7 makes it the input both the report and the apply paths diff against.

> **Invariant (generalizes #549 + #550):** validate, drift, reconcile and modify derive every field's desired value, and every structural rule, from **one schema (`module-fields.json`) + one resolver**. Any intentional difference between two paths is *stated in the schema*, never an incidental artifact of a second code copy.

### D2. One `modify` verb — `--set` writes config first, then the *unchanged* core algorithm runs

There is **one** `modify` verb, not two. `modify <m>` is exactly the release update `update-tappaas` already calls per module (via `module-manager module modify <m>` → `update-module.sh`). `modify <m> --set field=value …` is the operator field change (#557). They run the **same core algorithm**; `--set` only adds a first step:

0. **(`--set` only) static pre-gate, then write.** First run each `field=value` through a static change-class check (D3): if **any** field is `immutable` or `recreate`, reject the **whole** command before touching a single byte of config — no partial write (resolved: pre-gate + reject-whole). Otherwise write each `field=value` into the deployed `module.json` — as `tappaas`, via `copy-update-json.sh` (ADR-019 ownership invariant: never under `sudo`, or the config becomes root-owned and drops out of the sweep, #525). The pre-gate catches only what is knowable statically (immutable/recreate); every downtime/one-way decision (`in-place-reboot`, `migrate`-not-live-OK, `grow-only` shrink) still happens in the converge, where live state is known.
1. pre-update **snapshot** (rollback point),
2. **3-way merge** the release source into config (release ⇄ `.orig` ⇄ deployed — a `--set` field that differs from `.orig` is now an intentional override, exactly the #550 "not tracking release on purpose" case). `modify` **never writes back to the repo/release source** (resolved): the deployed config is the only thing it edits, and Desired-drifting-from-Released is the *expected*, annotated state — not something to auto-sync.
3. **converge any drift** by running the module's own `update.sh` **and** every `dependsOn` provider's `update-service.sh`,
4. pre/post **`test-module.sh`**,
5. bump `updateTime`.

So `--set` introduces **no new apply path** — it seeds desired state into the JSON and lets the existing converge realize it. This keeps one algorithm for the release sweep and the field change, and keeps ADR-019's `modify --set node=…` naming.

**What ADR-020 changes is the converge itself, not the verb count.** Today each `update-service.sh` is an ad-hoc drift loop that only *happens* to handle some changes (it grows a disk, migrates a node) and silently mishandles others. Under D3/D4 each `update-service.sh` becomes **change-class-aware**: it consults the declared change class for every field it owns and does the right thing with a *changed* value — migrate the node, grow (not shrink) the disk, reboot for a subnet change, or **refuse** an immutable/recreate field with a clear failure the snapshot wrapper can roll back. That is the piece that makes pushing a field change through the normal sweep correct, which is why the operator's `--set` can safely reuse it.

This is ADR-007f layering applied to field changes: intent lives in `module.json`; the manager (`modify`) realizes it; the service scripts / controllers are the only things that touch the cluster.

> **On #557's all-or-nothing note.** The full `dependsOn` converge is *retained* (not scoped to the touched service). The all-or-nothing concern is instead answered by **idempotence + correct change handling**: a change-class-aware `update-service.sh` whose owned fields did not change is a no-op, and `reconcile.ts` already accumulates rather than aborts on a dep failure (so an unrelated provider's failure no longer blocks the others). The residual — a provider that can *never* converge (a hand-configured, powered-off appliance) still being *attempted* on every run — is a real edge this model does not by itself remove; see Resolved Question 6 (out of scope for v1).

### D3. The field-change taxonomy (change classes)

Every field a service owns is declared with one **change class**, describing what changing it *after install* costs. The taxonomy is drawn directly from what `cluster/services/vm/update-service.sh` already encodes — it is being *named and declared*, not invented:

| Change class | Meaning | `cluster:vm` examples | modify behavior |
|---|---|---|---|
| **immutable** | cannot change in place | `vmid`, `os`, `image*`, `cloudInit` | **refuse**: "change requires delete + reinstall." |
| **in-place** | safe live change | `cores`, `memory`, `cputype`, `vmtag`, `vmname`, `mac*`, `trunks*` | apply (a `qm set`); no downtime. |
| **in-place-reboot** | live change but needs a guest reboot to take effect | `bridge*`/`zone*` (new subnet → renew DHCP, re-register DNS) | apply with an acknowledged reboot (`--force` if the guest is protected). |
| **grow-only** | one-way; grow allowed, shrink not | `diskSize` (grow via `resize-disk.sh`) | grow applies; shrink is **refused** (needs manual/offline path). |
| **migrate** | change relocates or rebuilds runtime state | `node`, `HANode` | delegated to the service's migrate hook — **ADR-019** (live-OK vs `--force`, HA rule re-point). |
| **manual** | reconcilable only by an operator action the tool won't take silently | `storage` (move-disk) | **report + refuse**: name the manual step; never move a disk implicitly. |
| **recreate** | takes effect only at guest creation | `bios` (power-off / reinstall) | **refuse** without an explicit recreate flag. |

The classes compose with `--force`: `--force` upgrades an acknowledged-downtime change (in-place-reboot, migrate-not-live-OK) from *refuse* to *apply with downtime*; it never overrides **immutable** or **recreate** (those require delete+reinstall, a different verb). This mirrors ADR-019's rule of thumb — *never a silent disruptive fallback; downtime is always an explicit `--force`.*

### D4. The per-service field-change hook contract

Change semantics live **next to the code that performs them**, per `<provider>:<service>`, not in a central switch (larsrossen's #498 note). Each service directory declares the fields it owns and how to change each one:

- **A field manifest** — `services/<service>/fields.json` (resolved: a standalone file, adjacent to the hook scripts, so `validate` reads it without sourcing bash) declaring, for each field in the service's `usedBy` set, its **change class** (D3) and its **apply hook**. `module-fields.json.usedBy` already maps *field → service*; the manifest adds *(field, service) → (change class, hook)*. The change class is keyed by the **(field, service) pair** (resolved), not the field alone: `node` is `migrate` under `cluster:vm`, and the `cluster:vm` hook internally routes the HA-vs-non-HA case per ADR-019, so the manifest stays one entry per owning service. `validate` reads it: a `usedBy` field with no manifest entry, or a manifest naming a class the taxonomy doesn't define, is a config-schema error caught statically (a new lint, in the spirit of #549).
- **An apply hook** per changeable field or change-class. For `cluster:vm`, the operator's named example: `services/vm/update-node.sh` — the hook for `node`/`HANode` — **essentially calls the scripts ADR-019 defines** (the proxmox-controller migrate primitive, the HA-rule re-point, the live-OK compat test). `modify --set node=…` → manager plans class `migrate` → dispatches `cluster:vm`'s `update-node` hook → ADR-019 scenarios A-M*/B-M*. Simpler fields share one generic hook (a scoped `qm set` for the `in-place` class).

`update-service.sh` is **refactored to iterate the same manifest + hooks** (D2's step 3) rather than holding a bespoke drift loop. There is then exactly **one** converge path — driven by the manifest — shared by the release sweep (`modify`), the operator field change (`modify --set`), and `reconcile --apply`; and exactly one place per service where "how does field X change" is written. (This DRYs the acting side the way D1 DRYs the desired side.)

**D7 is the realized mechanics of this contract.** It moves the *diff itself* off the bash side entirely: the manager computes the single drift and hands it to the service to apply, so `update-service.sh` neither reads actual nor decides what changed — it applies a drift record. The manifest, classes and hooks named here are exactly what D7 wires together.

### D5. The verb model — three views of one pipeline

| Verb | Reads | Writes | Cluster | Contract |
|---|---|---|---|---|
| **validate** `[<m>]` | schema + config | — | none | static: does the config satisfy the schema + structural rules + manifest coverage? |
| **drift / reconcile** `<m>` (no `--apply`) | schema + config + live | — | read | Released · Desired · Actual, defaults resolved (#550), 3-way `.orig` note. |
| **modify** `<m> [--set field=value …]` | schema + config + live | config + cluster | write | one verb (D2). Bare = the release update `update-tappaas` calls. `--set` writes the field(s) first, then the *same* core algorithm runs: snapshot → 3-way merge → converge (module `update.sh` + every `dependsOn` `update-service.sh`, now change-class-aware) → test → `updateTime`. |
| **reconcile --apply** `<m>` | config + live | cluster | write | re-apply the *whole current* config (converge, no config change / snapshot / test). Shares the same manifest-driven converge (D4) — a lighter path over the same hooks. |

`modify` gains the `--set field=value` surface #557 asks for as a pre-step, not a new engine: an immutable/recreate `--set` is rejected by the **static pre-gate** before any write (D2 step 0); everything the converge can attempt is written into `module.json` (as `tappaas`, `copy-update-json.sh`) and realized by the existing core algorithm, with any remaining live-state refusal (shrink, downtime-without-`--force`) surfacing from the owning `update-service.sh` and rolled back by the snapshot wrapper.

### D6. Manager-agnostic — the same model closes #538

The planner/actor split, the change-class taxonomy, and the field-manifest contract are **not module-specific**. `network-manager` is the second implementer: a zone's policy fields (`access-to`, `pinhole-allowed-from`, `description`) get change classes (all **in-place** — a firewall rule swap, no downtime), a field manifest, and `network-manager modify <zone> --set pinhole-allowed-from=…` that validates before it writes — the "same shape the sibling managers already present" that #538 asks for, and the alternative to hand-editing `zones.json` that ADR-014 D1 named as the anti-pattern. Every manager that owns declared fields exposes `modify <entity> --set field=value` over this frame.

### D7. Realization — the manager owns the one differ; services *report* and *apply*

The diff lives in **one** place: the TS manager. Services never compute drift — they *report* their actual state in a consistent shape and *apply* the drift the manager hands back. This is what makes "one drift computation" (and #550's single-source invariant) literally true rather than aspirational.

**The manager pipeline (shared by `inspect` and `modify`):**

```
desired = module-manager module resolve <name>     # D1: merged config + schema defaults + .orig flags   [TS]
actual  = <provider>/report-service.sh <name>       # a JSON map { field: liveValue } for the manifest    [bash, per service]
drift   = diff(desired, actual)                     # declared normalization; THE one differ              [TS — inspect renders it, modify applies it]
          <provider>/update-service.sh <name> --apply-drift <drift.json> [--force]                        # [bash, pure apply]
```

**Each service provides four thin things** (nothing more):

| Artifact | Shape | Notes |
|---|---|---|
| `services/<svc>/fields.json` | the manifest (D3/D4): per field → `class`, `apply`, `normalize`, `inputs` | data; linted by `validate` |
| `services/<svc>/report-service.sh <name>` | prints `{ field: liveValue }` for its manifest fields | provider-specific **extract only** — no diff. **Reused** by `test-service.sh` and the health checks (one read, three consumers) — resolved decision. |
| `services/<svc>/update-service.sh <name> --apply-drift <file>` | applies the drift record: batches the `set` fields, dispatches the hooks | provider-specific **apply**; **retains any non-field-update logic it already had** (see migration discipline) |
| `services/<svc>/update-<field>.sh` | one complex field each (`update-node.sh`, `update-disk.sh`, `update-net.sh`) | uniform CLI + exit protocol below |

**Where every concern lives — nothing is implemented twice:**

| Concern | Home | Why single-copy |
|---|---|---|
| Resolve desired (defaults, `.orig`) | manager (TS) | `module-manager module resolve` |
| Normalize (declared `tags`/`trunks`/`vlan` rules) | manager (TS), applied to **both** sides | kills the `vm-net.sh` ↔ `inspect.ts` duplication (Decision 1) |
| Diff | manager (TS) | shared by `inspect` (render) + `modify` (apply) — the one differ (Decision 2) |
| Extract actual | service `report-service.sh` (bash) | provider-specific read; `inspect.ts` **gives up its own `qm config` parsing** and consumes this (approved) |
| Build & apply (netopts string, `qm set`, migrate) | service + hooks (bash) | apply-side only; the TS side never builds |

**The drift record** carries everything the bash apply needs, so it never re-reads or re-decides. For a composite field the manager assembles the finished desired value (it knows actual, so it preserves the live MAC/queues) and the hook just applies the string:

```jsonc
{ "cores": { "class": "in-place",  "liveKey": "cores", "desired": "8", "actual": "2" },
  "net0":  { "class": "in-place-reboot", "hook": "update-net.sh",
             "desired": "virtio=BC:..,bridge=lan,tag=210", "actual": "virtio=BC:..,bridge=lan,tag=200",
             "sideEffects": ["reboot","dns"] },
  "node":  { "class": "migrate", "hook": "update-node.sh", "desired": "tappaas3", "actual": "tappaas1" } }
```

**The shared runner** (`cicd/lib/converge-lib.sh`, one copy) parses the drift record → batches every `set` field into one `qm set` (batching preserved) → dispatches each hook → sequences side-effects **once** (one reboot+DNS pass even if `net0` and `net1` both changed) → aggregates exit codes. `update-service.sh --apply-drift` is a ~10-line wiring stub over it *plus* whatever non-field logic the service already carried.

**The hook CLI/exit protocol** (uniform across all `update-<field>.sh`, so the runner treats them identically and each is independently runnable/testable, the `test-migrate-vm.sh` pattern):

```
update-<field>.sh <name> --field <name> --desired <v> --actual <v> [--check] [--force]
```
`0` applied / already in sync · `10` would change but needs disruption authorization · `20` refused (immutable/shrink) · `1` error. `update-node.sh` is the ADR-019 bridge: it routes HA-vs-non-HA internally and maps A-M*/B-M* onto these codes.

**Migration discipline (a hard requirement of this ADR, not a nicety).** Every existing `update-service.sh` is migrated to this contract in the SAME change, and each migration must **preserve existing behaviour semantically** — the current scripts encode hard-won invariants (MAC/queue preservation, the single batched `qm set`, reboot→wait-IP→DNS ordering, HA deferral, ADR-019's guards). Before splitting a script, its behaviour is understood field-by-field and re-expressed as manifest entries + hooks with the same effect, kept green by its existing tests. **Any logic that is NOT field-update drift — setup, registration, side tasks a given `update-service.sh` performs beyond reconciling declared fields — stays in `update-service.sh`** around the `--apply-drift` call; it is not forced into the manifest/hook shape. The refactor extracts the field-drift loop, not the whole script.

### D8. Disruption authorization — decoupling reboot from the two `--force`s

`--force` means two different things and must not be conflated: on `module-manager module modify` it authorizes **disruption** (reboot / offline migrate); on `update-tappaas` it means **"run the sweep now"** (a scheduling override). Forwarding the sweep's `--force` as disruption authorization would let a routine update silently reboot production guests.

- **A per-module `rebootOk`** (new `module-fields.json` field, **default `false`**): "may an unattended converge reboot/disrupt this guest to apply a change?" It is a property of the *workload* (a stateless front-end: yes; a database: only in a window), hence per-module — resolved. The field's *change class* says a change **needs** disruption; `rebootOk` says whether we are **allowed** to do it unattended.
- **Disruption is authorized iff** `module modify --force` was passed **OR** (`rebootOk == true` **AND** we are in the ADR-017 scheduled reboot pass — the same signal that already authorizes node reboots). `update-tappaas --force` is **never** forwarded as disruption authorization.
- **When a disruptive change is not authorized:** apply all non-disruptive drift, **skip** the reboot/offline-migrate, and **defer with a warning** — the converge still **exits 0** (resolved: not a failure) and prints a machine-parseable `DEFERRED:` line that `update-tappaas` collects into an end-of-sweep "N modules have pending disruptive changes" summary:
  ```
  ⚠ nextcloud: net0 subnet change needs a reboot — deferred (rebootOk=false).
    Apply in a maintenance window:  module-manager module modify nextcloud --force
  ```
  Mechanically, a hook returning `10` (needs disruption) with authorization absent is treated as **deferred, not failed**.

Three distinct levers that no longer collide: `update-tappaas --force` (schedule), `module modify --force` (authorize disruption now), `module.rebootOk` (standing per-module authorization for the scheduled pass).

## Scenarios (module-manager)

Let *live-OK* be as in ADR-019 (the CPU-compat verdict for a migrate). `--force` = acknowledged downtime.

| # | `modify` invocation | Class | Behavior |
|---|---|---|---|
| M1 | `--set cores=8` | in-place | `qm set`; no downtime; config rewritten. |
| M2 | `--set diskSize=64G` (grow) | grow-only | `resize-disk.sh`; config rewritten. |
| M3 | `--set diskSize=16G` (shrink) | grow-only | `cluster:vm`'s converge **refuses**: "disk shrink is not reconcilable in place"; snapshot wrapper rolls back. |
| M4 | `--set zone0=iot` | in-place-reboot | refuse without `--force` (subnet change reboots the guest); with `--force`: apply + reboot + DHCP + DNS re-register. |
| M5 | `--set node=tappaas3`, live-OK | migrate | `.node` written; converge's `update-node` hook → ADR-019 A-M1/B-M2 (migrate + rule re-point). |
| M6 | `--set node=tappaas3`, not live-OK, no `--force` | migrate | converge **refuses**: "moving to tappaas3 needs downtime — rerun with `--force`" (ADR-019 A-M2). |
| M7 | `--set vmid=250` | immutable | **static pre-gate rejects** before any write: "vmid cannot change in place — delete + reinstall." Config untouched. |
| M8 | `--set description=…` / a `dependsOn` fix (no cluster field) | (config-only) | field written; converge is a no-op on the cluster; the corrected config is now authoritative. The bare #557 case — correct a policy-only field without reinstall. |
| M9 | `--set proxyPort=8443` while the same module's `cluster:vm` carries unrelated pre-existing drift | in-place (network:proxy) | full converge runs: `network:proxy` applies the port; `cluster:vm`'s change-class-aware `update-service.sh` re-attempts its own drift too (not scoped away). Its owned fields' correctness is the point of D3; the residual "a provider that can never converge is still attempted" is deferred — Resolved Question 6 (out of scope for v1). |

Two refusal points (D2 step 0): the **static pre-gate** rejects `immutable`/`recreate` (M7) before any write, so config is never left ahead of reality for those; the **converge** rejects the live-state cases it can only know at apply time (M3 shrink, M6 downtime-without-`--force`), after the write, and the snapshot wrapper rolls back. A mixed `--set` with any pre-gated field is rejected whole, before writing anything.

## Testing (fast + `--deep`)

Two tiers (ADR-013 / `TESTING.md`), mirroring ADR-019's structure:

- **Fast (offline, default).** Unit-test the pure core: the desired-state resolver (D1) — one input, one value, for validate/drift/modify alike (a resolver mutation must turn *all three* red, proving the single-source invariant); the planner (D2/D3) — assert the class verdict per field (M1–M9) against a fake actual, with the apply hooks stubbed to a command log; the manifest lint (D4) — a `usedBy` field with no manifest entry, or an unknown class, fails `validate`. Keep the **mutation-testing** discipline: strip one guarantee (the shrink refusal, the immutable refusal, the scoping in M9) and confirm the *specific* assertion, and only it, goes red.
- **Deep (`--deep`, live, disposable fixture).** `modify --set cores` and `--set diskSize` (grow) against a throwaway VM; assert live values change and config is rewritten. The `migrate` class reuses ADR-019's deep migrate fixture (do not duplicate it — `modify --set node` is the caller of that path).

## Implementation plan

Sequenced so each phase is independently shippable, keeps the tree green, and defers the risky bulk (the 25-script migration) until the machinery is proven on one provider. **Scope measured:** `lib/ts` lives at `src/foundation/tappaas-cicd/lib/ts/`; the resolver embryo is `appliedDefault`/`resolveField` in `inspect.ts` (856 lines); the `cfg()` default ladder is in `cluster/services/vm/update-service.sh` (460 lines); shared bash foundations already exist (`get_config_value`/`normalize_module_config` in `common-install-routines.sh`, `vmnet_build_netopts`/`vmnet_parse` in `cluster/lib/vm-net.sh`); **25 `update-service.sh` scripts** must migrate (17 foundation + 8 apps). `report-service.sh`, `converge-lib.sh`, `fields.json`, and the `resolve` verb are all net-new.

| Phase | Deliverables | Tests (gate to the next phase) |
|---|---|---|
| **P0 — Manifest + schema foundations** (no runtime change) | `fields.json` JSON-schema + the `cluster:vm` reference manifest; the change-class vocabulary; add `rebootOk` to `module-fields.json`; `validate` manifest-coverage lint (a `usedBy` field with no manifest entry, or an unknown class, errors). | New `validate.ts` unit cases; existing suites unchanged. Exit: `validate` lints manifests; behaviour identical. |
| **P1 — One resolver** | Lift `appliedDefault`/`resolveField` out of `inspect.ts` into `lib/ts` (`desired.ts`); add the **`module-manager module resolve <name>`** verb (resolved config + defaults + `.orig` flags); `inspect.ts` consumes it. | Resolver unit tests shared by `inspect` + `resolve`; **mutation:** one resolver change turns both red. Exit: #550 closed on the desired side, one copy. |
| **P2 — One differ + `report-service.sh` (read side)** | `report-service.sh` contract + `cluster:vm/report-service.sh` (extract via `vm-net.sh`); move normalize+diff into the manager (TS); the drift-record format; `inspect.ts` **drops its `qm config` parsing** and renders the shared differ's output. | `inspect.test.ts` reworked against the differ + a fake `report-service.sh`; assert byte-identical report to today on the fixtures. Exit: literally one drift computation, shared by inspect + (P4) modify. |
| **P3 — Apply side on `cluster:vm`** | `cicd/lib/converge-lib.sh` (the runner); split `cluster/services/vm/update-service.sh` → `--apply-drift` + `update-node.sh` / `update-disk.sh` / `update-net.sh`; delete the `cfg()` ladder; `update-node.sh` calls the ADR-019 primitive. | **Every existing `cluster/vm` test stays green** (MAC/queue preserve, single `qm set`, reboot→IP→DNS order, HA deferral, ADR-019 guards); hook tests use the `test-migrate-vm.sh` stub shape; deep tier per the Testing section. Exit: `cluster:vm` converges via manifest on both `modify` and `reconcile --apply`. |
| **P4 — `modify --set` + pre-gate + disruption** | `--set field=value` (write via `copy-update-json.sh`) + static pre-gate (immutable/recreate reject-whole); `rebootOk` authorization + deferral (exit 0 + `DEFERRED:` line); `update-tappaas` collects deferrals into an end-of-sweep summary and never forwards its own `--force`. | Scenario matrix M1–M9 as unit tests (hooks stubbed to a log); a deferral test (rebootOk=false → non-disruptive applied, disruptive deferred, exit 0). Exit: **#498/#557 closed for `cluster:vm`.** |
| **P5 — Roll out to the other 24 scripts + network-manager** | Migrate remaining `update-service.sh`, **thin ones first** (identity 14–19, backup 48–64, network dns/rules/discovery 15–57, templates 31) to shake out the runner, then the heavy ones (`network:proxy` 290, `cluster:ha` 368, `cluster:lxc` 218, `nextcloud:fileservice` 196), then the 8 app services. Add `network-manager modify <zone> --set` (#538, the second-manager proof). **Each migration preserves semantics and retains non-field logic (D7).** | Per-script existing `test-service.sh`/module `test.sh` stay green; `network-manager` gets the #538 modify tests. Exit: all 25 on the contract; `validate` green fleet-wide. |
| **P6 — Docs + dead-code sweep** | Documentation updates (next section); delete the now-dead twins (`inspect.ts` parsing, `vm-net.sh` compare/normalize helpers, per-script `cfg()` ladders); regenerate `DEPENDENCIES.md`. | Doc-lint / link check; `grep` proves no second copy of resolve/normalize/diff survives. Exit: v1 complete. |

**Test strategy (ties to the existing suites).** Fast tier extends the current TS unit suites (`module/inspect/reconcile/cluster/cli.test.ts`) with the `fake-client.ts` injection already in place; the bash side reuses the `test-migrate-vm.sh` source-and-stub-`ssh` pattern for hooks and each provider's existing `test-service.sh` as the semantic-preservation gate. The **mutation discipline** (ADR-019) carries over: strip one guarantee (a shrink refusal, a `strict`-rule carry-over, the resolver default) and confirm the one specific assertion — and only it — goes red.

## Documentation impact

Per ADR-013 (one home per doc, by audience+lifecycle; module `README` = public web page, `DESIGN` = internal, realization/how-to → `docs/design/`):

| File | Change | Audience / why |
|---|---|---|
| `docs/ADR/ADR-020 …` (this) | the decision record | durable; stays in `docs/ADR/` |
| **`docs/design/adr-020-field-change-realization.md`** (NEW) | the how-it's-built companion: manifest format, `report-service.sh`/`--apply-drift`/hook contracts, `converge-lib.sh`, the migration playbook for the 25 scripts | developers; ADR-013 §2 routes realization/how-to here, not into the ADR |
| `…/module-manager/DESIGN.md` | rewrite the **service contract** section: `report-service.sh` + `fields.json` + `--apply-drift` + hooks replace the "every service ships an `update-service.sh` converge" wording; document the one-differ pipeline and `module resolve`; clear the "schema check pending" TODO | developers (internal, not web-synced) |
| `…/module-manager/README.md` | operator surface: `modify <m> --set field=value`, the change classes, `--force` vs `rebootOk`, the deferral message | end users — **web-synced to tappaas.org** (ADR-013 §6), so keep it operator-facing |
| `src/foundation/schemas/module-fields.json` | add `rebootOk` (+ description); add the change-class/normalize vocabulary the manifests reference; touch affected per-field `description`s | schema SSOT — read by tooling and humans |
| `src/foundation/schemas/README.md` | note `modify --set` / change classes / the `fields.json` manifest alongside the existing "admins drive verbs, not JSON" framing | reference, next to the schema |
| `src/foundation/TESTING.md` | add coverage rows for `report-service.sh`, `--apply-drift`, `converge-lib.sh`, the deferral path | cross-component test view |
| `src/apps/00-Template/` (`README-template.md`, `README-install-sh.md`, + a **new `fields.json` + `report-service.sh` template**) | the normative module templates must show the new service-contract shape a provider author copies | template authors (ADR-013 §4 "documentation-complete") |
| `src/foundation/DEPENDENCIES.md` | **regenerated**, not hand-edited (the `tappaas-generate-script-dependencies` skill) — new `report-service.sh`/`converge-lib.sh`/`fields.json` edges surface here | generated reference |
| `docs/ADR/README.md` | refresh the ADR-020 index row to mention the realization (D7/D8) | index |

Not touched: `docs/Architecture/` SSOT (no taxonomy change — this refines *realization*, not the model). The module/service contract has **no current home in `docs/`** — it lives only in the module-manager `DESIGN.md`/`README.md` — so the new `docs/design/` doc is the first consolidated statement of it.

## Consequences

- **Positive.** One desired-state definition and one change-semantics home per service → validate/drift/reconcile/modify cannot silently disagree (the general form of #549/#550). Operators get a sanctioned `modify --set` for every declared field (#557) instead of hand-editing deployed config or reinstalling — over the *same* algorithm `update-tappaas` already trusts, so there is no second apply engine to keep in sync. The change taxonomy is declared and lint-checked, so a new provider states its field semantics instead of hiding them in an imperative loop, and `update-service.sh` handles a *changed* field correctly instead of by accident. The frame generalizes to `network-manager` (#538) and any future manager. ADR-019's `node` change becomes one hook in that frame rather than a special case.
- **Cost.** Real work: lift the resolver into `module-manager module resolve`; move normalize+diff into the manager and delete `inspect.ts`'s own `qm config` parsing; author `fields.json` + `report-service.sh` per existing service; split each `update-service.sh` into `--apply-drift` + hooks; add the `--set` pre-step, `rebootOk`, and the disruption/deferral plumbing. **Every existing `update-service.sh` must be migrated with behaviour preserved and its non-field logic retained (D7 migration discipline)** — the largest and most delicate part of the work, gated by keeping each script's existing tests green.
- **Cross-cutting benefit.** `report-service.sh` gives every service one honest actual-state read, reused by `modify`, `inspect`/`reconcile`, `test-service.sh` and the health checks — so those four stop each having their own idea of "what is actually running."
- **Not solved by this ADR.** The full `dependsOn` converge is retained (D2), so #557's deeper edge — a provider that can *never* converge being *attempted* on every `modify` — is mitigated (idempotence, accumulate-don't-abort) but not removed; see Resolved Question 6 (out of scope for v1).
- **Neutral / superseded.** `modify`'s current "only `--environment`" surface is *extended* by `--set field=value` (same verb, same core). `reconcile --apply` is unchanged in contract, but shares the new manifest-driven converge.

## Resolved questions (v0.3–v0.4)

All decided; the resolutions are folded into the decisions above and restated here for the record. Items 1–7 were settled in v0.3; 8–11 in v0.4 (realization).

1. **Manifest location & format → `fields.json`.** The manifest is a standalone `services/<service>/fields.json` adjacent to the hook scripts — machine-clean, so `validate` reads it without sourcing bash. Not a header block in `update-service.sh`.
2. **Change class keyed by the (field, service) pair.** Not the field alone. `node` is `migrate` under `cluster:vm`; the `cluster:vm` hook routes the HA-vs-non-HA case internally per ADR-019, so the manifest stays one entry per owning service.
3. **`--set` never writes the repo/release source.** `modify` edits only the *deployed* config (the authority, per #557). Desired drifting from Released is the **expected**, annotated state (#550's "not tracking release on purpose") — it is reported, never auto-synced back to the module's git source.
4. **Static pre-gate for `immutable`/`recreate`.** Before writing, `modify` checks each `--set` field's change class and rejects an `immutable`/`recreate` change up front, so config is never left ahead of reality for a change the converge could only refuse afterward. Every downtime/one-way decision (`in-place-reboot`, `migrate`-not-live-OK, `grow-only` shrink) still happens in the converge, where live state is known.
5. **Reject the whole command on a mixed set.** `modify --set a=… --set b=…` where any field is pre-gated (or otherwise rejectable up front) rejects the **entire** command before writing anything — no partial write across one `modify`, so config and cluster always move together.
6. **The never-converge provider is out of scope for v1.** A `dependsOn` provider describing a hand-configured, powered-off appliance can never converge, yet the retained full sweep still attempts it on every `modify`. No per-dependency "do-not-converge" marker is introduced now; the accumulate-don't-abort behaviour (`reconcile.ts`) keeps it from blocking other providers. Revisit only if it bites in practice.
7. **Shared `lib/ts` core.** The desired-state resolver (D1) and the manifest-driven converge core live in `lib/ts`, shared by `module-manager` and `network-manager`; each manager supplies its own per-service manifests.
8. **Actual-state read → a dedicated `report-service.sh`.** Not a mode of `update-service.sh` and not folded into `test-service.sh`. A standalone per-service reporter, reused by `modify`, `inspect`/`reconcile`, `test-service.sh` and the health checks (D7).
9. **`rebootOk` is a per-module config field.** Not per-field. Default `false` (D8).
10. **A deferred disruptive change exits 0.** The converge is not marked failed; it prints a `DEFERRED:` line that `update-tappaas` summarizes at end of sweep (D8).
11. **`inspect.ts` gives up its own actual parsing.** It consumes `report-service.sh` like `modify` does, so there is genuinely one actual-state read and one differ (D7). This touches current `inspect.ts` code and is explicitly in scope.
