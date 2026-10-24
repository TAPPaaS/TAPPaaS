# position-manager

Where the site's hardware is. position-manager owns `config/positions.json`: the rooms
and the location each is in, the racks, where each device is placed, the devices nothing
manages, and the few cables nothing can see. It changes no device and no device record: a
placement names a device as `network-manager topology` names it — a node, a switch, an
access point, a machine, or a device recorded here — and only says where that device stands.

A location is the site's (`site-manager location list`): a room is in one, a rack is in a
room, a device is placed in a rack or loose in a room. A device with no placement is
somewhere at its location; the console lists it under that location.

`rack-manager` is its old name, and `racks.json` its file's: `rack-manager` answers the same
verbs for one release, and the update renames the file (rooms get the primary location,
`mounts` become `placements`).

The console's Site › Physical tab draws it by location, room and rack, with faceplates and the
links the switches and LLDP see drawn port to port, through `network-manager topology`,
which carries the positions resolved against the site.

## The record

`config/positions.json` (schema: [`schemas/positions-fields.json`](../../../schemas/positions-fields.json)):

```json
{
  "version": 1,
  "rooms": {
    "basement": { "displayName": "Basement" },
    "shed": { "displayName": "Shed", "location": "hareskov" }
  },
  "racks": {
    "rack1": { "units": 42, "width": "19in", "numbering": "bottom-up", "room": "basement" }
  },
  "placements": {
    "tappaas1": { "rack": "rack1", "u": 10, "height": 2, "width": "full", "face": "front", "faceplate": "generic/server-2u" },
    "USW Pro XG 10 PoE": { "rack": "rack1", "u": 30, "height": 1, "width": "full", "face": "front", "faceplate": "unifi/usw-pro-xg-10-poe" },
    "patch1": { "rack": "rack1", "u": 32, "height": 1, "width": "full", "face": "front" },
    "ISP modem": { "room": "basement" }
  },
  "devices": {
    "ISP modem": { "kind": "modem", "model": "generic/isp-modem" },
    "patch1": { "kind": "patch-panel", "ports": ["1", "2", "…", "24"], "displayName": "Patch panel A" },
    "printer": { "kind": "other", "ports": ["eth0"], "mac": "aa:bb:cc:00:11:22", "displayName": "printer-1" }
  },
  "cables": [
    { "from": { "device": "USW Pro XG 10 PoE", "port": "5" }, "to": { "device": "ISP modem", "port": "LAN 1" }, "kind": "uplink", "label": "ISP hand-off" },
    { "from": { "device": "USW Pro XG 10 PoE", "port": "8" }, "to": { "device": "printer", "port": "eth0" }, "kind": "patch" },
    { "from": { "device": "USW Pro XG 10 PoE", "port": "2" }, "to": { "device": "patch1", "port": "1", "side": "front" }, "kind": "patch", "origin": "seen" },
    { "from": { "device": "patch1", "port": "1", "side": "rear" }, "to": { "device": "tappaas2", "port": "enp97s0" }, "kind": "patch", "origin": "seen" }
  ]
}
```

- **rooms** are where racks stand and where a device can stand loose. A room's **location**
  names one of the site's locations; unset, it is the primary location.
- A rack's **room** names a room record; text that names no room yet is kept, and
  `validate` notes it.
- A **placement** is in a rack — **rack** and **u**, the lowest unit a device takes as the
  rack numbers its units, **height** the units it takes, **width** `full`, `half` or
  `third` with a **slot** (its column, 0 at the left), **face** `front` or `rear` — or loose
  in a room: **room**, and no unit or size (its plate gives its size). A device has at
  most one placement.
- **faceplate** is a catalog key; unset, the view draws the catalog's suggestion for
  the device's model, else a generic plate.
- **devices** are the devices nothing manages — a modem, an ONT, a UPS, a patch panel, or
  something a switch port saw (`modem`, `ont`, `ups`, `patch-panel`, `other`) — each with its
  catalog **model** or its **ports**, the **location** it is at (unset: the primary) and,
  when a switch port saw it, its **mac**. A recorded device is a device like any other: the
  topology lists it with its kind and ports, the console draws it, it can be placed and it
  is a cable end.
- **cables** are only what nothing can see: the ISP's modem, a device recorded from a
  switch port, a patch panel, a PDU. A cable the switches or LLDP see comes from the
  topology and is never recorded. A device only a cable names is still placed by that
  cable, with its faceplate, and `validate` says how to record it (`device add`).
- A patch panel's port has a **side**: its front (the default) and its rear each take
  one cable. A link split at a panel port (`cable split`) is two recorded segments
  marked with their **origin** — the link the topology sees, or a recorded cable — the
  device port to the panel port's front, the panel port's rear to the far end. The
  topology still carries one link between the two devices, with its segments and the
  panel port it runs through; the Physical view draws the two wires.
- A passive plate nothing records (a PDU) can still be placed under a name of its own
  with a passive faceplate.

## Verbs

| Verb | Does |
|------|------|
| `validate [--topology <file>] [--json]` | The whole document: every placement names a device the topology knows or one recorded here, no two overlap in a rack, each fits its rack, a loose device's room exists, every faceplate key is in the catalog, every cable end names a port the topology, a record or the catalog has, a panel port carries one cable a side; every location a room or a device names is the site's, and a device stands in a room at its own location. It notes a rack's room that is not recorded, a device only a cable names, and a device at a location that has no room (somewhere there, unplaced). |
| `room list\|show [<room>] [--json]` | The rooms, their location, their racks and what stands loose in them. |
| `room add <room> [--location <location>] [--display-name] [--description]` | A new room, at the primary location unless told. |
| `room modify <room> --set <field>=<value>... --unset <field>...` | Its display name, description or location. |
| `room delete <room>` | An empty room (no rack names it, nothing stands loose in it). |
| `device list\|show [<device>] [--json]` | The recorded devices, their ports, location and placement. |
| `device add <device> --kind modem\|ont\|ups\|patch-panel\|other [--model <vendor/model>] [--ports <n> \| --port <name>...] [--location <location>] [--display-name] [--description]` | A device nothing manages. Not a name the topology already has. |
| `device record <switch>:<port>\|<mac> --name <device> --kind <kind> [--port <name>] [--model] [--location] [--display-name] [--description]` | A device a switch port sees and nobody recorded (`network-manager topology` lists it, `source: seen`) becomes a recorded one: its MAC kept, at the switch's location unless told, shown by what LLDP or the lease calls it, and the port's link recorded as its cable to its port (what LLDP says, else its model's first, else `1`). |
| `device modify <device> --set <field>=<value>... --unset <field>...` | Its kind, model, ports (a count or a list), display name, description, location, mac. |
| `device remove <device>` | Once it is unplaced and no recorded cable names it. |
| `rack list\|show [<rack>] [--json]` | The racks; one rack with what is placed in it. |
| `rack add <rack> [--units 42] [--width 19in\|10in] [--numbering bottom-up\|top-down] [--display-name] [--room] [--description]` | A new rack. |
| `rack modify <rack> --set <field>=<value>... --unset <field>...` | Any field but its name; `--unset` clears a text. |
| `rack delete <rack>` | An empty rack. |
| `place list [--rack <rack>]\|show <device> [--json]` | What is placed where. |
| `place <device> (--rack <rack> --u <n> \| --room <room>) [--height] [--width] [--slot] [--face] [--faceplate] [--label] [--description]` | A device into a rack, or loose into a room. A recorded device's plate is its model's or its ports'. |
| `place modify <device> --set <field>=<value>... --unset <field>...` | A move (`rack` and `u`, `slot`, `face`, or `room` — out of the rack, loose in it) or its plate and label; `--unset faceplate` goes back to the suggestion. |
| `unplace <device>` | The device leaves its rack or room. A passive plate's recorded cables go with it; a recorded device keeps its own. |
| `cable list [--json]` | The recorded cables. |
| `cable add --from <device:port> --to <device:port> [--kind patch\|uplink\|power] [--label] [--from-faceplate\|--to-faceplate <key>] [--from-side\|--to-side front\|rear]` | A cable nothing can see; a side on a patch panel's port. |
| `cable remove <device:port> [--side front\|rear]` | The recorded cable on that port (on a panel, that side's). |
| `cable split <device:port> --via <panel:port>` | The link on that port — seen or recorded — through a patch panel port: two recorded segments, the port to the panel port's front, its rear to the far end. The panel port must be free on both sides. |
| `cable join <device:port>` | Undo a split, given the panel port or a device end of a segment: the link is the topology's again, or one recorded cable when it was one. |
| `faceplates list [--json]` | The catalog: the site's own plates first, marked `site`, then the shipped ones. |
| `faceplates show <vendor/model> [--device <name>] [--file] [--json]` | One plate as text, one line per port row; `--device` fills a generic plate from that device's ports, with their live state; `--file` prints it as a catalog file. |
| `faceplate add <vendor/model> --units <n> --ports <spec> [--width full\|half\|third] [--kind] [--passive] [--match <model>]... [--vendor] [--display-name] [--description]` | A plate the site adds for a model the catalog lacks (see [The site's own plates](#the-sites-own-plates)). |
| `faceplate modify <vendor/model> --set <field>=<value>... --unset <field>...` | A site plate's units, width, ports, kind, passive, match, vendor, displayName or description. |
| `faceplate delete <vendor/model>` | A site plate nothing places or records; one that replaced a shipped plate gives way to it. |
| `export --json` | The document and the whole catalog: what `network-manager topology` reads. |

`mount add`, `mount modify`, `mount remove`, `mount list` and `mount show` are the old
names of `place`, `place modify`, `unplace`, `place list` and `place show`; they answer
for one release.

Every changing verb takes `--check` (show the result, change nothing), locks, checks the
whole resulting document and writes it atomically; a change that would leave it invalid
writes nothing. The verbs that name a device read the topology (`network-manager topology
--json --no-health --no-positions`) unless `--topology <file>` hands one in; when it cannot be
read, device names are not checked and a warning says so. The location checks read
`config/site.json`. `rack delete`, `room delete`, `device remove`, `unplace` and `cable
remove` and `faceplate delete` are destructive (the console asks for the name).

A site whose `config/racks.json` the update has not renamed yet is read as it is; a
change is refused until it has been.

### Recording a device

A cable recorded before devices could be (the ISP's modem, named only on its cable)
keeps working; `validate` points it out. Recording the device keeps the cable as it is:

```
position-manager device add 'ISP modem' --kind modem --model generic/isp-modem --check
position-manager device add 'ISP modem' --kind modem --model generic/isp-modem
position-manager place 'ISP modem' --room basement      # or --rack rack1 --u 3
```

A device a switch port sees — a printer, a camera — is listed by the topology at its port
with its MAC and what LLDP or its lease says. One verb records it and its cable:

```
position-manager device record 'USW Pro XG 10 PoE:8' --name printer --kind other --check
position-manager device record aa:bb:cc:00:11:22 --name printer --kind other
position-manager place printer --room office
```

## The faceplate catalog

`faceplates/<vendor>/<model>.json`, one plate each:

```json
{
  "vendor": "UniFi", "model": "USW Pro XG 10 PoE", "match": ["USWED77"],
  "kind": "switch", "units": 1, "width": "full",
  "rows": [
    [{ "name": "Port 1", "kind": "poe" }, …, { "name": "Port 11", "kind": "sfp+" }],
    [{ "name": "Port 2", "kind": "poe" }, …, { "name": "Port 12", "kind": "sfp+" }]
  ],
  "labels": [{ "text": "UniFi", "at": "left" }]
}
```

- **rows** are the port rows top to bottom (`null` is a gap), drawn right of the plate's
  name. A plate whose ports have a layout gives **ports**, a port spec, instead (below):
  its ports in groups, each over its share of the plate's width. A port's **name** is the
  controller's ("Port 11", "sfp-sfpplus1"); its **id**, the topology's, is the number of
  "Port N", else the name, unless given. **kind** is `rj45`, `sfp+`, `sfp28`, `poe`,
  `console` or `power`.
- **match** lists the models and names the inventories report the device by: the catalog's
  suggestion for a device is the plate whose model or match is its model or name.
- **generic** `nics` fills the plate from a node's NICs (its uplinks), `ports` from a
  switch's ports (odd over even). The generic plates are the suggestion for a device the
  catalog lacks: a node gets `generic/server-2u`, a switch `generic/switch-1u`.
- **passive** marks a device nothing can see (patch panel, PDU, modem).

A new model is a new file; `faceplates show <key>` checks it without the console.

### The port spec

How `faceplate add --ports` and a catalog file's **ports** write a plate's ports:

- **groups** stand side by side, a comma between them and a gap between them on the plate;
- **rows** within a group, top to bottom, a slash between them;
- **items** within a row, a plus between them: `[<n>x]<kind>[@<rows>][:<name>]`, a kind
  `rj45`, `sfp+`, `sfp28`, `poe`, `console`, `power`, or `gap` (an empty place). A kind
  ending in `+` takes its own `+` before the next item: `2xsfp++rj45`.

Ports are numbered 1, 2, … unless named; `{n}` in a name is the number that name counts
from 1, and a name without it given to several ports gets the number after it.
`<n>x<kind>@<k>`, alone in its group, lays its ports in k rows, odd over even, as stacked
cages are. A group may end in its place on the plate, `[<from>-<to>]` in percent of its
width — every group, or none: then they stand right of the plate's name, packed to its
right edge.

| Spec | The plate |
|---|---|
| `24xrj45` | 24 ports in one row, 1-24 |
| `8xrj45, 2xsfp+` | eight RJ45, a gap, two SFP+ (9, 10) |
| `8xsfp+/8xsfp+` | two rows of eight, 1-8 over 9-16 |
| `16xsfp+@2:sfp-sfpplus{n}[3-66]` | sixteen cages odd over even, in the left two thirds |
| `rj45:WAN+gap+4xrj45:LAN {n}` | WAN, a gap, LAN 1-4 |

### The site's own plates

A site adds a plate for a model the catalog lacks; it is kept in `config/positions.json`
under `faceplates`, keyed `<vendor>/<model>`, and merged over the shipped catalog, so a
placement, a recorded device's model and a cable end name it as they name a shipped one:

```
position-manager faceplate add acme/nas-4 --units 2 --ports "4xrj45, 2xsfp+" --kind server --match NAS-4X --check
position-manager faceplate add acme/nas-4 --units 2 --ports "4xrj45, 2xsfp+" --kind server --match NAS-4X
position-manager place nas --rack rack1 --u 6 --faceplate acme/nas-4
```

It is checked as a shipped plate is: a broken one is an error and is not drawn. A site
plate of a shipped key replaces the shipped plate for the site, and `validate` says so;
deleting it brings the shipped plate back. The generic plates stay the fallback for a model
neither has. To contribute a plate upstream, `faceplates show <key> --file` prints it as
`faceplates/<vendor>/<model>.json`.

## Lifecycle

`install.sh` / `update.sh` build the flake package and link `position-manager` (and
`rack-manager`, its old name, for one release) into `~/bin`; the package carries the
catalog beside the compiled sources. `test.sh` is offline: the unit suite over hrossen's
topology and the CLI against a temp config. `validate.sh` runs `position-manager validate`.
