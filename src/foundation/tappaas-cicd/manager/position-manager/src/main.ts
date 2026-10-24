// position-manager — where the site's hardware is (ADR-036 D3). Owns
// config/positions.json: the rooms (each in a location of the site), the racks,
// where each device is placed (keyed by the device's topology name; the
// device's own record is never touched), the devices the topology cannot see
// (a modem, an ONT, a UPS, a patch panel) and the cables nothing can see. The
// faceplate catalog (faceplates/<vendor>/<model>.json) says what each device
// looks like; a site adds plates for the models it lacks (faceplate add),
// kept in positions.json and merged over it. network-manager's topology carries the result: the racks with
// their mounts resolved and every link mapped to faceplate ports.
//
// Every changing verb: lock → change → validate the WHOLE resulting file →
// write atomically. A verb that fails validation writes nothing. --check
// says in one line what the verb would change ("[check] would add room 'stue'
// at hareskov"), or "[refused] <why>" and exit 1; --check --json prints the
// whole resulting document instead. Nothing here touches a device.
//
// rack-manager is its old name: the package links it beside position-manager
// for one release (ADR-035 P2), and it answers the same verbs.
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
  devicesOf,
  roomsOf,
  placeWhere,
  endText,
  recordedPlate,
  recordedPorts,
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
import { Result, changeLine, addFaceplate, deleteFaceplate, modifyFaceplate, addCable, addDevice, recordSeen, placeDevice, addRack, addRoom, deleteRack, deleteRoom, joinCable, modifyDevice, modifyPlacement, modifyRack, modifyRoom, removeCable, removeDevice, unplaceDevice, splitCable } from "./verbs";

const VERSION = "0.2.0";

const CHECK: [string, string] = ["--check", "Say what would change, in one line; change nothing."];
const CHECK_JSON: [string, string] = ["--json", "With --check: the whole resulting positions.json, for machines."];
const TOPO: [string, string] = ["--topology F", "A `network-manager topology --json` document to check against, instead of running it."];
const JSON_OUT: [string, string] = ["--json", "As JSON."];

export const HELP: HelpSpec = {
  name: "position-manager",
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
      usage: "cable add --from <device:port> --to <device:port> [--kind patch|uplink|power] [--label <text>] [--from-faceplate <vendor/model>] [--to-faceplate <vendor/model>] [--from-side front|rear] [--to-side front|rear] [--topology <file>] [--check]",
      options: [
        ["--from D:P", "One end: a device and its port, as its faceplate or the topology names it."],
        ["--to D:P", "The other end."],
        ["--kind K", "patch (default), uplink or power."],
        ["--label T", "The label on the cable."],
        ["--from-faceplate K", "A device only this cable places (the ISP's modem): its faceplate."],
        ["--to-faceplate K", "The same, for the other end."],
        ["--from-side S", "A patch panel's port: front (default) or rear."],
        ["--to-side S", "The same, for the other end."],
        TOPO,
        CHECK, CHECK_JSON,
      ],
    },
    { usage: "cable remove <device:port> [--side front|rear] [--check]", options: [["--side S", "On a patch panel's port: the front (default) or the rear cable."], CHECK, CHECK_JSON], object: { positional: "device:port" } },
    { usage: "device list [--json]", options: [JSON_OUT], note: "(the recorded devices: what the topology cannot see)" },
    { usage: "device show <device> [--json]", options: [JSON_OUT], object: { positional: "device" } },
    {
      usage: "device add <device> --kind modem|ont|ups|patch-panel|other [--model <vendor/model>] [--ports <n> | --port <name>...] [--location <location>] [--display-name <text>] [--description <text>] [--topology <file>] [--check]",
      options: [
        ["--location L", "The location it is at (site-manager location list); unset, the primary location."],
        ["--kind K", "modem, ont, ups, patch-panel or other."],
        ["--model K", "Its plate in the catalog (faceplates list); its ports come from it unless given."],
        ["--ports N", "Its ports, named 1 to N (a patch panel)."],
        ["--port P", "A port by name (repeatable): WAN, LAN 1, …"],
        ["--display-name T", "The name shown."],
        ["--description T", "What it is, where it comes from."],
        TOPO,
        CHECK, CHECK_JSON,
      ],
    },
    {
      usage: "device modify <device> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "kind, model, ports (a count or a comma-separated list), displayName, description, location, mac (repeatable)."], ["--unset F", "Clear model, ports, displayName, description, location (back to the primary) or mac (repeatable)."], CHECK, CHECK_JSON],
      object: { positional: "device" },
    },
    { usage: "device remove <device> [--check]", options: [CHECK, CHECK_JSON], note: "(only once it is unplaced and no recorded cable names it)", object: { positional: "device" } },
    {
      usage: "device record <port-or-mac> --name <device> --kind modem|ont|ups|patch-panel|other [--port <name>] [--model <vendor/model>] [--location <location>] [--display-name <text>] [--description <text>] [--topology <file>] [--check]",
      options: [
        ["--name N", "The name it is recorded under."],
        ["--kind K", "modem, ont, ups, patch-panel or other."],
        ["--port P", "Its port the cable reaches (default: what LLDP says, else its model's first, else 1)."],
        ["--model K", "Its plate in the catalog (faceplates list)."],
        ["--location L", "The location it is at (default: the switch's)."],
        ["--display-name T", "The name shown (default: what LLDP or the lease calls it)."],
        ["--description T", "What it is."],
        TOPO,
        CHECK, CHECK_JSON,
      ],
      object: { positional: "port-or-mac" },
      note: "(<switch>:<port> or the MAC it is seen by: a device a switch port sees and nobody recorded, recorded with the port's cable)",
    },
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
    { usage: "export --json", effect: "read", options: [["--json", "The document and the whole catalog, for network-manager topology."]] },
  ],
  notes: [
    "A placement names a device as `network-manager topology` does. A cable the switches or LLDP see is drawn from the topology and never recorded; record only what nothing can see — the ISP's modem, a patch panel, a PDU.",
    "rack-manager is the old name of position-manager and answers the same verbs for one release; config/racks.json becomes config/positions.json by migration.",
    "A device nothing manages is recorded (device add, or device record for one a switch port sees), then placed in a rack or loose in a room (place). A link through a patch panel is split there (cable split): the topology still shows one link, the racks its two wires.",
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

// change — the shared sequence of every changing verb. Devices are read only
// for a verb that names one (a mount, a cable); a rack's own fields need none.
function change(store: Store, check: boolean, devices: SiteDevice[] | null | undefined, fn: (doc: PositionsDoc) => Result): number {
  if (!check && store.legacy) die(`${store.legacy} is still there: migration 0020 makes it config/positions.json (the next update, or scripts/run-migrations.sh) — nothing was changed`);
  return store.withLock(() => {
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
};

export function run(argv: string[]): number {
  const old = OLD_VERBS[argv.slice(0, 2).join(" ")];
  const args = old ? [...old, ...argv.slice(2)] : argv;
  if (args.length === 0 || args[0] === "help" || ((args[0] === "--help" || args[0] === "-h") && !args.includes("--json"))) {
    info(renderHelp(HELP));
    return 0;
  }
  if (args[0] === "--version" || args[0] === "version") {
    info(`position-manager ${VERSION}`);
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

  if (args[0] === "validate") {
    const findings = checkPositions(store.load(), readShipped(), devicesFor(args), siteLocs(store.configDir));
    if (json) {
      console.log(JSON.stringify({ valid: !findings.some((f) => f.severity === "error"), findings }, null, 2));
      return findings.some((f) => f.severity === "error") ? 1 : 0;
    }
    if (report(findings)) return 1;
    const d = store.load();
    info(`${GN}✓${CL} config/positions.json valid (${Object.keys(racksOf(d)).length} rack(s), ${Object.keys(placementsOf(d)).length} placement(s), ${cablesOf(d).length} recorded cable(s))`);
    return 0;
  }
  if (args[0] === "export") {
    // The catalog with the site's plates: what the topology draws with.
    const { catalog, errors } = loadCatalog();
    const doc = store.load();
    const merged = withSiteFaceplates(catalog, doc);
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
  if (verb === "device list" || verb === "device show") {
    const d = store.load();
    const catalog = readCatalog(store);
    const rows = Object.entries(devicesOf(d)).map(([name, r]) => ({
      name,
      ...r,
      ports: recordedPorts(r, catalog),
      plate: recordedPlate(name, r, catalog).key,
      placed: placementsOf(d)[name] ? where(placementsOf(d)[name]) : null,
      cables: cablesOf(d).filter((c) => c.from.device === name || c.to.device === name).length,
    }));
    if (verb === "device show") {
      const [name] = positional(args, 2);
      if (!name) die("device show <device>");
      const r = rows.find((x) => x.name === name) ?? die(`device ${name} is not recorded`);
      if (json) return out(r);
      info(`${GN}${r.name}${CL}  ${r.kind}${r.model ? `  ${r.model}` : ""}${r.displayName ? `  "${r.displayName}"` : ""}`);
      info(`  ports: ${r.ports.join(", ") || "-"}`);
      info(`  placed: ${r.placed ?? "nowhere"} · location ${r.location ?? "the primary"}${r.mac ? ` · mac ${r.mac}` : ""} · ${r.cables} recorded cable(s)`);
      if (r.description) info(`  ${r.description}`);
      return 0;
    }
    if (json) return out(rows);
    if (!rows.length) info("no recorded devices (device add <name> --kind …)");
    for (const r of rows) info(`${r.name.padEnd(24)} ${r.kind.padEnd(12)} ${String(r.ports.length).padStart(2)} port(s)  ${r.placed ?? "placed nowhere"}${r.model ? `  ${r.model}` : ""}`);
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
  if (verb === "device add") {
    const [name] = positional(args, 2);
    if (!name) die("device add <device> --kind …");
    const catalog = readCatalog(store);
    const devices = devicesFor(args);
    const seen = devices ? devices.filter((x) => !x.recorded).map((x) => x.name) : null;
    return change(store, check, devices, (d) =>
      addDevice(d, name, {
        kind: opt(args, "--kind"),
        model: opt(args, "--model"),
        ports: intOpt(args, "--ports"),
        port: opts(args, "--port"),
        displayName: opt(args, "--display-name"),
        description: opt(args, "--description"),
        location: opt(args, "--location"),
      }, catalog, seen),
    );
  }
  if (verb === "device modify") {
    const [name] = positional(args, 2);
    if (!name) die("device modify <device> --set <field>=<value>...");
    const s = sets(args);
    const catalog = readCatalog(store);
    return change(store, check, undefined, (d) => modifyDevice(d, name, s, catalog));
  }
  if (verb === "device record") {
    const [target] = positional(args, 2);
    if (!target) die("device record <switch>:<port>|<mac> --name <device> --kind …");
    const name = opt(args, "--name") ?? die("--name <device> is required: the name it is recorded under");
    const catalog = readCatalog(store);
    const read = readDevices(opt(args, "--topology"));
    if (!read.topology) die(`the topology could not be read (${read.error}): it is what says what a port sees`);
    const hit = findSeen(seenDevices(read.topology), target);
    if ("refused" in hit) die(hit.refused);
    const taken = (read.devices ?? []).filter((x) => !x.recorded).map((x) => x.name);
    const primary = siteLocs(store.configDir)?.primary ?? null;
    return change(store, check, read.devices, (d) =>
      recordSeen(d, hit, {
        name,
        kind: opt(args, "--kind"),
        port: opt(args, "--port"),
        model: opt(args, "--model"),
        location: opt(args, "--location"),
        displayName: opt(args, "--display-name"),
        description: opt(args, "--description"),
      }, catalog, taken, primary),
    );
  }
  if (verb === "device remove") {
    const [name] = positional(args, 2);
    if (!name) die("device remove <device>");
    return change(store, check, undefined, (d) => removeDevice(d, name));
  }
  if (verb === "place") {
    const [device] = positional(args, 1);
    if (!device) die("place <device> --rack <rack> --u <n> | --room <room>");
    const room = opt(args, "--room");
    const rack = opt(args, "--rack") ?? (room ? undefined : die("--rack (with --u), or --room, is required"));
    const u = intOpt(args, "--u") ?? (room ? undefined : die("--u is required"));
    const catalog = readCatalog(store);
    const rec = devicesOf(store.load())[device];
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
    const passive = !!m?.faceplate && catalog.find((f) => f.key === m.faceplate)?.passive === true && !devicesOf(store.load())[device];
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
    return change(store, check, devicesFor(args), (d) => addCable(d, from, to, opt(args, "--kind") ?? "patch", opt(args, "--label")));
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
  die(`unknown verb 'position-manager ${args.slice(0, 2).join(" ")}' — see 'position-manager --help'`);
}

if (require.main === module) {
  process.exit(guarded(() => run(process.argv.slice(2))));
}
