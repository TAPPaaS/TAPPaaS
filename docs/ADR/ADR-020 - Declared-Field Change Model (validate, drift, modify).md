# ADR-020 — Declared-Field Change Model (validate · drift · modify)

| | |
|---|---|
| **Status** | **Proposed / Draft** — design pass for #498. No code yet; this is the "decide in writing first" artifact. |
| **Version** | 0.2 |
| **Date** | 2026-09-02 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007f Realization](<ADR-007f - Realization.md>) (managers orchestrate / **plan**; controllers + service scripts do the imperative **act**) |
| **Refines** | [ADR-004 Module catalog & config cascade](<ADR-004-module-catalog-config-cascade.md>) (where a field's desired value comes from), [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates — the unit that owns a field's change semantics) |
| **Instantiated by** | [ADR-019 HA and Cross-Node VM Migration Policy](<ADR-019 - HA and Cross-Node VM Migration Policy.md>) — the `cluster:vm` `node`/`HANode` change is the first and hardest concrete change-hook; ADR-019 defines its policy, this ADR defines the frame it plugs into. |
| **Closes / addresses** | **#498** (modify cannot change config values — the parent design issue), **#557** (modify edits only `--environment`; deployed config is authoritative; reconcile --apply is all-or-nothing across `dependsOn`), **#538** (network-manager has no `modify` for a zone's policy fields — the sibling-manager instance of the same gap). Builds on the just-closed **#549** (validate must enforce the same rules as reconcile) and **#550** (one schema-driven desired-state resolver, done on the *reporting* side — this ADR extends it to the *acting* side, exactly as #550's closing note deferred to #498). |
| **Numbering note** | ADR-018 reserved by the SSH-identity PR #523; ADR-019 is HA/migration. This is **020**. |
| **Changelog** | v0.1 initial draft: the planner/actor split, the change-class taxonomy, the per-service field-change hook contract. v0.2 (operator decision): **one** `modify` verb — `--set` writes the field into config first, then the *unchanged* core modify algorithm runs (3-way merge → converge via the module's own `update.sh` + every `dependsOn` `update-service.sh`). ADR-020's job is to make that converge field-change-aware, not to add a second scoped apply path. |

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

> **Invariant (generalizes #549 + #550):** validate, drift, reconcile and modify derive every field's desired value, and every structural rule, from **one schema (`module-fields.json`) + one resolver**. Any intentional difference between two paths is *stated in the schema*, never an incidental artifact of a second code copy.

### D2. One `modify` verb — `--set` writes config first, then the *unchanged* core algorithm runs

There is **one** `modify` verb, not two. `modify <m>` is exactly the release update `update-tappaas` already calls per module (via `module-manager module modify <m>` → `update-module.sh`). `modify <m> --set field=value …` is the operator field change (#557). They run the **same core algorithm**; `--set` only adds a first step:

0. **(`--set` only)** write each `field=value` into the deployed `module.json` **first** — as `tappaas`, via `copy-update-json.sh` (ADR-019 ownership invariant: never under `sudo`, or the config becomes root-owned and drops out of the sweep, #525).
1. pre-update **snapshot** (rollback point),
2. **3-way merge** the release source into config (release ⇄ `.orig` ⇄ deployed — a `--set` field that differs from `.orig` is now an intentional override, exactly the #550 "not tracking release on purpose" case),
3. **converge any drift** by running the module's own `update.sh` **and** every `dependsOn` provider's `update-service.sh`,
4. pre/post **`test-module.sh`**,
5. bump `updateTime`.

So `--set` introduces **no new apply path** — it seeds desired state into the JSON and lets the existing converge realize it. This keeps one algorithm for the release sweep and the field change, and keeps ADR-019's `modify --set node=…` naming.

**What ADR-020 changes is the converge itself, not the verb count.** Today each `update-service.sh` is an ad-hoc drift loop that only *happens* to handle some changes (it grows a disk, migrates a node) and silently mishandles others. Under D3/D4 each `update-service.sh` becomes **change-class-aware**: it consults the declared change class for every field it owns and does the right thing with a *changed* value — migrate the node, grow (not shrink) the disk, reboot for a subnet change, or **refuse** an immutable/recreate field with a clear failure the snapshot wrapper can roll back. That is the piece that makes pushing a field change through the normal sweep correct, which is why the operator's `--set` can safely reuse it.

This is ADR-007f layering applied to field changes: intent lives in `module.json`; the manager (`modify`) realizes it; the service scripts / controllers are the only things that touch the cluster.

> **On #557's all-or-nothing note.** The full `dependsOn` converge is *retained* (not scoped to the touched service). The all-or-nothing concern is instead answered by **idempotence + correct change handling**: a change-class-aware `update-service.sh` whose owned fields did not change is a no-op, and `reconcile.ts` already accumulates rather than aborts on a dep failure (so an unrelated provider's failure no longer blocks the others). The residual — a provider that can *never* converge (a hand-configured, powered-off appliance) still being *attempted* on every run — is a real edge this model does not by itself remove; see Open Question 6.

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

- **A field manifest** — `services/<service>/fields.json` (or a structured header block in `update-service.sh`) declaring, for each field in the service's `usedBy` set, its **change class** (D3) and its **apply hook**. `module-fields.json.usedBy` already maps *field → service*; the manifest adds *field → (change class, hook)*. `validate` reads it: a `usedBy` field with no manifest entry, or a manifest naming a class the taxonomy doesn't define, is a config-schema error caught statically (a new lint, in the spirit of #549).
- **An apply hook** per changeable field or change-class. For `cluster:vm`, the operator's named example: `services/vm/update-node.sh` — the hook for `node`/`HANode` — **essentially calls the scripts ADR-019 defines** (the proxmox-controller migrate primitive, the HA-rule re-point, the live-OK compat test). `modify --set node=…` → manager plans class `migrate` → dispatches `cluster:vm`'s `update-node` hook → ADR-019 scenarios A-M*/B-M*. Simpler fields share one generic hook (a scoped `qm set` for the `in-place` class).

`update-service.sh` is **refactored to iterate the same manifest + hooks** (D2's step 3) rather than holding a bespoke drift loop. There is then exactly **one** converge path — driven by the manifest — shared by the release sweep (`modify`), the operator field change (`modify --set`), and `reconcile --apply`; and exactly one place per service where "how does field X change" is written. (This DRYs the acting side the way D1 DRYs the desired side.)

### D5. The verb model — three views of one pipeline

| Verb | Reads | Writes | Cluster | Contract |
|---|---|---|---|---|
| **validate** `[<m>]` | schema + config | — | none | static: does the config satisfy the schema + structural rules + manifest coverage? |
| **drift / reconcile** `<m>` (no `--apply`) | schema + config + live | — | read | Released · Desired · Actual, defaults resolved (#550), 3-way `.orig` note. |
| **modify** `<m> [--set field=value …]` | schema + config + live | config + cluster | write | one verb (D2). Bare = the release update `update-tappaas` calls. `--set` writes the field(s) first, then the *same* core algorithm runs: snapshot → 3-way merge → converge (module `update.sh` + every `dependsOn` `update-service.sh`, now change-class-aware) → test → `updateTime`. |
| **reconcile --apply** `<m>` | config + live | cluster | write | re-apply the *whole current* config (converge, no config change / snapshot / test). Shares the same manifest-driven converge (D4) — a lighter path over the same hooks. |

`modify` gains the `--set field=value` surface #557 asks for as a pre-step, not a new engine: the field is written into `module.json` (as `tappaas`, `copy-update-json.sh`) and the existing core algorithm realizes it. An immutable/recreate field surfaces as a converge-time refusal from its owning `update-service.sh`, rolled back by the snapshot wrapper (see Open Question 4 on whether a pre-write `validate` should reject such a `--set` before touching the JSON at all).

### D6. Manager-agnostic — the same model closes #538

The planner/actor split, the change-class taxonomy, and the field-manifest contract are **not module-specific**. `network-manager` is the second implementer: a zone's policy fields (`access-to`, `pinhole-allowed-from`, `description`) get change classes (all **in-place** — a firewall rule swap, no downtime), a field manifest, and `network-manager modify <zone> --set pinhole-allowed-from=…` that validates before it writes — the "same shape the sibling managers already present" that #538 asks for, and the alternative to hand-editing `zones.json` that ADR-014 D1 named as the anti-pattern. Every manager that owns declared fields exposes `modify <entity> --set field=value` over this frame.

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
| M7 | `--set vmid=250` | immutable | converge **refuses**: "vmid cannot change in place — delete + reinstall." |
| M8 | `--set description=…` / a `dependsOn` fix (no cluster field) | (config-only) | field written; converge is a no-op on the cluster; the corrected config is now authoritative. The bare #557 case — correct a policy-only field without reinstall. |
| M9 | `--set proxyPort=8443` while the same module's `cluster:vm` carries unrelated pre-existing drift | in-place (network:proxy) | full converge runs: `network:proxy` applies the port; `cluster:vm`'s change-class-aware `update-service.sh` re-attempts its own drift too (not scoped away). Its owned fields' correctness is the point of D3; the residual "a provider that can never converge is still attempted" is Open Question 6. |

With `--set`, the field is written to `module.json` **before** the converge (D2 step 0), so a converge-time refusal (M3/M6/M7) leaves config ahead of reality until rolled back or corrected — which is why Open Question 4 asks whether a pre-write `validate` should reject an obviously-immutable `--set` before it touches the JSON.

## Testing (fast + `--deep`)

Two tiers (ADR-013 / `TESTING.md`), mirroring ADR-019's structure:

- **Fast (offline, default).** Unit-test the pure core: the desired-state resolver (D1) — one input, one value, for validate/drift/modify alike (a resolver mutation must turn *all three* red, proving the single-source invariant); the planner (D2/D3) — assert the class verdict per field (M1–M9) against a fake actual, with the apply hooks stubbed to a command log; the manifest lint (D4) — a `usedBy` field with no manifest entry, or an unknown class, fails `validate`. Keep the **mutation-testing** discipline: strip one guarantee (the shrink refusal, the immutable refusal, the scoping in M9) and confirm the *specific* assertion, and only it, goes red.
- **Deep (`--deep`, live, disposable fixture).** `modify --set cores` and `--set diskSize` (grow) against a throwaway VM; assert live values change and config is rewritten. The `migrate` class reuses ADR-019's deep migrate fixture (do not duplicate it — `modify --set node` is the caller of that path).

## Consequences

- **Positive.** One desired-state definition and one change-semantics home per service → validate/drift/reconcile/modify cannot silently disagree (the general form of #549/#550). Operators get a sanctioned `modify --set` for every declared field (#557) instead of hand-editing deployed config or reinstalling — over the *same* algorithm `update-tappaas` already trusts, so there is no second apply engine to keep in sync. The change taxonomy is declared and lint-checked, so a new provider states its field semantics instead of hiding them in an imperative loop, and `update-service.sh` handles a *changed* field correctly instead of by accident. The frame generalizes to `network-manager` (#538) and any future manager. ADR-019's `node` change becomes one hook in that frame rather than a special case.
- **Cost.** Real work: lift the resolver out of `inspect.ts`; author a field manifest per existing service; refactor each `update-service.sh` from a bespoke drift loop into a manifest-driven, change-class-aware converge (must keep every ADR-019 regression guard green); add the `--set` pre-step + CLI surface. The acting bash scripts must consume manager-resolved desired values instead of their own `cfg()` defaults.
- **Not solved by this ADR.** The full `dependsOn` converge is retained (D2), so #557's deeper edge — a provider that can *never* converge being *attempted* on every `modify` — is mitigated (idempotence, accumulate-don't-abort) but not removed; see Open Question 6.
- **Neutral / superseded.** `modify`'s current "only `--environment`" surface is *extended* by `--set field=value` (same verb, same core). `reconcile --apply` is unchanged in contract, but shares the new manifest-driven converge.

## Open questions

1. **Manifest location & format.** A standalone `services/<service>/fields.json`, or a declared header block parsed out of `update-service.sh`? The former is machine-clean and lets `validate` read it without sourcing bash; the latter keeps class + code literally adjacent. *Draft: `fields.json`, adjacent to the hook scripts.*
2. **Change class per (field, service) vs per field.** `node` is `migrate` under `cluster:vm` but is *deferred to `cluster:ha`* when the module is HA (update-service.sh today). Is change class a property of the field alone, or of the (field, owning-service) pair, or does the owning service resolve HA-vs-non-HA internally in its `update-node` hook? *Draft: the pair; the `cluster:vm` `update-node` hook internally routes HA per ADR-019, so the manifest stays one entry.*
3. **`--set` and the git source.** `modify` rewrites the *deployed* config (the authority, per #557). Does it also propagate to the git module source, or is drifting Desired-off-Released the expected, annotated state (#550's "not tracking release on purpose")? *Draft: deployed only; Released divergence is reported, not auto-synced — consistent with #550.*
4. **Pre-write validate vs converge-time refusal.** `--set` writes the JSON *before* the converge (D2 step 0), so an immutable/recreate `--set` leaves config ahead of reality until the converge refuses and the snapshot rolls back. Should `modify` run the field's change class through `validate` **before** the write and reject an obviously-immutable `--set` up front — keeping set-first for everything the converge can actually attempt? *Draft: yes — a cheap static pre-gate for the `immutable`/`recreate` classes only; every downtime/one-way decision (`--force`) still happens in the converge where live state is known.*
5. **Multi-field atomicity.** `modify --set a=… --set b=…` where `a` is in-place and `b` is refused — write+apply `a` and report `b`, or reject the whole set before writing anything? *Draft: reject-whole at the pre-gate (OQ4) — no partial write across one `modify`, so config and cluster move together.*
6. **The never-converge provider (#557 residual).** A `dependsOn` provider describing a hand-configured, powered-off appliance can never converge, yet the retained full sweep attempts it on every `modify`. Do we need a per-dependency "advisory / do-not-converge" marker (a manifest flag on the *dependency*, not the field) so the sweep skips-and-reports it instead of failing? *Draft: out of scope for v1; revisit if it bites in practice — the accumulate-don't-abort behaviour keeps it from blocking other providers meanwhile.*
7. **network-manager sharing.** Does the resolver/converge core live in `lib/ts` shared by both managers, or is it duplicated per manager with a shared *contract* only? *Draft: shared `lib/ts` core, per-manager manifests.*
