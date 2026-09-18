# ADR-022d — Workload Classification

| | |
|---|---|
| **Status** | **Accepted** (2026-09-18) |
| **Version** | 1.0 |
| **Date** | 2026-09-09 (v1.0: 2026-09-18) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Refines** | [ADR-007b — Apps](<ADR-007b - Apps.md>) (what type of thing a module is) |
| **Amends** | ~~[ADR-012](ADR-012-backup-enhancement.md) §1.1, §2.1 (`shim` becomes `realized: false`)~~ (declined, #612) · Appendix A (pointer) · [ADR-009](<ADR-009 - Composition Meta-Model.md>) :41 and [GLOSSARY.md](../../GLOSSARY.md) :34 (Module boundary = VM boundary) |
| **Related** | [ADR-022c — Node and Host](<ADR-022c - Node and Host.md>); [ADR-007f — Realization](<ADR-007f - Realization.md>); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (composition); [ADR-012](ADR-012-backup-enhancement.md) (first consumer); #611 |
| **Changelog** | v1.0 (2026-09-18) — accepted (operator) with ADR-022f's values folded in (`machine`, `application`). The `realized` amendment to ADR-012 is **declined**: `shim` stays (ADR-012 v1.0, #612). · v0.18 (2026-09-18) — `kind` marker resolved (#611): `kind` names the workload; the ADR-007 `module` marker is retired by migration 0004; `external-host` retired. · v0.17 (2026-09-17) — review #624/#637: reduced to the `kind` vocabulary in one table; `cluster`/`kubernetes` noted as grouping concepts; dispatch rationale kept; `kind` marker left open; open questions and parking lot removed, to be filed as issues; amended ADR-009, GLOSSARY and ADR-012 declared. Earlier drafts in git history. |

What type of thing a module is — TAPPaaS's `kind`.

## Decision

### 1. `kind` answers one question: what type of thing is this module

**Why it matters — `kind` is a dispatch key.** [ADR-007f](<ADR-007f - Realization.md>) establishes Manager → Controller → Service: a Manager owns a domain's verbs and calls a Controller for the live I/O. `kind` is the field a Manager reads to pick the right Controller — `proxmox-controller` for a `vm` or `lxc`, and none exists yet for a `device`. A wrong or ambiguous `kind` is therefore a routing defect, not only a documentation one.

**As built today**, `module-manager` does not dispatch on `kind` yet: it installs a module by calling the `install-service.sh` of each `dependsOn` provider (for example `cluster:vm`), and `kind` is only stamped as the deployment marker `module` (see Migration). This ADR fixes the vocabulary that dispatch will need, not the dispatch itself.

**What a module runs on** is not `kind`: that is its Host, named by the `node` field ([ADR-022c](<ADR-022c - Node and Host.md>) D3). Two modules on the same substrate can still be different types.

| `kind` | Status | Meaning | Example | Normative anchor |
|---|---|---|---|---|
| `vm` | Accepted | a virtual machine (KVM/QEMU) on a cluster member | `openwebui` | DMTF Redfish `ComputerSystem.SystemType: Virtual`; Proxmox VE `qemu` API |
| `lxc` | Accepted | a Linux container (LXC) on a cluster member | `vllm-amd` | Redfish `SystemType: Virtual`; Proxmox VE `lxc` API |
| `host` | Accepted | its own Node, manageable by TAPPaaS (SSH, checks, updates) but not a cluster guest — cluster member or not | `satellite` | Redfish `SystemType: Physical` |
| `device` | Accepted | reachable by IP, unmanaged beyond network configuration — TAPPaaS cannot SSH into it or run checks against it | `alfen`, `smlight`; `backup` when it uses an external PBS | ArchiMate 3.x **Device** |
| `app` | Proposed | software installed onto an existing Host | `backup` with a local PBS | — |
| `oci` | Proposed | an OCI container tracked as its own module, not inside a `vm`/`lxc` | — | OCI Image & Runtime Specifications |

`host` the value is not **Host** the role (ADR-022c D3: the Node a module runs on); ADR-022f proposes renaming the value.

`cluster` and `kubernetes` are grouping concepts (composite modules), not `kind` values alongside the above — proposed in #637, to be decided in a separate ADR. That ADR also covers modelling hosts and clusters as modules, with a dependency hierarchy between modules.

### 2. What `kind` does not record

Each fact below has its own home and is never encoded in `kind`:

- **Cluster membership** — `site.json` ([ADR-022c](<ADR-022c - Node and Host.md>) D2).
- **Location and network position** — [ADR-022b](<ADR-022b - Location.md>) and the zone ([ADR-014](<ADR-014 - Zone and Environment Lifecycle.md>)).
- **Operating system** — a separate attribute.
- **Realization** — `shim` is a state, not a type. *(Accepted without the `realized: false` rename: `shim` stays as ADR-012's placement value — ADR-012 v1.0, #612.)*
- **Administrative relationship** — `external` is not a `kind` value.
- **Guest internals** — software a `vm` or `lxc` runs inside (for example a podman container) is not the module's `kind`.

### 3. Retired

`external-host` — it named who administers a resource while defining what it runs on, and its two schema definitions contradict each other (`module-fields.json`: *"a non-module cluster guest"*; `satellite-fields.json`: *"an EXTERNAL host, NOT a Proxmox cluster:vm"*). A satellite is part of the Site, at a Location different from the cluster, and is `kind: host`.

## Migration

`kind: external-host` appears in nine files in this repo — seven code or schema files (`schemas/satellite-fields.json`, `schemas/module-fields.json`, `satellite/satellite.json`, `satellite/test.sh`, `satellite-manager/lib/provision.sh`, `satellite-manager/test.sh`, the `module-manager` baseline fixture) and two docs (`satellite/README.md`, `satellite/DESIGN.md`) — plus copies in the Community repo (`satellite-fields.json`, `test.sh`, README).

**Resolved 2026-09-18 (#611): `kind` names the workload, and the deployment marker is retired.** `kind` was also ADR-007's object-type marker (`module`, stamped by `install-module.sh`). The marker gets no field of its own because nothing needs one: module discovery (#544) already recognises a module by its shape, the marker was never the only signal on any measured site, and older installs never carried it. The stamping is removed, each module AUTHORS its `kind` in its source JSON, and migration 0004 removes `kind: "module"` from deployed configs so the 3-way merge can adopt the authored value — except where the marker is a config's only module signal, where it is kept (discovery still accepts it) so the module does not vanish. `cluster` and `templates` carry no `kind` until the grouping-concept ADR.

## Consequences

- `kind` gets one definition, and every accepted value has a normative anchor.
- ADR-012 Appendix A can be retired; ADR-012 keeps only backup.
- Schema migration across the files above.

## Acceptance

- [ ] Accepted values `vm` / `lxc` / `host` / `device` defined in `GLOSSARY.md` with their anchors
- [ ] Proposed values recorded as proposed
- [x] `external-host` retired across the files above (#611; the Community repo's copies are that repository's to change)
- [x] ~~`realized` defined as a state, replacing `shim` in ADR-012~~ — declined: `shim` stays (ADR-012 v1.0, #612)
- [x] Resolved: `kind` marker value vs. its own field — neither: the marker is retired (#611, migration 0004)
- [ ] ADR-012 Appendix A replaced by a pointer to this ADR and to the parked administrative-domain relationship work
