// rack.tsx — the Site page's Physical view: the site's locations, each with its
// rooms, each room with its racks and the devices loose in it; each rack drawn
// as a frame with its unit rows numbered as the rack numbers them, each placed
// device as its faceplate at
// its units and width with its port grid, the ports' live state from the
// topology (link up or down, LAG), and the cables port to port in the zone
// colours of the Device view, labelled on hover, a click opening the cable's
// link in the side panel (the same panel the Device view opens). A device
// only a cable record places (the ISP's modem) stands left of the racks.
// Every location of the site is drawn, one above the other, the primary first
// (the drawing fits to the first and scrolls to the rest), its heading a link
// to its record on the Site page with its address: after its rooms, the
// devices that are at it and placed nowhere (with no room, somewhere there),
// and a backup buddy or a satellite that is there.
// Everything comes from `network-manager topology` .positions; nothing is
// placed by hand here.

import { MutableRefObject, PointerEvent as ReactPointerEvent, ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { zoneColor } from "../colors";
import { PlatePort, RackCable, PositionsView, Topology } from "../types";
import { navigate } from "../ui";
import { locationHref } from "../locations";
import { R, RackLayout, Sel, dropTargetAt, inner, layoutRacks, portKey, selOf } from "./layout";
import { isPatchPanel, linkId, panelPortSel } from "./devicegraph";
import { Box, Placed, nameArea, portCells } from "./platelayout";
import { PortAt, routeCables } from "./cableroute";
import { Dragged, Drop, dropAt, unitAt } from "./dragplace";
import type { DragState } from "./dragdrop";

export { R, selOf, layoutRacks } from "./layout";
export type { RackLayout } from "./layout";
export type { Box, Placed } from "./platelayout";

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

const isSel = (s: Sel | null, kind: Placed["kind"], device: string): boolean =>
  !!s && (((s.kind === "node" || s.kind === "switch" || s.kind === "ap" || s.kind === "mount") && s.id === device) || (s.kind === "port" && s.switch === device && kind === "switch") || (s.kind === "panelport" && s.panel === device));

// One faceplate: its name and model on the left, its LED, its port grid with
// each port's live state, the cabled ones underlined, the selected one ringed.
// The rack draws every placed device with it; the side panel draws the selected one.
export function PlateSvg({ p, on, portOn, cabled, rear, onPlate, onPort, onGrab, dragged }: { p: Placed; on: boolean; portOn: (id: string) => boolean; cabled?: Set<string>; rear?: Set<string>; onPlate: () => void; onPort: (id: string) => void; onGrab?: (e: ReactPointerEvent) => void; dragged?: boolean }) {
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
    <g className={onGrab ? "rack-plate rack-plate-drag" : "rack-plate"} opacity={dragged ? 0.45 : undefined} onClick={(e) => (e.stopPropagation(), onPlate())} onPointerDown={onGrab}>
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

// A drop on its way: the plate at its units, or its name in the room's area.
function PendingDrop({ L, d, drop }: { L: RackLayout; d: Dragged; drop: Drop }) {
  const room = drop.room ? L.rooms.find((m) => m.name === drop.room) : null;
  if (room) {
    return (
      <g pointerEvents="none">
        <rect className="drop-pending" x={room.x} y={room.y} width={room.w} height={room.h} rx={10} />
        <text x={room.x + 12} y={room.y - 4} className="rack-where">{d.device}: {d.from ? "moving here…" : "placing here…"}</text>
      </g>
    );
  }
  const at = L.racks.find((x) => x.r.name === drop.rack);
  if (!at || !drop.rows || !drop.span) return null;
  const iw = inner(at.r);
  const [a, b] = drop.span;
  const box = { x: at.x + R.rail + iw * a + 1, y: at.y + drop.rows[0] * R.u + 1, w: iw * (b - a) - 2, h: (drop.rows[1] - drop.rows[0] + 1) * R.u - 2 };
  const was = L.placed.find((p) => p.device === d.device);
  const p: Placed = { device: d.device, kind: d.kind as Placed["kind"], plate: was?.plate ?? null, box, up: null, title: was?.title ?? d.device, sub: d.from ? "moving here…" : "placing here…", rack: drop.rack ?? null };
  return (
    <g className="plate-pending" pointerEvents="none">
      <PlateSvg p={p} on={false} portOn={() => false} onPlate={() => undefined} onPort={() => undefined} />
      <rect className="drop-pending" x={box.x} y={box.y} width={box.w} height={box.h} rx={3} />
    </g>
  );
}

// drag: a device being dragged (dragdrop.tsx); dropRef: where a release now
// would put it; onGrab: a press on a placed plate (an operator's drawing only);
// pending: a drop on its way, drawn at its target until the positions show it.
export function RackCanvas({ t, v, sel, pick, cables, onPane, drag, dropRef, onGrab, pending }: { t: Topology; v: PositionsView; sel: Sel | null; pick: (s: Sel) => void; cables: boolean; onPane: () => void; drag?: DragState | null; dropRef?: MutableRefObject<Drop | null>; onGrab?: (e: ReactPointerEvent, device: string, grab: number) => void; pending?: { d: Dragged; drop: Drop } | null }) {
  const L = useMemo(() => layoutRacks(v, t.outside), [v, t.outside]);
  const wrap = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  // A client point in the drawing's own coordinates.
  const toSvg = (cx: number, cy: number): { x: number; y: number } | null => {
    const m = svgRef.current?.getScreenCTM();
    if (!m) return null;
    const p = new DOMPoint(cx, cy).matrixTransform(m.inverse());
    return { x: p.x, y: p.y };
  };
  const drop = useMemo((): Drop | null => {
    if (!drag || !wrap.current) return null;
    const b = wrap.current.getBoundingClientRect();
    if (drag.x < b.left || drag.x > b.right || drag.y < b.top || drag.y > b.bottom) return null;
    const at = toSvg(drag.x, drag.y);
    const target = at ? dropTargetAt(L, at.x, at.y, drag.grab) : null;
    return target ? dropAt(v, drag.d, target) : null;
  }, [drag, L, v]);
  useLayoutEffect(() => {
    if (dropRef) dropRef.current = drop;
  }, [drop, dropRef]);
  const [scale, setScale] = useState<number | null>(null);
  // Fitted until the operator zooms: the canvas has its size only after layout.
  const zoomed = useRef(false);
  const [hover, setHover] = useState<number | null>(null);
  const fit = () => {
    const el = wrap.current;
    if (!el) return;
    setScale(Math.max(0.3, Math.min(1.6, (el.clientWidth - 8) / L.width, (el.clientHeight - 8) / L.fitH)));
  };
  useLayoutEffect(fit, [L.width, L.fitH]);
  useEffect(() => {
    const el = wrap.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => {
      if (!zoomed.current) fit();
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [L.width, L.fitH]);
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
      .map((w, i) => ({ c: w.c, w, i, a: L.ports.get(portKey(w.from.device, w.from.port)), b: L.ports.get(portKey(w.to.device, w.to.port)) }))
      .filter((x): x is typeof x & { a: PortAt; b: PortAt } => !!x.a && !!x.b);
    // Each one curve, port to port; a bundle between two devices fans out.
    const routes = routeCables(ok.map((x) => ({ a: x.a, b: x.b, sideA: x.w.from.side, sideB: x.w.to.side, device: [x.w.from.device, x.w.to.device] })));
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
      dragged={drag?.d.device === p.device || pending?.d.device === p.device}
      onGrab={
        onGrab && p.kind !== "outside"
          ? (e) => {
              // Held by the unit under the pointer, so it keeps its place under it.
              const at = toSvg(e.clientX, e.clientY);
              const units = Math.max(1, Math.round((p.box.h + 2) / R.u));
              onGrab(e, p.device, p.rack && at ? Math.max(0, Math.min(units - 1, Math.floor((at.y - p.box.y) / R.u))) : 0);
            }
          : undefined
      }
    />
  );

  return (
    <div className="rack-canvas" ref={wrap} onClick={onPane}>
      <div className="rack-zoom" onClick={(e) => e.stopPropagation()}>
        <button className="btn" onClick={() => zoom(1 / 1.2)} aria-label="zoom out">−</button>
        <button className="btn" onClick={() => ((zoomed.current = false), fit())}>fit</button>
        <button className="btn" onClick={() => zoom(1.2)} aria-label="zoom in">+</button>
      </div>
      <svg ref={svgRef} width={L.width * k} height={L.height * k} viewBox={`0 0 ${L.width} ${L.height}`} role="img" aria-label="the racks">
        {L.locations.map((l) => (
          <g key={`loc:${l.name}`} className="rack-location">
            <rect x={l.x} y={l.y} width={l.w} height={l.h} rx={14} fill="none" stroke="#64748b" strokeWidth={l.primary ? 1.6 : 1.2} strokeDasharray={l.primary ? undefined : "10 5"} />
            {/* One line, so the address follows the name however wide the font draws it. */}
            <text x={l.x + 14} y={l.y + 20}>
              <tspan className="rack-location-title rack-location-link" onClick={(e) => (e.stopPropagation(), navigate(locationHref(l.name)))}>
                <title>{`${l.title}: its record on the Site page`}</title>
                {l.title}
              </tspan>
              {l.sub ? <tspan className="rack-where rack-location-sub" dx={12}>{l.sub}</tspan> : null}
            </text>
            {l.roomless || l.nowhere.length ? (
              <text x={l.nowhereX} y={l.nowhereY + 12} className="rack-where">
                {!l.roomless ? "placed nowhere here:" : l.nowhere.length ? "no room here — somewhere at this location:" : "no room here, and nothing recorded at it"}
              </text>
            ) : null}
            {l.nowhere.map((n, i) => (
              <text key={n.device} x={l.nowhereX} y={l.nowhereY + 34 + i * 20} className="rack-location-device" onClick={(e) => (e.stopPropagation(), pick(n.sel))}>
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
        {L.racks.map(({ r, x, y }) => {
          const iw = inner(r);
          const h = r.units * R.u;
          return (
            <g key={r.name} className="rack-frame">
              <text x={x} y={y - 24} className="rack-title" onClick={(e) => (e.stopPropagation(), pick({ kind: "rack", id: r.name }))}>
                {r.displayName ?? r.name}
              </text>
              <text x={x} y={y - 10} className="rack-where">
                {[`${r.units}U ${r.width}`, r.room].filter(Boolean).join(" · ")}
              </text>
              <rect x={x} y={y} width={iw + 2 * R.rail} height={h} rx={4} fill="#f8fafc" stroke={sel?.kind === "rack" && sel.id === r.name ? "#3b6fd4" : "#334155"} strokeWidth={sel?.kind === "rack" && sel.id === r.name ? 3 : 2} onClick={(e) => (e.stopPropagation(), pick({ kind: "rack", id: r.name }))} />
              <rect x={x + R.rail} y={y} width={iw} height={h} fill="#eef2f6" />
              {Array.from({ length: r.units }, (_, row) => (
                <g key={row}>
                  <line x1={x + R.rail} x2={x + R.rail + iw} y1={y + row * R.u} y2={y + row * R.u} stroke="#dbe2ea" />
                  <text x={x + R.rail / 2} y={y + row * R.u + R.u / 2 + 3.5} className="rack-unit">{unitAt(r, row)}</text>
                  <text x={x + R.rail * 1.5 + iw} y={y + row * R.u + R.u / 2 + 3.5} className="rack-unit">{unitAt(r, row)}</text>
                </g>
              ))}
            </g>
          );
        })}
        {L.placed.map(plate)}
        {drop && !drop.same && drop.room ? (() => {
          const room = L.rooms.find((m) => m.name === drop.room);
          return room ? <rect className={drop.ok ? "drop-ok" : "drop-bad"} x={room.x} y={room.y} width={room.w} height={room.h} rx={10} pointerEvents="none" /> : null;
        })() : null}
        {drop && !drop.same && drop.rack && drop.rows && drop.span ? (() => {
          const at = L.racks.find((x) => x.r.name === drop.rack);
          if (!at) return null;
          const iw = inner(at.r);
          const [a, b] = drop.span;
          return <rect className={drop.ok ? "drop-ok" : "drop-bad"} x={at.x + R.rail + iw * a + 1} y={at.y + drop.rows[0] * R.u + 1} width={iw * (b - a) - 2} height={(drop.rows[1] - drop.rows[0] + 1) * R.u - 2} rx={3} pointerEvents="none" />;
        })() : null}
        {pending ? <PendingDrop L={L} d={pending.d} drop={pending.drop} /> : null}
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
