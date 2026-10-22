// layout.ts — the topology document laid out under the spike's rules (§5.3):
// the ISP top-left with the firewall as a callout on the WAN path, the switches
// in the centre with their ports, the cluster members to the right with their
// uplinks and guests, the access points below the switches, the buddies and the
// satellite on the left as outside parties. Nothing is placed by hand (U9):
// dagre orders the node column against the switch ports to keep links from
// crossing, and every size follows from the document.

import dagre from "@dagrejs/dagre";
import { Edge, MarkerType, Node } from "@xyflow/react";
import { zoneColor } from "../colors";
import { TopoAp, TopoFinding, TopoNode, TopoOutside, TopoPort, TopoSwitch, TopoZone, Topology } from "../types";

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
  | { kind: "mount"; id: string }
  | { kind: "disk"; id: string; node: string } // id: the device
  | { kind: "pool"; id: string; node: string };

export type Pick = (s: Sel) => void;

// Geometry shared by the cards and the layout, so a handle sits on its row.
export const G = {
  colLeft: 0,
  colSwitch: 330,
  colNodes: 820,
  leftW: 250,
  switchW: 360,
  nodeW: 400,
  switchHead: 54,
  portRow: 26,
  lagRow: 22,
  nodeHead: 50,
  uplinkRow: 22,
  chipRow: 26,
  chipsPerRow: 3,
  gap: 36,
};

export type IspData = { wan: Topology["site"]["wan"]; pick: Pick; findings: TopoFinding[] };
export type FirewallData = { wan: Topology["site"]["wan"]; pick: Pick; findings: TopoFinding[] };
export type SwitchData = { sw: TopoSwitch; zones: TopoZone[]; pick: Pick; findings: TopoFinding[]; selected: Sel | null };
export type ClusterData = { node: TopoNode; pick: Pick; findings: TopoFinding[]; moduleLevel: Record<string, "fail" | "warn">; memory: string | null; showGuests: boolean; fwModule: string | null };
export type ApData = { ap: TopoAp; pick: Pick; findings: TopoFinding[] };
export type OutsideData = { o: TopoOutside | null; kind: "buddy" | "satellite"; pick: Pick; findings: TopoFinding[] };

export function switchHeight(sw: TopoSwitch): number {
  return G.switchHead + sw.ports.length * G.portRow + sw.lags.length * G.lagRow + 12;
}

export function nodeHeight(n: TopoNode, showGuests: boolean): number {
  const guests = n.guests.length;
  const chipRows = showGuests ? Math.ceil(guests / G.chipsPerRow) : 0;
  return G.nodeHead + n.uplinks.length * G.uplinkRow + 22 + chipRows * G.chipRow + 14;
}

// The y of a port row's centre inside its switch card.
export function portY(sw: TopoSwitch, port: string): number {
  const i = sw.ports.findIndex((p) => p.port === port);
  return G.switchHead + Math.max(i, 0) * G.portRow + G.portRow / 2;
}

export function uplinkY(n: TopoNode, uplink: string, leg: number): number {
  const i = Math.max(n.uplinks.findIndex((u) => u.name === uplink), 0);
  return G.nodeHead + i * G.uplinkRow + G.uplinkRow / 2 + (leg - (n.uplinks[i]?.legs.length ?? 1) / 2 + 0.5) * 5;
}

const portNum = (p: string): number => (Number.isFinite(Number(p)) ? Number(p) : 1e6);

// The order of the node column: dagre lays the switch ports and the nodes out
// as a two-rank graph and its crossing minimisation decides who sits where.
function nodeOrder(t: Topology): string[] {
  const g = new dagre.graphlib.Graph();
  g.setGraph({ rankdir: "LR", nodesep: 10, ranksep: 200 });
  g.setDefaultEdgeLabel(() => ({}));
  for (const s of t.switches) for (const p of s.ports) g.setNode(`p:${s.name}:${p.port}`, { width: 10, height: 10 });
  for (const n of t.nodes) g.setNode(`n:${n.name}`, { width: 10, height: 40 + n.guests.length * 4 });
  // Keep the ports in their physical order down the switch.
  for (const s of t.switches) {
    const ps = [...s.ports].sort((a, b) => portNum(a.port) - portNum(b.port));
    for (let i = 1; i < ps.length; i++) g.setEdge(`p:${s.name}:${ps[i - 1].port}`, `p:${s.name}:${ps[i].port}`, { minlen: 0, weight: 50 });
  }
  for (const n of t.nodes) {
    for (const u of n.uplinks) for (const l of u.legs) if (l.peer && g.hasNode(`p:${l.peer.switch}:${l.peer.port}`)) g.setEdge(`p:${l.peer.switch}:${l.peer.port}`, `n:${n.name}`, { weight: 1 });
  }
  try {
    dagre.layout(g);
    return [...t.nodes].sort((a, b) => (g.node(`n:${a.name}`)?.y ?? 0) - (g.node(`n:${b.name}`)?.y ?? 0)).map((n) => n.name);
  } catch {
    // dagre could not place it (an unconnected graph): the lowest port first.
    const first = (n: TopoNode) => Math.min(Infinity, ...n.uplinks.flatMap((u) => u.legs.map((l) => portNum(l.peer?.port ?? ""))));
    return [...t.nodes].sort((a, b) => first(a) - first(b)).map((n) => n.name);
  }
}

export interface LayoutOpts {
  pick: Pick;
  selected: Sel | null;
  showGuests: boolean;
  showLabels: boolean;
  memory: Record<string, string>; // node → its memory-commitment line
}

export function layoutTopology(t: Topology, o: LayoutOpts): { nodes: Node[]; edges: Edge[] } {
  const nodes: Node[] = [];
  const edges: Edge[] = [];
  const on = (kind: string, name: string) => t.findings.filter((f) => (f.on.kind === kind && f.on.name === name) || f.refs.some((r) => r.kind === kind && r.name === name));
  const moduleLevel: Record<string, "fail" | "warn"> = {};
  for (const f of t.findings) {
    if (f.on.kind !== "module" || f.gate === "cve-status") continue;
    if (f.level === "fail" || !moduleLevel[f.on.name]) moduleLevel[f.on.name] = f.level;
  }
  const wanColor = zoneColor({ name: "wan" });
  const fw = t.site.wan.firewall;

  // ── the centre: switches, stacked ──────────────────────────────────
  let y = 0;
  const swY: Record<string, number> = {};
  for (const s of t.switches) {
    swY[s.name] = y;
    nodes.push({
      id: `switch:${s.name}`,
      type: "switch",
      position: { x: G.colSwitch, y },
      data: { sw: s, zones: t.zones, pick: o.pick, findings: t.findings.filter((f) => f.on.switch === s.name || f.refs.some((r) => r.switch === s.name)), selected: o.selected } satisfies SwitchData,
      style: { width: G.switchW },
    });
    y += switchHeight(s) + G.gap;
  }
  const switchesBottom = y;

  // ── access points below the switches ───────────────────────────────
  let apX = G.colSwitch;
  for (const a of t.accessPoints) {
    nodes.push({ id: `ap:${a.name}`, type: "ap", position: { x: apX, y: switchesBottom + 20 }, data: { ap: a, pick: o.pick, findings: on("ap", a.name) } satisfies ApData, style: { width: 220 } });
    const sw = a.uplink ? t.switches.find((s) => s.name === a.uplink!.switch) : undefined;
    if (sw && a.uplink) {
      edges.push({
        id: `e-ap-${a.name}`,
        source: `switch:${sw.name}`,
        sourceHandle: `l-${a.uplink.port}`,
        target: `ap:${a.name}`,
        targetHandle: "up",
        type: "smoothstep",
        style: { stroke: "#64748b", strokeWidth: 2 },
        label: o.showLabels ? `port ${a.uplink.port} · trunk` : undefined,
      });
    }
    apX += 240;
  }

  // ── the node column, in dagre's order ──────────────────────────────
  y = 0;
  for (const name of nodeOrder(t)) {
    const n = t.nodes.find((x) => x.name === name)!;
    nodes.push({
      id: `node:${n.name}`,
      type: "cluster",
      position: { x: G.colNodes, y },
      data: { node: n, pick: o.pick, findings: t.findings.filter((f) => f.on.kind === "node" && f.on.name === n.name), moduleLevel, memory: o.memory[n.name] ?? null, showGuests: o.showGuests, fwModule: fw?.module ?? null } satisfies ClusterData,
      style: { width: G.nodeW },
    });
    y += nodeHeight(n, o.showGuests) + G.gap;
    for (const u of n.uplinks) {
      u.legs.forEach((l, i) => {
        if (!l.peer || !t.switches.some((s) => s.name === l.peer!.switch)) return;
        const lag = t.switches.find((s) => s.name === l.peer!.switch)?.ports.find((p) => p.port === l.peer!.port)?.lag;
        const at = (r: { kind: string; name: string; switch?: string }) => r.kind === "port" && r.name === l.peer!.port && r.switch === l.peer!.switch;
        const warn = t.findings.some((f) => at(f.on) || f.refs.some(at));
        edges.push({
          id: `e-${n.name}-${l.nic}`,
          source: `switch:${l.peer.switch}`,
          sourceHandle: `r-${l.peer.port}`,
          target: `node:${n.name}`,
          targetHandle: `leg-${u.name}-${i}`,
          type: "smoothstep",
          animated: false,
          style: u.name === "wan"
            ? { stroke: wanColor, strokeWidth: 2, strokeDasharray: "6 4" }
            : { stroke: l.up ? (warn ? "#d97706" : "#334155") : "#d64545", strokeWidth: lag ? 3.5 : 2.5, strokeDasharray: l.up ? undefined : "3 3" },
          label: o.showLabels ? `${l.nic}${l.speed ? ` · ${l.speed}` : ""}${u.name === "wan" ? ` · vlan ${t.site.wan.vlan ?? "?"}` : ""}` : undefined,
          labelStyle: { fontSize: 11, fill: "#334155" },
          labelBgStyle: { fill: "#f6f7f9" },
        });
      });
    }
  }

  // ── the left: the ISP, the firewall on the WAN path, outside parties ──
  let ly = 0;
  const handoff = t.site.wan.handoff;
  nodes.push({ id: "isp", type: "isp", position: { x: G.colLeft, y: ly }, data: { wan: t.site.wan, pick: o.pick, findings: on("site", "uplink") } satisfies IspData, style: { width: G.leftW } });
  if (handoff && swY[handoff.switch] !== undefined) {
    edges.push({
      id: "e-isp",
      source: "isp",
      sourceHandle: "out",
      target: `switch:${handoff.switch}`,
      targetHandle: `l-${handoff.port}`,
      type: "smoothstep",
      style: { stroke: wanColor, strokeWidth: 2.5, strokeDasharray: "6 4" },
      label: o.showLabels ? `port ${handoff.port} · vlan ${t.site.wan.vlan ?? "?"}` : undefined,
      markerEnd: { type: MarkerType.ArrowClosed, color: wanColor },
    });
  }
  ly += 110;
  if (fw) {
    nodes.push({ id: "firewall", type: "firewall", position: { x: G.colLeft, y: ly }, data: { wan: t.site.wan, pick: o.pick, findings: on("module", fw.module) } satisfies FirewallData, style: { width: G.leftW } });
    if (fw.node && t.nodes.some((n) => n.name === fw.node)) {
      edges.push({
        id: "e-fw",
        source: "firewall",
        sourceHandle: "host",
        target: `node:${fw.node}`,
        targetHandle: "top",
        type: "smoothstep",
        style: { stroke: "#7c3aed", strokeWidth: 1.5, strokeDasharray: "2 4" },
        label: o.showLabels ? `VM ${fw.vmid ?? "?"} runs on ${fw.node}` : undefined,
        labelStyle: { fontSize: 11, fill: "#5b21b6" },
      });
    }
    ly += 150;
  }
  ly = Math.max(ly + 20, 300);
  const backupNode = t.nodes.find((n) => n.roles.includes("backup"));
  const outside = [...t.outside];
  const parties: { o: TopoOutside | null; kind: "buddy" | "satellite" }[] = [
    ...outside.filter((x) => x.kind === "buddy").map((x) => ({ o: x, kind: "buddy" as const })),
    ...(outside.some((x) => x.kind === "satellite") ? outside.filter((x) => x.kind === "satellite").map((x) => ({ o: x, kind: "satellite" as const })) : [{ o: null, kind: "satellite" as const }]),
  ];
  for (const p of parties) {
    const id = `outside:${p.o?.name ?? "none"}`;
    nodes.push({ id, type: "outside", position: { x: G.colLeft, y: ly }, data: { o: p.o, kind: p.kind, pick: o.pick, findings: p.o ? on("peer", p.o.name) : [] } satisfies OutsideData, style: { width: G.leftW } });
    if (p.o && p.kind === "buddy" && backupNode) {
      edges.push({
        id: `e-${id}`,
        source: id,
        sourceHandle: "out",
        target: `node:${backupNode.name}`,
        targetHandle: "tunnel",
        type: "default",
        style: { stroke: p.o.state === "down" ? "#d97706" : "#0ea5a4", strokeWidth: 1.5, strokeDasharray: "1 5", strokeLinecap: "round" },
        label: o.showLabels ? `tunnel${p.o.state ? ` · ${p.o.state}` : ""}` : undefined,
        labelStyle: { fontSize: 11 },
      });
    }
    ly += 120;
  }
  return { nodes, edges };
}

export function portLabel(p: TopoPort): string {
  if (p.parked) return `parked · ${p.zones[0] ?? "?"}`;
  if (!p.target) return p.description ?? "—";
  if (p.target.kind === "isp") return p.description ?? "ISP hand-off";
  const nm = p.target.name ?? "?";
  return `${nm}${p.target.port ? ` ${p.target.port}` : ""}${p.role === "node-wan" ? " (wan)" : ""}`;
}
