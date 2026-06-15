# ADR-007c — Environments

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.0 |
| **Date** | 2026-06-15 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; #318 (rename "variant"→Environment); #319 (zone deletion); #294 (zone-aligned VMID); #313 (timezone→config) |

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
  "network": { "zone": "srv-mybusiness", "vlan": 220, "firewallPosture": "strict" },
  "authentikTenant": "id.mybusiness.nl",
  "updateWindow": "saturday-02:00-cet",
  "updateChannel": "stable",
  "backup": { "retention": "7y", "residency": "eu-only" },
  "legal": { "processor": "MyBusiness BV" }
}
```

`Zone` is the **network-implementation** of an Environment (kept as a term inside the Environment),
not a separate bucket.

## Migration (terminology)

The old term **Variant** becomes **Environment** (#318). `copy-update-json.sh --variant` aliases to
`--environment` for one release; `--variant` deprecated next major. Zone-deletion semantics for
managed-vs-client zones are tracked on #319; zone-aligned VMID ranges on #294.

## Acceptance

- [ ] `ownerOrg` present on every Environment; defaults to the family Org for legacy.
- [ ] `install-module.sh` validates `ownerOrg`; `--environment` accepted alongside `--variant`.
