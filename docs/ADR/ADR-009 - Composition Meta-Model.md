# ADR-009 — Composition Meta-Model

| | |
|---|---|
| **Status** | Proposed — composition direction **pending #171** discussion |
| **Version** | 0.1 |
| **Date** | 2026-06-15 |
| **Author** | Erik Daniel |
| **Related** | **#171** (metamodel refine) · **#167** (component taxonomy) · #161, #151 (closed spikes) · #297 (catalog); **classification:** [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>); [Capabilities](<../Architecture/Capabilities.md>) + ArchiMate appendix |

How a deployable unit is **built**. The companion to [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>):
ADR-007 *classifies* (which bucket), this ADR *composes* (how it is structured). Orthogonal — apply both.

> **Scope & status.** This ADR consolidates the #171 metamodel + the current docs. The **Node/Device
> direction** is the one genuinely open point (Decision §1) and stays **Proposed pending #171** —
> @larsrossen asked to keep #171 "smaller and more discussion-oriented", so the contested rename is a
> discussion, not a fait accompli. The rest is data-verified and ready.

## The model (ArchiMate-grounded)

```
Strategy:     Capability  ◁realizes◁  Stack  (Aggregation of Modules)
Application:  Module ▷ Application Component (recursive) ▷ Application Function ▷ Application Service
Technology:   Module (the VM)  ◁hosted-on◁  physical host (tappaas1)
Artifact:     Implementation  →realizes→  Component/Module   (swappable)
```

Every **Module** is classified by exactly one ADR-007 bucket (+ `tier` + `source`). One model composes,
the other classifies.

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

1. **Node/Device — OPEN, pending #171.**
   - **Option B (recommended)** — `node` = **physical host**, **Module = the VM** (what the code +
     #171 + foundation page + ADR-007d already do; preserves "module boundary = VM boundary"). Fix
     only the **2 prose docs** (appendix + Capabilities) to stop calling Node a VM.
   - **Option A** — ArchiMate-pure: Node = VM, Device = physical (insert a VM-Node element). Higher
     churn; contradicts the schema and #171.
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

- [ ] #171 ratifies the Node/Device direction (Option B recommended).
- [ ] Appendix + Capabilities.md updated to match (node = physical host); `capability` → `service`.
- [ ] #297 `stack` → `domain` follow-up filed/decided.
