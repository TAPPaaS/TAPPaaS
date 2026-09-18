# ADR-022a — Administrative Domain

| | |
|---|---|
| **Status** | **Accepted** (2026-09-18) |
| **Version** | 1.0 |
| **Date** | 2026-09-09 (v1.0: 2026-09-18) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Refines** | [ADR-007d — Site](<ADR-007d - Site.md>) (what a Site is) |
| **Amends** | [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) :43 (model diagram) · [ADR-007d](<ADR-007d - Site.md>) :14–15 (intro), :34–35 (when to add a second Site) · [GLOSSARY.md](../../GLOSSARY.md) :20 — the phrase "physical + admin perimeter" appears in all three · [ADR-012](ADR-012-backup-enhancement.md) §1.4.1 (cite RFC 1136, D4) |
| **Changelog** | v1.0 (2026-09-18) — accepted (operator). D6/D7 stay parked for 2.1. · v0.4 (2026-09-17) — review #624/#637: D6/D7 (relationship taxonomy, Health inventory) parked for 2.1; D5 wording; amended anchors in ADR-007d and ADR-012 declared. Earlier drafts in git history. |

Who is accountable for a resource.

## Decision

**D1. Adopt `Administrative Domain` as a first-class term**, with the IETF definition:

> The collection of resources under the control of a single administrative authority. ([RFC 4375](https://www.rfc-editor.org/rfc/rfc4375.html))

[RFC 1136](https://www.rfc-editor.org/rfc/rfc1136.html) adds the trust posture that TAPPaaS already implements: components inside one AD *"interoperate with a significant degree of mutual trust among themselves, but interoperate with other Administrative Domains in a mutually suspicious manner."*

**D2. A Site is exactly one Administrative Domain.** `Site` keeps its name, its schema and `site-manager`; it stops meaning "physical + admin perimeter" and becomes the composition of three aspects (parent ADR).

**D3. Accountability is not ownership.** The **administrator** runs a resource; the **owner** is accountable for its data and is already modelled as Organization (ADR-007a). `site.json` already carries `owner` while TAPPaaS administers — merging the two would repeat this ADR's own defect one level up.

**D4. The AD trust posture is the basis of cross-Site guarantees.** ADR-012 §1.4.1 already reasons this way — off-site copies are pull-only, the source holds no credential on its buddy — without naming the model. ADR-012 should cite RFC 1136 rather than re-derive it.

**D5. Never abbreviate it.** RFC 1136 uses `AD` as its own short form, but in an IT-operations estate `AD` reads as Active Directory — and `src/apps/windows-server/` deploys Windows Server 2025, for which Active Directory is the canonical first role. Because a Site is one Administrative Domain, the working word in every other document is **Site**. The full term is never abbreviated and is used only in ADR-022 and its ribs; every other document says **Site**.

*Parked for 2.1:* how a workload or system relates to this Administrative Domain (the classification taxonomy and where Health inventories what TAPPaaS does not manage) — separate issue, to be decided jointly.

## Schema

No new field. `Site` = the Administrative Domain; `site.json` is its record.

## Migration

Documentation only. `GLOSSARY.md` §A gains `Administrative Domain` and `owner`; `Site` is rewritten; ADR-007d §Decision gains a sentence naming the three aspects.

## Acceptance

- [ ] `Administrative Domain` defined in `GLOSSARY.md` §A with the RFC 4375 wording
- [ ] `Site` redefined as one Administrative Domain × Locations × Zones, in both `GLOSSARY.md` and ADR-007d
- [ ] `owner` defined and distinguished from administrator
- [ ] ADR-012 §1.4.1 cites RFC 1136 instead of re-deriving the trust posture
