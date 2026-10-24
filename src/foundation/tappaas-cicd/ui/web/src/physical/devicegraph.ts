// devicegraph.ts — the Device view as data: every physical device of the
// topology (the cluster nodes, the switches, the access points, the machines
// and devices a rack or a cable record names, the internet and the backup
// buddies) as one node, every pair of devices that a cable joins as one link
// with its cables, and each device's state from the findings on it. Plain
// data, no React: the unit tests run it over hrossen's topology.

import { RackCable, RecordedKind, Topology, TopoFinding } from "../types";
import { Sel } from "./layout";
import { CardState, stateOf } from "./states";

export type DevKind = "node" | "switch" | "ap" | "isp" | "buddy" | "machine" | "device";

export interface DevNode {
  id: string;
  name: string;
  kind: DevKind;
  sel: Sel;
  recorded?: RecordedKind; // a device position-manager records
  seen?: true; // a device a switch port sees that nobody recorded
}

// One cable, as the topology resolves it or as recorded; the internet's and a
// buddy's links have none (a hand-off and a tunnel).
export type Cable = Pick<RackCable, "from" | "to" | "kind" | "source" | "zones" | "lag" | "up" | "label" | "segments" | "via">;

export interface DevLink {
  id: string;
  a: string;
  b: string;
  kind: "lan" | "wan" | "uplink" | "peer-link" | "ap" | "tunnel" | "hand-off" | "other";
  cables: Cable[];
  zones: string[];
  up: boolean | null; // false when any cable is down
}

export const ISP = "Internet";
const peerId = (name: string) => `buddy ${name}`;

// A link's id: its two ends, in order.
export const linkId = (a: string, b: string): string => (a < b ? `${a} ↔ ${b}` : `${b} ↔ ${a}`);

const KIND_RANK: DevLink["kind"][] = ["wan", "hand-off", "tunnel", "peer-link", "uplink", "lan", "ap", "other"];

export function deviceGraph(t: Topology): { nodes: DevNode[]; links: DevLink[] } {
  const nodes = new Map<string, DevNode>();
  const add = (id: string, kind: DevKind, sel: Sel, name = id, recorded?: RecordedKind, seen?: boolean): void => {
    if (!nodes.has(id)) nodes.set(id, { id, name, kind, sel, ...(recorded ? { recorded } : {}), ...(seen ? { seen: true as const } : {}) });
  };
  for (const s of t.switches) add(s.name, "switch", { kind: "switch", id: s.name });
  for (const n of t.nodes) add(n.name, "node", { kind: "node", id: n.name });
  for (const a of t.accessPoints) add(a.name, "ap", { kind: "ap", id: a.name });
  for (const d of t.devices ?? []) add(d.name, d.kind === "machine" ? "machine" : "device", { kind: "mount", id: d.name }, d.source === "seen" && d.displayName ? d.displayName : d.name, d.recorded ? (d.kind as RecordedKind) : undefined, d.source === "seen");
  for (const o of t.positions?.outside ?? []) add(o.device, "device", { kind: "mount", id: o.device });
  // A placed plate nothing else names (a patch panel, a PDU).
  for (const m of t.positions?.racks.flatMap((r) => r.placements) ?? []) add(m.device, m.kind === "machine" ? "machine" : "device", { kind: "mount", id: m.device });

  // The cables: the racks' list when the topology carries it (the topology's
  // own links and the recorded ones), else what the uplinks and the access
  // points say.
  const cables: Cable[] = t.positions
    ? t.positions.cables
    : [
        ...t.nodes.flatMap((n) =>
          n.uplinks.flatMap((u) =>
            u.legs.filter((l) => l.peer).map((l): Cable => ({ from: { device: l.peer!.switch, port: l.peer!.port }, to: { device: n.name, port: l.nic }, kind: u.name, source: "topology", zones: [], lag: null, up: l.up, label: null })),
          ),
        ),
        ...t.accessPoints.filter((a) => a.uplink).map((a): Cable => ({ from: { device: a.uplink!.switch, port: a.uplink!.port }, to: { device: a.name, port: "uplink" }, kind: "ap", source: "topology", zones: [], lag: null, up: null, label: null })),
      ];
  const links = new Map<string, DevLink>();
  const join = (a: string, b: string, kind: DevLink["kind"], c?: Cable): void => {
    if (a === b || !nodes.has(a) || !nodes.has(b)) return;
    const id = linkId(a, b);
    const l = links.get(id) ?? { id, a: a < b ? a : b, b: a < b ? b : a, kind, cables: [], zones: [], up: null };
    if (KIND_RANK.indexOf(kind) < KIND_RANK.indexOf(l.kind)) l.kind = kind;
    if (c) {
      // A cable listed from both of its ends is one cable.
      if (!l.cables.some((x) => (x.from.device === c.to.device && x.from.port === c.to.port && x.to.device === c.from.device && x.to.port === c.from.port) || (x.from.device === c.from.device && x.from.port === c.from.port && x.to.device === c.to.device && x.to.port === c.to.port))) l.cables.push(c);
      for (const z of c.zones) if (!l.zones.includes(z)) l.zones.push(z);
      l.up = l.up === false || c.up === false ? false : c.up === true ? true : l.up;
    }
    links.set(id, l);
  };
  const kindOf = (k: string): DevLink["kind"] => (["lan", "wan", "uplink", "peer-link", "ap"].includes(k) ? (k as DevLink["kind"]) : "other");
  for (const c of cables) {
    for (const d of [c.from.device, c.to.device]) if (!nodes.has(d)) add(d, "device", { kind: "mount", id: d });
    join(c.from.device, c.to.device, kindOf(c.kind), c);
  }

  // A cable between two switches that each name only their own end (a peer
  // link: "sfp-sfpplus15 → peer-link" from both sides) is one cable, port to
  // port.
  const known = (dev: string, port: string) => !!t.switches.find((x) => x.name === dev)?.ports.some((p) => p.port === port);
  for (const l of links.values()) {
    const half = l.cables.filter((c) => !known(c.to.device, c.to.port) && known(c.from.device, c.from.port) && t.switches.some((x) => x.name === c.to.device));
    for (const c of half) {
      const twin = half.find((x) => x !== c && x.from.device === c.to.device && x.to.device === c.from.device && x.from.port === c.from.port && l.cables.includes(x));
      if (!twin || !l.cables.includes(c)) continue;
      l.cables = l.cables.filter((x) => x !== twin).map((x) => (x === c ? { ...c, to: { ...twin.from } } : x));
    }
  }

  // The internet: at the device the provider's line ends in (a recorded modem
  // on the hand-off port), else at the hand-off port's switch.
  const w = t.site.wan;
  add(ISP, "isp", { kind: "isp", id: "isp" });
  if (w.handoff) {
    const modem = cables.find((c) => (c.from.device === w.handoff!.switch && c.from.port === w.handoff!.port) || (c.to.device === w.handoff!.switch && c.to.port === w.handoff!.port));
    const far = modem ? (modem.from.device === w.handoff.switch ? modem.to.device : modem.from.device) : null;
    join(ISP, far && nodes.get(far)?.kind === "device" ? far : w.handoff.switch, "hand-off");
  }
  // A backup buddy: by its tunnel, to the node the firewall runs on.
  const fwNode = w.firewall?.node ?? t.nodes[0]?.name;
  for (const o of t.outside) {
    add(peerId(o.name), "buddy", { kind: "outside", id: o.name }, o.name);
    if (fwNode) join(peerId(o.name), fwNode, "tunnel");
  }
  return { nodes: [...nodes.values()], links: [...links.values()] };
}

// ── patch panels ──────────────────────────────────────────────────────

// What is on one side of a patch panel's port: the far end of its wire, and
// the cable that wire belongs to (a link split at the panel is one cable, its
// wires its segments).
export interface PanelSide {
  device: string;
  port: string;
  cable: RackCable;
}
export type PanelPortUse = { front?: PanelSide; rear?: PanelSide };

// A recorded patch panel's ports, as cabled: every wire whose end is one of
// its ports — a segment of a split link as much as a cable of its own — on
// that end's side (front unless it says rear).
export function panelPortUse(cables: RackCable[], panel: string): Map<string, PanelPortUse> {
  const out = new Map<string, PanelPortUse>();
  for (const c of cables) {
    for (const w of c.segments?.length ? c.segments : [c]) {
      for (const [e, far] of [[w.from, w.to], [w.to, w.from]] as const) {
        if (e.device !== panel) continue;
        const u = out.get(e.port) ?? {};
        u[e.side === "rear" ? "rear" : "front"] = { device: far.device, port: far.port, cable: c };
        out.set(e.port, u);
      }
    }
  }
  return out;
}

export const isPatchPanel = (t: Topology, device: string): boolean => (t.devices ?? []).some((d) => d.name === device && d.recorded && d.kind === "patch-panel");

// The free ports of the recorded patch panels: neither side cabled (a split
// takes a port's front and its rear).
export function freePanelPorts(t: Topology): string[] {
  const cables = t.positions?.cables ?? [];
  return (t.devices ?? [])
    .filter((d) => d.recorded && d.kind === "patch-panel")
    .flatMap((d) => {
      const use = panelPortUse(cables, d.name);
      return (d.ports ?? []).filter((p) => !use.get(p)?.front && !use.get(p)?.rear).map((p) => `${d.name}:${p}`);
    });
}

// What a click on a patch panel's port selects: the link a wire on it belongs
// to (both its wires, through the port), else the free port itself.
export function panelPortSel(t: Topology, panel: string, port: string): Sel {
  const u = panelPortUse(t.positions?.cables ?? [], panel).get(port);
  const c = (u?.front ?? u?.rear)?.cable;
  return c ? { kind: "link", id: linkId(c.from.device, c.to.device), port: `${panel}:${port}` } : { kind: "panelport", id: port, panel };
}

// The links a free panel port could carry: each cable of its own (not split
// already, no panel at an end, no power), by the end the split starts from.
export function splittable(t: Topology): { end: string; text: string }[] {
  return (t.positions?.cables ?? [])
    .filter((c) => !c.segments?.length && c.kind !== "power" && !isPatchPanel(t, c.from.device) && !isPatchPanel(t, c.to.device))
    .map((c) => ({ end: `${c.from.device}:${c.from.port}`, text: `${c.from.device}:${c.from.port} — ${c.to.device}:${c.to.port}` }));
}

// ── state ─────────────────────────────────────────────────────────────
export interface DevState {
  state: CardState;
  reasons: string[];
  findings: TopoFinding[];
}

// A device's state: the findings on it (its own, its ports' and LAGs' for a
// switch), a drifting port, an uplink leg down, a buddy down.
export function deviceState(t: Topology, d: DevNode): DevState {
  let findings: TopoFinding[] = [];
  const extra: { level: "warn" | "fail"; text: string }[] = [];
  const on = (kind: string, name: string) => t.findings.filter((f) => f.on.kind === kind && f.on.name === name);
  switch (d.kind) {
    case "node": {
      findings = on("node", d.name);
      const n = t.nodes.find((x) => x.name === d.name);
      for (const u of n?.uplinks ?? []) for (const l of u.legs) if (!l.up) extra.push({ level: "warn", text: `${u.name} leg ${l.nic} is down` });
      break;
    }
    case "switch": {
      findings = t.findings.filter((f) => (f.on.kind === "switch" && f.on.name === d.name) || f.on.switch === d.name);
      const s = t.switches.find((x) => x.name === d.name);
      for (const p of s?.ports ?? []) if (p.drift === "drift") extra.push({ level: "warn", text: `port ${p.port} drifts: add ${p.add.join(",") || "-"}, remove ${p.remove.join(",") || "-"}` });
      break;
    }
    case "ap":
      findings = on("ap", d.name);
      break;
    case "isp":
      findings = on("site", "uplink");
      break;
    case "buddy": {
      findings = on("peer", d.name);
      const o = t.outside.find((x) => x.name === d.name);
      if (o?.state === "down") extra.push({ level: "warn", text: `${d.name} is down` });
      break;
    }
    default:
      findings = [...on("mount", d.name), ...t.findings.filter((f) => f.on.kind === "device" && f.on.name === d.name)];
  }
  const all = [...findings.map((f) => ({ level: f.level, text: `${f.gate}: ${f.text}` })), ...extra];
  return { state: stateOf(all.map((x) => x.level)), reasons: all.map((x) => x.text), findings };
}

// The device a selection is about (a port is its switch's, a LAG too).
export function selectedDevice(g: { nodes: DevNode[] }, s: Sel | null): string | null {
  if (!s) return null;
  if (s.kind === "port" || s.kind === "lag") return s.switch;
  if (s.kind === "link") return null;
  if (s.kind === "panelport") return s.panel;
  const n = g.nodes.find((x) => x.sel.kind === s.kind && x.sel.id === s.id);
  return n?.id ?? null;
}

// ── layout ────────────────────────────────────────────────────────────
// A force-directed layout around the selected device: it sits at the origin,
// the devices one link away on a ring around it, two links away on the next
// ring, and so on; links pull their ends together, devices push each other
// apart. Without a selection the best-connected device is the centre, but
// not held there. Deterministic: the same graph and start give the same
// picture. `from` is where the devices are now, so a new selection moves
// them from there.
export interface Pt {
  x: number;
  y: number;
}

const RING = 210;

function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return (h >>> 0) / 4294967296;
}

export function depths(ids: string[], links: { a: string; b: string }[], center: string): Map<string, number> {
  const adj = new Map<string, string[]>(ids.map((i) => [i, []]));
  for (const l of links) {
    adj.get(l.a)?.push(l.b);
    adj.get(l.b)?.push(l.a);
  }
  const d = new Map<string, number>([[center, 0]]);
  const q = [center];
  while (q.length) {
    const x = q.shift()!;
    for (const y of adj.get(x) ?? []) if (!d.has(y)) (d.set(y, d.get(x)! + 1), q.push(y));
  }
  const far = Math.max(0, ...d.values()) + 1;
  for (const i of ids) if (!d.has(i)) d.set(i, far);
  return d;
}

export function forceLayout(ids: string[], links: { a: string; b: string }[], center: string | null, from?: Map<string, Pt>): Map<string, Pt> {
  const deg = new Map(ids.map((i) => [i, links.filter((l) => l.a === i || l.b === i).length]));
  const hub = center ?? [...ids].sort((a, b) => deg.get(b)! - deg.get(a)! || a.localeCompare(b))[0];
  if (!hub) return new Map();
  const depth = depths(ids, links, hub);
  const pos = new Map<string, Pt>();
  for (const i of ids) {
    const p = from?.get(i);
    const a = hash(i) * 2 * Math.PI;
    const r = depth.get(i)! * RING;
    pos.set(i, p ? { ...p } : { x: r * Math.cos(a), y: r * Math.sin(a) });
  }
  // The new centre's neighbours start on its side of the old picture.
  const c0 = pos.get(hub)!;
  for (const p of pos.values()) (p.x -= c0.x), (p.y -= c0.y);
  const N = 320;
  for (let it = 0; it < N; it++) {
    const alpha = 1 - it / N;
    const f = new Map(ids.map((i) => [i, { x: 0, y: 0 }]));
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const p = pos.get(ids[i])!;
        const q = pos.get(ids[j])!;
        let dx = p.x - q.x;
        let dy = p.y - q.y;
        let d2 = dx * dx + dy * dy;
        if (d2 < 1) (dx = hash(ids[i] + ids[j]) - 0.5), (dy = 0.5 - hash(ids[j] + ids[i])), (d2 = 1);
        const d = Math.sqrt(d2);
        const k = Math.min(60, 26000 / d2);
        f.get(ids[i])!.x += (dx / d) * k;
        f.get(ids[i])!.y += (dy / d) * k;
        f.get(ids[j])!.x -= (dx / d) * k;
        f.get(ids[j])!.y -= (dy / d) * k;
      }
    }
    for (const l of links) {
      const p = pos.get(l.a);
      const q = pos.get(l.b);
      if (!p || !q) continue;
      const dx = q.x - p.x;
      const dy = q.y - p.y;
      const d = Math.max(1, Math.hypot(dx, dy));
      const k = (d - RING * 0.9) * 0.06;
      f.get(l.a)!.x += (dx / d) * k;
      f.get(l.a)!.y += (dy / d) * k;
      f.get(l.b)!.x -= (dx / d) * k;
      f.get(l.b)!.y -= (dy / d) * k;
    }
    for (const i of ids) {
      const p = pos.get(i)!;
      const r = Math.hypot(p.x, p.y);
      const want = depth.get(i)! * RING;
      // The rings: each device pulled to its distance from the centre.
      const k = center ? (want - r) * 0.12 : -r * 0.01;
      if (r > 0.5) (f.get(i)!.x += (p.x / r) * k), (f.get(i)!.y += (p.y / r) * k);
    }
    for (const i of ids) {
      if (i === hub && center) continue;
      const p = pos.get(i)!;
      const v = f.get(i)!;
      const step = Math.min(40, Math.hypot(v.x, v.y)) * alpha;
      const n = Math.hypot(v.x, v.y) || 1;
      p.x += (v.x / n) * step;
      p.y += (v.y / n) * step;
    }
    if (center) pos.set(hub, { x: 0, y: 0 });
  }
  return pos;
}
