// vlanreach.ts — `health-manager vlan-reach`: does each zone's VLAN reach from
// every node to every other one?
//
// A zone's guests on two nodes talk over its VLAN, carried tagged through the
// switches between the nodes' LAN ports. A switch that does not carry it splits
// the zone, and nothing in the cluster's own view shows it until a guest moves.
//
// The probe, on every node at once, per active zone VLAN:
//   up     a VLAN interface tvr<vid> on the lan bridge (the bridge itself made a
//          member of the VLAN when it was not), IPv6 duplicate detection off; its
//          link-local address is the node's on that VLAN
//   ping   ping -6 to all-nodes (ff02::1) on it: who answers is who is reached
//   down   the interfaces removed, the bridge's membership put back as it was
// No IPv4 address, route or guest is touched; down runs whatever up and ping did.
//
// The result goes to TAPPAAS_VLAN_REACH_FILE (default
// /var/lib/tappaas/vlan-reach.json), where the console's Day 1 reads it.
//
// Exit: 0 every VLAN reaches every node (or one node); 2 a VLAN does not; 1 error.

import { readFileSync } from "fs";
import { join } from "path";
import { renameGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";
import { ClusterNode, clusterNodes } from "../../../lib/ts/src/nodes";
import { RemoteResult, ssh } from "../../../lib/ts/src/cluster";

export interface VlanReach {
  vid: number;
  zone: string;
  missing: { from: string; to: string }[]; // from does not reach to
}
export interface ReachResult {
  at: string;
  nodes: string[];
  vlans: VlanReach[];
  ok: boolean;
  error?: string;
  // Each node's LAN ports (MACs), for the instructions.
  lanPorts: Record<string, string[]>;
}

export const REACH_FILE = (): string => process.env.TAPPAAS_VLAN_REACH_FILE ?? "/var/lib/tappaas/vlan-reach.json";

// The active zone VLANs: a tag of their own (not the untagged mgmt), Active or Mandatory.
export function activeVlans(zones: Record<string, unknown>): { vid: number; zone: string }[] {
  const out: { vid: number; zone: string }[] = [];
  for (const [name, z] of Object.entries(zones)) {
    if (name.startsWith("_") || !z || typeof z !== "object") continue;
    const o = z as Record<string, unknown>;
    const vid = typeof o.vlantag === "number" ? o.vlantag : Number(o.vlantag);
    if (!Number.isInteger(vid) || vid < 2 || vid > 4094) continue;
    if (o.state !== "Active" && o.state !== "Mandatory") continue;
    out.push({ vid, zone: name });
  }
  return out.sort((a, b) => a.vid - b.vid);
}

const vidList = (vids: number[]): string => vids.join(" ");

export function upScript(vids: number[]): string {
  return [
    "set -u",
    `for v in ${vidList(vids)}; do`,
    '  i="tvr$v"',
    '  ip link show "$i" >/dev/null 2>&1 || ip link add link lan name "$i" type vlan id "$v" || continue',
    '  if ! bridge vlan show dev lan 2>/dev/null | grep -Eq "(^|[[:space:]])$v([[:space:]]|$)"; then bridge vlan add vid "$v" dev lan self && echo "SELF $v"; fi',
    '  sysctl -qw "net.ipv6.conf.$i.accept_dad=0" >/dev/null 2>&1 || true',
    '  ip link set "$i" up',
    "done",
    "sleep 2",
    `for v in ${vidList(vids)}; do echo "ADDR $v $(ip -6 -o addr show dev "tvr$v" scope link 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"; done`,
  ].join("\n");
}

export function pingScript(vids: number[]): string {
  return `for v in ${vidList(vids)}; do echo "SEEN $v $(ping -6 -c 2 -W 1 -I "tvr$v" ff02::1 2>/dev/null | grep -oE 'from fe80::[0-9a-f:]+' | awk '{print $2}' | sort -u | tr '\\n' ' ')"; done`;
}

export function downScript(vids: number[], self: number[]): string {
  return [
    `for v in ${vidList(vids)}; do ip link del "tvr$v" 2>/dev/null || true; done`,
    ...(self.length ? [`for v in ${vidList(self)}; do bridge vlan del vid "$v" dev lan self 2>/dev/null || true; done`] : []),
    "echo DOWN",
  ].join("\n");
}

// The lines a phase printed: ADDR/SEEN/SELF <vid> <rest>.
export function parseLines(out: string, tag: string): Map<number, string[]> {
  const m = new Map<number, string[]>();
  for (const line of out.split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (parts[0] !== tag || parts.length < 2) continue;
    m.set(Number(parts[1]), parts.slice(2).filter(Boolean));
  }
  return m;
}

// Who does not reach whom: node a reaches node b on a VLAN when b's address on it
// answered a's ping.
export function missingPairs(nodes: string[], addr: Map<string, string>, seen: Map<string, string[]>): { from: string; to: string }[] {
  const out: { from: string; to: string }[] = [];
  for (const a of nodes) {
    const got = new Set(seen.get(a) ?? []);
    for (const b of nodes) {
      if (a === b) continue;
      const ab = addr.get(b);
      if (!ab || !got.has(ab)) out.push({ from: a, to: b });
    }
  }
  return out;
}

export type Remote = (node: ClusterNode, script: string) => RemoteResult;
const viaSsh: Remote = (node, script) => ssh("root", node.address, script);

export function runVlanReach(configDir: string, remote: Remote = viaSsh, now = new Date()): ReachResult {
  const nodes = clusterNodes(configDir);
  const names = nodes.map((n) => n.name);
  const lanPorts = Object.fromEntries(nodes.map((n) => {
    const lan = (n.uplinks as { lan?: { ports?: unknown } } | undefined)?.lan?.ports;
    return [n.name, Array.isArray(lan) ? lan.filter((p): p is string => typeof p === "string") : []];
  }));
  const base = { at: now.toISOString(), nodes: names, lanPorts };
  let zones: Record<string, unknown> = {};
  try {
    zones = JSON.parse(readFileSync(join(configDir, "zones.json"), "utf8")) as Record<string, unknown>;
  } catch (e) {
    return { ...base, vlans: [], ok: false, error: `zones.json could not be read: ${(e as Error).message}` };
  }
  const vlans = activeVlans(zones);
  if (nodes.length < 2 || vlans.length === 0) return { ...base, vlans: vlans.map((v) => ({ ...v, missing: [] })), ok: true };
  const vids = vlans.map((v) => v.vid);

  const addr = new Map<number, Map<string, string>>(vids.map((v) => [v, new Map()]));
  const seen = new Map<number, Map<string, string[]>>(vids.map((v) => [v, new Map()]));
  const self = new Map<string, number[]>();
  const errors: string[] = [];
  try {
    for (const n of nodes) {
      const r = remote(n, upScript(vids));
      if (r.rc !== 0 && !r.stdout.includes("ADDR")) {
        errors.push(`${n.name}: ${r.stderr.trim() || `exit ${r.rc}`}`);
        continue;
      }
      self.set(n.name, [...parseLines(r.stdout, "SELF").keys()]);
      for (const [v, a] of parseLines(r.stdout, "ADDR")) if (a[0]) addr.get(v)?.set(n.name, a[0]);
    }
    for (const n of nodes) {
      const r = remote(n, pingScript(vids));
      for (const [v, s] of parseLines(r.stdout, "SEEN")) seen.get(v)?.set(n.name, s);
    }
  } finally {
    for (const n of nodes) remote(n, downScript(vids, self.get(n.name) ?? []));
  }
  if (errors.length) return { ...base, vlans: [], ok: false, error: `the probe could not start on ${errors.join("; ")}` };
  const out = vlans.map((v) => ({ ...v, missing: missingPairs(names, addr.get(v.vid)!, seen.get(v.vid)!) }));
  return { ...base, vlans: out, ok: out.every((v) => v.missing.length === 0) };
}

export function writeReach(r: ReachResult): void {
  const f = REACH_FILE();
  writeFileGuarded(`${f}.tmp`, `${JSON.stringify(r, null, 2)}\n`);
  renameGuarded(`${f}.tmp`, f);
}

// What to do when a VLAN does not cross: the ports that must carry it, and the
// easier way.
export function reachInstructions(r: ReachResult): string[] {
  const bad = r.vlans.filter((v) => v.missing.length);
  if (!bad.length) return [];
  const involved = [...new Set(bad.flatMap((v) => v.missing.flatMap((m) => [m.from, m.to])))].sort();
  return [
    `Carry VLAN${bad.length > 1 ? "s" : ""} ${bad.map((v) => `${v.vid} (${v.zone})`).join(", ")} tagged on the switch ports these nodes' LAN ports are cabled to, and on every link between those switches:`,
    ...involved.map((n) => `  ${n}: LAN port${(r.lanPorts[n] ?? []).length === 1 ? "" : "s"} ${(r.lanPorts[n] ?? []).join(", ") || "(not recorded)"}`),
    "Easier: bring the switches under management (Day 1 › Switch fabric, or Day 2 › Add a switch), and TAPPaaS sets these ports itself.",
  ];
}

export function reachLines(r: ReachResult): string[] {
  if (r.error) return [`✗ ${r.error}`];
  if (r.nodes.length < 2) return [`✓ one node (${r.nodes.join("") || "none"}): no VLAN crosses a switch`];
  return [
    ...r.vlans.map((v) => (v.missing.length
      ? `✗ VLAN ${v.vid} (${v.zone}): ${v.missing.map((m) => `${m.from} does not reach ${m.to}`).join("; ")}`
      : `✓ VLAN ${v.vid} (${v.zone}): every node reaches every other`)),
    ...reachInstructions(r),
  ];
}
