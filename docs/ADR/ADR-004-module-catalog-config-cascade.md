# ADR-004: Module catalog → desired-state config cascade

**Status:** accepted — core implemented (2026-06-06); cluster `timezone` and Layer-3 config zone-folder migration deferred to follow-up issues (see Open issues)
**Date:** 2026-06-04
**Deciders:** @LarsRossen + @ErikDaniel007
**Related:** #297, #305, repository.sh

> **Implementation note (2026-06-06):** Implemented Layer-1 (`managed`/`catalog`
> in `configuration.json` + `configuration-fields.json`, and
> `repository.sh add --managed full|tracked [--catalog <path>]`), Layer-2 (catalog
> renamed `modules.json` → `module-catalog.json`; schema renamed
> `module-catalog-schema.json` → `module-catalog-fields.json` with required
> `stack`/`category`/`status` taxonomy), and registered the Community repo. The two
> items below marked *(open: new issue)* — cluster `timezone` propagation and the
> Layer-3 zone-folder migration — are intentionally **not** done here; they are
> larger/disruptive and tracked separately.

---

## Cascade (overview)

```
configuration.json                 ← Layer 1: cluster registry
  repositories[].catalog           ↓
src/module-catalog.json            ← Layer 2: what CAN exist  (#305: renamed from modules.json)
  moduleName = filename stem       ↓
/home/tappaas/config/              ← Layer 3: what SHOULD exist (desired state)
  <repo>/                          ←   NEW: folder per repo mirrors repo structure
    <module>.json
```

**Reference schemas:**
- Layer 1: `src/foundation/configuration-fields.json`
- Layer 2: `src/foundation/module-catalog-fields.json` · `src/foundation/module-fields.json`
- Layer 2 dependency graph: `src/module-dependencies.md`

---

## Context

Three questions arise as the platform scales beyond one repo:

1. **What repos contribute to this cluster?** `configuration.json` lists repos but has no `managed` type or catalog pointer — tooling cannot route validation without hardcoded paths.
2. **What modules exist?** `src/modules.json` is a VMID collision register only — no taxonomy, no schema, no cross-repo queryability.
3. **What is deployed?** `/home/tappaas/config/*.json` is a flat list — no structural link to the repo or module that produced each file.

---

## Decision

### Layer 1 — Cluster registry: `configuration.json`  *(NEW fields)*

Add `managed` and `catalog` to each repository entry:

```json
{
  "tappaas": {
    "repositories": [
      {
        "name": "TAPPaaS",
        "url": "github.com/TAPPaaS/TAPPaaS",
        "branch": "main",
        "path": "/home/tappaas/TAPPaaS",
        "managed": "full",
        "catalog": "src/module-catalog.json"
      },
      {
        "name": "Community",
        "url": "github.com/TAPPaaS/Community",
        "branch": "stable",
        "path": "/home/tappaas/Community",
        "managed": "full",
        "catalog": "src/module-catalog.json"
      },
      {
        "name": "my-org-apps",
        "url": "github.com/example/my-org-apps",
        "branch": "main",
        "path": "/home/tappaas/repos/my-org-apps",
        "managed": "tracked"
      }
    ]
  }
}
```

| Field | Values | Meaning |
|---|---|---|
| `managed` | `"full"` | Repo contains TAPPaaS modules — full catalog validation |
| `managed` | `"tracked"` | Repo registered but no catalog requirements |
| `catalog` | path string | Location of module catalog relative to repo root. Default: `src/module-catalog.json`. Override for non-standard layouts. Omit for `tracked` repos. |

**NEW — `timezone`** *(open: new issue)*

Add cluster-wide timezone to `configuration.json`:

```json
{ "tappaas": { "timezone": "Europe/Amsterdam" } }
```

`copy-update-json.sh` propagates it to instance configs as `timeZone`. `update-os.sh` injects it before `nixos-rebuild switch`. NixOS modules use `lib.mkDefault "UTC"` as fallback — no per-module `timeZone` field. See `src/foundation/configuration-fields.json` for field schema.

`repository.sh add --managed <full|tracked>` is the authoritative tool for registering repos.

---

### Layer 2 — Module catalog: `src/module-catalog.json`  *(NEW: rename + taxonomy)*

**Renamed** from `modules.json` (per #297 + #305). Every `managed: full` repo contains this file. Validated by `src/foundation/module-catalog-fields.json`.

Required fields per entry *(NEW: `stack`, `category`, `status`)*:

```json
{
  "moduleName": "forgejo",
  "vmid": 350,
  "moduleJson": "src/ErikDaniel007/development/forgejo/forgejo.json",
  "stack": "foundation | application | community",
  "category": "git | monitoring | auth | media | ...",
  "status": "stable | beta | incomplete | deprecated"
}
```

- `stack` + `category`: enable catalog-driven tooling and UI
- `status`: single source of truth for module readiness
- VMID uniqueness: enforced at commit time via `module-catalog-fields.json`
- Module field contract: see `src/foundation/module-fields.json`
- Dependency graph: see `src/module-dependencies.md`

---

### Layer 3 — Desired state: `/home/tappaas/config/`  *(NEW: zone-based structure)*

**Current:** flat list — `forgejo.json`, `hass.json`, etc. Zone membership is invisible at filesystem level.

**NEW** *(open: new issue)*: organize by zone — the primary security and isolation boundary in TAPPaaS. `zone0` is already present in every module config; the folder structure is implicit in the data.

```
/home/tappaas/config/
  configuration.json         ← cluster root (stays at top level)
  zones.json                 ← zone definitions (stays at top level)

  mgmt/                      ← management zone
    firewall.json
    backup.json
    tappaas-cicd.json

  srvWork/
    forgejo.json
    litellm.json

  Community/srvWork/         ← Community repo, srvWork zone
    nextcloud.json

  iotCloud/
    solaredge.json
    alfen.json

  _cluster/                  ← no zone0: cluster-level helpers
    cluster.json
    templates.json
```

- Zone isolation is visible at a glance — `ls config/iotCloud/` answers "what is in my IoT zone?"
- `install-module.sh` derives path from `zone0` in module config
- Valid folder names are bounded by `zones.json` zone keys
- Multi-repo: prefix with repo name when same zone appears in multiple repos (e.g. `Community/srvWork/`)

**Contract with layer 2:** `moduleName` = config filename stem. `install-module.sh` is the authoritative tool for creating and updating config files.

---

## Rationale

**`managed` + `catalog` fields:** `repository.sh` derives validation rules from `configuration.json` at runtime — no hardcoded paths, no operator flags needed.

**Rename to `module-catalog.json`:** Consistent with `module-fields.json` naming convention. Communicates role (catalog, not implementation detail).

**Config folder structure (zone-based):** The config directory is operational state, not build state. Organize by operational domain (zone = security boundary), not supply chain (repo). `zone0` is already in every module config — the folder structure is implicit in the data. Zone isolation is the primary compliance boundary; it should be visible at the filesystem level. Multi-repo disambiguation uses `<repo>/<zone>/` prefix when needed.

**`timezone` in `configuration.json`:** A cluster has one timezone. Propagating it from one field eliminates per-VM drift and manual overrides. `lib.mkDefault "UTC"` in modules provides a safe fallback.

---

## Open issues

| # | Topic | Status |
|---|---|---|
| #297 | `module-catalog.json` rename + JSON Schema (`module-catalog-fields.json`) | ✅ done |
| #305 | Rename `modules.json` → `module-catalog.json` (TAPPaaS + Community repos) | ✅ done |
| TBD | `timezone` field in `configuration.json` + propagation | **to file** (deferred) |
| TBD | Config directory zone-based folder structure | **to file** (deferred) |

---

## Consequences

### Changes required

| What | Where |
|---|---|
| Add `managed`, `catalog` fields to `repositories[]` | `configuration.json` |
| `repository.sh add --managed <full\|tracked>` | `scripts/repository.sh` |
| Add `timezone` field + `copy-update-json.sh` propagation | `configuration.json`, `scripts/` |
| Add `stack`, `category`, `status` to catalog entries | `src/module-catalog.json` |
| Migrate `/home/tappaas/config/` to folder structure | `config/`, `install-module.sh` |

### What stays the same

- `module-fields.json` field contract for individual module JSONs
- `install-module.sh` as the authoritative tool for config files
- GH Issues workflow

### Implementation order

1. ✅ Merge #297 + #305 (`module-catalog.json` rename + `module-catalog-fields.json` schema)
2. ⏳ File + implement `timezone` issue *(deferred — own issue)*
3. ✅ `repository.sh --managed` + `catalog` field in `configuration.json`
4. ⏳ Config folder structure migration + `install-module.sh` update *(deferred — own issue)*
5. ✅ Add `stack` + `category` + `status` to catalog entries
