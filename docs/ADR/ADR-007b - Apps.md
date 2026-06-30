# ADR-007b — Apps

| | |
|---|---|
| **Status** | Accepted — **implemented** (P5/S7 on the `ADR007` branch) |
| **Version** | 1.3 |
| **Date** | 2026-06-30 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; #297 (module-catalog stack/category); **schema:** `schemas/module-fields.json`; **manager:** `module-manager` (verbs add/modify/delete/list/show/validate); **composition:** [ADR-009](<ADR-009 - Composition Meta-Model.md>) + #171 |
| **Changelog** | v1.3 — **as-built (2026-06-30):** module configs are **flat** `config/<name>.json` (no `modules/` folder); the foundation `firewall` module was **renamed `network`**; `environment` IS persisted on the *deployed* config (and the deployed name/VM is suffixed `<name>-<env>` for a non-default, non-mgmt environment); `tier:foundation` is enforced as **mgmt-only + single-instance + --force-to-delete**; the manager is `module-manager`. v1.2 — named `module-fields.json` as the App schema; catalog schema → Site-level; acceptance corrected. v1.1 — applied Erik⟷Lars review (CR-04 module=filename; CR-05 sourceMetadata→Site; CR-06/07 drop ownerGroup/environment; CR-03 local→issue) |

The **📦 Apps** classification domain. An App = a thing that runs (VM, container, service) with a lifecycle: install,
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
| `foundation` | ships with platform, **mgmt-only + single-instance**, `--force` to delete | `cluster`, `network` (was `firewall`), `identity`, `backup`, `templates`, `logging`, `tappaas-cicd` |
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

## Schema (`config/<name>.json` — flat, one file per deployed module)

> **As built:** module configs are **flat** in the config dir (`config/openwebui.json`,
> `config/network.json`, …) — there is no `config/modules/` folder. The *source* of a module lives in
> its repo dir (`src/apps/<name>/<name>.json` or a community repo); install stages a validated copy into
> `config/`.

```json
{
  "displayName": "OpenWebUI",
  "tier": "app",
  "source": "official",
  "version": "0.4.1",
  "vmname": "openwebui", "vmid": 311, "node": "tappaas2",
  "zone0": "myhome", "environment": "myhome",
  "dependsOn": ["cluster:vm", "litellm:models", "identity:sso"],
  "provides": []
}
```

Classification fields: `tier`, `source`. Lint rule: `tier: foundation` ⇒ `source: official` (or explicit
override). A `tier: foundation` module may only be installed into the **`mgmt`** environment, is
**single-instance**, and needs `--force` to delete.

**Schema.** Each module JSON is validated by **`schemas/module-fields.json`** (the App schema); the
`tier`/`source`/`environment` fields are defined there. The module *catalog* (the registry of all modules)
has a separate schema, `schemas/module-catalog-fields.json` — a Site-level concern (see ADR-007f).

Rules from review: a module's name **is** its `<name>.json` filename — no separate `module` field
(CR-04). `sourceMetadata` lives in **Site → `repositories`** (ADR-007d), not on the source module (CR-05).
`ownerGroup` is deploy-inferred (CR-06). `environment` (CR-07): the *source* module carries none, but on
**install** the chosen environment **is persisted** onto the deployed `config/<name>.json` (`.environment`),
and for a **non-default, non-`mgmt`** environment both the config filename and the VM name are suffixed
`<name>-<env>` (e.g. `nextcloud-staging`); `mgmt` and the single default environment install under the
bare name.

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
