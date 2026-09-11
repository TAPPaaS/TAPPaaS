# ADR-022a — Administrative Domain

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.3 |
| **Date** | 2026-09-09 (v0.3: 2026-09-11) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Amends** | [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) :43 (model diagram) · [ADR-007d](<ADR-007d - Site.md>) :13 (Decision) · [ADR-007e](<ADR-007e - Health.md>) (Health, D7) · [GLOSSARY.md](../../GLOSSARY.md) :20 — the phrase "physical + admin perimeter" appears in all three |
| **Changelog** | v0.1 — initial draft. v0.2 — D5 gained a forward reference to ADR-022d for the applied taxonomy, intended to close a duplication caught live on the 2026-09-11 LR/EB sync. **v0.3 corrects v0.2**: a citation wasn't enough — this rib's own charter *is* "who is accountable for a resource," so the applied taxonomy belongs here in full, not as a cross-reference from the classification rib. **D6 now contains the four-value taxonomy itself** (`this-site` / `no-site` / `other-site` / `unknown`, with the control-based ranking), moved wholesale from ADR-022d's former "Q1". **D7 (new)** moves the Health-inventory consequence here too, since it is a direct consequence of D6's values, not of `kind`. ADR-022d is corrected in step to contain only `kind` (device/workload type) — see its own v0.3 changelog. |

Who is accountable for a resource — the aspect classification sorts by.

## Decision

**D1. Adopt `Administrative Domain` as a first-class term**, with the IETF definition:

> The collection of resources under the control of a single administrative authority. ([RFC 4375](https://www.rfc-editor.org/rfc/rfc4375.html))

[RFC 1136](https://www.rfc-editor.org/rfc/rfc1136.html) adds the trust posture that TAPPaaS already implements: components inside one AD *"interoperate with a significant degree of mutual trust among themselves, but interoperate with other Administrative Domains in a mutually suspicious manner."*

**D2. A Site is exactly one Administrative Domain.** `Site` keeps its name, its schema and `site-manager`; it stops meaning "physical + admin perimeter" and becomes the composition of three aspects (parent ADR).

**D3. Accountability is not ownership.** The **administrator** runs a resource; the **owner** is accountable for its data and is already modelled as Organization (ADR-007a). `site.json` already carries `owner: "gridtefy"` while TAPPaaS administers — merging the two would repeat this ADR's own defect one level up.

**D4. The AD trust posture is the basis of cross-Site guarantees.** ADR-012 §1.4.1 already reasons this way — off-site copies are pull-only, the source holds no credential on its buddy — without naming the model. ADR-012 should cite RFC 1136 rather than re-derive it.

**D5. Never abbreviate it.** RFC 1136 uses `AD` as its own short form, but in an IT-operations estate `AD` reads as Active Directory — and `src/apps/windows-server/` deploys Windows Server 2025, for which Active Directory is the canonical first role. Because TAPPaaS decides one Site = one Administrative Domain, the working word in every other document is **Site**. The full term appears here, as the anchor, and nowhere else.

**D6. A workload's relationship to this Administrative Domain is one of four values.** Applies to every workload, ordered best-first by **control**: can this Site close the gap from its own side?

| Value | Administered by | Can we close it? | Defect? |
|---|---|---|---|
| `this-site` | this Administrative Domain | already ours | — |
| `no-site` | nobody TAPPaaS — third party, pre-existing | **yes** — adopt or migrate | yes, closable |
| `other-site` | another TAPPaaS Site | no — never ours | no, by design |
| `unknown` | not known to exist | find it first | yes, worst |

`no-site` ranks above `other-site` because the criterion is goal achievement, not trust: an unmanaged workload in our own domain is a gap we can close; another Site's workload never is. The **Defect?** column keeps that from reading as a demotion.

This is D1's definition and D3's accountability/ownership split, made concrete. [ADR-022d — Workload Classification](<ADR-022d - Workload Classification.md>) uses these four values — it does not define them, and only asks its own question (`kind`, what type of device/workload something is) once a workload is confirmed `this-site`.

**D7. Health owns what falls outside `this-site`.** `no-site`, `other-site` and `unknown` have no module file and never will — they are observations about the estate, not managed configuration. Health is a **viewpoint** (ISO/IEC 42010) across every classification domain, and this is exactly the surface it exists for. This amends ADR-007e, which today scopes Health to *"all classification terms"* — i.e. what is catalogued — with no place to put what is not.

## Schema

No new field at this level for D1–D5. `Site` = the AD; `site.json` is its record. D6's four values are a workload-level classification, realized against actual module/workload records by [ADR-022d](<ADR-022d - Workload Classification.md>); where D7's inventory of `no-site`/`other-site`/`unknown` observations lives is open (tracked in ADR-022d's open questions, since it is the document closest to Health's realization work).

## Migration

Documentation only. `GLOSSARY.md` §A gains `Administrative Domain`, `owner`, and the four D6 values; `Site` is rewritten; ADR-007d §Decision gains a sentence naming the three aspects; ADR-007e gains D7's amendment.

## Acceptance

- [ ] `Administrative Domain` defined in `GLOSSARY.md` §A with the RFC 4375 wording
- [ ] `Site` redefined as one AD × Locations × Zones, in both `GLOSSARY.md` and ADR-007d
- [ ] `owner` defined and distinguished from administrator
- [ ] ADR-012 §1.4.1 cites RFC 1136 instead of re-deriving the trust posture
- [ ] D6's four values (`this-site` / `no-site` / `other-site` / `unknown`) defined in `GLOSSARY.md` §A, with the ranking and Defect column
- [ ] ADR-007e amended per D7: Health covers unmanaged workloads
- [ ] ADR-022d contains no independent definition of D6's values — only uses them
