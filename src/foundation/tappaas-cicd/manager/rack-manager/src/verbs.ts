// verbs.ts — what each rack-manager verb does to config/racks.json, as pure
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
  Mount,
  MountWidth,
  NUMBERINGS,
  Numbering,
  RACK_NAME_RE,
  RACK_WIDTHS,
  Rack,
  RackWidth,
  RacksDoc,
  cablesOf,
  endText,
  mountsOf,
  racksOf,
} from "../../../lib/ts/src/racks";

export type Result = { doc: RacksDoc; summary: string } | { refused: string };

const clone = (d: RacksDoc): RacksDoc => JSON.parse(JSON.stringify(d ?? {}));
function withDoc(doc: RacksDoc, fn: (d: Required<Pick<RacksDoc, "racks" | "mounts" | "cables">>) => void): RacksDoc {
  const d = clone(doc);
  d.version = 1;
  d.racks = d.racks ?? {};
  d.mounts = d.mounts ?? {};
  d.cables = d.cables ?? [];
  fn(d as Required<Pick<RacksDoc, "racks" | "mounts" | "cables">>);
  if (d.cables.length === 0) delete d.cables;
  return d;
}

const int = (v: string): number | null => (/^\d+$/.test(v.trim()) ? Number(v.trim()) : null);
const text = (v: string): string | undefined => (v.trim() === "" ? undefined : v);

// ── racks ─────────────────────────────────────────────────────────────

export interface RackSpec {
  units?: number;
  width?: string;
  numbering?: string;
  displayName?: string;
  building?: string;
  room?: string;
  description?: string;
}

// rack add — a new rack, 42U 19in numbered from the bottom unless told.
export function addRack(doc: RacksDoc, name: string, spec: RackSpec): Result {
  if (!RACK_NAME_RE.test(name)) return { refused: `rack name '${name}' must match ${RACK_NAME_RE.source}` };
  if (racksOf(doc)[name]) return { refused: `rack ${name} already exists` };
  const width = (spec.width ?? "19in") as RackWidth;
  if (!RACK_WIDTHS.includes(width)) return { refused: `--width is one of ${RACK_WIDTHS.join(", ")}` };
  const numbering = (spec.numbering ?? "bottom-up") as Numbering;
  if (!NUMBERINGS.includes(numbering)) return { refused: `--numbering is one of ${NUMBERINGS.join(", ")}` };
  const rack: Rack = { units: spec.units ?? 42, width, numbering };
  for (const k of ["displayName", "building", "room", "description"] as const) if (spec[k]) rack[k] = spec[k];
  return { doc: withDoc(doc, (d) => void (d.racks[name] = rack)), summary: `rack ${name} added (${rack.units}U, ${width}, numbered ${numbering})` };
}

const RACK_FIELDS = ["displayName", "units", "width", "numbering", "building", "room", "description"];

// rack modify — any field but the name; units may not shrink below a mount.
export function modifyRack(doc: RacksDoc, name: string, sets: Array<[string, string]>): Result {
  if (!racksOf(doc)[name]) return { refused: `rack ${name} does not exist` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const r = d.racks[name];
    for (const [k, v] of sets) {
      if (k === "name") refused = "a rack's name is its key: add a rack under the new name, move the mounts, delete this one";
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
        const key = k as "displayName" | "building" | "room" | "description";
        if (text(v) === undefined) delete r[key];
        else r[key] = v;
      }
      if (refused) return;
    }
  });
  if (refused) return { refused };
  return { doc: next, summary: `rack ${name}: ${sets.map(([k, v]) => `${k}=${v}`).join(", ")}` };
}

// rack delete — only an empty rack: its mounts are moved or removed first.
export function deleteRack(doc: RacksDoc, name: string): Result {
  if (!racksOf(doc)[name]) return { refused: `rack ${name} does not exist` };
  const held = Object.entries(mountsOf(doc)).filter(([, m]) => m.rack === name).map(([d]) => d);
  if (held.length) return { refused: `rack ${name} still holds ${held.join(", ")} — move them (mount modify <device> --set rack=…) or remove them first` };
  return { doc: withDoc(doc, (d) => void delete d.racks[name]), summary: `rack ${name} deleted` };
}

// ── mounts ────────────────────────────────────────────────────────────

export interface MountSpec {
  rack: string;
  u: number;
  height?: number;
  width?: string;
  slot?: number;
  face?: string;
  faceplate?: string;
  label?: string;
  description?: string;
}

// mount add — a device into a rack. The height defaults to its faceplate's.
export function addMount(doc: RacksDoc, device: string, spec: MountSpec, catalog: Faceplate[]): Result {
  if (!device.trim()) return { refused: "mount add <device>: the device's topology name" };
  if (mountsOf(doc)[device]) return { refused: `${device} is already mounted in ${mountsOf(doc)[device].rack} — mount modify ${device} --set rack=… to move it` };
  if (!racksOf(doc)[spec.rack]) return { refused: `rack ${spec.rack} does not exist (rack add ${spec.rack})` };
  const width = (spec.width ?? "full") as MountWidth;
  if (!MOUNT_WIDTHS.includes(width)) return { refused: `--width is one of ${MOUNT_WIDTHS.join(", ")}` };
  const face = (spec.face ?? "front") as Face;
  if (!FACES.includes(face)) return { refused: `--face is front or rear` };
  const fp = spec.faceplate ? catalog.find((f) => f.key === spec.faceplate) : undefined;
  if (spec.faceplate && !fp) return { refused: `faceplate ${spec.faceplate} is not in the catalog (faceplates list)` };
  const m: Mount = { rack: spec.rack, u: spec.u, height: spec.height ?? fp?.units ?? 1, width, face };
  if (width !== "full") m.slot = spec.slot ?? 0;
  for (const k of ["faceplate", "label", "description"] as const) if (spec[k]) m[k] = spec[k];
  return {
    doc: withDoc(doc, (d) => void (d.mounts[device] = m)),
    summary: `${device} mounted in ${m.rack} at U${m.u}${m.height > 1 ? `-U${m.u + m.height - 1}` : ""}, ${m.face}${width === "full" ? "" : `, ${width} width slot ${m.slot}`}`,
  };
}

const MOUNT_FIELDS = ["rack", "u", "height", "width", "slot", "face", "faceplate", "label", "description"];

// mount modify — a move (rack, u, slot, face) or its plate and label. The
// device is the key: another device is another mount.
export function modifyMount(doc: RacksDoc, device: string, sets: Array<[string, string]>, catalog: Faceplate[]): Result {
  if (!mountsOf(doc)[device]) return { refused: `${device} is not mounted` };
  let refused: string | null = null;
  const next = withDoc(doc, (d) => {
    const m = d.mounts[device];
    for (const [k, v] of sets) {
      if (k === "device") refused = "the device is the mount's key: remove this mount and mount the other device";
      else if (!MOUNT_FIELDS.includes(k)) refused = `mount field '${k}' is not one of ${MOUNT_FIELDS.join(", ")}`;
      else if (k === "rack") {
        if (!d.racks[v]) refused = `rack ${v} does not exist`;
        else m.rack = v;
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
  return { doc: next, summary: `mount ${device}: ${sets.map(([k, v]) => `${k}=${v}`).join(", ")}` };
}

// mount remove — the device leaves the rack (the device itself is untouched).
// The recorded cables that name it go with it only when it is passive
// (nothing else knows it); a topology device keeps its recorded cables.
export function removeMount(doc: RacksDoc, device: string, passive: boolean): Result {
  if (!mountsOf(doc)[device]) return { refused: `${device} is not mounted` };
  const dropped = passive ? cablesOf(doc).filter((c) => c.from.device === device || c.to.device === device).length : 0;
  return {
    doc: withDoc(doc, (d) => {
      delete d.mounts[device];
      if (passive) d.cables = d.cables.filter((c) => c.from.device !== device && c.to.device !== device);
    }),
    summary: `${device} unmounted${dropped ? ` (and its ${dropped} recorded cable(s))` : ""}`,
  };
}

// ── cables ────────────────────────────────────────────────────────────

export function addCable(doc: RacksDoc, from: CableEnd, to: CableEnd, kind: string, label?: string): Result {
  if (!CABLE_KINDS.includes(kind as CableKind)) return { refused: `--kind is one of ${CABLE_KINDS.join(", ")}` };
  const taken = cablesOf(doc).find((c) => [c.from, c.to].some((e) => [from, to].some((x) => e.device === x.device && e.port === x.port)));
  if (taken) return { refused: `${endText(taken.from)} — ${endText(taken.to)} already uses one of these ports: remove it first` };
  const c: Cable = { from, to, kind: kind as CableKind, ...(label ? { label } : {}) };
  return { doc: withDoc(doc, (d) => void d.cables.push(c)), summary: `cable ${endText(from)} — ${endText(to)} (${kind}) recorded` };
}

// cable remove <device:port> — the recorded cable on that port.
export function removeCable(doc: RacksDoc, end: CableEnd): Result {
  const on = (e: CableEnd) => e.device === end.device && e.port === end.port;
  const c = cablesOf(doc).find((x) => on(x.from) || on(x.to));
  if (!c) return { refused: `no recorded cable on ${endText(end)} (a cable the topology sees is not recorded here)` };
  return { doc: withDoc(doc, (d) => void (d.cables = d.cables.filter((x) => x !== d.cables.find((y) => on(y.from) || on(y.to))))), summary: `cable ${endText(c.from)} — ${endText(c.to)} removed` };
}
