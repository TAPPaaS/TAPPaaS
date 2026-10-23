// positions.ts — config/positions.json and the faceplate catalog: where the
// site's hardware is inside its locations (schemas/positions-fields.json,
// ADR-036 D3). position-manager writes the document and validates it here;
// network-manager's topology resolves it against the site here (placements to
// devices, links to faceplate ports). Pure: documents and catalogs in,
// findings and views out.
//
// A room is in a location of site.json (absent: the primary one); a rack is in
// a room; a device is placed in a rack or loose in a room, at most once.
// Devices are named as the topology names them; a placement never holds a
// copy of a device's record. A device nothing manages (the ISP's modem, an
// ONT, a UPS, a patch panel) is recorded here, and is then a device like any
// other. A cable the switches or LLDP can see comes from the topology;
// positions.json records only the ones nothing can see.

export const POSITIONS_FILE = "positions.json";
// The file's name before position-manager (migration 0020 renames it): read
// while it is still there, never written.
export const LEGACY_RACKS_FILE = "racks.json";
export const RACK_NAME_RE = /^[a-z][a-z0-9-]{0,62}$/;
export const FACEPLATE_KEY_RE = /^[a-z0-9][a-z0-9-]*\/[a-z0-9][a-z0-9.+-]*$/;

export const RACK_WIDTHS = ["19in", "10in"] as const;
export const NUMBERINGS = ["bottom-up", "top-down"] as const;
export const MOUNT_WIDTHS = ["full", "half", "third"] as const;
export const FACES = ["front", "rear"] as const;
export const CABLE_KINDS = ["patch", "uplink", "power"] as const;
export const PORT_KINDS = ["rj45", "sfp+", "sfp28", "poe", "console", "power"] as const;
export const PLATE_KINDS = ["server", "switch", "ap", "patch-panel", "pdu", "modem", "other"] as const;
export const RECORDED_KINDS = ["modem", "ont", "ups", "patch-panel", "other"] as const;
export const DEVICE_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}$/;

export type RackWidth = (typeof RACK_WIDTHS)[number];
export type Numbering = (typeof NUMBERINGS)[number];
export type MountWidth = (typeof MOUNT_WIDTHS)[number];
export type Face = (typeof FACES)[number];
export type CableKind = (typeof CABLE_KINDS)[number];
export type PortKind = (typeof PORT_KINDS)[number];
export type PlateKind = (typeof PLATE_KINDS)[number];
export type RecordedKind = (typeof RECORDED_KINDS)[number];

export interface Rack {
  displayName?: string;
  units: number;
  width: RackWidth;
  numbering: Numbering;
  room?: string;
  description?: string;
}
// A room: where racks stand and where a device can stand loose, in a location
// of site.json (absent: the primary location).
export interface Room {
  displayName?: string;
  description?: string;
  location?: string;
}
// A placement: in a rack at its units (height, width, slot, face), or loose in
// a room (no rack, no unit: its plate gives its size).
export interface Placement {
  rack?: string;
  u?: number;
  room?: string; // a loose placement's room
  height?: number;
  width?: MountWidth;
  slot?: number;
  face?: Face;
  faceplate?: string;
  label?: string;
  description?: string;
}
export const SIDES = ["front", "rear"] as const;
export type Side = (typeof SIDES)[number];
export interface CableEnd {
  device: string;
  port: string;
  faceplate?: string; // a device only this cable places (the ISP's modem)
  side?: Side; // a patch panel's port: its front (default) or its rear
}
export interface Cable {
  from: CableEnd;
  to: CableEnd;
  kind: CableKind;
  label?: string;
  // A segment of a link split at a patch panel (cable split): what the link
  // was before — one the topology sees, or a recorded cable (cable join
  // records it again).
  origin?: "seen" | "recorded";
}
// A device nothing can see, recorded by its name: its kind, its plate in the
// catalog (model) or its ports, and how it is shown.
export interface RecordedDevice {
  kind: RecordedKind;
  model?: string; // a catalog key, <vendor>/<model>
  ports?: string[]; // its port names, when the model does not give them
  displayName?: string;
  description?: string;
  location?: string; // a location of site.json; absent: the primary one
  mac?: string; // the MAC a switch port saw it by (device record)
}
export interface PositionsDoc {
  version?: 1;
  rooms?: Record<string, Room>;
  racks?: Record<string, Rack>;
  placements?: Record<string, Placement>;
  // racks.json's name for the placements, read until migration 0020 has run
  mounts?: Record<string, Placement>;
  cables?: Cable[];
  devices?: Record<string, RecordedDevice>;
}

// A rack's height, width and face, and what a loose placement draws with.
export const heightOf = (m: Placement): number => m.height ?? 1;
export const widthOf = (m: Placement): MountWidth => m.width ?? "full";
export const faceOf = (m: Placement): Face => m.face ?? "front";

// An unmigrated document's mounts, as placements: a loose one keeps its room,
// plate, label and description, as migration 0020 writes it.
export function legacyPlacements(mounts: Record<string, Placement> | undefined): Record<string, Placement> {
  const out: Record<string, Placement> = {};
  for (const [d, m] of Object.entries(mounts ?? {})) {
    if (m.rack) out[d] = { ...m };
    else {
      const p: Placement = {};
      for (const k of ["room", "faceplate", "label", "description"] as const) if (m[k] !== undefined) p[k] = m[k];
      out[d] = p;
    }
  }
  return out;
}

export const racksOf = (d: PositionsDoc): Record<string, Rack> => d.racks ?? {};
export const placementsOf = (d: PositionsDoc): Record<string, Placement> => d.placements ?? legacyPlacements(d.mounts);
export const cablesOf = (d: PositionsDoc): Cable[] => d.cables ?? [];
export const devicesOf = (d: PositionsDoc): Record<string, RecordedDevice> => d.devices ?? {};
export const roomsOf = (d: PositionsDoc): Record<string, Room> => d.rooms ?? {};
export const ROOM_NAME_RE = /^[a-z][a-z0-9-]{0,62}$/;
// Where a mount is, in words: "rack1 U20" or "room basement (loose)".
export const placeWhere = (m: Placement): string => (m.rack ? `${m.rack} U${m.u ?? "?"}${heightOf(m) > 1 ? `-U${(m.u ?? 0) + heightOf(m) - 1}` : ""}` : `room ${m.room ?? "?"} (loose)`);

// The room a placement is in: its own, or its rack's.
export const roomOf = (doc: PositionsDoc, m: Placement): string | null => (m.rack ? racksOf(doc)[m.rack]?.room ?? null : m.room ?? null);

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
  devices?: { name: string; kind: string; vendor?: string | null; model?: string | null; ports?: string[]; recorded?: boolean; source?: string; location?: string | null; seen?: SeenAt | null }[];
}

// What a switch port reports of a device nobody recorded: the port, and what
// its controller says is behind it — a MAC, LLDP's name and port, a lease.
export interface SeenAt {
  switch: string;
  port: string;
  mac: string | null;
  lldp: { name: string; port: string | null } | null;
  lease: { hostname: string | null; address: string | null } | null;
}
export const MAC_RE = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;

// A device the topology lists as seen at a switch port (source "seen").
export interface SeenDevice extends SeenAt {
  name: string;
  location: string | null;
}
export function seenDevices(t: TopoLike): SeenDevice[] {
  return (t.devices ?? [])
    .filter((d) => d.source === "seen" && d.seen)
    .map((d) => ({ ...d.seen!, name: d.name, location: d.location ?? null }));
}

// The seen device a `device record` names: <switch>:<port>, or its MAC.
export function findSeen(seen: SeenDevice[], target: string): SeenDevice | { refused: string } {
  const mac = target.toLowerCase();
  if (MAC_RE.test(mac)) {
    const hit = seen.filter((x) => x.mac === mac);
    return hit.length === 1 ? hit[0] : { refused: hit.length ? `${mac} is seen on ${hit.length} ports: give <switch>:<port>` : `no switch port sees ${mac}` };
  }
  const end = parseEnd(target);
  if (!end) return { refused: "device record <switch>:<port> or <mac>" };
  const hit = seen.filter((x) => x.switch === end.device && x.port === end.port);
  if (hit.length === 1) return hit[0];
  if (hit.length > 1) return { refused: `${target} sees ${hit.length} devices (${hit.map((x) => x.mac ?? "?").join(", ")}): give the MAC` };
  return { refused: `${target} sees no device nobody recorded (network-manager topology lists what each port sees)` };
}

export type DeviceKind = "node" | "switch" | "ap" | "machine" | "device";
export interface SiteDevice {
  name: string;
  kind: DeviceKind;
  recorded?: RecordedKind; // recorded in positions.json, not managed
  seen?: true; // seen at a switch port, recorded nowhere
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
    out.push({
      name: d.name,
      kind: d.kind === "machine" ? "machine" : "device",
      ...(d.recorded && RECORDED_KINDS.includes(d.kind as RecordedKind) ? { recorded: d.kind as RecordedKind } : {}),
      ...(d.source === "seen" ? { seen: true as const } : {}),
      vendor: d.vendor ?? null,
      model: d.model ?? null,
      ports: (d.ports ?? []).map((id) => ({ id, up: null, lag: null, zones: [], disabled: false })),
    });
  }
  return out;
}

// ── recorded devices ──────────────────────────────────────────────────

// A recorded device's ports: its own list, else its model's plate's.
export function recordedPorts(d: RecordedDevice, catalog: Faceplate[]): string[] {
  if (d.ports?.length) return d.ports;
  const f = d.model ? catalog.find((x) => x.key === d.model) : undefined;
  return f ? f.rows.flat().filter((p): p is CatalogPort => !!p).map(portId) : [];
}

const PLATE_OF_KIND: Record<RecordedKind, PlateKind> = { modem: "modem", ont: "modem", ups: "pdu", "patch-panel": "patch-panel", other: "other" };

// A recorded device's plate: its model's from the catalog, else one made from
// its ports (a patch panel 24 to a row, a modem or an ONT half width).
export function recordedPlate(name: string, d: RecordedDevice, catalog: Faceplate[]): Faceplate {
  const f = d.model ? catalog.find((x) => x.key === d.model) : undefined;
  if (f && !d.ports?.length) return f;
  const ports = recordedPorts(d, catalog).map((n): CatalogPort => ({ name: n, kind: d.kind === "ups" ? "power" : "rj45" }));
  const rows: CatalogPort[][] = [];
  for (let i = 0; i < ports.length; i += 24) rows.push(ports.slice(i, i + 24));
  const small = d.kind === "modem" || d.kind === "ont";
  return {
    key: f?.key ?? `recorded/${d.kind}`,
    vendor: f?.vendor ?? "Generic",
    model: f?.model ?? (d.kind === "patch-panel" ? `${ports.length}-port patch panel` : d.kind === "ups" ? "UPS" : d.kind === "ont" ? "ONT" : d.kind === "modem" ? "modem" : name),
    kind: PLATE_OF_KIND[d.kind] ?? "other",
    units: f?.units ?? (rows.length > 2 ? 2 : 1),
    width: f?.width ?? (small ? "half" : "full"),
    passive: true,
    rows,
  };
}

// The site's devices and the recorded ones, each once (a seen device wins).
export function withRecorded(devices: SiteDevice[], doc: PositionsDoc, catalog: Faceplate[]): SiteDevice[] {
  const out = [...devices];
  for (const [name, d] of Object.entries(devicesOf(doc))) {
    if (out.some((x) => x.name === name)) continue;
    out.push({ name, kind: "device", recorded: d.kind, vendor: null, model: d.model ?? null, ports: recordedPorts(d, catalog).map((id) => ({ id, up: null, lag: null, zones: [], disabled: false })) });
  }
  return out;
}

// The catalog's plate for a device's model, else the generic one for its kind.
export function suggestFaceplate(catalog: Faceplate[], d: { kind: DeviceKind | "passive"; vendor?: string | null; model?: string | null; name?: string }): string | null {
  const names = [d.model, d.name].map(canon).filter((x) => x !== "");
  const hit = catalog.find((f) => !f.generic && [f.model, ...(f.match ?? [])].some((m) => names.includes(canon(m))));
  if (hit) return hit.key;
  const generic: Record<string, string> = { node: "generic/server-2u", switch: "generic/switch-1u", machine: "generic/server-1u", ap: "generic/ap" };
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

export interface PositionFinding {
  severity: "error" | "warn";
  message: string;
}

const COLUMNS: Record<MountWidth, number> = { full: 1, half: 2, third: 3 };

// The share of the rack's width a mount takes, as [from, to) in sixths.
export function columnSpan(m: Pick<Placement, "width" | "slot">): [number, number] {
  const w = m.width ?? "full";
  const n = COLUMNS[w] ?? 1;
  const s = w === "full" ? 0 : m.slot ?? 0;
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

// The site's locations, as the checks need them: their names and the primary.
export interface SiteLocs {
  names: string[];
  primary: string | null;
}

// checkPositions — the whole document: every placement names a device the
// topology knows (or a passive plate's own), no two overlap in a rack, each
// fits its rack, every faceplate key is in the catalog, every cable end names
// a port the topology or the catalog has; every location a room or a device
// names is the site's, a device stands in a room at its own location, and a
// device at a location without a room is pointed out. seen null: the topology
// could not be read, and the device checks are skipped with a warning; sites
// null: site.json could not be read, and the location checks are skipped.
export function checkPositions(doc: PositionsDoc, catalog: Faceplate[], seen: SiteDevice[] | null, sites: SiteLocs | null = null): PositionFinding[] {
  const out: PositionFinding[] = [];
  const err = (message: string) => out.push({ severity: "error", message });
  const warn = (message: string) => out.push({ severity: "warn", message });
  const racks = racksOf(doc);
  const mounts = placementsOf(doc);
  const recorded = devicesOf(doc);
  const byKey = (k: string | undefined) => (k ? catalog.find((f) => f.key === k) ?? null : null);
  if (seen === null) warn("the topology could not be read: the devices and their ports are not checked");

  // The recorded devices: a kind, a model the catalog has, ports named once,
  // and not a device the topology sees (that one is the topology's).
  for (const [name, d] of Object.entries(recorded)) {
    const where = `device ${name}`;
    if (!DEVICE_NAME_RE.test(name)) err(`${where}: a device name is letters, digits, spaces, dots, dashes and underscores`);
    if (!RECORDED_KINDS.includes(d.kind)) err(`${where}: kind is one of ${RECORDED_KINDS.join(", ")}`);
    if (d.model && !byKey(d.model)) err(`${where}: model ${d.model} is not in the catalog (faceplates list)`);
    const ports = d.ports ?? [];
    const dup = ports.find((x, i) => ports.indexOf(x) !== i);
    if (dup) err(`${where}: port ${dup} appears twice`);
    if (ports.some((x) => typeof x !== "string" || x.trim() === "" || x.includes(":"))) err(`${where}: a port name is text without a colon`);
    if (seen?.some((x) => x.name === name && !x.recorded)) err(`${where}: the topology sees a device of that name — record only what it cannot see`);
  }
  const devices = seen === null ? null : withRecorded(seen, doc, catalog);

  const rooms = roomsOf(doc);
  for (const name of Object.keys(rooms)) if (!ROOM_NAME_RE.test(name)) err(`room '${name}': a room name is lower case letters, digits and dashes`);
  for (const [name, r] of Object.entries(racks)) {
    // A rack's room names a room record; free text is accepted until the room is recorded.
    if (r.room && !rooms[r.room]) warn(`rack ${name}: room '${r.room}' is not recorded (position-manager room add ${ROOM_NAME_RE.test(r.room) ? r.room : "<name>"}), its text is kept as it is`);
    if (!RACK_NAME_RE.test(name)) err(`rack '${name}': a rack name is lower case letters, digits and dashes`);
    if (!Number.isInteger(r.units) || r.units < 1 || r.units > 60) err(`rack ${name}: units is 1 to 60`);
    if (!RACK_WIDTHS.includes(r.width)) err(`rack ${name}: width is one of ${RACK_WIDTHS.join(", ")}`);
    if (!NUMBERINGS.includes(r.numbering)) err(`rack ${name}: numbering is one of ${NUMBERINGS.join(", ")}`);
  }

  // Locations: a room's and a recorded device's name one of the site's.
  const locOf = (room: string | null): string | null => (room ? rooms[room]?.location ?? sites?.primary ?? null : null);
  if (sites) {
    const known = (l: string) => sites.names.includes(l);
    for (const [name, r] of Object.entries(rooms)) if (r.location !== undefined && !known(r.location)) err(`room ${name}: location '${r.location}' is not one of the site's (site-manager location list)`);
    for (const [name, d] of Object.entries(recorded)) if (d.location !== undefined && !known(d.location)) err(`device ${name}: location '${d.location}' is not one of the site's (site-manager location list)`);
  }

  const placed: { device: string; rack: string; face: Face; lo: number; hi: number; cols: [number, number] }[] = [];
  for (const [device, m] of Object.entries(mounts)) {
    const where = `placement ${device}`;
    // A device stands at its own location: its room is there.
    const own = recorded[device]?.location;
    const at = locOf(roomOf(doc, m));
    if (sites && own !== undefined && at !== null && at !== own) err(`${where}: room ${roomOf(doc, m)} is at ${at}, the device is at ${own} — place it in a room at ${own}, or change the device's location`);
    if (!m.rack) {
      // Loose in a room: the room exists, and nothing of a rack's position.
      if (!m.room) err(`${where}: neither a rack nor a room`);
      else if (!rooms[m.room]) err(`${where}: room '${m.room}' does not exist (room add ${m.room})`);
      if (m.u !== undefined || m.slot !== undefined) err(`${where}: a loose device has no unit or slot`);
      const fp = byKey(m.faceplate);
      if (m.faceplate && !fp) err(`${where}: faceplate ${m.faceplate} is not in the catalog`);
      if (devices !== null && !devices.some((d) => d.name === device) && !recorded[device] && !fp?.passive) err(`${where}: the topology has no device '${device}' and it is not recorded`);
      continue;
    }
    if (m.room) err(`${where}: a device in a rack is in its rack's room — give a rack or a room, not both`);
    const rack = racks[m.rack];
    if (!rack) {
      err(`${where}: rack '${m.rack}' does not exist`);
      continue;
    }
    const h = m.height ?? 0;
    if (!Number.isInteger(m.u) || (m.u ?? 0) < 1) err(`${where}: u is a rack unit from 1`);
    if (!Number.isInteger(m.height) || h < 1) err(`${where}: height is a whole number of rack units`);
    if (!MOUNT_WIDTHS.includes(m.width as MountWidth)) err(`${where}: width is one of ${MOUNT_WIDTHS.join(", ")}`);
    if (!FACES.includes(m.face as Face)) err(`${where}: face is front or rear`);
    const n = COLUMNS[widthOf(m)] ?? 1;
    if (m.slot !== undefined && (!Number.isInteger(m.slot) || m.slot < 0 || m.slot >= n)) err(`${where}: slot is 0${n > 1 ? `-${n - 1}` : ""} for a ${m.width}-width device`);
    if (Number.isInteger(m.u) && Number.isInteger(m.height) && m.u! + h - 1 > rack.units) {
      err(`${where}: U${m.u}-U${m.u! + h - 1} does not fit ${m.rack}'s ${rack.units}U`);
    }
    const fp = byKey(m.faceplate);
    if (m.faceplate && !fp) err(`${where}: faceplate ${m.faceplate} is not in the catalog`);
    if (fp && fp.units !== h) warn(`${where}: ${h}U high, its faceplate ${fp.key} is ${fp.units}U`);
    if (devices !== null && !devices.some((d) => d.name === device) && !recorded[device] && !fp?.passive) {
      err(`${where}: the topology has no device '${device}' (a node, switch, access point, machine or device) — a passive device needs a passive faceplate (a patch panel, a PDU)`);
    }
    if (Number.isInteger(m.u) && Number.isInteger(m.height)) placed.push({ device, rack: m.rack, face: faceOf(m), lo: m.u!, hi: m.u! + h - 1, cols: columnSpan(m) });
  }

  // A device at a location with no room is somewhere there, unplaced — said
  // once the site records a room at all (before that, nothing is placed).
  if (sites && Object.keys(rooms).length) {
    const roomed = new Set(Object.keys(rooms).map((r) => locOf(r)));
    const names = new Set([...(devices ?? []).map((d) => d.name), ...Object.keys(recorded)]);
    for (const name of names) {
      if (mounts[name]) continue;
      const at = recorded[name]?.location ?? sites.primary;
      if (at && !roomed.has(at)) warn(`${name} is at ${at}, which has no room: it is somewhere there, unplaced (position-manager room add <room> --location ${at})`);
    }
  }
  for (let i = 0; i < placed.length; i++) {
    for (let j = i + 1; j < placed.length; j++) {
      const a = placed[i];
      const b = placed[j];
      if (a.rack !== b.rack || a.face !== b.face) continue;
      if (a.hi < b.lo || b.hi < a.lo) continue;
      if (a.cols[1] <= b.cols[0] || b.cols[1] <= a.cols[0]) continue;
      err(`placements ${a.device} and ${b.device} overlap in ${a.rack} (U${Math.max(a.lo, b.lo)}${Math.min(a.hi, b.hi) > Math.max(a.lo, b.lo) ? `-U${Math.min(a.hi, b.hi)}` : ""}, ${a.face})`);
    }
  }

  const plateOf = (device: string): Faceplate | null => {
    const m = mounts[device];
    if (m?.faceplate) return byKey(m.faceplate);
    if (recorded[device]) return recordedPlate(device, recorded[device], catalog);
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
      // A patch panel's port takes one cable on its front and one on its rear.
      const panel = isPanel(doc, e?.device);
      if (e?.side !== undefined && !SIDES.includes(e.side)) err(`${where}: ${e.device} port ${e.port}: side is front or rear`);
      if (e?.side !== undefined && !panel) err(`${where}: ${e.device} is no patch panel: its ports have no front and rear`);
      const k = `${e?.device}\u0000${e?.port}${panel ? `\u0000${e.side ?? "front"}` : ""}`;
      if (used.has(k)) err(`${where}: ${e.device} port ${e.port}${panel ? ` (${e.side ?? "front"})` : ""} already carries cable ${used.get(k)}`);
      else used.set(k, i + 1);
    }
    if (c.from?.device === c.to?.device && c.from?.port === c.to?.port) err(`${where}: both ends are the same port`);
    // A device only this cable names: it works, but it is no device yet.
    for (const e of [c.from, c.to]) {
      if (!isStr(e?.device) || recorded[e.device] || mounts[e.device] || devices === null || devices.some((d) => d.name === e.device)) continue;
      warn(`${where}: ${e.device} is neither seen by the topology nor recorded — record it: position-manager device add '${e.device}' --kind modem|ont|ups|patch-panel|other${e.faceplate ? ` --model ${e.faceplate}` : ""}`);
    }
  }
  return out;
}

// A recorded patch panel: its ports have a front and a rear.
export const isPanel = (doc: PositionsDoc, device: string | undefined): boolean => !!device && devicesOf(doc)[device]?.kind === "patch-panel";

// "USW Pro XG 10 PoE:5" → the device and the port; a device name may hold ":".
export function parseEnd(s: string): CableEnd | null {
  const i = s.lastIndexOf(":");
  if (i <= 0 || i === s.length - 1) return null;
  return { device: s.slice(0, i), port: s.slice(i + 1) };
}
export const endText = (e: CableEnd): string => `${e.device}:${e.port}${e.side ? ` (${e.side})` : ""}`;

// ── the view the topology carries ──────────────────────────────────────

export interface PlacementView {
  device: string;
  kind: DeviceKind | "passive";
  recorded?: RecordedKind;
  rack: string; // "" for a loose device
  room?: string | null; // a loose device's room
  u: number; // 0 for a loose device
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
  room: string | null;
  description: string | null;
  location: string | null; // its room's
  placements: PlacementView[];
}
export interface CableView {
  from: { device: string; port: string; side?: Side };
  to: { device: string; port: string; side?: Side };
  kind: string; // a recorded cable's kind; a seen link's role (lan, wan, uplink, ap, peer-link, device)
  source: "topology" | "recorded";
  zones: string[];
  lag: string | null;
  up: boolean | null;
  label: string | null;
  // A link split at patch panels (cable split): the wires it is made of, end
  // to end, and the panel ports it runs through.
  segments?: { from: { device: string; port: string; side?: Side }; to: { device: string; port: string; side?: Side } }[];
  via?: { device: string; port: string }[];
}
export interface UnplacedView {
  device: string;
  kind: DeviceKind;
  recorded?: RecordedKind;
  seen?: true;
  vendor: string | null;
  model: string | null;
  suggestion: string | null;
  location: string | null;
}
export interface OutsideView {
  device: string; // placed by a cable record only
  faceplate: string | null;
  plate: ResolvedPlate | null;
}
// A room: its record, its racks (by name), and the devices loose in it. A
// room only a rack's free text names is drawn too, not recorded.
export interface RoomView {
  name: string;
  displayName: string | null;
  description: string | null;
  location: string | null; // its own, else the primary
  recorded: boolean;
  racks: string[];
  loose: PlacementView[];
}
// A location of the site, as far as positions go: its place, its rooms, and
// the devices there that stand in no room (somewhere at it, unplaced).
export interface LocationView {
  name: string;
  displayName: string | null;
  kind: "site" | "remote";
  primary: boolean;
  place: { country: string | null; city: string | null; address: string | null } | null;
  rooms: string[];
  unplaced: string[];
}
export interface PositionsView {
  locations: LocationView[];
  racks: RackView[];
  rooms: RoomView[];
  unplaced: UnplacedView[];
  cables: CableView[];
  outside: OutsideView[];
  // gone: a placement whose device is gone; unplaced: a device placed nowhere
  // at a location that has a room
  findings: { text: string; device: string; kind: "gone" | "unplaced"; rack: string | null }[];
}

// The site's locations as the view needs them (site.json, through
// lib/ts locations.ts readLocations): by name, and the primary.
export interface SitePlaces {
  locations: Record<string, { displayName?: string; kind?: "site" | "remote"; country?: string; city?: string; address?: string }>;
  primary: string | null;
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
  // A device a switch port sees: the port to it.
  for (const d of t.devices ?? []) {
    if (d.source !== "seen" || !d.seen) continue;
    const sp = (t.switches ?? []).find((s) => s.name === d.seen!.switch)?.ports?.find((p) => p.port === d.seen!.port);
    add({
      from: { device: d.seen.switch, port: d.seen.port },
      to: { device: d.name, port: d.ports?.[0] ?? "1" },
      kind: "device",
      source: "topology",
      zones: sp?.zones ?? [],
      lag: null,
      up: sp?.link === "up" ? true : sp?.link === "down" ? false : null,
      label: null,
    });
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

// resolvePositions — racks.json against the site: each mount on its device with
// its plate, the cables the topology sees plus the recorded ones, the devices
// mounted nowhere, and what does not reconcile.
// The location a device is at: the one the topology gives it, else a recorded
// device's own, else the primary.
export function deviceLocation(t: TopoLike, doc: PositionsDoc, name: string, primary: string | null): string | null {
  return t.devices?.find((d) => d.name === name)?.location ?? devicesOf(doc)[name]?.location ?? primary;
}

// resolvePositions — positions.json against the site: the locations with
// their rooms, each placement on its device with its plate, the cables the
// topology sees plus the recorded ones, the devices placed nowhere (by
// location), and what does not reconcile. locationOf: each device's location
// (the topology's, which knows every record); unset, deviceLocation.
export function resolvePositions(doc: PositionsDoc, catalog: Faceplate[], t: TopoLike, sites: SitePlaces = { locations: {}, primary: null }, locationOf?: (device: string) => string | null): PositionsView {
  const devices = withRecorded(siteDevices(t), doc, catalog);
  const recorded = devicesOf(doc);
  const mounts = placementsOf(doc);
  const byKey = (k: string | null | undefined) => (k ? catalog.find((f) => f.key === k) ?? null : null);
  const findings: PositionsView["findings"] = [];
  const where = locationOf ?? ((d: string) => deviceLocation(t, doc, d, sites.primary));
  const racks: RackView[] = Object.entries(racksOf(doc))
    .sort(([a], [b]) => portCompare(a, b))
    .map(([name, r]) => ({
      name,
      displayName: r.displayName ?? null,
      units: r.units,
      width: r.width,
      numbering: r.numbering,
      room: r.room ?? null,
      description: r.description ?? null,
      location: null as string | null,
      placements: [] as PlacementView[],
    }));
  const roomDocs = roomsOf(doc);
  const rooms: RoomView[] = Object.entries(roomDocs)
    .sort(([a], [b]) => portCompare(a, b))
    .map(([name, r]): RoomView => ({ name, displayName: r.displayName ?? null, description: r.description ?? null, location: r.location ?? sites.primary, recorded: true, racks: [], loose: [] }));
  for (const r of racks) {
    if (!r.room) continue;
    let room = rooms.find((x) => x.name === r.room);
    if (!room) {
      room = { name: r.room, displayName: null, description: null, location: sites.primary, recorded: false, racks: [], loose: [] };
      rooms.push(room);
    }
    room.racks.push(r.name);
    r.location = room.location;
  }
  for (const [device, m] of Object.entries(mounts)) {
    const rack = m.rack ? racks.find((r) => r.name === m.rack) : undefined;
    const dev = devices.find((d) => d.name === device) ?? null;
    const own = byKey(m.faceplate);
    const rec = recorded[device] ? recordedPlate(device, recorded[device], catalog) : null;
    const key = own ? own.key : rec ? rec.key : dev ? suggestFaceplate(catalog, dev) : null;
    const fp = own ?? rec ?? byKey(key);
    if (!dev && !fp?.passive) findings.push({ text: `${device} is placed in ${placeWhere(m)}, but the topology no longer has it`, device, kind: "gone", rack: m.rack ?? null });
    const room = !m.rack && m.room ? rooms.find((x) => x.name === m.room) : undefined;
    if (!rack && !room) continue;
    const plate = fp ? resolvePlate(fp, dev) : null;
    const states = dev?.ports.map((p) => p.up).filter((x): x is boolean => x !== null) ?? [];
    (rack ? rack.placements : room!.loose).push({
      device,
      kind: dev ? dev.kind : "passive",
      ...(dev?.recorded ? { recorded: dev.recorded } : {}),
      rack: m.rack ?? "",
      ...(room ? { room: room.name } : {}),
      u: m.u ?? 0,
      // A loose device is drawn at its plate's size.
      height: rack ? heightOf(m) : fp?.units ?? 1,
      width: rack ? widthOf(m) : fp?.width ?? "full",
      slot: rack && widthOf(m) !== "full" ? m.slot ?? 0 : 0,
      face: faceOf(m),
      label: m.label ?? null,
      description: m.description ?? null,
      faceplate: fp?.key ?? null,
      suggested: !own && !rec && !!fp,
      plate,
      up: states.length ? states.some((x) => x) : null,
    });
  }
  for (const r of racks) r.placements.sort((a, b) => b.u - a.u || a.slot - b.slot);
  const hasRack = racks.length > 0;
  const unplaced: UnplacedView[] = devices
    .filter((d) => !mounts[d.name])
    .map((d) => ({
      device: d.name,
      kind: d.kind,
      vendor: d.vendor,
      model: d.model,
      suggestion: d.recorded ? recorded[d.name]?.model ?? null : suggestFaceplate(catalog, d),
      location: where(d.name),
      ...(d.recorded ? { recorded: d.recorded } : {}),
      ...(d.seen ? { seen: true as const } : {}),
    }));
  // The locations: the site's, the primary first, and any a room or device
  // names that the site lacks (validate reports it).
  const roomed = new Set(rooms.map((r) => r.location));
  const names = [...new Set([sites.primary, ...Object.keys(sites.locations), ...rooms.map((r) => r.location), ...unplaced.map((u) => u.location)].filter((x): x is string => !!x))];
  const locations: LocationView[] = names
    .sort((a, b) => Number(b === sites.primary) - Number(a === sites.primary) || a.localeCompare(b))
    .map((name) => {
      const l = sites.locations[name];
      return {
        name,
        displayName: l?.displayName ?? null,
        kind: l?.kind ?? "site",
        primary: name === sites.primary,
        place: l ? { country: l.country ?? null, city: l.city ?? null, address: l.address ?? null } : null,
        rooms: rooms.filter((r) => r.location === name).map((r) => r.name),
        unplaced: unplaced.filter((u) => u.location === name).map((u) => u.device),
      };
    });
  // A device placed nowhere is a finding where it could stand in a room; at a
  // location with none it is somewhere there. A device a port only sees is
  // not one until it is recorded.
  if (hasRack) {
    for (const u of unplaced) {
      if (u.seen || (u.location !== null && !roomed.has(u.location) && sites.primary !== null)) continue;
      findings.push({ text: `${u.device} is placed nowhere: in no rack and in no room`, device: u.device, kind: "unplaced", rack: null });
    }
  }

  const cables = seenCables(t);
  const outside: OutsideView[] = [];
  for (const c of cablesOf(doc)) {
    const end = (e: CableEnd) => ({ device: e.device, port: e.port, ...(isPanel(doc, e.device) ? { side: e.side ?? "front" } : {}) });
    cables.push({ from: end(c.from), to: end(c.to), kind: c.kind, source: "recorded", zones: zonesAt(t, c.from) ?? zonesAt(t, c.to) ?? [], lag: null, up: upAt(t, c.from) ?? upAt(t, c.to), label: c.label ?? null });
    for (const e of [c.from, c.to]) {
      if (mounts[e.device] || devices.some((d) => d.name === e.device) || outside.some((o) => o.device === e.device)) continue;
      const fp = byKey(e.faceplate);
      outside.push({ device: e.device, faceplate: fp?.key ?? null, plate: fp ? resolvePlate(fp, null) : null });
    }
  }
  for (const r of rooms) r.loose.sort((a, b) => a.device.localeCompare(b.device));
  return { locations, racks, rooms, unplaced, cables: chainSegments(doc, cables), outside, findings };
}

// The segments of links split at patch panels, each chain from a device port
// through the panels' front and rear to the far device port, become one cable
// with its segments: a link the topology sees keeps its role and live state,
// the segments only say which wires it is. A chain that stops at a panel port
// (one side cabled) stays as its segments.
export function chainSegments(doc: PositionsDoc, cables: CableView[]): CableView[] {
  const panel = (d: string) => isPanel(doc, d);
  const same = (a: { device: string; port: string }, b: { device: string; port: string }) => a.device === b.device && a.port === b.port;
  const segs = cables.filter((c) => c.source === "recorded" && (panel(c.from.device) || panel(c.to.device)));
  const drop = new Set<CableView>();
  const merged: CableView[] = [];
  for (const s0 of segs) {
    if (drop.has(s0)) continue;
    const start = !panel(s0.from.device) ? s0.from : !panel(s0.to.device) ? s0.to : null;
    if (!start) continue; // a middle segment: reached from an end
    const chain: CableView[] = [];
    const via: { device: string; port: string }[] = [];
    let cur = s0;
    let from = start;
    let end: CableView["to"];
    for (;;) {
      chain.push(cur);
      const next = same(cur.from, from) && (cur.from.side ?? "") === (from.side ?? "") ? cur.to : cur.from;
      if (!panel(next.device)) {
        end = next;
        break;
      }
      via.push({ device: next.device, port: next.port });
      const other = (next.side ?? "front") === "front" ? "rear" : "front";
      const nx = segs.find((c) => !chain.includes(c) && [c.from, c.to].some((e) => same(e, next) && (e.side ?? "front") === other));
      if (!nx) {
        end = next;
        break;
      }
      from = [nx.from, nx.to].find((e) => same(e, next) && (e.side ?? "front") === other)!;
      cur = nx;
    }
    if (chain.length < 2 || panel(end.device)) continue;
    const base = cables.find((c) => c.source === "topology" && ((same(c.from, start) && same(c.to, end)) || (same(c.to, start) && same(c.from, end))));
    for (const c of chain) drop.add(c);
    if (base) drop.add(base);
    merged.push({
      from: base ? base.from : { device: start.device, port: start.port },
      to: base ? base.to : { device: end.device, port: end.port },
      kind: base?.kind ?? chain[0].kind,
      source: base ? "topology" : "recorded",
      zones: base?.zones ?? chain.find((c) => c.zones.length)?.zones ?? [],
      lag: base?.lag ?? null,
      up: base?.up ?? chain.map((c) => c.up).find((u) => u !== null) ?? null,
      label: chain[0].label,
      segments: chain.map((c) => ({ from: c.from, to: c.to })),
      via,
    });
  }
  return [...cables.filter((c) => !drop.has(c)), ...merged];
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
