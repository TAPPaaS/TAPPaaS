// topology.ts — `network-manager topology` (ADR-034 D5): the physical site as one
// derived document. It JOINS what the managers and controllers already report —
// site.json, `site-manager node list / node network show`, `switch-manager
// list / list-ports / lag list`, `ap-manager list`, zones.json, `module-manager
// module list` (guests and their run state, read through lib/ts/cluster.ts),
// `backup-manager peers` and `health-manager validate` — and stores nothing.
//
// The sources name the same things differently, and the join is where they are
// reconciled:
//   - a switch is "USW Pro XG 10 PoE" in the switch inventory and
//     "USW-Pro-XG-10-PoE" in a node's LLDP: names compare canonically;
//   - a port is "11" in the inventory and "Port 11" in LLDP;
//   - a node's NIC is "nic3" on the node and the switch's targetPort may spell it
//     by name or by MAC: LLDP (live) wins, the inventory fills in;
//   - a node's wan uplink is a switch port of type `device` with that node as its
//     target; a `device` port in the wan zone with no target is the ISP hand-off.
// What does not reconcile is reported as a `topology` finding, not guessed away.
//
// buildTopology() is pure (the unit tests run it over hrossen's captured
// outputs); collectSources() runs the verbs.

import { join } from "path";
import { ExecResult, captureResult } from "../../../lib/ts/src/exec";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { WanAddress, readWanAddress, wanAddressFile } from "../../../lib/ts/src/wan-address";

// ── the sources, as their verbs print them ────────────────────────────

export interface NetPort {
  name: string;
  mac: string;
  state: string;
  speed: number;
  mtu: number;
  mii?: string;
  aggregator?: string;
  actorState?: number;
  partnerState?: number;
  lldp: { chassis?: string; name: string; port: string } | null;
}

// site-manager node network show <node> --json
export interface NodeNetwork {
  node: string;
  live: {
    ports: NetPort[];
    lan: { mtu?: number | null; bond?: string; mode?: string; aggregator?: string; partnerMac?: string; members: NetPort[] };
    wan?: { members: NetPort[] };
    lrmActive?: boolean;
    corosync?: { links: number; disconnected: number };
    lldpd?: string;
  };
  declared?: { lan?: { mode?: string; ports?: string[] }; wan?: { ports?: string[] } };
  findings?: { level: string; text: string }[];
}

// switch-manager list --json
export interface SwitchList {
  controllers: { name: string; vendor?: string; managementIp?: string; managed?: string }[];
  switches: {
    name: string; vendor?: string; model?: string; managementIp?: string; controller?: string;
    managed?: string; location?: string; description?: string; ports?: number;
  }[];
}

// switch-manager list-ports --json (one entry per switch)
export interface SwitchPortRow {
  port: string;
  type: string | null;
  target: string | null;
  targetPort: string | null;
  zone: string | null;
  description: string | null;
  mode: string;
  nativeVlan: number;
  taggedVlans: number[];
  desired: { mode: string; nativeVlan: number; taggedVlans: number[] } | null;
  drift: "in-sync" | "drift" | "unmanaged";
  add: number[];
  remove: number[];
  lag: string | null;
  lagMembers: number[];
  lagLead?: string | null; // the LAG's lead port this member follows (#854); absent from an older controller
  parked?: boolean; // a port TAPPaaS does not use: an access port in iotLocal (#853)
  link?: string | null; // "up" | "down", when the switch says
  disabled?: boolean;
}
export interface SwitchPorts {
  switch: string;
  ports: SwitchPortRow[];
}

// switch-manager lag list --json
export interface LagRow {
  switch: string;
  name: string;
  ports: string[];
  live: number[];
  formed: boolean;
}

// ap-manager list --json
export interface ApRow {
  name: string;
  vendor?: string;
  model?: string;
  managementIp?: string;
  location?: string;
  uplink: { switch: string; port: string } | null;
  ssids: { name: string; zone?: string; vlan?: number; security?: string; disabled?: boolean }[];
}

// module-manager module list --json → .modules
export interface ModuleRow {
  name: string;
  kind: string; // vm | lxc | application | machine
  vmname: string | null;
  vmid: number | null;
  node: string | null;
  zone0: string | null;
  stack: string | null;
  scope?: string | null;
  status: string | null; // maturity
  environment: string | null;
  running: string; // running | stopped | -
  actualNode: string | null;
}

// backup-manager peers --json
export interface PeerRow {
  name: string;
  role: string;
  remoteHost?: string | null;
  namespace?: string | null;
  physicalLocation?: { country?: string; city?: string } | null;
  tunnel?: string | null;
}

// health-manager validate --json
export interface HealthSubject {
  kind: string;
  name: string;
}
export interface HealthDoc {
  status: string;
  gates: { name: string; status: string; detail: string; findings: { status: string; text: string; subject: HealthSubject | null }[] }[];
}

export interface TopoSources {
  site: Record<string, unknown> | null;
  nodes: { name: string; storagePools?: string[] }[] | null;
  networks: Record<string, NodeNetwork | null>;
  switches: SwitchList | null;
  ports: SwitchPorts[] | null;
  lags: LagRow[] | null;
  accessPoints: ApRow[] | null;
  zones: Record<string, unknown> | null;
  modules: ModuleRow[] | null;
  peers: PeerRow[] | null;
  health: HealthDoc | null;
  firewall: Record<string, unknown> | null; // config/<firewall module>.json
  satellites: { name: string; address: string | null }[];
  wanAddress?: WanAddress | null; // what the WAN held at the last network update
  errors: { source: string; error: string }[];
}

// ── the document ──────────────────────────────────────────────────────

export type TopoKind = "site" | "node" | "switch" | "port" | "lag" | "ap" | "module" | "peer" | "zone" | "pool";
export interface TopoRef {
  kind: TopoKind;
  name: string;
  switch?: string; // for a port or a LAG
}

export interface TopoPeerPort {
  switch: string; // the inventory name when known, else what LLDP says
  port: string;
  known: boolean; // the switch is in the inventory
  via: "lldp" | "inventory";
}
export interface TopoLeg {
  nic: string;
  mac: string;
  speed: string | null;
  up: boolean;
  peer: TopoPeerPort | null;
}
export interface TopoUplink {
  name: "lan" | "wan";
  mode: string;
  bond: string | null;
  mtu: number | null;
  declared: { mode: string | null; ports: string[] } | null;
  legs: TopoLeg[];
}
export interface TopoGuest {
  module: string;
  vmid: number | null;
  kind: string;
  zone: string | null;
  environment: string | null;
  stack: string | null;
  maturity: string | null;
  state: string;
}
export interface TopoNode {
  name: string;
  kind: "cluster-member";
  storagePools: string[];
  roles: string[]; // firewall | mothership | backup — what its guests make it
  ha: { lrm: "active" | "idle" } | null;
  corosync: { links: number; disconnected: number } | null;
  lldpd: string | null;
  uplinks: TopoUplink[];
  guests: TopoGuest[];
}
export type PortRole = "node-lan" | "node-wan" | "isp" | "ap" | "switch" | "uplink" | "device" | "parked" | "unmanaged";
export interface TopoPort {
  port: string;
  role: PortRole;
  type: string | null;
  mode: string;
  native: number;
  tagged: number[];
  zones: string[]; // the zones its VLANs are, access VLAN first
  target: { kind: "node" | "ap" | "switch" | "device" | "isp"; name: string | null; port: string | null } | null;
  description: string | null;
  lag: string | null;
  lagLead: string | null; // a LAG member: the lead port whose VLANs it carries (#854)
  parked: boolean; // an access port in the park zone, TAPPaaS uses it for nothing (#853)
  link: string | null;
  drift: "in-sync" | "drift" | "unmanaged";
  add: number[];
  remove: number[];
  seen: { node: string; nic: string } | null; // who LLDP says is on the other end
}
export interface TopoLag {
  name: string;
  ports: string[];
  formed: boolean;
  live: string[];
  node: string | null;
  bond: string | null;
}
export interface TopoSwitch {
  name: string;
  lldpName: string | null;
  vendor: string | null;
  model: string | null;
  managementIp: string | null;
  managed: string | null;
  controller: string | null;
  controllerAddress: string | null; // the controller's management URL (UniFi OS …)
  ports: TopoPort[];
  lags: TopoLag[];
}
export interface TopoAp {
  name: string;
  vendor: string | null;
  model: string | null;
  address: string | null;
  uplink: { switch: string; port: string } | null;
  ssids: { name: string; zone: string | null; vlan: number | null; security: string | null; enabled: boolean }[];
}
export interface TopoZone {
  name: string;
  vlan: number | null;
  state: string | null;
  type: string | null;
  tier: number | null;
  bridge: string | null;
  ip: string | null;
  serves: string[];
}
export interface TopoOutside {
  kind: "buddy" | "satellite";
  name: string;
  role: string | null;
  location: string | null;
  tunnel: string | null;
  address: string | null;
  state: "up" | "down" | null; // from the pulse
}
export interface TopoFinding {
  gate: string;
  level: "fail" | "warn";
  text: string;
  on: TopoRef;
  refs: TopoRef[]; // further objects the finding concerns (a node's LAG and its ports)
}
export interface TopoWanPath {
  node: string;
  nic: string;
  switch: string | null;
  port: string | null;
  active: boolean; // the firewall runs on this node
}
export interface Topology {
  version: 1;
  generated: string;
  site: {
    name: string | null;
    displayName: string | null;
    wan: {
      publicIp: string | null;
      // The addresses the firewall's WAN held at the last network update: the
      // public address when publicIp is "auto" (unless private: behind a router).
      discovered: WanAddress | null;
      ipv6: boolean;
      isp: string | null;
      zone: string | null;
      vlan: number | null;
      handoff: { switch: string; port: string; description: string | null } | null;
      firewall: { module: string; vmid: number | null; node: string | null; standby: string | null } | null;
      paths: TopoWanPath[];
    };
  };
  nodes: TopoNode[];
  switches: TopoSwitch[];
  accessPoints: TopoAp[];
  zones: TopoZone[];
  outside: TopoOutside[];
  findings: TopoFinding[];
  sources: { name: string; ok: boolean; error?: string }[];
}

// ── reconciliation helpers ────────────────────────────────────────────

// Names compare without case, spaces or punctuation: "USW Pro XG 10 PoE" is
// "USW-Pro-XG-10-PoE", "tappaas1" is "TAPPAAS1".
export const canon = (s: string | null | undefined): string => (s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");

// LLDP spells a port "Port 11" (UniFi), "11", "Gi1/0/11" …: the trailing number.
export function lldpPort(p: string): string {
  const m = /(\d+)\s*$/.exec(p);
  return m ? m[1] : p;
}

const isMac = (s: string): boolean => /^[0-9a-f]{2}([:-]?[0-9a-f]{2}){5}$/i.test(s);
const sameMac = (a: string, b: string): boolean => canon(a) === canon(b);

// A switch's targetPort names the node's NIC by name or by MAC.
export function nicMatches(p: NetPort, targetPort: string | null): boolean {
  if (!targetPort) return false;
  if (p.name === targetPort) return true;
  return isMac(targetPort) && sameMac(p.mac, targetPort);
}

export function speedLabel(mbps: number): string | null {
  if (!Number.isFinite(mbps) || mbps <= 0) return null;
  if (mbps >= 1000) {
    const g = mbps / 1000;
    return `${Number.isInteger(g) ? g : g.toFixed(1)}G`;
  }
  return `${mbps}M`;
}

const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

// ── the join ──────────────────────────────────────────────────────────

const FIREWALL_MODULE = "network";
const MOTHERSHIP_MODULE = "tappaas-cicd";
const BACKUP_MODULE = "backup";

export function buildTopology(src: TopoSources, now: Date = new Date()): Topology {
  const findings: TopoFinding[] = [];
  const topoFinding = (text: string, on: TopoRef, refs: TopoRef[] = []): void => {
    findings.push({ gate: "topology", level: "warn", text, on, refs });
  };

  // Zones: the VLAN → zone name map every port's VLAN list is read through.
  const zones: TopoZone[] = [];
  for (const [name, raw] of Object.entries(src.zones ?? {})) {
    if (name.startsWith("_") || !raw || typeof raw !== "object") continue;
    const z = raw as Record<string, unknown>;
    const serves = Array.isArray(z.serves) ? z.serves.filter((x): x is string => typeof x === "string") : str(z.serves) ? [z.serves as string] : [];
    zones.push({
      name,
      vlan: num(z.vlantag),
      state: str(z.state),
      type: str(z.type),
      tier: num(z.tier),
      bridge: str(z.bridge),
      ip: str(z.ip),
      serves,
    });
  }
  const zoneByVlan = new Map<number, string>();
  for (const z of zones) {
    // vlan 0 is untagged (mgmt and the overlays): never a port's VLAN by number.
    if (z.vlan && z.vlan > 0 && !zoneByVlan.has(z.vlan)) zoneByVlan.set(z.vlan, z.name);
  }
  const wanZone = zones.find((z) => z.type === "WAN") ?? zones.find((z) => z.name === "wan") ?? null;

  // Switches from the inventory; LLDP names resolve to them canonically.
  const invSwitches = src.switches?.switches ?? [];
  const switchByCanon = new Map<string, string>();
  for (const s of invSwitches) switchByCanon.set(canon(s.name), s.name);
  const lldpNames = new Map<string, string>(); // inventory name → LLDP spelling seen
  const resolveSwitch = (lldpName: string): { name: string; known: boolean } => {
    const inv = switchByCanon.get(canon(lldpName));
    if (inv) {
      if (lldpName !== inv) lldpNames.set(inv, lldpName);
      return { name: inv, known: true };
    }
    return { name: lldpName, known: false };
  };
  const portsBySwitch = new Map<string, SwitchPortRow[]>();
  for (const sp of src.ports ?? []) portsBySwitch.set(sp.switch, sp.ports);

  // Site nodes: site-manager's list, else site.json's, else whatever reported.
  const siteNodes = (src.nodes ?? siteJsonNodes(src.site)).map((n) => ({ name: n.name, storagePools: n.storagePools ?? [] }));
  for (const n of Object.keys(src.networks)) {
    if (!siteNodes.some((x) => x.name === n)) siteNodes.push({ name: n, storagePools: [] });
  }
  const nodeByCanon = new Map<string, string>();
  for (const n of siteNodes) nodeByCanon.set(canon(n.name), n.name);

  // Legs, and who LLDP says sits on each switch port.
  const seenAt = new Map<string, { node: string; nic: string }>(); // `${switch}\0${port}`
  const key = (sw: string, port: string): string => `${sw}\u0000${port}`;
  const legOf = (node: string, p: NetPort): TopoLeg => {
    let peer: TopoPeerPort | null = null;
    if (p.lldp && p.lldp.name) {
      const sw = resolveSwitch(p.lldp.name);
      peer = { switch: sw.name, port: lldpPort(p.lldp.port), known: sw.known, via: "lldp" };
      seenAt.set(key(peer.switch, peer.port), { node, nic: p.name });
    } else {
      // No LLDP answer: the switch inventory may still name this NIC.
      for (const [sw, rows] of portsBySwitch) {
        const r = rows.find((x) => canon(x.target) === canon(node) && nicMatches(p, x.targetPort));
        if (r) {
          peer = { switch: sw, port: r.port, known: true, via: "inventory" };
          break;
        }
      }
    }
    return { nic: p.name, mac: p.mac, speed: speedLabel(p.speed), up: p.state === "up", peer };
  };

  const nodes: TopoNode[] = siteNodes.map((n) => {
    const net = src.networks[n.name] ?? null;
    const uplinks: TopoUplink[] = [];
    if (net) {
      const lan = net.live.lan;
      const decl = net.declared?.lan;
      uplinks.push({
        name: "lan",
        mode: lan.mode || decl?.mode || "single",
        bond: str(lan.bond),
        mtu: num(lan.mtu),
        declared: decl ? { mode: str(decl.mode), ports: decl.ports ?? [] } : null,
        legs: (lan.members ?? []).map((p) => legOf(n.name, p)),
      });
      const wan = net.live.wan?.members ?? [];
      const wdecl = net.declared?.wan;
      if (wan.length > 0 || (wdecl?.ports ?? []).length > 0) {
        uplinks.push({
          name: "wan",
          mode: "single",
          bond: null,
          mtu: wan[0]?.mtu ?? null,
          declared: wdecl ? { mode: null, ports: wdecl.ports ?? [] } : null,
          legs: wan.map((p) => legOf(n.name, p)),
        });
      }
    }
    return {
      name: n.name,
      kind: "cluster-member",
      storagePools: n.storagePools,
      roles: [],
      ha: net && typeof net.live.lrmActive === "boolean" ? { lrm: net.live.lrmActive ? "active" : "idle" } : null,
      corosync: net?.live.corosync ?? null,
      lldpd: net ? str(net.live.lldpd) : null,
      uplinks,
      guests: [],
    };
  });
  const nodeNamed = (name: string | null): TopoNode | undefined => (name ? nodes.find((x) => canon(x.name) === canon(name)) : undefined);

  // Guests: every deployed module that runs somewhere, where it runs now.
  const guestNode = new Map<string, string>();
  for (const m of src.modules ?? []) {
    if (m.kind === "machine") continue;
    const where = m.actualNode ?? m.node;
    const node = nodeNamed(where);
    if (!node) continue;
    guestNode.set(m.name, node.name);
    node.guests.push({
      module: m.name,
      vmid: m.vmid,
      kind: m.kind,
      zone: m.zone0,
      environment: m.environment,
      stack: m.stack,
      maturity: m.status,
      state: m.running,
    });
  }
  for (const node of nodes) {
    node.guests.sort((a, b) => (a.vmid ?? 1e9) - (b.vmid ?? 1e9) || a.module.localeCompare(b.module));
    const has = (mod: string): boolean => node.guests.some((g) => g.module === mod);
    if (has(FIREWALL_MODULE)) node.roles.push("firewall");
    if (has(MOTHERSHIP_MODULE)) node.roles.push("mothership");
    if (has(BACKUP_MODULE)) node.roles.push("backup");
  }

  // Switches and their ports, reconciled against the legs.
  const apByCanon = new Map<string, string>();
  for (const a of src.accessPoints ?? []) apByCanon.set(canon(a.name), a.name);
  const switches: TopoSwitch[] = invSwitches.map((s) => {
    const rows = followLeads(portsBySwitch.get(s.name) ?? []);
    const ports: TopoPort[] = rows.map((r) => portOf(s.name, r));
    const lags: TopoLag[] = (src.lags ?? [])
      .filter((l) => l.switch === s.name)
      .map((l) => {
        const members = ports.filter((p) => l.ports.includes(p.port));
        const owners = [...new Set(members.map((p) => (p.target?.kind === "node" ? p.target.name : null)).filter((x): x is string => !!x))];
        const owner = owners.length === 1 ? owners[0] : null;
        const bond = owner ? (nodeNamed(owner)?.uplinks.find((u) => u.name === "lan")?.bond ?? null) : null;
        return { name: l.name, ports: l.ports, formed: l.formed, live: l.live.map(String), node: owner, bond };
      });
    return {
      name: s.name,
      lldpName: lldpNames.get(s.name) ?? null,
      vendor: str(s.vendor),
      model: str(s.model),
      managementIp: str(s.managementIp),
      managed: str(s.managed),
      controller: str(s.controller),
      controllerAddress: str(src.switches?.controllers.find((c) => c.name === s.controller)?.managementIp),
      ports,
      lags,
    };
  });

  // A LAG member follows its lead (#854): UniFi takes an aggregate's VLANs from
  // the lead port, so the member carries the lead's VLANs and no drift of its
  // own. switch-manager names the lead (lagLead); for one that predates it,
  // the lead is the LAG's lowest-numbered port, as \`lag set\` declares it.
  function followLeads(rows: SwitchPortRow[]): SwitchPortRow[] {
    const byPort = new Map(rows.map((r) => [r.port, r]));
    const leadOf = (r: SwitchPortRow): string | null => {
      if (r.lagLead !== undefined) return r.lagLead;
      if (!r.lag) return null;
      const first = rows.filter((x) => x.lag === r.lag).map((x) => x.port).sort((a, b) => Number(a) - Number(b))[0];
      return first !== r.port ? first : null;
    };
    return rows.map((r) => {
      const lead = leadOf(r);
      const l = lead !== null ? byPort.get(lead) : undefined;
      if (lead === null) return { ...r, lagLead: null };
      if (!l) return { ...r, lagLead: lead };
      return { ...r, lagLead: lead, mode: l.mode, nativeVlan: l.nativeVlan, taggedVlans: l.taggedVlans, desired: l.desired,
        drift: r.drift === "unmanaged" ? r.drift : "in-sync", add: [], remove: [] };
    });
  }

  function portOf(sw: string, r: SwitchPortRow): TopoPort {
    const seen = seenAt.get(key(sw, r.port)) ?? null;
    const vlans = r.mode === "access" ? [r.nativeVlan] : r.taggedVlans;
    const zonesOn = vlans.map((v) => zoneByVlan.get(v)).filter((x): x is string => !!x);
    const ref: TopoRef = { kind: "port", name: r.port, switch: sw };
    let target: TopoPort["target"] = null;
    let role: PortRole = "unmanaged";
    const targetNode = nodeNamed(r.target);
    if (targetNode) {
      // The node's own name for the NIC: LLDP first, then name or MAC.
      const net = src.networks[targetNode.name];
      let nic: string | null = null;
      if (seen && seen.node === targetNode.name) nic = seen.nic;
      else if (net) nic = net.live.ports.find((p) => nicMatches(p, r.targetPort))?.name ?? null;
      if (!nic) nic = r.targetPort;
      const seenNic = seen && seen.node === targetNode.name ? seen.nic : null;
      const spelledAsSeen = (p: NetPort): boolean => p.name === seenNic && nicMatches(p, r.targetPort);
      if (seenNic && r.targetPort && seenNic !== r.targetPort && !(net && net.live.ports.some(spelledAsSeen))) {
        topoFinding(`the switch records ${targetNode.name}/${r.targetPort} on port ${r.port}; LLDP from ${targetNode.name} says ${seenNic}`, ref, [{ kind: "node", name: targetNode.name }]);
      }
      target = { kind: "node", name: targetNode.name, port: nic };
      const onWan = (net?.live.wan?.members ?? []).some((p) => p.name === nic) || (wanZone !== null && r.zone === wanZone.name);
      role = r.type === "node" ? "node-lan" : onWan ? "node-wan" : r.type === "device" ? "device" : "node-lan";
    } else if (r.type === "ap") {
      target = { kind: "ap", name: apByCanon.get(canon(r.target)) ?? r.target, port: null };
      role = "ap";
    } else if (r.type === "switch" || r.type === "uplink") {
      target = { kind: "switch", name: r.target, port: r.targetPort };
      role = r.type;
    } else if (r.type === "device") {
      const isp = !r.target && wanZone !== null && (r.zone === wanZone.name || (r.mode === "access" && r.nativeVlan === wanZone.vlan));
      target = isp ? { kind: "isp", name: null, port: null } : { kind: "device", name: r.target, port: r.targetPort };
      role = isp ? "isp" : "device";
    } else if (r.type === "node" && r.target) {
      topoFinding(`port ${r.port} names node ${r.target}, which is not a site node`, ref);
      target = { kind: "node", name: r.target, port: r.targetPort };
      role = "node-lan";
    } else if (r.parked) {
      role = "parked";
    }
    if (seen && target?.kind !== "node") {
      topoFinding(`LLDP from ${seen.node}/${seen.nic} reaches port ${r.port}, which the switch inventory does not give to ${seen.node}`, ref, [{ kind: "node", name: seen.node }]);
    } else if (seen && target?.kind === "node" && target.name !== seen.node) {
      topoFinding(`the switch gives port ${r.port} to ${target.name}; LLDP says ${seen.node}/${seen.nic} is there`, ref, [{ kind: "node", name: seen.node }]);
    }
    if (r.drift === "drift") {
      findings.push({
        gate: "switch-drift",
        level: "warn",
        text: r.desired?.mode === "trunk"
          ? `port ${r.port} drifts from zones.json: add ${r.add.join(",") || "-"}, remove ${r.remove.join(",") || "-"} — network-manager reconcile`
          : `port ${r.port} carries vlan ${r.nativeVlan}, zones.json wants ${r.desired?.nativeVlan} — network-manager reconcile`,
        on: ref,
        refs: [],
      });
    }
    return {
      port: r.port,
      role,
      type: r.type,
      mode: r.mode,
      native: r.nativeVlan,
      tagged: r.taggedVlans,
      zones: zonesOn,
      target,
      description: r.description,
      lag: r.lag,
      lagLead: r.lagLead ?? null,
      parked: r.parked === true,
      link: r.link ?? null,
      drift: r.drift,
      add: r.add,
      remove: r.remove,
      seen,
    };
  }

  // A leg LLDP placed on a switch the inventory does not hold.
  for (const n of nodes) {
    for (const u of n.uplinks) {
      for (const l of u.legs) {
        if (l.peer && !l.peer.known) {
          topoFinding(`${n.name}/${l.nic} reaches "${l.peer.switch}" port ${l.peer.port}, a switch not in the inventory — switch-manager add-switch`, { kind: "node", name: n.name });
        }
      }
    }
  }

  const accessPoints: TopoAp[] = (src.accessPoints ?? []).map((a) => ({
    name: a.name,
    vendor: str(a.vendor),
    model: str(a.model),
    address: str(a.managementIp),
    uplink: a.uplink ? { switch: resolveSwitch(a.uplink.switch).name, port: a.uplink.port } : null,
    ssids: (a.ssids ?? []).map((s) => ({
      name: s.name,
      zone: str(s.zone),
      vlan: num(s.vlan),
      security: str(s.security),
      enabled: s.disabled !== true,
    })),
  }));

  // The pulse's word on each buddy (validate's pulse gate, subject peer).
  const pulseState = new Map<string, "up" | "down">();
  for (const f of src.health?.gates.find((g) => g.name === "pulse")?.findings ?? []) {
    if (f.subject?.kind === "peer") pulseState.set(f.subject.name, f.status === "pass" ? "up" : "down");
  }
  const outside: TopoOutside[] = [
    ...(src.peers ?? []).map((p): TopoOutside => ({
      kind: "buddy",
      name: p.name,
      role: str(p.role),
      location: [p.physicalLocation?.city, p.physicalLocation?.country].filter((x) => !!x).join(", ") || null,
      tunnel: str(p.tunnel),
      address: str(p.remoteHost),
      state: pulseState.get(p.name) ?? null,
    })),
    ...src.satellites.map((s): TopoOutside => ({
      kind: "satellite", name: s.name, role: null, location: null, tunnel: null, address: s.address, state: null,
    })),
  ];

  // Health findings, on the object each names (warn and fail only).
  for (const g of src.health?.gates ?? []) {
    for (const f of g.findings) {
      if ((f.status !== "fail" && f.status !== "warn") || !f.subject) continue;
      const on = refOf(f.subject);
      if (!on) continue;
      const refs: TopoRef[] = [];
      if (g.name === "lan-uplink" && on.kind === "node") {
        // A lan-uplink finding is about the node's bond: put it on its LAG and the
        // switch ports its legs land on, where the physical view draws them.
        for (const s of switches) for (const l of s.lags) if (l.node === on.name) refs.push({ kind: "lag", name: l.name, switch: s.name });
        for (const u of nodeNamed(on.name)?.uplinks ?? []) {
          if (u.name !== "lan") continue;
          for (const l of u.legs) if (l.peer) refs.push({ kind: "port", name: l.peer.port, switch: l.peer.switch });
        }
      }
      if (on.kind === "module") {
        const n = guestNode.get(on.name);
        if (n) refs.push({ kind: "node", name: n });
      }
      findings.push({ gate: g.name, level: f.status as "fail" | "warn", text: f.text.replace(/\s+/g, " ").trim(), on, refs });
    }
  }

  // The WAN path: the ISP hand-off, each node's wan port, the firewall.
  let handoff: Topology["site"]["wan"]["handoff"] = null;
  for (const s of switches) {
    const p = s.ports.find((x) => x.role === "isp");
    if (p) {
      handoff = { switch: s.name, port: p.port, description: p.description };
      break;
    }
  }
  const fwRow = (src.modules ?? []).find((m) => m.name === FIREWALL_MODULE) ?? null;
  const fwNode = fwRow ? (fwRow.actualNode ?? fwRow.node) : str(src.firewall?.node);
  const paths: TopoWanPath[] = [];
  for (const n of nodes) {
    for (const l of n.uplinks.find((u) => u.name === "wan")?.legs ?? []) {
      paths.push({ node: n.name, nic: l.nic, switch: l.peer?.switch ?? null, port: l.peer?.port ?? null, active: canon(n.name) === canon(fwNode) });
    }
  }
  const net = (src.site?.network ?? {}) as Record<string, unknown>;

  return {
    version: 1,
    generated: now.toISOString(),
    site: {
      name: str(src.site?.name),
      displayName: str(src.site?.displayName),
      wan: {
        publicIp: str(net.publicIp),
        discovered: src.wanAddress ?? null,
        ipv6: src.site?.ipv6 === true,
        isp: str(net.isp),
        zone: wanZone?.name ?? null,
        vlan: wanZone?.vlan ?? null,
        handoff,
        firewall: fwRow || src.firewall
          ? { module: FIREWALL_MODULE, vmid: fwRow?.vmid ?? num(src.firewall?.vmid), node: fwNode, standby: str(src.firewall?.HANode) }
          : null,
        paths,
      },
    },
    nodes,
    switches,
    accessPoints,
    zones,
    outside,
    findings,
    sources: SOURCE_NAMES.map((name) => {
      const e = src.errors.find((x) => x.source === name);
      return e ? { name, ok: false, error: e.error } : { name, ok: true };
    }),
  };

  function refOf(s: HealthSubject): TopoRef | null {
    switch (s.kind) {
      case "node":
        return { kind: "node", name: nodeNamed(s.name)?.name ?? s.name };
      case "module":
        return { kind: "module", name: s.name };
      case "peer":
        return { kind: "peer", name: s.name };
      case "pool":
        return { kind: "pool", name: s.name };
      case "site":
        return { kind: "site", name: s.name };
      case "port": {
        // "<switch>:<port>" (validate's switch-ports gate); a switch name may hold ":".
        const i = s.name.lastIndexOf(":");
        return i > 0 ? { kind: "port", name: s.name.slice(i + 1), switch: switchByCanon.get(canon(s.name.slice(0, i))) ?? s.name.slice(0, i) } : null;
      }
      default:
        return null;
    }
  }
}

function siteJsonNodes(site: Record<string, unknown> | null): { name: string; storagePools?: string[] }[] {
  const hw = (site?.hardware ?? {}) as Record<string, unknown>;
  const list = Array.isArray(hw.nodes) ? hw.nodes : [];
  return list
    .map((n) => n as Record<string, unknown>)
    .filter((n) => typeof n.name === "string")
    .map((n) => ({ name: n.name as string, storagePools: Array.isArray(n.storagePools) ? (n.storagePools as string[]) : [] }));
}

// ── reading the sources ───────────────────────────────────────────────

export const SOURCE_NAMES = [
  "site.json",
  "site-manager node list",
  "site-manager node network show",
  "switch-manager list",
  "switch-manager list-ports",
  "switch-manager lag list",
  "ap-manager list",
  "zones.json",
  "module-manager module list",
  "backup-manager peers",
  "health-manager validate",
  "wan-address.json",
];

export type Runner = (bin: string, args: string[]) => ExecResult;

export interface CollectOpts {
  configDir: string;
  zonesFile: string;
  // A validate --json the caller already holds (the console's cache); null skips
  // health findings; undefined runs health-manager validate --json.
  health?: HealthDoc | null;
  run?: Runner;
  wanAddressFile?: string; // default $TAPPAAS_WAN_ADDRESS_FILE or /var/lib/tappaas/wan-address.json
}

export function collectSources(o: CollectOpts): TopoSources {
  const run = o.run ?? captureResult;
  const errors: { source: string; error: string }[] = [];
  const json = <T>(source: string, bin: string, args: string[], okRcs: number[] = [0]): T | null => {
    const r = run(bin, args);
    if (!r.ran) {
      errors.push({ source, error: `${bin} not found` });
      return null;
    }
    try {
      const v = JSON.parse(r.stdout) as T;
      if (!okRcs.includes(r.rc)) errors.push({ source, error: `exit ${r.rc}` });
      return v;
    } catch {
      errors.push({ source, error: `exit ${r.rc}: ${(r.stderr || r.stdout).trim().split("\n").slice(-1)[0] ?? "no JSON"}` });
      return null;
    }
  };
  const file = (source: string, path: string): Record<string, unknown> | null => {
    try {
      const v = readJsonObject(path);
      if (!v) errors.push({ source, error: `${path} not found` });
      return v;
    } catch (e) {
      errors.push({ source, error: (e as Error).message });
      return null;
    }
  };

  const site = file("site.json", join(o.configDir, "site.json"));
  const nodes = json<{ name: string; storagePools?: string[] }[]>("site-manager node list", "site-manager", ["node", "list", "--json"]);
  const names = (nodes ?? siteJsonNodes(site)).map((n) => n.name);
  const networks: Record<string, NodeNetwork | null> = {};
  for (const n of names) {
    networks[n] = json<NodeNetwork>("site-manager node network show", "site-manager", ["node", "network", "show", n, "--json"]);
  }
  const modulesDoc = json<{ modules: ModuleRow[] }>("module-manager module list", "module-manager", ["module", "list", "--json"]);
  const modules = modulesDoc?.modules ?? null;
  let health: HealthDoc | null = o.health === undefined ? null : o.health;
  if (o.health === undefined) {
    // validate exits 1 when a gate fails; its document is complete either way.
    health = json<HealthDoc>("health-manager validate", "health-manager", ["validate", "--json"], [0, 1]);
  }
  // A satellite is a machine module of the satellite kind (ADR-010).
  const satellites: { name: string; address: string | null }[] = [];
  for (const m of (modules ?? []).filter((x) => x.kind === "machine")) {
    let cfg: Record<string, unknown> | null = null;
    try {
      cfg = readJsonObject(join(o.configDir, `${m.name}.json`));
    } catch {
      cfg = null;
    }
    if (/\/satellite\/?$/.test(String(cfg?.moduleSource ?? ""))) satellites.push({ name: m.name, address: str(cfg?.address) });
  }
  let firewall: Record<string, unknown> | null = null;
  try {
    firewall = readJsonObject(join(o.configDir, `${FIREWALL_MODULE}.json`));
  } catch {
    firewall = null;
  }
  // No record is not an error: the network update writes it (none yet, or the
  // WAN held no address).
  let wanAddress: WanAddress | null = null;
  try {
    wanAddress = readWanAddress(o.wanAddressFile ?? wanAddressFile());
  } catch (e) {
    errors.push({ source: "wan-address.json", error: (e as Error).message });
  }
  return {
    site,
    nodes,
    networks,
    switches: json<SwitchList>("switch-manager list", "switch-manager", ["list", "--json"]),
    ports: json<SwitchPorts[]>("switch-manager list-ports", "switch-manager", ["list-ports", "--json"]),
    lags: json<LagRow[]>("switch-manager lag list", "switch-manager", ["lag", "list", "--json"]),
    accessPoints: json<ApRow[]>("ap-manager list", "ap-manager", ["list", "--json"]),
    zones: file("zones.json", o.zonesFile),
    modules,
    peers: json<PeerRow[]>("backup-manager peers", "backup-manager", ["peers", "--json"]),
    health,
    firewall,
    satellites,
    wanAddress,
    errors,
  };
}

// ── the text view ─────────────────────────────────────────────────────

export function renderTopology(t: Topology): string[] {
  const out: string[] = [];
  const w = t.site.wan;
  out.push(`Site ${t.site.name ?? "?"}`);
  const fw = w.firewall ? `firewall ${w.firewall.module}${w.firewall.vmid ? ` (VM ${w.firewall.vmid})` : ""} on ${w.firewall.node ?? "?"}` : "no firewall module";
  out.push(
    `  WAN    ${w.handoff ? `ISP → ${w.handoff.switch} port ${w.handoff.port}` : "ISP hand-off not on a registered switch port"}` +
      `${w.vlan ? `, vlan ${w.vlan}` : ""}; ${fw}`,
  );
  const held = w.discovered;
  out.push(
    `         public address ${w.publicIp ?? "(unset)"}` +
      (held?.ipv4 ? `; the WAN holds ${held.ipv4}${held.private ? " (private: behind another router)" : ""}${held.observed ? ` (${held.observed})` : ""}` : ""),
  );
  for (const p of w.paths) {
    out.push(`         ${p.active ? "*" : " "} ${p.node}/${p.nic}${p.port ? ` ← ${p.switch} port ${p.port}` : " (no switch port known)"}`);
  }
  out.push("", "Nodes");
  for (const n of t.nodes) {
    const ups = n.uplinks
      .map((u) => `${u.name} ${u.mode}${u.bond ? ` ${u.bond}` : ""} ${u.legs.map((l) => `${l.nic}${l.speed ? `@${l.speed}` : ""}${l.up ? "" : "(down)"}→${l.peer ? `${l.peer.port}` : "?"}`).join(" ")}`)
      .join("; ");
    out.push(`  ${n.name.padEnd(12)}${ups || "(no network report)"}`);
    out.push(`  ${"".padEnd(12)}${n.guests.length} guest(s)${n.roles.length ? ` — ${n.roles.join(", ")}` : ""}`);
  }
  out.push("", "Switches");
  for (const s of t.switches) {
    out.push(`  ${s.name}${s.lldpName ? ` (LLDP: ${s.lldpName})` : ""}  [${s.vendor ?? "?"}] ${s.managed ?? ""}  ${s.ports.length} port(s)`);
    for (const p of s.ports) {
      const tgt = p.target ? `${p.target.kind}${p.target.name ? ` ${p.target.name}` : ""}${p.target.port ? `/${p.target.port}` : ""}` : "—";
      const vl = p.mode === "access" ? `access ${p.native}` : `trunk ${p.tagged.length}`;
      out.push(`    ${p.port.padStart(3)}  ${p.role.padEnd(10)}${tgt.padEnd(26)}${vl.padEnd(12)}${p.drift}${p.lag ? `  LAG ${p.lag}` : ""}`);
    }
    for (const l of s.lags) out.push(`    LAG ${l.name}: ports ${l.ports.join("+")} ${l.formed ? "formed" : "not formed"}${l.node ? ` — ${l.node}${l.bond ? ` ${l.bond}` : ""}` : ""}`);
  }
  if (t.accessPoints.length) {
    out.push("", "Access points");
    for (const a of t.accessPoints) out.push(`  ${a.name}  ${a.address ?? "-"}  uplink ${a.uplink ? `${a.uplink.switch}:${a.uplink.port}` : "-"}  ssids ${a.ssids.length}`);
  }
  if (t.outside.length) {
    out.push("", "Outside");
    for (const o of t.outside) out.push(`  ${o.kind.padEnd(10)}${o.name}${o.location ? ` (${o.location})` : ""}${o.state ? `  ${o.state}` : ""}`);
  }
  if (t.findings.length) {
    out.push("", "Findings");
    for (const f of t.findings) out.push(`  [${f.level.toUpperCase()}] ${f.gate}: ${f.on.kind} ${f.on.name}${f.on.switch ? `@${f.on.switch}` : ""} — ${f.text}`);
  }
  const bad = t.sources.filter((s) => !s.ok);
  if (bad.length) {
    out.push("", "Sources that did not answer");
    for (const s of bad) out.push(`  ${s.name}: ${s.error}`);
  }
  return out;
}
