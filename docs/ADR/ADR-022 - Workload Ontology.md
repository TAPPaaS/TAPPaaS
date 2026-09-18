# ADR-022 — Workload Ontology (Overview)

| | |
|---|---|
| **Status** | **Accepted** (2026-09-18) |
| **Version** | 1.0 |
| **Date** | 2026-09-09 (v1.0: 2026-09-18) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Refines** | [ADR-007d](<ADR-007d - Site.md>) (Site) · [ADR-007b](<ADR-007b - Apps.md>) (module type) |
| **Related** | [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (classification); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (`Node`, superseded in part); [ADR-014](<ADR-014 - Zone and Environment Lifecycle.md>) (zones — owner, not amended); [ADR-024](<ADR-024 - Site Fabric.md>) (inter-Site relationships); [ADR-012](ADR-012-backup-enhancement.md) (first consumer); [GLOSSARY.md](../../GLOSSARY.md) (the vocabulary SSOT this ADR updates) |
| **Changelog** | v1.0 (2026-09-18) — accepted with its ribs 022a–h (operator). Open question 2 answered by ADR-022e (`scope`); questions 1 and 3 stay open and block nothing. · v0.12 (2026-09-17) — review #624/#637: mapping section and answered question removed; open questions shortened; rib charters aligned; proposed ribs 022e–022h listed. Earlier drafts in git history. |

One noun — `Site` — has been carrying three independent questions: **who runs it**, **where it physically is**, and **what it runs on**. Separating them is the whole of this ADR.

---

## TL;DR

- A **Site** is one TAPPaaS installation. It is **exactly one Administrative Domain**, occupies **one or more Locations**, and contains **one or more Zones**. These three vary independently.
- **`Node`** returns to its ArchiMate meaning — any computational or physical resource that hosts others. A cluster member, a bare-metal box and a VM are all Nodes. What the glossary called "Node" becomes **cluster member**.
- **`Location`** is added, with the granularity the industry already uses: postal address → placement → part location.
- **`Administrative Domain`** is added (RFC 4375).
- **`kind`** records what type of thing a module is.
- **`zone`** is anchored to IEC 62443 and stays owned by ADR-014. Not re-decided here.
- Plane vocabulary (control / forwarding) is **scoped to the `network` module**, never to workloads.

## Why this is decomposed

Each aspect has its own normative source, its own schema surface and its own migration. One rib per aspect:

| Rib | Decides |
|---|---|
| [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>) | Who is accountable for a resource, and what trust follows from that |
| [ADR-022b — Location](<ADR-022b - Location.md>) | Where a resource physically is, at three granularities |
| [ADR-022c — Node and Host](<ADR-022c - Node and Host.md>) | What a resource runs on |
| [ADR-022d — Workload Classification](<ADR-022d - Workload Classification.md>) | What type of thing a module is (`kind`) |
| [ADR-022e — Module Scope](<ADR-022e - Module Scope.md>) *(proposed)* | Whether a module belongs to the Site or to one Environment (replaces `module.tier`) |
| [ADR-022f — Kind Values and Operating System](<ADR-022f - Kind Values and Operating System.md>) *(proposed)* | `application` and `machine` as `kind` values; operating system as a facet |
| [ADR-022g — Management](<ADR-022g - Management.md>) *(proposed)* | Whether TAPPaaS tooling controls a resource; `external` reserved for the Administrative Domain |
| [ADR-022h — Facet Register](<ADR-022h - Facet Register.md>) *(proposed)* | One register of facets and the tests a new facet must pass |

## The model — top view

```
Site  =  one Administrative Domain            (who runs it)      -> 022a
      x  one or more Locations                (where it is)      -> 022b
      x  one or more Zones                    (network position) -> ADR-014
         each module runs on a Node            (what it runs on)  -> 022c
         each module has a kind                (what type it is)  -> 022d
```

The three Site aspects are orthogonal. Live cases prove it:

| Case | Location | Zone | Administrative Domain |
|---|---|---|---|
| `tappaas1` | this rack | `mgmt` | this Site |
| ADR-010 satellite | **a cloud datacenter** | `edge` | this Site |
| Pre-existing local PBS (#456) | this rack | *(unmanaged)* | **not this Site** |
| A buddy TAPPaaS | elsewhere | *(none of ours)* | **another Site** |

A two-column model cannot express those four rows. That is the defect.

## Delegated, not decided here

- **Zones** — ADR-014 owns zone lifecycle, the trust lattice and enforcement. This ADR only records the definition zones already satisfy (IEC 62443).
- **Backup placement** — ADR-012 is the first consumer. It states *where PBS runs*; it does not define the words.

## Context

Four collisions, all live on `main`:

1. **`external` means several things** — a placement state that consumes a PBS by URL (ADR-012 §1.3); `kind: external-host`, whose two schema definitions contradict each other (ADR-022d); a CLI flag in `identity/update.sh`; and *"external relay"* in the `edge` zone description.
2. **`Node` contradicts the standard it cites.** `GLOSSARY.md` §B declares itself ArchiMate-based, then defines Node as "the physical Proxmox host". `config/backup.json` carries `node: "backup"` while `site.json` lists only `tappaas1` and `tappaas2`.
3. **Physical location is unnamed and has two homes.** `site-fields.json.location` is well formed; a satellite has only `provider.location`, an hcloud provisioning parameter.
4. **`tier` names three different things** — module lifecycle (`GLOSSARY.md` §A), zone trust (ADR-014 D5), and the Stack-promotion rule (`GLOSSARY.md` §C).

## Trade-offs & risks

- **Renaming `Node` touches the most-cited term in the composition model.** Mitigated: the *field* `node` keeps its name; only the glossary meaning widens, and `cluster member` is added for the narrow sense.
- **`kind: external-host` is a live schema value** in seven code or schema files, two docs and the Community repo (ADR-022d). Cheap, but it is satellite work.
- **Adding `Location` to satellites is new data.** Kept to `country`; finer granularity is available, not mandated.

## Open questions

1. Should `zone.tier` be renamed to align with IEC 62443 **Security Level**? ADR-014 owns it; raised, not decided.
2. ~~Should `module.tier` be replaced by `stack` (#624, #637)?~~ **Answered:** no — it becomes `scope` ([ADR-022e](<ADR-022e - Module Scope.md>), accepted).
3. Does `kind: device` need an **attachment** dimension (`wired` | `wireless`)? Raised in #624; not decided.

## Consequences

### Positive
- One word, one meaning. `kind: external-host` stops naming who administers a resource while defining what it runs on.
- ADR-012 can state where PBS runs without asserting cluster membership.
- Off-site backup becomes checkable: a Location difference is data, not an assertion.

### Negative / costs
- Four new or amended documents plus a glossary rewrite, all needing joint acceptance.
- A schema-value migration in the satellite module.

### Neutral
- No runtime behaviour changes. This ADR decides words; the code changes it implies are tracked separately.

## Acceptance (overview)

- [ ] `Site` redefined as one Administrative Domain × Locations × Zones (022a, 022b; amends ADR-007d)
- [ ] `Node` corrected to ArchiMate; `cluster member` and `Host` added (022c; supersedes ADR-009's Node entry)
- [ ] `Location` added with the three granularity levels (022b)
- [ ] `Administrative Domain` added (022a)
- [ ] `kind` values recorded (022d)
- [ ] `zone` anchored to IEC 62443, ownership left with ADR-014
- [ ] Plane vocabulary scoped to the `network` module (022c)
- [ ] `tier` namespaced: `module.tier` / `zone.tier`; the Stack-promotion rule renamed (022c)
- [ ] `GLOSSARY.md` §A–§D rewritten to match; decision history and TODOs moved out of the vocabulary SSOT

## Normative sources

| Term | Source |
|---|---|
| Node, Device, System Software, Location | [ArchiMate 3.x](https://pubs.opengroup.org/architecture/archimate3-doc/ch-Technology-Layer.html) |
| Administrative Domain | [RFC 4375](https://www.rfc-editor.org/rfc/rfc4375.html), [RFC 1136](https://www.rfc-editor.org/rfc/rfc1136.html) |
| Location granularity (`PostalAddress` / `Placement` / `PartLocation`) | [DMTF Redfish DSP0268](https://www.dmtf.org/sites/default/files/standards/documents/DSP0268_2025.4.html) `Resource.Location` |
| Zone | [ISA/IEC 62443](https://gca.isa.org/blog/how-to-define-zones-and-conduits) |
| Control / forwarding / management plane | [RFC 7426](https://www.rfc-editor.org/rfc/rfc7426.html) |
| Managed Element | [MAPE-K](https://arxiv.org/pdf/1505.00903) |
| `vm`, `lxc`, `host` | [DMTF Redfish](https://www.dmtf.org/standards/redfish) `ComputerSystem.SystemType` (`Virtual`, `Physical`); Proxmox VE API (`qemu` vs `lxc`) |
| `device` | ArchiMate 3.x **Device** |
| `oci` (proposed) | [OCI Image & Runtime Specifications](https://opencontainers.org/) |
