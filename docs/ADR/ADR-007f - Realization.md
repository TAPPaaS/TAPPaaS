# ADR-007f — Realization (Taxonomy → Foundation Modules & Control-Plane)

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 0.3 |
| **Date** | 2026-06-16 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320 (taxonomy); **composition:** [ADR-009](<ADR-009 - Composition Meta-Model.md>) (Stack ▷ Module ▷ Component); [ADR-008](<ADR-008-switch-module-network-infrastructure.md>) (switch/control-points); ADR-004 (config cascade); `src/foundation/tappaas-cicd/scripts/`; **implementation:** tappaas-cicd restructure (issue — to be filed) |
| **Changelog** | v0.3 — added the **Stack ▷ Module ▷ Component** level (ADR-009): Environments & Site are **Stacks** (≥2-Module composition, ADR-008); People/Health = Modules; Apps = lifecycle Module + workloads. Tiering rule: composition ≠ coordination. v0.2 — opnsense-controller → Environments |

The **SSOT mapping** from the ADR-007 classification (buckets) to the **existing TAPPaaS foundation
modules and control-plane scripts**. This ADR answers the question the flat `scripts/` pile cannot:
*"which ADR-007 bucket does this module / script serve?"* — MECE (every script in exactly one place)
and DRY (each schema co-located with its owning domain).

## Decision

Realization has **two layers**, both TAPPaaS-native ([ADR-009](<ADR-009 - Composition Meta-Model.md>)):

1. **Classification** (this family): every foundation module + control-plane script maps to exactly one
   ADR-007 bucket. MECE/DRY. Health is a **lens** (cross-cutting `health/`), not a bucket.
2. **Composition level** (ADR-009 `Stack ▷ Module ▷ Component`): a bucket is realized as a **Stack**
   *only* when it genuinely **composes ≥2 Modules**; otherwise as a single **Module**. Scripts are the
   **Components** of their Module.

**Tiering rule — composition ≠ coordination.** Promote a bucket to a **Stack** only on genuine
≥2-Module composition, **not** because a manager *coordinates* scripts at runtime:

- 🏠 **Environments = Stack** — composes **firewall** (OPNsense L3) + **switch** + **proxy/TLS** Modules.
  Data-driven: [ADR-008](<ADR-008-switch-module-network-infrastructure.md>) shows a zone spans *multiple
  independent control points* that must all reconcile → genuine multi-Module composition.
- 🏢 **Site = Stack** — composes **cluster** + **backup** + **templates** Modules.
- 👥 **People = Module** (`identity`) · 🩺 **Health = Module** (`logging`) — single Module, not a Stack.
- 📦 **Apps** — `app-manager` is a single **lifecycle Module** (it *coordinates* installs at runtime;
  coordination ≠ composition); the App workloads are independent Modules.

## Mapping (SSOT) — bucket → level → Module (System) → scripts (Components)

| Bucket | Level (ADR-009) | Module (System) | Scripts (Components) |
|--------|-----------------|-----------------|----------------------|
| 👥 **People** ([007a](<ADR-007a - People.md>)) | **Module** | `identity` | `user.sh`, `roles-ensure.sh` |
| 📦 **Apps** ([007b](<ADR-007b - Apps.md>)) | **Module** (lifecycle) + App workloads | `app-manager` *(coordinates installs)*; the apps are independent Modules | `install-module.sh`, `update-module.sh`, `delete-module.sh`, `test-module.sh`, `module-format.sh`, `copy-update-json.sh`, `common-install-routines.sh`, `snapshot-vm.sh`, `resize-disk.sh`, `update-os.sh`; `catalog/repository.sh` |
| 🏠 **Environments** ([007c](<ADR-007c - Environments.md>)) | **Stack** | `firewall` (OPNsense, incl. `opnsense-controller/`) | `zone-state.sh`, `apply-zones-merge.sh` |
| | | `proxy`/TLS (Caddy/ACME) | `setup-caddy.sh`, `acme-setup.sh` |
| | | `switch` ([ADR-008](<ADR-008-switch-module-network-infrastructure.md>)) | *(control-point reconcilers — #339)* |
| | | env/variant | `variant-manager.sh` |
| 🏢 **Site** ([007d](<ADR-007d - Site.md>)) | **Stack** | `cluster` | `migrate-node.sh`, `migrate-vm.sh` |
| | | `backup` | *(backup LCM ops)* |
| | | `templates` | — |
| | | site config | `validate-configuration.sh` |
| 🩺 **Health** *(lens)* ([007e](<ADR-007e - Health.md>)) | **Module** | `logging` | `inspect-cluster.sh`, `inspect-vm.sh`, `check-disk-threshold.sh` |
| — *(cross-component libs)* | — | `shared/` | `apply-json-merge.sh`, `audit-jq-readers.sh` |

### Schema co-location (DRY)

Each schema lives with the manager that owns its domain — not in a central pile:
`module-fields.json` → `app-manager/`; `zones-fields.json` → `environment-manager/`;
`configuration-fields.json` → `site-manager/` (splits into `site.json` + `environments/*` per ADR-007d).

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
