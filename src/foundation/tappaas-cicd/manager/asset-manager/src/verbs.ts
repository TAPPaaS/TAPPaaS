// verbs.ts — what each asset-manager verb does to config/positions.json, as pure
// functions over the document: a verb returns the new document or a refusal.
// Validating the whole result and writing it are main.ts's; this is what the
// unit tests pin.

import {
  ASSET_KINDS,
  ASSET_PORT_KINDS,
  Asset,
  AssetKind,
  AssetPort,
  AssetPortKind,
  AssetStage,
  DATE_RE,
  DISK_KINDS,
  DISPOSAL_HOWS,
  DiskKind,
  DiskRecord,
  assetWithSerial,
  disksIn,
  parseSize,
  DeviceKind,
  Disposal,
  OWNERSHIPS,
  Procurement,
  SiteDevice,
  StageView,
  WifiBand,
  assetMacs,
  assetNamed,
  assetPorts,
  assetsOf,
  currentName,
  nextTag,
  parsePortArg,
  placementName,
  portProblem,
  stageOf,
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
  Rack,
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
  SeenDevice,
  MAC_RE,
  LINK_SPEED_RE,
  racksOf,
  FACEPLATE_KEY_RE,
  PLATE_KINDS,
  PlateKind,
  SiteFaceplate,
  faceplatesOf,
  parsePortSpec,
} from "../../../lib/ts/src/positions";

// A change: the new document and what it does in one line, as an act and its
// object ("add", "room 'stue' at hareskov"): the dry run says "would add …",
// the apply "added …" (changeLine).
export type Act = "add" | "modify" | "delete" | "remove" | "place" | "record" | "split" | "join" | "receive" | "mark" | "clear" | "dispose" | "allocate" | "release";
export type Change = { doc: PositionsDoc; act: Act; what: string };
export type Result = Change | { refused: string };

const PAST: Record<Act, string> = {
  add: "added",
  modify: "modified",
  delete: "deleted",
  remove: "removed",
  place: "placed",
  record: "recorded",
  split: "split",
  join: "joined",
  receive: "received",
  mark: "marked",
  clear: "cleared",
  dispose: "disposed of",
  allocate: "allocated",
  release: "released",
};

export function changeLine(c: { act: Act; what: string }, check: boolean): string {
  return check ? `would ${c.act} ${c.what}` : `${PAST[c.act]} ${c.what}`;
}

// The fields a modify sets, and that nothing else in the file moves.
const setText = (sets: Array<[string, string]>): string => `${sets.map(([k, v]) => (v === "" ? `${k} unset` : `${k}=${v}`)).join(", ")}; positions.json otherwise unchanged`;
// Where a room is: its location, else the site's primary one.
const roomAt = (doc: PositionsDoc, room: string, primary: string | null | undefined): string | null => roomsOf(doc)[room]?.location ?? primary ?? null;

const clone = (d: PositionsDoc): PositionsDoc => JSON.parse(JSON.stringify(d ?? {}));
type Doc = Required<Pick<PositionsDoc, "racks" | "placements" | "cables" | "assets" | "rooms" | "faceplates">>;
function withDoc(doc: PositionsDoc, fn: (d: Doc) => void): PositionsDoc {
  const d = clone(doc);
  d.version = 1;
  d.racks = d.racks ?? {};
  // A document from before positions.json: its mounts are the placements.
  d.placements = placementsOf(d);
  delete d.mounts;
  d.cables = d.cables ?? [];
  d.assets = d.assets ?? {};
  d.rooms = d.rooms ?? {};
  d.faceplates = d.faceplates ?? {};
  // A building is the site's now (its primary location): one recorded on a rack
  // or a room before goes, silently, at the next write.
  for (const x of [...Object.values(d.racks), ...Object.values(d.rooms)] as Record<string, unknown>[]) delete x.building;
  fn(d as Doc);
  // The keys in the order the schema lists them.
  const order = ["version", "rooms", "racks", "placements", "assets", "cables", "faceplates"] as const;
  const out: PositionsDoc = {};
  for (const k of order) if (d[k] !== undefined) (out as Record<string, unknown>)[k] = d[k];
  for (const [k, v] of Object.entries(d)) if (!(k in out)) (out as Record<string, unknown>)[k] = v;
  if (Object.keys(out.rooms ?? {}).length === 0) delete out.rooms;
  if ((out.cables ?? []).length === 0) delete out.cables;
  if (Object.keys(out.assets ?? {}).length === 0) delete out.assets;
  if (Object.keys(out.faceplates ?? {}).length === 0) delete out.faceplates;
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
  return { doc: withDoc(doc, (d) => void (d.racks[name] = rack)), act: "add", what: `rack '${name}' (${rack.units}U, ${width}, numbered ${numbering}${rack.room ? `, in room ${rack.room}` : ""})` };
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
  return { doc: next, act: "modify", what: `rack '${name}': ${setText(sets)}` };
}

// rack delete — only an empty rack: its devices are moved or unplaced first.
export function deleteRack(doc: PositionsDoc, name: string): Result {
  if (!racksOf(doc)[name]) return { refused: `rack ${name} does not exist` };
  const held = Object.entries(placementsOf(doc)).filter(([, m]) => m.rack === name).map(([d]) => d);
  if (held.length) return { refused: `rack ${name} still holds ${held.join(", ")} — move them (place modify <device> --set rack=…) or unplace them first` };
  return { doc: withDoc(doc, (d) => void delete d.racks[name]), act: "delete", what: `rack '${name}'` };
}

// ── mounts ────────────────────────────────────────────────────────────

export interface PlaceSpec {
  in?: string; // a disk into this asset (ADR-042 D1)
  bay?: string;
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

// place — a device into a rack at its units, or loose into a room. The
// height defaults to its faceplate's.
export function placeDevice(doc: PositionsDoc, name: string, spec: PlaceSpec, catalog: Faceplate[], primary?: string | null): Result {
  if (!name.trim()) return { refused: "place <device>: the device's topology name, or an asset's" };
  if (spec.in !== undefined) return placeDisk(doc, name, spec.in, spec.bay);
  // An asset is placed under the name it plays.
  const device = placementName(doc, name);
  const asset = assetNamed(doc, device);
  if (asset?.asset.kind === "disk") return { refused: `${asset.key} is a disk: it is placed in an asset (place ${asset.key} --in <asset> [--bay <bay>])` };
  if (asset && (asset.asset.stage === "ordered" || asset.asset.stage === "disposed")) return { refused: `asset ${asset.key} is ${asset.asset.stage}: ${asset.asset.stage === "ordered" ? `asset receive ${asset.key} first` : "it is not here"}` };
  const r = placeAt(doc, device, spec, catalog, primary);
  if ("refused" in r || !asset) return r;
  return { ...r, doc: withDoc(r.doc, (d) => void (d.assets[asset.key].stage = d.assets[asset.key].stage === "stock" ? "placed" : d.assets[asset.key].stage)) };
}

function placeAt(doc: PositionsDoc, device: string, spec: PlaceSpec, catalog: Faceplate[], primary?: string | null): Result {
  if (placementsOf(doc)[device]) return { refused: `${device} is already placed in ${placeWhere(placementsOf(doc)[device])} — place modify ${device} to move it` };
  if (spec.room !== undefined) {
    if (spec.rack !== undefined || spec.u !== undefined) return { refused: "--room places a device loose in a room: no --rack, no --u (a rack names its own room)" };
    if (!roomsOf(doc)[spec.room]) return { refused: `room ${spec.room} does not exist (room add ${spec.room})` };
    if (spec.height !== undefined || spec.width !== undefined || spec.slot !== undefined || spec.face !== undefined) return { refused: "a device loose in a room has no height, width, slot or face: its plate gives its size" };
    const fp = spec.faceplate ? catalog.find((f) => f.key === spec.faceplate) : undefined;
    if (spec.faceplate && !fp) return { refused: `faceplate ${spec.faceplate} is not in the catalog (faceplates list)` };
    const m: Placement = { room: spec.room };
    for (const k of ["faceplate", "label", "description"] as const) if (spec[k]) m[k] = spec[k];
    return { doc: withDoc(doc, (d) => void (d.placements[device] = m)), act: "place", what: `'${device}' loose in room ${spec.room}${roomAt(doc, spec.room, primary) ? ` (location ${roomAt(doc, spec.room, primary)})` : ""}` };
  }
  if (spec.rack === undefined || spec.u === undefined) return { refused: "place <device> --rack <rack> --u <n>, or --room <room> for a device loose in a room" };
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
    act: "place",
    what: `'${device}' in ${m.rack} at U${m.u}${heightOf(m) > 1 ? `-U${(m.u ?? 0) + heightOf(m) - 1}` : ""}, ${m.face}${width === "full" ? "" : `, ${width} width slot ${m.slot}`}`,
  };
}

const PLACEMENT_FIELDS = ["rack", "u", "room", "height", "width", "slot", "face", "faceplate", "label", "description"];

// place modify — a move (rack, u, slot, face, or room) or its plate and label. The
// device is the key: another device is another mount.
export function modifyPlacement(doc: PositionsDoc, name: string, sets: Array<[string, string]>, catalog: Faceplate[]): Result {
  const device = placementName(doc, name);
  if (!placementsOf(doc)[device]) return { refused: `${device} is placed nowhere (place ${device} …)` };
  if (placementsOf(doc)[device].in !== undefined) return { refused: `${device} is a disk in ${placementsOf(doc)[device].in}: place ${device} --in <asset> [--bay <bay>] moves it` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const m = d.placements[device];
    for (const [k, v] of sets) {
      if (k === "device") refused = "the device is the placement's key: unplace it and place the other device";
      else if (!PLACEMENT_FIELDS.includes(k)) refused = `placement field '${k}' is not one of ${PLACEMENT_FIELDS.join(", ")}`;
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
  return { doc: next, act: "modify", what: `placement of '${device}': ${setText(sets)}` };
}

// unplace — the device leaves its rack or room (the device itself is untouched).
// The recorded cables that name it go with it only when it is passive
// (nothing else knows it); a topology device keeps its recorded cables.
export function unplaceDevice(doc: PositionsDoc, name: string, passive: boolean): Result {
  const device = placementName(doc, name);
  const was = placementsOf(doc)[device];
  if (!was) return { refused: `${device} is placed nowhere` };
  const dropped = passive ? cablesOf(doc).filter((c) => c.from.device === device || c.to.device === device).length : 0;
  const asset = assetNamed(doc, device);
  return {
    doc: withDoc(doc, (d) => {
      delete d.placements[device];
      if (passive) d.cables = d.cables.filter((c) => c.from.device !== device && c.to.device !== device);
      // An asset off its shelf or out of its rack is in stock again.
      if (asset && d.assets[asset.key].stage === "placed") d.assets[asset.key].stage = "stock";
    }),
    act: "remove",
    what: `placement of '${device}' from ${was.in !== undefined ? placeWhere(was).slice(3) : was.rack ? `${was.rack} U${was.u}` : `room ${was.room}`}${dropped ? ` (and its ${dropped} recorded cable(s))` : ""}${was.in !== undefined ? " (in stock)" : ""}`,
  };
}

// ── cables ────────────────────────────────────────────────────────────

export function addCable(doc: PositionsDoc, fromEnd: CableEnd, toEnd: CableEnd, kind: string, label?: string, linkSpeed?: string): Result {
  if (!CABLE_KINDS.includes(kind as CableKind)) return { refused: `--kind is one of ${CABLE_KINDS.join(", ")}` };
  if (linkSpeed !== undefined && !LINK_SPEED_RE.test(linkSpeed)) return { refused: "--link-speed is a number and its unit, lowercase: 100m, 1g, 2.5g, 10g" };
  // An asset's end is named as it plays.
  const from = { ...fromEnd, device: placementName(doc, fromEnd.device) };
  const to = { ...toEnd, device: placementName(doc, toEnd.device) };
  // The same port (and, on a patch panel, the same side).
  const same = (e: CableEnd, x: CableEnd) => e.device === x.device && e.port === x.port && (!isPanel(doc, e.device) || (e.side ?? "front") === (x.side ?? "front"));
  const taken = cablesOf(doc).find((c) => [c.from, c.to].some((e) => [from, to].some((x) => same(e, x))));
  if (taken) return { refused: `${endText(taken.from)} — ${endText(taken.to)} already uses one of these ports: remove it first` };
  const c: Cable = { from, to, kind: kind as CableKind, ...(label ? { label } : {}), ...(linkSpeed ? { linkSpeed } : {}) };
  return { doc: withDoc(doc, (d) => void d.cables.push(c)), act: "record", what: `cable ${endText(from)} — ${endText(to)} (${kind})` };
}

// cable remove <device:port> — the recorded cable on that port (a patch
// panel's: on the side given, front unless told).
export function removeCable(doc: PositionsDoc, given: CableEnd): Result {
  const end = { ...given, device: placementName(doc, given.device) };
  const on = (e: CableEnd) => e.device === end.device && e.port === end.port && (!isPanel(doc, e.device) || (e.side ?? "front") === (end.side ?? "front"));
  const c = cablesOf(doc).find((x) => on(x.from) || on(x.to));
  if (!c) return { refused: `no recorded cable on ${endText(end)} (a cable the topology sees is not recorded here)` };
  return { doc: withDoc(doc, (d) => void (d.cables = d.cables.filter((x) => x !== d.cables.find((y) => on(y.from) || on(y.to))))), act: "remove", what: `cable ${endText(c.from)} — ${endText(c.to)}` };
}

// ── assets (ADR-040 D7-D9) ─────────────────────────────────────────────

export interface AssetSpec {
  kind?: string;
  vendor?: string;
  model?: string;
  serial?: string;
  assetTag?: string;
  location?: string;
  stage?: string; // ordered or stock
  ports?: number; // 1..n, rj45 at 1g
  port?: string[]; // <name>[:<kind>[:<speed>]]
  displayName?: string;
  description?: string;
  procurement?: Procurement;
}

const PROCUREMENT_FIELDS = ["supplier", "orderRef", "purchaseDate", "warrantyUntil", "ownership", "notes"] as const;

// The ports a spec names: --port, else 1..--ports (rj45 at 1g).
function portsOf(spec: AssetSpec): AssetPort[] | undefined | { refused: string } {
  if (spec.port?.length && spec.ports !== undefined) return { refused: "give --ports <n> or --port <name>..., not both" };
  if (spec.port?.length) {
    const out: AssetPort[] = [];
    for (const s of spec.port) {
      const p = parsePortArg(s);
      if ("error" in p) return { refused: p.error };
      if (out.some((x) => x.name === p.name)) return { refused: `port ${p.name} is given twice` };
      out.push(p);
    }
    return out;
  }
  if (spec.ports !== undefined) {
    if (spec.ports < 1 || spec.ports > 96) return { refused: "--ports is 1 to 96" };
    return Array.from({ length: spec.ports }, (_, i): AssetPort => ({ name: String(i + 1), kind: "rj45", speed: "1g" }));
  }
  return undefined;
}

// What is wrong with procurement fields, before the whole check.
function procurementProblem(p: Procurement): string | null {
  if (p.ownership !== undefined && !OWNERSHIPS.includes(p.ownership)) return `ownership is ${OWNERSHIPS.join(" or ")}`;
  for (const k of ["purchaseDate", "warrantyUntil"] as const) if (p[k] !== undefined && !DATE_RE.test(p[k]!)) return `${k} is a date, YYYY-MM-DD`;
  return null;
}

const stageWords = (s: StageView): string => (s === "stock" ? "in stock" : s);

// asset add — a physical asset, bought or found, in stock unless it is only
// ordered. With no name it takes the next free tag of its kind (srv-NN,
// sw-NN, ap-NN, dev-NN). seen: the topology's device names (null: not read) —
// a name it has is a role, which an asset is allocated to, not named after.
export function addAsset(doc: PositionsDoc, name: string | undefined, spec: AssetSpec, catalog: Faceplate[], seen: string[] | null): Result {
  if (!ASSET_KINDS.includes(spec.kind as AssetKind)) return { refused: `--kind is one of ${ASSET_KINDS.join(", ")}` };
  const kind = spec.kind as AssetKind;
  const key = name ?? nextTag(doc, kind);
  if (!DEVICE_NAME_RE.test(key)) return { refused: `asset name '${key}': letters, digits, spaces, dots, dashes and underscores, up to 63` };
  if (assetsOf(doc)[key]) return { refused: `asset ${key} is already recorded (asset modify ${key})` };
  const playing = assetNamed(doc, key);
  if (playing) return { refused: `${key} is the role asset ${playing.key} plays: name the new asset otherwise` };
  if (seen?.includes(key)) return { refused: `the topology sees a device named ${key}: add the asset under its own name (or none: the next tag) and asset allocate it --role '${key}'` };
  const stage = (spec.stage ?? "stock") as AssetStage;
  if (stage !== "ordered" && stage !== "stock") return { refused: "--stage is ordered or stock (placed comes from place, operational from a role)" };
  if (spec.model && FACEPLATE_KEY_RE.test(spec.model) && !catalog.some((f) => f.key === spec.model)) return { refused: `model ${spec.model} is not in the catalog (faceplates list)` };
  const ports = portsOf(spec);
  if (ports && !Array.isArray(ports)) return ports;
  const a: Asset = { kind, stage };
  for (const k of ["displayName", "description", "vendor", "model", "serial", "assetTag", "location"] as const) if (spec[k]) a[k] = spec[k];
  if (ports?.length) a.ports = ports;
  const pr = Object.fromEntries(Object.entries(spec.procurement ?? {}).filter(([, v]) => v !== undefined && v !== "")) as Procurement;
  if (Object.keys(pr).length) {
    const bad = procurementProblem(pr);
    if (bad) return { refused: bad };
    a.procurement = pr;
  }
  if (a.serial) {
    const twin = Object.entries(assetsOf(doc)).find(([, x]) => x.serial === a.serial);
    if (twin) return { refused: `serial ${a.serial} is asset ${twin[0]}'s` };
  }
  const n = assetPorts(a, catalog).length;
  return { doc: withDoc(doc, (x) => void (x.assets[key] = a)), act: "add", what: `asset '${key}' (${kind}${a.model ? `, ${a.model}` : ""}, ${stageWords(stage)}, ${n} port(s)${a.location ? `, at ${a.location}` : ""})` };
}

const ASSET_FIELDS = ["kind", "vendor", "model", "serial", "assetTag", "displayName", "description", "location", "ports", "mac", "faultNote", ...PROCUREMENT_FIELDS.map((f) => `procurement.${f}`)];

// asset modify — its records: kind, vendor, model, serial, tag, names,
// location, procurement; ports (a count or a comma list, rj45 at 1g) and mac
// (its first port's) as device modify had them. Its stage, role and fault
// have verbs of their own.
export function modifyAsset(doc: PositionsDoc, name: string, sets: Array<[string, string]>, catalog: Faceplate[]): Result {
  if (!assetsOf(doc)[name]) return { refused: `asset ${name} is not recorded` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const a = d.assets[name];
    for (const [k, v] of sets) {
      if (k === "name") refused = "an asset's name is its key and stays: add a new asset for a new thing";
      else if (k === "role") refused = `the role is asset allocate ${name} --role <name> and asset release ${name}`;
      else if (k === "stage") refused = "the stage follows its verbs: asset receive, place, unplace, asset dispose";
      else if (k === "faulty") refused = `the fault flag is asset fault ${name} --note … and asset repaired ${name}`;
      else if (!ASSET_FIELDS.includes(k)) refused = `asset field '${k}' is not one of ${ASSET_FIELDS.join(", ")}`;
      else if (k === "kind") {
        if (!ASSET_KINDS.includes(v as AssetKind)) refused = `kind is one of ${ASSET_KINDS.join(", ")}`;
        else if ((v === "disk") !== (a.kind === "disk")) refused = "a disk stays a disk and nothing else becomes one: add the right asset, remove this one";
        else a.kind = v as AssetKind;
      } else if (k === "model") {
        if (text(v) === undefined) delete a.model;
        else if (FACEPLATE_KEY_RE.test(v) && !catalog.some((f) => f.key === v)) refused = `model ${v} is not in the catalog (faceplates list)`;
        else a.model = v;
      } else if (k === "ports") {
        const n = int(v);
        const names = n !== null ? Array.from({ length: n }, (_, i) => String(i + 1)) : v.split(",").map((x) => x.trim()).filter(Boolean);
        if (text(v) === undefined) delete a.ports;
        else a.ports = names.map((p) => a.ports?.find((x) => x.name === p) ?? { name: p, kind: "rj45", speed: "1g" });
      } else if (k === "mac") {
        const first = a.ports?.[0];
        if (text(v) === undefined) {
          if (first) delete first.mac;
        } else if (!MAC_RE.test(v.toLowerCase())) refused = "mac is six hex pairs, aa:bb:cc:dd:ee:ff";
        else if (!first) refused = `${name} has no port of its own to carry a MAC: port add ${name} <port> --kind rj45 --mac ${v}`;
        else first.mac = v.toLowerCase();
      } else if (k === "faultNote") {
        if (!a.faulty) refused = `${name} is not faulty: asset fault ${name} --note …`;
        else if (text(v) === undefined) refused = `a faulty asset keeps its note: asset repaired ${name} clears both`;
        else a.faultNote = v;
      } else if (k.startsWith("procurement.")) {
        const f = k.slice("procurement.".length) as (typeof PROCUREMENT_FIELDS)[number];
        const pr: Procurement = { ...(a.procurement ?? {}) };
        if (text(v) === undefined) delete pr[f];
        else (pr as Record<string, string>)[f] = v;
        const bad = procurementProblem(pr);
        if (bad) refused = bad;
        else if (Object.keys(pr).length) a.procurement = pr;
        else delete a.procurement;
      } else {
        const key = k as "vendor" | "serial" | "assetTag" | "displayName" | "description" | "location";
        if (text(v) === undefined) delete a[key];
        else a[key] = v;
      }
      if (refused) return;
    }
  });
  if (refused) return { refused };
  return { doc: next, act: "modify", what: `asset '${name}': ${setText(sets)}` };
}

export interface RecordSpec {
  name?: string; // absent: the next free tag of its kind
  kind?: string;
  port?: string; // its port the cable reaches
  model?: string;
  location?: string;
  displayName?: string;
  description?: string;
}

// asset record — a device a switch port sees and nobody recorded becomes an
// asset playing itself (its role its name): its MAC kept on the port the
// cable reaches (so the topology knows it as recorded), at the switch's
// location unless told, and the port's link recorded as its cable (nothing
// else sees that link). taken: the topology's device names.
export function recordSeen(doc: PositionsDoc, seen: SeenDevice, spec: RecordSpec, catalog: Faceplate[], taken: string[] | null, primary: string | null): Result {
  const busy = cablesOf(doc).find((c) => [c.from, c.to].some((e) => e.device === seen.switch && e.port === seen.port));
  if (busy) return { refused: `${seen.switch}:${seen.port} already has the recorded cable ${endText(busy.from)} — ${endText(busy.to)}` };
  if (seen.mac && Object.values(assetsOf(doc)).some((a) => assetMacs(a).includes(seen.mac!))) return { refused: `${seen.mac} is recorded already` };
  if (!ASSET_KINDS.includes(spec.kind as AssetKind)) return { refused: `--kind is one of ${ASSET_KINDS.join(", ")}` };
  const name = spec.name ?? nextTag(doc, spec.kind as AssetKind);
  const fp = spec.model ? catalog.find((f) => f.key === spec.model) : undefined;
  const modelPorts = fp ? assetPorts({ model: fp.key }, catalog) : [];
  const port = spec.port ?? (seen.lldp?.port && (!fp || modelPorts.some((p) => p.name === seen.lldp!.port)) ? seen.lldp.port : modelPorts[0]?.name ?? "1");
  const onPlate = modelPorts.find((p) => p.name === port);
  const location = spec.location ?? (seen.location && seen.location !== primary ? seen.location : undefined);
  const added = addAsset(doc, name, {
    kind: spec.kind,
    model: spec.model,
    displayName: spec.displayName ?? seen.lldp?.name ?? seen.lease?.hostname ?? undefined,
    description: spec.description,
    location,
  }, catalog, taken?.filter((n) => n !== seen.name) ?? null);
  if ("refused" in added) return added;
  const own: AssetPort = onPlate ? { name: port, kind: onPlate.kind } : { name: port, kind: "rj45", speed: "1g" };
  if (seen.mac) own.mac = seen.mac;
  const cable: Cable = { from: { device: seen.switch, port: seen.port }, to: { device: name, port }, kind: "patch" };
  return {
    doc: withDoc(added.doc, (d) => {
      d.assets[name].ports = [own];
      d.assets[name].role = name;
      d.cables.push(cable);
    }),
    act: "record",
    what: `asset '${name}' (${spec.kind}${seen.mac ? `, ${seen.mac}` : ""}) seen on ${seen.switch}:${seen.port}, with its cable to port ${port}`,
  };
}

// asset remove — a record made by mistake: only one nothing names (unplaced,
// no recorded cable) and in no role but its own. A disposed asset's record
// stays: that is its history.
export function removeAsset(doc: PositionsDoc, name: string): Result {
  const a = assetsOf(doc)[name];
  if (!a) return { refused: `asset ${name} is not recorded` };
  if (a.stage === "disposed") return { refused: `${name} is disposed: its record stays, read-only, with its history` };
  if (a.role && a.role !== name) return { refused: `${name} plays ${a.role} — asset release ${name} first` };
  const at = currentName(name, a);
  if (placementsOf(doc)[at]) return { refused: `${at} is placed — unplace ${at} first` };
  const held = disksIn(doc, name);
  if (held.length) return { refused: `${name} holds the disk(s) ${held.map((x) => x.key).join(", ")} — --with-disks removes their records with it, --disks-to-stock unplaces them into stock first (or unplace or move them)` };
  const cables = cablesOf(doc).filter((c) => c.from.device === at || c.to.device === at);
  const e = cables[0]?.from.device === at ? cables[0].from : cables[0]?.to;
  if (cables.length) return { refused: `${at} is an end of ${cables.length} recorded cable(s) — cable remove '${e.device}:${e.port}' first` };
  return { doc: withDoc(doc, (d) => void delete d.assets[name]), act: "remove", what: `asset '${name}'` };
}

// asset receive — what was ordered has come: in stock.
export function receiveAsset(doc: PositionsDoc, name: string): Result {
  const a = assetsOf(doc)[name];
  if (!a) return { refused: `asset ${name} is not recorded` };
  if (a.stage !== "ordered") return { refused: `${name} is ${stageWords(stageOf(doc, name, a))}, not ordered` };
  return { doc: withDoc(doc, (d) => void (d.assets[name].stage = "stock")), act: "receive", what: `asset '${name}' into stock` };
}

// asset fault — the faulty flag, with what is wrong; the stage stays (a node
// with a failed fan is operational and faulty).
export function faultAsset(doc: PositionsDoc, name: string, note: string | undefined): Result {
  const a = assetsOf(doc)[name];
  if (!a) return { refused: `asset ${name} is not recorded` };
  if (a.stage === "disposed") return { refused: `${name} is disposed` };
  if (!note?.trim()) return { refused: "--note <what is wrong> is required" };
  return {
    doc: withDoc(doc, (d) => Object.assign(d.assets[name], { faulty: true, faultNote: note.trim() })),
    act: "mark",
    what: `asset '${name}' faulty: ${note.trim()} (${stageWords(stageOf(doc, name, a))})`,
  };
}

// asset repaired — the flag and its note cleared.
export function repairAsset(doc: PositionsDoc, name: string): Result {
  const a = assetsOf(doc)[name];
  if (!a) return { refused: `asset ${name} is not recorded` };
  if (!a.faulty) return { refused: `${name} is not faulty` };
  return {
    doc: withDoc(doc, (d) => {
      delete d.assets[name].faulty;
      delete d.assets[name].faultNote;
    }),
    act: "clear",
    what: `asset '${name}''s fault${a.faultNote ? ` (${a.faultNote})` : ""}`,
  };
}

// asset dispose — it leaves the site: how, when, and whether its disks were
// wiped. Ending a role, unplacing and disposing are three acts (ADR-040 D8),
// so one with a role, a placement or a recorded cable is refused. The record
// stays.
export function disposeAsset(doc: PositionsDoc, name: string, how: string | undefined, wiped: boolean, when: string): Result {
  const a = assetsOf(doc)[name];
  if (!a) return { refused: `asset ${name} is not recorded` };
  if (a.stage === "disposed") return { refused: `${name} is disposed already (${a.disposal?.how ?? "?"}${a.disposal?.when ? `, ${a.disposal.when}` : ""})` };
  if (!DISPOSAL_HOWS.includes(how as Disposal["how"])) return { refused: `--how is one of ${DISPOSAL_HOWS.join(", ")}` };
  if (!DATE_RE.test(when)) return { refused: "--when is a date, YYYY-MM-DD" };
  if (a.role) return { refused: `${name} plays ${a.role} — asset release ${name} first` };
  if (placementsOf(doc)[name]) return { refused: `${name} is placed in ${placeWhere(placementsOf(doc)[name])} — unplace ${name} first` };
  const held = disksIn(doc, name);
  if (held.length) return { refused: `${name} holds the disk(s) ${held.map((x) => x.key).join(", ")} — --with-disks disposes of them with it (each wiped as --wiped says), --disks-to-stock unplaces them into stock first` };
  const cable = cablesOf(doc).find((c) => c.from.device === name || c.to.device === name);
  if (cable) return { refused: `${name} is an end of the recorded cable ${endText(cable.from)} — ${endText(cable.to)}: cable remove it first` };
  const disposal: Disposal = { how: how as Disposal["how"], when, ...(wiped ? { wiped: true } : {}) };
  return { doc: withDoc(doc, (d) => Object.assign(d.assets[name], { stage: "disposed", disposal })), act: "dispose", what: `asset '${name}' (${how}, ${when}${wiped ? ", disks wiped" : ""}); its record stays` };
}

// What becomes of the disks an asset holds when it is removed or disposed
// of: they go with it, or they are unplaced into stock first (for reuse).
export type DiskWay = "with-disks" | "to-stock";
// A verb of several steps, each a change of its own (in order, each over the
// one before): what the CMDB is told step by step; the file saved once.
export type Steps = { steps: Change[] } | { refused: string };

// Run the steps over doc; the first refusal refuses them all.
function chain(doc: PositionsDoc, fns: Array<(d: PositionsDoc) => Result>): Steps {
  const steps: Change[] = [];
  let cur = doc;
  for (const fn of fns) {
    const r = fn(cur);
    if ("refused" in r) return r;
    steps.push(r);
    cur = r.doc;
  }
  return { steps };
}

// The steps that take an asset's disks out of it: to stock (unplaced), or
// with it (their recorded cables, then each disk's placement and record; a
// disposal unplaces each and disposes of it, wiped as the asset says).
function diskSteps(doc: PositionsDoc, name: string, way: DiskWay | undefined, dispose?: { how: string | undefined; wiped: boolean; when: string }): Array<(d: PositionsDoc) => Result> {
  if (!way) return [];
  const fns: Array<(d: PositionsDoc) => Result> = [];
  for (const { key } of disksIn(doc, name)) {
    if (way === "to-stock") {
      fns.push((d) => unplaceDevice(d, key, false));
      continue;
    }
    for (const c of cablesOf(doc).filter((x) => x.from.device === key || x.to.device === key)) fns.push((d) => removeCable(d, c.from.device === key ? c.from : c.to));
    if (!dispose) {
      fns.push((d) => removeDisk(d, key));
      continue;
    }
    // Out of its asset and disposed of: one step, as the CMDB sees it.
    fns.push((d) => {
      const m = placementsOf(d)[key];
      const out = unplaceDevice(d, key, false);
      if ("refused" in out) return out;
      const r = disposeAsset(out.doc, key, dispose.how, dispose.wiped, dispose.when);
      if ("refused" in r) return r;
      return { ...r, what: `disk '${key}'${m ? `, ${placeWhere(m)}` : ""} (${dispose.how}, ${dispose.when}${dispose.wiped ? ", wiped" : ""}); its record stays` };
    });
  }
  return fns;
}

// asset remove <asset> --with-disks | --disks-to-stock — the record goes,
// and the disks it holds with it or into stock first. The asset's own
// conditions are checked before any disk is touched: one refusal, no change.
export function removeAssetSteps(doc: PositionsDoc, name: string, way?: DiskWay): Steps {
  const own = removeAsset({ ...doc, placements: Object.fromEntries(Object.entries(placementsOf(doc)).filter(([, m]) => m.in !== name)) }, name);
  if ("refused" in own) return own;
  return chain(doc, [...diskSteps(doc, name, way), (d) => removeAsset(d, name)]);
}

// asset dispose <asset> … --with-disks | --disks-to-stock — the same for a
// disposal: its disks disposed of with it (the one --wiped answer), or in
// stock first.
export function disposeAssetSteps(doc: PositionsDoc, name: string, how: string | undefined, wiped: boolean, when: string, way?: DiskWay): Steps {
  const own = disposeAsset({ ...doc, placements: Object.fromEntries(Object.entries(placementsOf(doc)).filter(([, m]) => m.in !== name)) }, name, how, wiped, when);
  if ("refused" in own) return own;
  return chain(doc, [...diskSteps(doc, name, way, { how, wiped, when }), (d) => disposeAsset(d, name, how, wiped, when)]);
}

// Every placement and recorded cable end named `from` is named `to`: what a
// role's start and end move (a placement survives the role, ADR-040 D7).
function rename(d: Doc, from: string, to: string): number {
  let n = 0;
  if (d.placements[from]) {
    d.placements[to] = d.placements[from];
    delete d.placements[from];
  }
  for (const c of d.cables) for (const e of [c.from, c.to]) if (e.device === from) {
    e.device = to;
    n++;
  }
  return n;
}

// The topology's device kinds each asset kind can play; others play any.
const PLAYS: Partial<Record<AssetKind, DeviceKind[]>> = { server: ["node", "machine"], switch: ["switch"], "access-point": ["ap"] };

// asset allocate — the asset takes a role: the topology's name for the node,
// machine, switch or AP it is from now on, or a device nothing manages that
// it is (a name the topology does not have yet). Its placement and recorded
// cables move to the role's name, which is what the topology joins on.
// devices: the topology's (null: not read, and the role is not checked).
export function allocateAsset(doc: PositionsDoc, name: string, role: string | undefined, devices: SiteDevice[] | null): Result {
  const a = assetsOf(doc)[name];
  if (!a) return { refused: `asset ${name} is not recorded` };
  if (!role?.trim()) return { refused: "--role <name> is required: the topology's name for what it plays" };
  if (a.kind === "disk") return { refused: `${name} is a disk: it plays no role, it is in an asset (place ${name} --in <asset>)` };
  if (a.stage === "ordered" || a.stage === "disposed") return { refused: `${name} is ${a.stage}: ${a.stage === "ordered" ? `asset receive ${name} first` : "it plays nothing any more"}` };
  if (a.role === role) return { refused: `${name} plays ${role} already` };
  if (a.role) return { refused: `${name} plays ${a.role} — asset release ${name} first` };
  if (!DEVICE_NAME_RE.test(role)) return { refused: `a role is a device's name: letters, digits, spaces, dots, dashes and underscores` };
  const other = assetNamed(doc, role);
  if (other && other.key !== name) return { refused: other.key === role ? `${role} is an asset's name` : `${role} is played by asset ${other.key} — asset release ${other.key} first` };
  const t = devices?.find((d) => d.name === role && !d.recorded) ?? null;
  if (t?.seen) return { refused: `${role} is a device a switch port only sees: asset record it instead` };
  const want = PLAYS[a.kind];
  if (want && devices !== null && !t) return { refused: `the topology has no ${want.join(" or ")} named ${role}: a ${a.kind} plays one (network-manager topology)` };
  if (want && t && !want.includes(t.kind)) return { refused: `${role} is a ${t.kind}: a ${a.kind} plays a ${want.join(" or ")}` };
  const p = placementsOf(doc);
  if (p[name] && p[role] && role !== name) return { refused: `${name} is placed in ${placeWhere(p[name])} and ${role} in ${placeWhere(p[role])}: unplace one of them first` };
  let moved = 0;
  const next = withDoc(doc, (d) => {
    d.assets[name].role = role;
    if (role !== name) moved = rename(d, name, role);
  });
  const placed = !!placementsOf(next)[role];
  return {
    doc: next,
    act: "allocate",
    what: `asset '${name}' to the role ${role}${t ? ` (the topology's ${t.kind})` : " (a device nothing manages)"}${placed || moved ? `; its ${[placed ? "placement" : "", moved ? `${moved} cable end(s)` : ""].filter(Boolean).join(" and ")} under ${role}` : ""}`,
  };
}

// asset release — the role ends; the asset keeps its placement, ports and
// cables, under its own name again, and falls back to placed or stock.
export function releaseAsset(doc: PositionsDoc, name: string): Result {
  const a = assetsOf(doc)[name];
  if (!a) return { refused: `asset ${name} is not recorded` };
  if (!a.role) return { refused: `${name} plays no role` };
  const role = a.role;
  if (role !== name && placementsOf(doc)[name]) return { refused: `a placement is keyed ${name} besides ${role}'s: unplace ${name} first` };
  let moved = 0;
  const next = withDoc(doc, (d) => {
    delete d.assets[name].role;
    if (role !== name) moved = rename(d, role, name);
  });
  const placed = !!placementsOf(next)[name];
  return { doc: next, act: "release", what: `asset '${name}' from the role ${role} (${placed ? "placed" : "in stock"}${role !== name && (placed || moved) ? `; its ${[placed ? "placement" : "", moved ? `${moved} cable end(s)` : ""].filter(Boolean).join(" and ")} under ${name}` : ""})` };
}

// ── an asset's ports ──────────────────────────────────────────────────

export interface PortSpec {
  kind?: string;
  speed?: string;
  standard?: string;
  bands?: string; // comma separated
  module?: string;
  role?: string;
  mac?: string;
  side?: string;
}
const PORT_FIELDS = ["kind", "speed", "standard", "bands", "module", "role", "mac", "side"];

// A port's field from its text: bands a comma list, a MAC lower case.
function setPortField(p: AssetPort & Record<string, unknown>, k: string, v: string): void {
  if (text(v) === undefined) delete p[k];
  else if (k === "bands") p.bands = v.split(",").map((x) => x.trim()).filter(Boolean) as WifiBand[];
  else p[k] = k === "mac" ? v.toLowerCase() : v;
}

// port add — a port of the asset's own: its connector and what goes with it.
// rj45 is 1g unless told.
export function addPort(doc: PositionsDoc, asset: string, port: string, spec: PortSpec, catalog: Faceplate[]): Result {
  const a = assetsOf(doc)[asset];
  if (!a) return { refused: `asset ${asset} is not recorded` };
  if (!port?.trim() || port.includes(":")) return { refused: "a port's name is text without a colon" };
  if (assetPorts(a, catalog).some((p) => p.name === port)) return { refused: `${asset} has a port ${port} already (port modify ${asset} ${port})` };
  if (!ASSET_PORT_KINDS.includes(spec.kind as AssetPortKind)) return { refused: `--kind is one of ${ASSET_PORT_KINDS.join(", ")}` };
  const p = { name: port, kind: spec.kind as AssetPortKind } as AssetPort & Record<string, unknown>;
  for (const k of PORT_FIELDS.slice(1)) {
    const v = spec[k as keyof PortSpec];
    if (v !== undefined) setPortField(p, k, v);
  }
  if (p.kind === "rj45" && p.speed === undefined) p.speed = "1g";
  const bad = portProblem(p, a.kind === "patch-panel");
  if (bad) return { refused: bad };
  return { doc: withDoc(doc, (d) => void (d.assets[asset].ports = [...(d.assets[asset].ports ?? []), p])), act: "add", what: `port ${port} to asset '${asset}' (${portWords(p)})` };
}

const portWords = (p: AssetPort): string => [p.kind, p.speed, p.standard, p.bands?.join("/"), p.module, p.role, p.mac, p.side].filter(Boolean).join(" ");

// port modify — a port's fields; a port of its model's plate takes an entry
// of its own, merged over the plate's.
export function modifyPort(doc: PositionsDoc, asset: string, port: string, sets: Array<[string, string]>, catalog: Faceplate[]): Result {
  const a = assetsOf(doc)[asset];
  if (!a) return { refused: `asset ${asset} is not recorded` };
  const merged = assetPorts(a, catalog).find((p) => p.name === port);
  if (!merged) return { refused: `${asset} has no port ${port} (port add ${asset} ${port} --kind …)` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const own = d.assets[asset].ports ?? [];
    let p = own.find((x) => x.name === port) as (AssetPort & Record<string, unknown>) | undefined;
    if (!p) {
      p = { name: port, kind: merged.kind };
      own.push(p);
    }
    for (const [k, v] of sets) {
      if (k === "name") refused = "a port's name is how cables name it: port add the new one, move the cable, port remove this one";
      else if (!PORT_FIELDS.includes(k)) refused = `port field '${k}' is not one of ${PORT_FIELDS.join(", ")}`;
      else if (k === "kind" && text(v) === undefined) refused = "a port keeps its kind";
      else setPortField(p, k, v);
      if (refused) return;
    }
    // What the plate gives is not restated: the port is checked as merged.
    const bad = portProblem({ ...merged, ...p } as AssetPort, d.assets[asset].kind === "patch-panel");
    if (bad) refused = bad;
    d.assets[asset].ports = own;
  });
  if (refused) return { refused };
  return { doc: next, act: "modify", what: `port ${port} of asset '${asset}': ${setText(sets)}` };
}

// port remove — a port of its own, that no recorded cable uses. One that
// refines a plate's port goes back to the plate's.
export function removePort(doc: PositionsDoc, asset: string, port: string, catalog: Faceplate[]): Result {
  const a = assetsOf(doc)[asset];
  if (!a) return { refused: `asset ${asset} is not recorded` };
  const own = (a.ports ?? []).some((p) => p.name === port);
  const plate = assetPorts({ model: a.model }, catalog).some((p) => p.name === port);
  if (!own) return { refused: plate ? `port ${port} is its model's (${a.model}): a plate's port stays` : `${asset} has no port ${port}` };
  const at = currentName(asset, a);
  const c = cablesOf(doc).find((x) => [x.from, x.to].some((e) => e.device === at && e.port === port));
  if (c && !plate) return { refused: `${at}:${port} carries the recorded cable ${endText(c.from)} — ${endText(c.to)}: cable remove it first` };
  return {
    doc: withDoc(doc, (d) => {
      d.assets[asset].ports = (d.assets[asset].ports ?? []).filter((p) => p.name !== port);
      if (!d.assets[asset].ports!.length) delete d.assets[asset].ports;
    }),
    act: "remove",
    what: `port ${port} of asset '${asset}'${plate ? ` (its model's port ${port} as the plate gives it)` : ""}`,
  };
}

// ── disks (ADR-042) ───────────────────────────────────────────────────

export interface DiskSpec {
  serial?: string;
  vendor?: string;
  model?: string;
  wwn?: string;
  size?: string; // bytes, or 960G, 1TB, 4TiB
  kind?: string; // nvme, ssd, hdd, usb
  bus?: string;
  firmware?: string;
  bay?: string;
  description?: string;
}

const gbText = (b: number): string => (b >= 1e12 ? `${(b / 1e12).toFixed(1)} TB` : `${Math.round(b / 1e9)} GB`);
const diskWords = (a: Asset): string => [a.serial ? `serial ${a.serial}` : null, a.disk?.size ? gbText(a.disk.size) : null, a.disk?.kind, a.model].filter(Boolean).join(", ");

// The asset a disk can be in: recorded, no disk, here.
function hostProblem(doc: PositionsDoc, name: string): { key: string } | { refused: string } {
  const hit = assetNamed(doc, name);
  if (!hit) return { refused: `asset ${name} is not recorded (asset-manager asset list)` };
  if (hit.asset.kind === "disk") return { refused: `${hit.key} is a disk: a disk is in a server or another device` };
  if (hit.asset.stage === "ordered" || hit.asset.stage === "disposed") return { refused: `asset ${hit.key} is ${hit.asset.stage}` };
  return { key: hit.key };
}

// A disk's record from a spec's fields, checked; the caller sets the serial.
function diskRecordOf(spec: DiskSpec): DiskRecord | { refused: string } {
  const dk: DiskRecord = {};
  if (spec.kind !== undefined) {
    if (!DISK_KINDS.includes(spec.kind as DiskKind)) return { refused: `--kind is one of ${DISK_KINDS.join(", ")}` };
    dk.kind = spec.kind as DiskKind;
  }
  if (spec.size !== undefined) {
    const n = parseSize(spec.size);
    if (n === null || n <= 0) return { refused: "--size is bytes, or a number with K, M, G, T (1000s) or KiB, MiB, GiB, TiB (1024s)" };
    dk.size = n;
  }
  for (const k of ["wwn", "bus", "firmware"] as const) if (spec[k]) dk[k] = spec[k];
  return dk;
}

// disk add <asset> <name> --serial <s> — a disk in an asset, recorded as the
// next dsk-NN with its by-id name shown, placed in that asset (its bay the
// one given, else the name). A serial an asset records already is refused.
export function addDisk(doc: PositionsDoc, asset: string, name: string, spec: DiskSpec): Result {
  if (!name?.trim()) return { refused: "disk add <asset> <name>: the disk's by-id name (or a label for it)" };
  const host = hostProblem(doc, asset);
  if ("refused" in host) return host;
  if (!spec.serial?.trim()) return { refused: "--serial <serial> is required: a disk is known by its serial" };
  const twin = assetWithSerial(doc, spec.serial);
  if (twin) {
    const m = placementsOf(doc)[twin];
    return { refused: `serial ${spec.serial} is asset ${twin}'s${m ? ` (${placeWhere(m)})` : ""}${assetsOf(doc)[twin].kind === "disk" ? ` — place ${twin} --in ${host.key} moves it` : ""}` };
  }
  const dk = diskRecordOf(spec);
  if ("refused" in dk) return dk;
  const key = nextTag(doc, "disk");
  const a: Asset = { kind: "disk", stage: "placed", displayName: name.trim(), serial: spec.serial.trim() };
  for (const k of ["vendor", "model", "description"] as const) if (spec[k]) a[k] = spec[k];
  if (Object.keys(dk).length) a.disk = dk;
  const m: Placement = { in: host.key, bay: spec.bay?.trim() || name.trim() };
  return {
    doc: withDoc(doc, (d) => {
      d.assets[key] = a;
      d.placements[key] = m;
    }),
    act: "add",
    what: `disk '${key}' (${name.trim()}; ${diskWords(a)}) ${placeWhere(m)}`,
  };
}

const DISK_FIELDS = ["displayName", "description", "vendor", "model", "serial", "assetTag", "wwn", "size", "kind", "bus", "firmware", "bay"];

// disk modify <disk> — its record and its bay; where it is is place --in.
export function modifyDisk(doc: PositionsDoc, name: string, sets: Array<[string, string]>): Result {
  const a = assetsOf(doc)[name];
  if (!a || a.kind !== "disk") return { refused: `${name} is no recorded disk (disk list)` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const x = d.assets[name];
    const dk: DiskRecord = { ...(x.disk ?? {}) };
    for (const [k, v] of sets) {
      if (k === "in") refused = `where it is: place ${name} --in <asset> [--bay <bay>]`;
      else if (!DISK_FIELDS.includes(k)) refused = `disk field '${k}' is not one of ${DISK_FIELDS.join(", ")}`;
      else if (k === "serial") {
        const twin = text(v) === undefined ? null : assetWithSerial(d, v, name);
        if (text(v) === undefined) refused = "a disk keeps its serial: it is what knows it";
        else if (twin) refused = `serial ${v} is asset ${twin}'s`;
        else x.serial = v.trim();
      } else if (k === "bay") {
        const m = d.placements[name];
        if (!m || m.in === undefined) refused = `${name} is in no asset (place ${name} --in <asset> --bay ${v})`;
        else if (text(v) === undefined) delete m.bay;
        else m.bay = v;
      } else if (k === "kind" || k === "size" || k === "wwn" || k === "bus" || k === "firmware") {
        if (text(v) === undefined) delete dk[k];
        else {
          const r = diskRecordOf({ [k]: v });
          if ("refused" in r) refused = r.refused.replace(/^--\w+/, k);
          else Object.assign(dk, r);
        }
      } else {
        const key = k as "displayName" | "description" | "vendor" | "model" | "assetTag";
        if (text(v) === undefined) delete x[key];
        else x[key] = v;
      }
      if (refused) return;
    }
    if (Object.keys(dk).length) x.disk = dk;
    else delete x.disk;
  });
  if (refused) return { refused };
  return { doc: next, act: "modify", what: `disk '${name}': ${setText(sets)}` };
}

// disk remove <disk> — a record made by mistake goes, with its placement; a
// disposed disk's record stays (asset dispose records that it left).
export function removeDisk(doc: PositionsDoc, name: string): Result {
  const a = assetsOf(doc)[name];
  if (!a || a.kind !== "disk") return { refused: `${name} is no recorded disk (disk list)` };
  if (a.stage === "disposed") return { refused: `${name} is disposed: its record stays, read-only, with its history` };
  const m = placementsOf(doc)[name];
  return {
    doc: withDoc(doc, (d) => {
      delete d.assets[name];
      delete d.placements[name];
    }),
    act: "remove",
    what: `disk '${name}' (${diskWords(a)})${m ? `, ${placeWhere(m)}` : ""}`,
  };
}

// place <disk> --in <asset> [--bay <b>] — a disk into an asset's bay: out of
// stock, or out of the asset it was in (the move, ADR-042 D1). The bay is
// the one given, else the one it had in that asset, else its by-id name.
export function placeDisk(doc: PositionsDoc, name: string, into: string, bay?: string): Result {
  const a = assetsOf(doc)[name];
  if (!a || a.kind !== "disk") return { refused: `only a disk is placed in another asset: ${name} is ${a ? `a ${a.kind}` : "no recorded asset"}` };
  if (a.stage === "ordered" || a.stage === "disposed") return { refused: `disk ${name} is ${a.stage}${a.stage === "ordered" ? ` (asset receive ${name} first)` : ""}` };
  const host = hostProblem(doc, into);
  if ("refused" in host) return host;
  const was = placementsOf(doc)[name];
  const same = was?.in === host.key;
  const m: Placement = { in: host.key, bay: bay?.trim() || (same ? was!.bay : undefined) || a.displayName || name };
  if (same && m.bay === was!.bay) return { refused: `${name} is ${placeWhere(was!)} already` };
  return {
    doc: withDoc(doc, (d) => {
      d.placements[name] = m;
      d.assets[name].stage = "placed";
    }),
    act: "place",
    what: `disk '${name}' ${placeWhere(m)}${was?.in !== undefined && !same ? ` (moved out of ${was.in})` : was?.in === undefined ? " (out of stock)" : ""}`,
  };
}

// What a server's CI says of a disk in it (its disks[], ADR-040 D15).
export interface FoundDisk {
  name: string; // by-id
  serial?: string;
  model?: string;
  vendor?: string;
  wwn?: string;
  size?: number;
  type?: string; // ssd, hdd, nvme, usb, unknown
  bus?: string;
}

// disk adopt — every disk an asset's CI lists that no asset records yet, by
// serial, recorded as a disk in that asset; what it skipped and why, as lines.
export function adoptDisks(doc: PositionsDoc, found: { asset: string; disks: FoundDisk[] }[]): { result: Result | null; lines: string[] } {
  const lines: string[] = [];
  let cur = doc;
  const added: string[] = [];
  for (const f of found) {
    const host = hostProblem(cur, f.asset);
    if ("refused" in host) {
      lines.push(`${f.asset}: ${host.refused}`);
      continue;
    }
    for (const x of f.disks) {
      if (!x.serial?.trim()) {
        lines.push(`${host.key}: ${x.name} has no serial: not recorded (disk add ${host.key} ${x.name} --serial <s> by hand)`);
        continue;
      }
      const twin = assetWithSerial(cur, x.serial);
      if (twin) {
        const m = placementsOf(cur)[twin];
        lines.push(`${host.key}: ${x.name} is ${twin} already${m?.in !== undefined && m.in !== host.key ? `, recorded ${placeWhere(m)}: place ${twin} --in ${host.key} if it moved` : !m ? `, in stock: place ${twin} --in ${host.key} if it is there` : ""}`);
        continue;
      }
      const kind = DISK_KINDS.includes(x.type as DiskKind) ? x.type : undefined;
      const r = addDisk(cur, host.key, x.name, { serial: x.serial, model: x.model, vendor: x.vendor, wwn: x.wwn, size: x.size ? String(x.size) : undefined, kind, bus: x.bus });
      if ("refused" in r) {
        lines.push(`${host.key}: ${x.name}: ${r.refused}`);
        continue;
      }
      cur = r.doc;
      added.push(r.what);
    }
  }
  if (!added.length) return { result: null, lines };
  return { result: { doc: cur, act: "record", what: added.length === 1 ? added[0] : `${added.length} disks: ${added.join("; ")}` }, lines };
}

// ── rooms ─────────────────────────────────────────────────────────────

const ROOM_FIELDS = ["displayName", "description", "location"];

export function addRoom(doc: PositionsDoc, name: string, spec: Room, primary?: string | null): Result {
  if (!ROOM_NAME_RE.test(name)) return { refused: `room name '${name}' must match ${ROOM_NAME_RE.source}` };
  if (roomsOf(doc)[name]) return { refused: `room ${name} already exists` };
  const r: Room = {};
  for (const k of ROOM_FIELDS as (keyof Room)[]) if (spec[k]) r[k] = spec[k];
  const named = Object.entries(racksOf(doc)).filter(([, x]) => x.room === name).map(([n]) => n);
  return { doc: withDoc(doc, (d) => void (d.rooms[name] = r)), act: "add", what: `room '${name}'${r.location ?? primary ? ` at ${r.location ?? primary}` : ""}${named.length ? ` (it holds ${named.join(", ")}, which named it already)` : ""}` };
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
  return { doc: next, act: "modify", what: `room '${name}': ${setText(sets)}` };
}

// room delete — only an empty room: no rack names it, nothing stands loose in it.
export function deleteRoom(doc: PositionsDoc, name: string): Result {
  if (!roomsOf(doc)[name]) return { refused: `room ${name} does not exist` };
  const racks = Object.entries(racksOf(doc)).filter(([, r]) => r.room === name).map(([n]) => n);
  const loose = Object.entries(placementsOf(doc)).filter(([, m]) => !m.rack && m.room === name).map(([n]) => n);
  if (racks.length || loose.length) return { refused: `room ${name} still holds ${[...racks.map((r) => `rack ${r}`), ...loose].join(", ")} — move them first` };
  return { doc: withDoc(doc, (d) => void delete d.rooms[name]), act: "delete", what: `room '${name}'` };
}

// ── segments: a link split at a patch panel ───────────────────────────

const sameEnd = (a: { device: string; port: string }, b: { device: string; port: string }) => a.device === b.device && a.port === b.port;

// cable split <device:port> --via <panel:port> — the link on that port (a
// recorded cable, or one the topology sees: seen) becomes two recorded
// segments: the port to the panel port's front, the panel port's rear to the
// far end.
export function splitCable(doc: PositionsDoc, given: CableEnd, viaGiven: CableEnd, seen: { from: CableEnd; to: CableEnd; kind: string }[] | null): Result {
  const end = { ...given, device: placementName(doc, given.device) };
  const via = { ...viaGiven, device: placementName(doc, viaGiven.device) };
  const panel = assetNamed(doc, via.device)?.asset;
  if (!panel || panel.kind !== "patch-panel") return { refused: `${via.device} is no recorded patch panel (asset add ${via.device} --kind patch-panel --ports <n>)` };
  if (!(panel.ports ?? []).some((p) => p.name === via.port) && !panel.model) return { refused: `patch panel ${via.device} has no port ${via.port}` };
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
    act: "split",
    what: `${end.device}:${end.port} — ${far.device}:${far.port} at ${via.device} port ${via.port} (front ← ${end.device}, rear → ${far.device})`,
  };
}

// cable join <end> — undo a split: the two segments at the panel port the
// end names (the panel's port, or a device end of one of its segments) are
// one link again; a recorded cable when it was one, else the topology's.
export function joinCable(doc: PositionsDoc, given: CableEnd): Result {
  const end = { ...given, device: placementName(doc, given.device) };
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
    act: "join",
    what: `${endText(x)} — ${endText(y)} at ${panelEnd.device} port ${panelEnd.port}${keep ? " (recorded as one cable)" : " (the topology's link again)"}`,
  };
}

// ── the site's faceplates ─────────────────────────────────────────────

export interface FaceplateSpec {
  units?: number;
  width?: string;
  ports?: string;
  kind?: string;
  passive?: boolean;
  match?: string[];
  vendor?: string;
  displayName?: string;
  description?: string;
}
const FACEPLATE_FIELDS = ["units", "width", "ports", "kind", "passive", "match", "vendor", "displayName", "description"];

// What is wrong with a site faceplate's fields, before the whole check.
function faceplateProblem(f: SiteFaceplate): string | null {
  if (!Number.isInteger(f.units) || f.units < 1 || f.units > 10) return "units is 1 to 10 rack units";
  if (f.width !== undefined && !MOUNT_WIDTHS.includes(f.width)) return `width is one of ${MOUNT_WIDTHS.join(", ")}`;
  if (f.kind !== undefined && !PLATE_KINDS.includes(f.kind)) return `kind is one of ${PLATE_KINDS.join(", ")}`;
  const spec = parsePortSpec(f.ports ?? "");
  if ("error" in spec) return `--ports: ${spec.error}`;
  const rows = Math.max(...spec.blocks.map((b) => b.rows.length));
  if (rows > 3 * f.units) return `${rows} rows of ports do not fit ${f.units}U: at most ${3 * f.units}`;
  return null;
}

// faceplate add <vendor/model> — a plate the site adds to the catalog. A key
// the shipped catalog has is the site's own plate from then on (validate says so).
export function addFaceplate(doc: PositionsDoc, key: string, spec: FaceplateSpec, catalog: Faceplate[]): Result {
  if (!FACEPLATE_KEY_RE.test(key)) return { refused: `a faceplate is <vendor>/<model>, lower case letters, digits and dashes (the model also . and +): '${key}'` };
  if (faceplatesOf(doc)[key]) return { refused: `the site already has faceplate ${key} (faceplate modify ${key})` };
  if (spec.ports === undefined) return { refused: "--ports <spec> is required: e.g. 24xrj45, or 8xrj45, 2xsfp+" };
  if (spec.units === undefined) return { refused: "--units <n> is required" };
  const f: SiteFaceplate = { kind: (spec.kind ?? "other") as PlateKind, units: spec.units, width: (spec.width ?? "full") as MountWidth, ports: spec.ports.trim() };
  if (spec.passive) f.passive = true;
  if (spec.match?.length) f.match = spec.match;
  for (const k of ["vendor", "displayName", "description"] as const) if (spec[k]) f[k] = spec[k];
  const bad = faceplateProblem(f);
  if (bad) return { refused: `faceplate ${key}: ${bad}` };
  const shipped = catalog.some((x) => x.key === key && !x.site);
  return { doc: withDoc(doc, (d) => void (d.faceplates[key] = f)), act: "add", what: `faceplate '${key}' to the site's catalog (${f.units}U ${f.width}, ${f.ports})${shipped ? ", in place of the shipped plate of that key" : ""}` };
}

export function modifyFaceplate(doc: PositionsDoc, key: string, sets: Array<[string, string]>): Result {
  if (!faceplatesOf(doc)[key]) return { refused: `the site has no faceplate ${key} (faceplate add ${key} …; a shipped plate is changed by adding the site's own of its key)` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const f = d.faceplates[key] as SiteFaceplate & Record<string, unknown>;
    for (const [k, v] of sets) {
      if (!FACEPLATE_FIELDS.includes(k)) refused = `faceplate field '${k}' is not one of ${FACEPLATE_FIELDS.join(", ")}`;
      else if (k === "units") {
        const n = int(v);
        if (n === null) refused = "units is a whole number";
        else f.units = n;
      } else if (k === "passive") {
        if (v === "true") f.passive = true;
        else if (v === "false" || v === "") delete f.passive;
        else refused = "passive is true or false";
      } else if (k === "match") {
        const m = v.split(",").map((x) => x.trim()).filter(Boolean);
        if (m.length) f.match = m;
        else delete f.match;
      } else if (k === "ports") {
        if (text(v) === undefined) refused = "ports cannot be cleared";
        else f.ports = v.trim();
      } else if (text(v) === undefined) delete f[k];
      else f[k] = v;
      if (refused) return;
    }
    const bad = faceplateProblem(f);
    if (bad) refused = `faceplate ${key}: ${bad}`;
  });
  if (refused) return { refused };
  return { doc: next, act: "modify", what: `faceplate '${key}': ${setText(sets)}` };
}

// faceplate delete — only a plate nothing uses; one that replaced a shipped
// plate gives way to it, so nothing that names it is left without one.
export function deleteFaceplate(doc: PositionsDoc, key: string, catalog: Faceplate[]): Result {
  if (!faceplatesOf(doc)[key]) return { refused: `the site has no faceplate ${key}${catalog.some((f) => f.key === key) ? " — a shipped plate is not deleted" : ""}` };
  const shipped = catalog.some((f) => f.key === key && !f.site) || catalog.some((f) => f.key === key && f.overrides);
  if (!shipped) {
    const users = [
      ...Object.entries(placementsOf(doc)).filter(([, m]) => m.faceplate === key).map(([n]) => `placement ${n}`),
      ...Object.entries(assetsOf(doc)).filter(([, x]) => x.model === key).map(([n]) => `asset ${n}`),
      ...cablesOf(doc).flatMap((c) => [c.from, c.to]).filter((e) => e.faceplate === key).map((e) => `the cable end ${e.device}:${e.port}`),
    ];
    if (users.length) return { refused: `faceplate ${key} is used by ${users.join(", ")} — give them another plate first` };
  }
  return { doc: withDoc(doc, (d) => void delete d.faceplates[key]), act: "delete", what: `faceplate '${key}' from the site's catalog${shipped ? " (the shipped plate of that key is drawn again)" : ""}` };
}
