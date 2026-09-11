# ADR-022d — Workload Classification

| | |
|---|---|
| **Status** | **Draft — for review** |
| **Version** | 0.5 |
| **Date** | 2026-09-09 (v0.5: 2026-09-11) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Related** | [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>) (D6 — the `this-site`/`no-site`/`other-site`/`unknown` values this ADR classifies against, once a workload is `this-site`; D7 — Health's inventory of everything else); [ADR-022c — Node and Host](<ADR-022c - Node and Host.md>) (`kind` as object-type marker); [ADR-007f — Realization](<ADR-007f - Realization.md>) (Manager → Controller → Service — the mechanism `kind` exists to drive); [ADR-012 Appendix A](ADR-012-backup-enhancement.md) (the taxonomy this replaces and retires); **#456** (origin — "do we agree on this?"); **#481** (the PR that landed Appendix A); [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite) |
| **Changelog** | v0.1 — initial draft. Splits ADR-012 Appendix A's six flat values into two questions, decides `kind`'s values, and gives Health the inventory it needs to cover workloads TAPPaaS does not manage. v0.2 — renamed from ADR-023 to ADR-022d, becoming a fourth rib under the ADR-022 spine alongside 022a/b/c; Q1 rewritten to *cite* ADR-022a instead of re-deriving it; Q2 reworded to "what type of device/workload is this." v0.3 corrects v0.2: citing wasn't enough — ADR-022a's own charter already is "who is accountable for a resource," so v0.2's Q1 has moved wholesale to ADR-022a D6/D7. This document now decides exactly `kind`. v0.4 — the "Appendix A retires cleanly" mapping table moved to the spine, ADR-022. **v0.5** — two gaps caught in review: (1) **the rationale for why `kind` needs to be a real, tooling-verifiable enumeration was never written down** — it drives Manager→Controller dispatch (ADR-007f), not just vocabulary hygiene; added to Context. (2) **`guest` is retired as a decided value** — LR rejected it live on the call as too generic ("it could be a Kubernetes guest... which will be very different"); re-inspecting the transcript, the actual agreed direction was explicit typing (`vm` / `lxc` / bare metal), confirmed by LR's own operational language throughout ("PVE VM or PVE LXC management commands"). Normative anchors added: [DMTF Redfish](https://www.dmtf.org/standards/redfish) `ComputerSystem.SystemType` for the top-level Physical/Virtual/Composed split, Proxmox VE's own `qemu`/`lxc` API distinction for the guest sub-split (TAPPaaS's actual substrate — same source ADR-022c already leans on for module-boundary evidence), and the [OCI Image/Runtime Specifications](https://opencontainers.org/) as the anchor for the still-open `docker-container` candidate, explicitly distinguished from LXC (a system container, not an OCI application container — conflating them would be a real modeling error). |

What type of device or workload a `this-site` resource is — TAPPaaS's `kind`.

---

## Context

ADR-012 Appendix A carries a six-value taxonomy — `node` · `standalone` · `satellite` · `external` · `remote` · `rogue` — marked *"companion reference, not a decision"*, destined for its own ADR. This is that ADR, together with [ADR-022a](<ADR-022a - Administrative Domain.md>) D6/D7, which now owns the "who administers it" half of the split this ADR originally proposed.

Appendix A's table is correct but flat: it answers two questions at once (who runs it, and what type it is), which is why `external` ends up spanning cases that behave differently and why `shim` sits as a peer value beside placements rather than as a state of one. [ADR-022a](<ADR-022a - Administrative Domain.md>) D6 answers the first question; this ADR answers the second.

This is urgent rather than tidy for two reasons:

1. **`kind` is already broken.** `module-fields.json` defines `kind: external-host` as *"a non-module **cluster guest**"*; `satellite-fields.json` defines the same value as *"an EXTERNAL host, **NOT** a Proxmox cluster:vm"*. Both on `main`. A satellite this Site provisions and manages is filed under a value named "external".

2. **`kind` is not just vocabulary — it is a dispatch key.** [ADR-007f](<ADR-007f - Realization.md>) already establishes Manager → Controller → Service as the built control plane: a Manager owns a domain's verb surface and calls a Controller for live I/O. Discussed live on 2026-09-11: *"when the manager needs to do something on a module, it can look at the kind and figure out which controller to talk to... If it's a VM or a[n LXC], you talk to the Proxmox controller because it knows everything about how these things work. If it's a hardware device, right now, we don't have a controller for it."* Today `module-manager` does not yet do this — per ADR-007f's as-built mapping it always uses the `cluster:vm` / `network:proxy` install-service hooks regardless of `kind` — but that is the direction this vocabulary has to support: a wrong or ambiguous `kind` is not a documentation defect, it is a routing defect. Whether `kind` should fully abstract a device (ask it uniform questions) or only route to the right controller (ask type-specific questions) is itself still open — LR: *"the exact way to implement it in a pluggable manner, I haven't thought through yet. But where you're going [routing] is exactly the direction we should take."* Recorded as a design direction, not a decision; see Open questions.

## Decision

### 1. `kind` answers one question: what type of device/workload is this

Asked only once [ADR-022a](<ADR-022a - Administrative Domain.md>) D6 has classified a workload as `this-site`. This is `kind` — the object-type marker [ADR-022c](<ADR-022c - Node and Host.md>) D5 defines as tooling-written, never hand-authored. v0.1 asked "what does it run on," which is the wrong question: as `kind` grows beyond VM/LXC (below), two workloads can share a substrate and still be different device types, and the substrate question is already answered elsewhere — by the Host/`node` relationship (ADR-022c), not by `kind`. `kind` answers **what class of device or workload this is**.

**Decided values:**

| `kind` | Meaning | Module boundary |
|---|---|---|
| `vm` | a virtual machine (KVM/QEMU) running on a cluster member | the VM |
| `lxc` | a Linux Container (LXC) running on a cluster member | the container |
| `host` | its own Node, not a cluster guest | the host |
| `cluster` | the Proxmox cluster itself, as a module in its own right — `site.json` stops directly enumerating cluster nodes | the cluster |

`cluster` is decided-now, not a future/3.0 item: stating it as a `kind` value does not require the `node`→`depends-on` change (see the parking lot below) — only that the cluster gets a module file of its own.

**Why `vm`/`lxc`, not `guest`.** v0.1–v0.4 used `guest` (a VM or LXC on a cluster member) as one value. Raised again live on 2026-09-11 and rejected: *"I don't like the word guest. It's too generic because it can be guest of what. It could be a Kubernetes guest for the matter, which will be very different"* (LR). Erik's counter-proposal — *"it's a VM. Or it's an LXC. Or it's a bare metal... classify to what it really is"* — is what this table now does. It is not a cosmetic rename: `guest` is also the operative distinction for dispatch (Context, above) — `module-manager list` already does different work for `PVE VM` vs `PVE LXC` management commands (LR, same session), so collapsing them back into one value would re-hide a real difference the routing rationale exists to expose.

**Normative anchor.** [DMTF Redfish](https://www.dmtf.org/standards/redfish) `ComputerSystem.SystemType` (verified against the current schema) gives the top-level split this table's rows sit inside: `Physical` ("a computer system" — this ADR's `host`), `Virtual` ("a virtual machine instance running on this system" — `vm`/`lxc` together), and `Composed` ("a computer system constructed by binding resource blocks together" — a good conceptual match for `cluster`). Redfish does not distinguish hypervisor VMs from containers within `Virtual` — that split is TAPPaaS's own substrate: the Proxmox VE API itself separates `GET /nodes/{node}/qemu/{vmid}` from `GET /nodes/{node}/lxc/{vmid}`, which is the same source [ADR-022c](<ADR-022c - Node and Host.md>) already treats as authoritative for module-boundary evidence. Using Proxmox's own two guest types, rather than inventing TAPPaaS-specific names, keeps `kind` tooling-verifiable by construction — the property [ADR-022c](<ADR-022c - Node and Host.md>) D5 requires ("tooling-written, never hand-authored").

**`external-host` is retired.** It named the administrative aspect (now [ADR-022a](<ADR-022a - Administrative Domain.md>) D6) while defining the hosting one, which is why its two schema definitions contradict each other.

**Proposed values — raised on 2026-09-11, not decided:**

| Candidate | What it would cover | Status |
|---|---|---|
| `hardware-module` (name open) | a physical device with an IP, uninspectable / unmanaged beyond network config — e.g. an IoT device | Proposed; name not settled |
| a managed-but-non-cluster-machine value | motivated by PBS, generalized to "a standardized way of managing Debian machines" (updates, SSH, checks) | Proposed; overlaps with `host` — undecided whether this is a `host` sub-type or a separate value |
| `kubernetes` | a Kubernetes-managed workload | Raised; blocked on whether a K8s deployment is one module or a grouping of modules (parked, see Open questions) |
| a container/OCI value (`docker-container` as raised, name open) | an OCI application container, as its own device/workload type | Flagged as "coming soon" — not yet added to the decided table. **Not the same thing as `lxc`**: LXC is a system container (a lightweight VM, own init/full OS), OCI/Docker is an application container (one process, shares the host kernel more directly, packaged per the [OCI Image Specification](https://opencontainers.org/)). Proxmox itself only runs LXC natively; an OCI container needs a runtime (e.g. Docker/Podman) hosted *inside* a `vm`, `lxc`, or `host` — so this candidate is a workload distinction layered on top of the others, not a peer substrate type, and needs its own design pass before it can be added |

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
- `kind` gets one definition instead of two contradictory ones, and the VM/LXC split is now the one the tooling already exercises, not merely named.
- ADR-012 Appendix A retires jointly with ADR-022a D6; ADR-012 keeps only backup.
- This document now owns exactly one question, matching its rib in ADR-022's spine — no overlap with ADR-022a's charter.
- The dispatch rationale (Context §2) gives a concrete acceptance test for any future `kind` candidate: does it change which Controller (or lack of one) a Manager calls?

### Negative / costs
- A schema-value migration across the seven files carrying `external-host` — now also touching every `kind: guest` site, since `guest` no longer exists as a value.
- `kind`'s enumeration is now explicitly open-ended (four proposed candidates), which the Acceptance list below does not yet close.
- Manager→Controller dispatch by `kind` is a direction, not a built mechanism (`module-manager` doesn't do it yet) — this ADR fixes the vocabulary it will need, not the dispatch code itself.

## Open questions

1. **`backup:vm` naming drift — narrowed, not eliminated, by the `vm`/`lxc` split.** `backup:vm` already matches the new `kind: vm` value exactly, so no rename is needed there. It's still inexact for a `kind: lxc` workload requesting the same capability. **Recommended: leave it** — `backup:vm` is a capability name (what's being backed up), not a restatement of `kind`; 14 modules depend on it and a rename buys nothing.
2. **Does a satellite need a `pending` phase** (host up, tunnel or storage not yet configured)? Raised in the source taxonomy, still open.
3. **`hardware-module` naming and boundary** — exact name and where it stops and `host` starts (2026-09-11).
4. **Is the managed-non-cluster-machine case (PBS / "standardized Debian machine") a `host` sub-type, or its own `kind` value?** (2026-09-11) Undecided.
5. **`kubernetes` as a `kind`** — blocked on the parked one-module-vs-a-grouping-of-modules question. Not designable until that's resolved.
6. **The OCI/container candidate** — anticipated ("come very soon"), not yet designed; needs to resolve how it composes with `vm`/`lxc`/`host` rather than replacing any of them (see the table above).
7. **Does OS become part of the classification for bare-metal hosts** (bare-metal-Debian vs. bare-metal-NixOS vs. bare-metal-Windows)? Raised 2026-09-11, unresolved.
8. **A "degree of management" axis** (aware-of → manage-network → manage-firmware) was raised as a candidate enumeration distinct from both ADR-022a D6 and this ADR's `kind` (2026-09-11) — not designed here; a future open question for this ADR or a successor, not assigned yet.
9. **Abstraction vs. routing.** Does `kind` exist so a Manager can ask every device the *same* questions (full abstraction), or so it knows *which* controller-specific questions to ask (routing)? Raised 2026-09-11 (Erik), agreed as "the direction we should take" (LR) without a pluggable design. Affects how far `kind`'s enumeration needs to grow versus how much a Controller can hide.

*Moved to [ADR-022a](<ADR-022a - Administrative Domain.md>) in v0.3, as they were about D6's values, not `kind`:* where the `no-site`/`other-site`/`unknown` inventory lives, and how `unknown` is discovered.

### Parking lot — explicitly out of scope here

The `node` field's replacement by a general `depends-on` relationship (a module depends on another module that happens to be a Host, rather than naming a node) — and the fuller recursive module model this implies (hosts and the cluster itself as modules other modules depend on) — was discussed and explicitly deferred as a **3.0 change** (2026-09-11 sync). Today's `node` field semantics, as described in [ADR-022c](<ADR-022c - Node and Host.md>), are unaffected by this ADR. This is recorded here only as a forward pointer, not a decision; it may eventually motivate a change to `cluster`'s module boundary above, but that is future work.

## Acceptance

- [ ] `kind` values decided as `vm` / `lxc` / `host` / `cluster`; `guest` retired in favor of the `vm`/`lxc` split; `external-host` retired across all seven files
- [ ] Manager→Controller dispatch-by-`kind` rationale documented (Context §2), citing ADR-007f, with today's as-built gap noted (not yet implemented in `module-manager`)
- [ ] Proposed `kind` candidates (`hardware-module`, the managed-non-cluster-machine value, `kubernetes`, the OCI/container value) recorded as open, not decided
- [ ] `realized` defined as a state, replacing `shim` in ADR-012; the `shim`-as-`kind` rejection reconfirmed
- [ ] ADR-012 Appendix A replaced by a pointer to this ADR and ADR-022a D6/D7 jointly
- [ ] This document contains no independent definition of ADR-022a's D6 values — only uses them
