# ADR-007f — Realization (Taxonomy → Foundation Modules & Control-Plane)

| | |
|---|---|
| **Status** | Accepted — **implemented** (S0–S9 on the `ADR007` branch; the realization described here is built) |
| **Version** | 1.0 |
| **Date** | 2026-06-30 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320 (taxonomy); **composition:** [ADR-009](<ADR-009 - Composition Meta-Model.md>); [ADR-008](<ADR-008-switch-module-network-infrastructure.md>) (switch/control-points); ADR-004 (config cascade); **verbs:** [design/ADR-007-verb-alignment.md](<../design/ADR-007-verb-alignment.md>); **build state:** [design/ADR-007-implementation-tracker.md](<../design/ADR-007-implementation-tracker.md>); closed: #364 (split opnsense-controller) · #365 (Managers) |
| **Changelog** | v1.0 — **as-built (2026-06-30):** the control plane is **realized**. The flat `scripts/` pile became **`tappaas-cicd/manager/` (7 TypeScript Managers with a uniform verb surface) + `tappaas-cicd/controller/` (6 Controllers doing live I/O) + `lib/`**. The mapping table below is rewritten to the built structure: `firewall`→**`network`** Module + `network-manager` (owns `zones.json` + reconciles 4 planes); People realized as `people-manager`→`identity-controller`; `module-manager` for Apps; `configuration-fields.json` retired → `site-fields.json` + `environment-fields.json`; per-domain `*-fields.json` schemas all present (People gap closed). v0.8 — Controller column added; Manager→Controller→Service chain explicit. v0.7 — Manager/Controller distinction. v0.6 — Schema column; People gap named. v0.5 — orchestrator layer; `repository.sh`→Site; `variant-manager.sh`=env-manager v0.1. v0.4 — Stack = Aggregation ≠ Serving. |

The **SSOT mapping** from the ADR-007 classification (classification domains) to the **existing TAPPaaS foundation
modules and control-plane scripts**. This ADR answers the question the flat `scripts/` pile cannot:
*"which ADR-007 classification domain does this module / script serve?"* — MECE (every script in exactly one place)
and DRY (each schema co-located with its owning domain).

## Decision

Realization has **two layers**, both TAPPaaS-native ([ADR-009](<ADR-009 - Composition Meta-Model.md>)):

1. **Classification** (this family): every foundation module + control-plane script maps to exactly one
   ADR-007 classification domain. MECE/DRY. Health is a **lens** (cross-cutting `health/`), not a classification domain.
2. **Composition level** (ADR-009 `Stack ▷ Module ▷ Component`): a classification domain is realized as a **Stack**
   *only* when it genuinely **aggregates ≥2 Modules**; otherwise as a single **Module**. Scripts are
   the **Components** of their Module.

**A Stack is an ArchiMate Aggregation — a *grouping*, not a dependency graph.** It says *which* Modules
belong together under a Capability (they still exist independently). It does **not** encode *how* they
relate: the **dependency relations** among them — e.g. `setup-caddy → opnsense-firewall`,
`zone-manager → vlan/dhcp/firewall`, all reconciling from the shared `zones.json` SSOT (ADR-008,
`src/foundation/DEPENDENCIES.csv`) — are **separate** ArchiMate **Serving** relations, carried in
`dependsOn`/`provides`. *Aggregation = what is grouped; the dependency graph = how they relate* — two
distinct relationship types.

**Manager vs Controller (as built).** Two distinct control-plane roles, now realized as two directories
under `tappaas-cicd/`:
- **Manager** (`manager/<x>-manager/`) — a **TypeScript** orchestrator for a domain. Owns the domain's
  config CRUD + validation + the reconcile cascade, and presents a **uniform verb surface**
  (`add`/`modify`/`delete`/`list`/`show`/`validate`/`reconcile` — see the
  [verb-alignment doc](<../design/ADR-007-verb-alignment.md>)). Admins drive verbs, never hand-edit JSON.
- **Controller** (`controller/<x>-controller/`) — a **Python/bash** component that does the live I/O for one
  plane (talk to OPNsense, Authentik, Proxmox, the switch/AP). Called by a Manager; never by the operator
  directly. Heavy I/O (cluster discovery, VM provisioning, PBS mutation) still lives in the legacy `.sh`
  the Managers shell out to (thin-orchestration), being ported into TS incrementally.

The model originally said "one Manager per classification domain". As built it is **finer**: a domain may
have **two** Managers when it owns two distinct config surfaces — Environments is realized by
**`environment-manager`** (the `config/environments/*` lifecycle) **and** **`network-manager`** (owns
`config/zones.json` end-to-end and reconciles the 4 network planes); People by **`people-manager`** (config)
+ the **`identity-controller`** (Authentik). Shared code lives in `lib/`.

**Tiering rule — aggregation ≠ coordination.** Promote a classification domain to a **Stack** only on genuine
≥2-Module *aggregation under a shared Capability*, **not** because a manager *coordinates* scripts at
runtime:

- 🏠 **Environments = Stack** — aggregates **`network`** (OPNsense L3, was `firewall`) + **switch** + **ap**
  + **proxy/TLS** planes; `network-manager` reconciles them from the shared `zones.json` SSOT (ADR-008; the
  `dependsOn` edges in `DEPENDENCIES.csv`) — Serving relations, *separate from* the aggregation.
- 🏢 **Site = Stack** — aggregates **cluster** + **backup** + **templates** + **tappaas-cicd** Modules.
- 👥 **People = Module** (`identity`) · 🩺 **Health = Module** (`logging`) — single Module, not a Stack.
- 📦 **Apps** — `module-manager` is a single **lifecycle Module** (it *coordinates* installs at runtime;
  coordination ≠ aggregation); the App workloads are independent Modules.

## Mapping (SSOT, as built) — classification domain → Manager(s) → level → Module(s) → schema → Controller(s)

All Managers live under `tappaas-cicd/manager/<x>-manager/` (TypeScript); Controllers under
`tappaas-cicd/controller/<x>-controller/` (Python/bash); schemas under `src/foundation/schemas/`.

| Classification domain | Manager(s) (TS) | Level | Module(s) | Schema (`schemas/`) | Controller(s) | Key services / scripts |
|---|---|---|---|---|---|---|
| 👥 **People** ([007a](<ADR-007a - People.md>)) | `people-manager` | Module | `identity` (Authentik) | `role`,`organization`,`group`,`user`-`fields.json` | **`identity-controller`** (Python; Authentik reconcile) | `user-setup.sh`, `minimal-org/`, `validate.sh` |
| 📦 **Apps** ([007b](<ADR-007b - Apps.md>)) | `module-manager` | Module (lifecycle) | the App workloads | `module-fields.json` | *(uses the `cluster:vm` / `network:proxy` install-service hooks)* | `install-module.sh`, `update-module.sh`, `delete-module.sh`, `test-module.sh`, `copy-update-json.sh`; `lib/common-install-routines.sh` |
| 🏠 **Environments** ([007c](<ADR-007c - Environments.md>)) | `environment-manager` (env files) **+** `network-manager` (owns `zones.json`, reconciles 4 planes) | **Stack** | `network` (OPNsense L3 — was `firewall`) | `environment-fields.json`, `zones-fields.json` | **`opnsense-controller`** (Python: firewall/DNS/Caddy/ACME), **`switch-controller`**, **`ap-controller`** | `zones-init`/`zones-merge`/`zones-check`, `reconcile [--only <plane>]`, `acme-setup.sh` |
| 🏢 **Site** ([007d](<ADR-007d - Site.md>)) | `site-manager` **+** `backup-manager` | **Stack** | `cluster`, `backup` (PBS on node), `templates`, `tappaas-cicd` | `site-fields.json`, `module-catalog-fields.json` *(was `configuration-fields.json` — retired)* | **`proxmox-controller`**, **`backup-controller`** | `create-site.sh`, `migrate-configuration.sh`, `repository.sh`, backup LCM |
| 🩺 **Health** *(lens)* ([007e](<ADR-007e - Health.md>)) | `health-manager` *(read-only: inspect/check)* | Module | `logging` (Loki/Grafana/Promtail) | — *(lens; none)* | — *(lens; none)* | `inspect`/`check` verbs |
| — *(shared)* | `lib/` | — | — | — | — | `common-install-routines.sh`, `apply-json-merge.sh`, `audit-jq-readers.sh` |

> **Manager → Controller → Service (realized).** Managers (TS) own the verb surface + config + the
> reconcile cascade; they call Controllers (Python/bash) for live I/O, which call the remaining Service
> scripts. **#364** (split opnsense-controller, extract `identity-controller`) and **#365** (implement the
> Managers) are **done**. Controllers built: `opnsense`, `identity`, `proxmox`, `switch`, `ap`, `backup`.
> A `manager/TEMPLATE/` + `controller/TEMPLATE/` + a P10 contract test encode the per-component contract
> (a Manager has `validate`; a Controller does not).

> **Realization layers** (terms → [ontology.md](<../Architecture/ontology.md>)): **classification domain** →
> **Manager** (TS control-plane orchestrator, verb surface) → **level** (Stack if ≥2 Modules, else Module) →
> **Module** → **Controller** (Python/bash, live I/O for one plane) → **Services** (the `.sh`/TS Components).
> This containment makes the grouping MECE (every component in exactly one Module under one Manager) and DRY.

> **Two review corrections (now realized).** (1) `repository.sh` (the **Repository Manager** — adds /
> lists / modifies module repositories) sits under **Site**: repositories are a **Site-level** concept
> (`site.json.repositories`, ADR-007d CR-17), not per-App. (2) the old `variant-manager.sh` became
> **`environment-manager`** (+ `network-manager` for the zone/TLS/DNS planes) — the Environments
> orchestrator, not a leaf service; `--variant` is kept only as a deprecated alias of `--environment`.

### Schema coverage (MECE check — as built)

All schemas live in **`src/foundation/schemas/`** (JSON Schema 2020-12), one per owned config surface:
`role`/`organization`/`group`/`user`-`fields.json` (People), `module-fields.json` +
`module-catalog-fields.json` (Apps/catalog), `environment-fields.json` + `zones-fields.json`
(Environments), `site-fields.json` (Site). The earlier findings are resolved:

- **People gap — CLOSED:** the four `role`/`organization`/`group`/`user` schemas now validate the People
  domain (`people-manager validate`).
- **Site transition — DONE:** `configuration-fields.json` is **retired**; `site.json` (`site-fields.json`)
  + `config/environments/*.json` (`environment-fields.json`) replaced it (ADR-007d / 007c).
- **Health — consistent:** no schema, as expected for a lens.

## Why this is the realization, not the taxonomy

- **ADR-007/a–e classify** (which classification domain a thing is in). **This ADR realizes** that classification in
  the foundation modules + `tappaas-cicd` control plane. Keeping them separate keeps each readable and
  lets the taxonomy stay stable while the realization evolves.
- **MECE:** every one of the ~42 foundation scripts lands in exactly one manager; managers map 1:1 to
  classification domains. **DRY:** zones live only in `environment-manager`; schemas co-locate with their domain; no
  competing second taxonomy.
- One-off migration scripts are separated from recurring LCM (retired to `Attic/` after use), out of
  scope for this mapping.

## References (existing TAPPaaS artifacts)

- Taxonomy: [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) + 007a–007e; issue #320.
- Control plane: `src/foundation/tappaas-cicd/manager/` (TS Managers) + `controller/` (Controllers) + `lib/`.
- Schemas: `src/foundation/schemas/` — `role/organization/group/user/module/module-catalog/environment/site/zones-fields.json`.
- Config cascade: ADR-004. Verb surface: [ADR-007-verb-alignment.md](<../design/ADR-007-verb-alignment.md>).
- **Implementing change — DONE:** the `tappaas-cicd` `scripts/` → Manager/Controller restructure was
  executed across stages S0–S9 (#364, #365 closed); build state in
  [ADR-007-implementation-tracker.md](<../design/ADR-007-implementation-tracker.md>).

## Acceptance

- [x] `tappaas-cicd/` is `manager/` (7 TS Managers) + `controller/` (6 Controllers) + `lib/`; the flat `scripts/` pile is retired/migrated.
- [x] Every foundation component resolves to exactly one classification domain (MECE check).
- [x] Each schema lives in `schemas/` and is owned by exactly one Manager (DRY check); People schemas present.
- [x] Managers present the uniform verb surface ([verb-alignment](<../design/ADR-007-verb-alignment.md>)); `health-manager` is read-only.

> **Not yet hardware-validated end-to-end as a clean release:** the realization was built + exercised on a
> live cluster (see the [implementation tracker](<../design/ADR-007-implementation-tracker.md>)), but the
> `ADR007` branch is **pending merge to `stable`**.
