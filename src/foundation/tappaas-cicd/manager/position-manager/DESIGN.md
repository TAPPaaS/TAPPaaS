# rack-manager — design

## What it is for

The console's physical view drew the site as cards and links laid out
automatically. An operator who stands in front of the rack wants the rack: the
devices at their units, their ports as they look, the cables port to port.
Nothing in TAPPaaS knew where anything sits, so this manager records only that,
and everything else comes from where it already is.

## Decisions

1. **One new record, nothing copied.** `config/racks.json` holds rooms, racks,
   mounts, the devices and the cables nothing can see. A mount is keyed by the device's name in the
   topology; the device's own record (site.json, the switch inventory, an AP's
   record, a module's config) is never touched or duplicated. A device renamed
   or removed shows as a finding, not as a stale copy.
2. **The topology joins it.** `network-manager topology` reads `rack-manager
   export --json` (the document and the catalog) and carries `racks`: the racks
   with each mount resolved to its device and plate, live port state on every
   plate port, and the cables. The console reads only the topology, as before.
   rack-manager in turn reads the topology to check device and port names
   (`--no-racks`, so the two never recurse).
3. **Cables come from what is seen.** Every switch port with a known far end and
   every node leg LLDP places is a cable, mapped to the plates' ports. racks.json
   records a cable only where nothing can see one: the ISP's modem (the hand-off
   port is known, the modem is not), a patch panel, a PDU. A recorded cable never
   restates a seen one.
4. **A catalog by vendor and model, generic where it lacks one.** A plate is a
   file per model with its port grid as the controller names the ports, so a
   plate port and a topology port meet by name. A node's NICs and an unknown
   switch's ports are not in any catalog: the generic plates are filled from the
   device. The suggestion (model or name against `match`) is what the view draws
   until the operator records a plate.
5. **Positions are the operator's.** Nothing can discover where a device sits;
   a mount is a statement, checked only for fitting and not overlapping (per
   face, per column: a half and a half side by side are fine).
6. **Pure core, thin CLI.** `lib/ts/src/racks.ts` holds the model, the check and
   the view, shared by rack-manager and network-manager; `src/verbs.ts` holds
   each verb as a function from document to document or refusal; `src/main.ts`
   locks, checks the whole result, writes atomically. The unit tests run the
   core over hrossen's captured topology.

## Findings in the topology

- a mount whose device the topology no longer has (`topology` gate, on the rack);
- a device mounted nowhere, once the site has a rack at all (on the device).

7. **What nothing can see is recorded, then it is a device.** A modem, an ONT, a
   UPS or a patch panel has no inventory to come from; `devices` records it with
   its kind and its model's or its own ports. The topology lists it among its
   devices, so a recorded device mounts, cables and draws like any other; a name
   the topology already has cannot be recorded.
8. **Rooms hold racks and loose devices.** A device on a shelf has a room and no
   unit. A rack's room is a reference to a room record; free text from before
   rooms existed is kept and noted until the room is recorded. A room has no
   building of its own: the site's location names it.
9. **A patch panel splits a wire, not a link.** A link through a panel port is two
   recorded segments, front and rear, each marked with the origin of the link they
   replace. The topology chains them back into one link between the two devices
   (with the live state of the link it sees), so the Device view keeps one line
   and the Physical view draws the two wires; `cable join` undoes it.

## What is left out

- Power: a PDU plate has outlets and a `power` cable kind exists, but nothing
  reads outlet state.
- The depth of a device (a full-depth server blocking the rear) is not modelled:
  front and rear are checked separately.
- A link through two panels in a row is chained, but `cable split` adds one panel
  at a time and `cable join` removes one at a time.
