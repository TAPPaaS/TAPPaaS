// layout.ts — what the Physical, Device and Storage views select (the side
// panel shows it), a switch port's far end in words, and where the Physical
// view draws things: the locations one above the other, the primary first,
// each room as big as what it holds (the rooms with racks side by side, the
// small ones in columns beside them), their racks and plates, and which rack
// unit or room a point of the drawing falls on. Pure: the drawing (rack.tsx) and its tests use the same
// numbers.

import { LocationInfo, PlacementInfo, PositionsView, RackInfo, RoomInfo, TopoOutside, TopoPort } from "../types";
import { PortAt } from "./cableroute";
import { DropTarget, rowOf, spanOf } from "./dragplace";
import { Placed, portCells } from "./platelayout";

export type Sel =
  | { kind: "node"; id: string }
  | { kind: "port"; id: string; switch: string }
  | { kind: "switch"; id: string }
  | { kind: "lag"; id: string; switch: string }
  | { kind: "ap"; id: string }
  | { kind: "outside"; id: string }
  | { kind: "guest"; id: string }
  | { kind: "isp"; id: string }
  | { kind: "firewall"; id: string }
  | { kind: "rack"; id: string }
  | { kind: "room"; id: string }
  | { kind: "mount"; id: string }
  | { kind: "panelport"; id: string; panel: string } // a free patch panel port
  | { kind: "disk"; id: string; node: string } // id: the device
  | { kind: "pool"; id: string; node: string }
  | { kind: "link"; id: string; port?: string }; // id: devicegraph.ts linkId; port: the end clicked, "<device>:<port>"

export type Pick = (s: Sel) => void;

export function portLabel(p: TopoPort): string {
  if (p.parked) return `parked · ${p.zones[0] ?? "?"}`;
  if (!p.target) return p.description ?? "—";
  if (p.target.kind === "isp") return p.description ?? "ISP hand-off";
  const nm = p.target.name ?? "?";
  return `${nm}${p.target.port ? ` ${p.target.port}` : ""}${p.role === "node-wan" ? " (wan)" : ""}`;
}

// Geometry: one rack unit, the rails with their numbers, a 19in and a 10in
// interior (wider than true scale, so a 12-port plate stays legible); from a
// location's top to its rooms' (locHead), from a room's top to its racks'
// (rackHead) or, in a room with none, its plates' (roomHead).
export const R = { u: 30, rail: 24, w19: 440, w10: 240, gap: 150, margin: 8, outsideW: 230, roomPad: 18, looseGap: 18, locPad: 14, locHead: 38, locGap: 18, rackHead: 76, roomHead: 34, roomGap: 40, stackGap: 14, roomMinW: 160, roomMinH: 64, nowhereW: 240 };

export const inner = (r: RackInfo) => (r.width === "10in" ? R.w10 : R.w19);

export interface RackLayout {
  width: number;
  height: number;
  fitH: number; // the height "fit" shows: the first location; the others are scrolled to
  racks: { r: RackInfo; x: number; y: number }[];
  // Each location an area around its rooms and, in a column after them, what
  // is at it placed nowhere (with no room: somewhere there); each room an
  // area: its racks and the devices loose in it.
  locations: { name: string; title: string; sub: string; primary: boolean; x: number; y: number; w: number; h: number; roomless: boolean; nowhereX: number; nowhereY: number; nowhere: { device: string; label: string; sel: Sel }[] }[];
  rooms: { name: string; title: string; sub: string; recorded: boolean; x: number; y: number; w: number; h: number }[];
  placed: Placed[];
  ports: Map<string, PortAt>;
}

export const portKey = (device: string, port: string) => `${device}\u0000${port}`;

// What a click on a plate or a port selects: the device's own side card (a
// node, a switch or one of its ports, an access point), else the placed device's.
export function selOf(kind: Placed["kind"], device: string, port?: string): Sel {
  if (kind === "switch") return port ? { kind: "port", id: port, switch: device } : { kind: "switch", id: device };
  if (kind === "node") return { kind: "node", id: device };
  if (kind === "ap") return { kind: "ap", id: device };
  return { kind: "mount", id: device };
}

// What stands at a location placed nowhere: its unplaced devices, then the
// backup buddies and satellites the topology has there (a satellite is also a
// machine of the site, so it is listed once).
function nowhereAt(v: PositionsView, loc: { name: string; unplaced: string[] }, outside: TopoOutside[]): RackLayout["locations"][number]["nowhere"] {
  const kindOf = (device: string): Placed["kind"] => v.unplaced.find((u) => u.device === device)?.kind ?? "device";
  const out = loc.unplaced.map((device) => ({ device, label: device, sel: selOf(kindOf(device), device) }));
  for (const o of outside) if (o.at === loc.name && !loc.unplaced.includes(o.name)) out.push({ device: o.name, label: `${o.name} (${o.kind === "buddy" ? "backup buddy" : "satellite"})`, sel: { kind: "outside", id: o.name } });
  return out;
}

// A location's heading: its name, and its address with "the primary location"
// on the primary; the drawing flows the two as one line.
export function locationHeading(loc: { name: string; displayName: string | null; primary: boolean; place: LocationInfo["place"] }): { title: string; sub: string } {
  const place = [loc.place?.address, loc.place?.city, loc.place?.country].filter(Boolean).join(", ");
  return { title: loc.displayName ?? loc.name, sub: [place, loc.primary ? "the primary location" : ""].filter(Boolean).join(" · ") };
}

const looseW = (m: PlacementInfo) => (m.width === "full" ? 320 : m.width === "half" ? 180 : 130);

const looseH = (ms: PlacementInfo[]) => ms.reduce((h, m) => h + Math.max(1, m.height) * R.u + R.looseGap, ms.length ? -R.looseGap : 0);

// A room's size, from what it holds: its racks side by side, then the column
// of its loose plates; as wide as its title at least.
export function roomSize(room: RoomInfo, racks: RackInfo[]): { w: number; h: number; head: number } {
  const looseWidth = Math.max(0, ...room.loose.map(looseW));
  const widths = [...racks.map((r) => inner(r) + 2 * R.rail), ...(looseWidth ? [looseWidth] : [])];
  const head = racks.length ? R.rackHead : R.roomHead + (room.recorded ? 0 : 14);
  const h = head + Math.max(looseH(room.loose), ...racks.map((r) => r.units * R.u), 0) + R.roomPad;
  const w = widths.reduce((a, b) => a + b, 0) + R.gap * Math.max(0, widths.length - 1) + 2 * R.roomPad;
  return { w: Math.max(w, R.roomMinW, 24 + (room.displayName ?? room.name).length * 9), h: Math.max(h, R.roomMinH), head };
}

// Where a location's rooms stand, from its top left: the rooms with racks side
// by side, the others after them in columns no taller than that row (each at
// least one room; with no rack room, each its own column). In the given order
// within each group.
export function arrangeRooms(rooms: { w: number; h: number; racks: boolean }[]): { at: { x: number; y: number }[]; w: number; h: number } {
  const at = rooms.map(() => ({ x: 0, y: 0 }));
  let x = 0;
  let rowH = 0;
  rooms.forEach((m, i) => {
    if (!m.racks) return;
    at[i] = { x, y: 0 };
    x += m.w + R.roomGap;
    rowH = Math.max(rowH, m.h);
  });
  let h = rowH;
  let y = 0;
  let colW = 0;
  rooms.forEach((m, i) => {
    if (m.racks) return;
    if (y > 0 && y + m.h > rowH) {
      x += colW + R.roomGap;
      y = 0;
      colW = 0;
    }
    at[i] = { x, y };
    h = Math.max(h, y + m.h);
    y += m.h + R.stackGap;
    colW = Math.max(colW, m.w);
  });
  return { at, w: Math.max(0, x + colW - (colW ? 0 : R.roomGap)), h };
}

export function layoutRacks(v: PositionsView, outside: TopoOutside[] = []): RackLayout {
  const placed: Placed[] = [];
  const ports: RackLayout["ports"] = new Map();
  let left = R.margin;
  let outsideBottom = 0;
  // A device a cable record places stands left of the locations.
  if (v.outside.length) {
    let y = R.locHead + R.rackHead + 12;
    for (const o of v.outside) {
      const h = (o.plate?.units ?? 1) * R.u + 6;
      placed.push({ device: o.device, kind: "outside", plate: o.plate, box: { x: left, y, w: R.outsideW, h }, up: null, title: o.device, sub: o.faceplate ?? "placed by a cable record", rack: null });
      outsideBottom = y + h;
      y += h + 26;
    }
    left += R.outsideW + R.gap * 0.7;
  }
  const racks: RackLayout["racks"] = [];
  const rooms: RackLayout["rooms"] = [];
  // A rack at (x, y): its width; its height is its units.
  const drawRack = (r: RackInfo, x: number, y: number): number => {
    racks.push({ r, x, y });
    const iw = inner(r);
    for (const m of r.placements) {
      if (m.face !== "front") continue;
      const [a, b] = spanOf(m);
      const top = rowOf(r, m.u + m.height - 1);
      placed.push({
        device: m.device,
        kind: m.kind,
        plate: m.plate,
        box: { x: x + R.rail + iw * a + 1, y: y + Math.min(top, rowOf(r, m.u)) * R.u + 1, w: iw * (b - a) - 2, h: m.height * R.u - 2 },
        up: m.up,
        title: m.label ? `${m.device} · ${m.label}` : m.device,
        sub: m.plate ? `${m.plate.vendor} ${m.plate.model}${m.suggested ? " (suggested)" : ""}` : "no faceplate",
        rack: r.name,
      });
    }
    return iw + 2 * R.rail;
  };
  // The devices loose in a room: a column of faceplates at (x, y).
  const drawLoose = (ms: PlacementInfo[], x: number, y0: number): void => {
    let y = y0;
    for (const m of ms) {
      const h = Math.max(1, m.height) * R.u;
      placed.push({ device: m.device, kind: m.kind, plate: m.plate, box: { x, y, w: looseW(m), h }, up: m.up, title: m.label ? `${m.device} · ${m.label}` : m.device, sub: m.plate ? `${m.plate.vendor} ${m.plate.model}` : "no faceplate", rack: null });
      y += h + R.looseGap;
    }
  };
  // Location by location, one above the other (the primary first), room by
  // room (a rack in no room below them, in no area).
  const locations: RackLayout["locations"] = [];
  const roomed = new Set((v.rooms ?? []).flatMap((r) => r.racks));
  const groups = v.locations?.length ? v.locations : [{ name: "", displayName: null, kind: "site" as const, primary: true, place: null, rooms: (v.rooms ?? []).map((r) => r.name), unplaced: [] }];
  let y = 2;
  let right = left;
  for (const loc of groups) {
    const inLoc = (v.rooms ?? []).filter((r) => loc.rooms.includes(r.name));
    const nowhere = loc.name ? nowhereAt(v, loc, outside) : [];
    if (!loc.name && !inLoc.length) continue;
    const roomY = y + R.locHead;
    const held = inLoc.map((room) => room.racks.map((name) => v.racks.find((c) => c.name === name)).filter((r): r is RackInfo => !!r));
    const sizes = inLoc.map((room, i) => ({ ...roomSize(room, held[i]), racks: held[i].length > 0 }));
    const arranged = arrangeRooms(sizes);
    inLoc.forEach((room, i) => {
      const { w, h, head } = sizes[i];
      const rx = left + R.locPad + arranged.at[i].x;
      const ry = roomY + arranged.at[i].y;
      let cx = rx + R.roomPad;
      for (const r of held[i]) cx += drawRack(r, cx, ry + head) + R.gap;
      drawLoose(room.loose, cx, ry + head);
      rooms.push({ name: room.name, title: room.displayName ?? room.name, sub: room.recorded ? "" : "not recorded", recorded: room.recorded, x: rx, y: ry, w, h });
    });
    // After the rooms (or in their place): what is here placed nowhere.
    let x = left + R.locPad + (arranged.w ? arranged.w + R.roomGap : 0);
    let bottom = roomY + arranged.h;
    const nowhereX = x;
    if (!inLoc.length || nowhere.length) {
      x += R.nowhereW + R.roomGap;
      bottom = Math.max(bottom, roomY + 34 + nowhere.length * 20);
    }
    let w = x - R.roomGap + R.locPad - left;
    if (loc.name) {
      const { title, sub } = locationHeading(loc);
      // As wide as its heading at least: the title, then its address.
      w = Math.max(w, 28 + title.length * 11 + 22 + sub.length * 6);
      locations.push({ name: loc.name, title, sub, primary: loc.primary, x: left, y, w, h: bottom + R.locPad - y, roomless: !inLoc.length, nowhereX, nowhereY: roomY, nowhere });
    }
    right = Math.max(right, left + w);
    y = bottom + R.locPad + R.locGap;
  }
  // One width for all, so the stack reads as one column.
  for (const l of locations) l.w = right - left;
  const fitH = locations.length ? locations[0].y + locations[0].h + 4 : 0;
  const loose = v.racks.filter((r) => !roomed.has(r.name));
  if (loose.length) {
    let x = left + R.locPad;
    const top = y + 40;
    for (const r of loose) {
      x += drawRack(r, x, top) + R.gap;
      y = Math.max(y, top + r.units * R.u + R.roomPad);
    }
    right = Math.max(right, x - R.gap + R.locPad);
  }
  for (const p of placed) {
    for (const c of portCells(p)) ports.set(portKey(p.device, c.port.id), { x: c.box.x + c.box.w / 2, y: c.box.y + c.box.h / 2, h: c.box.h, plateY: p.box.y, plateH: p.box.h, rack: p.rack });
  }
  const height = Math.max(y, outsideBottom + R.locGap, 200);
  return { width: Math.max(right + R.margin, 400), height, fitH: Math.max(fitH, outsideBottom + R.locGap) || height, locations, racks, rooms, placed, ports };
}

// Where a point of the drawing falls for a drop: a rack's row and the fraction
// across its interior (its rails count as its edge), else a room's area.
export function dropTargetAt(L: RackLayout, x: number, y: number, grab: number): DropTarget | null {
  for (const { r, x: rx, y: ry } of L.racks) {
    const iw = inner(r);
    if (x < rx || x > rx + iw + 2 * R.rail || y < ry || y > ry + r.units * R.u) continue;
    const row = Math.min(r.units - 1, Math.floor((y - ry) / R.u));
    return { rack: r.name, row: row - grab, across: Math.max(0, Math.min(0.999, (x - rx - R.rail) / iw)) };
  }
  const room = L.rooms.find((m) => x >= m.x && x <= m.x + m.w && y >= m.y && y <= m.y + m.h);
  return room ? { room: room.name } : null;
}
