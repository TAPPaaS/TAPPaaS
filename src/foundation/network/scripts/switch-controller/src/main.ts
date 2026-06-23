// switch-controller — TAPPaaS managed-switch network provider (ADR-007 S-TS).
//
// A faithful TypeScript port of firewall/scripts/switch-manager (ADR-008, #339).
// Reconciles managed switches to zones.json (the single source of truth) so a
// zone's VLAN is carried on every node-uplink trunk. Maintains two state files
// under $CONFIG_DIR:
//
//   switch-configuration-actual.json   facts: controllers / switches / per-port
//       topology (which node/AP/switch a port connects to) + the VLAN config
//       currently present once configured.
//   switch-configuration-desired.json  what zones.json IMPLIES — REGENERATED
//       from actual's topology + the active VLAN set (never hand-edited).
//
// Five-verb provider contract: interrogate → update-desired → delta → apply →
// confirm; `reconcile [--apply]` runs them in order. Vendor automation stays in
// bash plugins (scripts/plugins/<vendor>.sh), invoked across the FFI boundary
// via `bash -c '. "$plugin"; plugin_fn "$@"'`; manual.sh is the fallback.
//
// Exit codes (parity with switch-manager): ok=0, drift=2, error=1.

import { existsSync, readFileSync, writeFileSync, renameSync, unlinkSync, readdirSync } from "fs";
import { basename, join } from "path";
import { tmpdir } from "os";
import { spawnSync } from "child_process";

const VERSION = "0.1.0";

// ── Colours / logging (match switch-manager's helper surface) ────────
const GN = "\x1b[1;92m";
const CL = "\x1b[0m";
const BOLD = "\x1b[1m";
const YW = "\x1b[01;33m";
const RD = "\x1b[01;31m";

function info(msg: string): void {
  console.log(msg);
}
function warn(msg: string): void {
  console.log(`${YW}[Warning]${CL} ${msg}`);
}
class DieError extends Error {}
function die(msg: string): never {
  console.error(`${RD}[Error]${CL} ${msg}`);
  throw new DieError(msg);
}

// ── Config / paths ───────────────────────────────────────────────────
// Plugins ship in the bash source tree (scripts/plugins). Resolve relative to
// this file: dist/main.js → ../.. (switch-controller dir) → ../plugins. The Nix
// wrapper sets the same source layout via SWITCH_CONTROLLER_DIR if needed; the
// oracle always overrides PLUGIN_DIR explicitly for its stubs.
const CONTROLLER_DIR =
  process.env.SWITCH_CONTROLLER_DIR ??
  join(__dirname, "..", "..");
const PLUGIN_DIR = process.env.PLUGIN_DIR ?? join(CONTROLLER_DIR, "..", "plugins");

function configDir(): string {
  const c = process.env.CONFIG_DIR;
  if (!c) die("CONFIG_DIR is not set");
  return c;
}
function zonesFile(): string {
  return join(configDir(), "zones.json");
}
function actualFile(): string {
  return join(configDir(), "switch-configuration-actual.json");
}
function desiredFile(): string {
  return join(configDir(), "switch-configuration-desired.json");
}

const PORT_TYPES = ["node", "switch", "ap", "device", "uplink"];
const TRUNK_TYPES = new Set(["node", "switch", "ap", "uplink"]);
function isTrunkType(t: string): boolean {
  return TRUNK_TYPES.has(t);
}

// ── JSON value types (intentionally loose, mirroring jq's dynamic data) ─
type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
interface JObj {
  [k: string]: Json;
}
function isObj(v: Json | undefined): v is JObj {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// ── Atomic state I/O (temp → validate → rename) ──────────────────────
function readJson(path: string): JObj {
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Json;
  if (!isObj(parsed)) die(`${path}: not a JSON object`);
  return parsed;
}
function writeJsonAtomic(path: string, data: JObj): void {
  const txt = JSON.stringify(data, null, 2) + "\n";
  JSON.parse(txt); // validate round-trip before committing
  const tmp = join(tmpdir(), `sc-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
  writeFileSync(tmp, txt);
  try {
    renameSync(tmp, path);
  } catch {
    try {
      unlinkSync(tmp);
    } catch {
      /* ignore */
    }
    die(`Failed to update ${path}`);
  }
}
function emptyState(): JObj {
  return {
    $schema: "switch-configuration-schema.json",
    version: "2.0",
    controllers: {},
    switches: {},
    accessPoints: {},
  };
}
function ensureFiles(): void {
  for (const f of [actualFile(), desiredFile()]) {
    if (!existsSync(f)) writeJsonAtomic(f, emptyState());
  }
}
function loadActual(): JObj {
  return readJson(actualFile());
}
function saveActual(a: JObj): void {
  writeJsonAtomic(actualFile(), a);
}
function loadDesired(): JObj {
  return readJson(desiredFile());
}
function saveDesired(d: JObj): void {
  writeJsonAtomic(desiredFile(), d);
}

// ── Small JSON accessors (object defaults, like jq's `// {}`) ────────
function obj(v: Json | undefined): JObj {
  return isObj(v) ? v : {};
}
function arr(v: Json | undefined): Json[] {
  return Array.isArray(v) ? v : [];
}
function str(v: Json | undefined): string {
  return typeof v === "string" ? v : "";
}
function num(v: Json | undefined, dflt = 0): number {
  return typeof v === "number" ? v : dflt;
}
function intArray(v: Json | undefined): number[] {
  return arr(v).filter((n): n is number => typeof n === "number");
}
function has(o: JObj, k: string): boolean {
  return Object.prototype.hasOwnProperty.call(o, k);
}

// ── Active VLAN tags from zones.json (Active|Mandatory, vlantag>0) ────
function activeVlans(): number[] {
  const zones = readJson(zonesFile());
  const tags: number[] = [];
  for (const z of Object.values(zones)) {
    if (!isObj(z)) continue;
    const state = str(z.state);
    const tag = num(z.vlantag);
    if ((state === "Active" || state === "Mandatory") && tag > 0) tags.push(tag);
  }
  return Array.from(new Set(tags)).sort((a, b) => a - b);
}
// zone → vlantag (null if zone missing / no numeric tag).
function zoneVlantag(zoneName: string): number | null {
  if (!zoneName) return null;
  const z = readJson(zonesFile())[zoneName];
  if (isObj(z) && typeof z.vlantag === "number") return z.vlantag;
  return null;
}

// ── Argument parsing (flag map; preserves "unknown option" errors) ───
function parseFlags(args: string[], allowed: string[], ctx: string): Record<string, string> {
  const out: Record<string, string> = {};
  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (allowed.includes(a)) {
      out[a] = args[i + 1] ?? "";
      i += 2;
    } else {
      die(`${ctx}: unknown option '${a}'`);
    }
  }
  return out;
}

// ── Controller inventory ─────────────────────────────────────────────
function cmdAddController(args: string[]): number {
  const name = args[0];
  if (!name) die("add-controller requires a <name>");
  const f = parseFlags(args.slice(1), ["--vendor", "--ip", "--managed"], "add-controller");
  const vendor = f["--vendor"] ?? "";
  const ip = f["--ip"] ?? "";
  const managed = f["--managed"] ?? "auto";
  if (!vendor) die("add-controller requires --vendor");
  if (!ip) die("add-controller requires --ip");
  const a = loadActual();
  const controllers = obj(a.controllers);
  if (has(controllers, name)) die(`Controller '${name}' already exists`);
  controllers[name] = { vendor, managementIp: ip, managed };
  a.controllers = controllers;
  saveActual(a);
  info(`${GN}✓${CL} added controller '${name}' (${vendor}, ${ip})`);
  info("  run 'switch-manager interrogate' to upload its switches + ports");
  return 0;
}
function cmdRemoveController(name: string | undefined): number {
  if (!name) die("remove-controller requires a <name>");
  const a = loadActual();
  const controllers = obj(a.controllers);
  if (!has(controllers, name)) die(`Controller '${name}' not found`);
  delete controllers[name];
  a.controllers = controllers;
  saveActual(a);
  info(`${GN}✓${CL} removed controller '${name}'`);
  return 0;
}

// ── Switch inventory ─────────────────────────────────────────────────
function cmdAddSwitch(args: string[]): number {
  const name = args[0];
  if (!name) die("add-switch requires a <name>");
  const f = parseFlags(
    args.slice(1),
    ["--vendor", "--ip", "--managed", "--controller", "--model", "--location", "--description"],
    "add-switch",
  );
  const vendor = f["--vendor"] ?? "";
  const ip = f["--ip"] ?? "";
  const managed = f["--managed"] ?? "";
  const controller = f["--controller"] ?? "";
  const model = f["--model"] ?? "";
  const location = f["--location"] ?? "";
  const description = f["--description"] ?? "";
  if (!vendor) die("add-switch requires --vendor");
  if (!managed) die("add-switch requires --managed (auto|manual)");
  if (managed !== "auto" && managed !== "manual") die("add-switch: --managed must be 'auto' or 'manual'");
  const a = loadActual();
  if (controller && !has(obj(a.controllers), controller))
    die(`controller '${controller}' not found (add-controller first)`);
  const switches = obj(a.switches);
  if (has(switches, name)) die(`Switch '${name}' already exists (remove-switch first to recreate)`);
  switches[name] = {
    vendor,
    managed,
    controller: controller === "" ? null : controller,
    managementIp: ip,
    model,
    location,
    description,
    ports: {},
  };
  a.switches = switches;
  saveActual(a);
  const ctrlSuffix = controller ? `, controller=${controller}` : "";
  const ipSuffix = ip ? `, ${ip}` : "";
  info(`${GN}✓${CL} added switch '${name}' (${vendor}, ${managed}${ctrlSuffix}${ipSuffix})`);
  if (managed === "manual") {
    info(`  add its uplink ports:  switch-manager add-port ${name} <port> --type node --target tappaasN --target-port ethX`);
  } else if (!controller) {
    info("  run 'switch-manager interrogate' to upload its ports");
  }
  return 0;
}
function cmdRemoveSwitch(name: string | undefined): number {
  if (!name) die("remove-switch requires a <name>");
  const a = loadActual();
  const switches = obj(a.switches);
  if (!has(switches, name)) die(`Switch '${name}' not found`);
  delete switches[name];
  a.switches = switches;
  saveActual(a);
  info(`${GN}✓${CL} removed switch '${name}'`);
  return 0;
}

// ── Port inventory (add/update) ──────────────────────────────────────
function portSet(op: "add" | "update", args: string[]): number {
  const sw = args[0];
  const port = args[1];
  if (!sw || !port) die(`${op}-port requires <switch> <port>`);
  const a = loadActual();
  const switches = obj(a.switches);
  if (!has(switches, sw)) die(`Switch '${sw}' not found`);
  const swObj = obj(switches[sw]);
  const ports = obj(swObj.ports);
  const exists = has(ports, port);
  if (op === "add" && exists) die(`Port '${port}' already on '${sw}' (use update-port)`);
  if (op === "update" && !exists) die(`Port '${port}' not on '${sw}' (use add-port)`);

  const f = parseFlags(
    args.slice(2),
    ["--type", "--target", "--target-port", "--mode", "--zone", "--native", "--tagged", "--description"],
    `${op}-port`,
  );
  const type = f["--type"] ?? "";
  const target = f["--target"] ?? "";
  const targetPort = f["--target-port"] ?? "";
  const mode = f["--mode"] ?? "";
  const zone = f["--zone"] ?? "";
  const native = f["--native"] ?? "";
  const tagged = f["--tagged"] ?? "";
  const description = f["--description"] ?? "";

  if (type && !PORT_TYPES.includes(type)) die(`${op}-port: --type must be one of: ${PORT_TYPES.join(" ")}`);
  if (op === "add" && !type) die(`add-port requires --type (${PORT_TYPES.join(" ")})`);

  const upd: JObj = exists ? obj(ports[port]) : {};
  if (type) upd.type = type;
  if (target) upd.target = target;
  if (targetPort) upd.targetPort = targetPort;
  if (zone) upd.zone = zone;
  if (description) upd.description = description;
  if (native) upd.nativeVlan = JSON.parse(native) as Json;
  if (tagged) {
    upd.taggedVlans = Array.from(
      new Set(
        tagged
          .split(/[,;]/)
          .map((s) => s.trim())
          .filter((s) => s.length > 0)
          .map((s) => Number(s)),
      ),
    ).sort((x, y) => x - y);
  }

  // Set mode: explicit flag wins; else derive from the (possibly new) type.
  const effType = str(upd.type);
  if (mode) upd.mode = mode;
  else if (!str(upd.mode) && effType) upd.mode = isTrunkType(effType) ? "trunk" : "access";

  ports[port] = upd;
  swObj.ports = ports;
  switches[sw] = swObj;
  a.switches = switches;
  saveActual(a);
  info(`${GN}✓${CL} ${sw} port ${port}: ${JSON.stringify(upd)}`);
  return 0;
}
function cmdRemovePort(sw: string | undefined, port: string | undefined): number {
  if (!sw || !port) die("remove-port requires <switch> <port>");
  const a = loadActual();
  const switches = obj(a.switches);
  const swObj = obj(switches[sw]);
  const ports = obj(swObj.ports);
  if (!has(ports, port)) die(`Port '${port}' not found on '${sw}'`);
  delete ports[port];
  swObj.ports = ports;
  switches[sw] = swObj;
  a.switches = switches;
  saveActual(a);
  info(`${GN}✓${CL} removed port '${port}' from '${sw}'`);
  return 0;
}

// ── list / show ──────────────────────────────────────────────────────
function cmdList(): number {
  const a = loadActual();
  const controllers = obj(a.controllers);
  const switches = obj(a.switches);
  info(`${BOLD}Controllers (${Object.keys(controllers).length}):${CL}`);
  for (const [k, vRaw] of Object.entries(controllers)) {
    const v = obj(vRaw);
    info(`  ${k}  [${str(v.vendor)}]  ${str(v.managementIp)}`);
  }
  info(`${BOLD}Switches (${Object.keys(switches).length}):${CL}`);
  for (const [k, vRaw] of Object.entries(switches)) {
    const v = obj(vRaw);
    const via = v.controller ? ` via ${str(v.controller)}` : "";
    info(`  ${k}  [${str(v.vendor)}]  ${str(v.managed)}${via}  ports=${Object.keys(obj(v.ports)).length}`);
  }
  const aps = obj(a.accessPoints);
  if (Object.keys(aps).length > 0)
    info(`${BOLD}Access points (${Object.keys(aps).length}):${CL} (manage with ap-manager)`);
  return 0;
}
function cmdShow(name: string | undefined): number {
  if (!name) die("show requires a <name>");
  const a = loadActual();
  const switches = obj(a.switches);
  const controllers = obj(a.controllers);
  if (has(switches, name)) console.log(JSON.stringify(switches[name], null, 2));
  else if (has(controllers, name)) console.log(JSON.stringify(controllers[name], null, 2));
  else die(`No controller or switch named '${name}'`);
  return 0;
}

// ── list-ports: one line per port, actual config + drift vs desired ──
function cmdListPorts(target: string | undefined): number {
  const a = loadActual();
  const switches = obj(a.switches);
  if (target && !has(switches, target)) die(`Switch '${target}' not found`);
  const active = activeVlans();
  const swNames = target ? [target] : Object.keys(switches);
  for (const sw of swNames) {
    if (!sw) continue;
    info(`${BOLD}${sw}${CL} — actual port config (drift vs zones.json):`);
    const ports = obj(obj(switches[sw]).ports);
    for (const k of Object.keys(ports).sort((x, y) => Number(x) - Number(y))) {
      const p = obj(ports[k]);
      const t = str(p.type);
      const atag = intArray(p.taggedVlans);
      const anat = num(p.nativeVlan);
      const amode = str(p.mode) || "?";

      let desired: { mode: "trunk" | "access"; tagged: number[]; nat: number } | null;
      if (t === "node" || t === "switch" || t === "uplink" || t === "ap") {
        desired = { mode: "trunk", tagged: active, nat: 0 };
      } else if (t === "device") {
        const zv = zoneVlantag(str(p.zone));
        desired = { mode: "access", tagged: [], nat: zv !== null ? zv : anat };
      } else {
        desired = null;
      }

      let status: string;
      if (desired === null) {
        status = "untouched (unmanaged)";
      } else if (desired.mode === "trunk") {
        const add = desired.tagged.filter((v) => !atag.includes(v));
        const rem = atag.filter((v) => !desired!.tagged.includes(v));
        status = add.length > 0 || rem.length > 0 ? `DRIFT +${add.join(",")} -${rem.join(",")}` : "in sync";
      } else {
        status = desired.nat !== anat ? `DRIFT native ${anat} -> ${desired.nat}` : "in sync";
      }

      const targetPart =
        t === "" ? "—" : `${t} → ${str(p.target) || "?"}${p.targetPort ? "/" + str(p.targetPort) : ""}`;
      const actualPart = amode === "access" ? `vlan ${anat}` : atag.length > 0 ? atag.map(String).join(",") : "-";
      info(`  port ${k}: ${targetPart}  | actual: ${amode} ${actualPart}  | ${status}`);
    }
  }
  if (!(target || Object.keys(switches).length > 0)) info("  (no switches in inventory)");
  return 0;
}

// ── Plugin FFI (shell out to bash: `. "$plugin"; plugin_fn "$@"`) ─────
// The entire vendor boundary is crossed here — TS spawns across it, it does not
// replace bash. PLUGIN_DIR is honoured so the oracle can supply stub plugins.
function pluginCall(plugin: string, fn: string, args: string[]): { status: number; stdout: string; stderr: string } {
  const r = spawnSync("bash", ["-c", `. "$1"; shift; ${fn} "$@"`, "bash", plugin, ...args], {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (r.error) die(`plugin ${plugin}: ${r.error.message}`);
  return { status: r.status ?? 1, stdout: r.stdout, stderr: r.stderr };
}
function pluginHasFn(plugin: string, fn: string): boolean {
  const r = spawnSync("bash", ["-c", `. "$1" >/dev/null 2>&1; declare -F ${fn} >/dev/null`, "bash", plugin], {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 1024 * 1024,
  });
  return (r.status ?? 1) === 0;
}
function pluginSupports(plugin: string, vendor: string): boolean {
  const r = spawnSync(
    "bash",
    ["-c", `. "$1" >/dev/null 2>&1; plugin_supports "$2" >/dev/null 2>&1`, "bash", plugin, vendor],
    { encoding: "utf8", env: process.env, maxBuffer: 1024 * 1024 },
  );
  return (r.status ?? 1) === 0;
}
// Select a vendor plugin from PLUGIN_DIR; manual.sh is the last-resort fallback.
function selectPlugin(vendor: string): string {
  let files: string[];
  try {
    files = readdirSync(PLUGIN_DIR).filter((f) => f.endsWith(".sh"));
  } catch {
    files = [];
  }
  for (const f of files.sort()) {
    if (f === "manual.sh") continue;
    const p = join(PLUGIN_DIR, f);
    if (pluginSupports(p, vendor)) return p;
  }
  return join(PLUGIN_DIR, "manual.sh");
}
// Plugin for an inventory switch, honouring managed:manual (always manual.sh).
function pluginForSwitch(a: JObj, name: string): string {
  const sw = obj(obj(a.switches)[name]);
  if ((str(sw.managed) || "auto") === "manual") return join(PLUGIN_DIR, "manual.sh");
  return selectPlugin(str(sw.vendor));
}

function parseJsonLoose(text: string): Json | undefined {
  const t = text.trim();
  if (!t) return undefined;
  try {
    return JSON.parse(t) as Json;
  } catch {
    return undefined;
  }
}
// Deep merge mirroring jq's `*`: objects merge recursively, other values
// (incl. arrays) are replaced by the right-hand side.
function mergeDeep(a: Json, b: Json): Json {
  if (isObj(a) && isObj(b)) {
    const out: JObj = { ...a };
    for (const [k, v] of Object.entries(b)) out[k] = has(out, k) ? mergeDeep(out[k], v) : v;
    return out;
  }
  return b;
}

// ── Verb 1: interrogate (controllers + auto switches → actual) ───────
function cmdInterrogate(): number {
  info(`${BOLD}interrogate${CL} (controllers + auto switches → actual.json)`);
  ensureFiles();
  let a = loadActual();
  let d = loadDesired();

  for (const name of Object.keys(obj(a.controllers))) {
    const ctrl = obj(obj(a.controllers)[name]);
    const vendor = str(ctrl.vendor);
    const ip = str(ctrl.managementIp);
    const plugin = selectPlugin(vendor);
    if (!pluginHasFn(plugin, "plugin_controller_interrogate")) {
      info(`  controller ${name}: ${vendor} plugin has no controller interrogate — skipped`);
      continue;
    }
    const res = pluginCall(plugin, "plugin_controller_interrogate", [name, ip]);
    const state = parseJsonLoose(res.stdout);
    if (state === undefined || !isObj(state)) {
      warn(`  controller ${name}: no/invalid response (unreachable or rate-limited?) — left actual unchanged`);
      continue;
    }
    if (Object.keys(state).length === 0) {
      info(`  controller ${name}: nothing uploaded`);
      continue;
    }
    const stSwitches = obj(state.switches);
    const stAps = obj(state.aps);

    // ACTUAL: merge each reported switch (live config over operator annotations).
    const switches = obj(a.switches);
    for (const [sk, svRaw] of Object.entries(stSwitches)) {
      const merged = obj(mergeDeep(obj(switches[sk]), svRaw));
      merged.controller = name;
      merged.managed = "auto";
      switches[sk] = merged;
    }
    // Mark each AP's wired uplink switch port as an AP trunk.
    for (const [apName, aRaw] of Object.entries(stAps)) {
      const ap = obj(aRaw);
      const usw = str(ap.uplinkSwitch);
      const up = str(ap.uplinkPort);
      if (usw !== "" && up !== "" && switches[usw] != null) {
        const swObj = obj(switches[usw]);
        const ports = obj(swObj.ports);
        ports[up] = { ...obj(ports[up]), type: "ap", target: apName, mode: "trunk" };
        swObj.ports = ports;
        switches[usw] = swObj;
      }
    }
    a.switches = switches;
    saveActual(a);
    a = loadActual();

    // DESIRED: auto-register discovered APs into ap-manager's inventory.
    if (Object.keys(stAps).length > 0) {
      const accessPoints = obj(d.accessPoints);
      for (const [apName, aRaw] of Object.entries(stAps)) {
        const ap = obj(aRaw);
        const existing = obj(accessPoints[apName]);
        accessPoints[apName] = {
          ...existing,
          vendor: ap.vendor ?? null,
          model: ap.model ?? null,
          managementIp: ap.managementIp ?? null,
          uplinkSwitch: ap.uplinkSwitch ?? null,
          uplinkPort: ap.uplinkPort ?? null,
          ssids: obj(existing.ssids),
        };
      }
      d.accessPoints = accessPoints;
      saveDesired(d);
      d = loadDesired();
    }
    info(`  controller ${name}: uploaded ${Object.keys(stSwitches).length} switch(es), ${Object.keys(stAps).length} AP(s)`);
  }

  // Standalone auto switches (no controller, brand has a device plugin).
  a = loadActual();
  const standalone = Object.entries(obj(a.switches))
    .filter(([, sv]) => obj(sv).controller == null)
    .map(([k]) => k);
  for (const name of standalone) {
    const plugin = pluginForSwitch(a, name);
    if (basename(plugin) === "manual.sh") continue;
    if (!pluginHasFn(plugin, "plugin_interrogate")) continue;
    const ip = str(obj(obj(a.switches)[name]).managementIp);
    const res = pluginCall(plugin, "plugin_interrogate", [name, ip]);
    const state = parseJsonLoose(res.stdout);
    if (state === undefined || !isObj(state)) {
      warn(`  switch ${name}: no/invalid response — left actual unchanged`);
      continue;
    }
    if (Object.keys(state).length === 0) continue;
    const switches = obj(a.switches);
    switches[name] = obj(mergeDeep(obj(switches[name]), state));
    a.switches = switches;
    saveActual(a);
    a = loadActual();
    info(`  switch ${name}: uploaded ${Object.keys(obj(state.ports)).length} port(s)`);
  }
  return 0;
}

// ── Verb 2: update-desired (regenerate desired from actual + zones) ──
function cmdUpdateDesired(): number {
  info(`${BOLD}update-desired${CL} (actual topology + zones.json → desired.json)`);
  ensureFiles();
  const active = activeVlans();
  const a = loadActual();
  const cur = loadDesired();

  const des: JObj = { ...cur };
  des.controllers = obj(a.controllers);

  const newSwitches: JObj = {};
  for (const [sk, svRaw] of Object.entries(obj(a.switches))) {
    const sw = obj(svRaw);
    const ports = obj(sw.ports);
    const newPorts: JObj = {};
    for (const [pk, pRaw] of Object.entries(ports)) {
      const p = obj(pRaw);
      const t = str(p.type);
      if (t === "node" || t === "switch" || t === "uplink" || t === "ap") {
        newPorts[pk] = { ...p, mode: "trunk", taggedVlans: active.slice() };
      } else if (t === "device") {
        const zv = zoneVlantag(str(p.zone));
        newPorts[pk] = { ...p, mode: "access", nativeVlan: zv !== null ? zv : num(p.nativeVlan) };
      } else {
        newPorts[pk] = p;
      }
    }
    newSwitches[sk] = { ...sw, ports: newPorts };
  }
  des.switches = newSwitches;
  saveDesired(des);
  info(`  active VLAN set: ${active.join(",")}`);
  info(`  desired regenerated for ${Object.keys(newSwitches).length} switch(es)`);
  return 0;
}

// ── Verb 3: delta (desired vs actual, per port) ──────────────────────
interface Change {
  action: string;
  port: string;
  description: string;
}
function computeDelta(): { [sw: string]: Change[] } {
  const des = obj(loadDesired().switches);
  const act = obj(loadActual().switches);
  const out: { [sw: string]: Change[] } = {};
  for (const sw of Object.keys(des)) {
    const changes: Change[] = [];
    const desPorts = obj(obj(des[sw]).ports);
    const actPorts = obj(obj(act[sw]).ports);
    for (const [pk, pRaw] of Object.entries(desPorts)) {
      const p = obj(pRaw);
      const ap = obj(actPorts[pk]);
      const mode = str(p.mode);
      if (mode === "trunk") {
        const want = intArray(p.taggedVlans);
        const have = intArray(ap.taggedVlans);
        const addv = want.filter((v) => !have.includes(v));
        const delv = have.filter((v) => !want.includes(v));
        if (addv.length > 0 || delv.length > 0) {
          changes.push({
            action: "trunk-vlans",
            port: pk,
            description: `port ${pk} (${str(p.type) || "trunk"} ${str(p.target)}) trunk: +${addv.join(",")} -${delv.join(",")}`,
          });
        }
      } else if (mode === "access") {
        const wantNat = num(p.nativeVlan);
        const haveNat = num(ap.nativeVlan);
        if (wantNat !== haveNat) {
          changes.push({ action: "access-vlan", port: pk, description: `port ${pk} access VLAN ${haveNat} -> ${wantNat}` });
        }
      }
    }
    out[sw] = changes;
  }
  return out;
}
function cmdDelta(): { rc: number; total: number } {
  const delta = computeDelta();
  info(`${BOLD}delta${CL} (desired vs actual)`);
  let total = 0;
  const keys = Object.keys(delta);
  for (const sw of keys) {
    const changes = delta[sw];
    total += changes.length;
    if (changes.length > 0) {
      warn(`  ${sw}: ${changes.length} change(s)`);
      for (const c of changes) info(`      ${c.action}: ${c.description}`);
    } else {
      info(`  ${GN}✓${CL} ${sw}: in sync`);
    }
  }
  if (keys.length === 0) info("  (no switches in inventory)");
  return { rc: 0, total };
}

// ── Verb 4: apply (plugin push / manual print) ───────────────────────
function cmdApply(autoconfirm: boolean): { manual: number; applied: number } {
  const delta = computeDelta();
  info(`${BOLD}apply${CL}`);
  const a = loadActual();
  let manual = 0;
  let applied = 0;
  for (const sw of Object.keys(delta)) {
    const changes = delta[sw];
    if (changes.length === 0) continue;
    const plugin = pluginForSwitch(a, sw);
    const env = { ...process.env };
    if (autoconfirm) env.SM_AUTOCONFIRM = "1";
    const r = spawnSync(
      "bash",
      ["-c", `. "$1"; shift; plugin_apply "$@"`, "bash", plugin, sw, JSON.stringify({ changes })],
      { encoding: "utf8", env, maxBuffer: 32 * 1024 * 1024 },
    );
    if (r.stdout) process.stdout.write(r.stdout);
    if (r.stderr) process.stderr.write(r.stderr);
    if ((r.status ?? 1) === 0) {
      info(`  ${GN}✓${CL} ${sw}: applied via ${basename(plugin, ".sh")}`);
      applied += 1;
    } else {
      manual += 1;
    }
  }
  return { manual, applied };
}

// ── Verb 5: confirm (record applied VLAN config into actual) ─────────
function cmdConfirm(): number {
  info(`${BOLD}confirm${CL} (record applied VLAN config in actual.json)`);
  ensureFiles();
  const a = loadActual();
  const des = obj(loadDesired().switches);
  const switches = obj(a.switches);
  for (const [sw, svRaw] of Object.entries(switches)) {
    const s = obj(svRaw);
    const ports = obj(s.ports);
    const desPorts = obj(obj(des[sw]).ports);
    for (const [pk, pRaw] of Object.entries(ports)) {
      const dp = obj(desPorts[pk]);
      const overlay: JObj = {};
      for (const key of ["mode", "nativeVlan", "taggedVlans"] as const) {
        if (dp[key] !== undefined && dp[key] !== null) overlay[key] = dp[key];
      }
      ports[pk] = { ...obj(pRaw), ...overlay };
    }
    s.ports = ports;
    switches[sw] = s;
  }
  a.switches = switches;
  saveActual(a);
  info(`  ${GN}✓${CL} actual.json updated to match applied desired state`);
  return 0;
}

// ── reconcile (interrogate → update-desired → delta → apply → confirm) ─
function cmdReconcile(apply: boolean): number {
  cmdInterrogate();
  info("");
  cmdUpdateDesired();
  info("");
  const d = cmdDelta();
  info("");
  if (apply) {
    const ap = cmdApply(true);
    info("");
    cmdConfirm();
    info("");
    if (ap.manual > 0) {
      warn(`switch-manager: ${ap.manual} manual switch(es) — apply the VLANs printed above on the hardware (actual.json now records the intended config).`);
    }
    info(`${GN}switch-manager: applied${CL} (${ap.applied} via plugin, ${ap.manual} manual)`);
    return 0;
  }
  if (d.total > 0) {
    warn(`switch-manager: ${d.total} change(s) pending. Re-run with --apply.`);
    return 2;
  }
  info(`${GN}switch-manager: in sync${CL}`);
  return 0;
}

// ── Usage ────────────────────────────────────────────────────────────
const USAGE = `Usage: switch-manager <command> [args]

Inventory (recorded in switch-configuration-actual.json):
  add-controller <name> --vendor <v> --ip <ip> [--managed auto]
  remove-controller <name>
  add-switch <name> --vendor <v> --managed auto|manual [--controller <c>]
        [--ip <ip>] [--model <m>] [--location <l>] [--description <d>]
  remove-switch <name>
  add-port <switch> <port> --type node|switch|ap|device|uplink
        [--target <t>] [--target-port <tp>] [--mode trunk|access]
        [--zone <z>] [--native <vlan>] [--tagged 210,220] [--description <d>]
  update-port <switch> <port> [ ...same flags... ]
  remove-port <switch> <port>
  list
  list-ports [<switch>]   one line per port: actual config + drift vs zones.json
  show <controller|switch>

Reconciliation (five-verb provider contract, run in this order):
  interrogate             controller/auto switches -> actual.json (via plugin)
  update-desired          actual topology + zones.json -> desired.json
  delta                   desired-vs-actual VLAN differences per port
  apply                   push delta via plugin (manual plugin prints steps)
  confirm                 record applied VLAN config in actual.json
  reconcile [--apply]     run all five in order (apply only with --apply)

managed:manual switches are configured by hand (manual.sh prints what to tag);
managed:auto switches are programmed by their vendor plugin.`;

// ── Main ─────────────────────────────────────────────────────────────
function dispatch(argv: string[]): number {
  const cmd = argv[0];
  if (!cmd || cmd === "-h" || cmd === "--help") {
    info(USAGE);
    return 0;
  }
  if (cmd === "--version" || cmd === "version") {
    info(`switch-controller ${VERSION}`);
    return 0;
  }
  const rest = argv.slice(1);

  if (!existsSync(zonesFile())) die(`zones.json not found: ${zonesFile()}`);
  ensureFiles();

  switch (cmd) {
    case "add-controller":
      return cmdAddController(rest);
    case "remove-controller":
      return cmdRemoveController(rest[0]);
    case "add-switch":
      return cmdAddSwitch(rest);
    case "remove-switch":
      return cmdRemoveSwitch(rest[0]);
    case "add-port":
      return portSet("add", rest);
    case "update-port":
      return portSet("update", rest);
    case "remove-port":
      return cmdRemovePort(rest[0], rest[1]);
    case "list":
      return cmdList();
    case "list-ports":
    case "--list-ports":
      return cmdListPorts(rest[0]);
    case "show":
      return cmdShow(rest[0]);
    case "interrogate":
      return cmdInterrogate();
    case "update-desired":
      return cmdUpdateDesired();
    case "delta":
      return cmdDelta().rc;
    case "apply":
      cmdApply(false);
      return 0;
    case "confirm":
      return cmdConfirm();
    case "reconcile":
      return cmdReconcile(rest[0] === "--apply");
    default:
      return die(`Unknown command: ${cmd} (try --help)`);
  }
}

function main(): void {
  let code = 0;
  try {
    code = dispatch(process.argv.slice(2));
  } catch (e) {
    code = 1;
    if (!(e instanceof DieError)) {
      console.error(`${RD}[Error]${CL} ${(e as Error).message ?? String(e)}`);
    }
  }
  process.exit(code);
}

main();
