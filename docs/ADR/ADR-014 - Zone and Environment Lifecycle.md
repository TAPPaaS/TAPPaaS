# ADR-014 — Zone ↔ Environment Lifecycle & Operations

| | |
|---|---|
| **Status** | **Accepted** — implemented (see [ADR-014-implementation.md](../design/ADR-014-implementation.md); branch `feat/adr-014-zone-lifecycle`, packages P0–P8) |
| **Version** | 1.0 |
| **Date** | 2026-08-23 (v0.3: 2026-08-06) |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Refines** | [ADR-007c Environments](<ADR-007c - Environments.md>) (env↔zone binding), [ADR-007d Site](<ADR-007d - Site.md>) (`defaultEnvironment`, client-zone naming), [ADR-007f Realization](<ADR-007f - Realization.md>) (managers); ADR-001/002 (VLAN/zone model — the tier dimension) |
| **Related** | **#258** (origin of the `tier_model` prose in `zones.json` — a documentation/isolation-invariant issue, never an ADR; this ADR is its first design record); #424 (client/IoT zones ↔ environments undefined); #425 (keep client-zone names — closed); #426 (decouple site.name — closed); ADR-002 (dynamic VLAN); ADR-008 (network infrastructure); **owner:** `network-manager` (zones), `environment-manager` (environments) |
| **Changelog** | **v1.0 — ACCEPTED, reconciled with the implementation.** Three drafting decisions were settled by the operator: **`home` is KEPT** (the `home → private` rename is struck, with it the re-domaining and the generic rename-map machinery — F1); **D6 enforcement is phased** — I1–I4 ship warn-only and no gate is wired to `--strict` in this work (F2); **retired zones are auto-removed when unoccupied** by a new `retire` verb (F3). Four things the draft got wrong or left implicit were corrected while building: **D2's derivation is LOCAL, not symmetric** (the symmetric form invented firewall rules — see D2); **D1 keys on the zone's PRESENCE**, since a missing zone has no type to inspect; **D7 profiles need `grants`** to express the one edge a zone set cannot; and **`wan` belongs in `core`** (the draft omitted it). Adds **D8** (authored vs. effective documents) — the derivation has to be rendered, not written back, or the 3-way merge pins it. The D2 open question (where the back-fill runs) is resolved: inside `merge`. v0.3 — **recast `tier` as a strict trust lattice** (D5): `access-to` flows downward only (R1: `tier(A) ≤ tier(B)`), all upward reach is a `pinhole`; **DMZ drops out of the service class** to Tier 4 (internet-exposed) and **service sits above trusted clients** (client→service becomes a pinhole, #258-aligned); **isolation becomes an orthogonal `isolated` flag** (R2). D6 checks reduce to R1 + R2 + egress + archetype-conformance. Header now cites **#258** as the tier model's provenance. v0.2 — add the **zone tier model as first-class state** (D5: `tier` authored field + archetypes), **tier-based security invariants** in zones-check (D6, promoting the `_README` PR checklist to machine gates), and the **fresh-install default zone set + template cleanup** (D7). D3's IoT `--class` is subsumed by the D5 archetypes. v0.1 — initial draft: env↔service-zone binding (default / override / auto-create); symbolic `serves` link for client & IoT zones (rename-safe, fixes #424); guided IoT creation; filtered zone listing + confirmation that enable/disable already exist. |

## Context

ADR-007c fixed the **conceptual** model: an Environment binds to **exactly one** service zone
(`network.zone`, singular), defaulting to the environment's own name; `mgmt` is the foundation
environment; client and IoT segments are plain zones in `zones.json`, **not** part of an Environment.
ADR-007d made the **default** environment/zone name a first-class `site.defaultEnvironment` field,
decoupled from the neutral site code (#426), and settled that client zones keep site-local role names
(`home`/`guest`, #425).

What ADR-007 did **not** settle is the **operational lifecycle** — how an operator actually creates,
links, and toggles these things during setup and day-2 without hand-editing JSON. Three concrete gaps
remain (verified against the current managers):

1. **Env ↔ service zone is not a single step.** `environment add` writes `network.zone` but never
   creates the zone; `environment reconcile` only *warns* when the zone is absent
   (`environment-manager/src/reconcile.ts`). The service zone must be authored separately with
   `network-manager add` **before** the environment — an undocumented ordering trap.

2. **Client & IoT zones have no link to environments (#424).** A client zone (`home`, `work`) reaches
   its services through a hardcoded `access-to: ["srvHome", …]`; an IoT zone is reached through a
   hardcoded `pinhole-allowed-from`. Those names are the *pre-rename* template names — after
   `network-manager init` renames `srv → <defaultEnvironment>`, the references are stale, and the only
   fix today is editing `zones.json` by hand. There is no command to say "this client zone belongs to
   *that* environment."

3. **Inactive-zone management is undiscoverable, not absent.** `network-manager enable|disable|manual`
   already flips a zone's `state`, and `list` prints a state column — but there is no filtered view
   ("show me the inactive/client/IoT zones"), so operators don't know the capability exists.

Two further **model** gaps surfaced while designing the above (v0.2), and are addressed by D5–D7:

4. **The security tier is prose, not state.** `zones.json._README.tier_model` defines a six-tier
   trust/exposure model (control → service → trusted-client → IoT-controlled → IoT-isolated →
   untrusted-client), but **no field carries it** and no code reads it. The isolation invariant and the
   `pr_review_checklist` are enforced by human review only — a new zone gets the right tier defaults
   only if the operator copies the right template block by hand.

5. **The shipped template has drifted.** It carries test-only zones (`test`, `testAllowA/B`,
   `testPinhole`, typeId 8) and five near-duplicate service zones (`srvHome/srvWork/srvCust/srvDev/
   srvTest`) whose hardcoded `access-to` is precisely the stale-reference surface of gap 2/#424. There
   is no stated "right default set" for a fresh install.

This ADR defines the operational contract that closes those gaps. It changes **no** ADR-007 *conceptual*
invariant (one environment still binds one service zone; client/IoT zones remain plain zones; the
isolation invariant is untouched); it **adds** an orthogonal security dimension (`tier`) and makes the
existing invariants machine-checkable.

## Decision

### D1 — Env ↔ service zone: default, override, and auto-create

The binding rule is unchanged (007c): an Environment names **one** service zone in `network.zone`,
defaulting to the environment name. This ADR adds the **materialization** rule so it is one operator step:

- **Default (shared name).** `environment add <env>` with no `--zone` targets a service zone named
  `<env>`. If that zone already exists it is used as-is; the environment and its zone share a name and
  the operator does nothing else.
- **Override (different zone).** `environment add <env> --zone <Z>` binds the environment to an
  existing service zone `<Z>` whose name differs from the environment (e.g. a second environment that
  reuses a shared service segment, or the `srvCust`-style patterns in the 007c worked reference).
- **Auto-create (combine the two steps).** The target service zone **must exist before the environment
  is reconciled**. Two supported ways to satisfy that ordering:
  - *Pre-create:* `network-manager add <Z> --archetype service` first, then `environment add`.
  - *Combine:* `environment add <env> [--zone <Z>] --create-zone` — environment-manager shells out to
    `network-manager add <Z> --archetype service` (idempotent) **before** writing the environment file, so a
    single command yields a working environment + service zone.
- **Reconcile materializes, no longer just warns.** `environment reconcile <env>` is upgraded so an
  environment naming a zone that never existed can actually converge.

  > **v1.0 correction — the rule keys on PRESENCE, not on type.** The draft said "create a missing
  > *Service* zone; a missing *non-Service* zone is a hard error", which is not implementable: a zone
  > that is missing has no `type` to inspect. What the parenthetical actually describes ("the operator
  > pointed an environment at a client/IoT zone") is a zone that **exists** with the wrong type.

  | `zones.json` | outcome |
  |---|---|
  | zone **absent** | **create** it as a Service zone — that is the intent |
  | zone present, `type: Service` | nothing to do |
  | zone present, **any other type** | **hard error**, refused in preview *and* apply |

  The third case must not be papered over by minting a second zone underneath the operator; the error
  names both repairs (`environment modify <env> --zone <serviceZone>`, or `network-manager bind <zone>
  --environment <env>` if the client zone was meant to *consume* the environment). Plans therefore carry
  `errors[]` distinct from `warnings[]` — reconcile proceeds through warnings and refuses errors.
  **Ordering is load-bearing:** the zone is authored *before* the network pass, or the reconcile would
  converge a `zones.json` that does not yet contain it.

> **Ownership boundary (unchanged).** `network-manager` remains the sole writer of `zones.json`;
> `environment-manager` never edits zones directly — it *requests* zone creation/checks by shelling to
> `network-manager` (the existing `clients.ts` seam). Auto-create is a call across that seam, not a new
> writer. It uses `--archetype service`, so a zone created this way lands tier-correct rather than with
> bare defaults.

### D2 — Client & IoT zones link to an environment by a symbolic `serves` field (fixes #424)

The root cause of #424 is that a client/IoT zone's reachability is expressed as **literal service-zone
names** that do not survive the install-time rename. Replace the literal with a **symbolic reference to
the environment**, resolved on every reconcile — the same rename-safe pattern the zones 3-way merge
already relies on.

- **New optional zone field `serves`** (client and IoT zones only): the **environment name** whose
  service zone this zone consumes. It is authored once and is stable across renames.

  ```jsonc
  "home": {
    "type": "Client", "state": "Active", "vlantag": 310, "ip": "10.3.10.0/24",
    "tier": 2,
    "serves": "warmelo",              // ← the environment, not "srvHome"
    "access-to": ["internet"],        // ← the service-zone entry is now DERIVED, not hand-listed
    "pinhole-allowed-from": []
  }
  ```

- **Resolution.** On `network-manager reconcile`, `serves: "<env>"` looks up the environment's
  `network.zone` (in `config/environments/<env>.json`) and contributes **one** edge, on top of the
  literal `access-to`/`pinhole-allowed-from` baseline in the file. Because the edge is derived from the
  environment's *current* zone, renaming `srv → <env>` no longer strands the reference — #424's core
  defect.

  > **v1.0 correction — the derivation is LOCAL, and its direction depends on the zone's role.**
  > The draft derived a **symmetric pair** ("…and add this zone to that service zone's
  > `pinhole-allowed-from`"). Implemented literally and run against a production config, that
  > **invented edges the authored document never had** — including `<env>.access-to += iot`, a brand-new
  > zone-wide pass rule. A migration that is supposed to change nothing cannot mint firewall rules.
  >
  > **The rule: `serves` only ever modifies the zone that DECLARES it.**
  >
  > | declaring zone | derived edge |
  > |---|---|
  > | Client / Guest | `Z.access-to += S` — the client consumes the service |
  > | IoT | `Z.pinhole-allowed-from += S` — the environment's modules drive the devices |

  Each reproduces exactly the literal the template used to wire by hand, so the migration back-fill is
  **authored-only**: the rendered graph is byte-identical before and after. Two edges are deliberately
  *not* derived — `S.pinhole-allowed-from += Z` (unnecessary while the client reaches `S` zone-wide, and
  precisely what the deferred client→service pinhole conversion adds), and `S.access-to += Z` for a
  non-isolated IoT zone (that edge is **authored on the service zone** and is already rename-safe, since
  what `init` renames is the service zone's own *key* while the IoT names it lists are stable).
  A welcome consequence: **R2 becomes structural rather than conditional** — the IoT branch touches only
  `pinhole-allowed-from`, so an isolated zone cannot gain an inbound `access-to` by any code path.
- **New verb to author the link without editing JSON:**
  `network-manager bind <zone> --environment <env>` sets `serves` on a client/IoT zone (and
  `--unbind` clears it). This is the "make it easy to create the relationship" the operator asked for.
- **Isolation is unchanged, and now structurally so.** `serves` on an isolated IoT zone (`iotCams`,
  `iotUntrust`) never adds that zone to anyone's `access-to`; it only records which environment's
  modules may open **per-module pinholes** into it. Under the v1.0 locality rule this needs no special
  case at all — the IoT branch writes `pinhole-allowed-from` and nothing else.

> **Migration for existing installs.** `network-manager merge` (the rename-aware 3-way step) gains a
> one-time pass that, for each client/IoT zone whose literal reference names a zone that is some
> environment's `network.zone`, sets `serves` and drops the now-derived literal. Idempotent; a converged
> install re-runs it as a no-op. **This resolves the D2 open question:** the back-fill runs *inside*
> `merge`, because merge already holds the rename context and runs on every `update-tappaas`.
> A literal naming a **non-environment** zone (a retired `srvHome`, say) is deliberately left alone —
> that is stale, not a link, and pruning it is `retire`'s job (D7).
>
> Verified on a production config: the back-fill linked two zones, and the **`access-to` graph — the
> only field that compiles to pass rules — came out byte-identical**. The `pinhole-allowed-from` lists
> do change, and that change *is* #424 landing: three IoT zones named a renamed-away ghost, so a module
> in the live service zone literally could not declare a pinhole into them.

### D3 — Guided IoT (and client) zone creation — no JSON editing

Creating an IoT zone today means copying a template block and getting the tier/egress/isolation right by
hand. Replace with a guided preset that encodes the `zones.json._README.iot_classification` decision aid.
**This is realised by the D5 archetypes** — the four IoT classes are the `iot-*` archetypes, and the same
mechanism covers client zones:

- `network-manager add <name> --archetype iot-local|iot-cloud|iot-cams|iot-untrust` (was `--type IoT
  --class …`) materializes a correctly-tiered zone:
  - `iot-local` → Tier-3, egress none, reachable from its `serves` environment;
  - `iot-cloud` → Tier-3, egress internet;
  - `iot-cams` → Tier-4 isolated, egress none, pinhole-only;
  - `iot-untrust` → Tier-4 isolated, egress internet-only, pinhole-only.
- `network-manager add <name> --archetype trusted-client [--serves <env>]` does the same for a new client
  segment, wiring `access-to: ["internet"]` + the `serves` edge, so a second household/office segment is
  one command.
- Both reuse the existing `--vlan`/auto-allocation machinery; this is a thin preset layer over `add`
  (see D5), not a new code path. `--type`/`--from-zone` remain as low-level escapes.

### D4 — Inactive/typed zone listing (enable/disable already exist)

**Finding:** enabling/disabling zones is **already implemented** —
`network-manager enable|disable|manual <name> [--force]` flips `state`
(Active / Inactive / Manual), then `network-manager reconcile --apply` converges the planes. The only
gap is **discoverability**. Add filtering to the existing `list`:

- `network-manager list [--state Active|Inactive|Manual|Mandatory] [--type Service|Client|IoT|…] [--tier N] [--json]`
  — filter the existing `name / state / vlan` output. `list --state Inactive` answers "which zones are
  defined-but-off, ready to enable"; `list --type Client` answers "which client zones exist and (via
  `serves`) which environment each belongs to" (add `tier` + `serves` columns when `--type Client|IoT`).
- No new state model, no schema change for D4 — purely a read-side filter and columns.

### D5 — The zone tier model as a strict trust lattice (`tier` + archetypes)

> **v0.2→revision.** D5 originally reused the `_README` tier *labels* as-is. That ordering was
> descriptive, not a lattice — it could not be machine-checked because its own edges violated it
> (`home` `access-to` `srvHome` runs from the "less trusted" client *up* into the "more trusted"
> service). This revision makes `tier` a **strict total order with a single directional rule**, so the
> D6 checks reduce to one comparison.

**The organizing rule.** `access-to` is the **coarse, baseline, downward** trust flow. An `access-to`
edge may run only from a **more-trusted** zone to an **equal-or-less-trusted** one:

> **R1 (monotonic access-to):** for every edge `A access-to B`, `tier(A) ≤ tier(B)`
> (tier 0 = most trusted / most privileged). Never upward.

Everything that needs to go **upward** (a client reaching its service, the internet reaching a DMZ
host) is **not** an `access-to` edge — it is a narrow, **per-module `pinhole`** (specific source-IP →
specific port), declared in the target's `pinhole-allowed-from` + the module's install rule. `access-to`
is zone-wide and directional; `pinhole` is individual and is the *only* way trust flows up.

Two axes, still separate (the D5 thesis is unchanged — only the ranking is fixed):

| Axis | Field | Answers | Drives |
|---|---|---|---|
| **Category** | `type` / `typeId` | *what kind* of zone | VLAN band, IP subnet, interface |
| **Trust rank** | **`tier`** (new) | *how trusted* (outbound privilege) | R1 + the D6 machine checks |
| **Exposure** | **`isolated`** (new flag) | *inbound-quarantined?* | R2 (below) |

`tier` and `type` are genuinely orthogonal — after the reorder a `Guest` client and an `iotCloud` IoT
zone share **Tier 3** (both reach only the internet, neither is reachable inward), which is exactly why
tier cannot be derived from `type`.

**The lattice (0 = top / most trusted, 6 = bottom):**

| Tier | Name | `access-to` (downward, baseline) | Reached from above via | Members |
|---|---|---|---|---|
| **0** | Control plane | **all zones** (control) | *nothing — no inbound at all* | `mgmt` |
| **1** | Service backend | ↓ internet, dmz, IoT-controlled | **pinhole** from clients + reverse-proxy | `srv` → `<env>` |
| **2** | Trusted client | ↓ internet, own IoT-controlled | direct (its devices) | `home`, `work` |
| **3** | Untrusted edge | ↓ internet only | — | `guest`, `iotCloud`, `iotUntrust` |
| **4** | DMZ (exposed) | ↓ internet only | **pinhole** from internet | `dmz` |
| **5** | **Internet** (external) | — (the boundary) | — | *(pseudo-zone / token)* |
| **6** | Isolated / no-egress | *(none)* | **pinhole** only (if `isolated`) | `iotCams`, `iotLocal` |

Two deliberate moves from the old labels:
- **DMZ leaves the service class.** It is no longer a peer of the service backends (old Tier 1); it drops
  to **Tier 4**, just above the internet — a DMZ host is internet-exposed and assume-breach, so it must
  be *less* trusted than an internal backend, not equal to it. `service → dmz` (1 → 4) stays a legal
  downward `access-to`; `dmz` can reach nothing internal.
- **Service sits *above* trusted clients** (Tier 1 vs Tier 2). A client reaching its service is now an
  **upward pinhole** (`home` → `<env>`:port), not a zone-wide `access-to` — tighter, and it matches the
  #258 fix that removed the broad `home → srvWork` edge. The backend is the crown jewel; clients get
  specific ports, not the subnet.

**Isolation is an orthogonal inbound flag, not a tier.** `isolated: true` (privacy/quarantine) means
"accepts **no** zone-wide `access-to`; inbound only via per-module pinhole." It applies to `iotCams`
(no-egress cameras, GDPR Art. 25) **and** `iotUntrust` (internet-egress but quarantined) — which live at
*different* tiers (6 and 3). So isolation could never be a single tier row; it is a boolean:

> **R2 (isolation floor):** an `isolated` zone must not appear in **any** zone's `access-to` (the `mgmt`
> full-visibility exception aside) — this is the ADR-007 isolation invariant, now a field, not prose.

`iotLocal` shares Tier 6 with `iotCams` (both no-egress) but is **not** `isolated`: its serving zone
reaches it zone-wide (Home Assistant → local IoT), which R2 forbids for `iotCams`.

- **Archetypes** name a bundle of these defaults, so `add --archetype <A>` stamps `type`, `typeId`,
  `tier`, `isolated`, the `access-to` seed, then auto-allocates `subId`/`vlantag`/`ip`. The shipped
  template zones become concrete reference instances:

  | Archetype | type | tier | isolated | `access-to` seed | reference zone |
  |---|---|---|---|---|---|
  | `control` | Management | 0 | no | all | `mgmt` |
  | `service` | Service | 1 | no | internet, dmz | `srv` → `<env>` |
  | `trusted-client` | Client | 2 | no | internet (svc via **pinhole**) | `home` |
  | `guest` | Guest | 3 | no | internet | `guest` |
  | `iot-cloud` | IoT | 3 | no | internet | `iotCloud` |
  | `iot-untrust` | IoT | 3 | **yes** | internet | `iotUntrust` |
  | `dmz` | DMZ | 4 | no | internet (inbound via **pinhole**) | `dmz` |
  | `iot-local` | IoT | 6 | no | *(none)* | `iotLocal` |
  | `iot-cams` | IoT | 6 | **yes** | *(none)* | `iotCams` |

  The archetype catalog is a small table shipped with `network-manager` (extending
  `schemas/zones-fields.json`), the single source of the tier/type/isolated/egress defaults D6 checks
  against.

> **Two judgment calls in this reorder** (flag for confirmation): (a) **service above clients**, making
> `client → service` a pinhole rather than a broad `access-to` — tighter and #258-aligned, but it moves
> every client→service reach to per-module rules; (b) **`guest` and the internet-egress IoT zones share
> Tier 3** — correct for the `access-to` rank (identical outbound, no inbound), and `type` still
> separates them, but it breaks the old "one tier = one kind" reading. Both are recommended as written.

### D6 — Tier-based security invariants (promote the PR checklist to gates)

With the strict lattice (D5), `network-manager validate` (zones-check) gains the invariants that are
**human-only review today** (`zones.json._README.pr_review_checklist`). The D5 reorder collapses them to
two core rules + two guards.

> **v1.0 — enforcement is PHASED (decision F2/R3).** All four ship **warn-only**. `--strict` keeps its
> existing meaning (promote every warning to an error) as an opt-in flag an operator may run by hand,
> but **nothing** in CI, `pre-update.sh` or any install path is wired to it in this work. Turning it
> into a real pre-deploy gate is a later step, once the fleet-wide warning set is understood. The
> governing invariant of the implementation was that **no check introduced here can fail an install or
> an update** — and, more strongly, that not one firewall rule changes.
>
> On a converged install the expected residue is **exactly one I1 warning**: the client→service edge
> (`home` tier 2 → `<env>` tier 1), which is the deliberate F2 deferral. Converting it to per-module
> pinholes is tracked separately.

- **I1 = R1 — Monotonic `access-to`** *(the core check)*: for every edge `A access-to B`,
  `tier(A) ≤ tier(B)`. One comparison replaces the old hand-wavy "trust-directed reach" prose. Any upward
  edge is a violation — the author must use a `pinhole` instead. `internet` counts as Tier 5.
- **I2 = R2 — Isolation floor** *(currently unenforced in code — highest value)*: an `isolated` zone
  (`iotCams`, `iotUntrust`) must not appear in any zone's `access-to`, `mgmt`'s full-visibility exception
  aside. This is the ADR-007 isolation invariant, now checkable from a field.
- **I3 — Egress boundary:** a Tier-6 (no-egress) zone must not list `internet`; a Tier ≥3 zone's
  `access-to` beyond `internet` must be justified (it can only be a legal downward edge, so this mostly
  falls out of I1).
- **I4 — Archetype conformance:** every zone's `(type, tier, isolated)` triple must match a defined
  archetype (D5 catalog) — catches a zone configured against its declared intent (e.g. a `Service` typed
  at Tier 3, or an `iotCams` that lost its `isolated` flag). Replaces the old per-type tier table.

These reuse the existing `zonescheck.ts` reporter (`note`/`warn`/`error` + `--strict`); no new tool. The
`pinhole-allowed-from` side is **not** tier-gated (upward is what pinholes are *for*) — it is validated
per-module against the target zone's `pinhole-allowed-from` list, as today.

**Exemptions (v1.0, all data-driven from `schemas/zones-fields.json`):**

- **`mgmt`** is exempt from I1 and I2 — the control plane reaches every zone, including the isolated
  ones, by design. Without this every install fails its own check on day one.
- **`Overlay` and `WAN` zones are skipped by I1/I3/I4** (`tier_exempt_types`). Overlays are non-VLAN
  WireGuard segments with no meaningful trust rank — and `admin` legitimately carries
  `access-to: ["mgmt"]`, an upward edge into tier 0. `wan` is the switch-internal ISP hand-off with no
  interface, DHCP or rules. Neither carries a `tier`.
- **A zone with no authored `tier`** is reported once as an aggregate note and skipped, so an
  un-back-filled `zones.json` produces no noise.

**I2 also catches the `all` wildcard.** `access-to: ["all"]` compiles to a destination-any pass rule, so
it reaches every isolated zone *without naming one* — an R2 bypass the rule as drafted could not see.
Only `mgmt` may hold it. This makes `control` a **singleton archetype**: a second control-plane zone
trips I2 by design.

### D7 — Fresh-install default set via composable `init` profiles

Replace today's single flat template (~19 zones + 4 test zones) with **`network-manager init <profile>`**
— additive, idempotent zone bundles the operator applies in stages:

- **`network-manager init core --name <N>`** — the minimal coherent install (the `srv → <N>` rename runs
  here). This is the only profile a headless/server TAPPaaS needs. Profiles are **order-independent**
  and **idempotent** (re-applying is a byte-level no-op), and **existing zones always win**, so an init
  re-run can never rebuild a live file from template defaults (#427).
- **`network-manager init iot`** — adds the IoT segment set on top of `core`. Opt-in: a site with no
  smart-home/IoT devices never gets these zones.

Profiles are re-runnable and compose (`init core` then later `init iot`); each only ever adds/activates
its zones, never touches another profile's. Room for more profiles later (e.g. `init dev` for
`srvDev`/`srvTest`), but `core` + `iot` cover the SOHO baseline. A profile naming a zone the template
does not define is a **broken template** and fails loudly — this replaced the pre-D7 "template must
contain srv/home/guest" check with one that tracks what the profiles actually need.

| Profile | State | Zones (tier per the D5 lattice) |
|---|---|---|
| **`core`** | Active / Manual | `mgmt` (T0, Manual) · **`wan` (Manual)** · `netbird`/`edge`/`admin` overlays (Manual) · `<defaultEnvironment>` service zone (T1, from the `srv` rename) · **`home`** (T2, `serves <env>`) · `guest` (T3) · `dmz` (T4, **Mandatory**) |
| **`iot`** | Active | `iotCloud` (T3, `serves`) · `iotLocal` (T6, `serves`) · `iotCams` (T6, `isolated`, `serves`) · `iotUntrust` (T3, `isolated`) |

> **v1.0 — `wan` belongs in `core`.** The draft's table omitted it entirely. It is the switch-internal
> ISP hand-off that keeps the HA firewall's uplink across node failover; no install works without it.
> It ships Manual alongside the three overlays.

> **v1.0 — profiles need `grants`.** "A profile only ever adds/activates its zones" is *almost* right,
> but an IoT install must also give the service and client zones **reach** to the devices — an edge the
> zone definitions alone cannot express, because the targets belong to another profile. So a profile may
> declare `grants: { <zone>: [refs] }`, applied additively, with the same rename map, and **skipped
> entirely when the target zone is absent** so a grant can never author a dangling reference. `iot`
> grants `mgmt` visibility of all four, `<env>` reach to `iotLocal`/`iotCloud`, and `home` reach to
> `iotCloud`/`iotLocal` — exactly what the retired `srvHome` used to carry.

> **v1.0 — the merge SOURCE stays the full renamed template**, not the installed profile subset. A
> profile-scoped source would mean a field fix to an uninstalled zone could never be adopted later. So
> `zones.rename.json` == `zones.json.orig` == the whole renamed template, while the live `zones.json`
> is the installed subset: `current ⊆ rename == orig` (the draft's "current == orig == rename on a
> fresh install" no longer holds, by design).

Three deliberate changes from the earlier draft:

- **`dmz` moves into `core` as Mandatory** — it is already Mandatory in the template (the reverse-proxy /
  controlled-exposure path assumes it exists), so it belongs in the always-on `core`, not the opt-in `iot`.
- **`iotUntrust` joins the `iot` profile Active** (was Inactive/"Available"). Opting into IoT means opting
  into the whole segment set, quarantine zone included — it is `isolated` anyway, so shipping it hot costs
  nothing and saves a step.
- **No "Available/Inactive" pre-shipped zones.** A second trusted client, extra service zones, a `work`
  segment — all are **generated on demand** with `add --archetype …` (D5), not shipped dormant. Dormant
  zones were pure surface area (and the `srv*` ones were the #424 stale-`access-to` surface).

**~~`home` → `private`~~ — STRUCK (v1.0, decision F1). The trusted-client reference zone stays `home`.**

The draft proposed renaming it to `private` to pair with `guest`. The operator settled this the other
way, and the reasoning that killed it is #425's own: the zone key drives the client DNS domain
(`<zone>.internal`), so on an existing install the rename re-domains **every client device** and
de-converges `zones-merge`. That is a large, irreversible blast radius bought for a cosmetic pairing.

Two things fall away with it, which is most of why it was struck:

- **No generic rename-map machinery.** The draft assumed a "recorded rename map… the same mechanism as
  `srv → <env>`". No such mechanism existed — that map is a hardcoded literal in `zonesinit.ts`.
  Building a general one was a hidden cost of the rename, and `srv → <N>` remains the only rename.
- **ADR-007d needs no edit.** Its "client zones keep their template names" line stands verbatim.

Two **cleanups** to the shipped template:

- **Drop the test zones** (`test`, `testAllowA/B`, `testPinhole`) — a test probe has no business on a
  production install. They now live in `network/test-fixtures/test-zones.json`, next to the deep test
  that activates them; that test merges them into the deployed `zones.json`, runs, and removes the keys
  again.
- **Collapse `srvHome/srvWork/srvCust/srvDev/srvTest` → ship only `srv`** (renamed to
  `<defaultEnvironment>`). Additional service zones now come from `environment add --create-zone` (D1) or
  `add --archetype service` (D5) — removing the five stale-`access-to` blocks at the root of #424.
  `work` is dropped from the template too (a second client segment is generated on demand), but is
  **never removed from an existing install**.

### Retiring what a release stopped shipping — `network-manager retire` (v1.0, decision F3)

Dropping a zone from the template does **not** remove it from an existing install: the 3-way merge's
zone rule is "in current, absent in source → KEEP + warn", which is correct (it is what stops a release
silently deleting an operator's zone) but means the cleanup above would leave every retired zone as a
permanent orphan, still carrying the stale references #424 is about. Removal is therefore explicit:

```
network-manager retire [--apply]     # dry-run by default
```

- It considers an **explicit list** — `srvHome`, `srvWork`, `srvCust`, `srvDev`, `srvTest`, `iot`,
  `test`, `testAllowA`, `testAllowB`, `testPinhole` — **never "everything Inactive"**.
- A zone is removed only when it is **both** not `Active`/`Mandatory`/`Manual` (it provisions nothing
  today) **and** not named by any installed module's `zone`/`zone0`. Anything else is kept and reported
  with the reason: retiring a live zone would tear down its interface, and retiring an occupied one
  would orphan a running service.
- References to a retired zone are stripped from every other zone.
- **`srv` is never retired** (it is the rename source) and neither is **`work`** — a legitimate client
  zone that is merely switched off, and `enable work` must keep working. This is exactly why the set is
  a named list rather than a state query.

> **Infra overlays — what they are, and why they need rationalizing.** Three non-VLAN WireGuard overlays
> ship in every install (`state: Manual`, `vlantag: 0`, so `zone-manager` creates no interface/DHCP —
> they exist only so consumers like `network:proxy` can resolve their peer CIDRs). All three serve
> *remote reach* and their roles **overlap**:
> - **`netbird`** — NetBird WireGuard **mesh** (#367): many-peer admin VPN; peers carry their own CGNAT
>   CIDR (`100.64.0.0/10`); admitted through Caddy for admin tunnel access.
> - **`admin`** — ADR-010 **admin-vpn**: the single operator's plain WireGuard session terminating on
>   OPNsense (`10.255.1.0/24`, `access-to: [mgmt]`); no control plane, one-peer case.
> - **`edge`** — ADR-010 **satellite infra tunnel**: the OPNsense↔satellite `/31` link carrying public
>   ingress + off-site backup + relayed admin-vpn.
>
> That is **three mechanisms for adjacent needs** (mesh admin VPN vs single-operator admin VPN vs
> satellite relay). This ADR ships all three but does **not** settle the redundancy — **rationalizing the
> remote-access overlay model is a follow-up decision** (cross-ref ADR-010, #367): pick the canonical
> mechanism(s) and retire the rest. Out of scope here, flagged because `init` materializes all three.

### D8 — Authored vs. effective documents (added in v1.0)

D2's derivation has to land *somewhere*, and the draft did not say where. Writing the derived edges back
into `zones.json` is **wrong**: the 3-way merge cannot tell a derived value from an operator edit, so it
would pin them — and clearing a `serves` link would then strand its edges forever.

> **`zones.json` is AUTHORED state. `zones.effective.json` is the RENDERED graph.**

- `reconcile` (and every authored write: zone add/delete/state, `bind`, `merge`) re-renders
  `config/zones.effective.json` = the authored document with every `serves` link resolved.
- The consumers read the **effective** document: `zone-manager` (the OPNsense plane, via the reconcile
  call), `rules_manager.py` (per-module pinhole/egress validation, via its search order), and the Caddy
  access lists. `distribute` keeps pushing the authored file — nodes need only `vlantag`/`ip`.
- It is generated, never hand-edited, and every consumer falls back to the authored file on a system
  that predates ADR-014.

**Error policy is deliberately asymmetric.** An unresolvable `serves` link is *non-fatal* on a zone add
(a missing environment file must not block zone authoring — and on the install path `init` legitimately
runs before the environments exist) but **fatal** to `reconcile` and an **error** in `validate`. Those
are the verbs that converge and audit.

**`validate` gained `--effective`.** Moving the client→service edge out of the authored file means an
authored-scope check can no longer see it — a fresh install reported a completely clean graph while the
rendered one carried the known upward edge. Reporting clean would have been misleading, so `validate`
can audit the rendered graph, and the authored-scope run emits a scope note naming how many links it
could not judge.

## Command surface (summary)

| Command | Status | Purpose |
|---|---|---|
| `environment add <env> [--zone Z] [--create-zone]` | **extend** (`--create-zone` new) | create env; optionally auto-author its service zone in one step (D1) |
| `environment reconcile <env>` | **change** | materialize an **absent** zone as Service (was warn-only); hard-error when the named zone **exists** with a non-Service type (D1) |
| `network-manager bind <zone> --environment <env>` / `--unbind` | **new** | set/clear a client/IoT zone's `serves` link (D2) |
| `network-manager add <name> --archetype <A>` | **extend** | tier-correct zone creation from an archetype (D5); subsumes D3's `--class` |
| `network-manager reconcile` | **change** | render `zones.effective.json` from `serves` each run and hand it to the planes (D2/D8) |
| `network-manager validate [--effective]` | **extend** | tier invariants I1–I4 (R1 monotonic + R2 isolation), **warn-only** (F2); `--effective` audits the rendered graph (D8); `--strict` is an opt-in flag wired to no gate |
| `network-manager init <core\|iot> [--name N]` | **change** | composable profile bundles — additive, idempotent, order-independent (D7); drops the test zones + collapses `srv*` |
| `network-manager retire [--apply]` | **new** | remove zones a release stopped shipping, under the liveness + occupancy guard (D7/F3) |
| `network-manager merge` | **extend** | one-time `serves` back-fill for renamed service references (D2 migration) |
| `network-manager list [--state …] [--type …] [--tier N]` | **extend** | filtered/grouped zone view; `tier`+`serves` columns for client/IoT (D4) |
| `network-manager enable\|disable\|manual <name>` | **exists** | toggle inactive zones — already present, now documented as the answer (D4) |

## Schema changes

- **`zones.json` — new optional `serves` field** on Client and IoT zones (string: an environment name).
  Absent `serves` = today's behaviour (literal `access-to` only). No change to Service/Management/Overlay.
- **`zones.json` — new `tier` field** (integer 0–6, the D5 lattice; absent for Overlay/non-VLAN zones).
  Authored, stamped by the archetype; R1/`access-to` is checked against it (D6). Tier 5 is reserved for
  the `internet` boundary token (not a real zone).
- **`zones.json` — new `isolated` boolean** (default `false`) — the inbound-quarantine flag enforced by
  R2. Orthogonal to `tier` (`iotCams` T6 and `iotUntrust` T3 are both `isolated`).
- **`schemas/zones-fields.json`** — add `tier`, `isolated` and `serves` to `fields`; add the
  **`tier_model`** lattice, the **`archetypes.catalog`** (the D5 table), the **`invariants`** I1–I4 with
  their exemptions and remedies, and **`tier_exempt_types`** (`Overlay`, `WAN`). Documented in
  `network-manager/ZONES.md`, which replaces the `_README.tier_model` prose (that block now points at the
  schema and states plainly that the ranking it used to describe was *different*, so nobody follows the
  old one from memory).
  > **v1.0 note.** `network-manager` carries an **operative copy** of the catalog in `src/archetypes.ts`:
  > the nix builder narrows the build source to `lib/ts` + the component, so `foundation/schemas/` is not
  > reachable at build time, and resolving it at *run* time would make `validate` depend on a deployed
  > file that may be missing or stale on exactly the systems it audits. A unit test pins the two together
  > field-for-field, so drift fails the build rather than shipping two disagreeing definitions.
- **`zones.json` — a new `_profiles` doc block** declaring the D7 bundles (`zones` + `grants`).
  Install-time metadata: read from the shipped template, deliberately never copied into a live
  `zones.json`.
- **A new generated file, `config/zones.effective.json`** (D8). Never hand-edited, never merged.
- **No environment schema change.** `network.zone` (singular) stays exactly as ADR-007c built it.
- **No site schema change.** `defaultEnvironment` (007d/#426) already names the default env/zone.

## Consequences

- **Positive.** One-step env+zone creation; client/IoT ↔ environment links survive renames (closes
  #424's mechanism); zones created from tier-correct archetypes, not copy-paste; the isolation invariant
  and PR checklist become **machine gates** (D6) instead of human review; a fresh install ships a lean,
  intentional default set. `zones.json` becomes editable through `network-manager` verbs end to end — no
  hand-editing for the common cases.
- **Negative / cost.** `reconcile` now reads `config/environments/*.json` to resolve `serves` (a new
  cross-manager read; environment-manager already reads zones, so the coupling is mutual but bounded).
  There is a **second file to reason about** (`zones.effective.json`, D8) and three consumers had to be
  pointed at it. `environment reconcile` materializing a missing zone is a behaviour change, mitigated by
  the wrong-type hard error and by `--check`/dry-run on both managers.
- **Neutral / measured.** Backwards compatible: a `zones.json` with no `serves`/`tier` and literal
  `access-to` keeps working — an untiered zone is a *note*, not a warning, so an un-back-filled file
  produces no noise. The D7 template cleanup affects only fresh installs; existing installs converge via
  `merge` + `retire`.
  > **What the migration actually costs, measured on a production config (24 zones → 14):** the
  > **`access-to` graph — the only field that compiles to pass rules — is byte-identical**. Not one
  > firewall rule changes. Three IoT zones' `pinhole-allowed-from` swap a renamed-away ghost for the live
  > service zone, which is #424 being fixed rather than a cost. Residue after migration: **one I1
  > warning**, the deliberately-deferred client→service edge.

## Resolved design choices

These were weighed during drafting and are settled (kept here as the rationale trail):

1. **Auto-create is opt-in.** `--create-zone` is an explicit flag on `environment add`; the zone is not
   created implicitly. Chosen over default-on so a typo'd `--zone` cannot silently mint a stray zone —
   the small extra step is worth the safety.
2. **`serves` is a single environment, named `serves`.** One environment per client/IoT zone, mirroring
   the singular `network.zone` (007c) and deliberately not reintroducing the multi-edge model 007c
   dropped. A zone that genuinely needs to reach two environments' service segments is modelled by
   literal `access-to` entries, not `serves`.
3. **This is a standalone ADR-014**, refining 007c/007d/007f operationally rather than expanding the
   007 family — no renumbering of 007a–f. The tier model + archetypes + default set (D5–D7) are folded
   in here rather than a separate ADR-015 — one coherent zone-management story reviewed once.
4. **`tier` is authored, not derived.** It records declared security intent and is cross-checked by
   archetype conformance (I4); a purely derived tier could not catch a zone configured against its intent.
5. **`init` is staged into composable profiles** (D7): `init core` (mgmt + wan + overlays + service + `home` + `guest` +
   `dmz`) is the minimal install; `init iot` adds the full IoT segment set (`iotCloud`/`iotLocal`/
   `iotCams`/`iotUntrust`, all Active). No dormant "Available" zones — a second client / extra service
   zone is generated on demand via `add --archetype`. The trusted-client reference zone stays **`home`**
   (v1.0/F1 — the `private` rename was struck; see D7).
6. **`tier` is a strict trust lattice with one directional rule** (D5/R1): `access-to` flows downward
   only (`tier(A) ≤ tier(B)`); all upward reach is a `pinhole`. This makes the D6 security check a single
   comparison. It forced two reorders vs. the old `_README` labels — **DMZ dropped out of the service
   class** to Tier 4 (internet-exposed, assume-breach), and **service backends sit above trusted
   clients** (client→service becomes an upward pinhole, #258-aligned).
7. **Isolation is an orthogonal `isolated` flag** (R2), not a tier — because `iotCams` (T6) and
   `iotUntrust` (T3) are both quarantined yet sit at different trust ranks.

> **~~Two forks flagged for confirmation~~ — both CONFIRMED as written (v1.0).** `client → service` is a
> pinhole in the model, and `guest` shares Tier 3 with the internet-egress IoT zones. The first is
> adopted with **phased enforcement** (F2): the model says pinhole, the shipped derivation still emits
> the zone-wide edge so no firewall rule changes, and I1 warns about it. Converting it is its own issue.

### Settled while implementing (v1.0)

8. **`home` is kept; the `private` rename is struck** (F1) — the client DNS re-domaining is not worth a
   cosmetic pairing, and it removes the need for generic rename-map machinery that did not exist.
9. **D6 enforcement is phased** (F2/R3) — warn-only, no gate wired to `--strict` in this work.
10. **Retirement is auto-delete-when-unoccupied** (F3), via an explicit named list, never a state query.
11. **`serves` derives a LOCAL edge only** — the symmetric form invented firewall rules (D2).
12. **D1 keys on the zone's presence**, not its type — a missing zone has no type to inspect.
13. **`zones.json` stays authored; the derivation is rendered** (D8) — writing it back would let the
    3-way merge pin it.
14. **Profiles may `grants`** access-to entries onto zones from another profile (D7) — the one edge a
    zone set cannot express on its own.
15. **`tier` keeps its name** despite colliding with the App-lifecycle `tier` (`foundation`/`app`) in
    `GLOSSARY.md`. The two never appear on the same object and context disambiguates them; renaming the
    App one is optional future tidying.

## Open (deferred)

- **Convert `client → service` from a zone-wide `access-to` to per-module pinholes.** The F2 deferral,
  and the only I1 warning a converged install carries. Needs its own issue; nothing in this ADR depends
  on it.
- **Rationalize the three remote-access overlays** (`netbird` vs `admin` vs `edge`) — unchanged from
  v0.3, still out of scope, still needs its own ADR against ADR-010/#367.

## Acceptance — verified

Every box below is covered by an automated test (network-manager 236 unit + 16 CLI, environment-manager
27, module-manager 13 + 89) and, where marked ⬩, by a rehearsal against a copy of a production config.

- [x] `environment add --create-zone` yields a working environment + Service zone in one command.
- [x] `environment reconcile` creates an **absent** zone; hard-errors when the named zone **exists**
      with a non-Service type (D1 correction), in preview *and* apply.
- [x] `network-manager bind <zone> --environment <env>` sets `serves`; reconcile derives the correct
      **local** edge (D2 correction); R2 holds structurally for `isolated` zones.
- [x] ⬩ After `init` renames `srv → <env>`, a `serves`-linked client zone stays converged across
      `merge` — and the back-fill leaves the **`access-to` graph byte-identical** on a production config.
- [x] `network-manager add --archetype {service,dmz,trusted-client,iot-*,guest,control}` produces a
      zone with the correct `type`/`tier`/`isolated`/`access-to`-seed and auto-allocated vlan/ip — no edit.
      All nine archetypes verified to coexist and pass I1–I4 unmodified.
- [x] `zones-fields.json` carries `tier` + `isolated` + `serves` + the catalog, invariants and
      exemptions; `validate` reports R1/R2/egress/archetype conformance **as warnings**, and `--strict`
      turns a violating config non-zero — wired to no gate (F2).
- [x] `network-manager list --state Inactive`, `--type Client|IoT`, and `--tier N` filter correctly;
      client/IoT rows show `tier` + `serves` + `isolated`.
- [x] `network-manager init core` emits `mgmt` + `wan` + overlays + `<N>` + **`home`** + `guest` +
      `dmz`; `init iot` adds `iotCloud`/`iotLocal`/`iotCams`/`iotUntrust` plus its `grants`; idempotent,
      composable and order-independent; ships **no** test zones, no `srv{Home,…}`, no `work`.
      A fresh `init core` validates **completely clean**.
- [x] ~~The `home → private` rename…~~ **STRUCK (F1)** — `home` is kept, so there is no re-domaining
      and no rename map to build. `srv → <N>` remains the only rename.
- [x] ⬩ `network-manager retire` removes the ten retired zones when unoccupied and not live, keeps
      `work`/`srv`, strips every dangling reference, and is idempotent (F3).
- [x] `ZONES.md` documents `serves`, `bind`, archetypes, the `tier` lattice + R1/R2, the authored vs.
      effective split, install profiles, `retire`, and that enable/disable already exist — replacing the
      `_README.tier_model` prose, which now points at the schema.
- [x] #419: no shipped app module references a retired or renamed zone (enforced by a regression guard);
      an unresolvable `proxyAllowedZones` entry is a **hard error** instead of a silent drop; every zone
      reference is validated **before** any resource is created.
