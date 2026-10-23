# ADR-036 — Locations and Placement

| | |
|---|---|
| **Status** | **Proposed** |
| **Version** | 0.3 |
| **Date** | 2026-10-23 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | Findings 2 and 3 of [`src/DATAMODEL.md`](../../src/DATAMODEL.md) (location recorded in four shapes; devices in three files). Related: #865 (the zone names its environment), ADR-012 §1.5 (a machine's physical location), ADR-026 (machines), ADR-010 §8.4 (the satellite), ADR-034 (the console's Physical view), ADR-035 (a manager's rename and aliases). |
| **Changelog** | v0.3 (2026-10-23) — **D6** the cluster's nodes are their `pvehost` machine instances and `site.hardware.nodes[]` goes, `storagePools` moving to the instance (operator, 2026-10-23); O1 closed; the console decision is D7. · v0.2 (2026-10-23) — **D5** a backup buddy's place is a location of this site, named by the peer record (operator, 2026-10-23); the console decision is D6. · v0.1 (2026-10-23) — first draft, from the operator's direction of 2026-10-23: a device has a location and a placement; site-manager owns locations with a primary one; rack-manager becomes position-manager and owns every placement; devices carry no room or rack field. |

Where a thing is has two parts: the **location** it is at (a place with an address: the site's
building, a provider's data centre, a second house) and its **placement** inside that location (a
room, a rack, a unit in the rack). TAPPaaS records the first in four shapes and the second only for
what stands in a rack. This ADR gives every physical device one location and, where it stands
somewhere, one placement, each owned by one manager.

## Context

Four objects say where something is, each in its own way:

| Object | Field | Shape |
|---|---|---|
| `site.json` | `location` | country, city, building, timezone, locale, keyboard — the site itself |
| `racks.json` (rack-manager) | `rooms{}`, a rack's `room`, a mount's `rack`/`u` or `room` | the building's inside, assumed to be the site's building |
| a machine module (`kind: machine`, e.g. the satellite) | `physicalLocation` | country, city, building — the same shape as the site's, written again |
| `switch-configuration-desired.json` | a switch's or AP's `location` | free text |

And the devices themselves come from three files, joined only by name in the derived topology
(`network-manager topology --json`): the cluster's nodes in `site.hardware.nodes[]`, the switches
and access points in the switch configuration, and the devices nothing manages (a modem, an ONT, a
UPS, a patch panel) as rack-manager's `devices{}`. A device a switch port sees but nobody recorded
(a printer, a camera) is in no file at all.

The consequences show in the console: the Physical view had to assume every room is in the site's
building, a satellite in a provider's data centre has no room to be in, a switch's `location` is a
string no view can draw, and "where does this device stand" is answered differently for each of the
four kinds.

### What a device is

| Kind | Known from | Managed by |
|---|---|---|
| **Machine** | a cluster node (`site.hardware.nodes[]`, Proxmox) or a module instance of kind machine (a satellite, an adopted Debian host; ADR-026) | site-manager, module-manager |
| **Network device** | a switch or an access point in the switch configuration | switch-manager, ap-manager through their controllers |
| **Recorded device** | something a port connects to that nothing manages: a modem, an ONT, a UPS, a patch panel | rack-manager today |
| **Unrecorded device** | something a switch port sees (MAC, LLDP, DHCP lease) that no record names | nobody; shown by the topology at the port |

## Decision

### D1 — A location is an object of the site, owned by site-manager

`site.json` gets `locations{}`: one entry per place the site's devices can be, by name, each with
`displayName`, `country`, `city`, `address` (the street address or the provider and data centre),
and the optional `timezone`. The site's own building is one of them. `site.primaryLocation` names
the location a device is at when it names none, and `site.location` (today's shape) becomes
`locations[<primary>]` by migration, with `locale` and `keyboard` staying site-wide fields (they are
not a place).

site-manager gets `location list/show/add/modify/delete`; a location that a device, room or rack
names cannot be deleted; the primary location cannot be deleted.

### D2 — Every device has a location; it names one of the site's

Each device record carries one optional field, `location`, holding the name of a location. Absent,
the device is at the primary location. The field lives on the record that owns the device:

| Kind | Record | Field |
|---|---|---|
| cluster node | its `pvehost` instance, `<node>.json` (D6) | `location` |
| machine module | `<instance>.json` | `location` (replaces `physicalLocation`; the retired `location` field that once meant the module directory is gone from every installation by migration 0006, so the name is free) |
| switch, access point | `switch-configuration-desired.json` | `location` (was free text; now a location name, validated) |
| recorded device | position-manager's `devices{}` | `location` |

The field is a name, never an address: the address is looked up in site-manager. A satellite is a
machine whose `location` names a location of its own (`hetzner-fsn1`), which is how
`backup-manager validate` keeps checking that an off-site copy is off-site (ADR-012 §1.5).

### D3 — Placement is owned by position-manager, and only by it

rack-manager is renamed **position-manager**, its file `racks.json` becomes `positions.json`, and it
owns every placement:

- `rooms{}`: a room is in a location (`location`, default the primary one).
- `racks{}`: a rack is in a room.
- `placements{}`, keyed by device name: in a rack (`rack`, `u`, `height`, `width`, `slot`, `face`,
  `faceplate`) or loose in a room (`room`, `faceplate`). A device has at most one placement.
- `devices{}`: the recorded devices (D2's fourth kind), with `kind`, `model`, `ports`, `location`.
- `cables[]`: as today, including the segments of a link split at a patch panel.

No device record of another manager carries a room, rack or unit: those are position-manager's.
`validate` refuses a placement whose room's location differs from the device's own `location`, and
reports a device whose location has no room at all (it is somewhere in that location, unplaced).

The verbs: `room`, `rack`, `device`, `cable` as rack-manager has them; `mount` becomes `place
<device> (--rack <rack> --u <n> | --room <room>)`, `mount remove` becomes `unplace`, `mount modify`
becomes `place modify`. The old names answer for one release as aliases, the way ADR-035 P2 aliases
a renamed component, and `racks.json` is renamed by migration.

### D4 — The topology joins the four kinds; nothing else holds a device list

`network-manager topology --json` stays the one read that lists every device, now with `location`
and `placement` on each and a `source` saying which record it came from (`cluster`, `module`,
`switch-configuration`, `recorded`, `seen`). An **unrecorded device** appears from what the switch
controllers see at a port, with its MAC and what LLDP or the DHCP lease says, at the switch's
location and unplaced; `position-manager device record <port-or-mac> --name <n> --kind <k>` turns it
into a recorded device in one step, keeping the port's cable. There is no fifth file: each kind
stays with the manager that knows what it is, and the topology is where they meet.

### D5 — A backup buddy's place is a location too

A backup peer (`remote-<peer>.json`, `pull-`, `receive-`; `backup-manager peer add --country
--city`) records where the other site is so that `backup-manager validate` can tell an off-site copy
from an on-site one. That place becomes a location of this site (`kind: remote`, no rooms of its
own needed), and the peer record names it by `location` instead of carrying `country` and `city`;
`peer add` takes `--location <name>` and still accepts `--country`/`--city`, which then create the
location. Every place this site cares about is then one list in site-manager: its own buildings, its
machines' data centres, its buddies.

### D6 — The cluster's nodes are machines; `site.hardware.nodes[]` goes

Every cluster node is already a module instance of kind machine (`pvehost`: `tappaas1.json` with
its `address`, `uplinks`, `zone0`, `management`). The node list in `site.json` repeats their names
and adds one thing of its own, each node's `storagePools[]`. The list goes: a node is a machine like
any other in the list of installed modules, its `location` is the module's (D2), and `storagePools`
moves to the `pvehost` instance as a field of that module. `site-manager node add/delete` become the
operator's words for `module add pvehost` / `module delete`, so the install flow (`create-site`,
then the first node before any module exists) still reads the same; the pvehost record is written
first, and site.json no longer lists hardware. Readers of `hardware.nodes` (site-manager's
provisioning and reconcile, storage-manager's inventory, health-manager, backup placement, the
cluster's storage reconcile, the topology, the console's Setup) read the pvehost instances instead,
through one helper in `lib/ts`.

### D7 — The console draws locations, then rooms, then racks

The Physical view groups by location (the primary first), each location by its rooms, each room by
its racks and loose devices; a device with a location and no room is listed under the location. The
Overview's thumbnails follow. A satellite shows under its own location with its address from
site-manager. The device panel shows location and placement as two lines, each a link to its object.

## Consequences

- One answer to "where is it": the `location` name on the device, resolved by site-manager, and the
  placement in position-manager. The console, `backup-manager validate` and the topology read the
  same two things.
- `site.hardware` goes with its node list; a node's `storagePools` live on its `pvehost` instance.
- Five fields go: `site.location` (into `locations`), a machine's `physicalLocation`, a switch's or
  AP's free-text `location` (becomes a name), a backup peer's `country` and `city` (become a
  location), rack-manager's building-less rooms (rooms get a location). One manager is renamed; its verbs keep working for a release.
- Every installation is migrated: `site.location` → `locations{primary}`, `racks.json` →
  `positions.json` with `mounts{}` → `placements{}` and rooms given the primary location, machine
  modules' `physicalLocation` → a location added to the site (named from its city) and referenced,
  switch and AP `location` text kept as `description` where it names no location.
- The schemas, `rack-manager`'s README and DESIGN, the console's Physical and Overview pages, the
  Setup wizard's rack step and `src/DATAMODEL.md` change with it.

## Alternatives considered

- **A1 — Keep rack-manager and give rooms a building.** Fixes the satellite case only by adding a
  second place to record addresses; a switch's text location and a machine's `physicalLocation`
  stay as they are. Rejected: three shapes for one thing remain.
- **A2 — One device registry (`devices.json`) owned by position-manager.** Every device of every
  kind in one file, with its location and placement. Clean to read, but it duplicates what the
  cluster, the switch controller and the module records already own, and a node or switch would
  then exist twice with two owners. Rejected in favour of D4: the topology is that registry, derived.
- **A3 — Location as a free-text address on each device.** No lookup, but no two devices would spell
  the same place the same way, and nothing could group by it. Rejected; the name resolves to one
  address.
- **A4 — Placement on the device's own record** (`node.rack`, `switch.rack`). Puts rack units into
  files owned by managers that do not know racks, and leaves a recorded device as the only kind whose
  placement is position-manager's. Rejected: placement has one owner.

## Open questions

- **O1** *(closed by D6, 2026-10-23)* A cluster node is a machine: its `pvehost` instance is the
  record, and `site.hardware.nodes[]` goes.
- **O2** The faceplate catalog is in the source tree; a site cannot add a plate for a device model
  the catalog lacks. Out of scope here; the generic plates cover it.
- **O3** Whether `locale` and `keyboard` should move with the location (a second house in another
  country) or stay site-wide as proposed.

## Implementation plan

1. **Schema and site-manager:** `locations{}`, `primaryLocation`, the `location` verbs, the
   `site.location` migration; `backup-manager validate` reads a machine's and a peer's location
   through site-manager, and the peers' `country`/`city` migrate into locations.
2. **position-manager:** the rename with aliases, `positions.json`, rooms with a location,
   `placements{}` and the `place`/`unplace` verbs, `device record` from a seen device, the
   `racks.json` migration; the topology's `location`, `placement` and `source` on every device.
3. **Device records:** `storagePools` on the `pvehost` instance and `site.hardware` removed by
   migration, every reader moved to the instances; `location` on nodes, machine modules (migrating `physicalLocation`), switches
   and APs; validation that the name exists.
4. **Console:** the Physical view and Overview by location, the device panel's two lines, the Setup
   wizard's step, the forms.
5. **Docs and tests** throughout; `src/DATAMODEL.md` findings 2 and 3 closed.
