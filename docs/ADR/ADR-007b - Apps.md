# ADR-007b — Apps

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.2 |
| **Date** | 2026-06-16 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; #297 (module-catalog stack/category); **schema:** `module-fields.json`; **composition:** [ADR-009](<ADR-009 - Composition Meta-Model.md>) + #171 |
| **Changelog** | v1.2 — named `module-fields.json` as the App schema; catalog schema → Site-level; acceptance corrected. v1.1 — applied Erik⟷Lars review (CR-04 module=filename; CR-05 sourceMetadata→Site; CR-06/07 drop ownerGroup/environment; CR-03 local→issue) |

The **📦 Apps** bucket. An App = a thing that runs (VM, container, service) with a lifecycle: install,
update, test, backup, delete. Owned by a Group, lives in one Environment.

> **App ≡ Module.** In the composition model ([ADR-009](<ADR-009 - Composition Meta-Model.md>)), every
> App is a **Module** — the atomic deployable unit (one VM, one `{name}.json`). "App" is the
> user-facing label (the value stream calls them Apps because everyone knows what an app is); "Module"
> is the technical/composition term. Same deployment unit, two vocabularies.

## Decision

Apps carry **two orthogonal attributes** — never collapsed into one enum (that would break MECE):

| Attribute | Values | Answers |
|-----------|--------|---------|
| **`tier`** | `foundation` · `app` | *Can it be uninstalled?* (lifecycle role) |
| **`source`** | `official` · `community` · `private` · `local` | *Where does the catalog entry come from?* (origin & trust) |

> **Open (CR-03 → issue):** the intent of `source: local` — "operational data in markdown" — is under
> discussion; tracked as a separate issue.

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
  "displayName": "OpenWebUI",
  "tier": "app",
  "source": "official",
  "version": "0.4.1",
  "vmname": "openwebui", "vmid": 311, "node": "tappaas2",
  "dependsOn": ["cluster:vm", "litellm:models", "identity:sso"],
  "provides": []
}
```

New classification fields: `tier`, `source`. Lint rule: `tier: foundation` ⇒ `source: official` (or explicit override).

**Schema.** Each `module.json` is validated by **`module-fields.json`** (the App schema, `src/foundation/`);
the `tier`/`source` fields are defined there. The module *catalog* (the registry of all modules) has a
separate schema, `module-catalog-fields.json` — a Site-level concern (see ADR-007f).

Rules from review: a module's name **is** its `{name}.json` filename — no separate `module` field
(CR-04). `sourceMetadata` lives in **Site → `repositories`** (ADR-007d), not on the module (CR-05).
`ownerGroup` and `environment` are **inferred at deploy time**, not stored on the module (CR-06, CR-07).

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

- [ ] `tier`, `source` added to `module-fields.json` (`sourceMetadata` → Site `repositories` per ADR-007d; `ownerGroup`/`environment` dropped — deploy-inferred).
- [ ] One module re-tagged + passes `install-module.sh`; one `source: community` module installed e2e.
