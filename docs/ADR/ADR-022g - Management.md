# ADR-022g — Management

| | |
|---|---|
| **Status** | **Accepted** (2026-09-18) |
| **Version** | 1.0 |
| **Date** | 2026-09-17 (v1.0: 2026-09-18) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Amends** | `schemas/module-fields.json` `status` and `schemas/module-catalog-fields.json` `status` · [ADR-022d](<ADR-022d - Workload Classification.md>) (`device` meaning) · [ADR-012](ADR-012-backup-enhancement.md) §1.3, §2.1–§2.3, §2.7, §4, Testing, Acceptance, Appendix A (`placementState: external` → `consumed`; the `backup-manage.sh use-external` verb) |
| **Related** | [ADR-022a](<ADR-022a - Administrative Domain.md>) (Administrative Domain); [ADR-007e](<ADR-007e - Health.md>) (Health); [ADR-025](<ADR-025 - Config migrations and the upgrade path.md>); [ADR-022h](<ADR-022h - Facet Register.md>); #637, #614 |
| **Changelog** | v1.0 (2026-09-18) — accepted (operator), with D5 as amended by ADR-012 v0.9: `placementState` keeps `external`. `management` is recorded, not yet read by the sweep. · v0.1 (2026-09-17) — proposal: `management: managed \| unmanaged`; `external` kept for the administrative domain; `status` reduced to maturity. |

Whether TAPPaaS tooling controls a resource.

## Context

`external` carries several unrelated meanings on `main`:

| Where | Meaning |
|---|---|
| `module-fields.json` `status: external` | a guest on the cluster that TAPPaaS does not manage (no live config carries it) |
| backup `placementState: external` | a PBS used by URL — a buddy, a third party, or a local PBS installed outside TAPPaaS |
| backup `update.sh` | a PBS whose machine is not a cluster member — set even when TAPPaaS installed it |
| `kind: external-host` | a satellite, which TAPPaaS does manage (retired by ADR-022d) |
| `edge` zone | an off-site relay |

The code already separates the question this ADR names: `health-manager` classifies each running guest as `managed`, `external` or `not-in-config` (`inspect.ts:48`).

`status` answers three questions in one enum: maturity (`Development`, `Testing`, `Production`, `Deprecated`), lifecycle (`archived`) and management (`external`).

## Decision

**D1. Add `management: managed | unmanaged`.**

| Value | Meaning |
|---|---|
| `managed` | TAPPaaS tooling installs, updates, tests and deletes it |
| `unmanaged` | registered so TAPPaaS knows it exists; no install, update, test or delete lifecycle applies |

Anchor: the Kubernetes recommended label `app.kubernetes.io/managed-by` (the tool that manages a resource); ITIL 4 configuration items under or outside configuration control.

> **As implemented (2026-09-18):** `management` is a general module field, default `managed` (absent means managed). It is **recorded, not yet read**: the sweep still takes a module out of its lifecycle with `status: archived | external`, and moving that decision onto `management` is its own change.

**D2. `external` means only: outside this Site's Administrative Domain** (RFC 4375, ADR-022a). It is never a management value, a `status` value, a `kind` or a placement.

**D3. `status` answers maturity only** — `Development`, `Testing`, `Production`, `Deprecated` (Backstage `spec.lifecycle`). `archived` becomes a lifecycle state beside `realized` (ADR-022d §2); `external` becomes `management: unmanaged`. The catalog's `status` (`stable`, `beta`, `incomplete`, `deprecated`) answers the same question with other values; the two are merged into one enumeration.

**D4. Not registered is an observation, not a value.** A guest with no config (`not-in-config`) has no `management` field; how Health inventories it is the parked relationship work (ADR-022a).

**D5. Backup's consumed PBS is `placementState: consumed`**, replacing `external`. A PBS that TAPPaaS installed is placed on its Host (`node:<name>` today, `host:<name>` in PR #614) — never `consumed`, whether or not that Host is a cluster member.

**D6. `device` is a kind, not a management level.** ADR-022d's "unmanaged beyond network configuration" becomes "only network reachability is configured" (ADR-022f D1); whether TAPPaaS manages it is this facet.

## Migration

- `module-fields.json`: add `management`; `status` loses `archived`, `external`.
- Readers: `health-manager/src/inspect.ts`, `module-manager/src/inspect.ts`, `module-manager/src/types.ts`, `backup-manager/src/config.ts`, `backup/lib/pbs-job.sh`.
- `placementState` readers: `backup/lib/pbs-placement.sh`, `backup/update.sh`, `backup/scripts/backup-manage.sh`, `backup-manager` (`config.ts`, `main.ts`).
- One config migration (ADR-025); old values accepted for one release.

## Conflicts

- **#637 (09-16)** — *"a module can NOT be external as a module is managed by TAPPaaS"*. D2 agrees for `external`. D1 still allows a registered module to be `unmanaged`, which `status: external` already expresses today.
- **ADR-012** — D5 renames an implemented placement value.

## Acceptance

- [ ] `management`, `external` and `status` defined in `GLOSSARY.md` per D1–D3
- [ ] ADR-007b and ADR-012 §2.1 amended
- [ ] Readers and data migrated; old values accepted for one release
