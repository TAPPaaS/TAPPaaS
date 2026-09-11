# ADR-024 — Site Fabric

| | |
|---|---|
| **Status** | **Draft — placeholder.** Problem statement only; no schema, no field names, no storage decision. Explicitly deferred past 2.0 (2026-09-11 LR/EB sync: "the kind thing I need to settle now in 2.0. The other thing I don't need right now"). |
| **Version** | 0.1 |
| **Date** | 2026-09-11 |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) — this ADR builds on the Administrative Domain aspect, it does not amend it |
| **Related** | [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>) (the single-AD concept this ADR generalizes to a fabric of ADs); [ADR-012](ADR-012-backup-enhancement.md) §1.4 (the backup-buddy relationship — first live instance of the problem); satellite/`edge` zone case (ADR-010) |
| **Changelog** | v0.1 — placeholder draft opened from the 2026-09-11 LR/EB sync. Captures the problem statement and scope boundary only; LR proposed the ADR ("I would like to start an ADR024, which is about inter-site relationships"), Erik tied it to ADR-022a ("this basically builds upon 22A... a fabric of administrative domains"). No decision made. |

How a Site relates to the rest of the world — other TAPPaaS Sites, and third-party services it exposes to or consumes from.

---

## Context

[ADR-022a](<ADR-022a - Administrative Domain.md>) decided that a Site is **exactly one** Administrative Domain. That settles what a Site *is*, but not how it relates to the ones it is not — a buddy Site for off-site backup (ADR-012 §1.4), a satellite reachable only over a tunnel (ADR-010), or a module consuming a third-party service (e.g. an external OpenAI-compatible endpoint for LiteLLM). Today each of these is a per-module pointer, with no shared vocabulary or structure between them.

LR's framing, live on the call (2026-09-11): *"it's not who administrated it, but it's really a bigger concept of saying... my TAPPaaS system lives in a larger ecosystem of providers of services. I provide services and I consume services from the outside. This is about managing that larger inter-TAPPaaS fabric."*

Erik's framing of the same gap: *"if you zoom out and you make a site of sites... I got multiple sites around and I associate a module with a site."* — and, on where the boundary should sit: *"the services you're exposing is not backup exposing itself... your site is the master of all... Site is the administrative domain. It's the one that decides whether you can expose yourself or not."*

## Scope

Two things the call was explicit about, and both stay this way until a real drafting pass:

1. **Bidirectional.** This is not only "how do we describe our off-site backup buddy" — it is the general question of a Site **exposing** services outward and **consuming** services from outside, of which the backup-buddy case and the LiteLLM-external-provider case are two instances of the same underlying concept, not two separate mechanisms.
2. **Builds on ADR-022a, does not amend it.** ADR-022a decided a Site is one Administrative Domain. This ADR is the next question up: what does a *fabric* of Administrative Domains look like, and how does a Site declare a relationship to another one (or to something outside the fabric entirely)? [ADR-022a](<ADR-022a - Administrative Domain.md>) is unchanged by this draft.

**Explicitly out of scope for now** — this is a placeholder, not a design:

- Field names, schema shape, or where a fabric relationship is stored (module-level, site-level, or a new artifact).
- How a module declares "I expose this" or "I consume that" in a structured way (today: an ad hoc pointer per module — e.g. `pbsUrl` for backup).
- Whether "Site is the master of all exposure" (Erik's proposed principle above) becomes a Decision — recorded here as a candidate direction only.

## Candidate normative anchor (unverified)

LR gestured at the IETF/BGP **Autonomous System** concept as the closest existing model: *"it's the AS concept, administrative system, in the RFC world... I have one administrative system called MyTAPPaaSSystem, and it lives in a larger ecosystem."* This would sit alongside [ADR-022a](<ADR-022a - Administrative Domain.md>)'s existing RFC 4375/1136 anchors (RFC 4375 defines an Administrative Domain; the AS literature is the inter-domain-relationship layer above it) — flagged here as an anchor **to verify** when this ADR is actually drafted, not asserted as decided.

## Open questions (all of them — nothing below is decided)

1. Where does a fabric relationship live — on the Site record, on the module that has the relationship, or a new artifact?
2. How does a module register that it exposes a service, or consumes one, in a way Health (ADR-007e, amended by [ADR-022d](<ADR-022d - Workload Classification.md>) §4) can see?
3. Does "Site brokers all exposure" (Erik's candidate principle) become a Decision, or does per-module exposure stay legitimate for some cases?
4. Is the AS/BGP anchor the right normative source, or does TAPPaaS need its own model here?
5. How does this interact with [ADR-022d](<ADR-022d - Workload Classification.md>)'s `other-site` value (Q1) — is `other-site` the fabric-scoped view of a workload this ADR would otherwise describe more richly?

## Acceptance

Not applicable at placeholder status — no Decision section exists yet to accept against. This ADR advances to a real draft once 2.0 ships and the kind/classification work (ADR-022d) is settled, per the call's own sequencing.
