# ADR-022e — Module Scope

| | |
|---|---|
| **Status** | **Accepted** (2026-09-18) |
| **Version** | 1.1 |
| **Date** | 2026-09-17 (v1.0: 2026-09-18; v1.1: 2026-09-28) |
| **Author** | ErikDaniel007 (v1.1 amendment: LarsRossen) |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Amends** | [ADR-007b](<ADR-007b - Apps.md>) §`tier` and :81 (single-instance) · [ADR-022c](<ADR-022c - Node and Host.md>) D5 (`tier` namespacing) · [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) :46, :83 · [ADR-009](<ADR-009 - Composition Meta-Model.md>) :30 · [GLOSSARY.md](../../GLOSSARY.md) :25 |
| **Related** | [ADR-007c — Environments](<ADR-007c - Environments.md>) (`mgmt` is an Environment); [ADR-014](<ADR-014 - Zone and Environment Lifecycle.md>) (`zone.tier`, unchanged); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (Stack); [ADR-025](<ADR-025 - Config migrations and the upgrade path.md>) (migration runner); [ADR-022h](<ADR-022h - Facet Register.md>); #624, #637 |
| **Changelog** | **v1.1 (2026-09-28, #676)** — scope is **derived from `stack`, not stored**: the `foundation` stack is site-scoped, every other stack environment-scoped, and a module becomes site-scoped by moving into the foundation stack. D1, D5, Schema and Migration amended accordingly: no `scope` field, no config migration, the catalogue carries nothing. D4 is now enforced — the single-instance guard on foundation modules is gone. Built with #676. · v1.0 (2026-09-18) — accepted (operator). The `tier` → `scope` migration is implementation, tracked in the 2.1 plan (G1.1). · v0.1 (2026-09-17) — proposal: `module.tier` becomes `scope: site \| environment`. |

At which level of the Site ⊃ Environment hierarchy a module belongs.

## Context

`tier` names three things: module lifecycle (ADR-007b), zone trust (ADR-014) and the Stack-promotion rule (`GLOSSARY.md` §C). Review #624/#637 proposed replacing `module.tier` with `stack`.

Measured on `main`:

- **What `tier` does in code** — four enforced rules, all keyed on `foundation`: install into the `mgmt` Environment (`install-module.sh:387`); `source` must be `official` (`validate.ts:62`, `validate-module-tier-source.sh`); delete needs `--force` (`delete-module.sh:286`); shown in `module-manager list`.
- **What `tier` is said to answer** — ADR-007b: *"Can it be uninstalled?"* — contradicted by its own *"`--force` to delete"*. The code answers a different question: does the module belong to the Site, or to one Environment?
- **Single-instance is not true** — `satellite` is `tier: foundation` and exists once per satellite (`satellite-<name>.json`).
- **`stack` is a different question** — the catalog `stack` field has no code reader and its values are functional domains (`ai`, `security`, `collaboration`, …) plus `foundation`. `identity` is `tier: foundation` and `stack: security`; both are true at once.

## Decision

**D1. `module.tier` is replaced by `scope`** — the level of the Site ⊃ Environment hierarchy a module belongs to. *(v1.1)* Scope is **derived from the module's `stack`**, not stored in a field of its own:

| `scope` | Meaning | When | Replaces | Examples |
|---|---|---|---|---|
| `site` | belongs to the Site and serves all its Environments; installed in the `mgmt` Environment | `stack: foundation` | `tier: foundation` | `network`, `cluster`, `identity`, `backup`, `satellite` |
| `environment` | belongs to one Environment; may be installed in several | any other stack, or none | `tier: app` | `openwebui`, `nextcloud`, `litellm` |

A module becomes site-scoped by **moving into the foundation stack**, and in no other way. Measured on `main` when v1.1 was written, `tier: foundation` and `stack: foundation` agreed on every TAPPaaS module; a field for scope would only have stated the stack a second time and allowed the two to disagree — the fault #676 set out to remove. (A Community module that claimed `tier: foundation` while its stack said otherwise was simply wrong about itself.)

**D2. Normative anchor.** Scope is the containment level of a resource, as used by Kubernetes (`CustomResourceDefinition.spec.scope: Cluster | Namespaced`), OpenStack Keystone (system / domain / project scope) and Azure Resource Manager (management group / subscription / resource group). TAPPaaS's hierarchy is Site ⊃ Environment (ADR-007c, ADR-007d).

**D3. The existing rules follow `scope: site`**, unchanged in effect: installed in `mgmt`; `source: official` unless `--allow-fork`; delete requires `--force`.

**D4. Scope is not multiplicity.** A site-scoped module may have several named instances (`satellite`), as a Kubernetes cluster-scoped kind may. *(v1.1)* Enforced: the single-instance guard that `install-module.sh` applied to foundation modules is removed; installing the same instance twice is refused for every module alike.

**D5. Scope is not `stack`.** `Stack` stays the ArchiMate Aggregation of modules realizing a capability (ADR-009). The catalog's domain values are a separate facet (ADR-022h). Merging them would put a containment level and a functional domain in one enum. *(v1.1)* Deriving scope from one stack value does not merge them: no enum gains a value, and scope stays a separate term with its own meaning — it is simply decided by whether a module is in the foundation stack, which is the Site's own.

**D6. Scope is not a layer.** IaaS / PaaS / SaaS (NIST SP 800-145, ISO/IEC 17788) are defined by what the consumer controls, so one module can sit in different layers for different consumers. Layer is a viewpoint for documentation, never a module field.

**D7. `tier` keeps one meaning** — `zone.tier` (ADR-014). The Stack-promotion rule is renamed and moved to ADR-007f.

## Schema

*(v1.1)* No `scope` field. `module-fields.json` keeps `stack`, whose description now says that `foundation` decides scope, and marks `tier` **retired**: kept for one release so a deployed config that still carries it is not reported as holding an unknown field, then removed. `module-catalog.json` carries neither — the catalogue repeats nothing a module's own JSON says (#463), and it already carries `stack`.

## Migration

*(v1.1)* No config migration. Scope is computed wherever it is needed, by one rule implemented three times that must agree: `module_scope_of` (`lib/module-catalog-lib.sh`), `moduleScope` (`lib/ts/src/scope.ts`) and `module_scope` (the update sweep, Python).

- **Readers** changed to it: `install-module.sh` (install in `mgmt`; the single-instance guard removed, D4), `delete-module.sh` (`--force`), `copy-update-json.sh` (`zone0: mgmt` for a site-scoped module, #349), `resolve-module.sh` (`--field scope` replaces `--field tier`), `validate-module-tier-source.sh` and `validate.ts` (site-scoped ⇒ `source: official`; the file keeps its name), `module-catalog-lib.sh`, `module-manager` (`config.ts`, `main.ts`: `list` shows SCOPE), and the update sweep's ordering of foundation machines (`update_tappaas/main.py`). The last two were missing from v1.0's list.
- **Data:** `tier` is removed from every TAPPaaS module JSON and the template. On a site's next update the three-way merge drops it from each deployed config and reports the value (rule 2a: the release once defined the field and no longer does). `stack` is already in every module JSON and deployed config.
- **One release of fallback:** a JSON with no `stack` is read by its `tier` — a deployed config not yet updated, or a module from a repository whose module JSONs carry no stack (Community's carry `stack` only in the catalogue). The release after drops the fallback, and the `tier` schema entry with it.

## Conflicts

- **#624 / #637 — `tier` → `stack`.** This proposal keeps the intent (one clear name, `tier` retired for modules) but not the target field, for the reason in D5.

## Acceptance

- [x] `scope` defined in `GLOSSARY.md` with D1's values; `tier` defined only as `zone.tier`
- [x] ADR-007b §`tier` and ADR-022c D5 amended
- [x] Readers and data migrated; `tier` accepted for one release (#676, v1.1)
- [ ] The release after: the `tier` fallback and its schema entry removed
