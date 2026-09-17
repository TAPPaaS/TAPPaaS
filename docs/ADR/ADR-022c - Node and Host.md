# ADR-022c — Node and Host

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.4 |
| **Date** | 2026-09-09 (v0.4: 2026-09-17) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Refines** | [ADR-007d — Site](<ADR-007d - Site.md>) (`nodes`) · [ADR-007b — Apps](<ADR-007b - Apps.md>) (the `node` field) |
| **Supersedes in part** | [ADR-009](<ADR-009 - Composition Meta-Model.md>) — the `Node` entry (:40), the model line (:26) and Decision 1 (:66–72, Node = physical host) |
| **Amends** | [ADR-007b](<ADR-007b - Apps.md>) :95 (`node` note) · [ADR-007d](<ADR-007d - Site.md>) :30–33 (`nodes`) · [GLOSSARY.md](../../GLOSSARY.md) §B :33 (Node), §C :50–51 (Stack-promotion rule) · [ADR-007f](<ADR-007f - Realization.md>) (receives that rule) |
| **Changelog** | v0.4 (2026-09-17) — review #624/#637: module boundary, `kind` marker and Host discovery removed (`kind` is ADR-022d's); D6/D7 renumbered D4/D5; supersedes and amends rows completed (ADR-009, ADR-007b, ADR-007d, GLOSSARY, ADR-007f). Earlier drafts in git history. |

What a resource runs on.

## Decision

**D1. `Node` returns to its ArchiMate meaning:**

> A node represents a computational or physical resource that hosts, manipulates, or interacts with other computational or physical resources.

A cluster member, a bare-metal host and a VM are all Nodes. `GLOSSARY.md` §B declares itself ArchiMate-based and then narrows Node to "the physical Proxmox host" — which in ArchiMate is a **Device** plus **System Software**, not a Node.

**D2. Add `cluster member`** — a Node belonging to the Proxmox cluster, declared in `site.json`. This is the narrow sense the glossary previously called "Node", and it stays available where it is genuinely meant.

**D3. Add `Host`** — the Node a Module runs on. The `node` **field** keeps its name for compatibility; it names a Host and does **not** assert cluster membership. Live evidence: `config/backup.json` carries `node: "backup"` while `site.json` lists only `tappaas1` and `tappaas2`.

**D4. Plane vocabulary is scoped to the `network` module.** [RFC 7426](https://www.rfc-editor.org/rfc/rfc7426.html) defines forwarding, operational, control, management and application planes, all in terms of *network devices* and *traffic*; "data plane" is not a defined term there, only a widely used nickname for the forwarding plane. TAPPaaS runs a real forwarding plane in OPNsense and the switches, so the words must not be reused for workloads. The general term for what the management plane acts on is **Managed Element** ([MAPE-K](https://arxiv.org/pdf/1505.00903)).

**D5. `tier` is namespaced** — `module.tier` (lifecycle) and `zone.tier` (trust, ADR-014). The Stack-promotion rule in `GLOSSARY.md` §C is renamed and moved out of the vocabulary file; it is a rule, not a term.

## Schema

- `node` field — description amended: names a Host; does not imply cluster membership.
- No field is renamed by this ADR.

## Migration

Documentation only. The `kind: external-host` retirement is listed in [ADR-022d](<ADR-022d - Workload Classification.md>).

## Acceptance

- [ ] `Node`, `cluster member` and `Host` defined in `GLOSSARY.md` §B per D1–D3
- [ ] ADR-009's `Node` entry marked superseded by this ADR
- [ ] ADR-007b's `node` note ("the physical Proxmox host") amended per D3
- [ ] `Managed Element` and `forwarding plane` defined; plane vocabulary marked network-scoped
- [ ] `module.tier` / `zone.tier` namespaced; Stack-promotion rule moved to ADR-007f
