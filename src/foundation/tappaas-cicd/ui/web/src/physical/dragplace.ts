// dragplace.ts — a device dragged in the Physical view: from the Unplaced tray
// onto a rack's units or into a room, or a placed one to other units, another
// rack or a room. What it is (its size, where it is now), whether a drop
// target takes it (inside the rack, free, at the device's location), and the
// asset-manager argv the drop runs: `place` for a device placed nowhere,
// `place modify` for a placed one. Pure: the drawing (rack.tsx) and its tests
// use the same answers.

import { JobSummary, PositionsView, RackInfo } from "../types";

export type Width = "full" | "half" | "third";
export const COLS: Record<Width, number> = { full: 1, half: 2, third: 3 };

// The row (0 = the top one) of a unit, as the rack numbers them, and back.
export const rowOf = (r: Pick<RackInfo, "numbering" | "units">, unit: number): number => (r.numbering === "top-down" ? unit - 1 : r.units - unit);
export const unitAt = (r: Pick<RackInfo, "numbering" | "units">, row: number): number => (r.numbering === "top-down" ? row + 1 : r.units - row);

// A placement's share of the rack's width: [from, to] as fractions.
export const spanOf = (m: { width: string; slot: number }): [number, number] => {
  const n = COLS[m.width as Width] ?? 1;
  const s = m.width === "full" ? 0 : m.slot;
  return [s / n, (s + 1) / n];
};

const primaryOf = (v: PositionsView | null | undefined): string | null => v?.locations?.find((l) => l.primary)?.name ?? null;

// Where a device placed nowhere can go: the recorded rooms at its location and
// the racks in them (a rack in no room only at the primary location) — the
// console's backend narrows the Place… form's choices the same way.
export function placesFor(v: PositionsView | null | undefined, device: string): { location: string | null; rooms: string[]; racks: RackInfo[] } {
  const primary = primaryOf(v);
  const location = v?.unplaced.find((x) => x.device === device)?.location ?? primary;
  const rooms = (v?.rooms ?? []).filter((r) => (r.location ?? primary) === location);
  const names = new Set(rooms.map((r) => r.name));
  return { location, rooms: rooms.filter((r) => r.recorded).map((r) => r.name), racks: (v?.racks ?? []).filter((r) => (r.room ? names.has(r.room) : location === primary)) };
}

// The location a rack stands at: its room's, a rack in no room the primary.
export function rackLocation(v: PositionsView, r: RackInfo): string | null {
  const primary = primaryOf(v);
  if (!r.room) return primary;
  return (v.rooms ?? []).find((x) => x.name === r.room)?.location ?? primary;
}

// The size the Place… form starts a device placed nowhere with: a node two
// units, anything else one; an access point a third of the width.
export function prefillSize(kind: string | undefined): { height: number; width: Width } {
  return { height: kind === "node" ? 2 : 1, width: kind === "ap" ? "third" : "full" };
}

// The device being dragged: its size, where it is now (null: placed nowhere),
// its location, and (placed nowhere) the plate the catalog suggests.
export interface Dragged {
  device: string;
  kind: string;
  height: number;
  width: Width;
  slot: number;
  from: { rack: string; u: number } | { room: string } | null;
  location: string | null;
  faceplate: string | null;
}

export function draggedOf(v: PositionsView, device: string): Dragged | null {
  const primary = primaryOf(v);
  for (const r of v.racks) {
    const m = r.placements.find((x) => x.device === device);
    // A rear-facing device is not drawn: Change placement… moves it.
    if (m) return m.face === "front" ? { device, kind: m.kind, height: m.height, width: m.width, slot: m.width === "full" ? 0 : m.slot, from: { rack: r.name, u: m.u }, location: rackLocation(v, r), faceplate: null } : null;
  }
  for (const room of v.rooms ?? []) {
    const m = room.loose.find((x) => x.device === device);
    if (m) return { device, kind: m.kind, height: Math.max(1, m.height), width: m.width, slot: 0, from: { room: room.name }, location: room.location ?? primary, faceplate: null };
  }
  const u = v.unplaced.find((x) => x.device === device);
  if (!u || u.seen) return null; // a seen device is recorded first (Record…)
  return { device, kind: u.kind, ...prefillSize(u.kind), slot: 0, from: null, location: placesFor(v, device).location, faceplate: u.suggestion };
}

// Where the pointer is: a rack's row (the device's top row once the grab
// offset is taken off) and the fraction across its width, or a room's area.
export type DropTarget = { rack: string; row: number; across: number } | { room: string };

export interface Drop {
  ok: boolean;
  same: boolean; // where it already is: nothing to do
  text: string; // what the drop does, or why it cannot
  rack?: string;
  u?: number;
  slot?: number;
  rows?: [number, number]; // the rows to highlight, clipped to the rack
  span?: [number, number];
  room?: string;
  argv?: string[];
}

const RM = "asset-manager";

// The argv a valid drop runs.
export function dropArgv(d: Dragged, to: { rack: string; u: number; slot: number } | { room: string }): string[] {
  if (!d.from) {
    if ("room" in to) return [RM, "place", d.device, "--room", to.room, ...(d.faceplate ? ["--faceplate", d.faceplate] : [])];
    return [RM, "place", d.device, "--rack", to.rack, "--u", String(to.u), "--height", String(d.height), ...(d.width !== "full" ? ["--width", d.width, "--slot", String(to.slot)] : []), ...(d.faceplate ? ["--faceplate", d.faceplate] : [])];
  }
  const out = [RM, "place", "modify", d.device];
  if ("room" in to) return [...out, "--set", `room=${to.room}`];
  const was = "rack" in d.from ? d.from : null;
  if (!was || was.rack !== to.rack) out.push("--set", `rack=${to.rack}`);
  out.push("--set", `u=${to.u}`);
  if (d.width !== "full" && (!was || d.slot !== to.slot)) out.push("--set", `slot=${to.slot}`);
  return out;
}

// Whether a target takes the device, and what dropping it there runs.
export function dropAt(v: PositionsView, d: Dragged, t: DropTarget): Drop {
  if ("room" in t) {
    const room = (v.rooms ?? []).find((x) => x.name === t.room);
    if (!room) return { ok: false, same: false, text: `no room ${t.room}` };
    const name = room.displayName ?? room.name;
    if (d.from && "room" in d.from && d.from.room === room.name) return { ok: false, same: true, text: `already loose in ${name}`, room: room.name };
    if (!room.recorded) return { ok: false, same: false, text: `${name} is not recorded: add the room first`, room: room.name };
    const at = room.location ?? primaryOf(v);
    if (d.location && at !== d.location) return { ok: false, same: false, text: `${name} is at ${at ?? "?"}, the device at ${d.location}`, room: room.name };
    return { ok: true, same: false, text: `loose in ${name}`, room: room.name, argv: dropArgv(d, { room: room.name }) };
  }
  const r = v.racks.find((x) => x.name === t.rack);
  if (!r) return { ok: false, same: false, text: `no rack ${t.rack}` };
  const name = r.displayName ?? r.name;
  const top = t.row;
  const bottom = t.row + d.height - 1;
  const n = COLS[d.width];
  const slot = d.width === "full" ? 0 : Math.max(0, Math.min(n - 1, Math.floor(t.across * n)));
  const span = spanOf({ width: d.width, slot });
  const rows: [number, number] = [Math.max(0, top), Math.min(r.units - 1, bottom)];
  const base = { rack: r.name, slot, rows, span };
  if (top < 0 || bottom >= r.units) return { ok: false, same: false, ...base, text: `does not fit: ${d.height}U past the end of ${name} (${r.units}U)` };
  const u = Math.min(unitAt(r, top), unitAt(r, bottom));
  const units = d.height > 1 ? `U${u}–${u + d.height - 1}` : `U${u}`;
  if (d.from && "rack" in d.from && d.from.rack === r.name && d.from.u === u && d.slot === slot) return { ok: false, same: true, ...base, u, text: `already at ${units} of ${name}` };
  const at = rackLocation(v, r);
  if (d.location && at !== d.location) return { ok: false, same: false, ...base, u, text: `${name} is at ${at ?? "?"}, the device at ${d.location}` };
  const hit = r.placements.find((m) => {
    if (m.device === d.device || m.face !== "front") return false;
    if (m.u + m.height - 1 < u || m.u > u + d.height - 1) return false;
    const [a, b] = spanOf(m);
    return a < span[1] - 1e-9 && span[0] < b - 1e-9;
  });
  if (hit) return { ok: false, same: false, ...base, u, text: `${units} of ${name}: overlaps ${hit.device}` };
  return { ok: true, same: false, ...base, u, text: `${units} of ${name}${d.width !== "full" ? `, column ${slot + 1} of ${n}` : ""}`, argv: dropArgv(d, { rack: r.name, u, slot }) };
}

// Whether the positions show the device where it was dropped.
export function dropLanded(v: PositionsView, device: string, drop: Drop): boolean {
  if (drop.room) return !!(v.rooms ?? []).find((r) => r.name === drop.room)?.loose.some((m) => m.device === device);
  const m = v.racks.find((r) => r.name === drop.rack)?.placements.find((x) => x.device === device);
  return !!m && m.u === drop.u && (m.width === "full" || m.slot === drop.slot);
}

// Whether a drop is still on its way: its job has not ended, or it ended well
// and the positions read since do not show it yet. A job that failed, and a
// read after its end that has the device elsewhere, end it.
export function dropPending(v: PositionsView, device: string, drop: Drop, job: Pick<JobSummary, "state" | "exit" | "ended" | "previewPhase" | "cancelled" | "interrupted"> | null, read: { at: string | null; error: string | null }): boolean {
  if (!job || job.state === "queued" || job.state === "running") return true;
  if (job.state !== "done" || job.exit !== 0 || job.previewPhase?.stopped || job.cancelled || job.interrupted) return false;
  if (dropLanded(v, device, drop) || read.error) return false;
  return !(read.at && job.ended && Date.parse(read.at) >= Date.parse(job.ended));
}
