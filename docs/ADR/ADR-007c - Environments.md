# ADR-007c — Environments

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.2 |
| **Date** | 2026-06-17 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; #318 (rename "variant"→Environment); #299 (domain_groups — subsumed, see Migration); #319 (zone deletion); #294 (zone-aligned VMID); #313 (timezone→config) |
| **Changelog** | v1.3 — `network.zone` → `network.zones[]`: an Environment spans **one or more** zones (a single-zone Environment was the limiting case). Domain routing (#299 domain_groups) **subsumed** into the Environment — one MECE/DRY concept for "where apps run + under what domain"; added the single derivation chain (2026-06-17). v1.2 — "bucket" → "classification domain" throughout (2026-06-17). v1.1 — applied Erik⟷Lars review: ownerOrg→People:Organization ref (CR-08); vlan→zones.json (CR-09); drop identityOrganization/tenant (CR-11); updateWindow/Channel out of v1 → issues (CR-12/13); backup cross-level issue (CR-14). Deferred: firewallPosture (CR-10), legal→own ADR (CR-15) |

The **🏠 Environments** classification domain. An Environment = **where apps run**: network zones, domain, update
window, security posture. Owned by **exactly one Organization** (`ownerOrg`).

- An Environment carries: `domains`, `network.zones` (+ per-zone `vlan`, `firewallPosture`),
  `authentikTenant`, `updateWindow`/`updateChannel`, `backup` (retention/residency), `legal.processor`.
- **An Environment spans one or more zones.** `network.zones` is a **set** — a purpose that lives across
  several zones (e.g. a household with client + service + IoT zones, or a tenant with web + db zones)
  is **one** Environment, not one-per-zone.
- **Multi-tenant:** many Environments may share hardware; each is owned by one Org. A customer
  subdomain pattern (`{cust}.<domain>`) supports MSP-style hosting.
- **Add a second Environment per Org** when update timing, domain, security posture, or
  dev/staging/prod separation differ.

### Single concept for placement + domain (MECE / DRY)

The Environment is the **one** place that binds "where apps run" to "under what public domain".
It **subsumes** two earlier mechanisms so there is no overlapping config:

- **Variant (#318)** → an Environment selected per-module (`--environment`); see Migration.
- **domain_groups (#299)** → an Environment's `domains` **is** the per-zone-group domain mapping:
  the group of zones is `network.zones`, the domain is `domains.primary` (+ `aliases`, `cert`).
  No separate `domain_groups` registry is introduced.

- **MECE:** every zone belongs to **exactly one** Environment (a zone names its `environment` in
  `zones.json`); a **default Environment** covers legacy/unassigned zones, so coverage is exhaustive.
- **DRY — one derivation chain:**
  `module.zone0 → zones[zone0].environment → environments[env].domains.primary → proxyDomain`.
  `tappaas.domain` remains the fallback for zones with no Environment (backwards compatible).

## Schema (`config/environments/{name}.json`)

```json
{
  "name": "mybusiness",
  "displayName": "MyBusiness Production",
  "ownerOrg": "mybusiness-bv",
  "domains": { "primary": "mybusiness.nl", "aliases": ["mybusiness.com"], "aliasMode": "redirect" },
  "customerSubdomainPattern": "{cust}.mybusiness.nl",
  "network": { "zones": ["srv-mybusiness"], "firewallPosture": "strict" },
  "backup": { "retention": "7y", "residency": "eu-only" },
  "legal": { "processor": "MyBusiness BV" }
}
```

A purpose that spans several zones is still **one** Environment — `network.zones` lists them all,
and every module in any of those zones resolves to the same `domains.primary`:

```json
{
  "name": "myhome",
  "displayName": "Household",
  "ownerOrg": "family",
  "domains": { "primary": "home.example" },
  "network": { "zones": ["home", "srvHome", "iotCloud", "iotLocal"] }
}
```

> **Field notes (review).** `ownerOrg` **references** a People → Organization (by name), not a free
> string (CR-08). `vlan` lives in `zones.json`, not here (CR-09). `firewallPosture` values are **to be
> defined before adoption** (CR-10, deferred). `updateWindow`/`updateChannel` are **out of v1** — tracked
> as issues (CR-12, CR-13). `backup` is a **cross-level** concern (site → env → apps) — tracked separately
> (CR-14). The old `identityOrganization`/tenant field is **dropped**: `ownerOrg` + `domains` define
> identity (CR-11). `legal`/processor is **cross-cutting** across all classification domains — under review for its
> **own ADR** (CR-15; KISS, SBB = authentik).

`Zone` is the **network-implementation** of an Environment (kept as a term inside the Environment),
not a separate classification domain.

## Worked reference — one operator, five Environments on shared hardware

Anonymised from a real SOHO (placeholder `.example` domains). One household + two businesses + two
customer-hosting patterns, all on the same cluster — each Environment owned by one Org, each a
**1-to-many zone → public-domain** mapping. This is the full range the model must cover:

| # | Environment | `ownerOrg` | `domains.primary` (+aliases) | `network.zones` | Pattern |
|---|---|---|---|---|---|
| 1 | `myhome` | family | `home.example` | `home, srvHome, iotCloud, iotLocal` | one private domain across **many** zones |
| 2 | `business-a` | business-a-bv | `business-a.example` (+`business-a.example.net`, redirect) | `srvWork` | **twin domains** — one brand, two TLDs |
| 3 | `business-b` | business-b-bv | `business-b.example` | `srv` (its own service zone) | a **second business** on the same hardware |
| 4 | `business-a` (MSP) | business-a-bv | `{cust}.business-a.example` | `srvCust1` | customer hosted **as a subdomain** of the provider |
| 5 | `customer-c` | customer-c | `customer-c.example` | `srvCust` | customer brings **their own domain** |

Notes:
- **#1** is exactly the multi-zone case `#299` targeted: four zones, one domain, **one** Environment.
- **#2** uses `domains.aliases` + `aliasMode: redirect` for the twin domain (one wildcard cert).
- **#4** sets `customerSubdomainPattern: "{cust}.business-a.example"` on the *business-a* Environment —
  a module for `customer1` resolves at `<module>.customer1.business-a.example`; **no** separate
  Environment per customer.
- **#5** is a distinct Environment because the customer owns the domain **and** their own service zone.
- All five live as `config/environments/{name}.json`; **`configuration.json` / Site stays lean** — no
  per-domain registry bloat. One concept, one file-per-Environment, one derivation (MECE / DRY).

## Migration (terminology)

The old term **Variant** becomes **Environment** (#318). `copy-update-json.sh --variant` aliases to
`--environment` for one release; `--variant` deprecated next major. Zone-deletion semantics for
managed-vs-client zones are tracked on #319; zone-aligned VMID ranges on #294.

**domain_groups (#299) folds in here too.** Rather than a parallel `tappaas.domain_groups` registry
plus a per-zone `domain_group` field, the same need is met by `network.zones` + `domains` on the
Environment, with a per-zone `environment` selector in `zones.json`. #299 is implemented **as** the
Environment derivation chain above — not as a separate concept. `cert_refid` moves onto the
Environment's `domains` (one wildcard per Environment).

## Implementation & related issues

The Environment model is realized across these issues — **start from #318** (the spine):

| Issue | Role for this ADR | State |
|---|---|---|
| [#318](https://github.com/TAPPaaS/TAPPaaS/issues/318) | Rename **variant → Environment**; realize `environment-manager` (ADR-007f) — the spine | **open** |
| [#299](https://github.com/TAPPaaS/TAPPaaS/issues/299) | `domain_groups` per-zone domain routing — **subsumed** into `Environment.domains` + `network.zones[]` | closed |
| [#316](https://github.com/TAPPaaS/TAPPaaS/issues/316) | ADR-005 variant model — the origin of `--variant`, superseded by the rename | closed |
| [#294](https://github.com/TAPPaaS/TAPPaaS/issues/294) | Zone-aligned VMID ranges (multi-tenant Environments) | open |
| [#319](https://github.com/TAPPaaS/TAPPaaS/issues/319) | Zone deletion semantics (managed vs client/Environment zones) | open |
| [#313](https://github.com/TAPPaaS/TAPPaaS/issues/313) | `timezone` → config (an Environment/Site field) | open |
| [#320](https://github.com/TAPPaaS/TAPPaaS/issues/320) | Decision to adopt the ADR-007 taxonomy (this family) | closed |

**Order:** #318 is the spine (rename + `environment-manager`); it absorbs #299 (domains) and the
ADR-005/#316 variant model. #294 / #319 / #313 are adjacent zone/field concerns that read the same
`config/environments/` registry. #299 and #316 are closed because their scope folds into #318.

## Acceptance

- [ ] `ownerOrg` present on every Environment; defaults to the family Org for legacy.
- [ ] `install-module.sh` validates `ownerOrg`; `--environment` accepted alongside `--variant`.
- [ ] `Environment.network.zones[]` accepts a set; `firewall:proxy` derives `proxyDomain` via the chain above.
- [ ] `domain_groups` (#299) implemented **as** `Environment.domains` — no separate registry.
