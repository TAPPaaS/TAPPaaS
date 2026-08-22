# Zone Definitions in TAPPaaS

## Introduction

`zones.json` defines the security zones of a TAPPaaS installation. Each top-level
key is a zone with its network configuration, access policy, and DHCP settings.
Keys beginning with `_` (e.g. `_README`) are documentation blocks and are ignored
by every consumer.

**network-manager owns the entire zones lifecycle.** It is the single front door
for the network: it does CRUD on `zones.json` (the desired network state),
transforms the distributed template at install, reconciles release drift on every
update, audits consistency, distributes the file to the Proxmox nodes, and
reconciles the four infrastructure planes (OPNsense, Proxmox, switch, access
points) so a zone's VLAN actually reaches the firewall, the hosts, the physical
switch, and the WiFi. There is **no separate `zone-controller`** — the desired-state
authority lives inside network-manager.

Modules connect to zones via their `module.json` (`zone0`, ingress/egress).
The `zones.json` template ships under this directory; the live, per-installation
copy lives at `${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json`.

> The legacy `variant-manager` and `apply-zones-merge.sh` are **retired**. Variants
> were replaced by ADR-007 **environments** (`config/environments/<env>.json`); the
> bash merge was ported into `network-manager merge` (see below).
> The full design is in the appendix "Zones lifecycle…" sections A–D of
> `docs/design/ADR-007-implementation.md`.

## The zone object

| Field | Meaning |
|-------|---------|
| `type` / `typeId` | Security classification (see below). `typeId` is the numeric band. |
| `state` | Activation state (see below). |
| `subId` | 0–99, identifies the zone within its type band. |
| `vlantag` | VLAN tag. Computed: `typeId * 100 + subId` (0 = untagged). |
| `ip` | Subnet CIDR. Computed: `10.<typeId>.<subId>.0/24`. |
| `bridge` | VLAN trunk interface (`lan` / `wan` / `opt1` / `opt2`). |
| `access-to` | Zones (and `internet`) this zone may reach, subnet-to-subnet. |
| `pinhole-allowed-from` | Zones that may open per-module pinholes into this zone. |
| `tier` | Trust rank 0–6 in the strict lattice (0 = most trusted). `access-to` may only run **downward**. Optional; absent on `Overlay`/`WAN`. |
| `isolated` | Inbound quarantine: accepts **no** zone-wide `access-to`; pinhole-only. Orthogonal to `tier`. Default `false`. |
| `serves` | For a Client/IoT zone: the **environment** whose service zone it consumes. Symbolic — survives the `srv` → `<env>` rename (#424). |
| `DHCP-start` / `DHCP-end` | DHCP range offsets within the subnet (default 50–250). |
| `description` | Human-readable purpose. |
| `SSID` | Optional WiFi network name broadcast on this zone's VLAN. |

Auto-allocated VLANs use the 60–99 window within each type band. Zone keys match
`^[a-z][a-zA-Z0-9]*$` — **camelCase only, no hyphens or underscores** (#278), as in
`srvHome` / `iotCams`. This is what `network-manager add` has always enforced; the
schema previously advertised a hyphenated form that no code path would accept.
The client role zones `home` / `guest` stay unprefixed (#425) — the zone key drives
the client DNS domain `<zone>.internal`, so renaming one re-domains every device.

### Zone types

| Type | typeId | Purpose |
|------|--------|---------|
| Management | 0 | TAPPaaS nodes and self-management; locked down. Usually one zone, `mgmt`. |
| Service | 2 | Application/service modules. Multiple service zones may exist. |
| Client | 3 | End-user client devices. |
| IoT | 4 | IoT devices (often less secure). |
| Guest | 5 | Untrusted / guest access. |
| DMZ | 6 | Demilitarized zone for controlled-exposure services. |
| Overlay | 7 | Non-VLAN overlay (e.g. NetBird/WireGuard); no interface/DHCP/rules, always `Manual`, `vlantag=0`. Carries its own source CIDR so consumers can resolve it. |

### Zone `state`

| State | Meaning |
|-------|---------|
| **Active** | network-manager creates/maintains the OPNsense interface, DHCP scope, and baseline firewall rules. |
| **Mandatory** | Same as Active; the zone must exist and cannot be disabled. |
| **Inactive** | Defined but **not** provisioned (no interface/DHCP/rules); removed if it exists. The schema default. |
| **Disabled** | Same as Inactive. |
| **Manual** | network-manager neither creates nor removes it — managed externally/by the operator (e.g. `mgmt`, `netbird`). |

## Access Model: the Trust Lattice, Isolation, and `serves`

Two independent mechanisms control reachability between zones:

| Mechanism | Scope | Direction | Set by |
|---|---|---|---|
| `access-to` | Entire source subnet → entire target subnet | **Downward only** | Zone designer, in `zones.json` (baseline) |
| `pinhole-allowed-from` + module `install.sh` | Specific source VM IP → specific port | **The only way trust flows up** | Module author (runtime) |

### The lattice (ADR-014)

`tier` is a **strict trust rank**, not a label. It exists so the access model can be
machine-checked rather than reviewed by eye:

> **R1 (monotonic `access-to`)** — for every edge `A access-to B`, `tier(A) ≤ tier(B)`.
> Never upward. `internet` counts as tier 5.

| Tier | Name | `access-to` (downward baseline) | Reached from above via | Members |
|---|---|---|---|---|
| **0** | Control plane | all zones | *nothing — no inbound at all* | `mgmt` |
| **1** | Service backend | ↓ internet, dmz, IoT-controlled | **pinhole** from clients + reverse proxy | `<defaultEnvironment>` |
| **2** | Trusted client | ↓ internet, own IoT-controlled | direct (its own devices) | `home`, `work` |
| **3** | Untrusted edge | ↓ internet only | — | `guest`, `iotCloud`, `iotUntrust` |
| **4** | DMZ (exposed) | ↓ internet only | **pinhole** from internet | `dmz` |
| **5** | *Internet* | — (the boundary) | — | *(token, not a zone)* |
| **6** | Isolated / no-egress | *(none)* | **pinhole** only when `isolated` | `iotCams`, `iotLocal` |

Two consequences worth stating plainly:

- **DMZ is not a service peer.** A DMZ host is internet-exposed and assume-breach, so
  it sits *below* an internal backend (tier 4, not 1). `service → dmz` is a legal
  downward edge; `dmz` reaches nothing internal.
- **Service sits above trusted clients.** A client reaching its service is an **upward
  pinhole** (`home` → `<env>`:port), not a zone-wide `access-to`. The backend is the
  crown jewel; clients get specific ports, not the subnet.

`tier` and `type` are genuinely orthogonal — a `Guest` client and an `iotCloud` IoT
zone share tier 3 (identical outbound, no inbound), which is exactly why tier cannot
be derived from type.

**`Overlay` and `WAN` zones carry no tier** and are skipped by the tier checks:
overlays are non-VLAN WireGuard segments with no meaningful rank (`admin` legitimately
reaches `mgmt`), and `wan` is the switch-internal ISP hand-off with no interface or rules.

### Isolation is a flag, not a tier

> **R2 (isolation floor)** — a zone with `"isolated": true` must not appear in **any**
> zone's `access-to` (the `mgmt` exception aside).

Isolation is orthogonal to trust rank: `iotCams` (tier 6, no egress) and `iotUntrust`
(tier 3, internet egress) are both quarantined yet sit at different ranks — so it could
never be a single tier row. Inbound reach is granted only by per-module pinhole. Adding
an isolated zone to a non-`mgmt` `access-to` would nullify the pinhole mechanism: every
host in the source subnet would gain unconditional zone-wide reach. `iotCams` in
particular must stay purpose-limited (GDPR Art. 25).

`iotLocal` shares tier 6 with `iotCams` (both no-egress) but is **not** `isolated`: its
serving zone reaches it zone-wide (Home Assistant → local IoT), which R2 forbids for
`iotCams`.

### Archetypes

An archetype is a named bundle of tier-correct defaults. `network-manager add <name>
--archetype <A>` stamps `type`/`typeId`/`tier`/`isolated` and the `access-to` seed, then
auto-allocates `subId`/`vlantag`/`ip` — so a correctly-classified zone is one command,
not a copy-paste of a template block.

| Archetype | type | tier | isolated | `access-to` seed | reference zone |
|---|---|---|:---:|---|---|
| `control` | Management | 0 | no | all | `mgmt` |
| `service` | Service | 1 | no | internet, dmz | `srv` → `<env>` |
| `trusted-client` | Client | 2 | no | internet (service via **pinhole**) | `home`, `work` |
| `guest` | Guest | 3 | no | internet | `guest` |
| `iot-cloud` | IoT | 3 | no | internet | `iotCloud` |
| `iot-untrust` | IoT | 3 | **yes** | internet | `iotUntrust` |
| `dmz` | DMZ | 4 | no | internet (inbound via **pinhole**) | `dmz` |
| `iot-local` | IoT | 6 | no | *(none)* | `iotLocal` |
| `iot-cams` | IoT | 6 | **yes** | *(none)* | `iotCams` |

The catalog is authoritative in
[`schemas/zones-fields.json`](../../../schemas/zones-fields.json) (`archetypes.catalog`),
which is also what invariant I4 checks against.

### `serves` — linking a client or IoT zone to an environment

A client zone reaches its services, and an IoT zone is reached by them. Writing that as a
**literal** service-zone name is what issue #424 is about: `network-manager init` renames
`srv` → `<defaultEnvironment>`, and every literal reference is stranded.

`serves` names the **environment** instead, and is resolved on every reconcile:

```jsonc
"home": {
    "type": "Client", "state": "Active", "vlantag": 310, "ip": "10.3.10.0/24",
    "tier": 2,
    "serves": "warmelo",          // ← the environment, not "srvHome"
    "access-to": ["internet"],    // ← the service-zone edge is DERIVED, not listed
    "pinhole-allowed-from": []
}
```

Resolution reads `config/environments/<env>.json` `.network.zone` and contributes the
environment edge **on top of** the authored baseline. Because the edge is derived from the
environment's *current* zone, a rename can never strand it.

Set it with `network-manager bind <zone> --environment <env>` (`--unbind` clears it) —
no JSON editing. An `isolated` zone contributes **only** the pinhole direction, never an
inbound `access-to`, so R2 holds regardless of `serves`.

> **Authored vs. effective.** Derived edges are **never** written back into `zones.json`,
> which stays purely authored — otherwise the 3-way merge would see them as operator edits
> and pin them, stranding the edges of a `serves` link that was later cleared. `reconcile`
> renders `config/zones.effective.json` instead, and the consumers (`zone-manager`,
> `rules_manager`, the Caddy access lists) read that. It is generated, never hand-edited,
> and regenerated on every run.

### Security invariants (`network-manager validate`)

The checks below promote what used to be a human PR checklist into code. Each is a
**warning by default** and an error under `--strict`:

| ID | Rule | Notes |
|---|---|---|
| **I1** | R1 — monotonic `access-to`: `tier(A) ≤ tier(B)` | `mgmt` exempt; `Overlay`/`WAN` skipped; a missing `tier` is a note, not a warning |
| **I2** | R2 — isolation floor: an `isolated` zone is in nobody's `access-to` | `mgmt` exempt |
| **I3** | Egress boundary: a tier-6 zone must not list `internet` | `Overlay`/`WAN` skipped |
| **I4** | Archetype conformance: `(type, tier, isolated)` matches a catalog entry | catches a zone configured against its declared intent |

`pinhole-allowed-from` is deliberately **not** tier-gated — upward is what pinholes are
*for*. It is validated per-module against the target zone's list, as today.

## network-manager commands (the zones lifecycle)

One compiled CLI, `network-manager`, owns every flow that touches `zones.json`:

| Command | Purpose |
|---------|---------|
| `list` / `exists <n>` / `show <n>` _(alias `get`)_ | Read CRUD on `zones.json`. The `zone` keyword is an optional, legacy prefix. |
| `add <n> [--from-zone S] [--vlan N] [--check]` | Author a new zone **and reconcile all four planes** (so the VLAN reaches everything). `--from-zone` inherits type/bridge/access. |
| `delete <n> [--check]` | Disable the zone, reconcile all planes, then drop the key. |
| `reconcile [--apply] [--only <plane>]` | The 4-plane converge loop — `opnsense \| proxmox \| switch \| ap`. Default is a non-mutating dry-run (exit 2 = drift). |
| `init [<profile>] --name <N>` _(alias `zones-init`)_ | Apply a composable install profile (`core` / `iot`) — additive, idempotent, order-independent (see below). |
| `retire [--apply]` | Remove zones a release stopped shipping, under the liveness + occupancy guard. |
| `bind <n> --environment <env>` | Link a Client/IoT/Guest zone to an environment (`serves`). |
| `merge [--diff]` _(alias `zones-merge`)_ | Rename-aware 3-way reconciliation against the upstream template; run on every `update-tappaas` (replaces `apply-zones-merge.sh`). |
| `validate [--strict] [--effective]` _(alias `zones-check`)_ | Offline consistency audit (dangling refs, missing fields, the tier invariants I1–I4). `--effective` audits the rendered graph rather than the authored file. |
| `distribute [--dry-run]` _(alias `zones-distribute`)_ | Push the live `zones.json` to every Proxmox node so VMs can be created in its zones. |

`environment-manager` calls `network-manager` when an environment needs a zone
created or checked; domain/cert lifecycle stays with `environment-manager`.

## Install profiles and the per-installation rename

The distributed template carries every zone the release ships. A fresh install
applies one or more **profiles** — additive, idempotent bundles — rather than
taking the whole template and switching off what it does not want:

| Profile | Zones |
|---------|-------|
| **`core`** (default) | `mgmt` · `wan` · the `netbird`/`edge`/`admin` overlays · `<N>` (the renamed `srv`, forced Active) · `home` · `guest` · `dmz` (Mandatory) |
| **`iot`** | `iotLocal` · `iotCloud` · `iotCams` · `iotUntrust` — all Active, each `serves` the default environment |

```bash
network-manager init core --name acme     # the minimal coherent install
network-manager init iot  --name acme     # opt in to the IoT segment set
```

`core` is all a headless/server TAPPaaS needs. A site with no smart-home devices
never runs `init iot` and never carries those zones. Extra service zones, a
second client segment and so on are generated on demand with
`add --archetype …` or `environment add --create-zone` — **no dormant
"Available" zones are shipped**, because dormant zones were pure surface area
and the `srv*` ones were exactly the stale-reference surface of #424.

Profiles are **additive** (a profile only adds its own zones, plus the
`access-to` entries those zones need on zones from another profile),
**idempotent** (re-applying is a byte-level no-op), **order-independent**, and
**non-destructive** — existing zones always win, so an init re-run can never
rebuild a live file from template defaults (#427).

### The rename: `srv → <N>`, and nothing else

`init` stamps the installation name `<N>` (= `site.defaultEnvironment`) into the
zone namespace:

- **rename** `srv` → `<N>`, forced **Active** — the default service zone every
  app module lands in unless its JSON names another;
- **`home` and `guest` keep their names.** They are site-local client-*role*
  zones — there is one of each per site, so an org prefix would distinguish
  nothing, and the zone key drives the client DNS domain `<zone>.internal`, so
  renaming one re-domains every device (#425);
- **every zone-name reference is rewritten** through the same map — `access-to`,
  `pinhole-allowed-from`, and the `serves` placeholder.

That last point is what makes a shipped client/IoT zone come out of `init`
already bound: the template writes `serves: "srv"`, and after the rename it
reads `serves: "<N>"` — the default *environment*, which shares its name with
the default service zone by construction (ADR-007d/#426). No literal
service-zone reference is left to go stale.

### Retiring what a release stopped shipping

Dropping a zone from the template does **not** remove it from an existing
install — the 3-way merge deliberately keeps anything present locally but absent
upstream, so a release can never silently delete an operator's zone. Removal is
therefore an explicit, guarded step:

```bash
network-manager retire            # dry-run
network-manager retire --apply
```

`retire` considers an **explicit list** (`srvHome`, `srvWork`, `srvCust`,
`srvDev`, `srvTest`, `iot`, `test`, `testAllowA`, `testAllowB`, `testPinhole`) —
never "everything Inactive" — and removes one only when it is **both** not
Active/Mandatory/Manual **and** not named by any installed module's
`zone`/`zone0`. Anything else is kept with the reason. `srv` (the rename source)
and `work` (a client zone that is merely switched off) are never retired.

### Zone stability — installed modules stay put

A retired-set zone kept by the occupancy guard (still hosting deployed modules)
is the **intended steady state**, not a migration TODO. Already-installed modules
**stay in their zone**; the network lifecycle never moves a running service and
never auto-inactivates a zone that has live services. To relocate a module, back
up its data, uninstall it, and reinstall it in the target zone — there is no
in-place re-home (a zone change means a new VLAN/subnet/IP and re-wired
dependents).

### Three files, run on every update (rename-aware 3-way merge)

Keeping the rename robust across releases uses three files in `${CONFIG_DIR}`,
all in the installation's renamed namespace:

- **`zones.json`** — *current*: the live, per-installation zones.
- **`zones.json.orig`** — *baseline*: the version of the source the current was
  last merged from.
- **`zones.rename.json`** — *source*: the **full** upstream template with this
  installation's rename applied (regenerated on demand; never hand-edited). It
  carries every zone the release ships, whichever profiles are installed — a
  profile-scoped source would mean a field fix to an uninstalled zone could
  never be adopted later.

`network-manager merge` runs on every `update-tappaas`:

1. read the current repo template → apply the same rename algorithm → (re)write
   `zones.rename.json` (re-basing upstream changes into the renamed namespace);
2. 3-way merge *current* vs *baseline* vs *source* — per field: `state` and
   `serves` are **operator-pinned, never adopted** (`serves` names an environment
   that exists only on this system, so the shipped template can never hold a
   meaningful value for it); every other field adopts the source when
   `current == orig`, else the local edit wins. Zone-level: source-only → **ADD**;
   current-only → **keep + warn**; same `vlantag` / different name → **flag a
   possible rename (do not auto-rename)**;
3. write merged → `zones.json` and **advance `zones.json.orig` ← `zones.rename.json`**.

Because `srv`/`home`/`guest` never appear in `zones.rename.json` (they are renamed
away), the "source-only → ADD" rule can never re-create them — which is what
closes the recurring duplicate-VLAN corruption the old `apply-zones-merge.sh` had.

## Example Configuration

```json
{
    "mgmt": {
        "type": "Management",
        "state": "Manual",
        "typeId": "0",
        "subId": "0",
        "vlantag": 0,
        "ip": "10.0.0.0/24",
        "bridge": "lan",
        "tier": 0,
        "access-to": ["internet", "warmelo", "home", "iotCams", "dmz"],
        "pinhole-allowed-from": [],
        "description": "Control plane: hypervisors, backup, firewall, identity, cicd"
    },
    "warmelo": {
        "type": "Service",
        "state": "Active",
        "typeId": "2",
        "subId": "0",
        "vlantag": 200,
        "ip": "10.2.0.0/24",
        "bridge": "lan",
        "tier": 1,
        "access-to": ["internet", "iotCloud", "iotLocal", "dmz"],
        "pinhole-allowed-from": ["dmz"],
        "description": "Service zone for the warmelo environment"
    },
    "home": {
        "type": "Client",
        "state": "Active",
        "typeId": "3",
        "subId": "10",
        "vlantag": 310,
        "ip": "10.3.10.0/24",
        "bridge": "lan",
        "tier": 2,
        "serves": "warmelo",
        "access-to": ["internet", "iotCloud", "iotLocal"],
        "pinhole-allowed-from": [],
        "description": "Trusted personal devices: laptops, phones, tablets"
    },
    "iotCams": {
        "type": "IoT",
        "state": "Active",
        "typeId": "4",
        "subId": "30",
        "vlantag": 430,
        "ip": "10.4.30.0/24",
        "bridge": "lan",
        "tier": 6,
        "isolated": true,
        "serves": "warmelo",
        "access-to": [],
        "pinhole-allowed-from": [],
        "description": "Surveillance: cameras + NVR, fully isolated"
    }
}
```

Note `iotCams.access-to` is `[]` and `isolated` is `true`: an NVR in the `warmelo`
service zone reaches the cameras only through an explicit per-module pinhole, never
via `access-to`. Its `serves` link records *which* environment's modules may open
that pinhole — it never grants zone-wide reach (R2).

Note also that neither `home` nor `iotCams` names a service zone literally. `home`
gets `warmelo` added to its effective `access-to`, and `iotCams` gets `warmelo` added
to its effective `pinhole-allowed-from`, both derived from `serves` at reconcile time.

## Computed Values

- **vlantag**: `typeId * 100 + subId` (e.g. typeId=2, subId=10 → 210)
- **ip**: `10.<typeId>.<subId>.0/24` (e.g. typeId=2, subId=10 → 10.2.10.0/24)

## WiFi: the `SSID` field

A zone may declare an optional `SSID` field — the WiFi network name broadcast on
that zone's VLAN. It is consumed by the ADR-008 WiFi tooling (see
[`network/scripts/README.md`](../../../network/scripts/README.md)):

- **`setup-wlan-secrets.sh`** walks the active zones that declare an `SSID`, lets
  you set the real name (replacing the shipped `<PLACEHOLDER>`), and stores the
  WPA passphrase in a 0600 secrets file (never in `zones.json`).
- **`ap-controller`** maps each SSID to its zone's VLAN on the WiFi controller.

The passphrase and per-SSID security level are **not** stored here — only the
SSID name and (via `vlantag`) its VLAN.

## Field Reference

For complete field definitions including all possible values, defaults, and
validation rules, see
[`schemas/zones-fields.json`](../../../schemas/zones-fields.json):
all available fields and their types, valid values for enumerated fields
(including the `state` enum), defaults, computed-field formulas, and the special
access-control values. It also carries the machine-readable **`tier_model`**,
**`archetypes.catalog`**, **`invariants`** (I1–I4) and **`tier_exempt_types`** blocks
that this document describes in prose — those are the authoritative copies.

## Per-Module Firewall Rules

Zone-level rules govern coarse access between zones. **Per-module** rules
(`network:rules` capability) declare each module's ingress/egress contract in
its own JSON and are validated against the zone-level policy:

- Every `ingress.from` zone must be in the destination zone's `pinhole-allowed-from`.
- Egress to a zone not in the source zone's `access-to` is permitted but warned.

A peer that is **another module's name** is resolved via an OPNsense host alias
populated with the peer's FQDN (`<vmname>.<zone0>.internal`), kept fresh by
OPNsense Unbound against dnsmasq — DHCP IP changes do not require rule rewrites.

See [`network/README.md`](../../../network/README.md) for the full schema,
sequence bands, and CLI reference.
