// rack-manager — where the site's hardware sits. Owns config/racks.json: the
// racks, what is mounted where (keyed by the device's topology name; the
// device's own record is never touched), the devices the topology cannot see
// (a modem, an ONT, a UPS, a patch panel) and the cables nothing can see. The
// faceplate catalog (faceplates/<vendor>/<model>.json) says what each device
// looks like. network-manager's topology carries the result: the racks with
// their mounts resolved and every link mapped to faceplate ports.
//
// Every changing verb: lock → change → validate the WHOLE resulting file →
// write atomically. A verb that fails validation writes nothing. --check
// prints the result instead. Nothing here touches a device.
//
// Exit codes: ok=0, error=1.

import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { CL, GN, YW, die, guarded, info, requireOperator, warn } from "../../../lib/ts/src/cli";
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import {
  Faceplate,
  Mount,
  RackFinding,
  RacksDoc,
  SiteDevice,
  checkRacks,
  cablesOf,
  devicesOf,
  roomsOf,
  mountWhere,
  endText,
  recordedPlate,
  recordedPorts,
  mountsOf,
  parseEnd,
  racksOf,
  renderPlate,
  resolvePlate,
  seenCables,
  suggestFaceplate,
} from "../../../lib/ts/src/racks";
import { Store, loadCatalog, readDevices } from "./store";
import { Result, addCable, addDevice, addMount, addRack, addRoom, deleteRack, deleteRoom, joinCable, modifyDevice, modifyMount, modifyRack, modifyRoom, removeCable, removeDevice, removeMount, splitCable } from "./verbs";

const VERSION = "0.1.0";

const CHECK: [string, string] = ["--check", "Show the result; change nothing."];
const TOPO: [string, string] = ["--topology F", "A `network-manager topology --json` document to check against, instead of running it."];
const JSON_OUT: [string, string] = ["--json", "As JSON."];

export const HELP: HelpSpec = {
  name: "rack-manager",
  version: VERSION,
  tagline: "where the site's hardware sits — racks, mounts and the cables nothing can see, in config/racks.json",
  verbs: [
    { usage: "validate [--topology <file>] [--json]", options: [TOPO, ["--json", "The findings as JSON."]], note: "(config/racks.json against the topology and the catalog)" },
    { usage: "rack list [--json]", options: [JSON_OUT] },
    { usage: "rack show <rack> [--json]", options: [JSON_OUT], note: "(the rack and its mounts)" },
    {
      usage: "rack add <rack> [--units <n>] [--width 19in|10in] [--numbering bottom-up|top-down] [--display-name <text>] [--building <text>] [--room <text>] [--description <text>] [--check]",
      options: [
        ["--units N", "Its height in rack units (default 42)."],
        ["--width W", "19in (default) or 10in."],
        ["--numbering N", "bottom-up (default: U1 at the bottom) or top-down."],
        ["--display-name T", "The name shown on its frame."],
        ["--building T", "The building it stands in."],
        ["--room T", "The room it stands in (a room record's name; text until the room is recorded)."],
        ["--description T", "What it is for."],
        CHECK,
      ],
    },
    {
      usage: "rack modify <rack> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "displayName, units, width, numbering, building, room, description (repeatable)."], ["--unset F", "Clear a text field: displayName, building, room, description (repeatable)."], CHECK],
    },
    { usage: "rack delete <rack> [--check]", options: [CHECK], note: "(an empty rack only)" },
    { usage: "room list [--json]", options: [JSON_OUT], note: "(the rooms, their racks and the devices loose in them)" },
    { usage: "room show <room> [--json]", options: [JSON_OUT], object: { positional: "room" } },
    {
      usage: "room add <room> [--building <text>] [--display-name <text>] [--description <text>] [--check]",
      options: [["--building T", "The building it is in."], ["--display-name T", "The name shown."], ["--description T", "What it is."], CHECK],
    },
    {
      usage: "room modify <room> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "displayName, building, description (repeatable)."], ["--unset F", "Clear one of them (repeatable)."], CHECK],
      object: { positional: "room" },
    },
    { usage: "room delete <room> [--check]", options: [CHECK], note: "(an empty room only)", object: { positional: "room" } },
    { usage: "mount list [--rack <rack>] [--json]", options: [["--rack R", "Only this rack's."], JSON_OUT] },
    { usage: "mount show <device> [--json]", options: [JSON_OUT] },
    {
      usage:
        "mount add <device> (--rack <rack> --u <n> | --room <room>) [--height <n>] [--width full|half|third] [--slot <n>] [--face front|rear] [--faceplate <vendor/model>] [--label <text>] [--description <text>] [--topology <file>] [--check]",
      options: [
        ["--rack R", "The rack."],
        ["--u N", "The lowest rack unit it takes, as the rack numbers them."],
        ["--room R", "Loose in this room, in no rack (no --rack, no --u)."],
        ["--height N", "Rack units it takes (default: its faceplate's, else 1)."],
        ["--width W", "full (default), half or third of the rack's width."],
        ["--slot N", "A half or third: its column, 0 at the left."],
        ["--face F", "front (default) or rear."],
        ["--faceplate K", "The catalog's plate (faceplates list); unset, the catalog's suggestion for its model."],
        ["--label T", "The label on the device."],
        ["--description T", "A note on the mount."],
        TOPO,
        CHECK,
      ],
    },
    {
      usage: "mount modify <device> [--set <field>=<value>]... [--unset <field>]... [--topology <file>] [--check]",
      options: [["--set F=V", "rack, u, room, height, width, slot, face, faceplate, label, description (repeatable). A move is rack and u, or room (loose in it)."], ["--unset F", "Clear faceplate (back to the catalog's suggestion), label or description (repeatable)."], TOPO, CHECK],
    },
    { usage: "mount remove <device> [--check]", options: [CHECK], note: "(the device leaves the rack; nothing else changes)" },
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
        CHECK,
      ],
    },
    { usage: "cable remove <device:port> [--side front|rear] [--check]", options: [["--side S", "On a patch panel's port: the front (default) or the rear cable."], CHECK], object: { positional: "device:port" } },
    { usage: "device list [--json]", options: [JSON_OUT], note: "(the recorded devices: what the topology cannot see)" },
    { usage: "device show <device> [--json]", options: [JSON_OUT], object: { positional: "device" } },
    {
      usage: "device add <device> --kind modem|ont|ups|patch-panel|other [--model <vendor/model>] [--ports <n> | --port <name>...] [--display-name <text>] [--description <text>] [--topology <file>] [--check]",
      options: [
        ["--kind K", "modem, ont, ups, patch-panel or other."],
        ["--model K", "Its plate in the catalog (faceplates list); its ports come from it unless given."],
        ["--ports N", "Its ports, named 1 to N (a patch panel)."],
        ["--port P", "A port by name (repeatable): WAN, LAN 1, …"],
        ["--display-name T", "The name shown."],
        ["--description T", "What it is, where it comes from."],
        TOPO,
        CHECK,
      ],
    },
    {
      usage: "device modify <device> [--set <field>=<value>]... [--unset <field>]... [--check]",
      options: [["--set F=V", "kind, model, ports (a count or a comma-separated list), displayName, description (repeatable)."], ["--unset F", "Clear model, ports, displayName or description (repeatable)."], CHECK],
      object: { positional: "device" },
    },
    { usage: "device remove <device> [--check]", options: [CHECK], note: "(only once it is unmounted and no recorded cable names it)", object: { positional: "device" } },
    {
      usage: "cable split <device:port> --via <panel:port> [--topology <file>] [--check]",
      options: [["--via P:N", "The patch panel port the link runs through: the device's port to its front, its rear to the far end."], TOPO, CHECK],
      object: { positional: "device:port" },
      note: "(the link on that port, seen or recorded, becomes two recorded segments)",
    },
    { usage: "cable join <device:port> [--check]", options: [CHECK], object: { positional: "device:port" }, note: "(undo a split: a panel port, or a device end of one of its segments)" },
    { usage: "faceplates list [--json]", options: [JSON_OUT] },
    {
      usage: "faceplates show <vendor/model> [--device <name>] [--topology <file>] [--json]",
      options: [["--device N", "Fill a generic plate from this device's ports, with their live state."], TOPO, JSON_OUT],
    },
    { usage: "export --json", effect: "read", options: [["--json", "The document and the whole catalog, for network-manager topology."]] },
  ],
  notes: [
    "A mount names a device as `network-manager topology` does. A cable the switches or LLDP see is drawn from the topology and never recorded; record only what nothing can see — the ISP's modem, a patch panel, a PDU.",
    "A device nothing can see is recorded (device add), then mounted in a rack or loose in a room (mount add --room). A link through a patch panel is split there (cable split): the topology still shows one link, the racks its two wires.",
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
  "--units", "--width", "--numbering", "--display-name", "--building", "--room", "--description", "--set", "--rack", "--u", "--height", "--slot",
  "--face", "--faceplate", "--label", "--topology", "--from", "--to", "--kind", "--from-faceplate", "--to-faceplate", "--device", "--unset",
  "--model", "--ports", "--port", "--from-side", "--to-side", "--side", "--via",
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

function report(findings: RackFinding[]): number {
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

function readCatalog(): Faceplate[] {
  const { catalog, errors } = loadCatalog();
  for (const e of errors) note(`faceplate catalog: ${e}`);
  return catalog;
}

// change — the shared sequence of every changing verb. Devices are read only
// for a verb that names one (a mount, a cable); a rack's own fields need none.
function change(store: Store, check: boolean, catalog: Faceplate[], devices: SiteDevice[] | null | undefined, fn: (doc: RacksDoc) => Result): number {
  return store.withLock(() => {
    const r = fn(store.load());
    if ("refused" in r) die(r.refused);
    const findings = checkRacks(r.doc, catalog, devices ?? null).filter((f) => devices !== undefined || !f.message.startsWith("the topology could not be read"));
    const errors = report(findings.filter((f) => f.severity === "error" || !check));
    if (errors) die("config/racks.json would not be valid — nothing was changed");
    if (check) {
      info(`[check] ${r.summary}`);
      info(JSON.stringify(r.doc, null, 2));
      return 0;
    }
    store.save(r.doc);
    info(`${GN}✓${CL} ${r.summary}`);
    return 0;
  });
}

function devicesFor(args: string[]): SiteDevice[] | null {
  const d = readDevices(opt(args, "--topology"));
  if (d.error) note(`the topology could not be read (${d.error}): the device names are not checked`);
  return d.devices;
}

function rackRows(doc: RacksDoc) {
  return Object.entries(racksOf(doc)).map(([name, r]) => ({
    name,
    ...r,
    mounts: Object.entries(mountsOf(doc)).filter(([, m]) => m.rack === name).length,
  }));
}

function mountRows(doc: RacksDoc, rack?: string) {
  return Object.entries(mountsOf(doc))
    .filter(([, m]) => !rack || m.rack === rack)
    // rack by rack, highest first; the loose ones last, by room
    .sort(([, a], [, b]) => Number(!a.rack) - Number(!b.rack) || (a.rack ?? a.room ?? "").localeCompare(b.rack ?? b.room ?? "") || (b.u ?? 0) - (a.u ?? 0))
    .map(([device, m]) => ({ device, ...m }));
}

const where = (m: Mount) =>
  m.rack ? `${mountWhere(m)} ${m.face}${m.width === "full" ? "" : ` ${m.width} slot ${m.slot ?? 0}`}` : mountWhere(m);

export function run(argv: string[]): number {
  const args = argv;
  if (args.length === 0 || args[0] === "help" || ((args[0] === "--help" || args[0] === "-h") && !args.includes("--json"))) {
    info(renderHelp(HELP));
    return 0;
  }
  if (args[0] === "--version" || args[0] === "version") {
    info(`rack-manager ${VERSION}`);
    return 0;
  }
  const rc = checkArgs(HELP, args);
  if (rc !== undefined) return rc;
  const store = new Store(defaultConfigDir());
  const check = args.includes("--check");
  const json = args.includes("--json");
  quiet = json;
  const verb = args.slice(0, 2).join(" ");

  if (args[0] === "validate") {
    const catalog = readCatalog();
    const findings = checkRacks(store.load(), catalog, devicesFor(args));
    if (json) {
      console.log(JSON.stringify({ valid: !findings.some((f) => f.severity === "error"), findings }, null, 2));
      return findings.some((f) => f.severity === "error") ? 1 : 0;
    }
    if (report(findings)) return 1;
    const d = store.load();
    info(`${GN}✓${CL} config/racks.json valid (${Object.keys(racksOf(d)).length} rack(s), ${Object.keys(mountsOf(d)).length} mount(s), ${cablesOf(d).length} recorded cable(s))`);
    return 0;
  }
  if (args[0] === "export") {
    const { catalog, errors } = loadCatalog();
    console.log(JSON.stringify({ doc: store.load(), catalog, catalogErrors: errors }, null, 2));
    return 0;
  }

  if (verb === "rack list") {
    const rows = rackRows(store.load());
    if (json) return out(rows);
    if (!rows.length) info("no racks (rack add <name>)");
    for (const r of rows) info(`${GN}${r.name}${CL}  ${r.units}U ${r.width} ${r.numbering}  ${[r.building, r.room].filter(Boolean).join(" / ") || "-"}  ${r.mounts} mount(s)${r.displayName ? `  "${r.displayName}"` : ""}`);
    return 0;
  }
  if (verb === "rack show") {
    const [name] = positional(args, 2);
    if (!name) die("rack show <rack>");
    const d = store.load();
    const r = racksOf(d)[name] ?? die(`rack ${name} does not exist`);
    const mounts = mountRows(d, name);
    if (json) return out({ name, ...r, mounts });
    info(`${GN}${name}${CL}${r.displayName ? ` "${r.displayName}"` : ""}  ${r.units}U ${r.width}, numbered ${r.numbering}${r.building || r.room ? `  in ${[r.building, r.room].filter(Boolean).join(", ")}` : ""}`);
    if (r.description) info(`  ${r.description}`);
    for (const m of mounts) info(`  U${String(m.u).padStart(2)}${m.height > 1 ? `-${(m.u ?? 0) + m.height - 1}` : "   "}  ${m.device.padEnd(24)} ${m.face}${m.width === "full" ? "" : ` ${m.width}/${m.slot ?? 0}`}  ${m.faceplate ?? "(suggested plate)"}${m.label ? `  "${m.label}"` : ""}`);
    if (!mounts.length) info("  (empty)");
    return 0;
  }
  if (verb === "mount list") {
    const rows = mountRows(store.load(), opt(args, "--rack"));
    if (json) return out(rows);
    if (!rows.length) info("nothing mounted (mount add <device> --rack <rack> --u <n>)");
    for (const m of rows) info(`${m.device.padEnd(24)} ${where(m)}  ${m.faceplate ?? "-"}${m.description ? `  ${YW}${m.description}${CL}` : ""}`);
    return 0;
  }
  if (verb === "mount show") {
    const [device] = positional(args, 2);
    if (!device) die("mount show <device>");
    const m = mountsOf(store.load())[device] ?? die(`${device} is not mounted`);
    if (json) return out({ device, ...m });
    info(`${GN}${device}${CL}  ${where(m)}  ${m.height}U${m.faceplate ? `  faceplate ${m.faceplate}` : ""}${m.label ? `  label "${m.label}"` : ""}`);
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
      loose: Object.entries(mountsOf(d)).filter(([, m]) => !m.rack && m.room === name).map(([n]) => n),
    }));
    if (verb === "room show") {
      const [name] = positional(args, 2);
      if (!name) die("room show <room>");
      const r = rows.find((x) => x.name === name) ?? die(`room ${name} does not exist`);
      if (json) return out(r);
      info(`${GN}${r.name}${CL}${r.displayName ? ` "${r.displayName}"` : ""}${r.building ? `  in ${r.building}` : ""}`);
      info(`  racks: ${r.racks.join(", ") || "-"} · loose: ${r.loose.join(", ") || "-"}`);
      if (r.description) info(`  ${r.description}`);
      return 0;
    }
    if (json) return out(rows);
    if (!rows.length) info("no rooms (room add <name>)");
    for (const r of rows) info(`${r.name.padEnd(20)} ${(r.building ?? "-").padEnd(16)} ${r.racks.length} rack(s), ${r.loose.length} loose${r.displayName ? `  "${r.displayName}"` : ""}`);
    return 0;
  }
  if (verb === "device list" || verb === "device show") {
    const d = store.load();
    const { catalog } = loadCatalog();
    const rows = Object.entries(devicesOf(d)).map(([name, r]) => ({
      name,
      ...r,
      ports: recordedPorts(r, catalog),
      plate: recordedPlate(name, r, catalog).key,
      mounted: mountsOf(d)[name] ? where(mountsOf(d)[name]) : null,
      cables: cablesOf(d).filter((c) => c.from.device === name || c.to.device === name).length,
    }));
    if (verb === "device show") {
      const [name] = positional(args, 2);
      if (!name) die("device show <device>");
      const r = rows.find((x) => x.name === name) ?? die(`device ${name} is not recorded`);
      if (json) return out(r);
      info(`${GN}${r.name}${CL}  ${r.kind}${r.model ? `  ${r.model}` : ""}${r.displayName ? `  "${r.displayName}"` : ""}`);
      info(`  ports: ${r.ports.join(", ") || "-"}`);
      info(`  mounted: ${r.mounted ?? "nowhere"} · ${r.cables} recorded cable(s)`);
      if (r.description) info(`  ${r.description}`);
      return 0;
    }
    if (json) return out(rows);
    if (!rows.length) info("no recorded devices (device add <name> --kind …)");
    for (const r of rows) info(`${r.name.padEnd(24)} ${r.kind.padEnd(12)} ${String(r.ports.length).padStart(2)} port(s)  ${r.mounted ?? "mounted nowhere"}${r.model ? `  ${r.model}` : ""}`);
    return 0;
  }
  if (verb === "faceplates list") {
    const { catalog, errors } = loadCatalog();
    if (json) return out(catalog.map((f) => ({ key: f.key, vendor: f.vendor, model: f.model, kind: f.kind, units: f.units, width: f.width, passive: f.passive === true, generic: f.generic ?? null, match: f.match ?? [], ports: f.rows.flat().filter(Boolean).length })));
    for (const e of errors) note(e);
    for (const f of catalog) info(`${f.key.padEnd(34)} ${f.kind.padEnd(12)} ${f.units}U ${f.width.padEnd(6)} ${f.generic ? `filled from the device's ${f.generic}` : `${f.rows.flat().filter(Boolean).length} port(s)`}${f.passive ? "  passive" : ""}`);
    return 0;
  }
  if (verb === "faceplates show") {
    const [key] = positional(args, 2);
    if (!key) die("faceplates show <vendor/model>");
    const { catalog } = loadCatalog();
    const f = catalog.find((x) => x.key === key) ?? die(`faceplate ${key} is not in the catalog (faceplates list)`);
    const name = opt(args, "--device");
    let dev: SiteDevice | null = null;
    if (name) {
      const devices = devicesFor(args);
      dev = devices?.find((d) => d.name === name) ?? die(`the topology has no device '${name}'`);
    }
    const plate = resolvePlate(f, dev);
    if (json) return out(plate);
    for (const l of renderPlate(plate)) info(l);
    if (dev) info(`  (the catalog suggests ${suggestFaceplate(catalog, dev) ?? "no plate"} for ${dev.name})`);
    return 0;
  }

  requireOperator();
  if (verb === "rack add") {
    const [name] = positional(args, 2);
    if (!name) die("rack add <rack>");
    const catalog = readCatalog();
    return change(store, check, catalog, undefined, (d) =>
      addRack(d, name, {
        units: intOpt(args, "--units"),
        width: opt(args, "--width"),
        numbering: opt(args, "--numbering"),
        displayName: opt(args, "--display-name"),
        building: opt(args, "--building"),
        room: opt(args, "--room"),
        description: opt(args, "--description"),
      }),
    );
  }
  if (verb === "rack modify") {
    const [name] = positional(args, 2);
    if (!name) die("rack modify <rack> --set <field>=<value>... --unset <field>...");
    const s = sets(args);
    return change(store, check, readCatalog(), undefined, (d) => modifyRack(d, name, s));
  }
  if (verb === "rack delete") {
    const [name] = positional(args, 2);
    if (!name) die("rack delete <rack>");
    return change(store, check, readCatalog(), undefined, (d) => deleteRack(d, name));
  }
  if (verb === "room add") {
    const [name] = positional(args, 2);
    if (!name) die("room add <room>");
    return change(store, check, readCatalog(), undefined, (d) => addRoom(d, name, { building: opt(args, "--building"), displayName: opt(args, "--display-name"), description: opt(args, "--description") }));
  }
  if (verb === "room modify") {
    const [name] = positional(args, 2);
    if (!name) die("room modify <room> --set <field>=<value>...");
    const s = sets(args);
    return change(store, check, readCatalog(), undefined, (d) => modifyRoom(d, name, s));
  }
  if (verb === "room delete") {
    const [name] = positional(args, 2);
    if (!name) die("room delete <room>");
    return change(store, check, readCatalog(), undefined, (d) => deleteRoom(d, name));
  }
  if (verb === "device add") {
    const [name] = positional(args, 2);
    if (!name) die("device add <device> --kind …");
    const catalog = readCatalog();
    const devices = devicesFor(args);
    const seen = devices ? devices.filter((x) => !x.recorded).map((x) => x.name) : null;
    return change(store, check, catalog, devices, (d) =>
      addDevice(d, name, {
        kind: opt(args, "--kind"),
        model: opt(args, "--model"),
        ports: intOpt(args, "--ports"),
        port: opts(args, "--port"),
        displayName: opt(args, "--display-name"),
        description: opt(args, "--description"),
      }, catalog, seen),
    );
  }
  if (verb === "device modify") {
    const [name] = positional(args, 2);
    if (!name) die("device modify <device> --set <field>=<value>...");
    const s = sets(args);
    const catalog = readCatalog();
    return change(store, check, catalog, undefined, (d) => modifyDevice(d, name, s, catalog));
  }
  if (verb === "device remove") {
    const [name] = positional(args, 2);
    if (!name) die("device remove <device>");
    return change(store, check, readCatalog(), undefined, (d) => removeDevice(d, name));
  }
  if (verb === "mount add") {
    const [device] = positional(args, 2);
    if (!device) die("mount add <device> --rack <rack> --u <n> | --room <room>");
    const room = opt(args, "--room");
    const rack = opt(args, "--rack") ?? (room ? undefined : die("--rack (with --u), or --room, is required"));
    const u = intOpt(args, "--u") ?? (room ? undefined : die("--u is required"));
    const catalog = readCatalog();
    const rec = devicesOf(store.load())[device];
    return change(store, check, catalog, devicesFor(args), (d) =>
      addMount(d, device, {
        rack,
        u,
        room,
        height: intOpt(args, "--height") ?? (rec && !opt(args, "--faceplate") ? recordedPlate(device, rec, catalog).units : undefined),
        width: opt(args, "--width") ?? (rec && !opt(args, "--faceplate") ? recordedPlate(device, rec, catalog).width : undefined),
        slot: intOpt(args, "--slot"),
        face: opt(args, "--face"),
        faceplate: opt(args, "--faceplate"),
        label: opt(args, "--label"),
        description: opt(args, "--description"),
      }, catalog),
    );
  }
  if (verb === "mount modify") {
    const [device] = positional(args, 2);
    if (!device) die("mount modify <device> --set <field>=<value>... --unset <field>...");
    const s = sets(args);
    const catalog = readCatalog();
    return change(store, check, catalog, devicesFor(args), (d) => modifyMount(d, device, s, catalog));
  }
  if (verb === "mount remove") {
    const [device] = positional(args, 2);
    if (!device) die("mount remove <device>");
    const catalog = readCatalog();
    const m = mountsOf(store.load())[device];
    // A recorded device keeps its cables; a passive plate nothing records takes them along.
    const passive = !!m?.faceplate && catalog.find((f) => f.key === m.faceplate)?.passive === true && !devicesOf(store.load())[device];
    return change(store, check, catalog, undefined, (d) => removeMount(d, device, passive));
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
    const catalog = readCatalog();
    return change(store, check, catalog, devicesFor(args), (d) => addCable(d, from, to, opt(args, "--kind") ?? "patch", opt(args, "--label")));
  }
  if (verb === "cable split") {
    const [e] = positional(args, 2);
    const end = parseEnd(e ?? "") ?? die("cable split <device>:<port> --via <panel>:<port>");
    const via = parseEnd(opt(args, "--via") ?? die("--via <panel>:<port> is required")) ?? die("--via is <panel>:<port>");
    const read = readDevices(opt(args, "--topology"));
    if (read.error) note(`the topology could not be read (${read.error}): only a recorded cable can be split`);
    const seen = read.topology ? seenCables(read.topology) : null;
    return change(store, check, readCatalog(), read.devices, (d) => splitCable(d, end, via, seen));
  }
  if (verb === "cable join") {
    const [e] = positional(args, 2);
    const end = parseEnd(e ?? "") ?? die("cable join <device>:<port>");
    return change(store, check, readCatalog(), undefined, (d) => joinCable(d, end));
  }
  if (verb === "cable remove") {
    const [e] = positional(args, 2);
    const end = parseEnd(e ?? "") ?? die("cable remove <device>:<port>");
    const side = opt(args, "--side");
    if (side !== undefined && side !== "front" && side !== "rear") die("--side is front or rear");
    if (side) end.side = side;
    return change(store, check, readCatalog(), undefined, (d) => removeCable(d, end));
  }
  die(`unknown verb 'rack-manager ${args.slice(0, 2).join(" ")}' — see 'rack-manager --help'`);
}

if (require.main === module) {
  process.exit(guarded(() => run(process.argv.slice(2))));
}
