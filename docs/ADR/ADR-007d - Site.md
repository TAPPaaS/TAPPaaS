# ADR-007d — Site

| | |
|---|---|
| **Status** | Accepted — **implemented** (P2/S3 on the `ADR007` branch) |
| **Version** | 1.3 |
| **Date** | 2026-06-30 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #313 (timezone→site.json); ADR-004 (config cascade); ADR-007b (Apps — `sourceMetadata` → Site `repositories`); **manager:** `site-manager`; **schema:** `schemas/site-fields.json` |
| **Changelog** | v1.3 — **as-built (2026-06-30):** replaced the schema with the realized `site.json` (`name/displayName/owner/email/version/location/network/hardware.nodes[]/backup/updateSchedule/automaticReboot/snapshotRetention/repositories/organizations`); **public domain + DNS moved to the Environment** (not site-wide); `hardware.nodes[]` is a list of **objects** (`{name, storagePools}`); `repositories[]` carry a **`branch`** (not `updateChannel`); **`configuration.json` is RETIRED** (deleted at cutover, not a 2-release deprecation); the Site holds **no `environments` list** — environments are the files in `config/environments/`. v1.2 — "bucket" → "classification domain". v1.1 — Erik⟷Lars review: drop `identityProvider.type` (CR-16); add `repositories`, `updateChannel` per-repo (CR-17) |

The **🏢 Site** — the **container**, not a classification domain. One TAPPaaS = one Site: the physical + admin
perimeter holding everything shared across all Environments inside it.

## Decision

- A Site owns: identity (`name`/`owner`/`email`/`version`), hardware (`nodes[]` with their
  `storagePools`), WAN/ISP (`network.isp`/`publicIp`), backup target, **module `repositories`** (each
  carrying its own **`branch`** — per-repo, not per-site), update policy (`updateSchedule`,
  `automaticReboot`, `snapshotRetention`), location (country/timezone/locale), and **references to its
  `organizations`**. The **public domain + DNS are NOT site-wide** — they are per-Environment (007c).
  (`name` is the one name threaded everywhere: Proxmox cluster = `site.json .name` = default Environment =
  Organisation.)
- **`nodes` are the physical Proxmox hosts** (`tappaas1`, `tappaas2`) — the same `node` the module
  schema refers to (the physical host an App's VM is installed on). The composition naming of
  physical-host-vs-VM is reconciled in **[ADR-009](<ADR-009 - Composition Meta-Model.md>)**; the schema
  usage here — `node` = physical host — is authoritative.
- **Add a second Site** only for: different ISP, different physical hardware, different legal admin
  team, or a DR location.

## Schema (`config/site.json`)

As built (`schemas/site-fields.json`) — `name` is the install-wide identity, `hardware.nodes[]` is a list
of objects, and there is **no** site-wide domain/DNS/identityProvider (those are per-Environment) and **no**
`environments` list:

```json
{
  "name": "mysite-soho",
  "displayName": "My SOHO",
  "owner": "mysite-soho",
  "email": "admin@myhomedomain.nl",
  "version": "2.0",
  "location": { "country": "NL", "timezone": "Europe/Amsterdam", "locale": "nl_NL" },
  "network": { "isp": "<your-isp>", "publicIp": "auto" },
  "hardware": { "nodes": [ { "name": "tappaas1", "storagePools": ["tanka1"] } ] },
  "backup": null,
  "updateSchedule": ["monthly", "Thursday", 2],
  "automaticReboot": true,
  "snapshotRetention": 5,
  "repositories": [
    { "name": "TAPPaaS", "url": "https://github.com/TAPPaaS/TAPPaaS.git", "branch": "stable", "path": "/home/tappaas/TAPPaaS" }
  ],
  "organizations": []
}
```

> **Field notes (as built).** The public **domain + DNS provider are per-Environment** (007c), not on the
> Site (the single identity provider, Authentik, is reached at its module address — no `identityProvider`
> block). **`repositories[]`** lists the module catalogs (where an App's `sourceMetadata` lives — ADR-007b
> CR-05) and each carries its own **`branch`** (per-repo, not per-site — CR-17). The Site keeps **no list
> of environments**: environments are simply whatever files exist under `config/environments/`
> (enumerated from the directory). `email` is the admin/ACME contact (carried from the install).

## Config split (migration) — as built

The legacy mixed `configuration.json` split into **`site.json`** (site-wide) + **`environments/*.json`**
(per-environment), aligned with ADR-004. **`configuration.json` is now RETIRED** — it is migrated then
**deleted** at cutover (`migrate-configuration.sh`), and a fresh install never creates it (the install is
`site.json`-native via `create-site.sh`):

| `configuration.json` field | Goes to |
|---|---|
| `name`, `version`, `displayName` | `site.json` (top level) |
| `domain` / `rootDomain` | **`environments/<env>.json → domains.primary`** (per-environment, NOT site) |
| `dns provider` / cert refid | runtime (`config/cert-refids.json`) + per-env `domains.dnsMode` (NOT site) |
| `nodes` | `site.json → hardware.nodes[]` (objects with `storagePools`) |
| `email` | `site.json → email` |
| `backup target` | per-env `backup` + the site→env→module retention cascade |
| `timezone`, `locale` | `site.json → location` |
| `updateSchedule`, `automaticReboot`, `snapshotRetention` | `site.json` (top level) |
| `repositories` | `site.json → repositories[]` (each with its `branch`) |
| `variants`, `active zones` | `environments/<env>.json` + `config/zones.json` (the env names its `network.zone`) |

There is **no fallback to `configuration.json`** on a fresh install (no dual-read). On an upgrade, the
migration runs once (config→site), the env/zone bootstrap runs (`zones-init` + `create-minimal-environments`),
then `configuration.json` is dropped — see the [migration runbook](<../design/ADR-007-migration-runbook.md>).

## Acceptance

- [x] `site.json` validated by `site-manager validate` (`schemas/site-fields.json`).
- [x] Site-level fields migrated out of `configuration.json`, which is then **deleted** (no lingering fallback).
