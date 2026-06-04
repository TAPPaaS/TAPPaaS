# ADR-004: Module catalog → desired-state config cascade

**Status:** proposed
**Date:** 2026-06-04
**Deciders:** @LarsRossen + @ErikDaniel007
**Related:** #297 (module-catalog.json rename), repository.sh

---

## Context

A TAPPaaS cluster draws modules from one or more repositories. Two questions arise as the platform scales:

1. **What modules exist?** No single file answers this across multiple repos.
2. **What is deployed?** `/home/tappaas/config/*.json` are the live desired state, but no formal contract links them to the catalog.

The current state has three files without a formal cascade:

| File | Role today | Gap |
|---|---|---|
| `configuration.json` | Cluster root; lists repos | No `type` field per repo; only TAPPaaS registered |
| `src/modules.json` (→ `module-catalog.json`) | VMID collision register | No taxonomy, no schema |
| `/home/tappaas/config/<m>.json` | Live desired state | Not validated against catalog |

---

## Decision

**Define a three-layer cascade with formal contracts at each boundary.**

### Layer 1 — Cluster registry: `configuration.json`

Add a `type` field to each repository entry:

```json
{
  "tappaas": {
    "repositories": [
      {
        "name": "TAPPaaS",
        "url": "github.com/TAPPaaS/TAPPaaS",
        "branch": "main",
        "path": "/home/tappaas/TAPPaaS",
        "managed": "full"
      },
      {
        "name": "my-org-apps",
        "url": "github.com/example/my-org-apps",
        "branch": "stable",
        "path": "/home/tappaas/repos/my-org-apps",
        "managed": "tracked"
      }
    ]
  }
}
```

`managed` values:

| Value | Meaning | `repository.sh` behaviour |
|---|---|---|
| `"full"` | Repo contains TAPPaaS modules with `src/module-catalog.json` | Full validation: VMID registry, catalog schema, module count |
| `"tracked"` | Repo uses the cluster but defines no TAPPaaS modules | Registered in `configuration.json`; no catalog validation; `repository.sh` records it but does not manage module lifecycle |

`tracked` repos are registered so cluster tooling knows they exist (e.g. update schedules, SSH key distribution) but TAPPaaS imposes no structural requirements on their content.

### Layer 2 — Module catalog: `src/module-catalog.json`

Every `managed: full` repo contains `src/module-catalog.json` (per #297).

Required fields per entry:

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

- `stack` and `category`: enable catalog-driven tooling and UI (per #297)
- `status`: single source of truth for module readiness
- VMID uniqueness validated at commit time via JSON Schema

### Layer 3 — Desired state: `/home/tappaas/config/<module>.json`

Operator-owned desired-state files. Contract with layer 2: `moduleName` = config filename stem. `install-module.sh` is the authoritative tool for creating and updating these files.

---

## Rationale

**`managed` in `configuration.json`:** `repository.sh` validates `src/module-catalog.json` for `full` repos; `tracked` repos are registered with no catalog requirements. The field is machine-readable so tooling routes without operator flags at runtime.

**`stack` + `category` in module-catalog:** Two fields cover all current query patterns without over-specifying. Sufficient for UI, dashboards, and compliance sweeps.

**Industry precedent:** This three-layer model is standard in platform engineering (Backstage `catalog-info.yaml` + desired state; Helm chart registry + `values.yaml`; Crossplane XRD + XR). TAPPaaS implements the same pattern in JSON.

---

## Consequences

### Changes required

| What | Where | Blocks on |
|---|---|---|
| Add `managed` field to `configuration.json repositories[]` | `configuration.json` | `repository.sh` |
| `repository.sh add --managed <full|tracked>` flag | `scripts/repository.sh` | tracked repo registration |
| `stack`, `category`, `status` in `module-catalog.json` entries | per #297 | catalog tooling |

### What gets better

- Any tool reading `configuration.json` knows all repos and their validation rules
- VMID collisions caught at commit time, not install time
- `module-catalog.json` + JSON Schema is the single queryable module registry

### What stays the same

- `/home/tappaas/config/` structure — no changes
- `install-module.sh` — no changes
- GH Issues workflow — no changes

### Implementation order

1. Merge #297 (`module-catalog.json` rename + JSON Schema)
2. Extend `repository.sh` with `--managed <full|tracked>` flag
3. Update `configuration.json repositories[]` with `managed` field
4. Add `stack` + `category` to existing `module-catalog.json` entries
