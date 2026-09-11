# ADR-022 — Workload Ontology (Overview)

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.6 |
| **Date** | 2026-09-09 (v0.6: 2026-09-11) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen (co-owned canon) |
| **Related** | [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (classification, amended here); [ADR-007d](<ADR-007d - Site.md>) (Site, amended here); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (`Node`, superseded in part here); [ADR-014](<ADR-014 - Zone and Environment Lifecycle.md>) (zones — owner, not amended); [ADR-022d](<ADR-022d - Workload Classification.md>) (`kind`, built on this vocabulary); [ADR-024](<ADR-024 - Site Fabric.md>) (inter-Site relationships, builds on 022a); [ADR-012](ADR-012-backup-enhancement.md) (first consumer); [GLOSSARY.md](../../GLOSSARY.md) (the vocabulary SSOT this ADR updates) |
| **Changelog** | v0.1 — initial draft. Splits `Site` into three independent aspects, corrects `Node` to its ArchiMate meaning, adds `Location` and `Administrative Domain`, anchors `zone` to IEC 62443, and scopes the plane vocabulary to the network module. v0.2 — the classification rib is renamed ADR-023 → **ADR-022d** (2026-09-11 LR/EB sync), becoming a fourth rib beside 022a/b/c; the rib table and references below are updated to match. A new ADR-024 is noted as building on the Administrative-Domain aspect (022a) for inter-Site relationships — placeholder, not yet drafted at v0.2. **v0.3 corrects a boundary error in v0.2**: the "who administers it" taxonomy (`this-site`/`no-site`/`other-site`/`unknown`) had been left in ADR-022d, merely citing ADR-022a instead of living there — but 022a's own rib charter *is* "who is accountable for a resource," so the taxonomy has moved wholesale into ADR-022a D6 (with the Health consequence as D7). ADR-022d now owns exactly `kind`. Rib table and delegated-scope section below updated to match. **v0.4** moves the "Appendix A retires cleanly" mapping table here from ADR-022d — it draws on four things (022a's values, 022d's `kind`, `site.json`'s cluster-membership fact, and ADR-014/022b's zone), which makes it spine-level integration content, not any one rib's. **v0.5** adds normative-source rows for 022d's corrected `kind` enumeration (Redfish `SystemType`, Proxmox's own `qemu`/`lxc` split, OCI for the open container candidate) and retires open-question 3 (`backup:vm`/`backup:guest`), moot now that `guest` itself is retired. **v0.6** adds a `device` normative-sources row (reuses the existing ArchiMate row, no new source), corrects the stale `docker-container` label to `oci`, and adds a row for `cluster` as a **composite kind** — ArchiMate's Composition relationship plus Redfish's Composability model (`ResourceBlock`→`ComposedNode`), sharpening the existing `SystemType: Composed` citation rather than replacing it. |

One noun — `Site` — has been carrying three independent questions: **who runs it**, **where it physically is**, and **what it runs on**. Separating them is the whole of this ADR.

---

## TL;DR

- A **Site** is one TAPPaaS installation. It is **exactly one Administrative Domain**, occupies **one or more Locations**, and contains **one or more Zones**. These three vary independently.
- **`Node`** returns to its ArchiMate meaning — any computational or physical resource that hosts others. A cluster member, a bare-metal box and a VM are all Nodes. What the glossary called "Node" becomes **cluster member**.
- **`Location`** is added, with the granularity the industry already uses: postal address → rack placement → part location.
- **`Administrative Domain`** is added (RFC 4375). It is the aspect classification uses.
- **`zone`** is anchored to IEC 62443 and stays owned by ADR-014. Not re-decided here.
- Plane vocabulary (control / forwarding) is **scoped to the `network` module**, never to workloads.

## Why this is decomposed

Each of the three aspects has its own normative source, its own schema surface and its own migration. Carrying them in one document would repeat the mistake this ADR corrects. One rib per aspect:

| Rib | Decides |
|---|---|
| [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>) | Who is accountable for a resource, what trust follows from that, and the `this-site`/`no-site`/`other-site`/`unknown` taxonomy a workload's relationship to it takes (D6) — including where what-we-don't-manage is inventoried (D7) |
| [ADR-022b — Location](<ADR-022b - Location.md>) | Where a resource physically is, at three granularities |
| [ADR-022c — Node and Host](<ADR-022c - Node and Host.md>) | What a resource runs on, and what `kind` records |
| [ADR-022d — Workload Classification](<ADR-022d - Workload Classification.md>) | What `kind`'s values are — what type of device/workload something is, once 022a has confirmed it's `this-site` |

## The model — top view

```
Site  =  one Administrative Domain            (who runs it)      -> 022a
      x  one or more Locations                (where it is)      -> 022b
      x  one or more Zones                    (network position) -> ADR-014
         each workload runs on a Node          (what it runs on)  -> 022c
```

The three are orthogonal. Two live cases prove it, and they point in opposite directions:

| Case | Location | Zone | Administrative Domain |
|---|---|---|---|
| `tappaas1` | this rack | `mgmt` | this Site |
| ADR-010 satellite | **a cloud datacenter** | `edge` | this Site |
| Pre-existing local PBS (#456) | this rack | *(unmanaged)* | **not this Site** |
| A buddy TAPPaaS | elsewhere | *(none of ours)* | **another Site** |

A two-column model cannot express those four rows. That is the defect.

## Delegated, not decided here

- **Zones** — ADR-014 owns zone lifecycle, the trust lattice and enforcement. This ADR only records the definition zones already satisfy (IEC 62443) so other documents stop re-deriving it.
- **Administrative-Domain classification** — [ADR-022a](<ADR-022a - Administrative Domain.md>) decides the `this-site`/`no-site`/`other-site`/`unknown` taxonomy (D6) and where Health inventories what falls outside `this-site` (D7).
- **Workload (`kind`) classification** — [ADR-022d](<ADR-022d - Workload Classification.md>) decides what `kind`'s values are, once a workload is confirmed `this-site`. This ADR supplies the vocabulary both use.
- **Backup placement** — ADR-012 is the first consumer. It states *where PBS runs*; it does not define the words.

## Context

Five collisions, all live on `main`:

1. **`external` means five things** — a placement state that consumes a PBS by URL (ADR-012 §1.3); "not managed by this Site" (ADR-012 Appendix A); `kind: external-host`, whose two schema definitions **contradict each other** — `module-fields.json` says *"a non-module cluster guest"*, `satellite-fields.json` says *"an EXTERNAL host, NOT a Proxmox cluster:vm"*; a CLI flag in `identity/update.sh`; and *"semi-trusted external relay"* in the `edge` zone comment.
2. **`Node` contradicts the standard it cites.** `GLOSSARY.md` §B declares itself ArchiMate-based, then defines Node as "the physical Proxmox host". ArchiMate: *"a computational or physical resource that hosts, manipulates, or interacts with other computational or physical resources."* Live config already breaks the narrow reading — `config/backup.json` carries `node: "backup"`, and `site.json` lists only `tappaas1` and `tappaas2`.
3. **`Module boundary = VM boundary` has two live counterexamples** — `satellite.json` (`vmname: null`) and the `backup` module, which installs PBS on a host, not in a VM.
4. **Physical location is unnamed and has two homes.** `site-fields.json.location` is well formed ("Physical/legal location of the site", ISO 3166-1 `country`, IANA `timezone`). A satellite has no equivalent — only `provider.location`, documented as an hcloud region used for `hcloud server create` and *unused* for console-provisioned satellites.
5. **`tier` names three different things** — module lifecycle (`GLOSSARY.md` §A), zone trust (ADR-014 D5), and the Stack-promotion rule (`GLOSSARY.md` §C).

## Mapping — Appendix A retires cleanly

This is the payoff of collision 1 above: ADR-012 Appendix A's six flat values, laid out against the ribs that retire them. The **Administrative Domain** column is [ADR-022a](<ADR-022a - Administrative Domain.md>) D6's values; **`kind`** is [ADR-022d](<ADR-022d - Workload Classification.md>)'s. Neither column is redefined here — this table is a lookup across both ribs plus `site.json` (cluster membership) and the zone (ADR-014/022b), which is why it lives on the spine rather than in either rib.

| Appendix A | Administrative Domain (022a D6) | `kind` (022d) | Host is cluster member? | zone |
|---|---|---|---|---|
| `node` | `this-site` | `host` | yes | `mgmt` |
| `standalone` | `this-site` | `host` | no | `mgmt` |
| `satellite` | `this-site` | `host` | no | `edge` |
| `external` | `no-site` | — | — | — |
| `remote` | `other-site` | — | — | — |
| `rogue` | `unknown` | — | — | — |
| `shim` | — | — | — | `realized: false` |

All six terms survive as coordinates. None is lost, and no value carries two questions.

## Trade-offs & risks

- **Renaming `Node` touches the most-cited term in the composition model.** Mitigated: the *field* `node` keeps its name; only the glossary meaning widens, and `cluster member` is added for the narrow sense.
- **`kind: external-host` → `host` is a live schema value.** Seven files (`satellite-fields.json`, `module-fields.json`, `satellite.json`, `satellite-manager/lib/provision.sh`, two `test.sh`, one `module-manager` fixture). Cheap, but it is Lars's satellite work.
- **Adding `Location` to satellites is new required-ish data.** Kept to `country` at this ADR's level; finer granularity is available but not mandated.
- **Doing nothing is not free.** ADR-012 §4.1 would otherwise write `node:backup` — a false statement — into every site's config.

## Open questions / parking lot

1. Should `zone.tier` be renamed to align with IEC 62443 **Security Level**? ADR-014 owns it; raised, not decided.
2. Does `module.tier` deserve a clearer name (`lifecycle`), given `tier`'s three uses? Deferred — 22+ modules carry it.
3. ~~Should `backup:vm` become `backup:guest` once `kind` uses `guest`?~~ **Moot as of ADR-022d v0.5** — `kind: guest` was retired in favor of a `vm`/`lxc` split, and `backup:vm` already matches `kind: vm` exactly. The residual question (whether `kind: lxc` workloads should get their own backup-capability name) is tracked in ADR-022d's own open questions.

## Consequences

### Positive
- One word, one meaning. `external` stops being a placement state, a management claim and a chassis fact at once.
- ADR-012 can state where PBS runs without asserting cluster membership.
- Off-site backup becomes checkable: a Location difference is data, not an assertion.
- ADR-022d inherits settled vocabulary instead of re-coining it.

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
- [ ] `zone` anchored to IEC 62443, ownership left with ADR-014
- [ ] `Module` boundary follows `kind` (022c)
- [ ] Plane vocabulary scoped to the `network` module (022c)
- [ ] `tier` namespaced: `module.tier` / `zone.tier`; the Stack-promotion rule renamed
- [ ] `GLOSSARY.md` §A–§D rewritten to match; decision history and TODOs moved out of the vocabulary SSOT
- [ ] ADR-022d drafted against this vocabulary

## Appendix A — Normative sources

| Term | Source |
|---|---|
| Node, Device, System Software, Grouping, Aggregation, Serving, Location, Facility, Capability, Artifact | [ArchiMate 3.x](https://pubs.opengroup.org/architecture/archimate3-doc/ch-Technology-Layer.html) |
| Administrative Domain | [RFC 4375](https://www.rfc-editor.org/rfc/rfc4375.html), [RFC 1136](https://www.rfc-editor.org/rfc/rfc1136.html) |
| Location granularity (PostalAddress / Placement / PartLocation) | [DMTF Redfish DSP0268](https://www.dmtf.org/sites/default/files/standards/documents/DSP0268_2025.4.html) |
| Zone | [ISA/IEC 62443](https://gca.isa.org/blog/how-to-define-zones-and-conduits) |
| Viewpoint | ISO/IEC 42010 |
| Control / forwarding / management plane | [RFC 7426](https://www.rfc-editor.org/rfc/rfc7426.html) |
| Managed Element | [MAPE-K](https://arxiv.org/pdf/1505.00903) |
| `kind` as object-type marker | Kubernetes convention |
| `kind`'s top-level device/workload split (Physical / Virtual / Composed) | [DMTF Redfish](https://www.dmtf.org/standards/redfish) `ComputerSystem.SystemType` |
| `vm` vs `lxc` (022d's guest sub-split) | Proxmox VE's own API (`qemu` vs `lxc` endpoints) — TAPPaaS's substrate, not a third-party standard |
| `device` (022d's uninspectable-hardware value) | ArchiMate 3.x **Device** element (row 1 above) — same source, not a new one |
| Container image/runtime (022d's open `oci` candidate) | [OCI Image & Runtime Specifications](https://opencontainers.org/) |
| `cluster` as a **composite** kind, `host` as its member (022d) | ArchiMate 3.x **Composition** relationship (row 1's source — exclusive membership, unlike Aggregation); DMTF Redfish Composability (`ResourceBlock` → `ComposedNode`, the mechanism behind row-above's `SystemType: Composed`) |
| Site as a geographic level | [ISA-95 / IEC 62264-1](https://cdn.standards.iteh.ai/samples/16715/d49a9bbae3d54b639880eeb8ef21b8e8/IEC-62264-1-2013.pdf) — geographic only; does **not** cover the administrative aspect |
| Tenant | [NIST SP 800-145](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-145.pdf) — checked; **no standalone definition exists**, local term retained |
