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
| **Site** | The physical + admin perimeter. One TAPPaaS = one Site. The *container* that holds the three classification terms. |
| **People** | `Organization → Group → User`. Group is the RBAC primitive: finer-grained than Organization (org-level RBAC is too coarse), coarser than per-user rules. |
| **Apps** | A workload (VM/container/service). Has `tier` × `source`. Each App is a **Module** in the composition model — see §B. |
| **Environments** | Where Apps run — zones, domain, posture. Owned by one Organization. |
| **Health** | A cross-cutting **lens** (observability overlay) — applies across all classification terms, not a term itself. |
| **tier** | App lifecycle class: `foundation` (cannot uninstall) · `app` (user-installable). |
| **source** | App origin/trust: `official` · `community` · `private` · `local`. |

## B. Composition terms (ADR-009 / ArchiMate)

| Term | Definition |
|------|------------|
| **Node** | The physical Proxmox host (e.g. `tappaas1`). The `node` field in `module-fields.json` refers to this host. The VM is the **Module**. (Confirmed Erik⟷Lars 2026-06-16; ADR-009 Option B.) |
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
| **Manager** | Top-level control-plane orchestrator for a classification domain (e.g. `environment-manager`, `app-manager`, `site-manager`). Orchestrates one or more Controllers. Owns the domain's lifecycle contract. |
| **Controller** | A leaf control-plane component inside a Module that operates one specific function (e.g. `opnsense-controller`, `zone-controller`). Invoked by the Manager; not exposed to end-users directly. Invokes the Module's Service scripts internally (today: .sh; roadmap: Python wrapping .sh). Corresponds to a Function in ArchiMate terms. |
| **Realization level** | **Stack** (Manager over ≥2 aggregated Modules) vs **Module** (single). Promote to Stack only on genuine ≥2-Module aggregation — **not** runtime coordination. |
| **Tiering rule** | aggregation ≠ coordination. A Manager that merely coordinates scripts at runtime is a Module, not a Stack. |

> All terms here are **TAPPaaS-native**. Other organisations that consume this ontology map it via a
> one-way crosswalk maintained on **their** side — never in this repository.
