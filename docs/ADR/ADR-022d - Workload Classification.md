# ADR-022d — Workload Classification

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.2 |
| **Date** | 2026-09-09 (v0.2: 2026-09-11) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Related** | [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>) (Q1's concept — this ADR classifies against it, does not redefine it); [ADR-022c — Node and Host](<ADR-022c - Node and Host.md>) (`kind` as object-type marker); [ADR-007e](<ADR-007e - Health.md>) (Health — amended here); [ADR-012 Appendix A](ADR-012-backup-enhancement.md) (the taxonomy this replaces and retires); **#456** (origin — "do we agree on this?"); **#481** (the PR that landed Appendix A); [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite) |
| **Changelog** | v0.1 — initial draft. Splits ADR-012 Appendix A's six flat values into two questions, decides `kind`'s values, and gives Health the inventory it needs to cover workloads TAPPaaS does not manage. v0.2 — renamed from ADR-023 to ADR-022d, becoming a fourth rib under the ADR-022 spine alongside 022a/b/c (2026-09-11 LR/EB sync: "kind is absolutely a workload classification" — it belongs beside Administrative Domain, Location, Node/Host, not as a freestanding number). **Q1 rewritten** to cite ADR-022a's Administrative-Domain definition (D1/D3) instead of re-deriving it — closing a duplication both this ADR and ADR-022a D5 independently asserted (caught live on the call: "in ADR23, the notion of site was actually repeated from 22A"). **Q2's question reworded** from "what does it run on" to "what type of device/workload is this" — the actual question `kind` answers, per the call's own diagnosis. `kind`'s enumeration expanded: `cluster` added as decided; `hardware-module`, a managed-non-cluster-machine value, `kubernetes` and `docker-container` recorded as open/proposed, not decided; `shim`-as-kind reconfirmed rejected. New open questions added for the "degree of management" axis and OS-as-classification for bare metal; the `node`→`depends-on` replacement is cross-referenced as explicit future (3.0) work, out of scope here. |

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

**Q1 — Who administers it?** Applies to every workload. This is [ADR-022a](<ADR-022a - Administrative Domain.md>)'s concept, not a second one: D1 adopts **Administrative Domain** (RFC 4375) as *"the collection of resources under the control of a single administrative authority,"* and D3 distinguishes **accountability** (the administrator — what Q1 classifies) from **ownership** (data accountability, modelled separately as Organization, ADR-007a). This ADR does not re-derive that definition; it decides the four values a workload's administrator-relationship takes, ordered best-first by **control**: can this Site close the gap from its own side?

| Value | Administered by | Can we close it? | Defect? |
|---|---|---|---|
| `this-site` | this Administrative Domain | already ours | — |
| `no-site` | nobody TAPPaaS — third party, pre-existing | **yes** — adopt or migrate | yes, closable |
| `other-site` | another TAPPaaS Site | no — never ours | no, by design |
| `unknown` | not known to exist | find it first | yes, worst |

`no-site` ranks above `other-site` because the criterion is goal achievement, not trust: an unmanaged workload in our own domain is a gap we can close; another Site's workload never is. The **Defect?** column keeps that from reading as a demotion.

**Q2 — What type of device/workload is this?** Asked only when Q1 is `this-site`. This is `kind` — the object-type marker [ADR-022c](<ADR-022c - Node and Host.md>) D5 defines as tooling-written, never hand-authored. v0.1 asked "what does it run on," which is the wrong question: as `kind` grows beyond VM/LXC (below), two workloads can share a substrate and still be different device types, and the substrate question is already answered elsewhere — by the Host/`node` relationship (ADR-022c), not by `kind`. `kind` answers **what class of device or workload this is**.

**Decided values:**

| `kind` | Meaning | Module boundary |
|---|---|---|
| `guest` | a VM or LXC running on a cluster member | the VM |
| `host` | its own Node, not a cluster guest | the host |
| `cluster` | the Proxmox cluster itself, as a module in its own right — `site.json` stops directly enumerating cluster nodes | the cluster |

`cluster` is decided-now, not a future/3.0 item: stating it as a `kind` value does not require the `node`→`depends-on` change (see the parking lot below) — only that the cluster gets a module file of its own.

**`external-host` is retired.** It named the administrative aspect while defining the hosting one, which is why its two schema definitions contradict each other.

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
- Q1 now points at one source (ADR-022a) instead of two independent derivations of "who administers it."

### Negative / costs
- A schema-value migration across the seven files carrying `external-host`.
- Health gains an inventory surface it does not have today; scope and storage are open (below).
- `kind`'s enumeration is now explicitly open-ended (four proposed candidates), which the Acceptance list below does not yet close.

## Open questions

1. **Where does the inventory live?** Health needs somewhere to record `no-site` / `other-site` / `unknown` workloads. A `health-manager` verb, a file, or discovery output — undecided.
2. **How is `unknown` discovered at all?** Out of scope here; it is the reason the value exists.
3. **`backup:vm` naming drift** — under `kind: guest` it would read `backup:guest`. **Recommended: leave it.** 14 modules depend on `backup:vm` and the rename buys nothing.
4. **Does a satellite need a `pending` phase** (host up, tunnel or storage not yet configured)? Raised in the source taxonomy, still open.
5. **`hardware-module` naming and boundary** — exact name and where it stops and `host` starts (2026-09-11).
6. **Is the managed-non-cluster-machine case (PBS / "standardized Debian machine") a `host` sub-type, or its own `kind` value?** (2026-09-11) Undecided.
7. **`kubernetes` as a `kind`** — blocked on the parked one-module-vs-a-grouping-of-modules question. Not designable until that's resolved.
8. **`docker-container`** — anticipated ("come very soon"), not yet designed.
9. **Does OS become part of the classification for bare-metal hosts** (bare-metal-Debian vs. bare-metal-NixOS vs. bare-metal-Windows)? Raised 2026-09-11, unresolved.
10. **A "degree of management" axis** (aware-of → manage-network → manage-firmware) was raised as a candidate enumeration distinct from both Q1 and Q2 (2026-09-11) — not designed here; a future open question for this ADR or a successor, not assigned yet.

### Parking lot — explicitly out of scope here

The `node` field's replacement by a general `depends-on` relationship (a module depends on another module that happens to be a Host, rather than naming a node) — and the fuller recursive module model this implies (hosts and the cluster itself as modules other modules depend on) — was discussed and explicitly deferred as a **3.0 change** (2026-09-11 sync). Today's `node` field semantics, as described in [ADR-022c](<ADR-022c - Node and Host.md>), are unaffected by this ADR. This is recorded here only as a forward pointer, not a decision; it may eventually motivate a change to `cluster`'s module boundary above, but that is future work.

## Acceptance

- [ ] Q1 rewritten to cite ADR-022a (D1/D3) instead of re-deriving Administrative Domain; four values kept with the ranking and Defect column
- [ ] Q2 reworded to "what type of device/workload is this"; decided `kind` values (`guest` / `host` / `cluster`) written up; `external-host` retired across all seven files
- [ ] Proposed `kind` candidates (`hardware-module`, the managed-non-cluster-machine value, `kubernetes`, `docker-container`) recorded as open, not decided
- [ ] `realized` defined as a state, replacing `shim` in ADR-012; the `shim`-as-`kind` rejection reconfirmed
- [ ] ADR-007e amended: Health covers unmanaged workloads
- [ ] ADR-012 Appendix A replaced by a pointer to this ADR (now ADR-022d)
- [ ] Inventory home decided (open question 1)
- [ ] ADR-022a cross-references this ADR for the four Q1 values (reciprocal link — see ADR-022a's own Acceptance)
