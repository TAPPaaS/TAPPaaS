# ADR-004: Module catalog → desired-state config → backlog cascade

**Status:** proposed
**Date:** 2026-06-04
**Deciders:** @LarsRossen + @ErikDaniel007
**Related:** #297 (module-catalog.json rename), #304 (zone key camelCase), repository.sh

---

## Context

A TAPPaaS cluster draws modules from one or more repositories. Three questions arise as the platform scales:

1. **What modules exist?** No single file answers this across multiple repos.
2. **What is deployed?** `/home/tappaas/config/*.json` files are the live desired state, but there is no formal contract between them and the catalog.
3. **What needs changing?** Backlog items (GH Issues) have no machine-readable link to the module they describe.

The current state has three files without a formal cascade:

| File | Role today | Gap |
|---|---|---|
| `configuration.json` | Cluster root; lists repos | Only TAPPaaS registered; no `type` field per repo |
| `src/modules.json` (→ `module-catalog.json`) | VMID collision register | No taxonomy, no schema, not linked to config |
| `/home/tappaas/config/<m>.json` | Live desired state | Not validated against catalog |
| GH Issues | Module backlog | No `catalog_ref` field |

This pattern is well-established in platform engineering (Backstage, Crossplane, Helm registry) — we are implementing the same three-layer model: *what can exist* → *what should exist* → *what needs changing*.

---

## Decision

**Define a four-layer cascade with formal contracts at each boundary.**

### Layer 1 — Cluster registry: `configuration.json`

```json
{
  "tappaas": {
    "repositories": [
      {
        "name": "TAPPaaS",
        "url": "github.com/TAPPaaS/TAPPaaS",
        "branch": "main",
        "path": "/home/tappaas/TAPPaaS",
        "type": "module"
      },
      {
        "name": "gdty-apps",
        "url": "github.com/ErikDaniel007/gdty-apps",
        "branch": "main",
        "path": "/home/tappaas/repos/gdty-apps",
        "type": "digital-org"
      }
    ]
  }
}
```

- Add `type` field: `"module"` | `"digital-org"`
- All repos that supply modules or desired-state config to the cluster are listed here
- `repository.sh` is the authoritative tool; it must support `--type digital-org`

### Layer 2 — Module catalog: `src/module-catalog.json`

Every repo of `type: module` contains `src/module-catalog.json` (renamed from `modules.json` per #297).

Minimum required fields per entry:

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

- `stack` and `category` enable catalog-driven tooling and UI (per #297)
- `status` is the single source of truth for module readiness
- VMID uniqueness is validated at commit time via JSON Schema

### Layer 3 — Desired state: `/home/tappaas/config/<module>.json`

Each deployed module has one config file. The contract with layer 2:

- `module.json` fields (`vmname`, `zone0`, `vmid`) are authoritative
- Config files are operator-owned copies of the module spec, potentially with local overrides
- `install-module.sh` is the authoritative tool for creating/updating these files

No direct schema validation between layer 2 and layer 3 is required today. The link is `moduleName` = config filename stem.

### Layer 4 — Module backlog: GH Issues

Each GH Issue that tracks a module improvement carries a `catalog_ref` label matching `moduleName` in `module-catalog.json`.

Label convention: `module:<name>` (e.g. `module:forgejo`, `module:hass`).

This enables:
```bash
gh issue list --label "module:forgejo"   # forgejo backlog
gh issue list --label "module:firewall"  # firewall backlog
```

No structural change to GH Issues is required — labels are sufficient at this scale.

---

## Rationale

**Why a `type` field in `configuration.json`?**
`repository.sh` validates repos differently by type (`src/module-catalog.json` for module repos, `catalog.json` for digital-org repos). The type must be machine-readable so the tool can route validation without operator flags at runtime.

**Why `stack` + `category` in module-catalog?**
Flat unordered lists cannot drive UIs, dashboards, or compliance sweeps. Two fields cover all current query patterns without over-specifying.

**Why GH Issue labels instead of a separate backlog file per module?**
At current scale (<30 modules, single operator), a separate backlog file per module is over-engineered. GH Issues with `module:<name>` labels give the same queryability with zero additional tooling. Migration to a dedicated backlog file is straightforward when the module count warrants it.

**Industry precedent:**
- Backstage: `catalog-info.yaml` (layer 2) + Kubernetes desired state (layer 3) + GitHub Issues (layer 4)
- Helm: Chart registry (layer 2) + `values.yaml` (layer 3) + GitHub Issues (layer 4)
- Crossplane: XRD (layer 2) + XR (layer 3) + GH Issues (layer 4)

We are not unique. The decision here is which existing pattern to adopt at TAPPaaS scale.

---

## Consequences

### Changes required

| What | Where | Blocks |
|---|---|---|
| Add `type` field to `configuration.json repositories[]` | `configuration.json` | repository.sh |
| `repository.sh add --type digital-org` | `scripts/repository.sh` | gdty-apps registration |
| Add `stack`, `category`, `status` to `module-catalog.json` entries | per #297 | catalog tooling |
| Add `module:<name>` label to existing GH Issues | GitHub | backlog queryability |
| `gdty-apps`: add `src/module-catalog.json` | gdty-apps | repository.sh compliance |

### What gets better
- Any tool that reads `configuration.json` knows all repos and their type
- `gh issue list --label module:forgejo` is the forgejo backlog — no extra files
- `module-catalog.json` + JSON Schema catches VMID collisions at commit time, not install time

### What stays the same
- `/home/tappaas/config/` structure — no changes
- GH Issues workflow — labels added, nothing removed
- `install-module.sh` — no changes

### Risks
- `repository.sh` change is in `src/foundation/` — requires @LarsRossen review
- `module-catalog.json` schema (per #297) must land before layer 2 is enforced

---

## Implementation order

1. Merge #297 (`module-catalog.json` rename + schema)
2. Extend `repository.sh` with `--type` flag
3. Add `type` to `configuration.json repositories[]` + register gdty-apps
4. Add `module:<name>` labels to open GH Issues
5. Add `stack` + `category` to existing `module-catalog.json` entries
