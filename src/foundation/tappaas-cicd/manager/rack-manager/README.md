# rack-manager

Where the site's hardware sits. rack-manager owns `config/racks.json`: the racks,
what is mounted where, and the few cables nothing can see. It changes no device
and no device record: a mount names a device as `network-manager topology` names
it — a node, a switch, an access point, a machine or a device module — and only
says where that device is.

The console's Site › Physical tab draws it as racks with faceplates, the links
the switches and LLDP see drawn port to port, through `network-manager topology`,
which carries the racks resolved against the site.

## The record

`config/racks.json` (schema: [`schemas/racks-fields.json`](../../../schemas/racks-fields.json)):

```json
{
  "version": 1,
  "racks": {
    "rack1": { "units": 42, "width": "19in", "numbering": "bottom-up", "building": "House", "room": "Basement" }
  },
  "mounts": {
    "tappaas1": { "rack": "rack1", "u": 10, "height": 2, "width": "full", "face": "front", "faceplate": "generic/server-2u" },
    "USW Pro XG 10 PoE": { "rack": "rack1", "u": 30, "height": 1, "width": "full", "face": "front", "faceplate": "unifi/usw-pro-xg-10-poe" }
  },
  "cables": [
    { "from": { "device": "USW Pro XG 10 PoE", "port": "5" }, "to": { "device": "ISP modem", "port": "LAN 1", "faceplate": "generic/isp-modem" }, "kind": "uplink", "label": "ISP hand-off" }
  ]
}
```

- **u** is the lowest unit a device takes, as the rack numbers its units; **height**
  is how many it takes. **width** is `full`, `half` or `third` of the rack, with a
  **slot** (its column, 0 at the left) for a half or a third. **face** is `front` or `rear`.
- **faceplate** is a catalog key; unset, the view draws the catalog's suggestion for
  the device's model, else a generic plate.
- **cables** are only what nothing can see: the ISP's modem, a patch panel, a PDU.
  A cable the switches or LLDP see comes from the topology and is never recorded.
  A device only a cable names (the ISP's modem) is placed by that cable, with its faceplate.
- A passive device (a patch panel, a PDU) is mounted under a name of its own with a
  passive faceplate; it needs no device in the topology.

## Verbs

| Verb | Does |
|------|------|
| `validate [--topology <file>] [--json]` | The whole document: every mount names a device the topology knows, no two mounts overlap, each fits its rack, every faceplate key is in the catalog, every cable end names a port the topology or the catalog has. |
| `rack list\|show [<rack>] [--json]` | The racks; one rack with its mounts. |
| `rack add <rack> [--units 42] [--width 19in\|10in] [--numbering bottom-up\|top-down] [--display-name] [--building] [--room] [--description]` | A new rack. |
| `rack modify <rack> --set <field>=<value>... --unset <field>...` | Any field but its name; `--unset` clears a text. |
| `rack delete <rack>` | An empty rack. |
| `mount list [--rack <rack>]\|show <device> [--json]` | What is mounted where. |
| `mount add <device> --rack <rack> --u <n> [--height] [--width] [--slot] [--face] [--faceplate] [--label] [--description]` | A device into a rack. |
| `mount modify <device> --set <field>=<value>... --unset <field>...` | A move (`rack`, `u`, `slot`, `face`) or its plate and label; `--unset faceplate` goes back to the suggestion. |
| `mount remove <device>` | The device leaves the rack. A passive device's recorded cables go with it. |
| `cable list [--json]` | The recorded cables. |
| `cable add --from <device:port> --to <device:port> [--kind patch\|uplink\|power] [--label] [--from-faceplate\|--to-faceplate <key>]` | A cable nothing can see. |
| `cable remove <device:port>` | The recorded cable on that port. |
| `faceplates list [--json]` | The catalog. |
| `faceplates show <vendor/model> [--device <name>] [--json]` | One plate as text, one line per port row; `--device` fills a generic plate from that device's ports, with their live state. |
| `export --json` | The document and the whole catalog: what `network-manager topology` reads. |

Every changing verb takes `--check` (show the result, change nothing), locks, checks the
whole resulting document and writes it atomically; a change that would leave it invalid
writes nothing. The verbs that name a device read the topology (`network-manager topology
--json --no-health --no-racks`) unless `--topology <file>` hands one in; when it cannot be
read, device names are not checked and a warning says so. `rack delete`, `mount remove`
and `cable remove` are destructive (the console asks for the name).

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

- **rows** are the port rows top to bottom (`null` is a gap). A port's **name** is the
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

## Lifecycle

`install.sh` / `update.sh` build the flake package and link `rack-manager` into `~/bin`;
the package carries the catalog beside the compiled sources. `test.sh` is offline: the
unit suite over hrossen's topology and the CLI against a temp config. `validate.sh` runs
`rack-manager validate`.
