# TAPPaaS Ontology — Consolidated Glossary (SSOT)

> The **single summary glossary** for the TAPPaaS ontology. Every term used across ADR-007 (taxonomy),
> ADR-009 (composition) and ADR-007f (realization) is defined **once, here**. Other docs link to this;
> they do not redefine terms. The *decisions* live in the ADRs; this is the *vocabulary* SSOT.

## Three orthogonal axes (one Module is described by all three)

| Axis | Question | Owns |
|------|----------|------|
| **Classification** | *what kind is it, for the value stream?* | ADR-007 + 007a–007e |
| **Composition** | *how is it built?* | ADR-009 (#171) |
| **Realization** | *how is it operated (control plane)?* | ADR-007f |
| *(Discovery)* | *how do I browse it?* | #297 catalog |

## A. Classification terms (ADR-007)

| Term | Definition |
|------|------------|
| **Site** | The physical + admin perimeter. One TAPPaaS = one Site. The *container*, not a bucket. |
| **Bucket** | A top-level classification. Exactly three: People · Apps · Environments. |
| **People** | Bucket. `Organization → Group → User`. RBAC primitive = Group. |
| **Apps** | Bucket. A workload (VM/container/service). Has `tier` × `source`. Each App is a **Module** in the composition model — see §B. |
| **Environments** | Bucket. Where Apps run — zones, domain, posture. Owned by one Organization. |
| **Health** | A cross-cutting **lens** (observability overlay) — **not** a bucket. |
| **tier** | App lifecycle class: `foundation` (cannot uninstall) · `app` (user-installable). |
| **source** | App origin/trust: `official` · `community` · `private` · `local`. |

## B. Composition terms (ADR-009 / ArchiMate)

| Term | Definition |
|------|------------|
| **Device** | Physical hardware — the Proxmox host (`tappaas1`). (`node` in `module-fields.json`.) |
| **Node** | The VM. (`node` field in `module-fields.json` = the **physical host** = Device — Option B confirmed, Erik⟷Lars 2026-06-15. Two prose docs still say Node = VM and need updating — see ADR-009.) |
| **Module** | The atomic deployable unit: one VM, one `{name}.json`. *Module boundary = VM boundary.* |
| **Component** | A composable unit inside a Module (recursive). ArchiMate Application Component. |
| **Function** | Behaviour a Component realises. ArchiMate Application Function. |
| **Service** | A defined exposed interface (`provides`/`dependsOn`). ArchiMate Application Service. |
| **Stack** | An **Aggregation** of Modules realising a Capability. A *grouping*, not a dependency graph. |
| **Capability** | What the platform can do (Strategy layer). A Stack *realizes* a Capability. |
| **Implementation** | The swappable concrete Artifact that realizes a Component/Module. |
| **Aggregation** | ArchiMate whole-part **grouping** (parts exist independently). *What is grouped.* A Stack is an Aggregation. |
| **Serving / dependency** | ArchiMate relation: one element depends on / is served by another (`dependsOn`/`provides`, `DEPENDENCIES.csv`). *How they relate.* **Distinct from Aggregation.** |

## C. Realization terms (ADR-007f)

| Term | Definition |
|------|------------|
| **Orchestrator / manager** | The control-plane component that operates a bucket's Modules (e.g. `environment-manager`, `site-manager`). Realizes a **Stack** when it orchestrates ≥2 Modules. |
| **Realization level** | **Stack** (orchestrator over ≥2 aggregated Modules) vs **Module** (single). Promote to Stack only on genuine ≥2-Module aggregation — **not** runtime coordination. |
| **Tiering rule** | aggregation ≠ coordination. A manager that merely coordinates scripts at runtime is a Module, not a Stack. |

> All terms here are **TAPPaaS-native**. Other organisations that consume this ontology map it via a
> one-way crosswalk maintained on **their** side — never in this repository.
