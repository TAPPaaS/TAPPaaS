# ADR-022c — Node and Host

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.1 |
| **Date** | 2026-09-09 |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Supersedes in part** | [ADR-009](<ADR-009 - Composition Meta-Model.md>) — the `Node` entry |

What a resource runs on, and what `kind` records.

## Decision

**D1. `Node` returns to its ArchiMate meaning:**

> A node represents a computational or physical resource that hosts, manipulates, or interacts with other computational or physical resources.

A cluster member, a bare-metal host and a VM are all Nodes. `GLOSSARY.md` §B declares itself ArchiMate-based and then narrows Node to "the physical Proxmox host" — which in ArchiMate is a **Device** plus **System Software**, not a Node.

**D2. Add `cluster member`** — a Node belonging to the Proxmox cluster, declared in `site.json`. This is the narrow sense the glossary previously called "Node", and it stays available where it is genuinely meant.

**D3. Add `Host`** — the Node a Module runs on. The `node` **field** keeps its name for compatibility; it names a Host and does **not** assert cluster membership. Live evidence: `config/backup.json` carries `node: "backup"` while `site.json` lists only `tappaas1` and `tappaas2`.

**D4. Module boundary follows `kind`.** *"Module boundary = VM boundary"* has two live counterexamples — `satellite.json` (`vmname: null`) and the `backup` module, which apt-installs PBS on a host. Boundary is the VM for `kind: guest`, the host for `kind: host`.

**D5. `kind` is the object-type marker**, tooling-written, never hand-authored — the Kubernetes convention TAPPaaS already follows. Its **values** are decided by [ADR-022d](<ADR-022d - Workload Classification.md>), not here. What this ADR settles is that `external-host` cannot survive: `module-fields.json` defines it as *"a non-module cluster guest"* and `satellite-fields.json` as *"an EXTERNAL host, NOT a Proxmox cluster:vm"* — the same value, contradictory, both on `main`.

**D6. Plane vocabulary is scoped to the `network` module.** [RFC 7426](https://www.rfc-editor.org/rfc/rfc7426.html) defines forwarding, operational, control, management and application planes, all in terms of *network devices* and *traffic*; "data plane" is not a defined term there, only a widely used nickname for the forwarding plane. TAPPaaS runs a real forwarding plane in OPNsense and the switches, so the words must not be reused for workloads. The general term for what the management plane acts on is **Managed Element** ([MAPE-K](https://arxiv.org/pdf/1505.00903)).

**D7. `tier` is namespaced** — `module.tier` (lifecycle) and `zone.tier` (trust, ADR-014). The Stack-promotion rule in `GLOSSARY.md` §C is renamed and moved out of the vocabulary file; it is a rule, not a term.

**D8. A Host that is not a cluster member must be discoverable on its own terms.** Defining `Host` is not enough if every probe assumes Proxmox VE. `backup/lib/pbs-placement.sh` discovers storage with `pvesm status` and enumerates candidates with `pvesh get /nodes`, so a Node outside the cluster can be *named* but never *found*. A term that tooling cannot detect is a term that gets worked around. The implementation is tracked as a `backup` issue; the requirement is recorded here so it is not lost.

## Schema

- `module-fields.json` / `satellite-fields.json` — one definition of `kind`, values per ADR-022d.
- `node` field — description amended: names a Host; does not imply cluster membership.
- No field is renamed by this ADR.

## Migration

`kind: external-host` appears in seven files: `satellite-fields.json`, `module-fields.json`, `satellite.json`, `satellite-manager/lib/provision.sh`, `satellite/test.sh`, `satellite-manager/test.sh`, and one `module-manager` fixture. The value change lands with ADR-022d, which decides the replacement.

## Acceptance

- [ ] `Node`, `cluster member` and `Host` defined in `GLOSSARY.md` §B per D1–D3
- [ ] ADR-009's `Node` entry marked superseded by this ADR
- [ ] `Module` boundary defined as `kind`-dependent
- [ ] `kind` defined once, in one place
- [ ] `Managed Element` and `forwarding plane` defined; plane vocabulary marked network-scoped
- [ ] `module.tier` / `zone.tier` namespaced; Stack-promotion rule moved to ADR-007f
