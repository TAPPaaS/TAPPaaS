# ADR-022a — Administrative Domain

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.2 |
| **Date** | 2026-09-09 (v0.2: 2026-09-11) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Amends** | [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) :43 (model diagram) · [ADR-007d](<ADR-007d - Site.md>) :13 (Decision) · [GLOSSARY.md](../../GLOSSARY.md) :20 — the phrase "physical + admin perimeter" appears in all three |
| **Changelog** | v0.1 — initial draft. v0.2 — D5 gains a forward reference to [ADR-022d](<ADR-022d - Workload Classification.md>) as the place the `this-site`/`no-site`/`other-site`/`unknown` taxonomy is formally decided, closing a duplication caught live on the 2026-09-11 LR/EB sync: ADR-022d's Q1 had independently re-derived this document's D1/D3 instead of citing them. No change to D1–D4. |

Who is accountable for a resource — the aspect classification sorts by.

## Decision

**D1. Adopt `Administrative Domain` as a first-class term**, with the IETF definition:

> The collection of resources under the control of a single administrative authority. ([RFC 4375](https://www.rfc-editor.org/rfc/rfc4375.html))

[RFC 1136](https://www.rfc-editor.org/rfc/rfc1136.html) adds the trust posture that TAPPaaS already implements: components inside one AD *"interoperate with a significant degree of mutual trust among themselves, but interoperate with other Administrative Domains in a mutually suspicious manner."*

**D2. A Site is exactly one Administrative Domain.** `Site` keeps its name, its schema and `site-manager`; it stops meaning "physical + admin perimeter" and becomes the composition of three aspects (parent ADR).

**D3. Accountability is not ownership.** The **administrator** runs a resource; the **owner** is accountable for its data and is already modelled as Organization (ADR-007a). `site.json` already carries `owner: "gridtefy"` while TAPPaaS administers — merging the two would repeat this ADR's own defect one level up.

**D4. The AD trust posture is the basis of cross-Site guarantees.** ADR-012 §1.4.1 already reasons this way — off-site copies are pull-only, the source holds no credential on its buddy — without naming the model. ADR-012 should cite RFC 1136 rather than re-derive it.

**D5. Never abbreviate it.** RFC 1136 uses `AD` as its own short form, but in an IT-operations estate `AD` reads as Active Directory — and `src/apps/windows-server/` deploys Windows Server 2025, for which Active Directory is the canonical first role. Because TAPPaaS decides one Site = one Administrative Domain, the working word in every other document is **Site**. The full term appears here, as the anchor, and nowhere else.

**D6. The applied taxonomy is decided elsewhere, not here.** This ADR defines what an Administrative Domain *is* (D1) and how accountability differs from ownership (D3); it does not enumerate the values a workload's relationship to one takes. [ADR-022d — Workload Classification](<ADR-022d - Workload Classification.md>) Q1 owns that enumeration (`this-site` / `no-site` / `other-site` / `unknown`), built directly on D1/D3. Stating the values here as well, as v0.1 did in passing, is exactly the kind of duplication this ADR corrects one level up — one concept, one place.

## Schema

No new field at this level. `Site` = the AD; `site.json` is its record. Whether a workload outside this AD is tracked, and how, is [ADR-023](<ADR-023 - Workload Classification.md>).

## Migration

Documentation only. `GLOSSARY.md` §A gains `Administrative Domain` and `owner`; `Site` is rewritten; ADR-007d §Decision gains a sentence naming the three aspects.

## Acceptance

- [ ] `Administrative Domain` defined in `GLOSSARY.md` §A with the RFC 4375 wording
- [ ] `Site` redefined as one AD × Locations × Zones, in both `GLOSSARY.md` and ADR-007d
- [ ] `owner` defined and distinguished from administrator
- [ ] ADR-012 §1.4.1 cites RFC 1136 instead of re-deriving the trust posture
- [ ] ADR-022d's Q1 cites D1/D3 rather than re-deriving them (D6)
