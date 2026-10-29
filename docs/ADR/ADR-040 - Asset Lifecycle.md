# ADR-040 — Asset Lifecycle

| | |
|---|---|
| **Status** | **Draft** |
| **Version** | 0.1 |
| **Date** | 2026-10-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | #906. Amends ADR-036 D3 (who owns a placement, and what it is keyed by) and revisits its A2 (one device registry). Related: ADR-022c (Node is ArchiMate's; the physical thing is a Device), ADR-026 (machines as modules), ADR-034 (console), ADR-035 (a manager's rename and aliases), ADR-037 D4 (adding a node: switch port, MAC, boot disks). |
| **Changelog** | v0.1 (2026-10-29) — first draft, from #906. |

A machine is bought, racked, becomes `tappaas3`, is removed from the cluster, sits in the rack
for a month, becomes `tappaas5`, and is finally pulled out and sold. TAPPaaS today knows that box
only while it plays a part: as long as `tappaas3.json` exists. This ADR gives every physical
thing a record of its own, an **asset**, which lives from purchase to disposal, and makes the node,
switch, access point or recorded device a **role** the asset plays for a while.

## Context

ADR-036 gave every device one location and at most one placement. It kept the devices with the
managers that know them and let `network-manager topology` join them (D4), rejecting one stored
device registry (A2), because then a node or switch would exist twice with two owners.

That holds as long as a device always has a part to play. It breaks for the physical thing:

| What happens | What TAPPaaS records today |
|---|---|
| A machine is bought, not yet delivered | nothing |
| It is on the shelf, or racked, but not installed | nothing; a placement needs a name the topology knows, so it can be placed only as a passive plate under an invented name |
| `site-manager node add tappaas3` | `tappaas3.json` (the `pvehost` instance); its placement keyed by `tappaas3` |
| `site-manager node delete tappaas3` | the instance is archived; the placement names a device the topology no longer has, and `validate` complains about a box that is plainly still in rack A |
| The same box becomes `tappaas5` | a new instance; its placement, cables and port facts are entered again |
| A switch is swapped for a new one under the same name | the new switch inherits the old one's placement, cables and history without anyone noticing |
| A printer connects over Wi-Fi | a MAC a controller sees, at the AP's location; nothing records it as a thing |

The facts that belong to the box, not to its part, are spread over the part's records:
`bootDisks` (serials) and `uplinks` (port names) on the `pvehost` instance, the MAC in a switch's
desired config, `mac` and `ports` on a recorded device, the faceplate on a placement. When the part
ends, they go with it.

ArchiMate, which ADR-022c follows, already separates the two: a **Device** is the physical
resource, a **Node** what runs on it. TAPPaaS has names for the node (a `pvehost` instance, a
machine module, a switch in the switch configuration) and none for the device.

## Decision

### D1 — An asset is the physical thing, recorded for its whole life

An **asset** is anything physical the site owns or holds that can stand in a room or a rack: a
server or mini-PC, a switch, an access point, a modem, an ONT, a UPS, a patch panel, a PDU, a
printer, a camera, a disk shelf. Software, guests and modules are not assets; they run on assets.

An asset has:

| Field | Meaning |
|---|---|
| name (the key) | immutable; the operator's tag (`srv-07`) or, when made automatically, derived from the model and serial |
| `kind` | `server`, `switch`, `access-point`, `modem`, `ont`, `ups`, `patch-panel`, `pdu`, `other` (the recorded devices' kinds, widened) |
| `vendor`, `model`, `serial`, `assetTag` | what is on the label; `model` a faceplate catalog key where one exists |
| `stage` | D2 |
| `location`, `placement` | where it is (ADR-036's two parts, now on the asset: D3) |
| `ports[]` | D4 |
| `role` | the record it plays now, if any: `{ "kind": "node", "name": "tappaas3" }` (D5) |
| `procurement` | optional: `supplier`, `orderRef`, `purchaseDate`, `warrantyUntil`, `notes`. No prices; accounting is not TAPPaaS's |
| `history[]` | append-only: date, event, role, the operator or job that did it (D7) |

### D2 — Lifecycle: six stages, two of them derived

| Stage | Means | Set by |
|---|---|---|
| `ordered` | bought, not on site | `asset add --stage ordered` |
| `stock` | on site, at a location, not placed and playing no role | `asset receive`, `unplace` of an asset with no role |
| `placed` | in a room or rack, playing no role: racked and waiting, or a node removed and waiting for reuse | derived: a placement and no role |
| `operational` | playing a role: a node, a machine, a switch, an AP, a recorded device | derived: a role |
| `faulty` | broken or away for repair; keeps its placement and may keep its role | `asset fault` / `asset repaired` |
| `disposed` | gone: sold, recycled, returned. The record stays, read-only, with its history | `asset dispose --how sold\|recycled\|returned\|lost` |

*Decommissioned* is an event, not a stage: when a role ends (`node delete`, `switch remove`, …)
the asset drops back to `placed` (still in its rack) or `stock` (not placed). That is the reuse case
#906 starts from: nothing more has to be done before the box becomes `tappaas5`.

`placed` and `operational` are computed from the placement and the role, so they cannot drift
from the facts; `stage` is stored only for `ordered`, `stock`, `faulty` and `disposed`, which no
other record can show. `validate` refuses an asset that is `disposed` and still has a placement or
a role, and an `ordered` asset that has either.

The stages map onto the common vocabularies (checked 2026-10-29 in each project's source):

| TAPPaaS | NetBox `DeviceStatusChoices` | netbox-inventory Asset | Snipe-IT status type | Ralph DC asset |
|---|---|---|---|---|
| `ordered` | `planned` | (purchase `open`) | `pending` | `new` |
| `stock` | `inventory` | `stored` | `deployable` | `free` |
| `placed` | `staged` | `stored` | `deployable` | `to deploy` |
| `operational` | `active` | `used` | (checked out) | `in use` |
| `faulty` | `failed`, `offline` | – | `undeployable` | `damaged` |
| *role ends* | `decommissioning` | – | – | `cleaned` |
| `disposed` | – (device deleted) | `retired` | `archived` | `liquidated` |

ITIL 4's asset management practice and ISO/IEC 19770-1 fix no stage names; the common reading,
acquire → deploy → operate → retire → dispose, is the same arc. An export (D9) translates.

### D3 — asset-manager replaces position-manager

The physical record has one owner. **position-manager becomes asset-manager**, its
`positions.json` becomes `assets.json`, and it owns the rooms, the racks, the assets (each with
its placement and ports) and the cables nothing can see. ADR-036 D3's rule stays: no record of
another manager carries a room, rack or unit. What changes is what a placement hangs on: **an
asset, not a role's name**. The topology resolves `tappaas3` → its asset → the asset's
placement, so the placement survives the role.

`position-manager`, and `rack-manager` with it, answer as aliases for one release (ADR-035 P2).
The verbs keep their shape with an asset as the object: `place <asset>`, `unplace <asset>`,
`cable add --from <asset:port>`; a role's name is accepted wherever an asset is, resolved through
the role. `device add/record/modify/remove` become `asset add/record/modify/dispose`.

*Alternative kept open (O1):* asset-manager beside position-manager, the asset records only, with
placements staying in `positions.json` re-keyed by asset. Two managers for one physical record,
and every placement verb would have to look the asset up in the other one; the draft prefers one.

### D4 — Ports belong to the asset

An asset's `ports[]` are its physical connectors, each with `name` (the label on the case or the
OS's name: `enp97s0`, `LAN 1`, `port 8`), `kind` (`ethernet`, `sfp`, `wifi`, `bmc`, `usb`,
`power`), `mac` where it has one, `speed`, and for a patch panel its front and rear. A port is
filled from the faceplate catalog for the model, from what the install sees (D5), from the switch
controllers and LLDP, or by hand.

- **Cables** run between asset ports, as today's recorded cables; a cable the switches or LLDP see
  still comes from the topology and is never recorded.
- **Roles name ports, not interfaces.** A node's `uplinks`, a second lan leg, its WAN port
  (ADR-037 D4 `node network set`) name a port of its asset; the MAC is the port's.
- **The BMC is a port** (`kind: bmc`) with its own MAC and cable, so the out-of-band address of a
  node is no longer a fact nobody records.
- **Wi-Fi.** A `wifi` port has no cable; it has a **connection**: the SSID it joins, and so the zone
  that SSID bridges to (ap-manager: one SSID per zone). An access point's controller reports the
  client by MAC, which matches the asset's port; `validate` notes an asset whose Wi-Fi port is seen
  on an SSID of another zone than recorded.
- A MAC is unique across all assets' ports. A DHCP reservation or a pending node registration that
  names a MAC names, through it, an asset.

### D5 — Two ways in, one asset

**Asset first.** `asset add srv-07 --kind server --model hp/z840 --serial …`, then place it and
cable it. `site-manager node add tappaas5 --asset srv-07` installs on it: the switch port and the
MAC that ADR-037 D4 asks for come from the asset's cabled port, and the console's Add node starts
from "which asset" with those fields filled. `module adopt`, `switch-manager add-switch`,
`ap-manager add` and `asset-manager asset record` take `--asset` the same way.

**Role first.** A role added without `--asset` gets one: the installer's hook (ADR-037 D4 already
runs it) reports the DMI vendor, model and serial and every NIC's MAC; a switch's or AP's
controller reports its model, serial and MAC. Before a new asset is made, the facts are matched to
an existing one (D6); with no match, an asset is created at the role's location, named from model
and serial, `stock` → `operational`, and the operator is told so it can be placed.

**Reuse.** A role on an asset that has had one before keeps the asset's placement, ports, cables
and history; only the role changes. `node delete` and the other removal verbs end the role and
leave the asset where it is. Removing the asset from the rack is a separate act (`unplace`), and
so is getting rid of it (`dispose`), which refuses an asset that still has a role.

### D6 — An asset is recognised by serial, then MAC

The match order: `serial` (with vendor), then any port's `mac`, then the operator's word. A
**seen** device (ADR-036 D4: a MAC at a switch port or an AP's client list) whose MAC is an
asset's port is that asset, now at that port; one whose MAC is no asset's stays `seen` until
`asset record` makes it one. Two assets with the same serial, or a MAC on two assets, are refused.

### D7 — History is kept on the asset

Every stage change, role start and end, placement, move and repair appends to `history[]`, from
the verb that did it (job id in the console). The history is the answer to "what was this box
before", and the reason a disposed asset's record stays. Disposal records how, and for an asset
with disks whether they were wiped (`--wiped` / `--disks-removed`), because a sold node with a
`tank` pool on it carries the site's data.

### D8 — What is not an asset

A rented VPS or cloud instance is not physical to the site: it is a machine with a location
(ADR-036) and no asset. A **rented dedicated server** (ADR-037's Hetzner case) is physical but not
the site's: it may be an asset with `procurement.ownership: rented`, never `disposed` but
`returned`. A backup buddy's box belongs to the other site and is not an asset here. Consumables
and parts inside a machine (a disk, a DIMM) are not separate assets in this ADR (O3).

### D9 — Build, adopt, or borrow: borrow the model, keep the data

The candidates, as of 2026-10-29:

| Tool | Licence | Release | Stack | NixOS | Physical asset apart from its role | Racks, ports, cables, Wi-Fi | Purchase, warranty |
|---|---|---|---|---|---|---|---|
| **NetBox** | Apache-2.0 | 4.7.4, 2026-10-27; very active | Django, PostgreSQL, Redis, worker | `services.netbox` | no: a Device needs a type, a **role** and a site; with the **netbox-inventory** plugin (MIT) yes: an Asset `stored`/`used`/`retired`, assigned to a device | yes, the reference model; `WirelessLAN`, `WirelessLink` | only with netbox-inventory |
| **Nautobot** (+ Device Lifecycle Management) | Apache-2.0 | 3.2.8, 2026-10-27 | Django, PostgreSQL/MySQL, Redis, Celery | none | no; DLM tracks end-of-life per model, contracts and CVEs, not units | yes | contracts, not per unit |
| **Snipe-IT** | AGPL-3.0 | 8.8.3, 2026-10-22 | Laravel, MariaDB | `services.snipe-it` | yes, the asset is the record | no | yes |
| **Ralph** | Apache-2.0 | 2026-10-19 | Django, MySQL, Redis | none | yes (data-centre and back-office assets) | racks; ports partly | yes |
| **GLPI** + glpi-agent | GPL-3.0 | 12.0.1, 2026-10-28 | PHP, MariaDB | agent only | yes (CMDB) | yes | yes; the only one that discovers (agent, SNMP) |
| **Infrahub** | Apache-2.0 (community) | 1.11.9 | Neo4j, PostgreSQL, Redis, RabbitMQ | none | by schema | by schema | by schema |
| **Homebox** | AGPL-3.0 | 0.27.1, 2026-10-23 | one Go binary, SQLite | `services.homebox` | yes (home inventory) | no | yes |
| openDCIM, RackTables, i-doit open | GPL / unclear | openDCIM 26.01 after three quiet years; RackTables none since 2022 | PHP, MySQL | none | – | racks, power | – |

What the survey shows: the projects that model racks, ports and cables well (NetBox, Nautobot) tie
the physical box to its role, and the projects that model the box's life (Snipe-IT, Homebox,
netbox-inventory) have no ports or cables, or live as a plugin next to the device. netbox-inventory
draws the line this ADR draws (D1): an asset apart from the device it is assigned to.

**Decision: borrow.** TAPPaaS keeps the asset data in its own JSON, owned by asset-manager, with
NetBox's model for racks, ports, cables and wireless, netbox-inventory's split between asset and role,
and the stage table above. `asset-manager export --netbox` writes NetBox's import format (devices,
interfaces with MACs, cables, the inventory plugin's assets) for an operator who runs NetBox; a
two-way sync is not planned. Adopting a tool as the source of truth fails three of TAPPaaS's own
requirements:

- **The first node registers its own asset** (D5), before any module, database or console exists.
  A tool that runs as a module cannot be the record at that moment.
- **Footprint.** A small site is one mini-PC. NetBox, Nautobot, GLPI and Ralph are a Django or PHP
  application with PostgreSQL or MariaDB and a cache; that is a VM and an upstream to pin and patch
  (ADR-028) to know where a few boxes stand.
- **Every manager reads the physical record** (topology, backup's off-site check, the console, the
  install). Today that is a JSON read through `lib/ts`; through an external API it would become a
  dependency of the control plane on an application.

Only GLPI discovers on its own; TAPPaaS already discovers what it needs through the installer's hook,
the switch and AP controllers and LLDP (D5, D6), so that is no reason to adopt it.

## Consequences

- One answer to "what is this box, and what has it been": its asset. The role says what it does
  now; the asset says what it is, where, how it is cabled and what it has been.
- ADR-036 D3 is amended (the owner is asset-manager; a placement hangs on an asset) and A2 is
  revisited: there is now a stored registry of *physical things*, but not of roles. A node is still
  a `pvehost` instance and a switch still the switch configuration's; the asset is a different
  object, so nothing exists twice with two owners.
- `bootDisks`, a recorded device's `mac` and `ports`, and the port names in `uplinks` move to, or
  point at, the asset.
- A migration (ADR-025) makes an asset for every node, machine module, switch, AP and recorded
  device, keyed from what it knows (serial where a controller or the node gives one), turns
  `positions.json` into `assets.json` and re-keys every placement and cable end on the asset. Names
  that are only a passive plate become assets of kind `other`.
- The console gets an Assets page (stock and ordered first, then by location; an asset's panel
  with its history), "Add node on this asset" and Dispose…; the Physical view draws assets, with
  the role's name as the label when there is one.
- `src/DATAMODEL.md`, the schemas, position-manager's README and DESIGN, `GLOSSARY.md` (Asset,
  Role) change with it.

## Alternatives considered

- **A1 — Keep ADR-036 as it is and add a `stage` to recorded devices.** Nodes, switches and APs
  would still lose their placement with their role. Rejected: it fixes only the box nobody manages.
- **A2 — Adopt NetBox (with netbox-inventory), Nautobot, GLPI or Ralph as the source of truth.**
  See D9: not there at install, a VM and a database for a handful of boxes, and the control plane
  depending on an application's API. NetBox stays the export target.
- **A2b — Offer NetBox as an optional TAPPaaS module** (nixpkgs has `services.netbox`), fed by the
  export. Not rejected, not decided: worth it once a site has more assets than the console shows
  comfortably (O6).
- **A3 — Snipe-IT for the asset side, position-manager for the physical side.** Snipe-IT covers
  purchase, warranty and check-out well but has no racks, ports or cables, so the two halves of one
  box would sit in two systems. Rejected.
- **A4 — Asset fields on the role records** (`serial` on the `pvehost` instance). The facts die
  with the role, which is the problem. Rejected.

## Open questions

- **O1** One manager (D3) or asset-manager beside position-manager.
- **O2** Is `faulty` a stage or a flag next to the stage (a faulty node may still be operational)?
- **O3** Parts inside an asset: are disks worth tracking as assets of their own (they move between
  machines, fail, and must be wiped), or are `bootDisks` and pool members enough?
- **O4** Does health-manager warn about warranties running out, and about an asset `placed` with no
  role for a long time?
- **O5** Naming: the operator's tag, or the role's name by default for assets the migration makes
  (`tappaas3` the asset as well as the node), renamed when the role changes.
- **O6** A NetBox module (A2b), fed by the export: when, if ever.

## Implementation plan

1. Schema `assets-fields.json`; asset-manager with the alias; migration `positions.json` → `assets.json`.
2. Assets for the existing roles (migration), `--asset` on the role verbs, the role ending into
   `placed`/`stock`.
3. The installer's hook and the controllers report serial and MACs; the role-first path (D5, D6).
4. Ports on the asset: uplinks, BMC, Wi-Fi connection; seen devices matched by MAC.
5. Console: Assets page, Add node on an asset, Dispose…, the Physical view on assets.
6. Export to NetBox (D9).
