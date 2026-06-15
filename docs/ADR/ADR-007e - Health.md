# ADR-007e — Health (Lens)

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.0 |
| **Date** | 2026-06-15 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320 |

The **🩺 Health** lens. **Not a bucket** — a cross-cutting *overlay* that shows status on People,
Apps, and Environments.

## Decision

Health is a **lens**, not a fourth bucket. Observability is folded into each artifact's status badge,
with a single Site-level Health page as the system-wide overview. This keeps the "it just works"
prosumer UX (status on the thing it relates to) while preserving a cross-cutting ops view.

## How it surfaces

| Where | Example |
|-------|---------|
| next to an **App** | 🟢 service responding, recent backup OK |
| next to an **Environment** | 🟡 one node degraded, others fine |
| next to a **User** | 🔴 MFA expired |
| Site-level Health page | system-wide overview (the only dedicated Health UI page) |

## Why a lens, not a bucket

A module that *observes everything* cannot be MECE-assigned to a single bucket. Modeling Health as a
classification bucket would break ADR-007's "exactly one bucket per artifact" invariant. As a lens it
overlays all three buckets without partitioning them. Industry: Health is universally tracked but
variably positioned — TAPPaaS chooses *lens* over *bucket* for prosumer UX. Evidence:
[Architecture/taxonomy.md](<../Architecture/taxonomy.md>) → A.1.

## Acceptance

- [ ] Status badges defined for App / Environment / User.
- [ ] One Site-level Health overview page in the UI mockup.
