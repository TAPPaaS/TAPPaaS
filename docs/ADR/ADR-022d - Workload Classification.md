# ADR-022d — Workload Classification

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.4 |
| **Date** | 2026-09-09 (v0.4: 2026-09-11) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Related** | [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>) (D6 — the `this-site`/`no-site`/`other-site`/`unknown` values this ADR classifies against, once a workload is `this-site`; D7 — Health's inventory of everything else); [ADR-022c — Node and Host](<ADR-022c - Node and Host.md>) (`kind` as object-type marker); [ADR-012 Appendix A](ADR-012-backup-enhancement.md) (the taxonomy this replaces and retires); **#456** (origin — "do we agree on this?"); **#481** (the PR that landed Appendix A); [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite) |
| **Changelog** | v0.1 — initial draft. Splits ADR-012 Appendix A's six flat values into two questions, decides `kind`'s values, and gives Health the inventory it needs to cover workloads TAPPaaS does not manage. v0.2 — renamed from ADR-023 to ADR-022d, becoming a fourth rib under the ADR-022 spine alongside 022a/b/c; Q1 rewritten to *cite* ADR-022a instead of re-deriving it; Q2 reworded to "what type of device/workload is this." **v0.3 corrects v0.2**: citing wasn't enough — ADR-022a's own charter already is "who is accountable for a resource," so v0.2's Q1 (the four-value table, its ranking, and the Health-inventory consequence) has **moved wholesale to ADR-022a D6/D7**, not merely cited from there. This document now decides exactly one thing: `kind` — what type of device/workload something is, once ADR-022a's D6 has already said it is `this-site`. Renumbered accordingly; open questions 1–2 (Health's inventory storage, `unknown` discovery) moved to ADR-022a as they were about D6's values, not `kind`. v0.4 — the "Appendix A retires cleanly" mapping table moved to the spine, [ADR-022](<ADR-022 - Workload Ontology.md>) — it spans both ribs plus `site.json` and the zone, so it isn't this rib's content either. |

What type of device or workload a `this-site` resource is — TAPPaaS's `kind`.

---

## Context

ADR-012 Appendix A carries a six-value taxonomy — `node` · `standalone` · `satellite` · `external` · `remote` · `rogue` — marked *"companion reference, not a decision"*, destined for its own ADR. This is that ADR, together with [ADR-022a](<ADR-022a - Administrative Domain.md>) D6/D7, which now owns the "who administers it" half of the split this ADR originally proposed.

Appendix A's table is correct but flat: it answers two questions at once (who runs it, and what type it is), which is why `external` ends up spanning cases that behave differently and why `shim` sits as a peer value beside placements rather than as a state of one. [ADR-022a](<ADR-022a - Administrative Domain.md>) D6 answers the first question; this ADR answers the second.

This is urgent rather than tidy because **`kind` is already broken**: `module-fields.json` defines `kind: external-host` as *"a non-module **cluster guest**"*; `satellite-fields.json` defines the same value as *"an EXTERNAL host, **NOT** a Proxmox cluster:vm"*. Both on `main`. A satellite this Site provisions and manages is filed under a value named "external".

## Decision

### 1. `kind` answers one question: what type of device/workload is this

Asked only once [ADR-022a](<ADR-022a - Administrative Domain.md>) D6 has classified a workload as `this-site`. This is `kind` — the object-type marker [ADR-022c](<ADR-022c - Node and Host.md>) D5 defines as tooling-written, never hand-authored. v0.1 asked "what does it run on," which is the wrong question: as `kind` grows beyond VM/LXC (below), two workloads can share a substrate and still be different device types, and the substrate question is already answered elsewhere — by the Host/`node` relationship (ADR-022c), not by `kind`. `kind` answers **what class of device or workload this is**.

**Decided values:**

| `kind` | Meaning | Module boundary |
|---|---|---|
| `guest` | a VM or LXC running on a cluster member | the VM |
| `host` | its own Node, not a cluster guest | the host |
| `cluster` | the Proxmox cluster itself, as a module in its own right — `site.json` stops directly enumerating cluster nodes | the cluster |

`cluster` is decided-now, not a future/3.0 item: stating it as a `kind` value does not require the `node`→`depends-on` change (see the parking lot below) — only that the cluster gets a module file of its own.

**`external-host` is retired.** It named the administrative aspect (now [ADR-022a](<ADR-022a - Administrative Domain.md>) D6) while defining the hosting one, which is why its two schema definitions contradict each other.

**Proposed values — raised on 2026-09-11, not decided:**

| Candidate | What it would cover | Status |
|---|---|---|
| `hardware-module` (name open) | a physical device with an IP, uninspectable / unmanaged beyond network config — e.g. an IoT device | Proposed; name not settled |
| a managed-but-non-cluster-machine value | motivated by PBS, generalized to "a standardized way of managing Debian machines" (updates, SSH, checks) | Proposed; overlaps with `host` — undecided whether this is a `host` sub-type or a separate value |
| `kubernetes` | a Kubernetes-managed workload | Raised; blocked on whether a K8s deployment is one module or a grouping of modules (parked, see Open questions) |
| `docker-container` | a Docker container as its own device/workload type | Flagged as "coming soon" — not yet added to the decided table |

**Explicitly rejected:** `shim` was raised again as a candidate `kind` and rejected again, on the same grounds as §3 below — it is a state ("a step toward something else"), not a device type. No change to §3's treatment; recorded here for the trail.

### 2. Position is recorded, not encoded in the value

Two facts that Appendix A folded into its values are already recorded elsewhere, and stay there:

- **Is the Host a cluster member?** Declared in `site.json`. Not duplicated into `kind`.
- **Where is it — locally, or off-site through a tunnel?** The **zone** (ADR-014) and the **Location** (ADR-022b). The `edge` zone exists for exactly the satellite case.

### 3. `realized` is a state, not a value

Whether a workload's storage or service is actually built is orthogonal to what it is. ADR-012's `shim` is `realized: false`. Expressing it as a peer value makes "placed on a host, not yet built" inexpressible. (Reconfirmed 2026-09-11 — see §1's `shim` rejection above.)

The full retirement mapping (all six Appendix A terms against both this ADR's `kind` and ADR-022a D6 together) lives on the spine — [ADR-022 §Mapping](<ADR-022 - Workload Ontology.md#mapping--appendix-a-retires-cleanly>) — since it draws on both ribs plus `site.json` and the zone, not on this rib alone.

## Consequences

### Positive
- `external` stops being a hosting fact, a management claim and a placement state at once.
- `kind` gets one definition instead of two contradictory ones.
- ADR-012 Appendix A retires jointly with ADR-022a D6; ADR-012 keeps only backup.
- This document now owns exactly one question, matching its rib in ADR-022's spine — no overlap with ADR-022a's charter.

### Negative / costs
- A schema-value migration across the seven files carrying `external-host`.
- `kind`'s enumeration is now explicitly open-ended (four proposed candidates), which the Acceptance list below does not yet close.

## Open questions

1. **`backup:vm` naming drift** — under `kind: guest` it would read `backup:guest`. **Recommended: leave it.** 14 modules depend on `backup:vm` and the rename buys nothing.
2. **Does a satellite need a `pending` phase** (host up, tunnel or storage not yet configured)? Raised in the source taxonomy, still open.
3. **`hardware-module` naming and boundary** — exact name and where it stops and `host` starts (2026-09-11).
4. **Is the managed-non-cluster-machine case (PBS / "standardized Debian machine") a `host` sub-type, or its own `kind` value?** (2026-09-11) Undecided.
5. **`kubernetes` as a `kind`** — blocked on the parked one-module-vs-a-grouping-of-modules question. Not designable until that's resolved.
6. **`docker-container`** — anticipated ("come very soon"), not yet designed.
7. **Does OS become part of the classification for bare-metal hosts** (bare-metal-Debian vs. bare-metal-NixOS vs. bare-metal-Windows)? Raised 2026-09-11, unresolved.
8. **A "degree of management" axis** (aware-of → manage-network → manage-firmware) was raised as a candidate enumeration distinct from both ADR-022a D6 and this ADR's `kind` (2026-09-11) — not designed here; a future open question for this ADR or a successor, not assigned yet.

*Moved to [ADR-022a](<ADR-022a - Administrative Domain.md>) in v0.3, as they were about D6's values, not `kind`:* where the `no-site`/`other-site`/`unknown` inventory lives, and how `unknown` is discovered.

### Parking lot — explicitly out of scope here

The `node` field's replacement by a general `depends-on` relationship (a module depends on another module that happens to be a Host, rather than naming a node) — and the fuller recursive module model this implies (hosts and the cluster itself as modules other modules depend on) — was discussed and explicitly deferred as a **3.0 change** (2026-09-11 sync). Today's `node` field semantics, as described in [ADR-022c](<ADR-022c - Node and Host.md>), are unaffected by this ADR. This is recorded here only as a forward pointer, not a decision; it may eventually motivate a change to `cluster`'s module boundary above, but that is future work.

## Acceptance

- [ ] `kind` values decided as `guest` / `host` / `cluster`; `external-host` retired across all seven files
- [ ] Proposed `kind` candidates (`hardware-module`, the managed-non-cluster-machine value, `kubernetes`, `docker-container`) recorded as open, not decided
- [ ] `realized` defined as a state, replacing `shim` in ADR-012; the `shim`-as-`kind` rejection reconfirmed
- [ ] ADR-012 Appendix A replaced by a pointer to this ADR and ADR-022a D6/D7 jointly
- [ ] This document contains no independent definition of ADR-022a's D6 values — only uses them
