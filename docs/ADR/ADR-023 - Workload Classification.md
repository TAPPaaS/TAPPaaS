# ADR-023 — Workload Classification

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.1 |
| **Date** | 2026-09-09 |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Related** | [ADR-022](<ADR-022 - Workload Ontology.md>) (the vocabulary this ADR uses); [ADR-007e](<ADR-007e - Health.md>) (Health — amended here); [ADR-012 Appendix A](ADR-012-backup-enhancement.md) (the taxonomy this replaces and retires); **#456** (origin — "do we agree on this?"); **#481** (the PR that landed Appendix A); [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite) |
| **Changelog** | v0.1 — initial draft. Splits ADR-012 Appendix A's six flat values into two questions, decides `kind`'s values, and gives Health the inventory it needs to cover workloads TAPPaaS does not manage. |

How TAPPaaS sorts every workload it is aware of — including the ones it does not manage.

---

## Context

ADR-012 Appendix A carries a six-value taxonomy — `node` · `standalone` · `satellite` · `external` · `remote` · `rogue` — marked *"companion reference, not a decision"*, destined for its own ADR. This is that ADR.

Appendix A's table is correct but flat: it answers two questions at once (who runs it, and where it runs), which is why `external` ends up spanning cases that behave differently and why `shim` sits as a peer value beside placements rather than as a state of one.

Two things make this urgent rather than tidy:

1. **`kind` is already broken.** `module-fields.json` defines `kind: external-host` as *"a non-module **cluster guest**"*; `satellite-fields.json` defines the same value as *"an EXTERNAL host, **NOT** a Proxmox cluster:vm"*. Both on `main`. A satellite this Site provisions and manages is filed under a value named "external".
2. **Health has no place to put what it does not manage.** `GLOSSARY.md` scopes Health to *"all classification terms"* — i.e. what is catalogued. An undiscovered workload on the estate is exactly what a stability review needs to surface, and there is nowhere to record it.

## Decision

### 1. Two questions, not one flat list

**Q1 — Who administers it?** Applies to every workload. Ordered best-first by **control**: can this Site close the gap from its own side?

| Value | Administered by | Can we close it? | Defect? |
|---|---|---|---|
| `this-site` | this Administrative Domain | already ours | — |
| `no-site` | nobody TAPPaaS — third party, pre-existing | **yes** — adopt or migrate | yes, closable |
| `other-site` | another TAPPaaS Site | no — never ours | no, by design |
| `unknown` | not known to exist | find it first | yes, worst |

`no-site` ranks above `other-site` because the criterion is goal achievement, not trust: an unmanaged workload in our own domain is a gap we can close; another Site's workload never is. The **Defect?** column keeps that from reading as a demotion.

**Q2 — What does it run on?** Asked only when Q1 is `this-site`. This is `kind`:

| `kind` | Meaning | Module boundary |
|---|---|---|
| `guest` | a VM or LXC running on a cluster member | the VM |
| `host` | its own Node, not a cluster guest | the host |

**`external-host` is retired.** It named the administrative aspect while defining the hosting one, which is why its two schema definitions contradict each other.

### 2. Position is recorded, not encoded in the value

Two facts that Appendix A folded into its values are already recorded elsewhere, and stay there:

- **Is the Host a cluster member?** Declared in `site.json`. Not duplicated into `kind`.
- **Where is it — locally, or off-site through a tunnel?** The **zone** (ADR-014) and the **Location** (ADR-022b). The `edge` zone exists for exactly the satellite case.

### 3. `realized` is a state, not a value

Whether a workload's storage or service is actually built is orthogonal to what it is. ADR-012's `shim` is `realized: false`. Expressing it as a peer value makes "placed on a host, not yet built" inexpressible.

### 4. Health owns the inventory

Health is a **viewpoint** (ISO/IEC 42010) across every classification domain, **including workloads this Site does not manage**. `no-site`, `other-site` and `unknown` have no module file and never will — they are observations, and Health is where observations live. This amends ADR-007e.

## Mapping — Appendix A retires cleanly

| Appendix A | Q1 | `kind` | Host is cluster member? | zone |
|---|---|---|---|---|
| `node` | `this-site` | `host` | yes | `mgmt` |
| `standalone` | `this-site` | `host` | no | `mgmt` |
| `satellite` | `this-site` | `host` | no | `edge` |
| `external` | `no-site` | — | — | — |
| `remote` | `other-site` | — | — | — |
| `rogue` | `unknown` | — | — | — |
| `shim` | — | — | — | `realized: false` |

All six terms survive as coordinates. None is lost, and no value carries two questions.

## Consequences

### Positive
- `external` stops being a hosting fact, a management claim and a placement state at once.
- `kind` gets one definition instead of two contradictory ones.
- A Site can record what it does not manage — the precondition for a stability review.
- ADR-012 Appendix A retires; ADR-012 keeps only backup.

### Negative / costs
- A schema-value migration across the seven files carrying `external-host`.
- Health gains an inventory surface it does not have today; scope and storage are open (below).

## Open questions

1. **Where does the inventory live?** Health needs somewhere to record `no-site` / `other-site` / `unknown` workloads. A `health-manager` verb, a file, or discovery output — undecided.
2. **How is `unknown` discovered at all?** Out of scope here; it is the reason the value exists.
3. **`backup:vm` naming drift** — under `kind: guest` it would read `backup:guest`. **Recommended: leave it.** 14 modules depend on `backup:vm` and the rename buys nothing.
4. **Does a satellite need a `pending` phase** (host up, tunnel or storage not yet configured)? Raised in the source taxonomy, still open.

## Acceptance

- [ ] Q1's four values defined, with the ranking and the Defect column
- [ ] `kind` values decided as `guest` / `host`; `external-host` retired across all seven files
- [ ] `realized` defined as a state, replacing `shim` in ADR-012
- [ ] ADR-007e amended: Health covers unmanaged workloads
- [ ] ADR-012 Appendix A replaced by a pointer to this ADR
- [ ] Inventory home decided (open question 1)
