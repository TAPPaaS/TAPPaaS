// verbs.ts — what each position-manager verb does to config/positions.json, as pure
// functions over the document: a verb returns the new document or a refusal.
// Validating the whole result and writing it are main.ts's; this is what the
// unit tests pin.

import {
  CABLE_KINDS,
  Cable,
  CableEnd,
  CableKind,
  FACES,
  Face,
  Faceplate,
  MOUNT_WIDTHS,
  Placement,
  MountWidth,
  NUMBERINGS,
  Numbering,
  RACK_NAME_RE,
  RACK_WIDTHS,
  DEVICE_NAME_RE,
  RECORDED_KINDS,
  Rack,
  RecordedDevice,
  RecordedKind,
  devicesOf,
  isPanel,
  ROOM_NAME_RE,
  Room,
  roomsOf,
  placeWhere,
  RackWidth,
  PositionsDoc,
  cablesOf,
  endText,
  placementsOf,
  heightOf,
  racksOf,
} from "../../../lib/ts/src/positions";

export type Result = { doc: PositionsDoc; summary: string } | { refused: string };

const clone = (d: PositionsDoc): PositionsDoc => JSON.parse(JSON.stringify(d ?? {}));
type Doc = Required<Pick<PositionsDoc, "racks" | "placements" | "cables" | "devices" | "rooms">>;
function withDoc(doc: PositionsDoc, fn: (d: Doc) => void): PositionsDoc {
  const d = clone(doc);
  d.version = 1;
  d.racks = d.racks ?? {};
  // A document from before positions.json: its mounts are the placements.
  d.placements = placementsOf(d);
  delete d.mounts;
  d.cables = d.cables ?? [];
  d.devices = d.devices ?? {};
  d.rooms = d.rooms ?? {};
  // A building is the site's now (its primary location): one recorded on a rack
  // or a room before goes, silently, at the next write.
  for (const x of [...Object.values(d.racks), ...Object.values(d.rooms)] as Record<string, unknown>[]) delete x.building;
  fn(d as Doc);
  // The keys in the order the schema lists them.
  const order = ["version", "rooms", "racks", "placements", "devices", "cables"] as const;
  const out: PositionsDoc = {};
  for (const k of order) if (d[k] !== undefined) (out as Record<string, unknown>)[k] = d[k];
  for (const [k, v] of Object.entries(d)) if (!(k in out)) (out as Record<string, unknown>)[k] = v;
  if (Object.keys(out.rooms ?? {}).length === 0) delete out.rooms;
  if ((out.cables ?? []).length === 0) delete out.cables;
  if (Object.keys(out.devices ?? {}).length === 0) delete out.devices;
  return out;
}

const int = (v: string): number | null => (/^\d+$/.test(v.trim()) ? Number(v.trim()) : null);
const text = (v: string): string | undefined => (v.trim() === "" ? undefined : v);

// ── racks ─────────────────────────────────────────────────────────────

export interface RackSpec {
  units?: number;
  width?: string;
  numbering?: string;
  displayName?: string;
  room?: string;
  description?: string;
}

// rack add — a new rack, 42U 19in numbered from the bottom unless told.
export function addRack(doc: PositionsDoc, name: string, spec: RackSpec): Result {
  if (!RACK_NAME_RE.test(name)) return { refused: `rack name '${name}' must match ${RACK_NAME_RE.source}` };
  if (racksOf(doc)[name]) return { refused: `rack ${name} already exists` };
  const width = (spec.width ?? "19in") as RackWidth;
  if (!RACK_WIDTHS.includes(width)) return { refused: `--width is one of ${RACK_WIDTHS.join(", ")}` };
  const numbering = (spec.numbering ?? "bottom-up") as Numbering;
  if (!NUMBERINGS.includes(numbering)) return { refused: `--numbering is one of ${NUMBERINGS.join(", ")}` };
  const rack: Rack = { units: spec.units ?? 42, width, numbering };
  for (const k of ["displayName", "room", "description"] as const) if (spec[k]) rack[k] = spec[k];
  return { doc: withDoc(doc, (d) => void (d.racks[name] = rack)), summary: `rack ${name} added (${rack.units}U, ${width}, numbered ${numbering})` };
}

const RACK_FIELDS = ["displayName", "units", "width", "numbering", "room", "description"];

// rack modify — any field but the name; units may not shrink below a mount.
export function modifyRack(doc: PositionsDoc, name: string, sets: Array<[string, string]>): Result {
  if (!racksOf(doc)[name]) return { refused: `rack ${name} does not exist` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const r = d.racks[name];
    for (const [k, v] of sets) {
      if (k === "name") refused = "a rack's name is its key: add a rack under the new name, move its devices, delete this one";
      else if (!RACK_FIELDS.includes(k)) refused = `rack field '${k}' is not one of ${RACK_FIELDS.join(", ")}`;
      else if (k === "units") {
        const n = int(v);
        if (n === null) refused = "units is a whole number";
        else r.units = n;
      } else if (k === "width") {
        if (!RACK_WIDTHS.includes(v as RackWidth)) refused = `width is one of ${RACK_WIDTHS.join(", ")}`;
        else r.width = v as RackWidth;
      } else if (k === "numbering") {
        if (!NUMBERINGS.includes(v as Numbering)) refused = `numbering is one of ${NUMBERINGS.join(", ")}`;
        else r.numbering = v as Numbering;
      } else {
        const key = k as "displayName" | "room" | "description";
        if (text(v) === undefined) delete r[key];
        else r[key] = v;
      }
      if (refused) return;
    }
  });
  if (refused) return { refused };
  return { doc: next, summary: `rack ${name}: ${sets.map(([k, v]) => `${k}=${v}`).join(", ")}` };
}

// rack delete — only an empty rack: its devices are moved or unplaced first.
export function deleteRack(doc: PositionsDoc, name: string): Result {
  if (!racksOf(doc)[name]) return { refused: `rack ${name} does not exist` };
  const held = Object.entries(placementsOf(doc)).filter(([, m]) => m.rack === name).map(([d]) => d);
  if (held.length) return { refused: `rack ${name} still holds ${held.join(", ")} — move them (mount modify <device> --set rack=…) or remove them first` };
  return { doc: withDoc(doc, (d) => void delete d.racks[name]), summary: `rack ${name} deleted` };
}

// ── mounts ────────────────────────────────────────────────────────────

export interface MountSpec {
  rack?: string;
  u?: number;
  room?: string; // loose in this room: no rack, no unit
  height?: number;
  width?: string;
  slot?: number;
  face?: string;
  faceplate?: string;
  label?: string;
  description?: string;
}

// mount add — a device into a rack at its units, or loose into a room. The
// height defaults to its faceplate's.
export function addMount(doc: PositionsDoc, device: string, spec: MountSpec, catalog: Faceplate[]): Result {
  if (!device.trim()) return { refused: "mount add <device>: the device's topology name" };
  if (placementsOf(doc)[device]) return { refused: `${device} is already mounted in ${placeWhere(placementsOf(doc)[device])} — mount modify ${device} to move it` };
  if (spec.room !== undefined) {
    if (spec.rack !== undefined || spec.u !== undefined) return { refused: "--room places a device loose in a room: no --rack, no --u (a rack names its own room)" };
    if (!roomsOf(doc)[spec.room]) return { refused: `room ${spec.room} does not exist (room add ${spec.room})` };
    if (spec.height !== undefined || spec.width !== undefined || spec.slot !== undefined || spec.face !== undefined) return { refused: "a device loose in a room has no height, width, slot or face: its plate gives its size" };
    const fp = spec.faceplate ? catalog.find((f) => f.key === spec.faceplate) : undefined;
    if (spec.faceplate && !fp) return { refused: `faceplate ${spec.faceplate} is not in the catalog (faceplates list)` };
    const m: Placement = { room: spec.room };
    for (const k of ["faceplate", "label", "description"] as const) if (spec[k]) m[k] = spec[k];
    return { doc: withDoc(doc, (d) => void (d.placements[device] = m)), summary: `${device} stands loose in room ${spec.room}` };
  }
  if (spec.rack === undefined || spec.u === undefined) return { refused: "mount add <device> --rack <rack> --u <n>, or --room <room> for a device loose in a room" };
  if (!racksOf(doc)[spec.rack]) return { refused: `rack ${spec.rack} does not exist (rack add ${spec.rack})` };
  const width = (spec.width ?? "full") as MountWidth;
  if (!MOUNT_WIDTHS.includes(width)) return { refused: `--width is one of ${MOUNT_WIDTHS.join(", ")}` };
  const face = (spec.face ?? "front") as Face;
  if (!FACES.includes(face)) return { refused: `--face is front or rear` };
  const fp = spec.faceplate ? catalog.find((f) => f.key === spec.faceplate) : undefined;
  if (spec.faceplate && !fp) return { refused: `faceplate ${spec.faceplate} is not in the catalog (faceplates list)` };
  const m: Placement = { rack: spec.rack, u: spec.u, height: spec.height ?? fp?.units ?? 1, width, face };
  if (width !== "full") m.slot = spec.slot ?? 0;
  for (const k of ["faceplate", "label", "description"] as const) if (spec[k]) m[k] = spec[k];
  return {
    doc: withDoc(doc, (d) => void (d.placements[device] = m)),
    summary: `${device} mounted in ${m.rack} at U${m.u}${heightOf(m) > 1 ? `-U${(m.u ?? 0) + heightOf(m) - 1}` : ""}, ${m.face}${width === "full" ? "" : `, ${width} width slot ${m.slot}`}`,
  };
}

const MOUNT_FIELDS = ["rack", "u", "room", "height", "width", "slot", "face", "faceplate", "label", "description"];

// mount modify — a move (rack, u, slot, face) or its plate and label. The
// device is the key: another device is another mount.
export function modifyMount(doc: PositionsDoc, device: string, sets: Array<[string, string]>, catalog: Faceplate[]): Result {
  if (!placementsOf(doc)[device]) return { refused: `${device} is not mounted` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const m = d.placements[device];
    for (const [k, v] of sets) {
      if (k === "device") refused = "the device is the mount's key: remove this mount and mount the other device";
      else if (!MOUNT_FIELDS.includes(k)) refused = `mount field '${k}' is not one of ${MOUNT_FIELDS.join(", ")}`;
      else if (k === "rack") {
        if (!d.racks[v]) refused = `rack ${v} does not exist`;
        else {
          // Out of a room into a rack: its plate's height, full width, the front.
          if (!m.rack) {
            const fp = m.faceplate ? catalog.find((f) => f.key === m.faceplate) : undefined;
            m.height = m.height ?? fp?.units ?? 1;
            m.width = m.width ?? fp?.width ?? "full";
            m.face = m.face ?? "front";
          }
          m.rack = v;
          delete m.room;
        }
      } else if (k === "room") {
        // Loose in a room: out of its rack.
        if (!d.rooms[v]) refused = `room ${v} does not exist (room add ${v})`;
        else {
          m.room = v;
          for (const x of ["rack", "u", "slot", "height", "width", "face"] as const) delete m[x];
        }
      } else if (k === "u" || k === "height" || k === "slot") {
        const n = int(v);
        if (n === null) refused = `${k} is a whole number`;
        else m[k] = n;
      } else if (k === "width") {
        if (!MOUNT_WIDTHS.includes(v as MountWidth)) refused = `width is one of ${MOUNT_WIDTHS.join(", ")}`;
        else {
          m.width = v as MountWidth;
          if (v === "full") delete m.slot;
          else m.slot = m.slot ?? 0;
        }
      } else if (k === "face") {
        if (!FACES.includes(v as Face)) refused = "face is front or rear";
        else m.face = v as Face;
      } else if (k === "faceplate") {
        if (text(v) === undefined) delete m.faceplate;
        else if (!catalog.some((f) => f.key === v)) refused = `faceplate ${v} is not in the catalog (faceplates list)`;
        else m.faceplate = v;
      } else {
        const key = k as "label" | "description";
        if (text(v) === undefined) delete m[key];
        else m[key] = v;
      }
      if (refused) return;
    }
  });
  if (refused) return { refused };
  const nm = next.placements![device];
  if (nm.rack && nm.u === undefined) return { refused: `into rack ${nm.rack}: give its unit too (--set u=<n>)` };
  if (!nm.rack && (["u", "height", "width", "slot", "face"] as const).some((x) => nm[x] !== undefined)) return { refused: "a device loose in a room has no unit, height, width, slot or face: move it into a rack first (--set rack=<rack> --set u=<n>)" };
  return { doc: next, summary: `mount ${device}: ${sets.map(([k, v]) => `${k}=${v}`).join(", ")}` };
}

// mount remove — the device leaves the rack (the device itself is untouched).
// The recorded cables that name it go with it only when it is passive
// (nothing else knows it); a topology device keeps its recorded cables.
export function removeMount(doc: PositionsDoc, device: string, passive: boolean): Result {
  if (!placementsOf(doc)[device]) return { refused: `${device} is not mounted` };
  const dropped = passive ? cablesOf(doc).filter((c) => c.from.device === device || c.to.device === device).length : 0;
  return {
    doc: withDoc(doc, (d) => {
      delete d.placements[device];
      if (passive) d.cables = d.cables.filter((c) => c.from.device !== device && c.to.device !== device);
    }),
    summary: `${device} unmounted${dropped ? ` (and its ${dropped} recorded cable(s))` : ""}`,
  };
}

// ── cables ────────────────────────────────────────────────────────────

export function addCable(doc: PositionsDoc, from: CableEnd, to: CableEnd, kind: string, label?: string): Result {
  if (!CABLE_KINDS.includes(kind as CableKind)) return { refused: `--kind is one of ${CABLE_KINDS.join(", ")}` };
  // The same port (and, on a patch panel, the same side).
  const same = (e: CableEnd, x: CableEnd) => e.device === x.device && e.port === x.port && (!isPanel(doc, e.device) || (e.side ?? "front") === (x.side ?? "front"));
  const taken = cablesOf(doc).find((c) => [c.from, c.to].some((e) => [from, to].some((x) => same(e, x))));
  if (taken) return { refused: `${endText(taken.from)} — ${endText(taken.to)} already uses one of these ports: remove it first` };
  const c: Cable = { from, to, kind: kind as CableKind, ...(label ? { label } : {}) };
  return { doc: withDoc(doc, (d) => void d.cables.push(c)), summary: `cable ${endText(from)} — ${endText(to)} (${kind}) recorded` };
}

// cable remove <device:port> — the recorded cable on that port (a patch
// panel's: on the side given, front unless told).
export function removeCable(doc: PositionsDoc, end: CableEnd): Result {
  const on = (e: CableEnd) => e.device === end.device && e.port === end.port && (!isPanel(doc, e.device) || (e.side ?? "front") === (end.side ?? "front"));
  const c = cablesOf(doc).find((x) => on(x.from) || on(x.to));
  if (!c) return { refused: `no recorded cable on ${endText(end)} (a cable the topology sees is not recorded here)` };
  return { doc: withDoc(doc, (d) => void (d.cables = d.cables.filter((x) => x !== d.cables.find((y) => on(y.from) || on(y.to))))), summary: `cable ${endText(c.from)} — ${endText(c.to)} removed` };
}

// ── recorded devices ──────────────────────────────────────────────────

export interface DeviceSpec {
  kind?: string;
  model?: string;
  ports?: number;
  port?: string[];
  displayName?: string;
  description?: string;
  location?: string;
  mac?: string;
}

// The ports a spec names: --port names, else 1..--ports.
function portsOf(spec: DeviceSpec): string[] | undefined | { refused: string } {
  if (spec.port?.length && spec.ports !== undefined) return { refused: "give --ports <n> or --port <name>..., not both" };
  if (spec.port?.length) return spec.port;
  if (spec.ports !== undefined) {
    if (spec.ports < 1 || spec.ports > 96) return { refused: "--ports is 1 to 96" };
    return Array.from({ length: spec.ports }, (_, i) => String(i + 1));
  }
  return undefined;
}

// device add — a device the topology cannot see. Its name is how cables and
// placements name it; seen is the topology's device names (null: not read).
export function addDevice(doc: PositionsDoc, name: string, spec: DeviceSpec, catalog: Faceplate[], seen: string[] | null): Result {
  if (!DEVICE_NAME_RE.test(name)) return { refused: `device name '${name}': letters, digits, spaces, dots, dashes and underscores, up to 63` };
  if (devicesOf(doc)[name]) return { refused: `device ${name} is already recorded (device modify ${name})` };
  if (seen?.includes(name)) return { refused: `the topology sees a device named ${name}: record only what it cannot see` };
  if (!RECORDED_KINDS.includes(spec.kind as RecordedKind)) return { refused: `--kind is one of ${RECORDED_KINDS.join(", ")}` };
  if (spec.model && !catalog.some((f) => f.key === spec.model)) return { refused: `model ${spec.model} is not in the catalog (faceplates list)` };
  const ports = portsOf(spec);
  if (ports && !Array.isArray(ports)) return ports;
  if (!spec.model && !ports) return { refused: "give its ports (--ports <n> or --port <name>...) or a --model from the catalog" };
  const d: RecordedDevice = { kind: spec.kind as RecordedKind };
  if (spec.model) d.model = spec.model;
  if (ports) d.ports = ports;
  if (spec.displayName) d.displayName = spec.displayName;
  if (spec.description) d.description = spec.description;
  if (spec.location) d.location = spec.location;
  if (spec.mac) d.mac = spec.mac;
  const n = recordedPortsCount(d, catalog);
  return { doc: withDoc(doc, (x) => void (x.devices[name] = d)), summary: `device ${name} recorded (${d.kind}${d.model ? `, ${d.model}` : ""}, ${n} port(s))` };
}

function recordedPortsCount(d: RecordedDevice, catalog: Faceplate[]): number {
  if (d.ports?.length) return d.ports.length;
  const f = d.model ? catalog.find((x) => x.key === d.model) : undefined;
  return f ? f.rows.flat().filter(Boolean).length : 0;
}

const DEVICE_FIELDS = ["kind", "model", "ports", "displayName", "description", "location", "mac"];
export const MAC_RE = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;

// device modify — its kind, model, ports (a list, comma separated, or a
// count), display name or description. A port a cable uses stays.
export function modifyDevice(doc: PositionsDoc, name: string, sets: Array<[string, string]>, catalog: Faceplate[]): Result {
  if (!devicesOf(doc)[name]) return { refused: `device ${name} is not recorded` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const r = d.devices[name];
    for (const [k, v] of sets) {
      if (k === "name") refused = "a device's name is how cables and its placement name it: record the new one, move them, remove this one";
      else if (!DEVICE_FIELDS.includes(k)) refused = `device field '${k}' is not one of ${DEVICE_FIELDS.join(", ")}`;
      else if (k === "kind") {
        if (!RECORDED_KINDS.includes(v as RecordedKind)) refused = `kind is one of ${RECORDED_KINDS.join(", ")}`;
        else r.kind = v as RecordedKind;
      } else if (k === "model") {
        if (text(v) === undefined) delete r.model;
        else if (!catalog.some((f) => f.key === v)) refused = `model ${v} is not in the catalog (faceplates list)`;
        else r.model = v;
      } else if (k === "ports") {
        const n = int(v);
        const list = n !== null ? Array.from({ length: n }, (_, i) => String(i + 1)) : v.split(",").map((x) => x.trim()).filter(Boolean);
        if (text(v) === undefined) delete r.ports;
        else r.ports = list;
      } else if (k === "mac" && text(v) !== undefined && !MAC_RE.test(v.toLowerCase())) {
        refused = "mac is six hex pairs, aa:bb:cc:dd:ee:ff";
      } else {
        const key = k as "displayName" | "description" | "location" | "mac";
        if (text(v) === undefined) delete r[key];
        else r[key] = key === "mac" ? v.toLowerCase() : v;
      }
      if (refused) return;
    }
  });
  if (refused) return { refused };
  return { doc: next, summary: `device ${name}: ${sets.map(([k, v]) => `${k}=${v}`).join(", ")}` };
}

// device remove — only a device nothing names: unmount it and remove its
// cables first.
export function removeDevice(doc: PositionsDoc, name: string): Result {
  if (!devicesOf(doc)[name]) return { refused: `device ${name} is not recorded` };
  if (placementsOf(doc)[name]) return { refused: `${name} is mounted — mount remove ${name} first` };
  const cables = cablesOf(doc).filter((c) => c.from.device === name || c.to.device === name);
  const e = cables[0]?.from.device === name ? cables[0].from : cables[0]?.to;
  if (cables.length) return { refused: `${name} is an end of ${cables.length} recorded cable(s) — cable remove '${e.device}:${e.port}' first` };
  return { doc: withDoc(doc, (d) => void delete d.devices[name]), summary: `device ${name} removed` };
}

// ── rooms ─────────────────────────────────────────────────────────────

const ROOM_FIELDS = ["displayName", "description", "location"];

export function addRoom(doc: PositionsDoc, name: string, spec: Room): Result {
  if (!ROOM_NAME_RE.test(name)) return { refused: `room name '${name}' must match ${ROOM_NAME_RE.source}` };
  if (roomsOf(doc)[name]) return { refused: `room ${name} already exists` };
  const r: Room = {};
  for (const k of ROOM_FIELDS as (keyof Room)[]) if (spec[k]) r[k] = spec[k];
  const named = Object.entries(racksOf(doc)).filter(([, x]) => x.room === name).map(([n]) => n);
  return { doc: withDoc(doc, (d) => void (d.rooms[name] = r)), summary: `room ${name} recorded${named.length ? ` (it holds ${named.join(", ")}, which named it already)` : ""}` };
}

export function modifyRoom(doc: PositionsDoc, name: string, sets: Array<[string, string]>): Result {
  if (!roomsOf(doc)[name]) return { refused: `room ${name} does not exist` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    for (const [k, v] of sets) {
      if (k === "name") refused = "a room's name is how racks and placements name it: add the new room, move them, delete this one";
      else if (!ROOM_FIELDS.includes(k)) refused = `room field '${k}' is not one of ${ROOM_FIELDS.join(", ")}`;
      else if (text(v) === undefined) delete d.rooms[name][k as keyof Room];
      else d.rooms[name][k as keyof Room] = v;
      if (refused) return;
    }
  });
  if (refused) return { refused };
  return { doc: next, summary: `room ${name}: ${sets.map(([k, v]) => `${k}=${v}`).join(", ")}` };
}

// room delete — only an empty room: no rack names it, nothing stands loose in it.
export function deleteRoom(doc: PositionsDoc, name: string): Result {
  if (!roomsOf(doc)[name]) return { refused: `room ${name} does not exist` };
  const racks = Object.entries(racksOf(doc)).filter(([, r]) => r.room === name).map(([n]) => n);
  const loose = Object.entries(placementsOf(doc)).filter(([, m]) => !m.rack && m.room === name).map(([n]) => n);
  if (racks.length || loose.length) return { refused: `room ${name} still holds ${[...racks.map((r) => `rack ${r}`), ...loose].join(", ")} — move them first` };
  return { doc: withDoc(doc, (d) => void delete d.rooms[name]), summary: `room ${name} deleted` };
}

// ── segments: a link split at a patch panel ───────────────────────────

const sameEnd = (a: { device: string; port: string }, b: { device: string; port: string }) => a.device === b.device && a.port === b.port;

// cable split <device:port> --via <panel:port> — the link on that port (a
// recorded cable, or one the topology sees: seen) becomes two recorded
// segments: the port to the panel port's front, the panel port's rear to the
// far end.
export function splitCable(doc: PositionsDoc, end: CableEnd, via: CableEnd, seen: { from: CableEnd; to: CableEnd; kind: string }[] | null): Result {
  const panel = devicesOf(doc)[via.device];
  if (!panel || panel.kind !== "patch-panel") return { refused: `${via.device} is no recorded patch panel (device add ${via.device} --kind patch-panel --ports <n>)` };
  if (!(panel.ports ?? []).includes(via.port) && !panel.model) return { refused: `patch panel ${via.device} has no port ${via.port}` };
  const busy = cablesOf(doc).find((c) => [c.from, c.to].some((e) => sameEnd(e, via)));
  if (busy) return { refused: `${via.device} port ${via.port} already carries ${endText(busy.from)} — ${endText(busy.to)}: choose a free panel port` };
  if (isPanel(doc, end.device)) return { refused: "split a link at one of its device ends, not at a panel port" };
  const rec = cablesOf(doc).find((c) => sameEnd(c.from, end) || sameEnd(c.to, end));
  if (rec && (isPanel(doc, rec.from.device) || isPanel(doc, rec.to.device))) return { refused: `${end.device}:${end.port} already runs through a patch panel (cable join to undo it)` };
  const s = rec ? null : seen?.find((c) => sameEnd(c.from, end) || sameEnd(c.to, end)) ?? null;
  if (!rec && !s) return { refused: `no link on ${end.device}:${end.port}${seen === null ? " (the topology could not be read: give --topology)" : ""}` };
  const link = (rec ?? s)!;
  const far = sameEnd(link.from, end) ? link.to : link.from;
  const kind = (rec ? rec.kind : CABLE_KINDS.includes(link.kind as CableKind) ? link.kind : "patch") as CableKind;
  const origin = rec ? "recorded" : "seen";
  const label = rec?.label;
  const a: Cable = { from: { device: end.device, port: end.port }, to: { device: via.device, port: via.port, side: "front" }, kind, origin, ...(label ? { label } : {}) };
  const b: Cable = { from: { device: via.device, port: via.port, side: "rear" }, to: { device: far.device, port: far.port }, kind, origin, ...(label ? { label } : {}) };
  return {
    doc: withDoc(doc, (d) => {
      if (rec) d.cables = d.cables.filter((c) => !(sameEnd(c.from, rec.from) && sameEnd(c.to, rec.to)));
      d.cables.push(a, b);
    }),
    summary: `${end.device}:${end.port} — ${far.device}:${far.port} now runs through ${via.device} port ${via.port} (front ← ${end.device}, rear → ${far.device})`,
  };
}

// cable join <end> — undo a split: the two segments at the panel port the
// end names (the panel's port, or a device end of one of its segments) are
// one link again; a recorded cable when it was one, else the topology's.
export function joinCable(doc: PositionsDoc, end: CableEnd): Result {
  const cables = cablesOf(doc);
  let panelEnd: CableEnd | null = null;
  if (isPanel(doc, end.device)) panelEnd = { device: end.device, port: end.port };
  else {
    const seg = cables.find((c) => (sameEnd(c.from, end) || sameEnd(c.to, end)) && (isPanel(doc, c.from.device) || isPanel(doc, c.to.device)));
    if (seg) panelEnd = isPanel(doc, seg.from.device) ? seg.from : seg.to;
  }
  if (!panelEnd) return { refused: `no link through a patch panel on ${end.device}:${end.port}` };
  const at = (side: string) => cables.find((c) => [c.from, c.to].some((e) => sameEnd(e, panelEnd!) && (e.side ?? "front") === side));
  const f = at("front");
  const r = at("rear");
  if (!f || !r) return { refused: `${panelEnd.device} port ${panelEnd.port} carries only its ${f ? "front" : "rear"} cable: nothing to join (cable remove it instead)` };
  const other = (c: Cable) => (sameEnd(c.from, panelEnd!) ? c.to : c.from);
  const x = other(f);
  const y = other(r);
  const keep = f.origin === "recorded" || r.origin === "recorded" || isPanel(doc, x.device) || isPanel(doc, y.device) || (!f.origin && !r.origin);
  const joined: Cable = { from: x, to: y, kind: f.kind, ...(f.label ? { label: f.label } : {}), ...(isPanel(doc, x.device) || isPanel(doc, y.device) ? { origin: f.origin ?? "recorded" } : {}) };
  return {
    doc: withDoc(doc, (d) => {
      d.cables = d.cables.filter((c) => c !== d.cables.find((z) => z.from.device === f.from.device && z.from.port === f.from.port && z.to.device === f.to.device && z.to.port === f.to.port) && c !== d.cables.find((z) => z.from.device === r.from.device && z.from.port === r.from.port && z.to.device === r.to.device && z.to.port === r.to.port));
      if (keep) d.cables.push(joined);
    }),
    summary: `${endText(x)} — ${endText(y)} no longer runs through ${panelEnd.device} port ${panelEnd.port}${keep ? " (recorded as one cable)" : " (the topology's link again)"}`,
  };
}
