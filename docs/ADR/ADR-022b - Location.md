# ADR-022b — Location

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.2 |
| **Date** | 2026-09-09 (v0.2: 2026-09-11) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Related** | [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite); [ADR-012](ADR-012-backup-enhancement.md) §1.4 (the first consumer that needs it) |
| **Changelog** | v0.1 — initial draft. **v0.2** retires D2 (`Facility`): flagged in review (#624) as overlapping Location and unused by any proposed field, no elaboration followed, so removed per Lars's follow-up rather than left ambiguous. |

Where a resource physically is — distinct from where it sits on the network.

## Decision

**D1. Adopt `Location` for physical position**, structured as [DMTF Redfish](https://www.dmtf.org/sites/default/files/standards/documents/DSP0268_2025.4.html) already structures it:

| Level | Answers | Redfish property |
|---|---|---|
| **Postal address** | which building | `PostalAddress` |
| **Placement** | where in the room | `Placement` — `Row`, `Rack`, `RackOffset` (EIA-310 units) |
| **Part location** | where in the chassis | `PartLocation` — `Bay`, `Slot`, `Socket`, `Connector` |

Street address, rack address and rack slot are **one taxonomy at three granularities**, not three concepts.

**D2.** ~~`Facility` names the building level — ArchiMate: *"a physical structure or environment"* (office buildings, laboratories, **data centers**). It is a level inside Location, not a synonym for it.~~ **Removed (v0.2)** — not used by D1's Redfish levels or by the Schema section below; the ArchiMate overlap with Location that Lars flagged (#624) was never elaborated, so removed rather than left unresolved.

**D3. Location is orthogonal to zone.** IEC 62443 states it: zones are *"not geographically constrained and can span multiple physical locations."* A zone says nothing about where hardware sits, and a Location says nothing about network reach.

**D4. TAPPaaS records Location at country granularity by default.** `site-fields.json` already does this well — *"Physical/legal location of the site"*, required `country` (ISO 3166-1 alpha-2) and `timezone`. That shape is the standard; finer levels are available when a deployment needs them, never mandated.

**D5. Off-site must be recorded, not asserted.** A satellite has no Location today. `satellite-fields.json` carries only `provider.location`, documented as *"Tier B (allocation=api) ONLY — hcloud region for `hcloud server create`. For Tier A you pick it in the console (satellite-manager doesn't use it)."* That is a provisioning parameter. Consequence: ADR-012's off-site guarantee — a **physical** guarantee — cannot be checked from configuration, and its Testing section has no test for it.

## Schema

- `site.json.location` — unchanged; it is the reference shape.
- `satellite-<name>.json` — **add** `location`, same shape as the site's (required `country`). Distinct from `provider.location`, which stays a provisioning parameter.

## Migration

Additive. Existing satellites gain a `location` on next `satellite-manager` run or by hand; absent means "unknown", which a check can report rather than assume.

## Acceptance

- [ ] `Location` defined in `GLOSSARY.md` §A with the Redfish levels
- [ ] `satellite-fields.json` gains `location`, reusing the site shape — *the schema edit itself is tracked by the ADR-012 off-site issue; this ADR only fixes the shape*
- [ ] ADR-012 §1.4 requires an off-site target to declare a `location.country` differing from the Site's
- [ ] A check exists that every declared off-site target differs in country from the Site
