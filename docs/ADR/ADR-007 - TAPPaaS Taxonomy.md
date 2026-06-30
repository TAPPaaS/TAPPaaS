# ADR-007 — TAPPaaS Taxonomy (Overview)

| | |
|---|---|
| **Status** | Accepted — **implemented** on the `ADR007` branch (S0–S9, foundation realized; pending merge to `stable`) |
| **Version** | 2.4 |
| **Date** | 2026-06-30 |
| **Author** | Erik Daniel |
| **Supersedes** | ADR-007 v1.1 (monolithic) — decomposed into this overview + 007a–007e + ADR-009 |
| **Related** | #320 (taxonomy); **details:** [007a People](<ADR-007a - People.md>) · [007b Apps](<ADR-007b - Apps.md>) · [007c Environments](<ADR-007c - Environments.md>) · [007d Site](<ADR-007d - Site.md>) · [007e Health](<ADR-007e - Health.md>); **realization:** [ADR-007f](<ADR-007f - Realization.md>); **composition:** [ADR-009](<ADR-009 - Composition Meta-Model.md>) + #171; **glossary (SSOT):** [Architecture/ontology.md](<../Architecture/ontology.md>); **evidence + samples:** [Architecture/taxonomy.md](<../Architecture/taxonomy.md>); **build state + decisions:** [design/ADR-007-implementation-tracker.md](<../design/ADR-007-implementation-tracker.md>), [design/ADR-007-verb-alignment.md](<../design/ADR-007-verb-alignment.md>) |
| **Changelog** | v2.4 — **updated to the as-built design** after implementation on the `ADR007` branch (2026-06-30): the model held; the sub-ADRs are corrected where the realization diverged (Role is now a first-class People entity 007a; `network.zone` is singular + `dnsMode` + runtime cert-refid 007c; the real `site.json` 007d; `firewall`→`network`, 7 TypeScript managers + 6 controllers 007f). v2.3 — "bucket" → "classification domain" throughout; sub-ADR table column renamed (2026-06-17). v2.2 — added the consolidated ontology glossary SSOT (`Architecture/ontology.md`). v2.1 — added ADR-007f (realization mapping SSOT) |

---

## TL;DR

TAPPaaS uses **one Site**, with **3 classification domains + 1 cross-cutting lens**:

> **👥 People · 📦 Apps · 🏠 Environments · 🩺 Health (lens)**

This ADR is the **overview** of the model; the detail of each part lives in its own sub-ADR. How a
deployable unit is *built* (composition) is **ADR-009**. This ADR answers *which classification domain*
a thing is in — never *how it is built*.

This model is MECE, DRY, and matches industry-standard naming (Apple, GCP, GitHub, Authentik,
Backstage, Debian, HACS). Evidence: [Architecture/taxonomy.md](<../Architecture/taxonomy.md>).

---

## Why this is decomposed (v1.1 → v2.0)

v1.1 was a single 1000-line document mixing the decision, every domain's schema, the migration, and
the appendices. v2.0 keeps **one ADR per classification domain** so each is readable and changeable on its own. The
*model is unchanged* from v1.1 — only the structure is. This also keeps classification cleanly
separate from composition (#171), which @larsrossen asked to keep small and discussion-oriented.

---

## The model — top view

```
┌─────────────────────────────────────────────────────────────┐
│ 🏢 SITE  (the physical + admin perimeter — one TAPPaaS)      │
│   ┌───────────────────────────────────────────────────────┐ │
│   │ 👥 PEOPLE          📦 APPS          🏠 ENVIRONMENTS    │ │
│   │ Org→Group→User     tier × source    where apps run     │ │
│   └───────────────────────────────────────────────────────┘ │
│   🩺 HEALTH  (lens — observability overlay on all the above) │
└─────────────────────────────────────────────────────────────┘
```

- **Site** is the *container*, not a classification domain — one TAPPaaS = one Site. → [007d](<ADR-007d - Site.md>)
- **People · Apps · Environments** are the **3 classification domains** — every artifact is exactly one of them.
- **Health** is a **lens**, not a classification domain — a cross-cutting status overlay. → [007e](<ADR-007e - Health.md>)

### Why 3 classification domains + 1 lens

- **MECE** — every TAPPaaS artifact is exactly one of: a Person, an App, or a Place where Apps run. Zero overlap.
- **DRY** — each concept lives in one classification domain only; references by name, not duplication.
- **Apple-test** — a non-technical user understands the top nav in 30 seconds.
- **Ubiquiti-test** — scales from 1 site to many without changing the model.
- **Industry-aligned** — matches K8s, Coolify, Vercel, GCP, Apple BM, UniFi (evidence: [taxonomy.md](<../Architecture/taxonomy.md>)).

---

## Decision tree (high level — full detail in each sub-ADR)

```
A human? ............................ User             → 007a People
A legal/family/customer entity? ..... Organization     → 007a People
A collection of users (RBAC)? ....... Group            → 007a People
Something that runs? ................ App (tier+source) → 007b Apps
A zone / domain / update window? .... Environment      → 007c Environments
Hardware / ISP / IdP, site-wide? .... Site             → 007d Site
A status / metric / alarm? .......... Health (lens)    → 007e Health
```

## The sub-ADRs (1 classification domain each)

| ADR | Classification domain | Owns |
|-----|--------|------|
| [007a](<ADR-007a - People.md>) | 👥 People | Organization → Group → User; types; RBAC primitive |
| [007b](<ADR-007b - Apps.md>) | 📦 Apps | the `tier` × `source` orthogonal attributes |
| [007c](<ADR-007c - Environments.md>) | 🏠 Environments | zones, domains, `ownerOrg`, multi-tenant |
| [007d](<ADR-007d - Site.md>) | 🏢 Site | the perimeter; `site.json`; config split |
| [007e](<ADR-007e - Health.md>) | 🩺 Health | the cross-cutting lens |

A full worked example (SOHO setup), all sample JSON files, the industry-evidence data points, and the
glossary live in **[Architecture/taxonomy.md](<../Architecture/taxonomy.md>)** (living reference).

---

## Relationship to composition (delegated to ADR-009)

This taxonomy **classifies**; it does not define how a unit is **built**. The composition meta-model
(`Stack ▷ Module ▷ Component ▷ Function ▷ Service`) is **[ADR-009](<ADR-009 - Composition Meta-Model.md>)**
(tracking issue #171). The two are orthogonal: every **Module** (composition) is *classified* by
exactly one classification domain here (+ `tier` + `source`). Apply both; never one as a substitute. *Example:*
the `network` Module (ADR-009; the OPNsense firewall VM, renamed from `firewall` during implementation —
see 007f) is classified as **Environments** (this ADR); its sub-units are **Components**, not
classification domains.

## Realization (delegated to ADR-007f)

How the taxonomy is *operationalized* — the foundation modules + the `tappaas-cicd` control plane — is the
SSOT in **[ADR-007f](<ADR-007f - Realization.md>)**. The control plane mirrors the classification domains:
this overview *classifies*, ADR-007f *realizes*. **As built** (`ADR007` branch): the realization is a
two-layer control plane — **7 TypeScript Managers** (`people`, `module`, `environment`, `network`, `site`,
`backup`, `health`) exposing a uniform verb surface ([verb-alignment](<../design/ADR-007-verb-alignment.md>)),
which orchestrate **6 Controllers** (`opnsense`, `identity`, `proxmox`, `switch`, `ap`, `backup`) that do
the live I/O — superseding the original "one manager per domain / ~42 flat scripts" framing.

---

## Context

TAPPaaS previously used 4 overlapping terms — *Variants*, *Zones*, *Modules*, *configuration.json* —
that conflict and lack a unifying mental model. A clean taxonomy must be: robust, future-proof,
scalable (1 user → 50 orgs), enterprise-grade (RBAC/audit/compliance/multi-domain), use widely-adopted
naming, be B1-English, and feel Apple/Ubiquiti-opinionated. This ADR family is that taxonomy.

## Trade-offs & risks

| Risk | Impact | Mitigation |
|---|---|---|
| GDPR/DPA for hosting client data | Legal exposure | Article 30 register + DPA before onboarding `client-*` Orgs |
| Blast radius — one bad update hits family + business + clients | Multi-tenant outage | Stagger update windows: `dev`→`myhome`→`tappaas`→`mybusiness`→`client-*` |
| Authentik single point of failure | All Orgs lose SSO | HA Authentik, or accept + document |
| Community-source apps shown as official | Trust/security | Source badges (🟢/🟡/🔵/⚪); install warning for `community` |
| Foundation modules marked community | Platform breakage | Lint: `tier: foundation` ⇒ `source: official` (or override) |
| "Tenant" jargon leaks to UI | User confusion | UI says "Organization"; "tenant" only in architecture docs |

## Open questions / parking lot

| # | Item | Priority |
|---|---|---|
| 1 | `tappaas-org` legal entity (Foundation/BV/DBA?) | HIGH |
| 6 | DPA template + Article 30 register for the consultancy Org | HIGH |
| 2 | Customer hosting default — subdomain vs own-domain | MEDIUM |
| 9 | Authentik HA — accept SPOF or invest? | MEDIUM |
| 10 | Community repo location + review process | MEDIUM |
| 8 | UniFi controller — `tier: foundation` or `app`? | LOW |

(Full parking lot retained from v1.1 history.)

## Consequences

- **Positive** — one model covers Home/SMB/NGO/dev/MSP-lite/multi-org; DRY; aligns 1:1 with Authentik
  primitives; `tier`+`source` give Apple-style UX with a community ecosystem from day one.
- **Negative** — migration touches `src/foundation/` scripts; Variant→Environment needs a compat shim
  for one release; docs rewrite across `docs/Architecture/*`.
- **Neutral** — foundation/app and source are semantic/metadata only; runtime identical.

## Acceptance (overview)

Accepted when all sub-ADRs (007a–007e) are accepted and ADR-009's classification-coupling is
consistent. Per-domain acceptance criteria live in each sub-ADR; the reference doc holds the sample
files used to validate them.
