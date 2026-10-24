# position-manager — design

## What it is for

The console's physical view drew the site as cards and links laid out
automatically. An operator who stands in front of the rack wants the rack: the
devices at their units, their ports as they look, the cables port to port. And
a site is rarely one room: a modem in the hall, an access point in the living
room, a satellite in a provider's data centre, a backup buddy's house. Nothing
in TAPPaaS knew where anything stands, so this manager records only that, and
everything else comes from where it already is.

## Decisions

1. **One record, nothing copied.** `config/positions.json` holds rooms, racks,
   placements, the devices and the cables nothing can see. A placement is keyed
   by the device's name in the topology; the device's own record (a pvehost
   instance, the switch configuration, an AP's record, a module's config) is never
   touched or duplicated. A device renamed or removed shows as a finding, not as
   a stale copy.
2. **Where is two things: a location, then a placement.** A location (a building,
   a data centre) is the site's, owned by site-manager. A room is in a location; a
   rack in a room; a device is placed in a rack at its units or loose in a room.
   No other record carries a room, a rack or a unit. A device names its location
   on its own record (a recorded device here); unset, it is at the primary
   location. Its placement's room must be at that location, and a device at a
   location with no room is somewhere there, unplaced.
3. **The topology joins it.** `network-manager topology` reads `position-manager
   export --json` (the document and the catalog) and carries `positions`: the
   locations, their rooms and racks with each placement resolved to its device
   and plate, live port state on every plate port, and the cables; every device
   it lists carries its location, its placement and the record it came from. The
   console reads only the topology. position-manager in turn reads the topology
   to check device and port names (`--no-positions`, so the two never recurse).
4. **Cables come from what is seen.** Every switch port with a known far end and
   every node leg LLDP places is a cable, mapped to the plates' ports.
   positions.json records a cable only where nothing can see one: the ISP's
   modem (the hand-off port is known, the modem is not), a device recorded from
   a switch port, a patch panel, a PDU. A recorded cable never restates a seen one.
5. **A catalog by vendor and model, generic where it lacks one.** A plate is a
   file per model with its port grid as the controller names the ports, so a
   plate port and a topology port meet by name. A node's NICs and an unknown
   switch's ports are not in any catalog: the generic plates are filled from the
   device. The suggestion (model or name against `match`) is what the view draws
   until the operator records a plate. A site adds plates for its own models in
   positions.json (`faceplates`), merged over the shipped catalog by key; the
   check and the topology merge them, so nothing else tells them apart. A
   plate's ports are a grid, or a port spec whose groups stand at their share
   of the plate's width, so a plate can look like the unit's front.
6. **Positions are the operator's.** Nothing can discover where a device stands;
   a placement is a statement, checked only for fitting, not overlapping (per
   face, per column: a half and a half side by side are fine) and being at the
   device's location.
7. **Pure core, thin CLI.** `lib/ts/src/positions.ts` holds the model, the check
   and the view, shared by position-manager and network-manager; `src/verbs.ts`
   holds each verb as a function from document to document or refusal;
   `src/main.ts` locks, checks the whole result, writes atomically. The unit
   tests run the core over hrossen's captured topology.
8. **What nothing manages is recorded, then it is a device.** A modem, an ONT,
   a UPS or a patch panel has no inventory to come from; `devices` records it
   with its kind and its model's or its own ports. The topology lists it among
   its devices, so a recorded device is placed, cabled and drawn like any other;
   a name the topology already has cannot be recorded.
9. **What a switch port sees is one step from a record.** A device behind a port
   that no record names is listed by the topology as seen, with its MAC and what
   LLDP or its lease says, at the switch's location and unplaced. `device record`
   turns it into a recorded device, keeping its MAC (so it is not seen twice) and
   recording the port's link as its cable, since nothing else would draw it.
10. **Rooms hold racks and loose devices.** A device on a shelf has a room and no
    unit; its plate gives its size. A rack's room is a reference to a room
    record; free text from before rooms existed is kept and noted until the room
    is recorded.
11. **A patch panel splits a wire, not a link.** A link through a panel port is
    two recorded segments, front and rear, each marked with the origin of the
    link they replace. The topology chains them back into one link between the
    two devices (with the live state of the link it sees), so the Device view
    keeps one line and the Physical view draws the two wires; `cable join` undoes it.
12. **A rename keeps the old words for a release.** `rack-manager` and the
    `mount` verbs answer as aliases; `racks.json` is read until the update has
    renamed it, and a change waits until it has.

## Findings in the topology

- a placement whose device the topology no longer has (`topology` gate, on the rack);
- a device placed nowhere, at a location that has a room, once the site has a
  rack at all (on the device).

## What is left out

- Power: a PDU plate has outlets and a `power` cable kind exists, but nothing
  reads outlet state.
- The depth of a device (a full-depth server blocking the rear) is not modelled:
  front and rear are checked separately.
- A link through two panels in a row is chained, but `cable split` adds one panel
  at a time and `cable join` removes one at a time.
- Only recorded devices carry a location here; nodes, machines, switches and
  access points get theirs on their own records.
