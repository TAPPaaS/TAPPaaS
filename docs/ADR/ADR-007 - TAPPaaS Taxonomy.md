# ADR-001 — TAPPAAS Taxonomy & Meta-Model

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.1 |
| **Date** | 2026-06-09 |
| **Supersedes** | Old terminology: *Variants*, *Modules*, *Tenants* |
| **Related** | configuration.json, zones.json, module-fields.json, Authentik tenants |

---

## TL;DR

TAPPAAS uses **one Site**, with a **3-bucket top-level taxonomy + 1 cross-cutting lens**:

> **👥 People · 📦 Apps · 🏠 Environments · 🩺 Health (lens)**

- **People** is a 3-level hierarchy: **Organization → Group → User**
- **Apps** have two orthogonal attributes:
  - **`tier`** — `foundation` (cannot uninstall) or `app` (user-installable)
  - **`source`** — `official` (TAPPAAS-maintained) or `community` (peer-reviewed) or `private` (your own catalog) or `local` (dev work)
- **Environments** carry an **`ownerOrg`** tag
- **Health** is an overlay, not a bucket

This model is MECE, DRY, and matches industry-standard naming used by Apple, GCP, GitHub, Authentik, Backstage, Debian, and HACS. Evidence in [Appendix A](#appendix-a--industry-evidence-data-points).

---

## related ADRs

ADR-004 (/home/tappaas/TAPPaaS/docs/ADR/ADR-004-module-catalog-config-cascade.md)
ADR-005 (/home/tappaas/TAPPaaS/docs/ADR/ADR-005-variant-domain-architecture.md)
ADR-006 (/home/tappaas/TAPPaaS/docs/ADR/ADR-006-identity-users-and-roles.md)

---

## Reading guide (progressive disclosure)

| If you want... | Read |
|---|---|
| The decision in one paragraph | [TL;DR](#tldr) |
| The visual model | [Decision → The Model](#the-model--top-view) |
| Schemas to copy-paste | [Artifacts — Schemas](#the-artifacts--schemas) |
| Decide which bucket your file goes in | [Mapping Rules → Decision Tree](#decision-tree) |
| Old → new term conversion | [Mapping Rules → Migration Table](#old-term--new-term-migration-table) |
| A full worked example | [Concrete Application](#concrete-application--example-soho-setup) |
| Step-by-step migration | [Migration Path](#migration-path--from-current-config-to-new-model) |
| The data behind each decision | [Appendix A](#appendix-a--industry-evidence-data-points) |
| Ready-to-commit JSON files | [Appendix B](#appendix-b--sample-files-for-the-example-soho) |

---

## Context

TAPPAAS currently uses 4 internal terms — *Variants*, *Zones*, *Modules*, *configuration.json* — that overlap, conflict, and lack a unifying mental model. New users cannot answer:

- "Who can access what?"
- "What runs where?"
- "How do I host my family AND my business AND my clients on one TAPPAAS?"
- "Is the firewall an App or something else?"
- "How do I publish a community-built app?"

A clean taxonomy is required before adding more features. It must be:

1. **Robust** — survives future use cases without breaking
2. **Future-proof** — handles 1-tenant home setups *and* multi-org consultancies
3. **Scalable** — works from 1 user to 50 organizations
4. **Enterprise-grade** — supports RBAC, audit, compliance, multi-domain
5. **Widely adopted naming** — uses terms users already know from other platforms
6. **B1 English** — understandable for non-technical personas (Home, NGO, SMB)
7. **Apple/Ubiquiti-style UX** — opinionated, simple, "it just works"

---

## Decision

Adopt the model below as the canonical TAPPAAS meta-model. All schemas, docs, and UI labels follow it.

### The Model — Top View

```
┌─────────────────────────────────────────────────────────────┐
│ 🏢 SITE  (the physical + admin perimeter — one TAPPAAS)     │
│                                                              │
│   ┌───────────────────────────────────────────────────────┐ │
│   │ 👥 PEOPLE          📦 APPS          🏠 ENVIRONMENTS   │ │
│   │ ───────────        ──────────       ──────────────    │ │
│   │ Organizations      tier: app        (where apps run)  │ │
│   │  └ Groups          tier: foundation                   │ │
│   │     └ Users        + source: official|community|...   │ │
│   └───────────────────────────────────────────────────────┘ │
│                                                              │
│   🩺 HEALTH  (lens — observability overlay on all the above)│
└─────────────────────────────────────────────────────────────┘
```

### Why 3 Buckets + 1 Lens?

- **MECE** — Every TAPPAAS artifact is exactly one of: Person, App, or Place where Apps run. Zero overlap.
- **DRY** — Each concept lives in one bucket only.
- **Apple-test** — A non-technical user understands the top nav in 30 seconds.
- **Ubiquiti-test** — Scales from 1 site to many without changing the model.
- **Industry-aligned** — Matches K8s, Coolify, Vercel, GCP, Apple BM, UniFi (see [App. A.1](#a1--top-level-concept-frequency-across-18-platforms)).

---

## The Artifacts — Schemas

> Examples below use generic placeholders. Replace with your own values:
> - `<owner>` — the TAPPAAS site administrator (e.g. the founder) with email `<owner>@myhomedomain.nl`
> - `person2`, `person3`, `person4` — other household members (partner, kids)
> - `mybusiness-bv` — a company Organization
> - `myhomedomain.nl` — your private root domain

### 🏢 Site

**Definition:** The physical + admin perimeter. One TAPPAAS = one Site. Holds everything shared across all environments inside it: hardware, WAN, DNS, IdP, backup target, admin team.

**When to add a second Site:** Different ISP, different physical hardware, different legal admin team, or a DR location.

**Schema** (`/home/tappaas/config/site.json`):

```json
{
  "name": "mysite-soho",
  "displayName": "My SOHO",
  "owner": "<owner>",
  "location": {
    "country": "NL",
    "timezone": "Europe/Amsterdam",
    "locale": "nl_NL"
  },
  "network": {
    "isp": "<your-isp>",
    "publicIp": "auto",
    "rootDomain": "myhomedomain.nl"
  },
  "dns": {
    "provider": "<your-dns-provider>",
    "credentialsRef": "secrets/dns-provider"
  },
  "hardware": {
    "nodes": ["tappaas1", "tappaas2"],
    "storagePools": ["tanka1", "tanka2", "tankb2"],
    "cluster": "tappaas"
  },
  "identityProvider": {
    "type": "authentik",
    "url": "https://id.myhomedomain.nl"
  },
  "backup": {
    "target": "backup.myhomedomain.nl",
    "offsite": "tappaas-backup-buddy"
  },
  "updateChannel": "stable"
}
```

---

### 👥 People — 3-Level Hierarchy

**Hierarchy:** `Organization → Group → User`. A User can belong to many Groups across many Organizations.

#### Organization

**Definition:** The legal + identity entity. Maps 1:1 to an Authentik tenant. Owns Environments and Apps.

**Types:** `family` · `company` · `foundation` · `customer`

**Schema** (`/home/tappaas/config/people/organizations/{name}.json`):

```json
{
  "name": "mybusiness-bv",
  "type": "company",
  "displayName": "MyBusiness BV",
  "owner": "<owner>",
  "legalEntity": "MyBusiness BV",
  "jurisdiction": "NL",
  "kvk": "12345678",
  "primaryDomain": "mybusiness.nl",
  "aliasDomains": ["mybusiness.com"],
  "aliasMode": "redirect",
  "authentikTenant": "id.mybusiness.nl",
  "billing": {
    "invoicedBy": "self"
  },
  "dataResidency": "eu-only",
  "parentOrg": null
}
```

For a **customer**, add:

```json
{
  "name": "client-acme",
  "type": "customer",
  "parentOrg": "mybusiness-bv",
  "billing": {
    "invoicedBy": "mybusiness-bv",
    "contractRef": "DPA-YYYY-NNN"
  },
  "dpaSigned": "YYYY-MM-DD"
}
```

#### Group

**Definition:** A collection of Users within one Organization. Maps 1:1 to an Authentik group. The primitive for RBAC.

**Types:** `team` · `department` · `family-members` · `access-set` · `ad-hoc`

The `type` field drives UI labels (e.g. `type: family-members` shows "Members" in UI; `type: team` shows "Team"; default shows "Group").

**Schema** (`/home/tappaas/config/people/groups/{org}__{name}.json`):

```json
{
  "name": "mybusiness-bv__staff",
  "type": "team",
  "displayName": "MyBusiness Staff",
  "ownerOrg": "mybusiness-bv",
  "members": ["<owner>", "person2"],
  "authentikGroup": "mybusiness-bv-staff",
  "roles": ["editor"]
}
```

#### User

**Definition:** An individual human. Belongs to one or more Groups (across one or more Organizations).

**Schema** (`/home/tappaas/config/people/users/{name}.json`):

```json
{
  "name": "<owner>",
  "displayName": "<Site Administrator>",
  "primaryEmail": "<owner>@myhomedomain.nl",
  "memberOf": [
    "myhome__family",
    "mybusiness-bv__staff",
    "tappaas-org__maintainers"
  ],
  "authentikUser": "<owner>"
}
```

**Contextual UI labels** for the same User:

| Group context | UI label shown |
|---|---|
| `myhome__family` (`type: family-members`) | "Family Member" |
| `mybusiness-bv__staff` (`type: team`) | "Staff" |
| `tappaas-org__maintainers` (`type: team`) | "Maintainer" |
| (global admin view) | "User" |

---

### 📦 Apps

**Definition:** The things that run. A workload (VM, container, service) with lifecycle: install, update, test, backup, delete. Owned by a Group. Lives in one Environment.

Apps have **two orthogonal attributes**:

| Attribute | Values | Answers |
|---|---|---|
| **`tier`** | `foundation` · `app` | *Can it be uninstalled?* (lifecycle role) |
| **`source`** | `official` · `community` · `private` · `local` | *Where does the catalog entry come from?* (origin & trust) |

#### Why tier and source are separate

A community app is still an *App* (same install/update/uninstall lifecycle) — it just comes from a different repo with different support guarantees. Mixing the two into one enum would break MECE. Industry confirms this (Debian, Home Assistant HACS, Nextcloud, Synology, Umbrel, YunoHost — see [App. A.7](#a7--source-vs-tier-curated-vs-community-patterns)).

#### Tier values

| Tier | Meaning | Example |
|---|---|---|
| `foundation` | Comes with platform, cannot uninstall, locks the platform if removed | `firewall`, `cluster`, `identity`, `caddy`, `backup`, `tappaas-cicd` |
| `app` | User-installable, freely removable | `openwebui`, `nextcloud`, `vaultwarden` |

#### Source values

| Source | Meaning | UI badge |
|---|---|---|
| `official` | TAPPAAS-maintained, signed, supported by the foundation | 🟢 Verified |
| `community` | TAPPAAS-community repo, peer-reviewed but not officially supported | 🟡 Community |
| `private` | Hosted in a private/customer repo (e.g. a consultancy's internal apps) | 🔵 Private |
| `local` | Developed locally, not in any catalog yet | ⚪ Local |

#### Tier × Source — Valid Combinations

| | source: official | source: community | source: private | source: local |
|---|---|---|---|---|
| **tier: foundation** | ✅ Normal case | 🟡 Rare (community fork) | ✅ Custom platform modules | ✅ Dev work |
| **tier: app** | ✅ Normal case | ✅ Most community apps | ✅ Customer-specific apps | ✅ Dev work |

Every App is exactly one cell — naturally MECE.

#### Schema

Folder name kept as `modules/` for filesystem backward compatibility (`/home/tappaas/config/modules/{name}.json`):

```json
{
  "module": "openwebui",
  "displayName": "OpenWebUI",
  "tier": "app",
  "source": "official",
  "sourceMetadata": {
    "repo": "https://github.com/tappaas-org/openwebui-module",
    "maintainer": "tappaas-org",
    "supportLevel": "supported",
    "verifiedBy": "tappaas-org"
  },
  "version": "0.4.1",
  "ownerGroup": "mybusiness-bv__staff",
  "environment": "mybusiness",

  "vmname": "openwebui",
  "vmid": 311,
  "node": "tappaas2",
  "cores": 4,
  "memory": "4096",
  "diskSize": "50G",
  "storage": "tanka1",
  "imageType": "clone",
  "image": "8080",
  "bridge0": "lan",
  "zone0": "srv-mybusiness",
  "proxyDomain": "openwebui.mybusiness.nl",
  "proxyPort": 8080,

  "dependsOn": ["cluster:vm", "litellm:models", "identity:sso"],
  "provides": [],

  "backup": {
    "policy": "daily-30d",
    "items": ["postgres", "redis", "container-data", "secrets"]
  }
}
```

**Foundation example:**

```json
{
  "module": "firewall",
  "displayName": "OPNsense Firewall",
  "tier": "foundation",
  "source": "official",
  "sourceMetadata": {
    "repo": "https://github.com/tappaas-org/firewall-module",
    "maintainer": "tappaas-org",
    "supportLevel": "supported"
  },
  "version": "24.7",
  "ownerGroup": "myhome__admins",
  "environment": "site-wide",
  "dependsOn": [],
  "provides": ["proxy", "vpn", "dhcp", "dns"]
}
```

**Community example:**

```json
{
  "module": "some-cool-app",
  "displayName": "Some Cool App",
  "tier": "app",
  "source": "community",
  "sourceMetadata": {
    "repo": "https://github.com/tappaas-community/some-cool-app",
    "maintainer": "@community-contributor",
    "supportLevel": "best-effort",
    "verifiedBy": null
  },
  "version": "1.0.0",
  "ownerGroup": "myhome__family",
  "environment": "myhome",
  "dependsOn": ["cluster:vm"]
}
```

---

### 🏠 Environments

**Definition:** Where apps run. Carries network zones, domain, update window, security posture. Owned by exactly one Organization.

**When to add a second Environment per Org:** Different update timing, different domain, different security posture, multi-tenant on same hardware, or dev/staging/prod separation.

**Schema** (`/home/tappaas/config/environments/{name}.json`):

```json
{
  "name": "mybusiness",
  "displayName": "MyBusiness Production",
  "ownerOrg": "mybusiness-bv",

  "domains": {
    "primary": "mybusiness.nl",
    "aliases": ["mybusiness.com"],
    "aliasMode": "redirect"
  },
  "customerSubdomainPattern": "{cust}.mybusiness.nl",

  "network": {
    "zone": "srv-mybusiness",
    "vlan": 220,
    "firewallPosture": "strict"
  },

  "authentikTenant": "id.mybusiness.nl",

  "updateWindow": "saturday-02:00-cet",
  "updateChannel": "stable",

  "backup": {
    "retention": "7y",
    "residency": "eu-only"
  },

  "legal": {
    "processor": "MyBusiness BV"
  }
}
```

---

### 🩺 Health — The Lens

**Definition:** Not a bucket. A cross-cutting *overlay* that shows status on People, Apps, and Environments.

**Examples:**

- 🟢 Badge next to an App = service responding, recent backup OK
- 🟡 Badge next to an Environment = one node degraded, others fine
- 🔴 Badge next to a User = MFA expired
- Site-level health page = system-wide overview (the only dedicated Health UI page)

**Why a lens, not a bucket:** Folding observability into each artifact's status badge gives the Apple "it just works" feel for non-technical users, while preserving a cross-cutting view at the Site-level for ops users.

---

## Mapping Rules — How to Classify Any TAPPAAS Thing

### Decision Tree

```
What am I looking at?

├─ A human?
│   └─ User
│
├─ A legal entity, family, or customer?
│   └─ Organization (type = family|company|foundation|customer)
│
├─ A collection of Users for access control?
│   └─ Group (type = team|department|family-members|access-set|ad-hoc)
│
├─ Something that runs (VM, container, service)?
│   ├─ Q1: Comes with the platform, cannot uninstall?
│   │     YES → tier: foundation        NO → tier: app
│   └─ Q2: Where does its catalog entry come from?
│         TAPPAAS official repo  → source: official
│         TAPPAAS community repo → source: community
│         A private/customer repo → source: private
│         Local dev (not in any catalog) → source: local
│
├─ A network zone, domain, update window, firewall scope?
│   └─ Environment
│
├─ Hardware, ISP, root domain, IdP — shared across everything?
│   └─ Site
│
└─ A status indicator, log, metric, alarm?
    └─ Health (lens — surfaces on the artifact it relates to)
```

### Old Term → New Term (Migration Table)

| Old TAPPAAS term | New term | Schema field | Notes |
|---|---|---|---|
| Variant | Environment | `environments/{name}.json` | One file per env |
| Module | App | (keep `modules/` folder name for compat) | UI label changes |
| Module dependency | App dependency | `dependsOn` | Unchanged |
| Module that is platform infra | App with `tier: foundation` | `modules/{name}.json` + `tier` | New field |
| Module from community repo | App with `source: community` | `modules/{name}.json` + `source` | New field |
| Tenant | Organization (user-facing) / multi-tenant (architecture term) | `organizations/{name}.json` | Tenant kept ONLY as architecture noun |
| Zone | (kept) | inside Environment | Zone = network-implementation of Env |
| configuration.json (mixed) | Split into `site.json` + `environments/*.json` | — | See migration path |
| User group | Group | `groups/{org}__{name}.json` | Universal IAM primitive |
| Variant manager | Environment manager | — | Renamed |

### How to Map an Existing TAPPAAS Script or Module

For each file in `src/`, ask:

1. **Is it a foundation service (`src/foundation/`)?** → Map to App with `tier: foundation`, `source: official`, derive owner from the platform admin group.
2. **Is it a user app (`src/apps/`)?** → Map to App with `tier: app`, `source: official`, owner = installing Group, env = installer's choice.
3. **Is it from the community repo?** → Map to App with `source: community` (tier depends on whether it can be uninstalled).
4. **Is it a script that touches the cluster, network, or IdP globally?** → It implements Site-level behavior. Document as such.
5. **Does it touch zones, domains, firewall pinholes?** → It implements Environment-level behavior.
6. **Does it manage user accounts, secrets, SSO?** → It implements People-level behavior.

---

## Concrete Application — Example SOHO Setup

A founder runs a household, a consulting company, contributes to TAPPAAS, and hosts one paying client. All on one physical TAPPAAS Site.

```
🏢 Site: mysite-soho
    │
    ├── 👥 People
    │     ├── Organizations
    │     │     ├── myhome          (type: family,     domain: myhomedomain.nl)
    │     │     ├── mybusiness-bv   (type: company,    domain: mybusiness.nl + .com alias)
    │     │     ├── tappaas-org     (type: foundation, domain: tappaas.org)
    │     │     └── client-acme     (type: customer,   parentOrg: mybusiness-bv)
    │     │
    │     ├── Groups
    │     │     ├── myhome__family
    │     │     ├── mybusiness-bv__staff
    │     │     ├── tappaas-org__maintainers
    │     │     ├── tappaas-org__contributors
    │     │     └── client-acme__admins
    │     │
    │     └── Users
    │           ├── <owner>           (site administrator — member of: myhome__family, mybusiness-bv__staff, tappaas-org__maintainers)
    │           ├── person2 (partner) (member of: myhome__family)
    │           ├── person3 (kid)     (member of: myhome__family)
    │           └── person4 (kid)     (member of: myhome__family)
    │
    ├── 🏠 Environments
    │     ├── myhome       (ownerOrg: myhome,         zone: srv-home,        domain: myhomedomain.nl)
    │     ├── mybusiness   (ownerOrg: mybusiness-bv,  zone: srv-mybusiness,  domain: mybusiness.nl)
    │     ├── tappaas      (ownerOrg: tappaas-org,    zone: srv-tappaas,     domain: tappaas.org)
    │     ├── client-acme  (ownerOrg: client-acme,    zone: srv-client-acme, domain: acme.mybusiness.nl)
    │     └── dev          (ownerOrg: tappaas-org,    zone: srv-dev,         used cross-Org for labs)
    │
    └── 📦 Apps
          ├── Foundation tier (tier=foundation, source=official)
          │     firewall · cluster · identity · caddy · backup · tappaas-cicd
          │
          ├── App tier — official  (tier=app, source=official)
          │     openwebui, vaultwarden, nextcloud, gitea, ...
          │
          ├── App tier — community  (tier=app, source=community)
          │     some-cool-app from tappaas-community repo
          │
          └── App tier — private  (tier=app, source=private)
                consultancy-customer-portal in mybusiness-bv's own repo
```

---

## Secrets — Where They Live

Secrets are distributed by **what consumes them**, with RBAC (in People) controlling access:

| Secret type | Bucket | Example | File location |
|---|---|---|---|
| Personal credential | 👥 People | Login password, MFA, personal Bitwarden vault | Authentik + Vaultwarden |
| Workload secret | 📦 App | DB password, OAuth client secret, API key the app uses | App-scoped secret store, referenced by `secretsRef` |
| Infrastructure secret | 🏢 Site | TLS cert key, DNS API token, cluster join token | `site.json` references, vault-managed |

**Rule of thumb:** Secret belongs to the *thing that consumes it*. People-bucket RBAC decides *who can read or change it*.

---

## Trade-offs & Risks

| Risk | Impact | Mitigation |
|---|---|---|
| GDPR / DPA obligations for hosting client data | Legal exposure if no DPA | Article 30 register + DPA template before onboarding `client-*` Orgs |
| Blast radius — one bad update hits family + business + clients | Multi-tenant outage | Stagger update windows: `dev` → `myhome` → `tappaas` → `mybusiness` → `client-*` |
| Authentik single point of failure | All Orgs lose SSO at once | HA Authentik, or accept and document |
| Cost allocation across Orgs (NL tax) | Belastingdienst may ask | Tag resource use per `ownerOrg`, allocate hardware/power proportionally |
| `tappaas-org` legal entity unclear | Affects `legalProcessor` field | Open question — see [Parking Lot](#open-questions--parking-lot) |
| "Tenant" jargon leaking into UI | User confusion | Strict rule: UI says "Organization", only architecture docs say "multi-tenant" |
| Community-source apps misrepresented as official | Trust failure, security risk | UI badges per source (🟢/🟡/🔵/⚪); install warning for `source: community` |
| Foundation modules marked as community | Platform breakage | Lint rule: `tier: foundation` requires `source: official` (or explicit override) |

---

## Migration Path — From Current Config to New Model

### Phase 1 — Add new without breaking old (zero downtime)

1. Create `/home/tappaas/config/site.json` (copy site-wide fields from `configuration.json`).
2. Create `/home/tappaas/config/people/` directory tree (organizations, groups, users).
3. Add `tier`, `source`, `sourceMetadata`, and `ownerGroup` fields to `module-fields.json` schema. Default existing modules to `tier: app`, `source: official`. Mark foundation modules as `tier: foundation`.
4. Add `ownerOrg` to environment definitions; default to the family Org for legacy.

### Phase 2 — Split configuration.json into site.json + environments/

5. Identify which fields in `configuration.json` are Site-level vs Environment-level (table below).
6. Move Site-level fields to `site.json`, keep Environment-level in `environments/default.json`.
7. Update all scripts that read `configuration.json` to read from `site.json` first, fall back to old file.
8. Mark old `configuration.json` as deprecated, schedule removal in 2 minor releases.

### Phase 3 — Rename "Variant" → "Environment" in code and docs

9. Symlink `copy-update-json.sh --variant` to also accept `--environment` (same behavior).
10. Update docs and CLI help text. Deprecate `--variant` in next major release.

### Phase 4 — Surface multi-Org UX + Community catalog

11. Add Organization picker to relevant CLI commands and UI.
12. Add `ownerOrg` validation in `install-module.sh`.
13. Define community repo location, review process, and trust signal badges in UI.
14. Document the multi-tenant + community-source workflows.

### Configuration field migration map

| Current `configuration.json` field | Goes to |
|---|---|
| `domain`, `rootDomain` | `site.json → network.rootDomain` |
| `nodes` | `site.json → hardware.nodes` |
| `dns provider` | `site.json → dns` |
| `backup target` | `site.json → backup` |
| `timezone`, `locale` | `site.json → location` |
| `updateSchedule` | `environments/default.json → updateWindow` |
| `subdomain prefix` | `environments/{name}.json → domains` |
| `active zones` | `environments/{name}.json → network.zone` |

---

## Open Questions / Parking Lot

| # | Item | Priority | Next action |
|---|---|---|---|
| 1 | `tappaas-org` legal entity — Foundation, BV, or DBA? | HIGH | Decide before client onboarding; affects `legalProcessor` |
| 2 | Customer hosting default — subdomain vs own-domain | MEDIUM | Pick default offer, allow upgrade |
| 3 | Alias modes per Org (redirect vs mirror vs split) | LOW | One-sentence intent statement per alias |
| 4 | DNS reservations for `tappaas.org` subdomains (docs/demo/community/git/id/status) | LOW | 5-min DNS task |
| 5 | Family sub-groups (parents/kids/guests) | LOW | YAGNI until first parental-control app |
| 6 | DPA template + Article 30 register for the consultancy Org | HIGH | Legal blocker for client hosting |
| 7 | TAPPAAS positioning as "MSP-lite for solopreneurs" | STRATEGIC | Validate with 3-5 target users |
| 8 | UniFi controller — `tier: foundation` or `tier: app`? | LOW | Per-Site decision in `site.json` |
| 9 | Authentik HA — accept SPOF or invest? | MEDIUM | Risk-based, defer until > 2 clients |
| 10 | Community repo location and review process | MEDIUM | Decide Git org structure, review checklist, signing rules |
| 11 | Trust signal UI design (HACS-style badges) | LOW | Post-MVP UX work |
| 12 | Private/customer catalogs | LOW (or HIGH if MSP-lite) | Define how a consultancy hosts its own catalog |

---

## Consequences

### Positive

- One model covers Home, SMB, NGO, dev, MSP-lite, and multi-org consulting setups.
- DRY: each concept lives in one place; references are by name, not duplication.
- Aligns 1:1 with Authentik primitives (Tenant, Group, User).
- `tier` + `source` separation gives Apple-iOS-style UX with a single pipeline — and supports community ecosystem from day one.
- Industry-aligned naming reduces learning curve for new users.

### Negative

- Migration touches scripts across `src/foundation/`.
- Renaming Variant → Environment requires backward-compat shims for one release cycle.
- File-tree restructuring affects backup scripts, snapshot paths, and docs.
- Documentation rewrite needed across `docs/Architecture/*`.
- Community catalog needs governance setup before launch.

### Neutral

- Foundation/App distinction is semantic only — runtime is identical.
- Source is metadata only — runtime is identical regardless of where the catalog entry came from.

---

## Acceptance Criteria

This ADR is accepted when:

- [ ] `site.json` schema validated by `validate-configuration.sh`
- [ ] Sample `organizations/`, `groups/`, `users/` files created
- [ ] `tier`, `source`, `sourceMetadata`, `ownerGroup` added to `module-fields.json`
- [ ] At least one module re-tagged with new schema and passes `install-module.sh`
- [ ] At least one `source: community` module installed end-to-end as proof
- [ ] Migration of `configuration.json` documented step-by-step
- [ ] UI mockup of 3-bucket nav + Health lens + source badges reviewed

---

# Appendix A — Industry Evidence (Data Points)

All design decisions in this ADR are backed by frequency analysis across 18+ platforms. Below is the raw evidence per decision.

## A.1 — Top-level concept frequency across 18 platforms

Why **People · Apps · Environments** as the three buckets:

| Concept | Found in | Count |
|---|---|---|
| Identity / People / Users (some form) | All 18 | 18/18 |
| App / Workload / Service (some form) | All 18 | 18/18 |
| Environment | K8s, Coolify, Vercel, Backstage (System), GCP, AWS, Azure, Heroku | 8/10 |
| Project / Site (above Env) | Coolify, Vercel, UniFi, Backstage, AWS, Azure, GCP, Apple BM | 8/10 |
| Resource (distinct from App) | AWS, Azure, GCP, K8s, Backstage, Coolify | 6/10 |
| Health / Observability as separate bucket | K8s, UniFi, Backstage, AWS, Azure, GCP, Synology | 7/10 |

**Conclusion:** People, Apps, Environments are universal. Health is universally tracked but variably positioned — TAPPAAS chooses *lens* over *bucket* for prosumer UX.

## A.2 — "Tenant" vs "Organization" naming

Why we use **Organization** in UI and **tenant** only as architecture term:

| Term | Platforms using it | Count |
|---|---|---|
| **Organization / Org** | GCP, GitHub, Okta, Salesforce, HashiCorp Cloud, Google Workspace, Apple Business Manager, AWS Organizations, Auth0 (B2B), Microsoft (user-facing) | **10** |
| Tenant | Azure (technical), Authentik, Auth0 (technical), Microsoft 365 (admin docs) | 4 |
| Workspace | Slack, Notion | 2 |
| Team | Vercel | 1 |
| Group | GitLab | 1 |
| Family | Apple Family Sharing | 1 (consumer) |
| Realm | Keycloak | 1 |
| Account | AWS (per-account), UniFi | 1-2 |

**Conclusion:** Organization wins ~2.5×. Tenant is for *architecture docs only*.

## A.3 — "Group" vs "Team" for the middle People layer

Why we use **Group** as primitive, with `type: team` as optional display label:

**Identity / IAM systems (where TAPPAAS plugs in):**

| System | Term |
|---|---|
| LDAP, Active Directory, Authentik, Keycloak, AWS IAM, Azure AD/Entra, GCP IAM, Okta, Auth0, Linux/Unix, Kubernetes RBAC, Backstage | **Group** |

**12/12 IAM systems use "Group".** Confirmed by current RBAC literature: bindings map identities or groups to roles.

**Collaboration tools (a different layer):**

| Tool | Term |
|---|---|
| GitHub, Vercel, Linear, Asana, Atlassian, Notion, HashiCorp Cloud, Slack, Microsoft Teams, Coolify | **Team** |

**Universality test (covers all 7 TAPPAAS use cases):**

| Use case | Group fits? | Team fits? |
|---|---|---|
| Family members | ✅ | ❌ (awkward) |
| Company staff | ✅ | ✅ |
| OSS contributors | ✅ | 🟡 |
| Auditors (read-only) | ✅ | ❌ (not a team) |
| On-call rotation | ✅ | ✅ |
| Mailing list | ✅ | ❌ |
| Ad-hoc reviewers | ✅ | ❌ |

**Conclusion:** Group is the primitive (7/7 coverage); Team is a display *type* (Backstage-style).

## A.4 — Top-level hierarchies of comparable platforms

| Platform | Hierarchy (top → bottom) |
|---|---|
| **Backstage** | Domain → System → Component (+ API, Resource) + Users/Groups |
| **Coolify** | Server → Project → Environment → Resource (+ Teams) |
| **Vercel** | Team → Project → Environment → Deployment |
| **K8s** | Cluster → Namespace → Workload (RBAC cross-cuts) |
| **UniFi** | Account → Site → Devices/Clients/Networks/Profiles |
| **Apple Business Manager** | Org → Location → Devices + Apps + Users + Profiles |
| **AWS** | Organization → Account → VPC/Region → Resource |
| **Azure** | Tenant → Subscription → Resource Group → Resource |
| **GCP** | Organization → Folder → Project → Resource |
| **Terraform / HCP** | Org → Workspace → Resource (+ Teams) |
| **TAPPAAS (this ADR)** | Site → People/Apps/Environments (3-bucket flat under Site) + Health lens |

**TAPPAAS is intentionally flatter** to match prosumer UX. Multi-Org sits inside People (not as a hierarchical layer), avoiding the AWS/Azure complexity that overwhelms small users.

## A.5 — "Environment" universal adoption

| Platform | Uses "Environment"? |
|---|---|
| Kubernetes (Namespace) | ✅ Effectively |
| Coolify | ✅ Direct |
| Vercel | ✅ Direct |
| Backstage (via System) | ✅ Implicit |
| GCP, AWS, Azure | ✅ Direct |
| Heroku | ✅ Direct |
| Apple Business Manager (Location/Profile) | ✅ Indirect |
| UniFi (Site) | ✅ Indirect |
| Synology DSM, YunoHost, Umbrel, CasaOS | ❌ (single-env by design) |

**Conclusion:** "Environment" is the *de facto* term in any multi-env-capable platform.

## A.6 — Industry pattern recognition for multi-Org-on-one-host setups

The "one founder, multiple ventures, on one infrastructure" pattern maps to recognized industry patterns:

| Industry Pattern | Examples |
|---|---|
| **Multi-account / Organizations** (cloud) | AWS Organizations, GCP folders, Azure subscriptions |
| **MSP multi-tenant** | UniFi Site Manager, ConnectWise, NinjaOne, Microsoft CSP |
| **Holding company IT** | Family office serving multiple LLCs |
| **Indie-hacker / Solopreneur domains** | 37signals (Basecamp, Hey), Pieter Levels (Nomadlist, RemoteOK), Levels.fyi |
| **Authentik / Keycloak Realms** | Native multi-realm identity isolation |

**Conclusion:** Common pattern at enterprise scale, **gap in prosumer FOSS** — a real positioning opportunity for TAPPAAS.

## A.7 — Source vs Tier (curated vs community) patterns

Why we model `source` as a separate dimension from `tier`:

| Platform | Lifecycle (tier-equivalent) | Source/Origin (catalog) |
|---|---|---|
| **Debian** | Same (`apt install`) | `main` · `universe` · `multiverse` (4 components) |
| **Ubuntu** | Same | `main` · `restricted` · `universe` · `multiverse` |
| **Home Assistant** | Same (integration) | Core integrations vs **HACS** (community) |
| **Nextcloud** | Same (app) | Official · Featured · 3rd party |
| **Synology DSM** | Same (Package Center) | Synology · Community |
| **Umbrel** | Same | Official Store · Community Store |
| **YunoHost** | Same | Official · Working · Inprogress · Notworking |
| **WordPress** | Different — core can't be uninstalled | Core (tier=foundation) + Plugins (source=official/3rd) |
| **iOS** | Different — System Apps can't be uninstalled | System (tier=foundation) + App Store (source=apple) |

**Conclusion:** 7/9 platforms model curated-vs-community as **source** (separate from lifecycle). 2 platforms use `tier` only when *lifecycle genuinely differs* — exactly what TAPPAAS does with `foundation` vs `app`. The two dimensions are orthogonal and both are needed.

---

# Appendix B — Sample Files for the Example SOHO

Ready-to-commit JSON files for the example setup. Use as starting point for migration Phase 1. Replace placeholder values (`<owner>`, `mybusiness-bv`, `myhomedomain.nl`, etc.) with your own.

## site.json

```json
{
  "name": "mysite-soho",
  "displayName": "My SOHO",
  "owner": "<owner>",
  "location": { "country": "NL", "timezone": "Europe/Amsterdam", "locale": "nl_NL" },
  "network": { "rootDomain": "myhomedomain.nl" },
  "dns": { "provider": "<your-dns-provider>", "credentialsRef": "secrets/dns-provider" },
  "hardware": { "nodes": ["tappaas1", "tappaas2"], "storagePools": ["tanka1", "tankb2"], "cluster": "tappaas" },
  "identityProvider": { "type": "authentik", "url": "https://id.myhomedomain.nl" },
  "backup": { "target": "backup.myhomedomain.nl", "offsite": "tappaas-backup-buddy" },
  "updateChannel": "stable"
}
```

## people/organizations/

```json
// myhome.json
{
  "name": "myhome",
  "type": "family",
  "displayName": "My Home",
  "owner": "<owner>",
  "primaryDomain": "myhomedomain.nl",
  "authentikTenant": "id.myhomedomain.nl",
  "jurisdiction": "NL"
}

// mybusiness-bv.json
{
  "name": "mybusiness-bv",
  "type": "company",
  "displayName": "MyBusiness BV",
  "owner": "<owner>",
  "legalEntity": "MyBusiness BV",
  "jurisdiction": "NL",
  "kvk": "12345678",
  "primaryDomain": "mybusiness.nl",
  "aliasDomains": ["mybusiness.com"],
  "aliasMode": "redirect",
  "authentikTenant": "id.mybusiness.nl",
  "dataResidency": "eu-only"
}

// tappaas-org.json
{
  "name": "tappaas-org",
  "type": "foundation",
  "displayName": "TAPPAAS",
  "owner": "<owner>",
  "legalEntity": "TBD — see Parking Lot #1",
  "jurisdiction": "EU",
  "primaryDomain": "tappaas.org",
  "aliasDomains": [],
  "authentikTenant": "id.tappaas.org",
  "dataResidency": "eu-only"
}

// client-acme.json (template)
{
  "name": "client-acme",
  "type": "customer",
  "parentOrg": "mybusiness-bv",
  "displayName": "ACME B.V.",
  "legalEntity": "ACME B.V.",
  "jurisdiction": "NL",
  "primaryDomain": "acme.mybusiness.nl",
  "authentikTenant": "id.acme.mybusiness.nl",
  "billing": { "invoicedBy": "mybusiness-bv", "contractRef": "DPA-YYYY-NNN" },
  "dataResidency": "eu-only",
  "dpaSigned": "YYYY-MM-DD"
}
```

## people/groups/

```json
// myhome__family.json
{
  "name": "myhome__family",
  "type": "family-members",
  "displayName": "Family",
  "ownerOrg": "myhome",
  "members": ["<owner>", "person2", "person3", "person4"],
  "authentikGroup": "myhome-family"
}

// mybusiness-bv__staff.json
{
  "name": "mybusiness-bv__staff",
  "type": "team",
  "displayName": "MyBusiness Staff",
  "ownerOrg": "mybusiness-bv",
  "members": ["<owner>"],
  "authentikGroup": "mybusiness-bv-staff",
  "roles": ["admin"]
}
```

## people/users/

```json
// <owner>.json
{
  "name": "<owner>",
  "displayName": "<Site Administrator>",
  "primaryEmail": "<owner>@myhomedomain.nl",
  "memberOf": [
    "myhome__family",
    "mybusiness-bv__staff",
    "tappaas-org__maintainers"
  ],
  "authentikUser": "<owner>"
}
```

## environments/

```json
// myhome.json
{
  "name": "myhome",
  "displayName": "My Home",
  "ownerOrg": "myhome",
  "domains": { "primary": "myhomedomain.nl", "aliases": [], "aliasMode": "redirect" },
  "network": { "zone": "srv-home", "vlan": 210, "firewallPosture": "balanced" },
  "authentikTenant": "id.myhomedomain.nl",
  "updateWindow": "weekend",
  "backup": { "retention": "long-term-personal", "residency": "eu-only" }
}

// mybusiness.json
{
  "name": "mybusiness",
  "displayName": "MyBusiness Production",
  "ownerOrg": "mybusiness-bv",
  "domains": { "primary": "mybusiness.nl", "aliases": ["mybusiness.com"], "aliasMode": "redirect" },
  "customerSubdomainPattern": "{cust}.mybusiness.nl",
  "network": { "zone": "srv-mybusiness", "vlan": 220, "firewallPosture": "strict" },
  "authentikTenant": "id.mybusiness.nl",
  "updateWindow": "saturday-02:00-cet",
  "backup": { "retention": "7y", "residency": "eu-only" },
  "legal": { "processor": "MyBusiness BV" }
}

// tappaas.json
{
  "name": "tappaas",
  "displayName": "TAPPAAS Community",
  "ownerOrg": "tappaas-org",
  "domains": { "primary": "tappaas.org", "aliases": [], "aliasMode": "redirect" },
  "network": { "zone": "srv-tappaas", "vlan": 230, "firewallPosture": "balanced" },
  "authentikTenant": "id.tappaas.org",
  "updateChannel": "edge",
  "backup": { "retention": "1y", "residency": "eu-only" }
}
```

---

# Appendix C — Glossary

| Term | Definition |
|---|---|
| **Site** | The physical + admin perimeter. One TAPPAAS = one Site. |
| **Organization** | A legal or identity entity (family, company, foundation, customer). Owns Envs and Apps. |
| **Group** | A collection of Users for access control. Lives in one Org. |
| **User** | An individual human. Can be in many Groups across many Orgs. |
| **Environment** | Where Apps run. Has zone, domain, update window. Owned by an Org. |
| **App** | A workload (VM, container, service). Has a `tier` and a `source`. |
| **Tier** | App classification by lifecycle: `foundation` (platform, cannot uninstall) or `app` (user-installable). |
| **Source** | App classification by origin: `official` (TAPPAAS-maintained), `community` (peer-reviewed), `private` (your own catalog), `local` (dev work). |
| **Health** | Cross-cutting observability lens. Not a bucket — overlays the other artifacts. |
| **Tenant** | Architecture term for "isolated customer of a multi-tenant system". *Not* a UI term in TAPPAAS — that's Organization. |
| **DPA** | Data Processing Agreement (GDPR). Required when one Org hosts another Org's data. |
| **MSP** | Managed Service Provider — pattern where one infrastructure serves multiple client Orgs. |
| **Community catalog** | The TAPPAAS-community repo of `source: community` modules. Peer-reviewed, not officially supported. |
