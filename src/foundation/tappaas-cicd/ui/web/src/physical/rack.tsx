// rack.tsx — the Site page's Physical view: the site's locations, each with its
// rooms, each room with its racks and the devices loose in it; each rack drawn
// as a frame with its unit rows numbered as the rack numbers them, each placed
// device as its faceplate at
// its units and width with its port grid, the ports' live state from the
// topology (link up or down, LAG), and the cables port to port in the zone
// colours of the Device view, labelled on hover, a click opening the cable's
// link in the side panel (the same panel the Device view opens). A device
// only a cable record places (the ISP's modem) stands left of the racks.
// Every location of the site is drawn, the primary first, its heading a link
// to its record on the Site page with its address: after its rooms, the
// devices that are at it and placed nowhere (with no room, somewhere there),
// and a backup buddy or a satellite that is there.
// Everything comes from `network-manager topology` .positions; nothing is
// placed by hand here.

import { ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { zoneColor } from "../colors";
import { PlatePort, RackCable, RackInfo, PlacementInfo, PositionsView, TopoOutside, Topology } from "../types";
import { navigate } from "../ui";
import { locationHref } from "../locations";
import { Sel } from "./layout";
import { isPatchPanel, linkId, panelPortSel } from "./devicegraph";
import { Box, Placed, nameArea, portCells } from "./platelayout";
import { PortAt, routeCables } from "./cableroute";

// Geometry: one rack unit, the rails with their numbers, a 19in and a 10in
// interior (wider than true scale, so a 12-port plate stays legible).
export const R = { u: 30, rail: 24, w19: 440, w10: 240, gap: 150, top: 116, margin: 24, outsideW: 230, bottom: 40, roomPad: 18, looseGap: 18, locPad: 14, roomY: 40, nowhereW: 240 };

const inner = (r: RackInfo) => (r.width === "10in" ? R.w10 : R.w19);
const COLS: Record<string, number> = { full: 1, half: 2, third: 3 };
const span = (m: { width: string; slot: number }): [number, number] => {
  const n = COLS[m.width] ?? 1;
  const s = m.width === "full" ? 0 : m.slot;
  return [s / n, (s + 1) / n];
};
// The row (0 = the top one) of a unit, as the rack numbers them.
const rowOf = (r: RackInfo, unit: number) => (r.numbering === "top-down" ? unit - 1 : r.units - unit);
const unitAt = (r: RackInfo, row: number) => (r.numbering === "top-down" ? row + 1 : r.units - row);

export type { Box, Placed } from "./platelayout";

export interface RackLayout {
  width: number;
  height: number;
  racks: { r: RackInfo; x: number }[];
  // Each location an area around its rooms and, in a column after them, what
  // is at it placed nowhere (with no room: somewhere there); each room an
  // area: its racks and the devices loose in it.
  locations: { name: string; title: string; sub: string; primary: boolean; x: number; y: number; w: number; h: number; roomless: boolean; nowhereX: number; nowhere: { device: string; label: string; sel: Sel }[] }[];
  rooms: { name: string; title: string; sub: string; recorded: boolean; x: number; y: number; w: number; h: number }[];
  placed: Placed[];
  ports: Map<string, PortAt>;
}

const key = (device: string, port: string) => `${device}\u0000${port}`;

// What stands at a location placed nowhere: its unplaced devices, then the
// backup buddies and satellites the topology has there (a satellite is also a
// machine of the site, so it is listed once).
function nowhereAt(v: PositionsView, loc: { name: string; unplaced: string[] }, outside: TopoOutside[]): RackLayout["locations"][number]["nowhere"] {
  const kindOf = (device: string): Placed["kind"] => v.unplaced.find((u) => u.device === device)?.kind ?? "device";
  const out = loc.unplaced.map((device) => ({ device, label: device, sel: selOf(kindOf(device), device) }));
  for (const o of outside) if (o.at === loc.name && !loc.unplaced.includes(o.name)) out.push({ device: o.name, label: `${o.name} (${o.kind === "buddy" ? "backup buddy" : "satellite"})`, sel: { kind: "outside", id: o.name } });
  return out;
}

export function layoutRacks(v: PositionsView, outside: TopoOutside[] = []): RackLayout {
  const placed: Placed[] = [];
  const ports: RackLayout["ports"] = new Map();
  let x = R.margin;
  // A device a cable record places stands left of the racks.
  if (v.outside.length) {
    let y = R.top + 10;
    for (const o of v.outside) {
      const h = (o.plate?.units ?? 1) * R.u + 6;
      placed.push({ device: o.device, kind: "outside", plate: o.plate, box: { x, y, w: R.outsideW, h }, up: null, title: o.device, sub: o.faceplate ?? "placed by a cable record", rack: null });
      y += h + 26;
    }
    x += R.outsideW + R.gap * 0.7;
  }
  const racks: RackLayout["racks"] = [];
  const rooms: RackLayout["rooms"] = [];
  let maxH = 0;
  const drawRack = (r: RackInfo) => {
    racks.push({ r, x });
    const iw = inner(r);
    for (const m of r.placements) {
      if (m.face !== "front") continue;
      const [a, b] = span(m);
      const top = rowOf(r, m.u + m.height - 1);
      placed.push({
        device: m.device,
        kind: m.kind,
        plate: m.plate,
        box: { x: x + R.rail + iw * a + 1, y: R.top + Math.min(top, rowOf(r, m.u)) * R.u + 1, w: iw * (b - a) - 2, h: m.height * R.u - 2 },
        up: m.up,
        title: m.label ? `${m.device} · ${m.label}` : m.device,
        sub: m.plate ? `${m.plate.vendor} ${m.plate.model}${m.suggested ? " (suggested)" : ""}` : "no faceplate",
        rack: r.name,
      });
    }
    maxH = Math.max(maxH, r.units * R.u);
    x += iw + 2 * R.rail + R.gap;
  };
  // The devices loose in a room: a column of faceplates beside its racks.
  const drawLoose = (ms: PlacementInfo[]) => {
    if (!ms.length) return;
    let y = R.top;
    const colW = Math.max(...ms.map((m) => (m.width === "full" ? 320 : m.width === "half" ? 180 : 130)));
    for (const m of ms) {
      const w = m.width === "full" ? 320 : m.width === "half" ? 180 : 130;
      const h = Math.max(1, m.height) * R.u;
      placed.push({ device: m.device, kind: m.kind, plate: m.plate, box: { x, y, w, h }, up: m.up, title: m.label ? `${m.device} · ${m.label}` : m.device, sub: m.plate ? `${m.plate.vendor} ${m.plate.model}` : "no faceplate", rack: null });
      y += h + R.looseGap;
    }
    maxH = Math.max(maxH, y - R.top);
    x += colW + R.gap;
  };
  // Location by location (the primary first), room by room (a rack in no
  // room after them, in no area).
  const locations: RackLayout["locations"] = [];
  const roomed = new Set((v.rooms ?? []).flatMap((r) => r.racks));
  const groups = v.locations?.length ? v.locations : [{ name: "", displayName: null, kind: "site" as const, primary: true, place: null, rooms: (v.rooms ?? []).map((r) => r.name), unplaced: [] }];
  for (const loc of groups) {
    const inLoc = (v.rooms ?? []).filter((r) => loc.rooms.includes(r.name));
    const nowhere = loc.name ? nowhereAt(v, loc, outside) : [];
    if (!loc.name && !inLoc.length) continue;
    const lx0 = x;
    for (const room of inLoc) {
      const x0 = x;
      for (const name of room.racks) {
        const r = v.racks.find((y) => y.name === name);
        if (r) drawRack(r);
      }
      drawLoose(room.loose);
      if (x === x0) x += 200; // an empty room still shows
      rooms.push({ name: room.name, title: room.displayName ?? room.name, sub: room.recorded ? "" : "not recorded", recorded: room.recorded, x: x0 - R.roomPad, y: R.roomY, w: x - R.gap - x0 + 2 * R.roomPad, h: 0 });
      x += 30;
    }
    // After the rooms (or in their place): what is here placed nowhere.
    const nowhereX = inLoc.length ? x - 30 - R.gap / 2 : x;
    if (!inLoc.length || nowhere.length) x = nowhereX + R.nowhereW + R.gap;
    if (loc.name) {
      const place = [loc.place?.address, loc.place?.city, loc.place?.country].filter(Boolean).join(", ");
      const title = loc.displayName ?? loc.name;
      const sub = [place, loc.primary ? "the primary location" : loc.kind === "remote" ? "another site's" : ""].filter(Boolean).join(" · ");
      // As wide as its heading at least: the title, then its address.
      const head = 28 + title.length * 9.5 + 10 + sub.length * 5.6;
      let w = x - (inLoc.length && !nowhere.length ? R.gap + 30 : R.gap) - lx0 + 2 * (R.roomPad + R.locPad);
      if (head > w) {
        x += head - w;
        w = head;
      }
      locations.push({
        name: loc.name,
        title,
        sub,
        primary: loc.primary,
        x: lx0 - R.roomPad - R.locPad,
        y: 2,
        w,
        h: 0,
        roomless: !inLoc.length,
        nowhereX,
        nowhere,
      });
    }
    x += 40;
  }
  for (const r of v.racks) if (!roomed.has(r.name)) drawRack(r);
  for (const p of placed) {
    for (const c of portCells(p)) ports.set(key(p.device, c.port.id), { x: c.box.x + c.box.w / 2, y: c.box.y + c.box.h / 2, h: c.box.h, plateY: p.box.y, plateH: p.box.h, rack: p.rack });
  }
  const outsideH = placed.filter((p) => p.kind === "outside").reduce((h, p) => Math.max(h, p.box.y + p.box.h), 0);
  const nowhereH = Math.max(0, ...locations.map((l) => R.roomY + 40 + l.nowhere.length * 20));
  const height = Math.max(R.top + maxH + R.bottom, outsideH + R.bottom, nowhereH + R.bottom);
  for (const room of rooms) room.h = height - room.y - 16;
  for (const l of locations) l.h = height - l.y - 4;
  return { width: Math.max(x - R.gap + R.margin + 160, 400), height, locations, racks, rooms, placed, ports };
}

// A trunk's colour by what it joins, bright enough to tell apart on the
// light canvas (CABLE_KINDS is also the legend's).
export const CABLE_KINDS: { kind: string; stroke: string; label: string }[] = [
  { kind: "lan", stroke: "#16a34a", label: "node trunk" },
  { kind: "uplink", stroke: "#f97316", label: "switch uplink" },
  { kind: "peer-link", stroke: "#2563eb", label: "peer link" },
  { kind: "ap", stroke: "#a21caf", label: "access point" },
  { kind: "device", stroke: "#e11d48", label: "device" },
  { kind: "patch", stroke: "#0891b2", label: "patch" },
];
export const CABLE_DOWN = "#dc2626";

// A cable's colour and dash: a wan link dashed in the wan colour, an access
// link in its zone's colour, a trunk in its kind's colour, a link that is
// down red and dotted; thin, a LAG member a little thicker.
export function cableStyle(c: RackCable, t: Topology): { stroke: string; width: number; dash?: string } {
  const width = c.lag ? 2.6 : 2;
  if (c.up === false) return { stroke: CABLE_DOWN, width, dash: "2 3" };
  if (c.kind === "wan" || (c.zones.length === 1 && c.zones[0] === t.site.wan.zone)) return { stroke: zoneColor({ name: "wan" }), width, dash: "6 4" };
  if (c.zones.length === 1) {
    const z = t.zones.find((x) => x.name === c.zones[0]);
    return { stroke: zoneColor(z ?? { name: c.zones[0] }), width, dash: c.source === "recorded" ? "2 3" : undefined };
  }
  if (c.kind === "power") return { stroke: "#b91c1c", width: 2, dash: "1 3" };
  return { stroke: CABLE_KINDS.find((k) => k.kind === c.kind)?.stroke ?? "#475569", width, dash: c.source === "recorded" ? "2 3" : undefined };
}

// The cable a click on <device>:<port> selected.
const tagged = (c: RackCable, port: string): boolean => [c.from, c.to, ...(c.via ?? [])].some((e) => `${e.device}:${e.port}` === port);

// A selected cable's label, halfway along it: what it is and its two ports.
export function cableTag(c: RackCable, w: { from: { device: string; port: string }; to: { device: string; port: string } }): string {
  const what = c.zones.length === 1 && c.kind !== "wan" ? c.zones[0] : CABLE_KINDS.find((k) => k.kind === c.kind)?.label ?? c.kind;
  return `${what}${c.lag ? " (LAG)" : ""} ${w.from.device}:${w.from.port} ↔ ${w.to.device}:${w.to.port}`;
}

export function cableText(c: RackCable): string {
  const st = c.up === true ? "up" : c.up === false ? "down" : "state unknown";
  return `${c.from.device}:${c.from.port} — ${c.to.device}:${c.to.port} · ${c.kind}${c.lag ? ` · LAG ${c.lag}` : ""} · ${st}${c.zones.length ? ` · ${c.zones.join(", ")}` : ""}${c.source === "recorded" ? " · recorded" : ""}${c.via?.length ? ` · via ${c.via.map((v) => `${v.device}:${v.port}`).join(", ")}` : ""}${c.label ? ` · ${c.label}` : ""}`;
}

function portFill(p: PlatePort): string {
  if (p.disabled) return "#e5e7eb";
  if (p.up === true) return "#2f9e44";
  if (p.up === false) return "#475569";
  return "#cbd5e1";
}

function portTitle(p: PlatePort): string {
  const st = p.disabled ? "disabled" : p.up === true ? "link up" : p.up === false ? "no link" : "state unknown";
  return `${p.name}${p.name !== p.id ? ` (${p.id})` : ""} · ${p.kind} · ${st}${p.lag ? ` · LAG ${p.lag}` : ""}${p.zones.length ? ` · ${p.zones.join(", ")}` : ""}`;
}

function Port({ c, selected, cabled, rear, onClick }: { c: { port: PlatePort; box: Box }; selected: boolean; cabled: boolean; rear: boolean; onClick: () => void }) {
  const { port: p, box: b } = c;
  const sfp = p.kind === "sfp+" || p.kind === "sfp28";
  return (
    <g className="rack-port" onClick={(e) => (e.stopPropagation(), onClick())}>
      <title>{portTitle(p)}</title>
      {p.kind === "power" ? (
        <circle cx={b.x + b.w / 2} cy={b.y + b.h / 2} r={Math.min(b.w, b.h) / 2} fill="#1f2937" stroke="#94a3b8" />
      ) : (
        <rect x={b.x} y={b.y} width={b.w} height={b.h} rx={sfp ? 1 : 1.5} fill={sfp ? "#111827" : "#0f172a"} stroke={p.lag ? "#7c3aed" : "#64748b"} strokeWidth={p.lag ? 1.6 : 0.8} />
      )}
      {p.kind !== "power" ? <rect x={b.x + 2} y={b.y + (sfp ? 2 : 3)} width={b.w - 4} height={b.h - (sfp ? 4 : 5)} rx={1} fill={portFill(p)} opacity={p.kind === "console" ? 0.6 : 1} /> : null}
      {p.kind === "poe" ? <rect x={b.x + 2} y={b.y + 1} width={b.w - 4} height={1.4} fill="#facc15" /> : null}
      {cabled ? <rect x={b.x} y={b.y + b.h + 1.2} width={b.w} height={1.8} rx={0.9} fill="#38bdf8" /> : null}
      {rear ? <rect x={b.x} y={b.y - 3} width={b.w} height={1.8} rx={0.9} fill="#c084fc"><title>its rear is cabled</title></rect> : null}
      {selected ? <rect x={b.x - 2} y={b.y - 2} width={b.w + 4} height={b.h + 4} rx={2} fill="none" stroke="#f59e0b" strokeWidth={2.2} /> : null}
    </g>
  );
}

// What a click on a plate or a port selects: the device's own side card (a
// node, a switch or one of its ports, an access point), else the placed device's.
export function selOf(kind: Placed["kind"], device: string, port?: string): Sel {
  if (kind === "switch") return port ? { kind: "port", id: port, switch: device } : { kind: "switch", id: device };
  if (kind === "node") return { kind: "node", id: device };
  if (kind === "ap") return { kind: "ap", id: device };
  return { kind: "mount", id: device };
}

const isSel = (s: Sel | null, kind: Placed["kind"], device: string): boolean =>
  !!s && (((s.kind === "node" || s.kind === "switch" || s.kind === "ap" || s.kind === "mount") && s.id === device) || (s.kind === "port" && s.switch === device && kind === "switch") || (s.kind === "panelport" && s.panel === device));

// One faceplate: its name and model on the left, its LED, its port grid with
// each port's live state, the cabled ones underlined, the selected one ringed.
// The rack draws every placed device with it; the side panel draws the selected one.
export function PlateSvg({ p, on, portOn, cabled, rear, onPlate, onPort }: { p: Placed; on: boolean; portOn: (id: string) => boolean; cabled?: Set<string>; rear?: Set<string>; onPlate: () => void; onPort: (id: string) => void }) {
  const cells = portCells(p);
  const led = p.up === true ? "#2f9e44" : p.up === false ? "#d64545" : "#9aa4b2";
  const na = nameArea(p.plate);
  const onTop = na.at === "top";
  // The name's place: left of the ports, right of them, or a strip along the top.
  const nx = p.box.x + p.box.w * na.from;
  const labelW = na.at === "left" && !p.plate?.blocks?.length ? Math.min(124, p.box.w * 0.34) : onTop ? p.box.w - 40 : p.box.w * (na.to - na.from) - 24;
  const tight = p.box.h < 34 || onTop;
  const dark = p.kind === "outside" || p.plate?.passive;
  return (
    <g className="rack-plate" onClick={(e) => (e.stopPropagation(), onPlate())}>
      <title>{`${p.title} — ${p.sub}`}</title>
      <rect x={p.box.x} y={p.box.y} width={p.box.w} height={p.box.h} rx={3} fill={p.kind === "outside" ? "#f1f5f9" : p.plate?.passive ? "#e2e8f0" : "#1e293b"} stroke={on ? "#3b6fd4" : p.kind === "outside" ? "#94a3b8" : "#0f172a"} strokeWidth={on ? 2.5 : 1} strokeDasharray={p.kind === "outside" ? "4 3" : undefined} />
      {/* the rack ears with their screws */}
      {p.kind !== "outside" && p.box.w > 300 ? (
        <>
          <circle cx={p.box.x - R.rail / 2 + 1} cy={p.box.y + R.u / 2 - 1} r={2.2} fill="#94a3b8" />
          <circle cx={p.box.x + p.box.w + R.rail / 2 - 1} cy={p.box.y + R.u / 2 - 1} r={2.2} fill="#94a3b8" />
        </>
      ) : null}
      <circle cx={nx + (onTop ? 6 : 8)} cy={p.box.y + (onTop ? 6 : 8)} r={onTop ? 2.6 : 3.4} fill={led}>
        <title>{p.up === true ? "up: a port has link" : p.up === false ? "no port has link" : "no live state known"}</title>
      </circle>
      <text x={nx + (onTop ? 12 : 15)} y={p.box.y + (onTop ? 9 : tight ? p.box.h / 2 + 4 : 13)} className={`${dark ? "rack-name rack-name-dark" : "rack-name"}${onTop ? " rack-name-top" : ""}`}>
        {onTop ? `${p.title}${p.plate ? ` · ${p.plate.vendor} ${p.plate.model}` : ""}`.slice(0, Math.max(8, Math.floor(labelW / 5.2))) : p.title.length * 6.4 > labelW + 30 && cells.length ? `${p.title.slice(0, Math.max(6, Math.floor((labelW + 30) / 6.4) - 1))}…` : p.title}
      </text>
      {!tight ? (
        <text x={nx + 15} y={p.box.y + 25} className={dark ? "rack-sub rack-sub-dark" : "rack-sub"}>
          {p.sub.length * 5.4 > labelW + 20 && cells.length ? `${p.sub.slice(0, Math.max(6, Math.floor((labelW + 20) / 5.4) - 1))}…` : p.sub}
        </text>
      ) : null}
      {cells.map((c) => (
        <Port key={c.port.id} c={c} selected={portOn(c.port.id)} cabled={!!cabled?.has(c.port.id)} rear={!!rear?.has(c.port.id)} onClick={() => onPort(c.port.id)} />
      ))}
    </g>
  );
}

export function RackCanvas({ t, v, sel, pick, cables, onPane }: { t: Topology; v: PositionsView; sel: Sel | null; pick: (s: Sel) => void; cables: boolean; onPane: () => void }) {
  const L = useMemo(() => layoutRacks(v, t.outside), [v, t.outside]);
  const wrap = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState<number | null>(null);
  // Fitted until the operator zooms: the canvas has its size only after layout.
  const zoomed = useRef(false);
  const [hover, setHover] = useState<number | null>(null);
  const fit = () => {
    const el = wrap.current;
    if (!el) return;
    setScale(Math.max(0.3, Math.min(1.6, (el.clientWidth - 8) / L.width, (el.clientHeight - 8) / L.height)));
  };
  useLayoutEffect(fit, [L.width, L.height]);
  useEffect(() => {
    const el = wrap.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => {
      if (!zoomed.current) fit();
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [L.width, L.height]);
  const zoom = (f: number) => {
    zoomed.current = true;
    setScale(Math.max(0.2, Math.min(3, (scale ?? 1) * f)));
  };
  const k = scale ?? 1;
  // One wire per cable, or per segment of a link split at a patch panel (each
  // segment carries its link: its style, its selection).
  const wires = v.cables.flatMap((c) => (c.segments?.length ? c.segments.map((s) => ({ c, from: s.from, to: s.to })) : [{ c, from: c.from, to: c.to }]));
  const drawn = useMemo(() => {
    const ok = wires
      .map((w, i) => ({ c: w.c, w, i, a: L.ports.get(key(w.from.device, w.from.port)), b: L.ports.get(key(w.to.device, w.to.port)) }))
      .filter((x): x is typeof x & { a: PortAt; b: PortAt } => !!x.a && !!x.b);
    // Each one curve, port to port; a bundle between two devices fans out.
    const routes = routeCables(ok.map((x) => ({ a: x.a, b: x.b, rearA: x.w.from.side === "rear", rearB: x.w.to.side === "rear", device: [x.w.from.device, x.w.to.device] })));
    return ok.map((x, k) => ({ ...x, d: routes[k].d, mid: routes[k].mid }));
  }, [v, L]);
  const hovered = drawn.find((d) => d.i === hover);

  // The cabled ports of each device: a patch panel's front (underlined) and rear (overlined) apart.
  const [cabledOf, rearOf] = useMemo(() => {
    const m = new Map<string, Set<string>>();
    const r = new Map<string, Set<string>>();
    for (const c of v.cables) for (const s of c.segments?.length ? c.segments : [c]) for (const e of [s.from, s.to]) (e.side === "rear" ? r : m).set(e.device, ((e.side === "rear" ? r : m).get(e.device) ?? new Set()).add(e.port));
    return [m, r];
  }, [v]);
  const plate = (p: Placed): ReactNode => (
    <PlateSvg
      key={`${p.rack ?? "out"}:${p.device}`}
      p={p}
      cabled={cabledOf.get(p.device)}
      rear={rearOf.get(p.device)}
      on={isSel(sel, p.kind, p.device)}
      portOn={(id) => (sel?.kind === "port" && sel.switch === p.device && sel.id === id) || (sel?.kind === "panelport" && sel.panel === p.device && sel.id === id) || (sel?.kind === "link" && v.cables.some((c) => linkId(c.from.device, c.to.device) === sel.id && (c.segments?.length ? c.segments : [c]).some((w) => [w.from, w.to].some((e) => e.device === p.device && e.port === id))))}
      onPlate={() => pick(selOf(p.kind, p.device))}
      onPort={(id) => pick(isPatchPanel(t, p.device) ? panelPortSel(t, p.device, id) : selOf(p.kind, p.device, id))}
    />
  );

  return (
    <div className="rack-canvas" ref={wrap} onClick={onPane}>
      <div className="rack-zoom" onClick={(e) => e.stopPropagation()}>
        <button className="btn" onClick={() => zoom(1 / 1.2)} aria-label="zoom out">−</button>
        <button className="btn" onClick={() => ((zoomed.current = false), fit())}>fit</button>
        <button className="btn" onClick={() => zoom(1.2)} aria-label="zoom in">+</button>
      </div>
      <svg width={L.width * k} height={L.height * k} viewBox={`0 0 ${L.width} ${L.height}`} role="img" aria-label="the racks">
        {L.locations.map((l) => (
          <g key={`loc:${l.name}`} className="rack-location">
            <rect x={l.x} y={l.y} width={l.w} height={l.h} rx={14} fill="none" stroke="#64748b" strokeWidth={l.primary ? 1.6 : 1.2} strokeDasharray={l.primary ? undefined : "10 5"} />
            <text x={l.x + 14} y={l.y + 20} className="rack-location-title rack-location-link" onClick={(e) => (e.stopPropagation(), navigate(locationHref(l.name)))}>
              <title>{`${l.title}: its record on the Site page`}</title>
              {l.title}
            </text>
            {l.sub ? <text x={l.x + 14 + l.title.length * 9.5 + 10} y={l.y + 20} className="rack-where">{l.sub}</text> : null}
            {l.roomless || l.nowhere.length ? (
              <text x={l.nowhereX} y={R.roomY + 12} className="rack-where">
                {!l.roomless ? "placed nowhere here:" : l.nowhere.length ? "no room here — somewhere at this location:" : "no room here, and nothing recorded at it"}
              </text>
            ) : null}
            {l.nowhere.map((n, i) => (
              <text key={n.device} x={l.nowhereX} y={R.roomY + 34 + i * 20} className="rack-location-device" onClick={(e) => (e.stopPropagation(), pick(n.sel))}>
                {n.label}
              </text>
            ))}
          </g>
        ))}
        {L.rooms.map((room) => (
          <g key={room.name} className="rack-room" onClick={(e) => (e.stopPropagation(), pick({ kind: "room", id: room.name }))}>
            <rect x={room.x} y={room.y} width={room.w} height={room.h} rx={10} fill="#f8fafc" stroke="#94a3b8" strokeDasharray={room.recorded ? undefined : "6 4"} />
            <text x={room.x + 12} y={room.y + 22} className="rack-room-title">{room.title}</text>
            {room.sub ? <text x={room.x + 12} y={room.y + 38} className="rack-where">{room.sub}</text> : null}
          </g>
        ))}
        {L.racks.map(({ r, x }) => {
          const iw = inner(r);
          const h = r.units * R.u;
          return (
            <g key={r.name} className="rack-frame">
              <text x={x} y={R.top - 24} className="rack-title" onClick={(e) => (e.stopPropagation(), pick({ kind: "rack", id: r.name }))}>
                {r.displayName ?? r.name}
              </text>
              <text x={x} y={R.top - 10} className="rack-where">
                {[`${r.units}U ${r.width}`, r.room].filter(Boolean).join(" · ")}
              </text>
              <rect x={x} y={R.top} width={iw + 2 * R.rail} height={h} rx={4} fill="#f8fafc" stroke={sel?.kind === "rack" && sel.id === r.name ? "#3b6fd4" : "#334155"} strokeWidth={sel?.kind === "rack" && sel.id === r.name ? 3 : 2} onClick={(e) => (e.stopPropagation(), pick({ kind: "rack", id: r.name }))} />
              <rect x={x + R.rail} y={R.top} width={iw} height={h} fill="#eef2f6" />
              {Array.from({ length: r.units }, (_, row) => (
                <g key={row}>
                  <line x1={x + R.rail} x2={x + R.rail + iw} y1={R.top + row * R.u} y2={R.top + row * R.u} stroke="#dbe2ea" />
                  <text x={x + R.rail / 2} y={R.top + row * R.u + R.u / 2 + 3.5} className="rack-unit">{unitAt(r, row)}</text>
                  <text x={x + R.rail * 1.5 + iw} y={R.top + row * R.u + R.u / 2 + 3.5} className="rack-unit">{unitAt(r, row)}</text>
                </g>
              ))}
            </g>
          );
        })}
        {L.placed.map(plate)}
        {cables
          ? drawn.map(({ c, i, d, a, b }) => {
              const st = cableStyle(c, t);
              const on = sel?.kind === "link" && sel.id === linkId(c.from.device, c.to.device);
              const lit = hover === i || on;
              const op = (hover === null && !(sel?.kind === "link")) || lit ? 1 : 0.25;
              return (
                <g key={i} className="rack-cable" opacity={op} onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover((h) => (h === i ? null : h))} onClick={(e) => (e.stopPropagation(), pick({ kind: "link", id: linkId(c.from.device, c.to.device), port: `${c.from.device}:${c.from.port}` }))}>
                  <path d={d} fill="none" stroke="transparent" strokeWidth={10} />
                  <path d={d} fill="none" stroke={st.stroke} strokeWidth={lit ? st.width + 1.4 : st.width} strokeDasharray={st.dash} strokeLinecap="round" />
                  {/* a dot where it meets each port */}
                  <circle cx={a.x} cy={a.y} r={lit ? 3.2 : 2.4} fill={st.stroke} stroke="#ffffff" strokeWidth={0.8} />
                  <circle cx={b.x} cy={b.y} r={lit ? 3.2 : 2.4} fill={st.stroke} stroke="#ffffff" strokeWidth={0.8} />
                </g>
              );
            })
          : null}
        {cables
          ? drawn
              // The selected cable — the one clicked, both wires of a split one —
              // else every cable of the selected link.
              .filter(({ c }) => sel?.kind === "link" && sel.id === linkId(c.from.device, c.to.device))
              .filter(({ c }, _, all) => !(sel?.kind === "link" && sel.port) || !all.some((x) => tagged(x.c, sel.port!)) || tagged(c, sel.port))
              .map(({ c, w, i, mid }, k) => {
                // Its label halfway along each wire, just above the curve's
                // middle so a short cable stays in sight; several stacked.
                const tx = cableTag(c, w);
                const tw = tx.length * 5.3 + 10;
                const y = mid[1] - 22 - k * 17;
                return (
                  <g key={`tag:${i}`} className="rack-cable-tag" pointerEvents="none">
                    <rect x={mid[0] - tw / 2} y={y} width={tw} height={15} rx={3} fill="#ffffff" stroke={cableStyle(c, t).stroke} strokeWidth={1.2} />
                    <text x={mid[0]} y={y + 11} textAnchor="middle" className="rack-cable-tag-text">{tx}</text>
                  </g>
                );
              })
          : null}
        {hovered && cables ? (
          <g className="rack-cable-label" pointerEvents="none">
            {(() => {
              const tx = cableText(hovered.c);
              const x = Math.min(L.width - tx.length * 6.2 - 12, Math.max(4, (hovered.a!.x + hovered.b!.x) / 2 - (tx.length * 6.2) / 2));
              const y = Math.min(hovered.a!.y, hovered.b!.y) - 12;
              return (
                <>
                  <rect x={x - 5} y={y - 13} width={tx.length * 6.2 + 10} height={18} rx={3} fill="#0f172a" opacity={0.92} />
                  <text x={x} y={y} className="rack-tip">{tx}</text>
                </>
              );
            })()}
          </g>
        ) : null}
      </svg>
    </div>
  );
}
