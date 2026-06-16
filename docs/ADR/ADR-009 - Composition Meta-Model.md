# ADR-009 — Composition Meta-Model

| | |
|---|---|
| **Status** | Proposed — Node/Device direction confirmed (Erik⟷Lars review 2026-06-15, Option B); #171 open for community discussion |
| **Version** | 0.3 |
| **Date** | 2026-06-16 |
| **Author** | Erik Daniel |
| **Related** | **#171** (metamodel refine) · **#167** (component taxonomy) · #161, #151 (closed spikes) · #297 (catalog); **classification:** [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>); **glossary SSOT:** [ontology.md](<../Architecture/ontology.md>); **realization:** [ADR-007f](<ADR-007f - Realization.md>); **existing docs:** [Capabilities](<../Architecture/Capabilities.md>) + ArchiMate appendix + [foundation module-designs](https://tappaas.org/architecture/module-designs/foundation/) |
| **Changelog** | v0.3 — Node/Device direction confirmed (Option B, meeting 2026-06-15); App≡Module equivalence added to Terms. v0.2 — glossary-SSOT link (ontology.md) + Terms selection; cross-links to ADR-007f and foundation module-designs |

How a deployable unit is **built**. The companion to [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>):
ADR-007 *classifies* (which bucket), this ADR *composes* (how it is structured). Orthogonal — apply both.

> **Scope & status.** This ADR consolidates the #171 metamodel + the current docs. The **Node/Device
> direction** was confirmed in the Erik⟷Lars architecture review (2026-06-15) as **Option B** (node
> field = physical host = Device; Module = the VM). The GitHub issue #171 remains open for community
> discussion — the decision is owner-confirmed, not yet formally closed.

## The model (ArchiMate-grounded)

```
Strategy:     Capability  ◁realizes◁  Stack  (Aggregation of Modules)
Application:  Module ▷ Application Component (recursive) ▷ Application Function ▷ Application Service
Technology:   Module (the VM)  ◁hosted-on◁  physical host (tappaas1)
Artifact:     Implementation  →realizes→  Component/Module   (swappable)
```

Every **Module** is classified by exactly one ADR-007 bucket (+ `tier` + `source`). One model composes,
the other classifies.

## Terms (selection — full glossary: [ontology.md](<../Architecture/ontology.md>) §B)

The composition vocabulary is defined **once** in ontology.md (the term SSOT); the terms this ADR
decides on:

| Term | Definition |
|------|------------|
| **Device** | Physical hardware — the Proxmox host (`tappaas1`); the `node` field in `module-fields.json`. |
| **Node** | The VM. The `node` field in `module-fields.json` refers to the **physical host** (Device) — confirmed Option B (Erik⟷Lars 2026-06-15). Two prose docs (Capabilities.md + ArchiMate appendix) still say Node = VM; those are the minority and need updating. |
| **Module** | The atomic deployable unit: one VM, one `{name}.json`. *Module boundary = VM boundary.* |
| **App** | The user-facing classification label for a Module in the **Apps** bucket (ADR-007b). "App" and "Module" denote the same deployment unit — "App" is what the value stream calls it; "Module" is the technical/composition term. |
| **Component** | A composable unit inside a Module (recursive). ArchiMate Application Component. |
| **Function** | Behaviour a Component realises. Application Function. |
| **Service** | A defined exposed interface (`provides`/`dependsOn`). Application Service. |
| **Stack** | An ArchiMate **Aggregation** of Modules realising a Capability — a *grouping*, not a dependency graph. |
| **Capability** | What the platform can do (Strategy). A Stack *realizes* a Capability. |
| **Implementation** | The swappable Artifact that *realizes* a Component/Module. |
| **Aggregation** vs **Serving** | Aggregation = grouping (a Stack); Serving = a dependency (`dependsOn`/`provides`). Two distinct relations. |

## The divergence — three current sources disagree (live-verified 2026-06-15)

| Concept | Capabilities.md + ArchiMate appendix (prose) | `module-fields.json` (schema/code) | #171 |
|---|---|---|---|
| **node** | a **VM** ("module runs on a NixOS VM = Node") | the **physical Proxmox host** (`node`, example `tappaas1`) | a **physical machine** (grounded in the schema, `tappaasN`) |
| **Capability vs Service** | Module *implements a Capability* | uses the `capability` notation | uses **Service**, drops "capability" |
| **Stack** | central (AI/Foundation Stack) | no `stack` field — absent | absent |
| **Function / Implementation** | not present | (no field) | **new** |

> **Verified:** "node = VM" is held only by **2 prose docs**; the **schema + #171 + tappaas.org's
> foundation page** all use **node = physical host** — and ADR-007d's `site.json.hardware.nodes`
> (`tappaas1`, `tappaas2`) does too. So "node = VM" is the minority; the code and #171 agree.

## Decision

1. **Node/Device — CONFIRMED: Option B** (Erik⟷Lars architecture review 2026-06-15; #171 open for community discussion).
   - **Option B (decided)** — `node` field = **physical host** (= Device); **Module = the VM**.
     Preserves "module boundary = VM boundary"; matches the schema, #171 body, ADR-007d `hardware.nodes`,
     and the tappaas.org foundation page. Fix only the **2 prose docs** (appendix + Capabilities.md)
     to stop calling Node a VM.
   - ~~Option A~~ — ArchiMate-pure (Node = VM, Device = physical) — not adopted; higher churn,
     contradicts the schema and #171.
2. **Keep both Capability (Strategy) and Service (Application).** Rename the `module:capability`
   notation → **`module:service`** (it is a Service).
3. **Keep Stack** — an ArchiMate Aggregation of Modules realizing a Capability.
4. **Component = Application Component** (recursive Composition).
5. **Adopt Function + Implementation** (Application Function; Implementation = swappable Artifact).

## Relation to the catalog/discovery axis (#297)

The catalog (`module-catalog.json`, #297, already merged) carries `stack` × `category` × `repo` for
**browsing** — a third, independent axis. ⚠️ **Naming collision:** `Stack` here (composition
Aggregation) vs `stack` in #297 (a browse facet). **Recommendation:** rename the #297 facet
`stack` → `domain`, reserving `Stack` for the Aggregation. (#297 is closed → needs a follow-up issue.)

## Acceptance

- [x] Node/Device direction confirmed as Option B (Erik⟷Lars review 2026-06-15).
- [ ] Appendix + Capabilities.md updated to match (node = physical host); `capability` → `service`.
- [ ] #171 formally closed after community discussion.
- [ ] #297 `stack` → `domain` follow-up filed/decided.
