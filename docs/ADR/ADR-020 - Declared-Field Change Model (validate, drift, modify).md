# ADR-020 — Declared-Field Change Model (validate · drift · modify)

| | |
|---|---|
| **Status** | **Proposed / Draft** — design pass for #498. No code yet; this is the "decide in writing first" artifact. |
| **Version** | 0.1 |
| **Date** | 2026-09-02 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007f Realization](<ADR-007f - Realization.md>) (managers orchestrate / **plan**; controllers + service scripts do the imperative **act**) |
| **Refines** | [ADR-004 Module catalog & config cascade](<ADR-004-module-catalog-config-cascade.md>) (where a field's desired value comes from), [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates — the unit that owns a field's change semantics) |
| **Instantiated by** | [ADR-019 HA and Cross-Node VM Migration Policy](<ADR-019 - HA and Cross-Node VM Migration Policy.md>) — the `cluster:vm` `node`/`HANode` change is the first and hardest concrete change-hook; ADR-019 defines its policy, this ADR defines the frame it plugs into. |
| **Closes / addresses** | **#498** (modify cannot change config values — the parent design issue), **#557** (modify edits only `--environment`; deployed config is authoritative; reconcile --apply is all-or-nothing across `dependsOn`), **#538** (network-manager has no `modify` for a zone's policy fields — the sibling-manager instance of the same gap). Builds on the just-closed **#549** (validate must enforce the same rules as reconcile) and **#550** (one schema-driven desired-state resolver, done on the *reporting* side — this ADR extends it to the *acting* side, exactly as #550's closing note deferred to #498). |
| **Numbering note** | ADR-018 reserved by the SSH-identity PR #523; ADR-019 is HA/migration. This is **020**. |
| **Changelog** | v0.1 initial draft: the planner/actor split, the change-class taxonomy, the per-service field-change hook contract, and the scoped `modify` that closes #557's all-or-nothing edge. |

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

### D2. Planner / actor split — the manager plans, the service acts

The manager is the **planner**; the `<provider>:<service>` scripts are the **actors**. For any field change the manager:

1. **resolves** desired state (D1),
2. **reads** actual state and computes drift (the existing `inspect` differ),
3. **classifies** each changed field by its owning service's *change class* (D3),
4. **plans** — produces a per-field verdict (apply / needs-`--force` / refuse), and
5. **dispatches** each change to the owning service's apply hook (D4), **scoped to only the services whose fields changed**.

Step 5's scoping is the fix for #557's all-or-nothing edge: `modify` touches only the service(s) owning the changed fields, never a blanket `dependsOn` sweep. (`reconcile --apply` — a *converge of the whole current config* — keeps its full sweep; it is a different verb with a different contract.)

This is the ADR-007f layering applied to field changes: intent lives in `module.json`; the manager realizes it; the service script / controller is the only thing that touches the cluster. It also carries ADR-019's **ownership invariant** — `modify` rewrites `module.json` via `copy-update-json.sh` as `tappaas`, never under `sudo`, or the config becomes root-owned and silently drops out of the update sweep (#525).

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

`update-service.sh` (the whole-config converge that `reconcile --apply` calls) is **refactored to iterate the same manifest + hooks** rather than holding a bespoke drift loop — so the converge path and the modify path apply a given field through the *same* code, and there is one place per service where "how does field X change" is written. (This DRYs the acting side the way D1 DRYs the desired side.)

### D5. The verb model — three views of one pipeline

| Verb | Reads | Writes | Cluster | Contract |
|---|---|---|---|---|
| **validate** `[<m>]` | schema + config | — | none | static: does the config satisfy the schema + structural rules + manifest coverage? |
| **drift / reconcile** `<m>` (no `--apply`) | schema + config + live | — | read | Released · Desired · Actual, defaults resolved (#550), 3-way `.orig` note. |
| **modify** `<m> --set field=value …` | schema + config + live | config + cluster | write | change declared field(s): plan by change class (D3), apply via owning service hook (D4), **scoped** to touched services (D2), inside the snapshot+test wrapper. |
| **reconcile --apply** `<m>` | config + live | cluster | write | re-apply the *whole current* config (converge). Unchanged; distinct from modify (no config change, full `dependsOn` sweep). |

`modify` gains the `--set field=value` surface #557 asks for. It rewrites `module.json` (as `tappaas`, `copy-update-json.sh`) **and** drives the change action the class implies — refusing before it writes for an immutable/manual/recreate field, so the deployed config and reality never disagree.

### D6. Manager-agnostic — the same model closes #538

The planner/actor split, the change-class taxonomy, and the field-manifest contract are **not module-specific**. `network-manager` is the second implementer: a zone's policy fields (`access-to`, `pinhole-allowed-from`, `description`) get change classes (all **in-place** — a firewall rule swap, no downtime), a field manifest, and `network-manager modify <zone> --set pinhole-allowed-from=…` that validates before it writes — the "same shape the sibling managers already present" that #538 asks for, and the alternative to hand-editing `zones.json` that ADR-014 D1 named as the anti-pattern. Every manager that owns declared fields exposes `modify <entity> --set field=value` over this frame.

## Scenarios (module-manager)

Let *live-OK* be as in ADR-019 (the CPU-compat verdict for a migrate). `--force` = acknowledged downtime.

| # | `modify` invocation | Class | Behavior |
|---|---|---|---|
| M1 | `--set cores=8` | in-place | `qm set`; no downtime; config rewritten. |
| M2 | `--set diskSize=64G` (grow) | grow-only | `resize-disk.sh`; config rewritten. |
| M3 | `--set diskSize=16G` (shrink) | grow-only | **refuse** before writing: "disk shrink is not reconcilable in place." |
| M4 | `--set zone0=iot` | in-place-reboot | refuse without `--force` (subnet change reboots the guest); with `--force`: apply + reboot + DHCP + DNS re-register. |
| M5 | `--set node=tappaas3`, live-OK | migrate | rewrite `.node`; dispatch `update-node` → ADR-019 A-M1/B-M2 (migrate + rule re-point). |
| M6 | `--set node=tappaas3`, not live-OK, no `--force` | migrate | **refuse**: "moving to tappaas3 needs downtime — rerun with `--force`" (ADR-019 A-M2). |
| M7 | `--set vmid=250` | immutable | **refuse**: "vmid cannot change in place — delete + reinstall." |
| M8 | `--set dependsOn+=…` / `--set description=…` (no cluster field) | (config-only) | validate, rewrite config; no cluster action. This is the bare #557 case (correct a policy-only field without reinstall). |
| M9 | `--set proxyPort=8443` on a `network:proxy`-only module, while `cluster:vm` carries unrelated drift | in-place (network:proxy) | apply **only** `network:proxy`'s hook; `cluster:vm` is untouched — the #557 all-or-nothing fix (D2). |

Each row ends with the config rewritten only if the change was applied (or is config-only); a refusal writes nothing.

## Testing (fast + `--deep`)

Two tiers (ADR-013 / `TESTING.md`), mirroring ADR-019's structure:

- **Fast (offline, default).** Unit-test the pure core: the desired-state resolver (D1) — one input, one value, for validate/drift/modify alike (a resolver mutation must turn *all three* red, proving the single-source invariant); the planner (D2/D3) — assert the class verdict per field (M1–M9) against a fake actual, with the apply hooks stubbed to a command log; the manifest lint (D4) — a `usedBy` field with no manifest entry, or an unknown class, fails `validate`. Keep the **mutation-testing** discipline: strip one guarantee (the shrink refusal, the immutable refusal, the scoping in M9) and confirm the *specific* assertion, and only it, goes red.
- **Deep (`--deep`, live, disposable fixture).** `modify --set cores` and `--set diskSize` (grow) against a throwaway VM; assert live values change and config is rewritten. The `migrate` class reuses ADR-019's deep migrate fixture (do not duplicate it — `modify --set node` is the caller of that path).

## Consequences

- **Positive.** One desired-state definition and one change-semantics home per service → validate/drift/reconcile/modify cannot silently disagree (the general form of #549/#550). Operators get a sanctioned `modify --set` for every declared field (#557) instead of hand-editing deployed config or reinstalling. `modify` is scoped, so one provider's change no longer drags an unrelated drifted provider along (#557). The change taxonomy is declared and lint-checked, so a new provider states its field semantics instead of hiding them in an imperative loop. The frame generalizes to `network-manager` (#538) and any future manager. ADR-019's `node` change becomes one hook in a general frame rather than a special case.
- **Cost.** Real work: lift the resolver out of `inspect.ts`; author a field manifest per existing service; refactor `update-service.sh` from a bespoke drift loop into a manifest-driven dispatcher (must keep every ADR-019 regression guard green); build the `modify --set` planner + CLI surface. The acting bash scripts must consume manager-resolved desired values instead of their own `cfg()` defaults.
- **Neutral / superseded.** `modify`'s current "only `--environment`" surface is superseded by `--set field=value`. `reconcile --apply` is unchanged (deliberately still a full converge).

## Open questions

1. **Manifest location & format.** A standalone `services/<service>/fields.json`, or a declared header block parsed out of `update-service.sh`? The former is machine-clean and lets `validate` read it without sourcing bash; the latter keeps class + code literally adjacent. *Draft: `fields.json`, adjacent to the hook scripts.*
2. **Change class per (field, service) vs per field.** `node` is `migrate` under `cluster:vm` but is *deferred to `cluster:ha`* when the module is HA (update-service.sh today). Is change class a property of the field alone, or of the (field, owning-service) pair, or does the owning service resolve HA-vs-non-HA internally in its `update-node` hook? *Draft: the pair; the `cluster:vm` `update-node` hook internally routes HA per ADR-019, so the manifest stays one entry.*
3. **`--set` and the git source.** `modify` rewrites the *deployed* config (the authority, per #557). Does it also propagate to the git module source, or is drifting Desired-off-Released the expected, annotated state (#550's "not tracking release on purpose")? *Draft: deployed only; Released divergence is reported, not auto-synced — consistent with #550.*
4. **Multi-field atomicity.** `modify --set a=… --set b=…` where `a` is in-place and `b` is refused — apply `a` and report `b`, or refuse the whole set? *Draft: plan-then-refuse-whole — no partial application across a single `modify` invocation, so config and cluster move together.*
5. **network-manager sharing.** Does the resolver/planner live in `lib/ts` shared by both managers, or is it duplicated per manager with a shared *contract* only? *Draft: shared `lib/ts` core, per-manager manifests.*
