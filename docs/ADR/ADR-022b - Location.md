# ADR-022b — Location

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.3 |
| **Date** | 2026-09-09 (v0.3: 2026-09-17) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Refines** | [ADR-007d — Site](<ADR-007d - Site.md>) (`site.json.location`) |
| **Amends** | [ADR-012](ADR-012-backup-enhancement.md) §1.4 (an off-site target declares `location.country`) |
| **Related** | [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite); [ADR-012](ADR-012-backup-enhancement.md) §1.4 (the first consumer that needs it) |
| **Changelog** | v0.3 (2026-09-17) — review #624/#637: `Facility` removed; `Room` added; Redfish properties limited to those used; Location inherits from the Site (new D4); D3/D4 renumbered D2/D3; ADR-012 §1.4 declared as amended. Earlier drafts in git history. |

Where a resource physically is — distinct from where it sits on the network.

## Decision

**D1. Adopt `Location` for physical position**, structured as [DMTF Redfish](https://www.dmtf.org/sites/default/files/standards/documents/DSP0268_2025.4.html) `Resource.Location` structures it:

| Level | Answers | Redfish property |
|---|---|---|
| **Postal address** | which building, which floor | `PostalAddress` — `Country`, `Building`, `Floor` |
| **Placement** | where in the building | `Placement` — `Room`, `Row`, `Rack`, `RackOffset` (`RackOffsetUnits`: EIA-310) |
| **Part location** | where in the chassis | `PartLocation` — `LocationType` (`Slot`, `Bay`, …) |

TAPPaaS uses only the properties listed; the rest of Redfish `Location` is out of scope. Building, room, rack and slot are **one taxonomy at three granularities**, not separate concepts. A rack is in a room, a room is in a building.

Part location is **reserved**: defined so the taxonomy is complete, not recorded until TAPPaaS tracks assets.

**D2. Location is orthogonal to zone.** IEC 62443 states it: zones are *"not geographically constrained and can span multiple physical locations."* A zone says nothing about where hardware sits, and a Location says nothing about network reach.

**D3. TAPPaaS records Location at country granularity by default.** `site-fields.json` already does this — *"Physical/legal location of the site"*, required `country` (ISO 3166-1 alpha-2) and `timezone`. Finer levels are available when a deployment needs them, never mandated.

**D4. Location is a refinement model.** A resource inherits every level it does not declare from the Site. It declares only what differs or what is finer.

Example — `site.json` declares `country: NL`. A satellite declaring `country: DE` is in DE; one declaring nothing is in NL. A resource that declares only `Placement: { Room: "utility", Rack: "R1" }` is in NL too.

**D5. Off-site must be recorded, not asserted.** A satellite has no Location today. `satellite-fields.json` carries only `provider.location`, documented as an hcloud region for `hcloud server create` — a provisioning parameter. ADR-012's off-site guarantee is physical, so it cannot be checked from configuration.

## Schema

- `site.json.location` — unchanged; it is the reference shape.
- `satellite-<name>.json` — **add** `location`, same shape as the site's. Distinct from `provider.location`, which stays a provisioning parameter.

## Migration

Additive. Existing satellites gain a `location` on the next `satellite-manager` run or by hand.

## Acceptance

- [ ] `Location` defined in `GLOSSARY.md` §A with the Redfish levels and the refinement rule
- [ ] `satellite-fields.json` gains `location`, reusing the site shape — *the schema edit itself is tracked by the ADR-012 off-site issue; this ADR only fixes the shape*
- [ ] ADR-012 §1.4 requires an off-site target to declare a `location.country` differing from the Site's
- [ ] A check exists that every declared off-site target differs in country from the Site
