// devicegraph.ts — the Device view as data: every physical device of the
// topology (the cluster nodes, the switches, the access points, the machines
// and devices a rack or a cable record names, the internet and the backup
// buddies) as one node, every pair of devices that a cable joins as one link
// with its cables, and each device's state from the findings on it. Plain
// data, no React: the unit tests run it over hrossen's topology.

import { RackCable, Topology, TopoFinding } from "../types";
import { Sel } from "./layout";
import { CardState, stateOf } from "./states";

export type DevKind = "node" | "switch" | "ap" | "isp" | "buddy" | "machine" | "device";

export interface DevNode {
  id: string;
  name: string;
  kind: DevKind;
  sel: Sel;
}

// One cable, as the topology resolves it or as recorded; the internet's and a
// buddy's links have none (a hand-off and a tunnel).
export type Cable = Pick<RackCable, "from" | "to" | "kind" | "source" | "zones" | "lag" | "up" | "label">;

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
  const add = (id: string, kind: DevKind, sel: Sel, name = id): void => {
    if (!nodes.has(id)) nodes.set(id, { id, name, kind, sel });
  };
  for (const s of t.switches) add(s.name, "switch", { kind: "switch", id: s.name });
  for (const n of t.nodes) add(n.name, "node", { kind: "node", id: n.name });
  for (const a of t.accessPoints) add(a.name, "ap", { kind: "ap", id: a.name });
  for (const d of t.devices ?? []) add(d.name, d.kind, { kind: "mount", id: d.name });
  for (const o of t.racks?.outside ?? []) add(o.device, "device", { kind: "mount", id: o.device });

  // The cables: the racks' list when the topology carries it (the topology's
  // own links and the recorded ones), else what the uplinks and the access
  // points say.
  const cables: Cable[] = t.racks
    ? t.racks.cables
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
  const n = g.nodes.find((x) => x.sel.kind === s.kind && x.sel.id === s.id);
  return n?.id ?? null;
}
