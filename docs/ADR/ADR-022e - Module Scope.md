# ADR-022e — Module Scope

| | |
|---|---|
| **Status** | **Proposed** |
| **Version** | 0.1 |
| **Date** | 2026-09-17 |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Amends** | [ADR-007b](<ADR-007b - Apps.md>) §`tier` and :81 (single-instance) · [ADR-022c](<ADR-022c - Node and Host.md>) D5 (`tier` namespacing) · [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) :46, :83 · [ADR-009](<ADR-009 - Composition Meta-Model.md>) :30 · [GLOSSARY.md](../../GLOSSARY.md) :25 |
| **Related** | [ADR-007c — Environments](<ADR-007c - Environments.md>) (`mgmt` is an Environment); [ADR-014](<ADR-014 - Zone and Environment Lifecycle.md>) (`zone.tier`, unchanged); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (Stack); [ADR-025](<ADR-025 - Config migrations and the upgrade path.md>) (migration runner); [ADR-022h](<ADR-022h - Facet Register.md>); #624, #637 |
| **Changelog** | v0.1 (2026-09-17) — proposal: `module.tier` becomes `scope: site \| environment`. |

At which level of the Site ⊃ Environment hierarchy a module belongs.

## Context

`tier` names three things: module lifecycle (ADR-007b), zone trust (ADR-014) and the Stack-promotion rule (`GLOSSARY.md` §C). Review #624/#637 proposed replacing `module.tier` with `stack`.

Measured on `main`:

- **What `tier` does in code** — four enforced rules, all keyed on `foundation`: install into the `mgmt` Environment (`install-module.sh:387`); `source` must be `official` (`validate.ts:62`, `validate-module-tier-source.sh`); delete needs `--force` (`delete-module.sh:286`); shown in `module-manager list`.
- **What `tier` is said to answer** — ADR-007b: *"Can it be uninstalled?"* — contradicted by its own *"`--force` to delete"*. The code answers a different question: does the module belong to the Site, or to one Environment?
- **Single-instance is not true** — `satellite` is `tier: foundation` and exists once per satellite (`satellite-<name>.json`).
- **`stack` is a different question** — the catalog `stack` field has no code reader and its values are functional domains (`ai`, `security`, `collaboration`, …) plus `foundation`. `identity` is `tier: foundation` and `stack: security`; both are true at once.

## Decision

**D1. `module.tier` is replaced by `scope`** — the level of the Site ⊃ Environment hierarchy a module belongs to.

| `scope` | Meaning | Replaces | Examples |
|---|---|---|---|
| `site` | belongs to the Site and serves all its Environments; installed in the `mgmt` Environment | `tier: foundation` | `network`, `cluster`, `identity`, `backup`, `satellite` |
| `environment` | belongs to one Environment; may be installed in several | `tier: app` | `openwebui`, `nextcloud`, `litellm` |

**D2. Normative anchor.** Scope is the containment level of a resource, as used by Kubernetes (`CustomResourceDefinition.spec.scope: Cluster | Namespaced`), OpenStack Keystone (system / domain / project scope) and Azure Resource Manager (management group / subscription / resource group). TAPPaaS's hierarchy is Site ⊃ Environment (ADR-007c, ADR-007d).

**D3. The existing rules follow `scope: site`**, unchanged in effect: installed in `mgmt`; `source: official` unless `--allow-fork`; delete requires `--force`.

**D4. Scope is not multiplicity.** A site-scoped module may have several named instances (`satellite`), as a Kubernetes cluster-scoped kind may.

**D5. Scope is not `stack`.** `Stack` stays the ArchiMate Aggregation of modules realizing a capability (ADR-009). The catalog's domain values are a separate facet (ADR-022h). Merging them would put a containment level and a functional domain in one enum.

**D6. Scope is not a layer.** IaaS / PaaS / SaaS (NIST SP 800-145, ISO/IEC 17788) are defined by what the consumer controls, so one module can sit in different layers for different consumers. Layer is a viewpoint for documentation, never a module field.

**D7. `tier` keeps one meaning** — `zone.tier` (ADR-014). The Stack-promotion rule is renamed and moved to ADR-007f.

## Schema

- `module-fields.json`: `tier` → `scope` (`site` \| `environment`, default `environment`).
- `module-catalog.json` entries: `tier` → `scope`.

## Migration

Readers to change: `install-module.sh`, `delete-module.sh`, `resolve-module.sh`, `validate-module-tier-source.sh`, `module-catalog-lib.sh`, `module-manager` (`validate.ts`, `config.ts`, `main.ts`, `inspect.ts`), `satellite-manager/lib/provision.sh`. Data: 20 core module JSONs, the Community modules (17 `app`, 1 `foundation`), and every deployed `config/<module>.json` — as one config migration (ADR-025), accepting `tier` for one release.

## Conflicts

- **#624 / #637 — `tier` → `stack`.** This proposal keeps the intent (one clear name, `tier` retired for modules) but not the target field, for the reason in D5.

## Acceptance

- [ ] `scope` defined in `GLOSSARY.md` with D1's values; `tier` defined only as `zone.tier`
- [ ] ADR-007b §`tier` and ADR-022c D5 amended
- [ ] Readers and data migrated; `tier` accepted for one release
