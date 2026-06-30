# ADR-007e — Health (Lens)

| | |
|---|---|
| **Status** | Accepted — **partially implemented** (the observability plane is built; status-badge UI is future) |
| **Version** | 1.2 |
| **Date** | 2026-06-30 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; **realized by:** the `logging` Module (Loki/Grafana/Promtail) + the read-only `health-manager` |
| **Changelog** | v1.2 — **as-built (2026-06-30):** the lens is realized by the **`logging` foundation Module** (Loki + Grafana + Promtail + syslog ingest from OPNsense and the PVE nodes) and a **read-only `health-manager`** (inspect/check verbs — no `add/modify/delete`, since a lens owns no entities). The per-artifact status-badge UI remains future work. v1.1 — "bucket" → "classification domain" throughout; Health = lens, not a classification domain (2026-06-17) |

The **🩺 Health** lens. **Not a classification domain** — a cross-cutting *overlay* that shows status on People,
Apps, and Environments.

## Decision

Health is a **lens**, not a fourth classification domain. Observability is folded into each artifact's status badge,
with a single Site-level Health page as the system-wide overview. This keeps the "it just works"
prosumer UX (status on the thing it relates to) while preserving a cross-cutting ops view.

> **As built.** The observability plane is the **`logging`** Module (Grafana dashboards over Loki; Promtail
> + syslog receivers ingest the firewall and every PVE node's journal). The control-plane lens is
> **`health-manager`** — deliberately **read-only** (`inspect`/`check`), with **no** `validate`/`add`/
> `modify`/`delete` verbs, because a lens observes entities it does not own (see the verb-alignment doc).

## How it surfaces

| Where | Example |
|-------|---------|
| next to an **App** | 🟢 service responding, recent backup OK |
| next to an **Environment** | 🟡 one node degraded, others fine |
| next to a **User** | 🔴 MFA expired |
| Site-level Health page | system-wide overview (the only dedicated Health UI page) |

## Why a lens, not a classification domain

A module that *observes everything* cannot be MECE-assigned to a single classification domain. Modeling Health as a
classification domain would break ADR-007's "exactly one classification domain per artifact" invariant. As a lens it
overlays all three classification domains without partitioning them. Industry: Health is universally tracked but
variably positioned — TAPPaaS chooses *lens* over *classification domain* for prosumer UX. Evidence:
[Architecture/taxonomy.md](<../Architecture/taxonomy.md>) → A.1.

## Acceptance

- [ ] Status badges defined for App / Environment / User.
- [ ] One Site-level Health overview page in the UI mockup.
