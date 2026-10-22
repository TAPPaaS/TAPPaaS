// rack.tsx — the Site page's Physical view: each rack drawn as a frame with its
// unit rows numbered as the rack numbers them, each mount as its faceplate at
// its units and width with its port grid, the ports' live state from the
// topology (link up or down, LAG), and the cables port to port in the zone
// colours of the Device view, labelled on hover. A device only a cable record
// places (the ISP's modem) stands left of the racks. Everything comes from
// `network-manager topology` .racks; nothing is placed by hand here.

import { ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { zoneColor } from "../colors";
import { PlatePort, RackCable, RackInfo, RackMount, RacksView, ResolvedPlate, Topology } from "../types";
import { Sel } from "./layout";

// Geometry: one rack unit, the rails with their numbers, a 19in and a 10in
// interior (wider than true scale, so a 12-port plate stays legible).
export const R = { u: 30, rail: 24, w19: 440, w10: 240, gap: 150, top: 46, margin: 24, outsideW: 230, bottom: 40 };

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

interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}
interface Placed {
  device: string;
  kind: RackMount["kind"] | "outside";
  plate: ResolvedPlate | null;
  box: Box;
  up: boolean | null;
  title: string;
  sub: string;
  rack: string | null;
}
export interface RackLayout {
  width: number;
  height: number;
  racks: { r: RackInfo; x: number }[];
  placed: Placed[];
  ports: Map<string, { x: number; y: number; rackRight: number; rack: string | null }>;
}

const key = (device: string, port: string) => `${device}\u0000${port}`;

// Where every port of every plate is drawn: one cell per port of the plate's
// grid, right-aligned, the label on the left.
function portCells(p: Placed): { port: PlatePort; box: Box }[] {
  const rows = p.plate?.rows ?? [];
  if (!rows.length) return [];
  const cols = Math.max(...rows.map((r) => r.length), 1);
  const labelW = Math.min(124, p.box.w * 0.34);
  const avail = p.box.w - labelW - 12;
  const cw = Math.max(9, Math.min(22, avail / cols));
  const ch = Math.max(7, Math.min(13, (p.box.h - 8) / rows.length - 3));
  const gridW = cols * cw;
  const gridH = rows.length * (ch + 3);
  const x0 = p.box.x + p.box.w - 8 - gridW;
  const y0 = p.box.y + (p.box.h - gridH) / 2 + 1.5;
  const out: { port: PlatePort; box: Box }[] = [];
  rows.forEach((row, ri) =>
    row.forEach((c, ci) => {
      if (c) out.push({ port: c, box: { x: x0 + ci * cw + 1, y: y0 + ri * (ch + 3), w: cw - 3, h: ch } });
    }),
  );
  return out;
}

export function layoutRacks(v: RacksView): RackLayout {
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
  let maxH = 0;
  for (const r of v.racks) {
    racks.push({ r, x });
    const iw = inner(r);
    for (const m of r.mounts) {
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
  }
  for (const p of placed) {
    const rackRight = p.rack ? (racks.find((x) => x.r.name === p.rack)!.x + inner(racks.find((x) => x.r.name === p.rack)!.r) + 2 * R.rail) : p.box.x + p.box.w;
    for (const c of portCells(p)) ports.set(key(p.device, c.port.id), { x: c.box.x + c.box.w / 2, y: c.box.y + c.box.h / 2, rackRight, rack: p.rack });
  }
  const outsideH = placed.filter((p) => p.kind === "outside").reduce((h, p) => Math.max(h, p.box.y + p.box.h), 0);
  return { width: Math.max(x - R.gap + R.margin + 60, 400), height: Math.max(R.top + maxH + R.bottom, outsideH + R.bottom), racks, placed, ports };
}

// A cable's colour and dash, as the Device view draws links: a wan link
// dashed in the wan colour, an access link in its zone's colour, a trunk
// slate, a link that is down red and dotted.
export function cableStyle(c: RackCable, t: Topology): { stroke: string; width: number; dash?: string } {
  const width = c.lag ? 3.5 : 2.5;
  if (c.up === false) return { stroke: "#d64545", width, dash: "3 3" };
  if (c.kind === "wan" || (c.zones.length === 1 && c.zones[0] === t.site.wan.zone)) return { stroke: zoneColor({ name: "wan" }), width, dash: "6 4" };
  if (c.zones.length === 1) {
    const z = t.zones.find((x) => x.name === c.zones[0]);
    return { stroke: zoneColor(z ?? { name: c.zones[0] }), width, dash: c.source === "recorded" ? "2 3" : undefined };
  }
  if (c.kind === "power") return { stroke: "#b91c1c", width: 2, dash: "1 3" };
  return { stroke: "#334155", width, dash: c.source === "recorded" ? "2 3" : undefined };
}

export function cableText(c: RackCable): string {
  const st = c.up === true ? "up" : c.up === false ? "down" : "state unknown";
  return `${c.from.device}:${c.from.port} — ${c.to.device}:${c.to.port} · ${c.kind}${c.lag ? ` · LAG ${c.lag}` : ""} · ${st}${c.zones.length ? ` · ${c.zones.join(", ")}` : ""}${c.source === "recorded" ? " · recorded" : ""}${c.label ? ` · ${c.label}` : ""}`;
}

// The cable's path: out of the rack's side between two ports of one rack
// (where the cable management runs); from a device outside the racks over the
// rack's top and down its side; a droop between racks.
type End = { x: number; y: number; rackRight: number; rack: string | null };
function cablePath(a0: End, b0: End): string {
  const [a, b] = !a0.rack && b0.rack ? [a0, b0] : !b0.rack && a0.rack ? [b0, a0] : [a0, b0];
  if (!a.rack && b.rack) {
    const top = R.top - 6;
    const side = b.rackRight + 16;
    return `M ${a.x} ${a.y} C ${a.x + 30} ${a.y}, ${a.x + 30} ${top}, ${a.x + 70} ${top} L ${side - 14} ${top} C ${side} ${top}, ${side} ${b.y}, ${b.x} ${b.y}`;
  }
  if (a.rack && a.rack === b.rack) {
    const bend = a.rackRight - Math.min(a.x, b.x) + 18 + Math.abs(a.y - b.y) * 0.12;
    return `M ${a.x} ${a.y} C ${a.x + bend} ${a.y}, ${b.x + bend} ${b.y}, ${b.x} ${b.y}`;
  }
  const mid = (a.x + b.x) / 2;
  const droop = Math.max(a.y, b.y) + 40;
  return `M ${a.x} ${a.y} C ${mid} ${a.y}, ${mid} ${droop}, ${b.x} ${b.y}`;
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

function Port({ c, selected, onClick }: { c: { port: PlatePort; box: Box }; selected: boolean; onClick: () => void }) {
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
      {selected ? <rect x={b.x - 2} y={b.y - 2} width={b.w + 4} height={b.h + 4} rx={2} fill="none" stroke="#3b6fd4" strokeWidth={2} /> : null}
    </g>
  );
}

// What a click on a plate or a port selects: the device's own side card (a
// node, a switch or one of its ports, an access point), else the mount's.
export function selOf(kind: Placed["kind"], device: string, port?: string): Sel {
  if (kind === "switch") return port ? { kind: "port", id: port, switch: device } : { kind: "switch", id: device };
  if (kind === "node") return { kind: "node", id: device };
  if (kind === "ap") return { kind: "ap", id: device };
  return { kind: "mount", id: device };
}

const isSel = (s: Sel | null, kind: Placed["kind"], device: string): boolean =>
  !!s && (((s.kind === "node" || s.kind === "switch" || s.kind === "ap" || s.kind === "mount") && s.id === device) || (s.kind === "port" && s.switch === device && kind === "switch"));

export function RackCanvas({ t, v, sel, pick, cables, onPane }: { t: Topology; v: RacksView; sel: Sel | null; pick: (s: Sel) => void; cables: boolean; onPane: () => void }) {
  const L = useMemo(() => layoutRacks(v), [v]);
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
  const drawn = v.cables
    .map((c, i) => ({ c, i, a: L.ports.get(key(c.from.device, c.from.port)), b: L.ports.get(key(c.to.device, c.to.port)) }))
    .filter((x) => x.a && x.b);
  const hovered = drawn.find((d) => d.i === hover);

  const plate = (p: Placed): ReactNode => {
    const on = isSel(sel, p.kind, p.device);
    const cells = portCells(p);
    const led = p.up === true ? "#2f9e44" : p.up === false ? "#d64545" : "#9aa4b2";
    const labelW = Math.min(124, p.box.w * 0.34);
    const tight = p.box.h < 34;
    return (
      <g key={`${p.rack ?? "out"}:${p.device}`} className="rack-plate" onClick={(e) => (e.stopPropagation(), pick(selOf(p.kind, p.device)))}>
        <title>{`${p.title} — ${p.sub}`}</title>
        <rect x={p.box.x} y={p.box.y} width={p.box.w} height={p.box.h} rx={3} fill={p.kind === "outside" ? "#f1f5f9" : p.plate?.passive ? "#e2e8f0" : "#1e293b"} stroke={on ? "#3b6fd4" : p.kind === "outside" ? "#94a3b8" : "#0f172a"} strokeWidth={on ? 2.5 : 1} strokeDasharray={p.kind === "outside" ? "4 3" : undefined} />
        {/* the rack ears with their screws */}
        {p.kind !== "outside" && p.box.w > 300 ? (
          <>
            <circle cx={p.box.x - R.rail / 2 + 1} cy={p.box.y + R.u / 2 - 1} r={2.2} fill="#94a3b8" />
            <circle cx={p.box.x + p.box.w + R.rail / 2 - 1} cy={p.box.y + R.u / 2 - 1} r={2.2} fill="#94a3b8" />
          </>
        ) : null}
        <circle cx={p.box.x + 8} cy={p.box.y + 8} r={3.4} fill={led}>
          <title>{p.up === true ? "up: a port has link" : p.up === false ? "no port has link" : "no live state known"}</title>
        </circle>
        <text x={p.box.x + 15} y={p.box.y + (tight ? p.box.h / 2 + 4 : 13)} className={p.kind === "outside" || p.plate?.passive ? "rack-name rack-name-dark" : "rack-name"}>
          {p.title.length * 6.4 > labelW + 30 && cells.length ? `${p.title.slice(0, Math.max(6, Math.floor((labelW + 30) / 6.4) - 1))}…` : p.title}
        </text>
        {!tight ? (
          <text x={p.box.x + 15} y={p.box.y + 25} className={p.kind === "outside" || p.plate?.passive ? "rack-sub rack-sub-dark" : "rack-sub"}>
            {p.sub.length * 5.4 > labelW + 20 && cells.length ? `${p.sub.slice(0, Math.max(6, Math.floor((labelW + 20) / 5.4) - 1))}…` : p.sub}
          </text>
        ) : null}
        {cells.map((c) => (
          <Port key={c.port.id} c={c} selected={sel?.kind === "port" && sel.switch === p.device && sel.id === c.port.id} onClick={() => pick(selOf(p.kind, p.device, c.port.id))} />
        ))}
      </g>
    );
  };

  return (
    <div className="rack-canvas" ref={wrap} onClick={onPane}>
      <div className="rack-zoom" onClick={(e) => e.stopPropagation()}>
        <button className="btn" onClick={() => zoom(1 / 1.2)} aria-label="zoom out">−</button>
        <button className="btn" onClick={() => ((zoomed.current = false), fit())}>fit</button>
        <button className="btn" onClick={() => zoom(1.2)} aria-label="zoom in">+</button>
      </div>
      <svg width={L.width * k} height={L.height * k} viewBox={`0 0 ${L.width} ${L.height}`} role="img" aria-label="the racks">
        {L.racks.map(({ r, x }) => {
          const iw = inner(r);
          const h = r.units * R.u;
          return (
            <g key={r.name} className="rack-frame">
              <text x={x} y={R.top - 24} className="rack-title" onClick={(e) => (e.stopPropagation(), pick({ kind: "rack", id: r.name }))}>
                {r.displayName ?? r.name}
              </text>
              <text x={x} y={R.top - 10} className="rack-where">
                {[`${r.units}U ${r.width}`, r.building, r.room].filter(Boolean).join(" · ")}
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
          ? drawn.map(({ c, i, a, b }) => {
              const st = cableStyle(c, t);
              const d = cablePath(a!, b!);
              return (
                <g key={i} className="rack-cable" onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover((h) => (h === i ? null : h))}>
                  <path d={d} fill="none" stroke="transparent" strokeWidth={10} />
                  <path d={d} fill="none" stroke={st.stroke} strokeWidth={hover === i ? st.width + 1.5 : st.width} strokeDasharray={st.dash} opacity={hover === null || hover === i ? 0.9 : 0.35} strokeLinecap="round" />
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
