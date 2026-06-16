# ADR-007f — Realization (Taxonomy → Foundation Modules & Control-Plane)

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 0.7 |
| **Date** | 2026-06-16 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320 (taxonomy); **composition:** [ADR-009](<ADR-009 - Composition Meta-Model.md>) (Stack ▷ Module ▷ Component); [ADR-008](<ADR-008-switch-module-network-infrastructure.md>) (switch/control-points); ADR-004 (config cascade); `src/foundation/tappaas-cicd/scripts/`; **implementation:** tappaas-cicd restructure (issue — to be filed) |
| **Changelog** | v0.7 — Manager/Controller distinction added (Erik⟷Lars 2026-06-16): Manager orchestrates Controllers; Controller = leaf function inside a Module. v0.6 — Schema column; People gap named; `module-catalog-fields.json` → Site. v0.5 — orchestrator layer; `repository.sh` → Site; `variant-manager.sh` = env-manager v0.1. v0.4 — Stack = Aggregation ≠ Serving. |

The **SSOT mapping** from the ADR-007 classification (buckets) to the **existing TAPPaaS foundation
modules and control-plane scripts**. This ADR answers the question the flat `scripts/` pile cannot:
*"which ADR-007 bucket does this module / script serve?"* — MECE (every script in exactly one place)
and DRY (each schema co-located with its owning domain).

## Decision

Realization has **two layers**, both TAPPaaS-native ([ADR-009](<ADR-009 - Composition Meta-Model.md>)):

1. **Classification** (this family): every foundation module + control-plane script maps to exactly one
   ADR-007 bucket. MECE/DRY. Health is a **lens** (cross-cutting `health/`), not a bucket.
2. **Composition level** (ADR-009 `Stack ▷ Module ▷ Component`): a bucket is realized as a **Stack**
   *only* when it genuinely **aggregates ≥2 Modules**; otherwise as a single **Module**. Scripts are
   the **Components** of their Module.

**A Stack is an ArchiMate Aggregation — a *grouping*, not a dependency graph.** It says *which* Modules
belong together under a Capability (they still exist independently). It does **not** encode *how* they
relate: the **dependency relations** among them — e.g. `setup-caddy → opnsense-firewall`,
`zone-manager → vlan/dhcp/firewall`, all reconciling from the shared `zones.json` SSOT (ADR-008,
`src/foundation/DEPENDENCIES.csv`) — are **separate** ArchiMate **Serving** relations, carried in
`dependsOn`/`provides`. *Aggregation = what is grouped; the dependency graph = how they relate* — two
distinct relationship types.

**Manager vs Controller.** Two distinct control-plane roles (confirmed Erik⟷Lars 2026-06-16):
- **Manager** — top-level orchestrator for a classification domain (`environment-manager`, `app-manager`, `site-manager`). Owns the domain's lifecycle contract. Orchestrates ≥1 Controllers.
- **Controller** — a leaf control-plane component *inside* a Module that operates one specific function (`opnsense-controller`, `zone-controller`). Called by the Manager; encapsulated within the Module boundary.

**Tiering rule — aggregation ≠ coordination.** Promote a bucket to a **Stack** only on genuine
≥2-Module *aggregation under a shared Capability*, **not** because a manager *coordinates* scripts at
runtime:

- 🏠 **Environments = Stack** — aggregates **firewall** (OPNsense L3) + **switch** + **proxy/TLS**
  Modules; their **dependency relations** (a zone reconciling across control points — ADR-008; the
  `dependsOn` edges in `DEPENDENCIES.csv`) are Serving relations, *separate from* the aggregation.
- 🏢 **Site = Stack** — aggregates **cluster** + **backup** + **templates** Modules.
- 👥 **People = Module** (`identity`) · 🩺 **Health = Module** (`logging`) — single Module, not a Stack.
- 📦 **Apps** — `app-manager` is a single **lifecycle Module** (it *coordinates* installs at runtime;
  coordination ≠ aggregation); the App workloads are independent Modules.

## Mapping (SSOT) — bucket → orchestrator → level → Module → schema → services

| Bucket | Orchestrator (control plane) | Level | Module | Schema (`src/foundation/`) | Services (Components) |
|--------|------------------------------|-------|--------|----------------------------|-----------------------|
| 👥 **People** ([007a](<ADR-007a - People.md>)) | `identity-manager` | Module | `identity` | **— gap** (orgs/groups/users unvalidated) | `user.sh`, `roles-ensure.sh` |
| 📦 **Apps** ([007b](<ADR-007b - Apps.md>)) | `app-manager` *(coordinates installs)* | Module (lifecycle) | the App workloads (independent Modules) | `module-fields.json` (per-Module) | `install-module.sh`, `update-module.sh`, `delete-module.sh`, `test-module.sh`, `module-format.sh`, `copy-update-json.sh`, `common-install-routines.sh`, `snapshot-vm.sh`, `resize-disk.sh`, `update-os.sh` |
| 🏠 **Environments** ([007c](<ADR-007c - Environments.md>)) | **`environment-manager`** *(today: `variant-manager.sh` = its v0.1)* | **Stack** | `firewall` (OPNsense, incl. `opnsense-controller/`) | `zones-fields.json` | `zone-state.sh`, `apply-zones-merge.sh` |
| | | | `proxy`/TLS (Caddy/ACME) | | `setup-caddy.sh`, `acme-setup.sh` |
| | | | `switch` ([ADR-008](<ADR-008-switch-module-network-infrastructure.md>)) | | *(control-point reconcilers — #339)* |
| 🏢 **Site** ([007d](<ADR-007d - Site.md>)) | `site-manager` | **Stack** | `cluster` | `configuration-fields.json` *(→ splits into `site.json` + `environments/*`, ADR-007d)* | `migrate-node.sh`, `migrate-vm.sh` |
| | | | `backup` | | *(backup LCM ops)* |
| | | | `templates` | | — |
| | | | **catalog / repositories** | `module-catalog-fields.json` | **`repository.sh`**, `validate-configuration.sh` |
| 🩺 **Health** *(lens)* ([007e](<ADR-007e - Health.md>)) | `health/` | Module | `logging` | — *(lens; none)* | `inspect-cluster.sh`, `inspect-vm.sh`, `check-disk-threshold.sh` |
| — *(shared libs)* | `shared/` | — | — | — | `apply-json-merge.sh`, `audit-jq-readers.sh` |

> **Realization layers** (terms → [ontology.md](<../Architecture/ontology.md>)): **bucket** →
> **orchestrator** (control-plane manager) → **level** (Stack if it orchestrates ≥2 Modules, else
> Module) → **Module** → **services** (the scripts = Components). This containment makes the grouping
> MECE (every service in exactly one Module under one orchestrator) and DRY.

> **Two review corrections (data-driven).** (1) `repository.sh` (the **Repository Manager** — adds /
> lists / modifies module repositories) moves **Apps → Site**: repositories are a **Site-level** concept
> (`site.json.repositories`, ADR-007d CR-17), not per-App. (2) `variant-manager.sh` (it registers an
> *environment*/variant and orchestrates its zone + TLS + DNS) is the **v0.1 of `environment-manager`**
> — the embryonic Environments **orchestrator**, not a leaf service.

### Schema coverage (MECE check)

Each `src/foundation/*-fields.json` schema co-locates with its owning manager (DRY): `module-fields.json`
→ `app-manager/`; `zones-fields.json` → `environment-manager/`; `configuration-fields.json` +
`module-catalog-fields.json` → `site-manager/` (the catalog follows `repository.sh` to Site, CR-17).
The schema column surfaces three findings:

- **Gap — People** has no `*-fields.json`: organisations/groups/users are unvalidated. A `people`/identity
  schema is owed (ADR-006).
- **Transition — Site** `configuration-fields.json` is splitting into `site.json` + `environments/*`
  (ADR-007d) — it currently spans Site and Environments until the split lands.
- **Consistent — Health** has no schema, as expected for a lens (not a bucket).

## Why this is the realization, not the taxonomy

- **ADR-007/a–e classify** (which bucket a thing is in). **This ADR realizes** that classification in
  the foundation modules + `tappaas-cicd` control plane. Keeping them separate keeps each readable and
  lets the taxonomy stay stable while the realization evolves.
- **MECE:** every one of the ~42 foundation scripts lands in exactly one manager; managers map 1:1 to
  buckets. **DRY:** zones live only in `environment-manager`; schemas co-locate with their domain; no
  competing second taxonomy.
- One-off migration scripts are separated from recurring LCM (retired to `Attic/` after use), out of
  scope for this mapping.

## References (existing TAPPaaS artifacts)

- Taxonomy: [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) + 007a–007e; issue #320.
- Control plane: `src/foundation/tappaas-cicd/scripts/` (the scripts mapped above).
- Schemas: `src/foundation/module-fields.json`, `zones-fields.json`, `configuration-fields.json`.
- Config cascade: ADR-004.
- **Implementing change:** the `tappaas-cicd` scripts/ → bucket-manager restructure (issue to be
  filed). This ADR is its governing model; the restructure is its execution.

## Acceptance

- [ ] `tappaas-cicd/` contains one manager per bucket + `health/` + `shared/`; `scripts/` retired.
- [ ] Every foundation script resolves to exactly one bucket (MECE check).
- [ ] Each schema co-located with its owning manager (DRY check).
