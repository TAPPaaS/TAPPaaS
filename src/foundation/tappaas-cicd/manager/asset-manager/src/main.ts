// asset-manager — the site's physical assets and where they are (ADR-040 D7,
// ADR-036 D3). Owns config/positions.json: the rooms (each in a location of the
// site), the racks, where each device is placed (keyed by the device's topology
// name; the device's own record is never touched), the assets — each physical
// thing with its ports (D9), its lifecycle from ordered to disposed, and the
// role it plays: a node, a switch, an AP, or a device nothing manages (a
// modem, a patch panel) — and the cables nothing can see. The faceplate catalog
// (faceplates/<vendor>/<model>.json) says what each device looks like; a site
// adds plates for the models it lacks (faceplate add), kept in positions.json
// and merged over it. network-manager's topology carries the result: the racks
// with their placements resolved, the assets, and every link mapped to
// faceplate ports. assets{} is interim, until the CMDB holds them (ADR-040
// step 3).
//
// Every changing verb: lock → change → validate the WHOLE resulting file →
// write atomically. A verb that fails validation writes nothing. --check
// says in one line what the verb would change ("[check] would add room 'stue'
// at hareskov"), or "[refused] <why>" and exit 1; --check --json prints the
// whole resulting document instead. Nothing here touches a device.
//
// position-manager and rack-manager are its old names: the package links them
// beside asset-manager for one release (ADR-035 P2), and they answer the same
// verbs; so do the device verbs, as the asset verbs they became.
//
// Exit codes: ok=0, error=1.

import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { CL, GN, YW, die, guarded, info, requireOperator, warn } from "../../../lib/ts/src/cli";
import { defaultConfigDir, readJsonObject } from "../../../lib/ts/src/config-io";
import { readLocations } from "../../../lib/ts/src/locations";
import {
  Faceplate,
  Placement,
  PositionFinding,
  PositionsDoc,
  SiteDevice,
  SiteLocs,
  checkPositions,
  faceOf,
  findSeen,
  heightOf,
  seenDevices,
  widthOf,
  cablesOf,
  Procurement,
  assetNamed,
  assetPorts,
  assetsOf,
  currentName,
  stageOf,
  roomsOf,
  placeWhere,
  endText,
  recordedPlate,
  placementsOf,
  parseEnd,
  racksOf,
  renderPlate,
  resolvePlate,
  seenCables,
  suggestFaceplate,
  faceplateFile,
  withSiteFaceplates,
} from "../../../lib/ts/src/positions";
import { Store, loadCatalog, readDevices } from "./store";
import { CmdbRefused, CmdbReport, cmdbReport } from "../../../lib/ts/src/cmdb";
import { changeJob } from "../../../lib/ts/src/job";
import { View, changeReport, cmdbAnswer, cmdbView, fullReport } from "./cmdb";
import {
  Result,
  changeLine,
  addAsset,
  addFaceplate,
  addPort,
  allocateAsset,
  deleteFaceplate,
  disposeAsset,
  faultAsset,
  modifyAsset,
  modifyFaceplate,
  modifyPort,
  addCable,
  receiveAsset,
  recordSeen,
  releaseAsset,
  removeAsset,
  removePort,
  repairAsset,
  placeDevice,
  addRack,
  addRoom,
  deleteRack,
  deleteRoom,
  joinCable,
  modifyPlacement,
  modifyRack,
  modifyRoom,
  removeCable,
  unplaceDevice,
  splitCable,
} from "./verbs";

const VERSION = "0.3.0";

const CHECK: [string, string] = ["--check", "Say what would change, in one line; change nothing."];
const CHECK_JSON: [string, string] = ["--json", "With --check: the whole resulting positions.json, for machines."];
const TOPO: [string, string] = ["--topology F", "A `network-manager topology --json` document to check against, instead of running it."];
const JSON_OUT: [string, string] = ["--json", "As JSON."];

export const HELP: HelpSpec = {
  name: "asset-manager",
  version: VERSION,
  tagline: "where the site's hardware is — rooms in the site's locations, racks, placements and the cables nothing can see, in config/positions.json",
  verbs: [
    { usage: "validate [--topology <file>] [--json]", options: [TOPO, ["--json", "The findings as JSON."]], note: "(config/positions.json against the topology, the site's locations and the catalog)" },
    { usage: "rack list [--json]", options: [JSON_OUT] },
    { usage: "rack show <rack> [--json]", options: [JSON_OUT], note: "(the rack and what is placed in it)" },
    {
      usage: "rack add <rack> [--units <n>] [--width 19in|10in] [--numbering bottom-up|top-down] [--display-name <text>] [--room <text>] [--description <text>] [--check]",
      options: [
        ["--units N", "Its height in rack units (default 42)."],
        ["--width W", "19in (default) or 10in."],
        ["--numbering N", "bottom-up (default: U1 at the bottom) or top-down."],
        ["--display-name T", "The name shown on its frame."],
        ["--room T", "The room it stands in (a room record's name; text until the room is recorded)."],
        ["--description T", "What it is for."],
        CHECK, CHECK_JSON,
      ],
    },
    {
      usage: "rack modify <rack> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "displayName, units, width, numbering, room, description (repeatable)."], ["--unset F", "Clear a text field: displayName, room, description (repeatable)."], CHECK, CHECK_JSON],
    },
    { usage: "rack delete <rack> [--check]", options: [CHECK, CHECK_JSON], note: "(an empty rack only)" },
    { usage: "room list [--json]", options: [JSON_OUT], note: "(the rooms, their racks and the devices loose in them)" },
    { usage: "room show <room> [--json]", options: [JSON_OUT], object: { positional: "room" } },
    {
      usage: "room add <room> [--location <location>] [--display-name <text>] [--description <text>] [--check]",
      options: [["--location L", "The location it is in (site-manager location list); unset, the primary location."], ["--display-name T", "The name shown."], ["--description T", "What it is."], CHECK, CHECK_JSON],
    },
    {
      usage: "room modify <room> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "displayName, description, location (repeatable)."], ["--unset F", "Clear one of them; location back to the primary (repeatable)."], CHECK, CHECK_JSON],
      object: { positional: "room" },
    },
    { usage: "room delete <room> [--check]", options: [CHECK, CHECK_JSON], note: "(an empty room only)", object: { positional: "room" } },
    { usage: "place list [--rack <rack>] [--json]", options: [["--rack R", "Only this rack's."], JSON_OUT], aliases: ["mount list"] },
    { usage: "place show <device> [--json]", options: [JSON_OUT], aliases: ["mount show"] },
    {
      usage:
        "place <device> (--rack <rack> --u <n> | --room <room>) [--height <n>] [--width full|half|third] [--slot <n>] [--face front|rear] [--faceplate <vendor/model>] [--label <text>] [--description <text>] [--topology <file>] [--check]",
      options: [
        ["--rack R", "In this rack."],
        ["--u N", "The lowest rack unit it takes, as the rack numbers them."],
        ["--room R", "Loose in this room, in no rack (no --rack, no --u): its plate gives its size."],
        ["--height N", "In a rack: the units it takes (default: its faceplate's, else 1)."],
        ["--width W", "In a rack: full (default), half or third of its width."],
        ["--slot N", "A half or third: its column, 0 at the left."],
        ["--face F", "In a rack: front (default) or rear."],
        ["--faceplate K", "The catalog's plate (faceplates list); unset, the catalog's suggestion for its model."],
        ["--label T", "The label on the device."],
        ["--description T", "A note on where it stands."],
        TOPO,
        CHECK, CHECK_JSON,
      ],
      aliases: ["mount add"],
      object: { positional: "device" },
    },
    {
      usage: "place modify <device> [--set <field>=<value>]... [--unset <field>]... [--topology <file>] [--check]",
      options: [["--set F=V", "rack, u, room, height, width, slot, face, faceplate, label, description (repeatable). A move is rack and u, or room (loose in it)."], ["--unset F", "Clear faceplate (back to the catalog's suggestion), label or description (repeatable)."], TOPO, CHECK, CHECK_JSON],
      aliases: ["mount modify"],
      object: { positional: "device" },
    },
    { usage: "unplace <device> [--check]", options: [CHECK, CHECK_JSON], note: "(the device leaves its rack or room; nothing else changes)", aliases: ["mount remove"], destructive: true, object: { positional: "device" } },
    { usage: "cable list [--json]", options: [JSON_OUT], note: "(the recorded cables; the topology adds the ones it sees)" },
    {
      usage: "cable add --from <device:port> --to <device:port> [--kind patch|uplink|power] [--label <text>] [--link-speed <speed>] [--from-faceplate <vendor/model>] [--to-faceplate <vendor/model>] [--from-side front|rear] [--to-side front|rear] [--topology <file>] [--check]",
      options: [
        ["--from D:P", "One end: a device and its port, as its faceplate or the topology names it."],
        ["--to D:P", "The other end."],
        ["--kind K", "patch (default), uplink or power."],
        ["--label T", "The label on the cable."],
        ["--link-speed S", "The link speed seen on it (100m, 1g, 2.5g, 10g): the connection's, where a port's speed is its maximum."],
        ["--from-faceplate K", "A device only this cable places (the ISP's modem): its faceplate."],
        ["--to-faceplate K", "The same, for the other end."],
        ["--from-side S", "A patch panel's port: front (default) or rear."],
        ["--to-side S", "The same, for the other end."],
        TOPO,
        CHECK, CHECK_JSON,
      ],
    },
    { usage: "cable remove <device:port> [--side front|rear] [--check]", options: [["--side S", "On a patch panel's port: the front (default) or the rear cable."], CHECK, CHECK_JSON], object: { positional: "device:port" } },
    { usage: "asset list [--stage <stage>] [--kind <kind>] [--json]", options: [["--stage S", "Only these: ordered, stock, placed, operational, disposed."], ["--kind K", "Only this kind."], JSON_OUT], note: "(every asset, its stage, role and where it is)", aliases: ["device list"] },
    { usage: "asset show <asset> [--json]", options: [JSON_OUT], object: { positional: "asset" }, aliases: ["device show"] },
    {
      usage:
        "asset add [<asset>] --kind server|switch|access-point|modem|ont|ups|patch-panel|pdu|other [--vendor <text>] [--model <vendor/model>] [--serial <text>] [--asset-tag <text>] [--stage ordered|stock] [--ports <n> | --port <name>[:<kind>[:<speed>]]...] [--location <location>] [--display-name <text>] [--description <text>] [--supplier <text>] [--order-ref <text>] [--purchase-date <date>] [--warranty-until <date>] [--ownership owned|rented] [--notes <text>] [--topology <file>] [--check]",
      options: [
        ["--kind K", "server, switch, access-point, modem, ont, ups, patch-panel, pdu or other."],
        ["--vendor T", "Who made it."],
        ["--model K", "Its plate in the catalog (faceplates list) — its ports come from it — or the model's name."],
        ["--serial T", "Its serial number: unique, the key a controller reports it by."],
        ["--asset-tag T", "The site's own tag on the case."],
        ["--stage S", "ordered (bought, not here yet) or stock (default)."],
        ["--ports N", "Its ports, named 1 to N, rj45 at 1g (a patch panel)."],
        ["--port P", "A port: <name>[:<kind>[:<speed>]] — a kind rj45 (default, 1g), sfp, wifi, usb-a, usb-c (repeatable): WAN, eth1:rj45:2.5g, sfp1:sfp:10g."],
        ["--location L", "The location it is at (site-manager location list); unset, the primary location."],
        ["--display-name T", "The name shown."],
        ["--description T", "What it is, where it comes from."],
        ["--supplier T", "Bought from."],
        ["--order-ref T", "The order or invoice reference."],
        ["--purchase-date D", "Bought on, YYYY-MM-DD."],
        ["--warranty-until D", "Its warranty ends, YYYY-MM-DD."],
        ["--ownership O", "owned or rented."],
        ["--notes T", "Anything else about the purchase."],
        TOPO,
        CHECK, CHECK_JSON,
      ],
      note: "(a physical thing, by its name, else the next free tag of its kind: srv-NN, sw-NN, ap-NN, dev-NN)",
      aliases: ["device add"],
    },
    {
      usage: "asset modify <asset> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "kind, vendor, model, serial, assetTag, displayName, description, location, ports (a count or a comma list), mac (its first port's), faultNote, procurement.supplier|orderRef|purchaseDate|warrantyUntil|ownership|notes (repeatable)."], ["--unset F", "Clear one of them (repeatable)."], CHECK, CHECK_JSON],
      object: { positional: "asset" },
      aliases: ["device modify"],
    },
    { usage: "asset remove <asset> [--check]", options: [CHECK, CHECK_JSON], note: "(a record made by mistake: unplaced, in no role, no recorded cable; a disposed asset's record stays)", object: { positional: "asset" }, aliases: ["device remove"] },
    {
      usage: "asset record <port-or-mac> [--name <asset>] --kind <kind> [--port <name>] [--model <vendor/model>] [--location <location>] [--display-name <text>] [--description <text>] [--topology <file>] [--check]",
      options: [
        ["--name N", "The name it is recorded under (default: the next free tag of its kind)."],
        ["--kind K", "server, switch, access-point, modem, ont, ups, patch-panel, pdu or other."],
        ["--port P", "Its port the cable reaches (default: what LLDP says, else its model's first, else 1)."],
        ["--model K", "Its plate in the catalog (faceplates list)."],
        ["--location L", "The location it is at (default: the switch's)."],
        ["--display-name T", "The name shown (default: what LLDP or the lease calls it)."],
        ["--description T", "What it is."],
        TOPO,
        CHECK, CHECK_JSON,
      ],
      object: { positional: "port-or-mac" },
      note: "(<switch>:<port> or the MAC it is seen by: a device a switch port sees and nobody recorded becomes an asset playing itself, its MAC on its port, with the port's cable)",
      aliases: ["device record"],
    },
    { usage: "asset receive <asset> [--check]", options: [CHECK, CHECK_JSON], note: "(what was ordered has come: ordered → stock)", object: { positional: "asset" } },
    { usage: "asset fault <asset> --note <text> [--check]", options: [["--note T", "What is wrong."], CHECK, CHECK_JSON], note: "(the faulty flag, beside its stage)", object: { positional: "asset" } },
    { usage: "asset repaired <asset> [--check]", options: [CHECK, CHECK_JSON], note: "(the faulty flag and its note cleared)", object: { positional: "asset" } },
    {
      usage: "asset dispose <asset> --how sold|recycled|returned|lost [--wiped] [--when <date>] [--check]",
      options: [["--how H", "sold, recycled, returned or lost."], ["--wiped", "Its disks were wiped."], ["--when D", "When, YYYY-MM-DD (default: today)."], CHECK, CHECK_JSON],
      note: "(it leaves the site; refused while it has a role, a placement or a recorded cable; its record stays)",
      destructive: true,
      object: { positional: "asset" },
    },
    {
      usage: "asset allocate <asset> --role <name> [--topology <file>] [--check]",
      options: [["--role N", "The topology's name for what it plays: a node or machine (a server), a switch, an access point, or a device nothing manages."], TOPO, CHECK, CHECK_JSON],
      note: "(its placement and recorded cables follow it under the role's name)",
      object: { positional: "asset" },
    },
    { usage: "asset release <asset> [--check]", options: [CHECK, CHECK_JSON], note: "(the role ends; its placement and cables stay with the asset, under its own name)", object: { positional: "asset" } },
    {
      usage: "port add <asset> <port> --kind rj45|sfp|wifi|usb-a|usb-c [--speed <speed>] [--standard wifi5|wifi6|wifi7] [--bands <list>] [--module dac|sr|lr|rj45] [--role lan|wan|bmc] [--mac <mac>] [--side front|rear] [--check]",
      options: [
        ["--kind K", "Its connector: rj45, sfp, wifi, usb-a, usb-c."],
        ["--speed S", "Its maximum: rj45 1g (default), 2.5g, 10g; sfp 1g, 10g, 25g; usb usb2, usb3."],
        ["--standard S", "A wifi port's: wifi5, wifi6, wifi7."],
        ["--bands B", "A wifi port's bands, a comma list of 2.4, 5, 6."],
        ["--module M", "What an sfp cage holds: dac, sr, lr, rj45."],
        ["--role R", "What the node uses it for: lan, wan, bmc."],
        ["--mac M", "Its MAC: unique across every port."],
        ["--side S", "A patch panel's port on one side only: front or rear."],
        CHECK, CHECK_JSON,
      ],
      object: { positional: "port", within: ["asset"] },
    },
    {
      usage: "port modify <asset> <port> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "kind, speed, standard, bands, module, role, mac, side (repeatable); a port of its model's plate takes an entry of its own."], ["--unset F", "Clear one but kind (repeatable)."], CHECK, CHECK_JSON],
      object: { positional: "port", within: ["asset"] },
    },
    { usage: "port remove <asset> <port> [--check]", options: [CHECK, CHECK_JSON], note: "(a port of its own no recorded cable uses; one over its plate's goes back to the plate's)", destructive: true, object: { positional: "port", within: ["asset"] } },
    {
      usage: "cable split <device:port> --via <panel:port> [--topology <file>] [--check]",
      options: [["--via P:N", "The patch panel port the link runs through: the device's port to its front, its rear to the far end."], TOPO, CHECK, CHECK_JSON],
      object: { positional: "device:port" },
      note: "(the link on that port, seen or recorded, becomes two recorded segments)",
    },
    { usage: "cable join <device:port> [--check]", options: [CHECK, CHECK_JSON], object: { positional: "device:port" }, note: "(undo a split: a panel port, or a device end of one of its segments)" },
    { usage: "faceplates list [--json]", options: [JSON_OUT], note: "(the shipped catalog and the site's own plates, marked site)" },
    {
      usage: "faceplates show <vendor/model> [--device <name>] [--topology <file>] [--file] [--json]",
      options: [["--device N", "Fill a generic plate from this device's ports, with their live state."], TOPO, ["--file", "The plate as a catalog file, faceplates/<vendor>/<model>.json: how a site's plate goes upstream."], JSON_OUT],
    },
    {
      usage: "faceplate add <vendor/model> --units <n> --ports <spec> [--width full|half|third] [--kind server|switch|ap|patch-panel|pdu|modem|other] [--passive] [--match <model>]... [--vendor <text>] [--display-name <text>] [--description <text>] [--check]",
      options: [
        ["--units N", "Its height in rack units."],
        ["--ports S", "Its ports: groups side by side (a comma between, a gap on the plate), rows within a group (a slash between), items within a row (a plus between): [<n>x]<kind>[@<rows>][:<name>], a kind rj45, sfp+, sfp28, poe, console, power or gap. 24xrj45 · 8xrj45, 2xsfp+ · 8xsfp+/8xsfp+ · 16xsfp+@2 (odd over even) · rj45:WAN+gap+4xrj45:LAN {n}. A group may end in its place in percent of the width: [3-66]."],
        ["--width W", "full (default), half or third of the rack's width."],
        ["--kind K", "What it is (default other): server, switch, ap, patch-panel, pdu, modem, other."],
        ["--passive", "Nothing sees it (a patch panel, a PDU): placed without a topology device."],
        ["--match M", "A model or name an inventory reports it by: the plate is then suggested for it (repeatable)."],
        ["--vendor T", "The vendor as drawn (default: the key's)."],
        ["--display-name T", "The model as drawn (default: the key's)."],
        ["--description T", "What it is."],
        CHECK, CHECK_JSON,
      ],
      note: "(a plate the shipped catalog lacks, in config/positions.json; a shipped key is replaced by the site's plate)",
    },
    {
      usage: "faceplate modify <vendor/model> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "units, width, ports, kind, passive, match (a comma list), vendor, displayName, description (repeatable)."], ["--unset F", "Clear match, vendor, displayName or description (repeatable)."], CHECK, CHECK_JSON],
    },
    { usage: "faceplate delete <vendor/model> [--check]", options: [CHECK, CHECK_JSON], note: "(a site plate nothing uses; one that replaced a shipped plate gives way to it)" },
    {
      usage: "export --json [--cmdb]",
      effect: "read",
      options: [["--json", "The document and the whole catalog, for network-manager topology."], ["--cmdb", "Instead of the document: its objects and relations as the CMDB would answer them (ADR-040), with the catalog."]],
    },
    {
      usage: "report [--json]",
      effect: { noPreview: "the CMDB's record of the rooms, racks, assets, ports, placements, cables and allocations" },
      readWhen: ["--json"],
      options: [["--json", "Print the reports instead of sending them."]],
      note: "(everything config/positions.json records, to cmdb-controller; spooled when it does not answer)",
    },
  ],
  notes: [
    "A placement names a device as `network-manager topology` does. A cable the switches or LLDP see is drawn from the topology and never recorded; record only what nothing can see — the ISP's modem, a patch panel, a PDU.",
    "position-manager and rack-manager are the old names of asset-manager and answer the same verbs for one release; config/racks.json became config/positions.json by migration 0020.",
    "An asset is the physical thing (ADR-040 D7): asset add records it, ordered or in stock; place puts it in a rack or a room; asset allocate gives it a role — a node, a switch, an AP, or a device nothing manages that it is — and its placement and cables follow the role's name; asset release ends the role, asset dispose the asset. faulty is a flag beside the stage (asset fault, asset repaired). A device a switch port sees is recorded by asset record.",
    "A port's kind is its connector (rj45, sfp, wifi, usb-a, usb-c), its speed its maximum; the link a cable negotiates is the cable's link speed. A plate's ports are the asset's, its own merged over them by name (port add, port modify).",
    "A link through a patch panel is split there (cable split): the topology still shows one link, the racks its two wires.",
    "The device verbs are the asset verbs' old names (device add, list, show, modify, remove, record), answering for one release. config/positions.json's devices{} becomes assets{} by migration 0027; a change waits until it has run.",
    "mount add, mount modify and mount remove are the old names of place, place modify and unplace, answering for one release.",
  ],
};

// Print a document as JSON; the verb is done.
function out(v: unknown): number {
  console.log(JSON.stringify(v, null, 2));
  return 0;
}

function opt(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}
function opts(args: string[], name: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) if (args[i] === name && args[i + 1] !== undefined) out.push(args[++i]);
  return out;
}
const VALUED = [
  "--units", "--width", "--numbering", "--display-name", "--room", "--description", "--set", "--rack", "--u", "--height", "--slot",
  "--face", "--faceplate", "--label", "--topology", "--from", "--to", "--kind", "--from-faceplate", "--to-faceplate", "--device", "--unset",
  "--model", "--ports", "--port", "--from-side", "--to-side", "--side", "--via", "--location", "--name", "--match", "--vendor",
  "--serial", "--asset-tag", "--stage", "--role", "--note", "--how", "--when", "--supplier", "--order-ref", "--purchase-date",
  "--warranty-until", "--ownership", "--notes", "--speed", "--standard", "--bands", "--module", "--mac", "--link-speed",
];
function positional(args: string[], skip: number): string[] {
  const out: string[] = [];
  for (let i = skip; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      if (VALUED.includes(args[i])) i++;
      continue;
    }
    out.push(args[i]);
  }
  return out;
}
function intOpt(args: string[], name: string): number | undefined {
  const v = opt(args, name);
  if (v === undefined) return undefined;
  if (!/^\d+$/.test(v)) die(`${name} is a whole number`);
  return Number(v);
}
// --set field=value and --unset field (an empty value: a text cleared).
function sets(args: string[]): Array<[string, string]> {
  const out = opts(args, "--set").map((kv): [string, string] => {
    const i = kv.indexOf("=");
    if (i <= 0) die(`--set ${kv}: write field=value`);
    return [kv.slice(0, i), kv.slice(i + 1)];
  });
  for (const f of opts(args, "--unset")) out.push([f, ""]);
  if (!out.length) die("nothing to change — give --set <field>=<value> or --unset <field>");
  return out;
}

function report(findings: PositionFinding[]): number {
  let errors = 0;
  for (const f of findings) {
    if (f.severity === "error") {
      errors++;
      console.error(`\x1b[01;31m[Error]\x1b[0m ${f.message}`);
    } else warn(f.message);
  }
  return errors;
}

// A warning; under --json on stderr, so stdout stays the document.
let quiet = false;
const note = (m: string): void => (quiet ? console.error(`[Warning] ${m}`) : warn(m));

// The shipped catalog: what the checks merge the site's plates over.
let shipped: Faceplate[] | null = null;
function readShipped(): Faceplate[] {
  if (shipped) return shipped;
  const { catalog, errors } = loadCatalog();
  for (const e of errors) note(`faceplate catalog: ${e}`);
  return (shipped = catalog);
}
// The catalog a verb names plates from: the shipped one with the site's own.
function readCatalog(store: Store): Faceplate[] {
  return withSiteFaceplates(readShipped(), store.load()).catalog;
}

// ── the CMDB (ADR-040 step 3): positions.json stays the record, the CMDB
// is told. A report never fails a verb: lib/ts cmdb.ts spools what it cannot
// deliver; a refusal is a warning.

// The verb being run, for the change it reports.
let verbRun = "";

function viewOf(store: Store, doc: PositionsDoc): View {
  return cmdbView(doc, withSiteFaceplates(readShipped(), doc).catalog, siteLocs(store.configDir)?.primary ?? null);
}

// The console's job and its actor (ADR-040 D6: a change links to its job).
function changeCtx(): { verb: string; job?: string; actor?: string } {
  return { verb: verbRun, ...changeJob() };
}

// Send one report; say what became of it, never throw. An allocation the
// CMDB refuses names a node no manager has reported yet: the next report
// (asset-manager report) sends it again.
function deliver(r: CmdbReport, allocation: boolean): "delivered" | "spooled" | "refused" | "off" {
  try {
    const o = cmdbReport(r);
    return o.off ? "off" : o.delivered ? "delivered" : "spooled";
  } catch (e) {
    const why = e instanceof CmdbRefused ? `${e.message}${Array.isArray(e.body.problems) ? `: ${(e.body.problems as { at: string; error: string }[]).map((p) => `${p.at} ${p.error}`).join("; ")}` : ""}` : (e as Error).message;
    if (allocation) {
      const rel = r.relations?.[0];
      const to = rel && typeof rel.to === "object" ? rel.to.name : "?";
      const from = rel && typeof rel.from === "object" ? rel.from.name : "?";
      note(`the CMDB has no node ${to} yet: ${from}'s allocation to it waits for the next asset-manager report (${why})`);
    } else note(`the CMDB did not take ${verbRun || "the report"} (${why}); config/positions.json has it`);
    return "refused";
  }
}

function reportChange(store: Store, before: View, doc: PositionsDoc): void {
  try {
    const c = changeReport(before, viewOf(store, doc), changeCtx());
    if (c.report) deliver(c.report, false);
    for (const a of c.allocations) deliver(a, true);
  } catch (e) {
    note(`the change was not reported to the CMDB (${(e as Error).message})`);
  }
}

// change — the shared sequence of every changing verb. Devices are read only
// for a verb that names one (a mount, a cable); a rack's own fields need none.
function change(store: Store, check: boolean, devices: SiteDevice[] | null | undefined, fn: (doc: PositionsDoc) => Result): number {
  if (!check && store.legacy) die(`${store.legacy} is still there: migration 0020 makes it config/positions.json (the next update, or scripts/run-migrations.sh) — nothing was changed`);
  if (!check && store.load().devices) die(`config/positions.json still records devices{}: migration 0027 makes them assets{} (the next update, or scripts/run-migrations.sh) — nothing was changed`);
  return store.withLock(() => {
    const before = check ? null : viewOf(store, store.load());
    const r = fn(store.load());
    if ("refused" in r) return check ? refuse(r.refused) : die(r.refused);
    const findings = checkPositions(r.doc, readShipped(), devices ?? null, siteLocs(store.configDir)).filter((f) => devices !== undefined || !f.message.startsWith("the topology could not be read"));
    if (check) {
      // One line: what it would do, or why not (the file's errors, not its warnings).
      const errors = findings.filter((f) => f.severity === "error");
      if (errors.length) return refuse(`config/positions.json would not be valid: ${errors.map((f) => f.message).join("; ")}`);
      if (quiet) return out(r.doc);
      info(`[check] ${changeLine(r, true)}`);
      return 0;
    }
    if (report(findings)) die("config/positions.json would not be valid — nothing was changed");
    store.save(r.doc);
    info(`${GN}✓${CL} ${changeLine(r, false)}`);
    if (before) reportChange(store, before, r.doc);
    return 0;
  });
}

// A dry run's refusal: one line (under --json, {refused}), exit 1.
function refuse(why: string): number {
  if (quiet) console.log(JSON.stringify({ refused: why }, null, 2));
  else info(`[refused] ${why}`);
  return 1;
}

// The site's locations (site.json): what a room's or a device's location may
// name. null when site.json cannot be read: the location checks are skipped.
function siteLocs(configDir: string): SiteLocs | null {
  try {
    const site = readJsonObject(`${configDir}/site.json`);
    if (!site) return null;
    const l = readLocations(site);
    return { names: Object.keys(l.locations), primary: l.primary };
  } catch {
    return null;
  }
}

function devicesFor(args: string[]): SiteDevice[] | null {
  const d = readDevices(opt(args, "--topology"));
  if (d.error) note(`the topology could not be read (${d.error}): the device names are not checked`);
  return d.devices;
}

// The asset a verb names: by its own name, or by the role it plays (what the
// topology and the console call it).
function assetKey(store: Store, name: string): string {
  return assetNamed(store.load(), name)?.key ?? name;
}

function rackRows(doc: PositionsDoc) {
  return Object.entries(racksOf(doc)).map(([name, r]) => ({
    name,
    ...r,
    placements: Object.entries(placementsOf(doc)).filter(([, m]) => m.rack === name).length,
  }));
}

function placementRows(doc: PositionsDoc, rack?: string) {
  return Object.entries(placementsOf(doc))
    .filter(([, m]) => !rack || m.rack === rack)
    // rack by rack, highest first; the loose ones last, by room
    .sort(([, a], [, b]) => Number(!a.rack) - Number(!b.rack) || (a.rack ?? a.room ?? "").localeCompare(b.rack ?? b.room ?? "") || (b.u ?? 0) - (a.u ?? 0))
    .map(([device, m]) => ({ device, ...m }));
}

const where = (m: Placement) =>
  m.rack ? `${placeWhere(m)} ${faceOf(m)}${widthOf(m) === "full" ? "" : ` ${widthOf(m)} slot ${m.slot ?? 0}`}` : placeWhere(m);

// The old verbs, answering for one release: mount add/modify/remove/list/show.
const OLD_VERBS: Record<string, string[]> = {
  "mount add": ["place"],
  "mount modify": ["place", "modify"],
  "mount remove": ["unplace"],
  "mount list": ["place", "list"],
  "mount show": ["place", "show"],
  "device list": ["asset", "list"],
  "device show": ["asset", "show"],
  "device add": ["asset", "add"],
  "device modify": ["asset", "modify"],
  "device remove": ["asset", "remove"],
  "device record": ["asset", "record"],
};

export function run(argv: string[]): number {
  const old = OLD_VERBS[argv.slice(0, 2).join(" ")];
  const args = old ? [...old, ...argv.slice(2)] : argv;
  if (args.length === 0 || args[0] === "help" || ((args[0] === "--help" || args[0] === "-h") && !args.includes("--json"))) {
    info(renderHelp(HELP));
    return 0;
  }
  if (args[0] === "--version" || args[0] === "version") {
    info(`asset-manager ${VERSION}`);
    return 0;
  }
  const rc = checkArgs(HELP, args);
  if (rc !== undefined) return rc;
  const store = new Store(defaultConfigDir());
  const check = args.includes("--check");
  const json = args.includes("--json");
  quiet = json;
  // place <device> and unplace <device> are one word; every other verb two.
  const one = (args[0] === "place" && !["list", "show", "modify"].includes(args[1] ?? "")) || args[0] === "unplace";
  const verb = one ? args[0] : args.slice(0, 2).join(" ");
  verbRun = verb;

  if (args[0] === "validate") {
    const findings = checkPositions(store.load(), readShipped(), devicesFor(args), siteLocs(store.configDir));
    if (json) {
      console.log(JSON.stringify({ valid: !findings.some((f) => f.severity === "error"), findings }, null, 2));
      return findings.some((f) => f.severity === "error") ? 1 : 0;
    }
    if (report(findings)) return 1;
    const d = store.load();
    info(`${GN}✓${CL} config/positions.json valid (${Object.keys(racksOf(d)).length} rack(s), ${Object.keys(placementsOf(d)).length} placement(s), ${Object.keys(assetsOf(d)).length} asset(s), ${cablesOf(d).length} recorded cable(s))`);
    return 0;
  }
  if (args[0] === "export") {
    // The catalog with the site's plates: what the topology draws with.
    const { catalog, errors } = loadCatalog();
    const doc = store.load();
    const merged = withSiteFaceplates(catalog, doc);
    if (args.includes("--cmdb")) {
      // What the topology would read from the CMDB once it is the record
      // (positionsFromCmdb turns it back into a document); not wired yet.
      const v = cmdbView(doc, merged.catalog, siteLocs(store.configDir)?.primary ?? null);
      console.log(JSON.stringify({ ...cmdbAnswer(v), skipped: v.skipped, catalog: merged.catalog, catalogErrors: [...errors, ...merged.findings.filter((f) => f.severity === "error").map((f) => f.message)] }, null, 2));
      return 0;
    }
    console.log(JSON.stringify({ doc, catalog: merged.catalog, catalogErrors: [...errors, ...merged.findings.filter((f) => f.severity === "error").map((f) => f.message)] }, null, 2));
    return 0;
  }

  if (verb === "rack list") {
    const rows = rackRows(store.load());
    if (json) return out(rows);
    if (!rows.length) info("no racks (rack add <name>)");
    for (const r of rows) info(`${GN}${r.name}${CL}  ${r.units}U ${r.width} ${r.numbering}  ${r.room ?? "-"}  ${r.placements} device(s)${r.displayName ? `  "${r.displayName}"` : ""}`);
    return 0;
  }
  if (verb === "rack show") {
    const [name] = positional(args, 2);
    if (!name) die("rack show <rack>");
    const d = store.load();
    const r = racksOf(d)[name] ?? die(`rack ${name} does not exist`);
    const mounts = placementRows(d, name);
    if (json) return out({ name, ...r, placements: mounts });
    info(`${GN}${name}${CL}${r.displayName ? ` "${r.displayName}"` : ""}  ${r.units}U ${r.width}, numbered ${r.numbering}${r.room ? `  in ${r.room}` : ""}`);
    if (r.description) info(`  ${r.description}`);
    for (const m of mounts) info(`  U${String(m.u).padStart(2)}${heightOf(m) > 1 ? `-${(m.u ?? 0) + heightOf(m) - 1}` : "   "}  ${m.device.padEnd(24)} ${faceOf(m)}${widthOf(m) === "full" ? "" : ` ${widthOf(m)}/${m.slot ?? 0}`}  ${m.faceplate ?? "(suggested plate)"}${m.label ? `  "${m.label}"` : ""}`);
    if (!mounts.length) info("  (empty)");
    return 0;
  }
  if (verb === "place list") {
    const rows = placementRows(store.load(), opt(args, "--rack"));
    if (json) return out(rows);
    if (!rows.length) info("nothing placed (place <device> --rack <rack> --u <n> | --room <room>)");
    for (const m of rows) info(`${m.device.padEnd(24)} ${where(m)}  ${m.faceplate ?? "-"}${m.description ? `  ${YW}${m.description}${CL}` : ""}`);
    return 0;
  }
  if (verb === "place show") {
    const [device] = positional(args, 2);
    if (!device) die("place show <device>");
    const m = placementsOf(store.load())[device] ?? die(`${device} is placed nowhere`);
    if (json) return out({ device, ...m });
    info(`${GN}${device}${CL}  ${where(m)}${m.rack ? `  ${heightOf(m)}U` : ""}${m.faceplate ? `  faceplate ${m.faceplate}` : ""}${m.label ? `  label "${m.label}"` : ""}`);
    if (m.description) info(`  ${m.description}`);
    return 0;
  }
  if (verb === "cable list") {
    const cables = cablesOf(store.load());
    if (json) return out(cables);
    if (!cables.length) info("no recorded cables (the topology draws the ones it sees)");
    for (const c of cables) info(`${endText(c.from)} — ${endText(c.to)}  ${c.kind}${c.label ? `  "${c.label}"` : ""}`);
    return 0;
  }
  if (verb === "room list" || verb === "room show") {
    const d = store.load();
    const rows = Object.entries(roomsOf(d)).map(([name, r]) => ({
      name,
      ...r,
      racks: Object.entries(racksOf(d)).filter(([, x]) => x.room === name).map(([n]) => n),
      loose: Object.entries(placementsOf(d)).filter(([, m]) => !m.rack && m.room === name).map(([n]) => n),
    }));
    if (verb === "room show") {
      const [name] = positional(args, 2);
      if (!name) die("room show <room>");
      const r = rows.find((x) => x.name === name) ?? die(`room ${name} does not exist`);
      if (json) return out(r);
      info(`${GN}${r.name}${CL}${r.displayName ? ` "${r.displayName}"` : ""}`);
      info(`  racks: ${r.racks.join(", ") || "-"} · loose: ${r.loose.join(", ") || "-"}`);
      if (r.description) info(`  ${r.description}`);
      return 0;
    }
    if (json) return out(rows);
    if (!rows.length) info("no rooms (room add <name>)");
    for (const r of rows) info(`${r.name.padEnd(20)} ${r.racks.length} rack(s), ${r.loose.length} loose${r.displayName ? `  "${r.displayName}"` : ""}`);
    return 0;
  }
  if (verb === "asset list" || verb === "asset show") {
    const d = store.load();
    const catalog = readCatalog(store);
    const rows = Object.entries(assetsOf(d)).map(([name, a]) => {
      const at = currentName(name, a);
      return {
        name,
        ...a,
        stage: stageOf(d, name, a),
        ports: assetPorts(a, catalog),
        plate: recordedPlate(at, a, catalog).key,
        placed: placementsOf(d)[at] ? where(placementsOf(d)[at]) : null,
        cables: cablesOf(d).filter((c) => c.from.device === at || c.to.device === at).length,
      };
    });
    if (verb === "asset show") {
      const [name] = positional(args, 2);
      if (!name) die("asset show <asset>");
      // An asset by its own name, or by the role it plays.
      const r = rows.find((x) => x.name === name) ?? rows.find((x) => x.role === name) ?? die(`asset ${name} is not recorded`);
      if (json) return out(r);
      info(`${GN}${r.name}${CL}  ${r.kind}  ${r.stage}${r.faulty ? `  ${YW}faulty${r.faultNote ? `: ${r.faultNote}` : ""}${CL}` : ""}${r.displayName ? `  "${r.displayName}"` : ""}`);
      info(`  role: ${r.role ?? "none"} · placed: ${r.placed ?? "nowhere"} · location ${r.location ?? "the primary"} · ${r.cables} recorded cable(s)`);
      const rec = [r.vendor, r.model, r.serial ? `serial ${r.serial}` : null, r.assetTag ? `tag ${r.assetTag}` : null].filter(Boolean).join(" · ");
      if (rec) info(`  ${rec}`);
      info(`  ports: ${r.ports.map((p) => `${p.name} (${[p.kind, p.speed, p.standard, p.bands?.join("/"), p.module, p.role, p.mac, p.side].filter(Boolean).join(" ")})`).join(", ") || "-"}`);
      if (r.procurement) info(`  procurement: ${Object.entries(r.procurement).map(([k, v]) => `${k} ${v}`).join(" · ")}`);
      if (r.disposal) info(`  disposal: ${r.disposal.how}${r.disposal.when ? ` ${r.disposal.when}` : ""}${r.disposal.wiped ? ", disks wiped" : ""}`);
      if (r.description) info(`  ${r.description}`);
      return 0;
    }
    const stage = opt(args, "--stage");
    const kind = opt(args, "--kind");
    const shown = rows.filter((r) => (!stage || r.stage === stage) && (!kind || r.kind === kind));
    if (json) return out(shown);
    if (!shown.length) info(rows.length ? "no asset matches" : "no assets (asset add --kind …)");
    for (const r of shown) info(`${r.name.padEnd(24)} ${r.kind.padEnd(13)} ${r.stage.padEnd(12)} ${(r.role ?? "-").padEnd(20)} ${String(r.ports.length).padStart(2)} port(s)  ${r.placed ?? "placed nowhere"}${r.faulty ? `  ${YW}faulty${CL}` : ""}`);
    return 0;
  }
  if (verb === "faceplates list") {
    const { catalog: base, errors } = loadCatalog();
    const merged = withSiteFaceplates(base, store.load());
    // The site's own first: they are what a site adds for its own models.
    const catalog = [...merged.catalog.filter((f) => f.site), ...merged.catalog.filter((f) => !f.site)];
    if (json)
      return out(catalog.map((f) => ({ key: f.key, vendor: f.vendor, model: f.model, kind: f.kind, units: f.units, width: f.width, passive: f.passive === true, generic: f.generic ?? null, match: f.match ?? [], ports: f.rows.flat().filter(Boolean).length, site: f.site === true, overrides: f.overrides === true, spec: f.ports ?? null, description: f.description ?? null })));
    for (const e of errors) note(e);
    for (const f of merged.findings) (f.severity === "error" ? note : info)(f.message);
    for (const f of catalog) info(`${f.key.padEnd(34)} ${f.kind.padEnd(12)} ${f.units}U ${f.width.padEnd(6)} ${f.generic ? `filled from the device's ${f.generic}` : `${f.rows.flat().filter(Boolean).length} port(s)`}${f.passive ? "  passive" : ""}${f.site ? `  ${GN}site${CL}${f.overrides ? " (replaces the shipped plate)" : ""}` : ""}`);
    return 0;
  }
  if (verb === "faceplates show") {
    const [key] = positional(args, 2);
    if (!key) die("faceplates show <vendor/model>");
    const catalog = readCatalog(store);
    const f = catalog.find((x) => x.key === key) ?? die(`faceplate ${key} is not in the catalog (faceplates list)`);
    if (args.includes("--file")) return out(faceplateFile(f));
    const name = opt(args, "--device");
    let dev: SiteDevice | null = null;
    if (name) {
      const devices = devicesFor(args);
      dev = devices?.find((d) => d.name === name) ?? die(`the topology has no device '${name}'`);
    }
    const plate = resolvePlate(f, dev);
    if (json) return out(plate);
    for (const l of renderPlate(plate)) info(l);
    if (f.ports) info(`  ports: ${f.ports}${f.site ? `  (the site's own${f.overrides ? ", in place of the shipped plate" : ""})` : ""}`);
    if (dev) info(`  (the catalog suggests ${suggestFaceplate(catalog, dev) ?? "no plate"} for ${dev.name})`);
    return 0;
  }

  requireOperator();
  if (args[0] === "report") {
    const doc = store.load();
    if (doc.devices) die("config/positions.json still records devices{}: migration 0027 makes them assets{} (the next update, or scripts/run-migrations.sh) — nothing was reported");
    const v = viewOf(store, doc);
    const r = fullReport(v);
    if (json) return out({ ...r, skipped: v.skipped });
    for (const s of v.skipped) note(`not reported: ${s}`);
    const main = deliver(r.report, false);
    if (main === "refused") return 1;
    if (main === "off") {
      info("TAPPAAS_CMDB=off: nothing reported");
      return 0;
    }
    const outcome = r.allocations.map((a) => deliver(a, true));
    const n = (o: string) => outcome.filter((x) => x === o).length;
    info(
      `${main === "delivered" ? `${GN}✓${CL} reported to the CMDB` : `${YW}spooled${CL} (cmdb-controller did not answer; the next report replays it)`}: ` +
        `${v.objects.filter((o) => o.class !== "location").length} object(s), ${v.relations.length} relation(s), ` +
        `${r.allocations.length} allocation(s)${n("refused") ? ` (${n("refused")} waiting for their node)` : ""}`,
    );
    return 0;
  }
  if (verb === "faceplate add") {
    const [key] = positional(args, 2);
    if (!key) die("faceplate add <vendor/model> --units <n> --ports <spec>");
    const catalog = readCatalog(store);
    return change(store, check, undefined, (d) =>
      addFaceplate(d, key, {
        units: intOpt(args, "--units"),
        ports: opt(args, "--ports"),
        width: opt(args, "--width"),
        kind: opt(args, "--kind"),
        passive: args.includes("--passive"),
        match: opts(args, "--match"),
        vendor: opt(args, "--vendor"),
        displayName: opt(args, "--display-name"),
        description: opt(args, "--description"),
      }, catalog),
    );
  }
  if (verb === "faceplate modify") {
    const [key] = positional(args, 2);
    if (!key) die("faceplate modify <vendor/model> --set <field>=<value>...");
    const s = sets(args);
    return change(store, check, undefined, (d) => modifyFaceplate(d, key, s));
  }
  if (verb === "faceplate delete") {
    const [key] = positional(args, 2);
    if (!key) die("faceplate delete <vendor/model>");
    const catalog = readShipped();
    return change(store, check, undefined, (d) => deleteFaceplate(d, key, catalog));
  }
  if (verb === "rack add") {
    const [name] = positional(args, 2);
    if (!name) die("rack add <rack>");
    return change(store, check, undefined, (d) =>
      addRack(d, name, {
        units: intOpt(args, "--units"),
        width: opt(args, "--width"),
        numbering: opt(args, "--numbering"),
        displayName: opt(args, "--display-name"),
        room: opt(args, "--room"),
        description: opt(args, "--description"),
      }),
    );
  }
  if (verb === "rack modify") {
    const [name] = positional(args, 2);
    if (!name) die("rack modify <rack> --set <field>=<value>... --unset <field>...");
    const s = sets(args);
    return change(store, check, undefined, (d) => modifyRack(d, name, s));
  }
  if (verb === "rack delete") {
    const [name] = positional(args, 2);
    if (!name) die("rack delete <rack>");
    return change(store, check, undefined, (d) => deleteRack(d, name));
  }
  if (verb === "room add") {
    const [name] = positional(args, 2);
    if (!name) die("room add <room>");
    const primary = siteLocs(store.configDir)?.primary ?? null;
    return change(store, check, undefined, (d) => addRoom(d, name, { location: opt(args, "--location"), displayName: opt(args, "--display-name"), description: opt(args, "--description") }, primary));
  }
  if (verb === "room modify") {
    const [name] = positional(args, 2);
    if (!name) die("room modify <room> --set <field>=<value>...");
    const s = sets(args);
    return change(store, check, undefined, (d) => modifyRoom(d, name, s));
  }
  if (verb === "room delete") {
    const [name] = positional(args, 2);
    if (!name) die("room delete <room>");
    return change(store, check, undefined, (d) => deleteRoom(d, name));
  }
  if (verb === "asset add") {
    const [name] = positional(args, 2);
    const catalog = readCatalog(store);
    const devices = devicesFor(args);
    const seen = devices ? devices.filter((x) => !x.recorded).map((x) => x.name) : null;
    return change(store, check, devices, (d) =>
      addAsset(d, name, {
        kind: opt(args, "--kind"),
        vendor: opt(args, "--vendor"),
        model: opt(args, "--model"),
        serial: opt(args, "--serial"),
        assetTag: opt(args, "--asset-tag"),
        stage: opt(args, "--stage"),
        ports: intOpt(args, "--ports"),
        port: opts(args, "--port"),
        displayName: opt(args, "--display-name"),
        description: opt(args, "--description"),
        location: opt(args, "--location"),
        procurement: {
          supplier: opt(args, "--supplier"),
          orderRef: opt(args, "--order-ref"),
          purchaseDate: opt(args, "--purchase-date"),
          warrantyUntil: opt(args, "--warranty-until"),
          ownership: opt(args, "--ownership") as Procurement["ownership"],
          notes: opt(args, "--notes"),
        },
      }, catalog, seen),
    );
  }
  if (verb === "asset modify") {
    const [given] = positional(args, 2);
    if (!given) die("asset modify <asset> --set <field>=<value>...");
    const name = assetKey(store, given);
    const s = sets(args);
    const catalog = readCatalog(store);
    return change(store, check, undefined, (d) => modifyAsset(d, name, s, catalog));
  }
  if (verb === "asset record") {
    const [target] = positional(args, 2);
    if (!target) die("asset record <switch>:<port>|<mac> --kind … [--name <asset>]");
    const catalog = readCatalog(store);
    const read = readDevices(opt(args, "--topology"));
    if (!read.topology) die(`the topology could not be read (${read.error}): it is what says what a port sees`);
    const hit = findSeen(seenDevices(read.topology), target);
    if ("refused" in hit) die(hit.refused);
    const taken = (read.devices ?? []).filter((x) => !x.recorded).map((x) => x.name);
    const primary = siteLocs(store.configDir)?.primary ?? null;
    return change(store, check, read.devices, (d) =>
      recordSeen(d, hit, {
        name: opt(args, "--name"),
        kind: opt(args, "--kind"),
        port: opt(args, "--port"),
        model: opt(args, "--model"),
        location: opt(args, "--location"),
        displayName: opt(args, "--display-name"),
        description: opt(args, "--description"),
      }, catalog, taken, primary),
    );
  }
  if (verb === "asset remove") {
    const [given] = positional(args, 2);
    if (!given) die("asset remove <asset>");
    const name = assetKey(store, given);
    return change(store, check, undefined, (d) => removeAsset(d, name));
  }
  if (verb === "asset receive" || verb === "asset fault" || verb === "asset repaired" || verb === "asset dispose" || verb === "asset release") {
    const [given] = positional(args, 2);
    if (!given) die(`${verb} <asset>`);
    const name = assetKey(store, given);
    const today = new Date().toISOString().slice(0, 10);
    return change(store, check, undefined, (d) =>
      verb === "asset receive" ? receiveAsset(d, name)
      : verb === "asset fault" ? faultAsset(d, name, opt(args, "--note"))
      : verb === "asset repaired" ? repairAsset(d, name)
      : verb === "asset dispose" ? disposeAsset(d, name, opt(args, "--how"), args.includes("--wiped"), opt(args, "--when") ?? today)
      : releaseAsset(d, name),
    );
  }
  if (verb === "asset allocate") {
    const [given] = positional(args, 2);
    if (!given) die("asset allocate <asset> --role <name>");
    const name = assetKey(store, given);
    const devices = devicesFor(args);
    return change(store, check, devices, (d) => allocateAsset(d, name, opt(args, "--role"), devices));
  }
  if (verb === "port add") {
    const [given, port] = positional(args, 2);
    const asset = given ? assetKey(store, given) : given;
    if (!asset || !port) die("port add <asset> <port> --kind …");
    const catalog = readCatalog(store);
    return change(store, check, undefined, (d) =>
      addPort(d, asset, port, {
        kind: opt(args, "--kind"),
        speed: opt(args, "--speed"),
        standard: opt(args, "--standard"),
        bands: opt(args, "--bands"),
        module: opt(args, "--module"),
        role: opt(args, "--role"),
        mac: opt(args, "--mac"),
        side: opt(args, "--side"),
      }, catalog),
    );
  }
  if (verb === "port modify") {
    const [given, port] = positional(args, 2);
    const asset = given ? assetKey(store, given) : given;
    if (!asset || !port) die("port modify <asset> <port> --set <field>=<value>...");
    const s = sets(args);
    const catalog = readCatalog(store);
    return change(store, check, undefined, (d) => modifyPort(d, asset, port, s, catalog));
  }
  if (verb === "port remove") {
    const [given, port] = positional(args, 2);
    const asset = given ? assetKey(store, given) : given;
    if (!asset || !port) die("port remove <asset> <port>");
    const catalog = readCatalog(store);
    return change(store, check, undefined, (d) => removePort(d, asset, port, catalog));
  }
  if (verb === "place") {
    const [device] = positional(args, 1);
    if (!device) die("place <device> --rack <rack> --u <n> | --room <room>");
    const room = opt(args, "--room");
    const rack = opt(args, "--rack") ?? (room ? undefined : die("--rack (with --u), or --room, is required"));
    const u = intOpt(args, "--u") ?? (room ? undefined : die("--u is required"));
    const catalog = readCatalog(store);
    const rec = assetNamed(store.load(), device)?.asset;
    const primary = siteLocs(store.configDir)?.primary ?? null;
    return change(store, check, devicesFor(args), (d) =>
      placeDevice(d, device, {
        rack,
        u,
        room,
        // In a rack, a recorded device takes its plate's height and width.
        height: intOpt(args, "--height") ?? (rack && rec && !opt(args, "--faceplate") ? recordedPlate(device, rec, catalog).units : undefined),
        width: opt(args, "--width") ?? (rack && rec && !opt(args, "--faceplate") ? recordedPlate(device, rec, catalog).width : undefined),
        slot: intOpt(args, "--slot"),
        face: opt(args, "--face"),
        faceplate: opt(args, "--faceplate"),
        label: opt(args, "--label"),
        description: opt(args, "--description"),
      }, catalog, primary),
    );
  }
  if (verb === "place modify") {
    const [device] = positional(args, 2);
    if (!device) die("place modify <device> --set <field>=<value>... --unset <field>...");
    const s = sets(args);
    const catalog = readCatalog(store);
    return change(store, check, devicesFor(args), (d) => modifyPlacement(d, device, s, catalog));
  }
  if (verb === "unplace") {
    const [device] = positional(args, 1);
    if (!device) die("unplace <device>");
    const catalog = readCatalog(store);
    const m = placementsOf(store.load())[device];
    // A recorded device keeps its cables; a passive plate nothing records takes them along.
    const passive = !!m?.faceplate && catalog.find((f) => f.key === m.faceplate)?.passive === true && !assetNamed(store.load(), device);
    return change(store, check, undefined, (d) => unplaceDevice(d, device, passive));
  }
  if (verb === "cable add") {
    const from = parseEnd(opt(args, "--from") ?? die("--from <device:port> is required")) ?? die("--from is <device>:<port>");
    const to = parseEnd(opt(args, "--to") ?? die("--to <device:port> is required")) ?? die("--to is <device>:<port>");
    const ff = opt(args, "--from-faceplate");
    const tf = opt(args, "--to-faceplate");
    if (ff) from.faceplate = ff;
    if (tf) to.faceplate = tf;
    const fs = opt(args, "--from-side");
    const ts = opt(args, "--to-side");
    for (const [e, sd] of [[from, fs], [to, ts]] as const) {
      if (sd === undefined) continue;
      if (sd !== "front" && sd !== "rear") die("a side is front or rear");
      e.side = sd;
    }
    return change(store, check, devicesFor(args), (d) => addCable(d, from, to, opt(args, "--kind") ?? "patch", opt(args, "--label"), opt(args, "--link-speed")));
  }
  if (verb === "cable split") {
    const [e] = positional(args, 2);
    const end = parseEnd(e ?? "") ?? die("cable split <device>:<port> --via <panel>:<port>");
    const via = parseEnd(opt(args, "--via") ?? die("--via <panel>:<port> is required")) ?? die("--via is <panel>:<port>");
    const read = readDevices(opt(args, "--topology"));
    if (read.error) note(`the topology could not be read (${read.error}): only a recorded cable can be split`);
    const seen = read.topology ? seenCables(read.topology) : null;
    return change(store, check, read.devices, (d) => splitCable(d, end, via, seen));
  }
  if (verb === "cable join") {
    const [e] = positional(args, 2);
    const end = parseEnd(e ?? "") ?? die("cable join <device>:<port>");
    return change(store, check, undefined, (d) => joinCable(d, end));
  }
  if (verb === "cable remove") {
    const [e] = positional(args, 2);
    const end = parseEnd(e ?? "") ?? die("cable remove <device>:<port>");
    const side = opt(args, "--side");
    if (side !== undefined && side !== "front" && side !== "rear") die("--side is front or rear");
    if (side) end.side = side;
    return change(store, check, undefined, (d) => removeCable(d, end));
  }
  die(`unknown verb 'asset-manager ${args.slice(0, 2).join(" ")}' — see 'asset-manager --help'`);
}

if (require.main === module) {
  // exitCode, not exit(): exit() ends the process before a large write to a pipe
  // (the verb manifest, an export) has drained.
  process.exitCode = guarded(() => run(process.argv.slice(2)));
}
