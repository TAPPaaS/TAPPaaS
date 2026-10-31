# asset-manager

The site's physical assets and where they are (ADR-040 D7–D9). asset-manager owns
`config/positions.json`: the rooms and the location each is in, the racks, where each device
is placed, the **assets** — every physical box with its ports, its life from ordered to
disposed, and the role it plays — and the few cables nothing can see. It changes no device
and no device record: a placement names a device as `network-manager topology` names it — a
node, a switch, an access point, a machine, or a device nothing manages — and only says where
that device stands.

An asset is the thing; its **role** is what it is for the time being: the topology's name for
the node, switch or access point it is allocated to, or for the device nothing manages that it
is (the ISP's modem, a patch panel). A placement and a cable end name the role while there is
one, and the asset's own name when there is none, so a box keeps its rack, its ports and its
cables when its role ends and can take another (`asset release`, `asset allocate`).

`assets{}` is **interim**: ADR-040 step 3 moves the assets, with the rooms, racks, placements
and cables, into the CMDB that cmdb-controller keeps. Its shape is the CMDB's `asset` and
`port` classes' attributes, so that migration is a copy. Until then `positions.json` stays
the record and asset-manager reports all of it to the CMDB ([below](#reports-to-the-cmdb)).

A location is the site's (`site-manager location list`): a room is in one, a rack is in a
room, a device is placed in a rack or loose in a room. A device with no placement is
somewhere at its location; the console lists it under that location.

`position-manager` (ADR-036) and `rack-manager` before it are its old names: both answer the
same verbs for one release (ADR-040 D7, ADR-035 P2). `racks.json` was its file's old name;
migration 0020 renamed it.

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
    "ISP modem": { "room": "basement" },
    "dsk-01": { "in": "srv-01", "bay": "2" }
  },
  "assets": {
    "srv-01": { "kind": "server", "vendor": "HP", "model": "Z840", "serial": "CZC1234ABC", "stage": "placed", "role": "tappaas1", "displayName": "tappaas1",
                "ports": [{ "name": "ilo", "kind": "rj45", "speed": "1g", "role": "bmc", "mac": "aa:bb:cc:00:00:01" }],
                "procurement": { "supplier": "Proshop", "purchaseDate": "2024-03-01", "warrantyUntil": "2027-03-01", "ownership": "owned" } },
    "sw-01": { "kind": "switch", "vendor": "unifi", "model": "unifi/usw-pro-xg-10-poe", "stage": "placed", "role": "USW Pro XG 10 PoE" },
    "srv-02": { "kind": "server", "stage": "stock", "faulty": true, "faultNote": "PSU 2 dead, away for repair" },
    "ISP modem": { "kind": "modem", "model": "generic/isp-modem", "stage": "placed", "role": "ISP modem" },
    "patch1": { "kind": "patch-panel", "ports": [{ "name": "1", "kind": "rj45", "speed": "1g" }, "…"], "displayName": "Patch panel A", "stage": "placed", "role": "patch1" },
    "printer": { "kind": "other", "ports": [{ "name": "eth0", "kind": "rj45", "speed": "1g", "mac": "aa:bb:cc:00:11:22" }], "displayName": "printer-1", "stage": "stock", "role": "printer" },
    "dsk-01": { "kind": "disk", "displayName": "ata-Samsung_SSD_870_EVO_1TB_S6PTNX0R123456A", "vendor": "Samsung", "model": "Samsung SSD 870 EVO 1TB",
                "serial": "S6PTNX0R123456A", "disk": { "kind": "ssd", "bus": "sata", "size": 1000204886016 }, "stage": "placed" }
  },
  "cables": [
    { "from": { "device": "USW Pro XG 10 PoE", "port": "5" }, "to": { "device": "ISP modem", "port": "LAN 1" }, "kind": "uplink", "label": "ISP hand-off" },
    { "from": { "device": "USW Pro XG 10 PoE", "port": "8" }, "to": { "device": "printer", "port": "eth0" }, "kind": "patch", "linkSpeed": "100m" },
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
  in a room: **room**, and no unit or size (its plate gives its size) — or, a disk's, **in**
  another asset (by its own name, never a disk) at its **bay** (the slot label, else the
  disk's by-id name). A disk is placed only so, and nothing else is. A device has at most
  one placement.
- **faceplate** is a catalog key; unset, the view draws the catalog's suggestion for
  the device's model, else a generic plate.
- **assets** are the physical things, keyed by name — a tag per kind (`srv-NN`, `sw-NN`,
  `ap-NN`, `dev-NN`, `dsk-NN`: the next free one when `asset add` or `disk add` is given none)
  or the operator's own. Each has a **kind** (`server`, `switch`, `access-point`, `modem`,
  `ont`, `ups`, `patch-panel`, `pdu`, `other`, `disk`), its records — **vendor**, **model** (a catalog key where the
  catalog has one: its ports then come from the plate), **serial** (unique), **assetTag**,
  **procurement** (`supplier`, `orderRef`, `purchaseDate`, `warrantyUntil`, `ownership`
  owned|rented, `notes`; no prices) and, once gone, **disposal** (`how` sold|recycled|
  returned|lost, `when`, `wiped`) — its **ports** (below), the **location** it is at (unset:
  the primary), its **stage** and its **role**.
- An asset's **stage** is `ordered`, `stock`, `placed` or `disposed` as recorded;
  `operational` is derived from a role and `placed` from a placement, and the verbs keep
  the recorded one in step. **faulty** is a flag beside the stage, with a **faultNote**: a node
  with a failed fan is operational and faulty; a server away for repair is in stock and faulty.
  An ordered or a disposed asset has no placement and no role; a disposed one's record stays.
- An asset's **role** is the name the topology knows it by: a node or a machine (a server's),
  a switch (a switch's), an access point (an AP's), or — for any other kind — a device nothing
  manages, which the asset then is to the topology (its role usually its own name). Every asset
  that is here (not ordered, not disposed) is a device of the topology by its role's name, else
  its own: it can be placed, it is a cable end, the console draws it.
- A **disk** is an asset of its own: the part of a site that fails most, moves between
  machines and is wiped before it leaves. Its **serial** is what knows it — unique across
  the assets, compared without case, spaces and dashes, as tools spell it differently; a
  by-id name changes with the controller and slot and is only its **displayName**. Its
  **disk** record holds its **kind** (`nvme`, `ssd`, `hdd`, `usb`), **bus**, **wwn**, **size**
  (bytes) and **firmware**. It has no ports and plays no role; it is no device of the
  topology. Placed `in` an asset it is `placed`; unplaced it is in stock; `place --in`
  another asset is the move. An asset that holds disks is neither removed nor disposed
  of until they are unplaced or moved: whether each was wiped is the disk's disposal.
- An asset's **ports** belong to it (ADR-040 D9). A port's **kind** names its connector —
  `rj45`, `sfp`, `wifi`, `usb-a`, `usb-c` — and its **speed** is its maximum (`rj45` 1g, 2.5g,
  10g; `sfp` 1g, 10g, 25g; `usb-*` usb2, usb3); a `wifi` port has a **standard** (`wifi5`,
  `wifi6`, `wifi7`) and **bands** (`2.4`, `5`, `6`) instead, an `sfp` cage a **module** (`dac`,
  `sr`, `lr`, `rj45`). **role** (`lan`, `wan`, `bmc`) says what the node uses it for — a BMC is
  an `rj45` port with role `bmc`, with its own **mac**; power, video and serial are no ports. A
  MAC is unique across every port. A patch panel's port may have a **side**, front or rear, when
  it has only one. The ports of an asset's model's plate are its ports; its own entries are
  merged over them by name (a module in a cage, a MAC), and its own the plate lacks follow.
- **cables** are only what nothing can see: the ISP's modem, a device recorded from a
  switch port, a patch panel, a PDU. A cable the switches or LLDP see comes from the
  topology and is never recorded. A device only a cable names is still placed by that
  cable, with its faceplate, and `validate` says how to record it (`asset add`). A cable's
  **linkSpeed** is the speed seen on it — the connection's, where a port's speed is its
  maximum: a 10G cage holding a 1G module is `speed: 10g` with a `1g` link.
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
| `validate [--topology <file>] [--json]` | The whole document: every asset's kind, stage, ports (a speed its connector has, a standard and bands only on wifi, a module only in a cage) and records (serials unique, MACs unique across every port, dates as YYYY-MM-DD), no ordered or disposed asset placed or in a role, a disposed one with its disposal, each role one asset's and one the topology knows (a server's a node or machine, a switch's a switch, an AP's an AP); every placement names a device the topology knows or one recorded here, no two overlap in a rack, each fits its rack, a loose device's room exists, every faceplate key is in the catalog, every cable end names a port the topology, a record or the catalog has, a panel port carries one cable a side; every location a room or a device names is the site's, and a device stands in a room at its own location. It notes a rack's room that is not recorded, a device only a cable names, and a device at a location that has no room (somewhere there, unplaced). |
| `room list\|show [<room>] [--json]` | The rooms, their location, their racks and what stands loose in them. |
| `room add <room> [--location <location>] [--display-name] [--description]` | A new room, at the primary location unless told. |
| `room modify <room> --set <field>=<value>... --unset <field>...` | Its display name, description or location. |
| `room delete <room>` | An empty room (no rack names it, nothing stands loose in it). |
| `asset list [--stage <stage>] [--kind <kind>] [--json]` | Every asset: its kind, stage (operational and placed derived), role, ports and where it is, the faulty ones marked. |
| `asset show <asset> [--json]` | One asset, by its name or the role it plays: its records, ports (its plate's merged with its own), placement, procurement, disposal. |
| `asset add [<asset>] --kind <kind> [--vendor] [--model <vendor/model>] [--serial] [--asset-tag] [--stage ordered\|stock] [--ports <n> \| --port <name>[:<kind>[:<speed>]]...] [--location <location>] [--display-name] [--description] [--supplier] [--order-ref] [--purchase-date] [--warranty-until] [--ownership owned\|rented] [--notes]` | A physical thing, bought (`--stage ordered`) or here (in stock), under its name or the next free tag of its kind. Not a name the topology has: that is a role, which the asset is allocated to. |
| `asset record <switch>:<port>\|<mac> [--name <asset>] --kind <kind> [--port <name>] [--model] [--location] [--display-name] [--description]` | A device a switch port sees and nobody recorded (`network-manager topology` lists it, `source: seen`) becomes an asset playing itself: its MAC on its port (so it is not seen twice), at the switch's location unless told, shown by what LLDP or the lease calls it, and the port's link recorded as its cable to its port (what LLDP says, else its model's first, else `1`). |
| `asset modify <asset> --set <field>=<value>... --unset <field>...` | Its kind, vendor, model, serial, assetTag, display name, description, location, ports (a count or a list, rj45 at 1g), mac (its first port's), faultNote, `procurement.<field>`. |
| `asset receive <asset>` | What was ordered has come: in stock. |
| `asset allocate <asset> --role <name>` | It takes a role: a node or machine (a server), a switch, an access point the topology knows — or, for another kind, a device nothing manages. Its placement and recorded cables move to the role's name. |
| `asset release <asset>` | The role ends: its placement and cables stay with the box, under its own name; it is placed or in stock again. |
| `asset fault <asset> --note <text>` / `asset repaired <asset>` | The faulty flag beside its stage, with what is wrong; cleared. |
| `asset dispose <asset> --how sold\|recycled\|returned\|lost [--wiped] [--when <date>] [--with-disks \| --disks-to-stock]` | It leaves the site; refused while it has a role, a placement or a recorded cable (three acts). The record stays, read-only. One that holds disks needs an answer for them: `--with-disks` takes each disk out and disposes of it the same way (`--how`, `--when`, wiped as `--wiped` says), then the asset; `--disks-to-stock` takes them out into stock first. |
| `asset remove <asset> [--with-disks \| --disks-to-stock]` | A record made by mistake, or a machine that leaves the site: unplaced, no recorded cable, in no role but its own. A disposed asset's record stays. One that holds disks is refused unless told what becomes of them: `--with-disks` removes each disk's recorded cables, placement and record, then the asset's (the machine leaves with its disks); `--disks-to-stock` takes them out first (they stay recorded, in stock, for another asset). |
| `port add <asset> <port> --kind rj45\|sfp\|wifi\|usb-a\|usb-c [--speed] [--standard] [--bands <list>] [--module] [--role lan\|wan\|bmc] [--mac] [--side front\|rear]` | A port of its own: its connector and what goes with it (rj45 is 1g unless told). |
| `port modify <asset> <port> --set <field>=<value>... --unset <field>...` | A port's kind, speed, standard, bands, module, role, mac or side; a port of its model's plate takes an entry of its own, merged over it. |
| `port remove <asset> <port>` | A port of its own no recorded cable uses; one over its plate's goes back to the plate's. |
| `disk list [<asset>] [--json]` | The disks, each in the asset and bay it is in, or in stock. |
| `disk add <asset> <name> --serial <s> [--model] [--vendor] [--wwn] [--size <size>] [--kind nvme\|ssd\|hdd\|usb] [--bus] [--firmware] [--bay] [--description]` | A disk in an asset: the next `dsk-NN`, `<name>` (its by-id name) shown, placed in that asset at `--bay` (default: its name). A serial an asset records already is refused, naming that asset. `--size` is bytes or `960G`, `4TB` (1000s), `4TiB` (1024s). |
| `disk modify <disk> --set <field>=<value>... --unset <field>...` | Its displayName, description, vendor, model, serial (never unset), assetTag, wwn, size, kind, bus, firmware, bay. |
| `disk remove <disk>` | A record made by mistake, with its placement. A disposed disk's record stays. |
| `disk adopt [<asset>]` | Every disk the CMDB's server CIs list (what `site-manager report --discover` found) that no asset records yet, by serial, recorded in that server; the recorded ones and those without a serial are skipped, each said. Once, for the servers there are; `node add` records a new machine's disks itself. |
| `rack list\|show [<rack>] [--json]` | The racks; one rack with what is placed in it. |
| `rack add <rack> [--units 42] [--width 19in\|10in] [--numbering bottom-up\|top-down] [--display-name] [--room] [--description]` | A new rack. |
| `rack modify <rack> --set <field>=<value>... --unset <field>...` | Any field but its name; `--unset` clears a text. |
| `rack delete <rack>` | An empty rack. |
| `place list [--rack <rack>]\|show <device> [--json]` | What is placed where. |
| `place <device> (--rack <rack> --u <n> \| --room <room>) [--height] [--width] [--slot] [--face] [--faceplate] [--label] [--description]` | A device into a rack, or loose into a room. An asset's plate is its model's, or one drawn from its ports. |
| `place <disk> --in <asset> [--bay <bay>]` | A disk into an asset's bay: out of stock, or out of the asset it was in (the move). The bay is the one given, else the one it had there, else its by-id name. |
| `place modify <device> --set <field>=<value>... --unset <field>...` | A move (`rack` and `u`, `slot`, `face`, or `room` — out of the rack, loose in it) or its plate and label; `--unset faceplate` goes back to the suggestion. |
| `unplace <device>` | The device leaves its rack or room, a disk its asset. A passive plate's recorded cables go with it; an asset keeps its own (and is in stock again). |
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
| `export --json --cmdb` | The same as the CMDB would answer it (its objects and relations, with the catalog): the reference for reading the positions from the CMDB. Not used yet. |
| `report [--json]` | Everything the record holds, to the CMDB ([Reports to the CMDB](#reports-to-the-cmdb)); `--json` prints the reports instead. |

`mount add`, `mount modify`, `mount remove`, `mount list` and `mount show` are the old
names of `place`, `place modify`, `unplace`, `place list` and `place show`; `device list`,
`device show`, `device add`, `device modify`, `device remove` and `device record` are the old
names of the `asset` verbs; they answer for one release. A verb that names an asset takes its
name or the role it plays. Placing an asset in stock makes it placed, unplacing it puts it back
in stock; an ordered or disposed asset is not placed.

Every changing verb takes `--check` (one line of what it would change — `[check] would add
room 'stue' at hareskov` — or `[refused] <why>` and exit 1; `--check --json` prints the whole
resulting document; the apply reports the same line, done), locks, checks the
whole resulting document and writes it atomically; a change that would leave it invalid
writes nothing. The verbs that name a device read the topology (`network-manager topology
--json --no-health --no-positions`) unless `--topology <file>` hands one in; when it cannot be
read, device names are not checked and a warning says so. The location checks read
`config/site.json`. `rack delete`, `room delete`, `asset dispose`, `unplace`, `cable
remove`, `port remove` and `faceplate delete` are destructive (the console asks for the name).

A site whose `config/racks.json` the update has not renamed yet is read as it is; a
change is refused until it has been. Likewise a `positions.json` that still records
`devices{}`: each reads as an asset playing itself, and a change waits for migration 0027,
which makes them assets and gives every node, switch and access point one of its own
(`srv-NN`, `sw-NN`, `ap-NN` in the topology's order, the role's name as its display name).

### A box's life

A server bought, racked, made a node, retired and sold (ADR-040 D7's example):

```
asset-manager asset add --kind server --vendor HP --model Z840 --serial CZC1234ABC --stage ordered --supplier Proshop   # srv-07
asset-manager asset receive srv-07
asset-manager port add srv-07 ilo --kind rj45 --role bmc --mac aa:bb:cc:00:00:07
asset-manager place srv-07 --rack rack1 --u 12 --faceplate generic/server-2u
asset-manager asset allocate srv-07 --role tappaas5 --check     # once site-manager has added tappaas5
asset-manager asset allocate srv-07 --role tappaas5             # its placement is tappaas5's now
asset-manager asset fault srv-07 --note "fan 2 failed"          # operational and faulty
asset-manager asset repaired srv-07
asset-manager asset release srv-07                              # the node is gone; the box stays in its rack
asset-manager unplace srv-07
asset-manager asset dispose srv-07 --how sold --wiped
```

### A disk's life

```
asset-manager disk adopt --check                    # the disks the servers' CIs know, once
asset-manager disk add srv-02 ata-HGST_HDN726050ALE614_NAHW317X --serial NAHW317X --kind hdd --size 5TB --bay 3
asset-manager disk list srv-02
asset-manager place dsk-04 --in srv-03              # moved to another server
asset-manager unplace dsk-04                        # pulled: in stock
asset-manager asset dispose dsk-04 --how recycled --wiped
```

A machine with its disks: `asset remove` and `asset dispose` refuse one that holds disks
until told what becomes of them. Each disk is its own step, a line of its own and its own
report to the CMDB (a disk's CI ends before its asset's); the file is written once, and a
refusal anywhere changes nothing:

```
asset-manager asset remove srv-04 --with-disks --check
[check] would remove disk 'dsk-11' (serial S1), in srv-04, bay sda
[check] would remove disk 'dsk-12' (serial S2), in srv-04, bay sdb
[check] would remove asset 'srv-04'
asset-manager asset remove srv-04 --disks-to-stock             # the disks kept, in stock
asset-manager asset dispose srv-04 --how recycled --wiped --with-disks
```

### Recording a device

A cable recorded before devices could be (the ISP's modem, named only on its cable)
keeps working; `validate` points it out. Recording the device keeps the cable as it is:

```
asset-manager asset add 'ISP modem' --kind modem --model generic/isp-modem --check
asset-manager asset add 'ISP modem' --kind modem --model generic/isp-modem
asset-manager place 'ISP modem' --room basement      # or --rack rack1 --u 3
```

A device a switch port sees — a printer, a camera — is listed by the topology at its port
with its MAC and what LLDP or its lease says. One verb records it and its cable:

```
asset-manager asset record 'USW Pro XG 10 PoE:8' --name printer --kind other --check
asset-manager asset record aa:bb:cc:00:11:22 --name printer --kind other
asset-manager place printer --room office
```

## Reports to the CMDB

asset-manager is a CMDB source (ADR-040 D4; `"cmdbSource": true` in `components.json`).
`config/positions.json` is still the record; the CMDB is told what it holds, as
`source: asset-manager`, every object and relation marked `recorded: true`:

| positions.json | CMDB |
|---|---|
| a room | `room`, `at` its location (by name; site-manager reports the location) |
| a rack | `rack`, `placed-in` its room (`room` field); width in inches |
| an asset | its D3 class: `server`; `network-device` (switch, access-point); `appliance` (modem, ont, ups); `passive-device` (patch-panel, pdu); `other-device` — with `deviceType`, vendor, model, serial, assetTag, stage (as derived: `placed`, `operational`), faulty, faultNote, procurement, disposal |
| its ports (its own, merged over its model's plate, else the plate it is placed with) | `port`, `part-of` the asset; kind, speed, standard, bands, module, role, mac, side |
| a disk in an asset | `disk`, `part-of` that asset (its key with the tag, and immutable: a moved disk's CI in the old asset ends and one in the new begins); bay, vendor, model, serial, wwn, size, kind, bus, firmware, assetTag, the by-id name shown, stage, faulty, faultNote, procurement, disposal. A disk in stock has no CI; site-manager adds what the node says of it (health, holds, partitions, and SMART from the sweep) |
| a placement | `placed-in` from the asset to its rack (u, height, width, slot, face, faceplate, label, description on the relation) or its room |
| a recorded cable | `connects` port to port (kind, label, origin, side, linkSpeed) |
| an asset's role | `allocated-to` the node of that name (`{class: node, name}`: the machine, vm or device CI another manager reports) |

```
asset-manager report               # all of it: one batch, and one report per allocation
asset-manager report --json        # the reports, not sent
asset-manager export --json --cmdb # the same, as the CMDB would answer a query for it
```

- **Every verb that writes `positions.json`** (the asset, port, place, cable, room and rack
  verbs) reports what it changed, after writing it: a `change` with the verb, the console's
  job id (`TAPPAAS_JOB_ID`), the actor (`TAPPAAS_ACTOR`, else the OS user), the objects and
  relations that differ and what they name; what it removed is ended (`end: true`). A
  faceplate verb changes nothing the CMDB holds and reports nothing. `--check` reports nothing.
- **Never a gate.** A report cmdb-controller cannot take now is spooled under
  `config/.cmdb-spool/` and replayed by the next report that reaches it (or `cmdb rescan`);
  one it refuses is a warning. The verb is done either way.
- **Allocations go apart**, one report each: the controller refuses a whole batch when a
  reference does not resolve, and the node an asset plays may not be in the CMDB yet. A
  refused allocation is a warning that names the node; the next `asset-manager report`
  sends it again.
- **Not reported** (printed by `report`, listed under `skipped` by `--json`): a room with no
  location while site.json has no primary one; a rack in no recorded room (its placements
  with it); a placement no asset is recorded for; a cable with an end that is no recorded
  asset's port (a node's NIC on a `generic` plate). An asset's own `location` (a location
  of site.json, with no room) has no relation in the metamodel yet.

## The faceplate catalog

`faceplates/<vendor>/<model>.json`, one plate each:

```json
{
  "vendor": "UniFi", "model": "USW Pro XG 10 PoE", "match": ["USWED77"],
  "kind": "switch", "units": 1, "width": "full",
  "ports": "10xpoe:Port {n}+2xsfp+:Port {n}[51-98]",
  "labels": [{ "text": "UniFi", "at": "left" }]
}
```

or, a grid right of the plate's name:

```json
{
  "vendor": "UniFi", "model": "Nano HD", "kind": "ap", "units": 1, "width": "third",
  "rows": [[{ "name": "Port 1", "id": "uplink", "kind": "poe" }]]
}
```

- **rows** are the port rows top to bottom (`null` is a gap), drawn right of the plate's
  name. A plate whose ports have a layout gives **ports**, a port spec, instead (below):
  its ports in groups, each over its share of the plate's width. A port's **name** is the
  controller's ("Port 11", "sfp-sfpplus1"); its **id**, the topology's, is the number of
  "Port N", else the name, unless given. **kind** is how it is drawn — `rj45`, `sfp+`,
  `sfp28`, `poe`, `console` or `power` — and says the asset's port: `rj45` and `poe` an `rj45`
  port at 1g, `sfp+` an `sfp` cage at 10g, `sfp28` one at 25g; a console and a power inlet are
  drawn and are no ports. **speed** gives another (a 10G RJ45: `"speed": "10g"`), one its
  connector comes in.
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
- **items** within a row, a plus between them: `[<n>x]<kind>[-<speed>][@<rows>][:<name>]`, a
  kind `rj45`, `sfp+`, `sfp28`, `poe`, `console`, `power`, or `gap` (an empty place). A speed
  (`1g`, `2.5g`, `10g`, `25g`) is the port's maximum where it is not its kind's — `rj45-2.5g`,
  `poe-10g`, `sfp+-1g` — and one its connector comes in (`rj45-25g` is refused). A kind ending
  in `+` takes its own `+` before the next item: `2xsfp++rj45`.

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
| `10xpoe-10g:Port {n}+2xsfp+:Port {n}[51-98]` | ten 10G PoE RJ45 and two SFP+ cages, over the right half |

### The site's own plates

A site adds a plate for a model the catalog lacks; it is kept in `config/positions.json`
under `faceplates`, keyed `<vendor>/<model>`, and merged over the shipped catalog, so a
placement, an asset's model and a cable end name it as they name a shipped one:

```
asset-manager faceplate add acme/nas-4 --units 2 --ports "4xrj45, 2xsfp+" --kind server --match NAS-4X --check
asset-manager faceplate add acme/nas-4 --units 2 --ports "4xrj45, 2xsfp+" --kind server --match NAS-4X
asset-manager place nas --rack rack1 --u 6 --faceplate acme/nas-4
```

It is checked as a shipped plate is: a broken one is an error and is not drawn. A site
plate of a shipped key replaces the shipped plate for the site, and `validate` says so;
deleting it brings the shipped plate back. The generic plates stay the fallback for a model
neither has. To contribute a plate upstream, `faceplates show <key> --file` prints it as
`faceplates/<vendor>/<model>.json`.

## Lifecycle

`install.sh` / `update.sh` build the flake package and link `asset-manager` (and
`position-manager` and `rack-manager`, its old names, for one release) into `~/bin`; the package carries the
catalog beside the compiled sources. `test.sh` is offline: the unit suite over hrossen's
topology and the CLI against a temp config, its CMDB client pointed at a socket nobody serves
(the reports land in the temp config's spool, where the suite reads them). `test/unit/cmdb.test.ts`
checks `report` over hrossen's positions.json as migration 0027 leaves it against
cmdb-controller's `metamodel/*.json`; what the controller does with it is cmdb-controller's test. `validate.sh` runs `asset-manager validate`.
