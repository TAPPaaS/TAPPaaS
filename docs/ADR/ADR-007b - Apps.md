# ADR-007b — Apps

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.0 |
| **Date** | 2026-06-15 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; #297 (module-catalog stack/category); **composition:** [ADR-009](<ADR-009 - Composition Meta-Model.md>) + #171 |

The **📦 Apps** bucket. An App = a thing that runs (VM, container, service) with a lifecycle: install,
update, test, backup, delete. Owned by a Group, lives in one Environment.

## Decision

Apps carry **two orthogonal attributes** — never collapsed into one enum (that would break MECE):

| Attribute | Values | Answers |
|-----------|--------|---------|
| **`tier`** | `foundation` · `app` | *Can it be uninstalled?* (lifecycle role) |
| **`source`** | `official` · `community` · `private` · `local` | *Where does the catalog entry come from?* (origin & trust) |

Every App is exactly one cell of the `tier × source` grid — naturally MECE.

### `tier`

| Tier | Meaning | Example |
|------|---------|---------|
| `foundation` | ships with platform, cannot uninstall, removing it breaks the platform | `firewall`, `cluster`, `identity`, `caddy`, `backup`, `tappaas-cicd` |
| `app` | user-installable, freely removable | `openwebui`, `nextcloud`, `vaultwarden` |

### `source`

| Source | Meaning | Badge |
|--------|---------|-------|
| `official` | TAPPaaS-maintained, signed, supported | 🟢 Verified |
| `community` | community repo, peer-reviewed, not officially supported | 🟡 Community |
| `private` | private/customer repo | 🔵 Private |
| `local` | local dev, not in any catalog | ⚪ Local |

### Valid `tier × source` combinations

| | official | community | private | local |
|---|---|---|---|---|
| **foundation** | ✅ normal | 🟡 rare (fork) | ✅ custom platform | ✅ dev |
| **app** | ✅ normal | ✅ most community apps | ✅ customer-specific | ✅ dev |

## Schema (`config/modules/{name}.json` — folder kept as `modules/` for compatibility)

```json
{
  "module": "openwebui",
  "displayName": "OpenWebUI",
  "tier": "app",
  "source": "official",
  "sourceMetadata": { "repo": "https://github.com/tappaas-org/openwebui-module", "maintainer": "tappaas-org", "supportLevel": "supported", "verifiedBy": "tappaas-org" },
  "version": "0.4.1",
  "ownerGroup": "mybusiness-bv__staff",
  "environment": "mybusiness",
  "vmname": "openwebui", "vmid": 311, "node": "tappaas2",
  "dependsOn": ["cluster:vm", "litellm:models", "identity:sso"],
  "provides": []
}
```

New classification fields: `tier`, `source`, `sourceMetadata`, `ownerGroup`. Lint rule:
`tier: foundation` ⇒ `source: official` (or explicit override).

> **`node` = the physical Proxmox host** (e.g. `tappaas2`) the App's VM is installed on — see
> [007d Site](<ADR-007d - Site.md>) and [ADR-009](<ADR-009 - Composition Meta-Model.md>).

> **Boundary with ADR-009 / #297.** This ADR owns *classification* fields (`tier`, `source`). The
> *composition* (Module ▷ Component ▷ Function ▷ Service) is **ADR-009**. The *catalog/discovery*
> facets (`stack`/`category`, #297) are a separate axis — ADR-009 covers the relation + the "Stack"
> naming note.

## Why tier and source are separate

7/9 platforms (Debian, Ubuntu, HACS, Nextcloud, Synology, Umbrel, YunoHost) model curated-vs-community
as **source**, separate from lifecycle **tier**. Evidence: [taxonomy.md](<../Architecture/taxonomy.md>) → A.7.

## Acceptance

- [ ] `tier`, `source`, `sourceMetadata`, `ownerGroup` added to `module-fields.json`.
- [ ] One module re-tagged + passes `install-module.sh`; one `source: community` module installed e2e.
