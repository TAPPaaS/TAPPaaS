# ADR-007d — Site

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.2 |
| **Date** | 2026-06-17 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; #313 (timezone→site.json); ADR-004 (config cascade); ADR-007b (Apps — `sourceMetadata` → Site `repositories`) |
| **Changelog** | v1.2 — "bucket" → "classification domain" (Site = container, not a classification domain) (2026-06-17). v1.1 — applied Erik⟷Lars review: drop `identityProvider.type` (single provider, CR-16); add `repositories`, `updateChannel` is **per-repo not per-site** (CR-17) |

The **🏢 Site** — the **container**, not a classification domain. One TAPPaaS = one Site: the physical + admin
perimeter holding everything shared across all Environments inside it.

## Decision

- A Site owns: hardware (`nodes`, `storagePools`, `cluster`), WAN/ISP, `rootDomain`, DNS provider,
  identity provider (Authentik), backup target, **module `repositories`** (each carrying its own
  update channel — update channel is **per-repo, not per-site**), location (country/timezone/locale).
- **`nodes` are the physical Proxmox hosts** (`tappaas1`, `tappaas2`) — the same `node` the module
  schema refers to (the physical host an App's VM is installed on). The composition naming of
  physical-host-vs-VM is reconciled in **[ADR-009](<ADR-009 - Composition Meta-Model.md>)**; the schema
  usage here — `node` = physical host — is authoritative.
- **Add a second Site** only for: different ISP, different physical hardware, different legal admin
  team, or a DR location.

## Schema (`config/site.json`)

```json
{
  "name": "mysite-soho",
  "displayName": "My SOHO",
  "owner": "<owner>",
  "location": { "country": "NL", "timezone": "Europe/Amsterdam", "locale": "nl_NL" },
  "network": { "isp": "<your-isp>", "publicIp": "auto", "rootDomain": "myhomedomain.nl" },
  "dns": { "provider": "<your-dns-provider>", "credentialsRef": "secrets/dns-provider" },
  "hardware": { "nodes": ["tappaas1", "tappaas2"], "storagePools": ["tanka1", "tankb2"], "cluster": "tappaas" },
  "identityProvider": { "url": "https://id.myhomedomain.nl" },
  "backup": { "target": "backup.myhomedomain.nl", "offsite": "tappaas-backup-buddy" },
  "repositories": [
    { "name": "tappaas-official", "url": "https://github.com/tappaas-org", "updateChannel": "stable" }
  ]
}
```

> **Field notes (review).** `identityProvider` carries only `url` — a single provider (authentik), so
> the `type` option is omitted (CR-16). **`repositories`** lists the module catalogs — this is where an
> App's `sourceMetadata` lives (ADR-007b, CR-05). **`updateChannel` is per-repository, not per-site**
> (CR-17): it sits inside each `repositories[]` entry.

## Config split (migration)

The legacy mixed `configuration.json` splits into **`site.json`** (site-wide) + **`environments/*.json`**
(per-environment), aligned with ADR-004:

| `configuration.json` field | Goes to |
|---|---|
| `domain`, `rootDomain` | `site.json → network.rootDomain` |
| `nodes` | `site.json → hardware.nodes` |
| `dns provider`, `backup target` | `site.json → dns` / `backup` |.  (should be by environment - not by site!) 
| `timezone`, `locale` | `site.json → location` |
| `updateSchedule` | `environments/{name}.json → updateWindow` |
| `subdomain prefix` | `environments/{name}.json → domains` |
| `active zones` | `environments/{name}.json → network.zone` |

Scripts read `site.json` first, fall back to the old file; deprecate `configuration.json` over 2 minor
releases.

## Acceptance

- [ ] `site.json` schema validated by `validate-configuration.sh`.
- [ ] Site-level fields migrated out of `configuration.json`; fallback path works.
