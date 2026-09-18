# ADR-022h — Facet Register

| | |
|---|---|
| **Status** | **Accepted** (2026-09-18) |
| **Version** | 1.0 |
| **Date** | 2026-09-17 (v1.0: 2026-09-18) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Amends** | [GLOSSARY.md](../../GLOSSARY.md) ("Three orthogonal axes") |
| **Related** | [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (classification domains); [ADR-013](<ADR-013 - Documentation Structure and Standards.md>) (documentation); [ADR-022e](<ADR-022e - Module Scope.md>), [ADR-022f](<ADR-022f - Kind Values and Operating System.md>), [ADR-022g](<ADR-022g - Management.md>) |
| **Changelog** | v1.0 (2026-09-18) — accepted (operator). · v0.1 (2026-09-17) — proposal: one register of facets, a six-test gate, schema values as the machine source. |

How TAPPaaS keeps the attributes that describe a resource mutually exclusive and defined once.

## Context

ADR-007 splits TAPPaaS into classification **domains** (People, Apps, Environments; Site as container). ADR-022 describes one resource along independent **facets** (who, where, on what, what type). Nothing lists the facets together, so the same defect keeps returning — one field answering several questions:

- `tier` — "can it be uninstalled?" (ADR-007b) versus what the code enforces (Site or Environment)
- `stack` — functional domains plus `foundation`
- `status` — maturity, lifecycle and management
- `external` — five meanings (ADR-022g)
- VM `os` — family and distribution

Enumerations are also copied: `tier` and `source` values live in ADR-007b, `GLOSSARY.md`, `module-fields.json`, `validate.ts` and `validate-module-tier-source.sh`. The owner of `stack` / `category` is named three different ways (ADR-007b, `GLOSSARY.md`, ADR-004).

## Decision

**D1. `GLOSSARY.md` holds one facet register.** Anchor: ISO/IEC 11179 (metadata registry — every data element has a definition, a value domain and a steward); ISO 25964-1 (facet analysis — one characteristic of division per facet).

| Facet | Question | Owner | Applies to | Field | Status |
|---|---|---|---|---|---|
| Administrative Domain | who is accountable for it? | ADR-022a | Site | `site.json` | Draft |
| Location | where is it physically? | ADR-022b | Site, machine | `location` | Draft |
| Host · cluster member | what does it run on? is that a cluster member? | ADR-022c | module · Node | `node` · `site.json` | Draft |
| Zone | where is it on the network? | ADR-014 | module | `zone0` | Accepted |
| Kind | which unit does it realize? | ADR-022d, ADR-022f | module | `kind` | Draft · Proposed |
| Operating system | which OS does the system run? | ADR-022f | machine, vm, lxc | `os.family`, `os.id` | Proposed |
| Scope | Site or Environment? | ADR-022e | module | `scope` (was `tier`) | Proposed |
| Source | where does the catalog entry come from? | ADR-007b | module | `source` | Accepted |
| Management | does TAPPaaS tooling control it? | ADR-022g | module | `management` | Proposed |
| Maturity | how ready is it? | ADR-022g | module, catalog entry | `status` (two enumerations today) | Proposed |
| Realization | is it built? | ADR-022d (`realized`) · ADR-012 §2.1 (`placementState`) | module | `realized`, `placementState` | Draft · Accepted |
| Catalog domain | which functional domain, for browsing? | ADR-004 | catalog entry | `stack` → `domain` (ADR-009 :82) | Open |
| Stack | which modules realize a capability together? | ADR-009 | group of modules | — | Proposed |

**D2. Six tests before a facet is added or changed.** A proposal passes all six, with data:

1. **One question** — every resource it applies to has exactly one answer.
2. **Exhaustive** — every module in the core and Community catalogs gets a value.
3. **Exclusive** — no module fits two values; boundary cases named.
4. **Orthogonal** — cross-tabulated with existing facets; if another facet determines it fully, it is a rename, not a facet.
5. **Anchored** — one widely adopted normative source.
6. **Read** — a code reader exists, or the facet is marked catalog-only.

**D3. One owner per facet.** Only the owner ADR defines values; another ADR amends it, with reciprocal header links — added to the target when the amending ADR is accepted.

**D4. The schema is the machine source of values.** `values` in the field schema is authoritative; validators read it instead of repeating it. The register and ADRs point to it.

## Migration

- `GLOSSARY.md`: the "Three orthogonal axes" table becomes the register.
- `validate.ts` and `validate-module-tier-source.sh` read `tier` / `source` values from `module-fields.json`.

## Acceptance

- [ ] Register in `GLOSSARY.md`, one row per facet, each with an owner
- [ ] Every ADR that adds or changes a facet records the six tests with their data
- [ ] No enumeration hard-coded outside its schema
