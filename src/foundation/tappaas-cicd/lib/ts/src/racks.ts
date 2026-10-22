// racks.ts — config/racks.json and the faceplate catalog: where the site's
// hardware sits (schemas/racks-fields.json). rack-manager writes the document
// and validates it here; network-manager's topology resolves it against the
// site here (mounts to devices, links to faceplate ports). Pure: documents and
// catalogs in, findings and views out.
//
// Devices are named as the topology names them; a rack never holds a copy of
// a device's record. A cable the switches or LLDP can see comes from the
// topology; racks.json records only the ones nothing can see.

export const RACKS_FILE = "racks.json";
export const RACK_NAME_RE = /^[a-z][a-z0-9-]{0,62}$/;
export const FACEPLATE_KEY_RE = /^[a-z0-9][a-z0-9-]*\/[a-z0-9][a-z0-9.+-]*$/;

export const RACK_WIDTHS = ["19in", "10in"] as const;
export const NUMBERINGS = ["bottom-up", "top-down"] as const;
export const MOUNT_WIDTHS = ["full", "half", "third"] as const;
export const FACES = ["front", "rear"] as const;
export const CABLE_KINDS = ["patch", "uplink", "power"] as const;
export const PORT_KINDS = ["rj45", "sfp+", "sfp28", "poe", "console", "power"] as const;
export const PLATE_KINDS = ["server", "switch", "ap", "patch-panel", "pdu", "modem", "other"] as const;

export type RackWidth = (typeof RACK_WIDTHS)[number];
export type Numbering = (typeof NUMBERINGS)[number];
export type MountWidth = (typeof MOUNT_WIDTHS)[number];
export type Face = (typeof FACES)[number];
export type CableKind = (typeof CABLE_KINDS)[number];
export type PortKind = (typeof PORT_KINDS)[number];
export type PlateKind = (typeof PLATE_KINDS)[number];

export interface Rack {
  displayName?: string;
  units: number;
  width: RackWidth;
  numbering: Numbering;
  building?: string;
  room?: string;
  description?: string;
}
export interface Mount {
  rack: string;
  u: number;
  height: number;
  width: MountWidth;
  slot?: number;
  face: Face;
  faceplate?: string;
  label?: string;
  description?: string;
}
export interface CableEnd {
  device: string;
  port: string;
  faceplate?: string; // a device only this cable places (the ISP's modem)
}
export interface Cable {
  from: CableEnd;
  to: CableEnd;
  kind: CableKind;
  label?: string;
}
export interface RacksDoc {
  version?: 1;
  racks?: Record<string, Rack>;
  mounts?: Record<string, Mount>;
  cables?: Cable[];
}

export const racksOf = (d: RacksDoc): Record<string, Rack> => d.racks ?? {};
export const mountsOf = (d: RacksDoc): Record<string, Mount> => d.mounts ?? {};
export const cablesOf = (d: RacksDoc): Cable[] => d.cables ?? [];

// ── the catalog ───────────────────────────────────────────────────────

// A port as the catalog spells it: its name as the controller names it
// ("Port 11", "sfp-sfpplus1"); its id, the topology's, when that differs
// from what the name gives ("Port 11" → "11").
export interface CatalogPort {
  name: string;
  id?: string;
  kind: PortKind;
}
export interface Faceplate {
  key: string; // <vendor>/<model>, its path in the catalog
  vendor: string;
  model: string;
  match?: string[]; // the models and names the inventories report it by
  kind: PlateKind;
  units: number;
  width: MountWidth;
  // A device nothing can see (patch panel, PDU, modem): mounted without a
  // topology device.
  passive?: boolean;
  // A generic plate is filled from the device: its NICs (a server), or its
  // ports (a switch). rows then holds what is fixed (a console, power).
  generic?: "nics" | "ports";
  // Port rows, top to bottom; null is a gap.
  rows: (CatalogPort | null)[][];
  labels?: { text: string; at?: "left" | "right" }[];
  description?: string;
}

// A port's topology id: its id, else the number of "Port N", else its name.
export function portId(p: CatalogPort): string {
  if (p.id) return p.id;
  const m = /^port\s*(\d+)$/i.exec(p.name.trim());
  return m ? m[1] : p.name;
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const isStr = (v: unknown): v is string => typeof v === "string" && v !== "";

// A catalog entry read from its file: what is wrong with it, or the entry.
export function parseFaceplate(key: string, raw: unknown): Faceplate | { error: string } {
  const o = obj(raw);
  if (!FACEPLATE_KEY_RE.test(key)) return { error: `${key}: a faceplate is <vendor>/<model>.json, lower case` };
  if (!isStr(o.vendor) || !isStr(o.model)) return { error: `${key}: vendor and model are required` };
  if (!PLATE_KINDS.includes(o.kind as PlateKind)) return { error: `${key}: kind is one of ${PLATE_KINDS.join(", ")}` };
  if (!Number.isInteger(o.units) || (o.units as number) < 1) return { error: `${key}: units is a whole number of rack units` };
  if (!MOUNT_WIDTHS.includes((o.width ?? "full") as MountWidth)) return { error: `${key}: width is one of ${MOUNT_WIDTHS.join(", ")}` };
  if (o.generic !== undefined && o.generic !== "nics" && o.generic !== "ports") return { error: `${key}: generic is nics or ports` };
  if (!Array.isArray(o.rows)) return { error: `${key}: rows is a list of port rows` };
  const rows: (CatalogPort | null)[][] = [];
  const ids = new Set<string>();
  for (const [i, r] of (o.rows as unknown[]).entries()) {
    if (!Array.isArray(r)) return { error: `${key}: row ${i + 1} is not a list` };
    const row: (CatalogPort | null)[] = [];
    for (const c of r) {
      if (c === null) {
        row.push(null);
        continue;
      }
      const p = obj(c);
      if (!isStr(p.name)) return { error: `${key}: row ${i + 1} has a port with no name` };
      if (!PORT_KINDS.includes(p.kind as PortKind)) return { error: `${key}: port ${p.name}: kind is one of ${PORT_KINDS.join(", ")}` };
      const port: CatalogPort = { name: p.name, kind: p.kind as PortKind, ...(isStr(p.id) ? { id: p.id } : {}) };
      if (ids.has(portId(port))) return { error: `${key}: port ${portId(port)} appears twice` };
      ids.add(portId(port));
      row.push(port);
    }
    rows.push(row);
  }
  return {
    key,
    vendor: o.vendor,
    model: o.model,
    ...(Array.isArray(o.match) ? { match: o.match.filter(isStr) } : {}),
    kind: o.kind as PlateKind,
    units: o.units as number,
    width: (o.width ?? "full") as MountWidth,
    ...(o.passive === true ? { passive: true } : {}),
    ...(o.generic ? { generic: o.generic as "nics" | "ports" } : {}),
    rows,
    ...(Array.isArray(o.labels) ? { labels: o.labels.map(obj).filter((l) => isStr(l.text)).map((l) => ({ text: l.text as string, ...(l.at === "left" || l.at === "right" ? { at: l.at } : {}) })) } : {}),
    ...(isStr(o.description) ? { description: o.description } : {}),
  };
}

// ── the site's devices, as the topology names them ─────────────────────

// The parts of `network-manager topology --json` read here (structural: lib/ts
// does not import a manager's types).
export interface TopoLike {
  nodes?: { name: string; uplinks?: { name: string; mode?: string; bond?: string | null; legs?: { nic: string; speed?: string | null; up?: boolean; peer?: { switch: string; port: string } | null }[] }[] }[];
  switches?: {
    name: string;
    vendor?: string | null;
    model?: string | null;
    ports?: { port: string; role?: string; link?: string | null; disabled?: boolean; lag?: string | null; zones?: string[]; target?: { kind: string; name: string | null; port: string | null } | null }[];
  }[];
  accessPoints?: { name: string; vendor?: string | null; model?: string | null; uplink?: { switch: string; port: string } | null }[];
  devices?: { name: string; kind: string; vendor?: string | null; model?: string | null }[];
}

export type DeviceKind = "node" | "switch" | "ap" | "machine" | "device";
export interface SiteDevice {
  name: string;
  kind: DeviceKind;
  vendor: string | null;
  model: string | null;
  ports: { id: string; up: boolean | null; lag: string | null; zones: string[]; disabled: boolean }[];
}

const canon = (s: string | null | undefined): string => (s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
const portCompare = (a: string, b: string): number => a.localeCompare(b, "en", { numeric: true });

// Every device the topology knows, with the ports it knows on each: a node's
// NICs (its uplinks' legs), a switch's ports, an access point's uplink, and
// the machines and devices the topology lists by name.
export function siteDevices(t: TopoLike): SiteDevice[] {
  const out: SiteDevice[] = [];
  for (const n of t.nodes ?? []) {
    const ports: SiteDevice["ports"] = [];
    for (const u of n.uplinks ?? []) {
      for (const l of u.legs ?? []) {
        if (ports.some((p) => p.id === l.nic)) continue;
        ports.push({ id: l.nic, up: typeof l.up === "boolean" ? l.up : null, lag: u.mode === "lacp" && u.bond ? u.bond : null, zones: [], disabled: false });
      }
    }
    out.push({ name: n.name, kind: "node", vendor: null, model: null, ports });
  }
  for (const s of t.switches ?? []) {
    out.push({
      name: s.name,
      kind: "switch",
      vendor: s.vendor ?? null,
      model: s.model ?? null,
      ports: (s.ports ?? []).map((p) => ({ id: p.port, up: p.link === "up" ? true : p.link === "down" ? false : null, lag: p.lag ?? null, zones: p.zones ?? [], disabled: p.disabled === true })),
    });
  }
  for (const a of t.accessPoints ?? []) {
    // The AP's link is its switch port's.
    const sp = a.uplink ? (t.switches ?? []).find((s) => s.name === a.uplink!.switch)?.ports?.find((p) => p.port === a.uplink!.port) : undefined;
    out.push({ name: a.name, kind: "ap", vendor: a.vendor ?? null, model: a.model ?? null, ports: [{ id: "uplink", up: sp?.link === "up" ? true : sp?.link === "down" ? false : null, lag: null, zones: sp?.zones ?? [], disabled: false }] });
  }
  for (const d of t.devices ?? []) {
    if (out.some((x) => x.name === d.name)) continue;
    out.push({ name: d.name, kind: d.kind === "machine" ? "machine" : "device", vendor: d.vendor ?? null, model: d.model ?? null, ports: [] });
  }
  return out;
}

// The catalog's plate for a device's model, else the generic one for its kind.
export function suggestFaceplate(catalog: Faceplate[], d: { kind: DeviceKind | "passive"; vendor?: string | null; model?: string | null; name?: string }): string | null {
  const names = [d.model, d.name].map(canon).filter((x) => x !== "");
  const hit = catalog.find((f) => !f.generic && [f.model, ...(f.match ?? [])].some((m) => names.includes(canon(m))));
  if (hit) return hit.key;
  const generic: Record<string, string> = { node: "generic/server-2u", switch: "generic/switch-1u", machine: "generic/server-1u" };
  const g = generic[d.kind];
  return g && catalog.some((f) => f.key === g) ? g : null;
}

// ── a plate, resolved for its device ───────────────────────────────────

export interface PlatePort {
  id: string; // the topology's
  name: string; // the controller's
  kind: PortKind;
  up: boolean | null;
  disabled: boolean;
  lag: string | null;
  zones: string[];
}
export interface ResolvedPlate {
  key: string;
  vendor: string;
  model: string;
  kind: PlateKind;
  units: number;
  width: MountWidth;
  passive: boolean;
  rows: (PlatePort | null)[][];
  labels: { text: string; at?: "left" | "right" }[];
}

// What kind of port a topology id is, when a generic plate has to guess.
function guessKind(id: string): PortKind {
  if (/sfp28/i.test(id)) return "sfp28";
  if (/sfp|qsfp/i.test(id)) return "sfp+";
  if (/console|serial/i.test(id)) return "console";
  return "rj45";
}

// A plate for a device: the catalog's rows with the device's live state on each
// port, or for a generic plate the device's own ports (a server's NICs in one
// row, a switch's ports odd over even).
export function resolvePlate(f: Faceplate, dev: SiteDevice | null): ResolvedPlate {
  const live = (id: string) => dev?.ports.find((p) => p.id === id);
  const port = (id: string, name: string, kind: PortKind): PlatePort => {
    const l = live(id);
    return { id, name, kind, up: l?.up ?? null, disabled: l?.disabled ?? false, lag: l?.lag ?? null, zones: l?.zones ?? [] };
  };
  const fixed = f.rows.map((r) => r.map((c) => (c ? port(portId(c), c.name, c.kind) : null)));
  let rows = fixed;
  if (f.generic && dev) {
    const known = new Set(fixed.flat().filter((p): p is PlatePort => !!p).map((p) => p.id));
    const own = dev.ports.map((p) => p.id).filter((id) => !known.has(id)).sort(portCompare);
    const plate = own.map((id) => port(id, id, guessKind(id)));
    if (f.generic === "nics") rows = [plate, ...fixed].filter((r) => r.length > 0);
    else {
      // A switch: odd ports over even, as most front panels have them.
      const top = plate.filter((_, i) => i % 2 === 0);
      const bottom = plate.filter((_, i) => i % 2 === 1);
      rows = [top, bottom, ...fixed].filter((r) => r.length > 0);
    }
  }
  return { key: f.key, vendor: f.vendor, model: f.model, kind: f.kind, units: f.units, width: f.width, passive: f.passive === true, rows, labels: f.labels ?? [] };
}

export const platePorts = (p: ResolvedPlate): PlatePort[] => p.rows.flat().filter((x): x is PlatePort => !!x);

// A plate as text, one line per port row: `faceplates show`.
export function renderPlate(p: ResolvedPlate): string[] {
  const head = `${p.key} — ${p.vendor} ${p.model} · ${p.units}U ${p.width === "full" ? "full width" : `${p.width} width`} · ${p.kind}${p.passive ? " (passive)" : ""}`;
  const cells = p.rows.map((r) => r.map((c) => (c ? `[${c.id === c.name ? c.id : `${c.id} ${c.name}`}·${c.kind}${c.up === true ? " up" : c.up === false ? " down" : ""}]` : "")));
  const w = Math.max(4, ...cells.flat().map((c) => c.length));
  const lines = [head];
  if (cells.length === 0 || cells.every((r) => r.length === 0)) lines.push("  (no ports — filled from the device)");
  for (const r of cells) lines.push(`  ${r.map((c) => c.padEnd(w)).join(" ")}`.trimEnd());
  for (const l of p.labels) lines.push(`  label${l.at ? ` (${l.at})` : ""}: ${l.text}`);
  return lines;
}

// ── validation ────────────────────────────────────────────────────────

export interface RackFinding {
  severity: "error" | "warn";
  message: string;
}

const COLUMNS: Record<MountWidth, number> = { full: 1, half: 2, third: 3 };

// The share of the rack's width a mount takes, as [from, to) in sixths.
export function columnSpan(m: Pick<Mount, "width" | "slot">): [number, number] {
  const n = COLUMNS[m.width] ?? 1;
  const s = m.width === "full" ? 0 : m.slot ?? 0;
  return [(s * 6) / n, ((s + 1) * 6) / n];
}

// Where an end of a cable is: a topology device's port, a mounted device's
// plate port, or a port of the faceplate the end itself names.
function endProblem(e: CableEnd, devices: SiteDevice[] | null, plateOf: (device: string) => Faceplate | null, catalog: Faceplate[]): string | null {
  if (!isStr(e?.device) || !isStr(e?.port)) return "an end names no device or no port";
  const fp = e.faceplate ? catalog.find((f) => f.key === e.faceplate) ?? null : plateOf(e.device);
  if (e.faceplate && !fp) return `${e.device}: faceplate ${e.faceplate} is not in the catalog`;
  const plateIds = fp ? fp.rows.flat().filter((p): p is CatalogPort => !!p).map(portId) : [];
  const dev = devices?.find((d) => d.name === e.device) ?? null;
  if (plateIds.includes(e.port) || dev?.ports.some((p) => p.id === e.port)) return null;
  // A generic plate takes the device's ports, which only the topology knows.
  if (fp?.generic && devices === null) return null;
  if (!dev && !fp) return devices === null ? null : `${e.device} is not a device of the topology, mounted, or given a faceplate`;
  return `${e.device} has no port ${e.port}${fp ? ` (faceplate ${fp.key}: ${plateIds.join(", ") || "its ports come from the device"})` : ""}`;
}

// checkRacks — the whole document: every mount names a device the topology
// knows (or a passive plate's own), no two mounts overlap in a rack, each fits
// its rack, every faceplate key is in the catalog, every cable end names a
// port the topology or the catalog has. devices null: the topology could not
// be read, and the device checks are skipped with a warning.
export function checkRacks(doc: RacksDoc, catalog: Faceplate[], devices: SiteDevice[] | null): RackFinding[] {
  const out: RackFinding[] = [];
  const err = (message: string) => out.push({ severity: "error", message });
  const warn = (message: string) => out.push({ severity: "warn", message });
  const racks = racksOf(doc);
  const mounts = mountsOf(doc);
  const byKey = (k: string | undefined) => (k ? catalog.find((f) => f.key === k) ?? null : null);
  if (devices === null) warn("the topology could not be read: the devices and their ports are not checked");

  for (const [name, r] of Object.entries(racks)) {
    if (!RACK_NAME_RE.test(name)) err(`rack '${name}': a rack name is lower case letters, digits and dashes`);
    if (!Number.isInteger(r.units) || r.units < 1 || r.units > 60) err(`rack ${name}: units is 1 to 60`);
    if (!RACK_WIDTHS.includes(r.width)) err(`rack ${name}: width is one of ${RACK_WIDTHS.join(", ")}`);
    if (!NUMBERINGS.includes(r.numbering)) err(`rack ${name}: numbering is one of ${NUMBERINGS.join(", ")}`);
  }

  const placed: { device: string; rack: string; face: Face; lo: number; hi: number; cols: [number, number] }[] = [];
  for (const [device, m] of Object.entries(mounts)) {
    const where = `mount ${device}`;
    const rack = racks[m.rack];
    if (!rack) {
      err(`${where}: rack '${m.rack}' does not exist`);
      continue;
    }
    if (!Number.isInteger(m.u) || m.u < 1) err(`${where}: u is a rack unit from 1`);
    if (!Number.isInteger(m.height) || m.height < 1) err(`${where}: height is a whole number of rack units`);
    if (!MOUNT_WIDTHS.includes(m.width)) err(`${where}: width is one of ${MOUNT_WIDTHS.join(", ")}`);
    if (!FACES.includes(m.face)) err(`${where}: face is front or rear`);
    const n = COLUMNS[m.width] ?? 1;
    if (m.slot !== undefined && (!Number.isInteger(m.slot) || m.slot < 0 || m.slot >= n)) err(`${where}: slot is 0${n > 1 ? `-${n - 1}` : ""} for a ${m.width}-width device`);
    if (Number.isInteger(m.u) && Number.isInteger(m.height) && m.u + m.height - 1 > rack.units) {
      err(`${where}: U${m.u}-U${m.u + m.height - 1} does not fit ${m.rack}'s ${rack.units}U`);
    }
    const fp = byKey(m.faceplate);
    if (m.faceplate && !fp) err(`${where}: faceplate ${m.faceplate} is not in the catalog`);
    if (fp && fp.units !== m.height) warn(`${where}: ${m.height}U high, its faceplate ${fp.key} is ${fp.units}U`);
    if (devices !== null && !devices.some((d) => d.name === device) && !fp?.passive) {
      err(`${where}: the topology has no device '${device}' (a node, switch, access point, machine or device) — a passive device needs a passive faceplate (a patch panel, a PDU)`);
    }
    if (Number.isInteger(m.u) && Number.isInteger(m.height)) placed.push({ device, rack: m.rack, face: m.face, lo: m.u, hi: m.u + m.height - 1, cols: columnSpan(m) });
  }
  for (let i = 0; i < placed.length; i++) {
    for (let j = i + 1; j < placed.length; j++) {
      const a = placed[i];
      const b = placed[j];
      if (a.rack !== b.rack || a.face !== b.face) continue;
      if (a.hi < b.lo || b.hi < a.lo) continue;
      if (a.cols[1] <= b.cols[0] || b.cols[1] <= a.cols[0]) continue;
      err(`mounts ${a.device} and ${b.device} overlap in ${a.rack} (U${Math.max(a.lo, b.lo)}${Math.min(a.hi, b.hi) > Math.max(a.lo, b.lo) ? `-U${Math.min(a.hi, b.hi)}` : ""}, ${a.face})`);
    }
  }

  const plateOf = (device: string): Faceplate | null => {
    const m = mounts[device];
    if (m?.faceplate) return byKey(m.faceplate);
    const d = devices?.find((x) => x.name === device);
    return d ? byKey(suggestFaceplate(catalog, d) ?? undefined) : null;
  };
  const used = new Map<string, number>();
  for (const [i, c] of cablesOf(doc).entries()) {
    const where = `cable ${i + 1}${c.label ? ` (${c.label})` : ""}`;
    if (!CABLE_KINDS.includes(c.kind)) err(`${where}: kind is one of ${CABLE_KINDS.join(", ")}`);
    for (const e of [c.from, c.to]) {
      const p = endProblem(e, devices, plateOf, catalog);
      if (p) err(`${where}: ${p}`);
      const k = `${e?.device}\u0000${e?.port}`;
      if (used.has(k)) err(`${where}: ${e.device} port ${e.port} already carries cable ${used.get(k)}`);
      else used.set(k, i + 1);
    }
    if (c.from?.device === c.to?.device && c.from?.port === c.to?.port) err(`${where}: both ends are the same port`);
  }
  return out;
}

// "USW Pro XG 10 PoE:5" → the device and the port; a device name may hold ":".
export function parseEnd(s: string): CableEnd | null {
  const i = s.lastIndexOf(":");
  if (i <= 0 || i === s.length - 1) return null;
  return { device: s.slice(0, i), port: s.slice(i + 1) };
}
export const endText = (e: CableEnd): string => `${e.device}:${e.port}`;

// ── the view the topology carries ──────────────────────────────────────

export interface RackMountView {
  device: string;
  kind: DeviceKind | "passive";
  rack: string;
  u: number;
  height: number;
  width: MountWidth;
  slot: number;
  face: Face;
  label: string | null;
  description: string | null;
  faceplate: string | null; // the key drawn
  suggested: boolean; // not recorded: the catalog's suggestion
  plate: ResolvedPlate | null;
  up: boolean | null; // any of its ports up; null: nothing known
}
export interface RackView {
  name: string;
  displayName: string | null;
  units: number;
  width: RackWidth;
  numbering: Numbering;
  building: string | null;
  room: string | null;
  description: string | null;
  mounts: RackMountView[];
}
export interface CableView {
  from: { device: string; port: string };
  to: { device: string; port: string };
  kind: string; // a recorded cable's kind; a seen link's role (lan, wan, uplink, ap, peer-link, device)
  source: "topology" | "recorded";
  zones: string[];
  lag: string | null;
  up: boolean | null;
  label: string | null;
}
export interface UnplacedView {
  device: string;
  kind: DeviceKind;
  vendor: string | null;
  model: string | null;
  suggestion: string | null;
}
export interface OutsideView {
  device: string; // placed by a cable record only
  faceplate: string | null;
  plate: ResolvedPlate | null;
}
export interface RacksView {
  racks: RackView[];
  unplaced: UnplacedView[];
  cables: CableView[];
  outside: OutsideView[];
  // device: a mount whose device is gone; unplaced: a device mounted nowhere
  findings: { text: string; device: string; kind: "gone" | "unplaced"; rack: string | null }[];
}

const ROLE_KIND: Record<string, string> = { "node-lan": "lan", "node-wan": "wan", switch: "uplink", uplink: "uplink", ap: "ap", device: "device", "peer-link": "peer-link" };

// The cables the topology sees: every switch port with a known far end, and
// every node leg LLDP places, once each.
export function seenCables(t: TopoLike): CableView[] {
  const out: CableView[] = [];
  const key = (a: string, ap: string, b: string, bp: string) => [`${a}\u0000${ap}`, `${b}\u0000${bp}`].sort().join("\u0001");
  const seen = new Set<string>();
  const add = (c: CableView) => {
    const k = key(c.from.device, c.from.port, c.to.device, c.to.port);
    if (seen.has(k)) return;
    seen.add(k);
    out.push(c);
  };
  for (const s of t.switches ?? []) {
    for (const p of s.ports ?? []) {
      const tg = p.target;
      if (!tg || !tg.name || tg.kind === "isp") continue;
      const farPort = tg.kind === "ap" ? "uplink" : tg.port;
      if (!farPort) continue;
      add({
        from: { device: s.name, port: p.port },
        to: { device: tg.name, port: farPort },
        kind: ROLE_KIND[p.role ?? ""] ?? p.role ?? "patch",
        source: "topology",
        zones: p.zones ?? [],
        lag: p.lag ?? null,
        up: p.link === "up" ? true : p.link === "down" ? false : null,
        label: null,
      });
    }
  }
  for (const n of t.nodes ?? []) {
    for (const u of n.uplinks ?? []) {
      for (const l of u.legs ?? []) {
        if (!l.peer) continue;
        const sp = (t.switches ?? []).find((s) => s.name === l.peer!.switch)?.ports?.find((p) => p.port === l.peer!.port);
        add({
          from: { device: l.peer.switch, port: l.peer.port },
          to: { device: n.name, port: l.nic },
          kind: u.name === "wan" ? "wan" : "lan",
          source: "topology",
          zones: sp?.zones ?? [],
          lag: sp?.lag ?? (u.mode === "lacp" ? u.bond ?? null : null),
          up: typeof l.up === "boolean" ? l.up : null,
          label: null,
        });
      }
    }
  }
  return out;
}

// resolveRacks — racks.json against the site: each mount on its device with
// its plate, the cables the topology sees plus the recorded ones, the devices
// mounted nowhere, and what does not reconcile.
export function resolveRacks(doc: RacksDoc, catalog: Faceplate[], t: TopoLike): RacksView {
  const devices = siteDevices(t);
  const mounts = mountsOf(doc);
  const byKey = (k: string | null | undefined) => (k ? catalog.find((f) => f.key === k) ?? null : null);
  const findings: RacksView["findings"] = [];
  const racks: RackView[] = Object.entries(racksOf(doc))
    .sort(([a], [b]) => portCompare(a, b))
    .map(([name, r]) => ({
      name,
      displayName: r.displayName ?? null,
      units: r.units,
      width: r.width,
      numbering: r.numbering,
      building: r.building ?? null,
      room: r.room ?? null,
      description: r.description ?? null,
      mounts: [],
    }));
  for (const [device, m] of Object.entries(mounts)) {
    const rack = racks.find((r) => r.name === m.rack);
    const dev = devices.find((d) => d.name === device) ?? null;
    const recorded = byKey(m.faceplate);
    const key = recorded ? recorded.key : dev ? suggestFaceplate(catalog, dev) : null;
    const fp = recorded ?? byKey(key);
    if (!dev && !fp?.passive) findings.push({ text: `${device} is mounted in ${m.rack} at U${m.u}, but the topology no longer has it`, device, kind: "gone", rack: m.rack });
    if (!rack) continue;
    const plate = fp ? resolvePlate(fp, dev) : null;
    const states = dev?.ports.map((p) => p.up).filter((x): x is boolean => x !== null) ?? [];
    rack.mounts.push({
      device,
      kind: dev ? dev.kind : "passive",
      rack: m.rack,
      u: m.u,
      height: m.height,
      width: m.width,
      slot: m.width === "full" ? 0 : m.slot ?? 0,
      face: m.face,
      label: m.label ?? null,
      description: m.description ?? null,
      faceplate: fp?.key ?? null,
      suggested: !recorded && !!fp,
      plate,
      up: states.length ? states.some((x) => x) : null,
    });
  }
  for (const r of racks) r.mounts.sort((a, b) => b.u - a.u || a.slot - b.slot);
  const hasRack = racks.length > 0;
  const unplaced: UnplacedView[] = devices
    .filter((d) => !mounts[d.name])
    .map((d) => ({ device: d.name, kind: d.kind, vendor: d.vendor, model: d.model, suggestion: suggestFaceplate(catalog, d) }));
  if (hasRack) for (const u of unplaced) findings.push({ text: `${u.device} is mounted in no rack`, device: u.device, kind: "unplaced", rack: null });

  const cables = seenCables(t);
  const outside: OutsideView[] = [];
  for (const c of cablesOf(doc)) {
    cables.push({ from: { device: c.from.device, port: c.from.port }, to: { device: c.to.device, port: c.to.port }, kind: c.kind, source: "recorded", zones: zonesAt(t, c.from) ?? zonesAt(t, c.to) ?? [], lag: null, up: upAt(t, c.from) ?? upAt(t, c.to), label: c.label ?? null });
    for (const e of [c.from, c.to]) {
      if (mounts[e.device] || devices.some((d) => d.name === e.device) || outside.some((o) => o.device === e.device)) continue;
      const fp = byKey(e.faceplate);
      outside.push({ device: e.device, faceplate: fp?.key ?? null, plate: fp ? resolvePlate(fp, null) : null });
    }
  }
  return { racks, unplaced, cables, outside, findings };
}

function swPort(t: TopoLike, e: CableEnd) {
  return (t.switches ?? []).find((s) => s.name === e.device)?.ports?.find((p) => p.port === e.port);
}
const zonesAt = (t: TopoLike, e: CableEnd): string[] | null => swPort(t, e)?.zones ?? null;
function upAt(t: TopoLike, e: CableEnd): boolean | null {
  const l = swPort(t, e)?.link;
  return l === "up" ? true : l === "down" ? false : null;
}

// The rack unit drawn at a row (0 = the top row): the rack's numbering.
export function unitAtRow(r: Pick<Rack, "units" | "numbering">, row: number): number {
  return r.numbering === "top-down" ? row + 1 : r.units - row;
}
