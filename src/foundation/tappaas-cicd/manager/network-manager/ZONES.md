# Zone Definitions in TAPPaaS

`zones.json` defines the security zones of a TAPPaaS installation: each top-level key is a
zone with its network, its access policy and its DHCP settings. Keys beginning with `_` are
documentation blocks and are ignored. The template ships in this directory; the site's own
copy is `config/zones.json`.

This page is the zone **model**: what a zone is, and the trust it is meant to express.
Two pages complete it:

- [network-manager](README.md) — the commands that create, change, check and distribute
  zones. `network-manager` owns the whole zone lifecycle; nothing else edits `zones.json`.
- [FIREWALL-RULES.md](FIREWALL-RULES.md) — how the zones, and the modules in them, become
  the firewall's rule set.

## The zone object

| Field | Meaning |
|-------|---------|
| `type` / `typeId` | Security classification (below); `typeId` is its numeric band. |
| `state` | Activation state (below). |
| `subId` | 0–99, the zone within its type band. |
| `vlantag` | VLAN tag, computed `typeId * 100 + subId` (0 = untagged). |
| `ip` | Subnet, computed `10.<typeId>.<subId>.0/24`. |
| `bridge` | The trunk the VLAN rides (`lan` / `wan` / `opt1` / `opt2`); for an overlay, the interface its traffic arrives on. |
| `access-to` | Zones (and `internet`) this zone may reach — whole subnet, every port. |
| `pinhole-allowed-from` | Zones whose modules may open a pinhole into this zone. |
| `snat-allowed-from` | Zones whose traffic may be masqueraded into this zone. |
| `tier` | Trust rank 0–6 (0 = most trusted). Absent on `Overlay`/`WAN`. |
| `isolated` | Inbound quarantine: no zone may reach it zone-wide. Default `false`. |
| `serves` | For a Client, Guest or IoT zone: the environment whose service zone it uses. |
| `DHCP-start` / `DHCP-end` | DHCP range offsets within the subnet (default 50–250). |
| `SSID` | Optional WiFi network broadcast on this zone's VLAN ([below](#wifi-the-ssid-field)). |
| `ipv6Subnet` | The zone's IPv6 network, 0–255: its `/64` within the site's prefix. Assigned by default; remove it to keep the zone IPv4-only ([IPV6.md](IPV6.md)). |
| `mdns` | The zone takes part in mDNS discovery across zones ([below](#discovery-across-zones-mdns)). Default `false`. |
| `description` | Human-readable purpose. |

Zone keys are camelCase (`^[a-z][a-zA-Z0-9]*$`), as in `srvHome` / `iotCams`. The client
zones `home` / `guest` stay unprefixed: the key is the client DNS domain `<zone>.internal`,
so renaming one re-domains every device. Every field, its values and defaults:
[`schemas/zones-fields.json`](../../../schemas/zones-fields.json).

### Zone types

| Type | typeId | Purpose |
|------|--------|---------|
| Management | 0 | TAPPaaS nodes and self-management; locked down. Usually one zone, `mgmt`. |
| Service | 2 | Application and service modules. A site may have several. |
| Client | 3 | End-user devices. |
| IoT | 4 | IoT devices (often less secure). |
| Guest | 5 | Untrusted or guest access. |
| DMZ | 6 | Services exposed to the internet. |
| Overlay | 7 | A non-VLAN overlay (WireGuard, NetBird): no interface or DHCP, always `Manual`, `vlantag` 0. |

### Zone `state`

| State | Meaning |
|-------|---------|
| **Active** | network-manager creates and maintains the zone's interface, DHCP scope and firewall rules. |
| **Mandatory** | As Active; the zone must exist and cannot be disabled. |
| **Inactive** | Defined but not provisioned; removed if it exists. The schema default. |
| **Disabled** | As Inactive. |
| **Manual** | network-manager neither creates nor removes it; it is managed outside TAPPaaS (`mgmt`, the overlays). |

## The trust model

Two mechanisms control reachability between zones:

| Mechanism | What it grants | Direction | Set by |
|---|---|---|---|
| `access-to` | the whole target subnet, every port | **downward only** | the zone, in `zones.json` |
| `pinhole-allowed-from` | a module's declared ports, to the zones listed | **the only way trust flows up** | the module, in its own JSON |

How each becomes a firewall rule is in [FIREWALL-RULES.md](FIREWALL-RULES.md).

### The lattice

`tier` is a **strict trust rank**, there so the access model can be checked by machine
rather than by eye. It is checked, not enforced: the rules come from `access-to` and
`pinhole-allowed-from`, and the [invariants](#security-invariants-network-manager-validate)
warn when those break the lattice.

> **R1 (monotonic `access-to`)** — for every edge `A access-to B`, `tier(A) ≤ tier(B)`.
> Never upward. `internet` counts as tier 5.

| Tier | Name | `access-to` (downward) | Reached from above via | Members |
|---|---|---|---|---|
| **0** | Control plane | all zones | nothing | `mgmt` |
| **1** | Service backend | internet, IoT it controls | **pinhole** from clients and the reverse proxy | `<defaultEnvironment>` |
| **2** | Trusted client | internet, its own IoT | its own devices | `home`, `work` |
| **3** | Untrusted edge | internet only | — | `guest`, `iotCloud`, `iotUntrust` |
| **4** | DMZ (exposed) | internet only | **pinhole** from the internet | `dmz` |
| **5** | *Internet* | — | — | *(a token, not a zone)* |
| **6** | Isolated / no egress | none | **pinhole** only, when `isolated` | `iotCams`, `iotLocal` |

- **No zone reaches the DMZ zone-wide.** A DMZ host is internet-exposed and assumed
  breached, so it sits below an internal backend, and `access-to: dmz` is refused (I5): the
  DMZ gateway is the firewall itself, so the edge would give the whole source zone the
  firewall's GUI and SSH. Published names are reached through Caddy, and a DMZ workload by
  pinhole.
- **Service sits above trusted clients.** A client reaching its service uses an upward
  pinhole to specific ports, never the backend's whole subnet.
- `tier` and `type` are orthogonal: a `Guest` zone and `iotCloud` share tier 3.
- `Overlay` and `WAN` zones carry no tier and are skipped by the tier checks.

### Isolation is a flag, not a tier

> **R2 (isolation floor)** — a zone with `"isolated": true` is in no zone's `access-to`
> (`mgmt` aside).

Isolation is independent of rank: `iotCams` (tier 6, no egress) and `iotUntrust` (tier 3,
internet egress) are both quarantined. They are reached only by pinhole. `iotLocal` shares
tier 6 with `iotCams` but is not isolated: its serving zone reaches it zone-wide (Home
Assistant → local IoT), which R2 forbids for `iotCams`: camera footage stays reachable only
by the modules that need it.

### `mgmt` reaches every zone: `all`

`mgmt` says `"access-to": ["internet", "all"]`. `all` stands for `internet` plus every zone
that is not `Disabled`, an `Overlay` or the `WAN` hand-off, so adding or deleting a zone
never edits `mgmt`. Only `mgmt` may hold `all` (I2).

### Linking a client or IoT zone to an environment: `serves`

A client zone reaches its services, and an IoT zone is reached by them. Naming the service
zone literally breaks when `network-manager init` renames `srv` → `<defaultEnvironment>`,
so `serves` names the **environment**, and the edge is derived from its current zone on
every reconcile:

```jsonc
"home": {
    "type": "Client", "state": "Active", "ip": "10.3.10.0/24", "tier": 2,
    "serves": "warmelo",          // the environment, not "srvHome"
    "access-to": ["internet"],    // the service-zone edge is derived, not listed
    "pinhole-allowed-from": []
}
```

A Client or Guest zone gets the environment's service zone added to its `access-to`; an IoT
zone gets it added to its `pinhole-allowed-from`, so an `isolated` zone never gains inbound
reach. The derived edges live in `config/zones.effective.json`, never in `zones.json`.

A zone may serve **several environments** — a workstation zone that reaches both a production
and a development service zone: `"serves": ["warmelo", "lab"]`. Each environment's edge is
derived, and the zone gets all of them. One environment stays a plain string.

Set it with `network-manager bind` ([network-manager](README.md)):

| Command | Effect |
|---|---|
| `bind <zone> --environment <env>` | the zone serves `<env>` — **replacing** any link it had |
| `bind <zone> --environment <env> --add` | the zone serves `<env>` **as well** |
| `bind <zone> --unbind --environment <env>` | the zone no longer serves `<env>`; other links stay |
| `bind <zone> --unbind` | every link is cleared |

### Archetypes

An archetype is a named bundle of tier-correct defaults: `network-manager add <name>
--archetype <A>` sets `type`, `tier`, `isolated` and the `access-to` seed, then allocates
`subId`, `vlantag` and `ip`.

| Archetype | type | tier | isolated | `access-to` seed | reference zone |
|---|---|---|:---:|---|---|
| `control` | Management | 0 | no | all | `mgmt` |
| `service` | Service | 1 | no | internet | `srv` → `<env>` |
| `trusted-client` | Client | 2 | no | internet (service via pinhole) | `home`, `work` |
| `guest` | Guest | 3 | no | internet | `guest` |
| `iot-cloud` | IoT | 3 | no | internet | `iotCloud` |
| `iot-untrust` | IoT | 3 | **yes** | internet | `iotUntrust` |
| `dmz` | DMZ | 4 | no | internet (inbound via pinhole) | `dmz` |
| `iot-local` | IoT | 6 | no | *(none)* | `iotLocal` |
| `iot-cams` | IoT | 6 | **yes** | *(none)* | `iotCams` |

The catalogue is authoritative in `schemas/zones-fields.json` (`archetypes.catalog`).

### Security invariants (`network-manager validate`)

Each is a warning, and an error under `--strict`:

| ID | Rule | Notes |
|---|---|---|
| **I1** | R1 — `tier(A) ≤ tier(B)` for every `access-to` edge | `mgmt` exempt; `Overlay`/`WAN` skipped; names every edge it could not check for a missing `tier` |
| **I2** | R2 — an `isolated` zone is in nobody's `access-to`; only `mgmt` holds `all` | `mgmt` exempt |
| **I3** | A tier-6 zone does not list `internet` | `Overlay`/`WAN` skipped |
| **I4** | `(type, tier, isolated)` matches an archetype | catches a zone configured against its intent |
| **I5** | No zone but `mgmt` has `dmz` in `access-to` | the DMZ is reached through Caddy or by pinhole |

`pinhole-allowed-from` is deliberately not tier-gated: upward is what pinholes are for.

### Discovery across zones: `mdns`

Printers, media players, speakers and smart-home hubs announce themselves with mDNS, which
stays within one VLAN. A zone with `"mdns": true` joins a single discovery group: a device in
it finds devices in every other zone of the group, and is found by them.

```bash
network-manager modify home --set mdns=true
network-manager modify iotCloud --set mdns=true
module-manager update network
```

- **Discovery only.** Finding a device does not let a client reach it: that is still the
  zone's `access-to` or a module's pinhole. A phone in `home` that discovers a speaker in
  `iotCloud` connects to it only if `home` may reach `iotCloud`.
- **One group.** Every zone in it hears every other; there are no pairs. It takes two zones
  to relay anything.
- **IPv4.** Announcements are relayed over IPv4; the connection that follows may use either
  family.
- **Which zones.** VLAN zones that are not `Management`, `WAN` or `Overlay`; `validate`
  refuses the others.
- **Modules.** A module that needs its own zone discoverable declares `discoveryMdns` (the
  zones that should find it), which adds its zone and those zones to the same group.

The firewall's mDNS repeater carries it, with one rule letting each zone of the group reach
it ([FIREWALL-RULES.md](FIREWALL-RULES.md)). Setting the field back to `false` takes the zone
out at the next network update; with fewer than two zones left the repeater is switched off.

## Zones on a new and an updated site

A fresh install applies **profiles**, not the whole template: `core` (`mgmt`, `wan`, the
overlays, the default service zone, `home`, `guest`, `dmz`) and optionally `iot` (`iotLocal`,
`iotCloud`, `iotCams`, `iotUntrust`). `init` renames `srv` to the site's default environment
and rewrites every reference to it; `home` and `guest` keep their names. Commands:
[network-manager `init`](README.md).

On every update, `network-manager merge` reconciles the site's zones with the new template
by a 3-way merge of `zones.json` (current), `zones.json.orig` (what it was last merged from)
and `zones.rename.json` (the new template with the site's rename applied): a field the site
never changed follows the release, a field it changed is kept; `state` and `serves` are
always the site's. A zone new in the template is added; a zone the site has and the template
dropped is kept with a warning, and removed only by `network-manager retire`, never while a
module still runs in it.

Installed modules stay in their zone: TAPPaaS never moves a running service between zones.
Moving one means backing up, uninstalling and reinstalling it in the target zone.

## Example

```json
{
    "mgmt": {
        "type": "Management", "state": "Manual", "typeId": "0", "subId": "0",
        "vlantag": 0, "ip": "10.0.0.0/24", "bridge": "lan", "tier": 0,
        "access-to": ["internet", "all"],
        "pinhole-allowed-from": [],
        "description": "Control plane: hypervisors, backup, firewall, identity, cicd"
    },
    "warmelo": {
        "type": "Service", "state": "Active", "typeId": "2", "subId": "0",
        "vlantag": 200, "ip": "10.2.0.0/24", "bridge": "lan", "tier": 1,
        "access-to": ["internet", "iotCloud", "iotLocal"],
        "pinhole-allowed-from": ["dmz"],
        "description": "Service zone for the warmelo environment"
    },
    "home": {
        "type": "Client", "state": "Active", "typeId": "3", "subId": "10",
        "vlantag": 310, "ip": "10.3.10.0/24", "bridge": "lan", "tier": 2,
        "serves": "warmelo",
        "access-to": ["internet", "iotCloud", "iotLocal"],
        "pinhole-allowed-from": [],
        "description": "Trusted personal devices: laptops, phones, tablets"
    },
    "iotCams": {
        "type": "IoT", "state": "Active", "typeId": "4", "subId": "30",
        "vlantag": 430, "ip": "10.4.30.0/24", "bridge": "lan", "tier": 6,
        "isolated": true,
        "serves": "warmelo",
        "access-to": [],
        "pinhole-allowed-from": [],
        "description": "Surveillance: cameras + NVR, fully isolated"
    }
}
```

`home` reaches `warmelo` through its `serves` link, and `iotCams` accepts pinholes from
`warmelo` through its own — neither names the service zone. An NVR in `warmelo` reaches the
cameras only through its module's pinhole, never zone-wide.

## WiFi: the `SSID` field

An optional `SSID` is the WiFi network broadcast on the zone's VLAN, used by the WiFi
tooling ([`network/scripts/README.md`](../../../network/scripts/README.md)):
`setup-wlan-secrets.sh` sets the real name and stores the passphrase in a 0600 secrets file
(never in `zones.json`), and `ap-manager` maps each SSID to its zone's VLAN. A zone
without WiFi omits it or sets `null`; the shipped `<PLACEHOLDER>` means "not chosen yet".
Only an `Active` zone broadcasts.
