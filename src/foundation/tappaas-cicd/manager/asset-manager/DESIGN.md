# asset-manager — design

## What it is for

The console's physical view drew the site as cards and links laid out
automatically. An operator who stands in front of the rack wants the rack: the
devices at their units, their ports as they look, the cables port to port. And
a site is rarely one room: a modem in the hall, an access point in the living
room, a satellite in a provider's data centre, a backup buddy's house. Nothing
in TAPPaaS knew where anything stands, so this manager records only that, and
everything else comes from where it already is.

And a box outlives what it is used for (#906, ADR-040 D7): bought, on the shelf,
racked, a node, retired, a node again under another name, sold. Known only while
it played a role, it vanished between roles and took its rack, its ports and its
cables with it. So the manager that knows where boxes stand — position-manager,
now asset-manager — also knows the boxes: each an **asset** with its ports and a
life of its own, and the role it plays for the time being.

## Decisions

1. **One record, nothing copied.** `config/positions.json` holds rooms, racks,
   placements, the assets and the cables nothing can see. A placement is keyed
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
3. **The topology joins it.** `network-manager topology` reads `asset-manager
   export --json` (the document and the catalog) and carries `positions`: the
   locations, their rooms and racks with each placement resolved to its device
   and plate, live port state on every plate port, and the cables; every device
   it lists carries its location, its placement and the record it came from. The
   console reads only the topology. asset-manager in turn reads the topology
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
   and the view, shared by asset-manager and network-manager; `src/verbs.ts`
   holds each verb as a function from document to document or refusal;
   `src/main.ts` locks, checks the whole result, writes atomically. The unit
   tests run the core over hrossen's captured topology.
8. **Every box is an asset; what it plays is its role (ADR-040 D7).** `assets`
   records each physical thing by a name that never changes — a tag per kind
   (`srv-NN`, `sw-NN`, `ap-NN`, `dev-NN`, O5) or the operator's own — with its
   records (vendor, model, serial, tag, procurement, disposal), its ports and
   its stage. Its role is the topology's name for what it is now: a node or a
   machine, a switch, an access point, or a device nothing manages (a modem, a
   patch panel), which the asset then is to the topology. One role, one asset;
   a server plays a node, a switch a switch, an AP an AP. A placement and a
   cable end keep naming the device as the topology does — the role, while
   there is one; the asset's own name, while there is none — and allocate and
   release move them between the two, so a placement survives its role and the
   topology still joins on names. Every asset that is here (not ordered, not
   disposed) is a device of the topology, so a spare server on a shelf is drawn
   at its location and placed like any other.
9. **Stages are recorded where nothing can see them, derived where something
   can.** `ordered`, `stock` and `disposed` are acts (receive, dispose);
   `placed` follows the placement and `operational` the role, so the view
   derives them and the verbs keep the recorded stage in step. `faulty` is a
   flag beside the stage, with a note: a node is operational and faulty. Ending
   a role, unplacing and disposing are three acts (D8): dispose refuses an asset
   with a role, a placement or a recorded cable, and a disposed record stays.
10. **Ports belong to the asset, named by the connector (ADR-040 D9).** A port's
    kind is what a cable plugs into — `rj45`, `sfp`, `wifi`, `usb-a`, `usb-c` —
    with its speed (its maximum), a Wi-Fi standard and bands, an SFP module, a
    role (`lan`, `wan`, `bmc`) and its MAC; a BMC is an rj45 port with role
    `bmc`. The link a cable negotiates is the cable's `linkSpeed`. A model's
    plate is the template: each plate port is an asset port (`poe-10g` a 10G
    rj45, `sfp+` a 10G cage), the asset's own entries merged over it by name, so
    a module or a MAC is recorded without restating the plate. MACs are unique
    across every port, so a MAC names one asset.
11. **What a switch port sees is one step from a record.** A device behind a port
    that no record names is listed by the topology as seen, with its MAC and what
    LLDP or its lease says, at the switch's location and unplaced. `asset record`
    turns it into an asset playing itself, keeping its MAC on its port (so it is
    not seen twice) and recording the port's link as its cable, since nothing
    else would draw it.
12. **Rooms hold racks and loose devices.** A device on a shelf has a room and no
    unit; its plate gives its size. A rack's room is a reference to a room
    record; free text from before rooms existed is kept and noted until the room
    is recorded.
13. **A patch panel splits a wire, not a link.** A link through a panel port is
    two recorded segments, front and rear, each marked with the origin of the
    link they replace. The topology chains them back into one link between the
    two devices (with the live state of the link it sees), so the Device view
    keeps one line and the Physical view draws the two wires; `cable join` undoes it.
14. **A rename keeps the old words for a release.** `position-manager`,
    `rack-manager`, the `mount` verbs and the `device` verbs answer as aliases;
    `racks.json` is read until migration 0020 has renamed it and `devices{}`
    until migration 0027 has made them assets, and a change waits until each has.
15. **`assets{}` is interim, shaped for the CMDB.** ADR-040 moves the actual
    state into a CMDB kept by cmdb-controller (built on its own branch); this
    half of its step 3 needs none of it. Until the CMDB migration (step 3's
    second half), the assets live in positions.json with exactly the attributes
    of the CMDB's `resource`/`asset` and `port` classes (D3) — kind, vendor,
    model, serial, assetTag, procurement, disposal, stage, faulty, role as
    `allocatedTo`, ports with kind, speed or standard and bands, module, role,
    mac and side — so that migration is a copy, and asset-manager then reports
    them with `source: recorded` instead of writing them here.

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
- Only an asset playing no role, or a device nothing manages, carries the
  location that counts here; nodes, machines, switches and access points get
  theirs on their own records, and their asset's is ignored by the topology.
- `--asset` on the role verbs (`site-manager node add`, `switch-manager
  add-switch`, `ap-manager add`) and the installer's report of a new node's
  serial and MACs (ADR-040 D8) are not built: the role-first path is `asset
  allocate` by hand, or migration 0027 for what exists. The migration matches an
  existing asset by its role only, not yet by serial or MAC.
- Disks are attributes of a server, not assets (ADR-040 O4); history of
  allocations is the CMDB's (D6), not kept here.
