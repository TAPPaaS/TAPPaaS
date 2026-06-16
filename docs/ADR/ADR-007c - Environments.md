# ADR-007c — Environments

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.1 |
| **Date** | 2026-06-16 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; #318 (rename "variant"→Environment); #319 (zone deletion); #294 (zone-aligned VMID); #313 (timezone→config) |
| **Changelog** | v1.1 — applied Erik⟷Lars review: ownerOrg→People:Organization ref (CR-08); vlan→zones.json (CR-09); drop identityOrganization/tenant (CR-11); updateWindow/Channel out of v1 → issues (CR-12/13); backup cross-level issue (CR-14). Deferred: firewallPosture (CR-10), legal→own ADR (CR-15) |

The **🏠 Environments** bucket. An Environment = **where apps run**: network zones, domain, update
window, security posture. Owned by **exactly one Organization** (`ownerOrg`).

## Decision

- An Environment carries: `domains`, `network.zone` (+ `vlan`, `firewallPosture`), `authentikTenant`,
  `updateWindow`/`updateChannel`, `backup` (retention/residency), `legal.processor`.
- **Multi-tenant:** many Environments may share hardware; each is owned by one Org. A customer
  subdomain pattern (`{cust}.<domain>`) supports MSP-style hosting.
- **Add a second Environment per Org** when update timing, domain, security posture, or
  dev/staging/prod separation differ.

## Schema (`config/environments/{name}.json`)

```json
{
  "name": "mybusiness",
  "displayName": "MyBusiness Production",
  "ownerOrg": "mybusiness-bv",
  "domains": { "primary": "mybusiness.nl", "aliases": ["mybusiness.com"], "aliasMode": "redirect" },
  "customerSubdomainPattern": "{cust}.mybusiness.nl",
  "network": { "zone": "srv-mybusiness", "firewallPosture": "strict" },
  "backup": { "retention": "7y", "residency": "eu-only" },
  "legal": { "processor": "MyBusiness BV" }
} 
```

> **Field notes (review).** `ownerOrg` **references** a People → Organization (by name), not a free
> string (CR-08). `vlan` lives in `zones.json`, not here (CR-09). `firewallPosture` values are **to be
> defined before adoption** (CR-10, deferred). `updateWindow`/`updateChannel` are **out of v1** — tracked
> as issues (CR-12, CR-13). `backup` is a **cross-level** concern (site → env → apps) — tracked separately
> (CR-14). The old `identityOrganization`/tenant field is **dropped**: `ownerOrg` + `domains` define
> identity (CR-11). `legal`/processor is **cross-cutting** across all buckets — under review for its
> **own ADR** (CR-15; KISS, SBB = authentik).

`Zone` is the **network-implementation** of an Environment (kept as a term inside the Environment),
not a separate bucket.

## Migration (terminology)

The old term **Variant** becomes **Environment** (#318). `copy-update-json.sh --variant` aliases to
`--environment` for one release; `--variant` deprecated next major. Zone-deletion semantics for
managed-vs-client zones are tracked on #319; zone-aligned VMID ranges on #294.

## Acceptance

- [ ] `ownerOrg` present on every Environment; defaults to the family Org for legacy.
- [ ] `install-module.sh` validates `ownerOrg`; `--environment` accepted alongside `--variant`.
