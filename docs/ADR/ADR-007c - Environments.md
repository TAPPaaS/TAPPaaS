# ADR-007c — Environments

| | |
|---|---|
| **Status** | Accepted — **implemented** (P3/S4 on the `ADR007` branch) |
| **Version** | 1.4 |
| **Date** | 2026-06-30 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #318 (rename "variant"→Environment); #299 (domain_groups — subsumed); #319 (zone deletion); #294 (zone-aligned VMID, out of scope); #313 (timezone→site); **manager:** `environment-manager`; **zones owned by** `network-manager` |
| **Changelog** | v1.4 — **as-built (2026-06-30):** (1) `network.zones[]` reverted to **`network.zone`** (singular) — the realized schema binds an Environment to **one** zone; (2) added **`domains.dnsMode`** (`per-service`\|`wildcard`); (3) the TLS **cert refid is runtime state**, NOT an authored field — `domains.tlsCertRefid` is **rejected** by the schema and lives in `config/cert-refids.json` keyed by environment; (4) **`mgmt` is an Environment** (omits `domains`); (5) the **default Environment = the Site/org name** (`<N>`), and `configuration.json` is **retired** (no `tappaas.domain` fallback). v1.3 — (superseded) `network.zone` → `network.zones[]`. v1.2 — "bucket" → "classification domain". v1.1 — Erik⟷Lars review: ownerOrg→Organization ref (CR-08); vlan→zones.json (CR-09); drop identityOrganization/tenant (CR-11); updateWindow/Channel → issues (CR-12/13); backup cross-level (CR-14). Deferred: firewallPosture (CR-10), legal→own ADR (CR-15) |

The **🏠 Environments** classification domain. An Environment = **where apps run**: network zones, domain, update
window, security posture. Owned by **exactly one Organization** (`ownerOrg`).

- An Environment carries (as built): `ownerOrg`, `domains` (`primary`, `aliases`, **`dnsMode`**),
  `network.zone`, `backup` (retention/residency), and optionally `legal.processor`. (`vlan`/`firewallPosture`
  live in `zones.json`; `updateWindow`/`updateChannel` and `authentikTenant` were deferred — see field notes.)
- **An Environment binds to one zone** (`network.zone`, **singular** — the v1.3 `network.zones[]` set was
  reverted in implementation). A tenant whose services genuinely need several network segments models that
  in `zones.json` (a service zone may itself span/trunk VLANs); the Environment names the one zone its
  modules deploy into.
- **`mgmt` is itself an Environment** — the foundation/control-plane environment; it omits `domains` (no
  public domain). Foundation modules deploy here.
- **The default Environment is named after the Site/org (`<N>`)** and is the zone a module lands in when
  `--environment` is omitted (and it is not a foundation module → `mgmt`).
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

- **MECE:** a module names its Environment (`--environment`, persisted as `.environment`) and its zone
  (`zone0`); a **default Environment** (`<N>`) covers the unspecified case, so coverage is exhaustive.
- **DRY — one derivation chain (as built):**
  `module.environment → environments/<env>.json .domains.primary (+ .dnsMode) → proxyDomain` (Caddy).
  There is **no `tappaas.domain` fallback** — `configuration.json` is retired; the environment file is the
  source of truth for the public domain.

## Schema (`config/environments/{name}.json`)

As built (`schemas/environment-fields.json`) — `network.zone` is **singular**, `domains` carries a
**`dnsMode`**, and `tlsCertRefid` is **NOT** an authored field (it is reconciler-populated runtime state —
see TLS note):

```json
{
  "name": "mybusiness",
  "displayName": "MyBusiness Production",
  "ownerOrg": "mybusiness-bv",
  "domains": { "primary": "mybusiness.nl", "aliases": ["mybusiness.com"], "dnsMode": "wildcard" },
  "network": { "zone": "mybusiness" },
  "backup": { "retention": "7y", "residency": "eu-only" },
  "legal": { "processor": "MyBusiness BV" }
}
```

The **`mgmt`** Environment (foundation/control plane) omits `domains` entirely:

```json
{ "name": "mgmt", "ownerOrg": "", "network": { "zone": "mgmt" } }
```

> **TLS / cert refid (as built).** `domains.dnsMode` decides the certificate strategy: `per-service`
> (default — Caddy issues per-host HTTP-01 certs, nothing to store) or `wildcard` (OPNsense ACME issues one
> `*.<primary>` cert). When a wildcard cert exists, its OPNsense Trust refid is **runtime state** written to
> `config/cert-refids.json` keyed by environment — it is **not** authored on the Environment, and the schema
> **rejects** a `tlsCertRefid` field. This replaces the v1.3 "`cert_refid` moves onto `domains`" plan.

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

| # | Environment | `ownerOrg` | `domains.primary` (+aliases) | `network.zone` | Pattern |
|---|---|---|---|---|---|
| 1 | `myhome` | family | `home.example` | `myhome` (its service zone) | private domain for the household's service zone |
| 2 | `business-a` | business-a-bv | `business-a.example` (+`business-a.example.net`) | `srvWork` | **twin domains** — one brand, two TLDs |
| 3 | `business-b` | business-b-bv | `business-b.example` | `srv` (its own service zone) | a **second business** on the same hardware |
| 4 | `business-a` (MSP) | business-a-bv | `{cust}.business-a.example` | `srvCust1` | customer hosted **as a subdomain** of the provider |
| 5 | `customer-c` | customer-c | `customer-c.example` | `srvCust` | customer brings **their own domain** |

Notes (as built):
- **#1** — `network.zone` is **singular**, so an Environment names the **one service zone** its modules
  deploy into. The household's client/IoT segments (`home`, `iotCloud`, `iotLocal`) are plain **network
  zones** in `zones.json` (devices live there, with `access-to` the service zone) — they are not part of
  the Environment. (The v1.3 "one Environment across four zones" idea was dropped with the singular-zone
  schema; the original #299 multi-zone-domain need is met by the service zone + the per-zone access graph.)
- **#2** uses `domains.aliases` for the twin domain (one `dnsMode: wildcard` cert covers both).
- **#4** the `{cust}` subdomain pattern lets a module for `customer1` resolve at
  `<module>.customer1.business-a.example` — **no** separate Environment per customer.
- **#5** is a distinct Environment because the customer owns the domain **and** their own service zone.
- All live as `config/environments/<name>.json`; **`site.json` stays lean** (no per-domain registry, and
  the Site holds no environment *list* — environments are simply the files in `config/environments/`).

## Migration (terminology)

The old term **Variant** becomes **Environment** (#318). `copy-update-json.sh --variant` aliases to
`--environment` for one release; `--variant` deprecated next major. Zone-deletion semantics for
managed-vs-client zones are tracked on #319; zone-aligned VMID ranges on #294.

**domain_groups (#299) folds in here too.** Rather than a parallel `tappaas.domain_groups` registry
plus a per-zone `domain_group` field, the same need is met by `network.zone` + `domains` on the
Environment. #299 is implemented **as** the Environment derivation chain above — not as a separate
concept. The TLS **cert refid does NOT live on the Environment** — it is runtime state in
`config/cert-refids.json` keyed by environment (see the TLS note above); `domains.dnsMode` selects
per-service vs one wildcard per Environment.

> **Install-time zone setup (as built).** `network-manager zones-init --name <N>` transforms the repo
> zones template into the live `config/zones.json` for this installation (e.g. the distributed `srv` zone
> → the default zone `<N>`; unused legacy `srv*` zones set Inactive), and `create-minimal-environments`
> creates the `mgmt` + default `<N>` environment files. `network-manager` owns `zones.json` end-to-end.

## Implementation & related issues

The Environment model is realized across these issues — **start from #318** (the spine):

| Issue | Role for this ADR | State |
|---|---|---|
| [#318](https://github.com/TAPPaaS/TAPPaaS/issues/318) | Rename **variant → Environment**; realize `environment-manager` (ADR-007f) — the spine | **open** |
| [#299](https://github.com/TAPPaaS/TAPPaaS/issues/299) | `domain_groups` per-zone domain routing — **subsumed** into `Environment.domains` + `network.zone` | closed |
| [#316](https://github.com/TAPPaaS/TAPPaaS/issues/316) | ADR-005 variant model — the origin of `--variant`, superseded by the rename | closed |
| [#294](https://github.com/TAPPaaS/TAPPaaS/issues/294) | Zone-aligned VMID ranges (multi-tenant Environments) | open |
| [#319](https://github.com/TAPPaaS/TAPPaaS/issues/319) | Zone deletion semantics (managed vs client/Environment zones) | open |
| [#313](https://github.com/TAPPaaS/TAPPaaS/issues/313) | `timezone` → config (an Environment/Site field) | open |
| [#320](https://github.com/TAPPaaS/TAPPaaS/issues/320) | Decision to adopt the ADR-007 taxonomy (this family) | closed |

**Order:** #318 is the spine (rename + `environment-manager`); it absorbs #299 (domains) and the
ADR-005/#316 variant model. #294 / #319 / #313 are adjacent zone/field concerns that read the same
`config/environments/` registry. #299 and #316 are closed because their scope folds into #318.

## Acceptance

- [x] `ownerOrg` references a People Organization; `environment-manager` validates it (mgmt may be `""`).
- [x] `--environment` is the front door (`--variant` kept as a deprecated alias); the chosen env is persisted on the deployed module.
- [x] `Environment.network.zone` (singular) references a zone in `zones.json`; `network:proxy` derives `proxyDomain` from `domains.primary` + `dnsMode`.
- [x] `domain_groups` (#299) implemented **as** `Environment.domains` — no separate registry; cert refid is runtime (`cert-refids.json`).
