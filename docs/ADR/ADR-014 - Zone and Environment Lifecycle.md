# ADR-014 — Zone ↔ Environment Lifecycle & Operations

| | |
|---|---|
| **Status** | **Proposed** — draft (not yet implemented) |
| **Version** | 0.3 |
| **Date** | 2026-08-06 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Refines** | [ADR-007c Environments](<ADR-007c - Environments.md>) (env↔zone binding), [ADR-007d Site](<ADR-007d - Site.md>) (`defaultEnvironment`, client-zone naming), [ADR-007f Realization](<ADR-007f - Realization.md>) (managers); ADR-001/002 (VLAN/zone model — the tier dimension) |
| **Related** | **#258** (origin of the `tier_model` prose in `zones.json` — a documentation/isolation-invariant issue, never an ADR; this ADR is its first design record); #424 (client/IoT zones ↔ environments undefined); #425 (keep client-zone names — closed); #426 (decouple site.name — closed); ADR-002 (dynamic VLAN); ADR-008 (network infrastructure); **owner:** `network-manager` (zones), `environment-manager` (environments) |
| **Changelog** | v0.3 — **recast `tier` as a strict trust lattice** (D5): `access-to` flows downward only (R1: `tier(A) ≤ tier(B)`), all upward reach is a `pinhole`; **DMZ drops out of the service class** to Tier 4 (internet-exposed) and **service sits above trusted clients** (client→service becomes a pinhole, #258-aligned); **isolation becomes an orthogonal `isolated` flag** (R2). D6 checks reduce to R1 + R2 + egress + archetype-conformance. Header now cites **#258** as the tier model's provenance. v0.2 — add the **zone tier model as first-class state** (D5: `tier` authored field + archetypes), **tier-based security invariants** in zones-check (D6, promoting the `_README` PR checklist to machine gates), and the **fresh-install default zone set + template cleanup** (D7). D3's IoT `--class` is subsumed by the D5 archetypes. v0.1 — initial draft: env↔service-zone binding (default / override / auto-create); symbolic `serves` link for client & IoT zones (rename-safe, fixes #424); guided IoT creation; filtered zone listing + confirmation that enable/disable already exist. |

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
  - *Pre-create:* `network-manager add <Z> --type Service` first, then `environment add`. (Works today.)
  - *Combine:* `environment add <env> [--zone <Z>] --create-zone` — environment-manager shells out to
    `network-manager add <Z> --type Service` (idempotent) **before** writing the environment file, so a
    single command yields a working environment + service zone.
- **Reconcile materializes, no longer just warns.** `environment reconcile <env>` is upgraded: when
  `network.zone` names a **Service-type** zone that is missing from `zones.json`, reconcile **creates it
  Active** (via network-manager) instead of emitting today's warning. A missing **non-Service** zone
  (the operator pointed an environment at a client/IoT zone) stays a hard error — that is a
  configuration mistake, not something to auto-fix.

> **Ownership boundary (unchanged).** `network-manager` remains the sole writer of `zones.json`;
> `environment-manager` never edits zones directly — it *requests* zone creation/checks by shelling to
> `network-manager` (the existing `clients.ts` seam). Auto-create is a call across that seam, not a new
> writer.

### D2 — Client & IoT zones link to an environment by a symbolic `serves` field (fixes #424)

The root cause of #424 is that a client/IoT zone's reachability is expressed as **literal service-zone
names** that do not survive the install-time rename. Replace the literal with a **symbolic reference to
the environment**, resolved on every reconcile — the same rename-safe pattern the zones 3-way merge
already relies on.

- **New optional zone field `serves`** (client and IoT zones only): the **environment name** whose
  service zone this zone consumes. It is authored once and is stable across renames.

  ```jsonc
  "private": {
    "type": "Client", "state": "Active", "vlantag": 30, "ip": "10.3.0.0/24",
    "serves": "warmelo",              // ← the environment, not "srvHome"
    "access-to": ["internet"],        // ← the service-zone entry is now DERIVED, not hand-listed
    "pinhole-allowed-from": []
  }
  ```

- **Resolution.** On `network-manager reconcile`, `serves: "<env>"` expands to: add the environment's
  `network.zone` (looked up in `config/environments/<env>.json`) to this client zone's effective
  `access-to`; and add this zone to that service zone's `pinhole-allowed-from`. The literal
  `access-to`/`pinhole-allowed-from` in the file remain the **baseline** (internet, cross-client, etc.);
  `serves` contributes the environment edge on top. Because the edge is derived from the environment's
  *current* `network.zone`, renaming `srv → <env>` no longer strands the reference — #424's core defect.
- **New verb to author the link without editing JSON:**
  `network-manager bind <zone> --environment <env>` sets `serves` on a client/IoT zone (and
  `--unbind` clears it). This is the "make it easy to create the relationship" the operator asked for.
- **Tier-4 isolation is unchanged.** `serves` on an isolated IoT zone (`iotCams`, `iotUntrust`) still
  never adds that zone to anyone's `access-to`; it only records which environment's modules may open
  **per-module pinholes** into it (the existing `pinhole-allowed-from` mechanism). The isolation
  invariant in `zones.json._README` is preserved verbatim.

> **Migration for existing installs.** `network-manager merge` (the rename-aware 3-way step) gains a
> one-time pass that, for each client/IoT zone whose literal `access-to` references a renamed service
> zone, sets `serves` to the owning environment and drops the now-derived literal. Idempotent; a
> converged install re-runs it as a no-op.

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
| **2** | Trusted client | ↓ internet, own IoT-controlled | direct (its devices) | `private`, `work` |
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
  **upward pinhole** (`private` → `srv`:port), not a zone-wide `access-to` — tighter, and it matches the
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
  | `trusted-client` | Client | 2 | no | internet (svc via **pinhole**) | `private`, `work` |
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
two core rules + two guards. Each is a warning by default, a hard error under `--strict` (a pre-deploy /
CI gate):

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

### D7 — Fresh-install default set via composable `init` profiles

Replace today's single flat template (~19 zones + 4 test zones) with **`network-manager init <profile>`**
— additive, idempotent zone bundles the operator applies in stages:

- **`network-manager init core --name <N>`** — the minimal coherent install (the `srv → <N>` rename runs
  here). This is the only profile a headless/server TAPPaaS needs.
- **`network-manager init iot`** — adds the IoT segment set on top of `core`. Opt-in: a site with no
  smart-home/IoT devices never gets these zones.

Profiles are re-runnable and compose (`init core` then later `init iot`); each only ever adds/activates
its zones, never touches another profile's. Room for more profiles later (e.g. `init dev` for
`srvDev`/`srvTest`), but `core` + `iot` cover the SOHO baseline.

| Profile | State | Zones (tier per the D5 lattice) |
|---|---|---|
| **`core`** | Active / Manual | `mgmt` (T0, Manual) · `<defaultEnvironment>` service zone (T1, from the `srv` rename) · `private` (T2, `serves <env>`) · `guest` (T3) · `dmz` (T4, **Mandatory**) |
| **`iot`** | Active | `iotCloud` (T3) · `iotLocal` (T6) · `iotCams` (T6, `isolated`) · `iotUntrust` (T3, `isolated`) |
| **overlays** (always present) | Manual | `netbird` · `edge` · `admin` — non-VLAN; see note below |

Three deliberate changes from the earlier draft:

- **`dmz` moves into `core` as Mandatory** — it is already Mandatory in the template (the reverse-proxy /
  controlled-exposure path assumes it exists), so it belongs in the always-on `core`, not the opt-in `iot`.
- **`iotUntrust` joins the `iot` profile Active** (was Inactive/"Available"). Opting into IoT means opting
  into the whole segment set, quarantine zone included — it is `isolated` anyway, so shipping it hot costs
  nothing and saves a step.
- **No "Available/Inactive" pre-shipped zones.** A second trusted client, extra service zones, a `work`
  segment — all are **generated on demand** with `add --archetype …` (D5), not shipped dormant. Dormant
  zones were pure surface area (and the `srv*` ones were the #424 stale-`access-to` surface).

**`home` → `private`.** The trusted-client reference zone is renamed `home` → **`private`**, pairing
cleanly with `guest` (private vs guest, both site-local *role* names — the #425/007d principle stands:
role names, never org-prefixed).

> **Interaction with #425 / ADR-007d (must handle in migration).** #425 fixed `zones-init` to *keep*
> `home`/`guest` unchanged, because the zone key drives the client DNS domain (`<zone>.internal`) and a
> rename re-domains every device and de-converges `zones-merge`. Renaming `home → private` is safe for
> **fresh** installs (they never had `home`), but for **existing** installs it is exactly that kind of
> rename: it must go through the **recorded rename map** (the same mechanism as `srv → <env>`), not a
> hardcoded rename, and it re-domains `home.internal → private.internal`. ADR-007d's "client zones keep
> their template names" line needs a one-word update (the template name is now `private`), and the
> migration must record `home → private`. **Flagged as a decision:** accept the one-time re-domaining, or
> keep `home` as the reference name after all.

Two **cleanups** to the shipped template (unchanged):

- **Drop the test zones** (`test`, `testAllowA/B`, `testPinhole`, typeId 8) from the shipped
  `zones.json` — they belong only in `test/fixtures/zones.json`, never in the install template.
- **Collapse `srvHome/srvWork/srvCust/srvDev/srvTest` → ship only `srv`** (renamed to
  `<defaultEnvironment>`). Additional service zones now come from `environment add --create-zone` (D1) or
  `add --archetype service` (D5) — removing the five stale-`access-to` blocks at the root of #424.

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

## Command surface (summary)

| Command | Status | Purpose |
|---|---|---|
| `environment add <env> [--zone Z] [--create-zone]` | **extend** (`--create-zone` new) | create env; optionally auto-author its service zone in one step (D1) |
| `environment reconcile <env>` | **change** | materialize a missing **Service** zone (was warn-only); hard-error on missing non-service zone (D1) |
| `network-manager bind <zone> --environment <env>` / `--unbind` | **new** | set/clear a client/IoT zone's `serves` link (D2) |
| `network-manager add <name> --archetype <A>` | **extend** | tier-correct zone creation from an archetype (D5); subsumes D3's `--class` |
| `network-manager reconcile` | **change** | resolve `serves` → derived `access-to`/`pinhole-allowed-from` each run (D2) |
| `network-manager validate` (zones-check) | **extend** | tier security invariants I1–I4 (R1 monotonic + R2 isolation); `--strict` = hard gate (D6) |
| `network-manager init <core\|iot> [--name N]` | **change** | composable profile bundles (D7); drop test zones + collapse `srv*` |
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
- **`schemas/zones-fields.json`** — add `tier`, `isolated`, and `serves` to `fields`; add the **archetype
  catalog** (the D5 table: archetype → type/typeId/tier/isolated/`access-to`-seed) as the single source of
  tier-correct defaults + the D6/I4 conformance target. Document all three in `network-manager/ZONES.md`
  (Field Reference + a tier-lattice / archetype section, replacing the `_README.tier_model` prose).
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
  Auto-create in `environment reconcile` is a behaviour change — an environment pointing at a
  mistyped/missing zone now *creates* a service zone instead of warning; mitigated by the non-service
  hard-error and by `--check`/dry-run on both managers. The new D6 invariants may flag **pre-existing**
  configs that passed human review — expect a one-time cleanup pass (run non-`--strict` first).
- **Neutral.** Backwards compatible: a `zones.json` with no `serves`/`tier` fields and literal `access-to`
  keeps working (D6 warns on a missing `tier` rather than erroring, until back-filled); both fields are
  purely additive. The D7 template cleanup affects only fresh installs; existing installs converge via
  `merge`.

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
5. **`init` is staged into composable profiles** (D7): `init core` (mgmt + service + `private` + `guest` +
   `dmz`) is the minimal install; `init iot` adds the full IoT segment set (`iotCloud`/`iotLocal`/
   `iotCams`/`iotUntrust`, all Active). No dormant "Available" zones — a second client / extra service
   zone is generated on demand via `add --archetype`. The trusted-client reference zone is **`private`**
   (was `home`), paired with `guest`.
6. **`tier` is a strict trust lattice with one directional rule** (D5/R1): `access-to` flows downward
   only (`tier(A) ≤ tier(B)`); all upward reach is a `pinhole`. This makes the D6 security check a single
   comparison. It forced two reorders vs. the old `_README` labels — **DMZ dropped out of the service
   class** to Tier 4 (internet-exposed, assume-breach), and **service backends sit above trusted
   clients** (client→service becomes an upward pinhole, #258-aligned).
7. **Isolation is an orthogonal `isolated` flag** (R2), not a tier — because `iotCams` (T6) and
   `iotUntrust` (T3) are both quarantined yet sit at different trust ranks.

> **Two forks flagged for confirmation** (recommended as written, easy to flip): whether
> `client → service` is a pinhole (chosen) or stays a broad `access-to` (which would instead put clients
> above services); and whether `guest` shares Tier 3 with the internet-egress IoT zones (chosen) or gets
> its own rank.

## Open (deferred to implementation)

- **`merge` back-fill ordering.** Whether the one-time `serves` back-fill (D2 migration) runs inside
  `merge` or as a discrete migration step — resolve when the migration is written.

## Acceptance (draft — becomes a checklist on Accepted)

- [ ] `environment add --create-zone` yields a working environment + Service zone in one command.
- [ ] `environment reconcile` creates a missing Service zone; hard-errors on a missing non-Service zone.
- [ ] `network-manager bind <zone> --environment <env>` sets `serves`; reconcile derives the correct
      `access-to`/`pinhole-allowed-from`; R2 still holds for `isolated` zones.
- [ ] After `init` renames `srv → <env>`, a `serves`-linked client zone stays converged across
      `merge` (no stale service reference; regression test in `network-manager/test.sh`).
- [ ] `network-manager add --archetype {service,dmz,trusted-client,iot-*,guest,control}` produces a
      zone with the correct `type`/`tier`/`isolated`/`access-to`-seed and auto-allocated vlan/ip — no edit.
- [ ] `zones-fields.json` carries `tier` + `isolated` + `serves` + the archetype catalog; `validate
      --strict` enforces R1 (monotonic `access-to`), R2 (isolation floor), egress, and archetype
      conformance, and fails a violating config (e.g. an upward `access-to` edge).
- [ ] `network-manager list --state Inactive`, `--type Client|IoT`, and `--tier N` filter correctly;
      client/IoT rows show `tier` + `serves`.
- [ ] `network-manager init core` emits mgmt + service + `private` + `guest` + `dmz`; `init iot` adds
      `iotCloud`/`iotLocal`/`iotCams`/`iotUntrust`; both idempotent and composable; ships **no** test
      zones and no `srv{Home,Work,Cust,Dev,Test}`.
- [ ] The `home → private` rename is driven by the recorded rename map (not hardcoded), stays converged
      across `merge`, and re-domains `home.internal → private.internal` on an existing install only.
- [ ] `ZONES.md` documents `serves`, `bind`, archetypes, the `tier` lattice + R1/R2, and that
      enable/disable already exist (replacing the `_README.tier_model` prose).
