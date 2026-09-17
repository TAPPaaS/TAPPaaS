# ADR-024 — Site Fabric

| | |
|---|---|
| **Status** | **Draft — placeholder.** Problem statement only; no schema, no field names, no storage decision. Explicitly deferred past 2.0. |
| **Version** | 0.3 |
| **Date** | 2026-09-11 (v0.3: 2026-09-17) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) — this ADR builds on the Administrative Domain aspect, it does not amend it |
| **Related** | [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>) (the single-Administrative-Domain concept this ADR generalizes to a fabric); [ADR-012](ADR-012-backup-enhancement.md) §1.4 (the backup-buddy relationship — first live instance of the problem); satellite/`edge` zone case (ADR-010) |
| **Changelog** | v0.3 (2026-09-17) — references to ADR-022a D6/D7 removed (parked for 2.1). Placeholder; no content decided. Earlier drafts in git history. |

How a Site relates to the rest of the world — other TAPPaaS Sites, and third-party services it exposes to or consumes from.

---

## Context

[ADR-022a](<ADR-022a - Administrative Domain.md>) decided that a Site is **exactly one** Administrative Domain. That settles what a Site *is*, but not how it relates to the ones it is not — a buddy Site for off-site backup (ADR-012 §1.4), a satellite reachable only over a tunnel (ADR-010), or a module consuming a third-party service (e.g. an external OpenAI-compatible endpoint for LiteLLM). Today each of these is a per-module pointer, with no shared vocabulary or structure between them.

The gap is bigger than any one case: a Site needs a general way to describe that it lives inside a larger ecosystem — of other TAPPaaS Sites, and of third-party providers it exposes services to or consumes services from. Framed as a "site of sites," the question is how a Site declares a relationship to another Administrative Domain, not just how one specific module (backup) happens to point at one.

## Scope

Two things settled about this ADR's own boundary, both staying this way until a real drafting pass:

1. **Bidirectional.** This is not only "how do we describe our off-site backup buddy" — it is the general question of a Site **exposing** services outward and **consuming** services from outside, of which the backup-buddy case and the LiteLLM-external-provider case are two instances of the same underlying concept, not two separate mechanisms.
2. **Builds on ADR-022a, does not amend it.** ADR-022a decided a Site is one Administrative Domain. This ADR is the next question up: what does a *fabric* of Administrative Domains look like, and how does a Site declare a relationship to another one (or to something outside the fabric entirely)? [ADR-022a](<ADR-022a - Administrative Domain.md>) is unchanged by this draft.

**Explicitly out of scope for now** — this is a placeholder, not a design:

- Field names, schema shape, or where a fabric relationship is stored (module-level, site-level, or a new artifact).
- How a module declares "I expose this" or "I consume that" in a structured way (today: an ad hoc pointer per module — e.g. `pbsUrl` for backup).
- Whether a Site should broker all outward exposure itself, rather than each module registering its own — a candidate direction, not a decision.

## Candidate normative anchor (unverified)

The IETF/BGP **Autonomous System** concept was raised as the closest existing model for one administrative system relating to a larger ecosystem of peers. This would sit alongside [ADR-022a](<ADR-022a - Administrative Domain.md>)'s existing RFC 4375/1136 anchors (RFC 4375 defines an Administrative Domain; the AS literature is the inter-domain-relationship layer above it) — flagged here as an anchor **to verify** when this ADR is actually drafted, not asserted as decided.

## Open questions (all of them — nothing below is decided)

1. Where does a fabric relationship live — on the Site record, on the module that has the relationship, or a new artifact?
2. How does a module register that it exposes a service, or consumes one, in a way Health (ADR-007e) can see?
3. Does "Site brokers all exposure" become a Decision, or does per-module exposure stay legitimate for some cases?
4. Is the AS/BGP anchor the right normative source, or does TAPPaaS need its own model here?
5. How does this interact with the workload-to-Administrative-Domain relationship taxonomy parked from [ADR-022a](<ADR-022a - Administrative Domain.md>) for 2.1 — is "another Site's workload" the fabric-scoped view this ADR would otherwise describe more richly?

## Acceptance

Not applicable at placeholder status — no Decision section exists yet to accept against. This ADR advances to a real draft once 2.0 ships and the kind/classification work (ADR-022d) is settled.
