// topology.ts — `network-manager topology` (ADR-034 D5): the physical site as one
// derived document. It JOINS what the managers and controllers already report —
// site.json, `site-manager node list / node network show`, `switch-manager
// list / list-ports / lag list`, `ap-manager list`, zones.json, `module-manager
// module list` (guests and their run state, read through lib/ts/cluster.ts),
// `backup-manager peers`, `health-manager validate` and `position-manager
// export` — and stores nothing. The positions (position-manager's
// config/positions.json and its faceplate catalog) are resolved here against
// the devices and links found: the site's locations with their rooms and
// racks, each placement on its device and plate, every link on faceplate
// ports. Every device carries its location, its placement and the record it
// came from (ADR-036 D4); a device a switch port sees that no record names is
// listed as seen, at the switch's location.
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
// An MLAG pair (two MikroTik switches presenting one LACP partner) and the LAGs
// across it come from switch-manager's switch-configuration-actual.json: the pair
// and its peer link, which ports are the peer link's members, and each port's
// mlag-id. A LAG across the pair is drawn once, under the pair; its members'
// live state (disabled, link) decides whether it is formed.
//
// buildTopology() is pure (the unit tests run it over hrossen's captured
// outputs); collectSources() runs the verbs.

import { join } from "path";
import { ExecResult, captureResult } from "../../../lib/ts/src/exec";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { WanAddress, readWanAddress, wanAddressFile } from "../../../lib/ts/src/wan-address";
import { Faceplate, PositionsDoc, PositionsView, RecordedKind, cablesOf, placementsOf, recordedPorts, resolvePositions, roomOf } from "../../../lib/ts/src/positions";
import { readLocations } from "../../../lib/ts/src/locations";

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
    mlag?: { peerPort?: string; bridge?: string } | null;
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
  lagMembers: (number | string)[]; // port ids: numbers on UniFi, names on MikroTik
  lagLead?: string | null; // the LAG's lead port this member follows (#854); absent from an older controller
  parked?: boolean; // a port TAPPaaS does not use: an access port in iotLocal (#853)
  link?: string | null; // "up" | "down", when the switch says
  disabled?: boolean;
  // What the controller reports behind the port (its MAC table, LLDP, the
  // lease it saw); absent from a controller that does not report it.
  neighbors?: PortNeighbor[];
}
export interface PortNeighbor {
  mac: string;
  lldp?: { name?: string | null; port?: string | null } | null;
  lease?: { hostname?: string | null; address?: string | null } | null;
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
  live: (number | string)[];
  formed: boolean;
  mlagId?: number | null;
}

// ~/config/switch-configuration-actual.json (switch-manager), the parts read here
export interface ActualPort {
  lag?: string | null;
  mlagId?: number | null;
  liveMlagId?: number | null;
  peerLink?: boolean; // a member of the MLAG peer link
  bridged?: boolean; // false: not on the switch's bridge (MikroTik ether1)
  disabled?: boolean;
  bond?: string;
}
export interface SwitchActual {
  mlagPairs?: Record<string, { switches?: string[]; peerPort?: Record<string, string> }>;
  switches?: Record<string, { mlag?: { peerPort?: string; bridge?: string } | null; ports?: Record<string, ActualPort> }>;
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
  // Where it is: the location it names and that location's place (ADR-036
  // D5); a peer migration 0019 has not reached carries physicalLocation.
  location?: string | null;
  place?: { country?: string; city?: string } | null;
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
  satellites: { name: string; address: string | null; location?: string | null }[];
  // Each machine module's location name (ADR-036 D2): a cluster node's pvehost
  // instance, a satellite, an adopted host. Absent: at the primary location.
  machineLocations?: Record<string, string>;
  wanAddress?: WanAddress | null; // what the WAN held at the last network update
  actual?: SwitchActual | null; // switch-configuration-actual.json: MLAG pairs, peer links
  // position-manager export --json; undefined: not read (--no-positions), null: it did not answer
  positions?: { doc: PositionsDoc; catalog: Faceplate[] } | null;
  errors: { source: string; error: string }[];
}

// ── the document ──────────────────────────────────────────────────────

export type TopoKind = "site" | "node" | "switch" | "port" | "lag" | "ap" | "module" | "peer" | "zone" | "pool" | "rack";
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
// Where a device is (ADR-036): the location it is at, and its placement in a
// room — in a rack at a unit, or loose (rack and u null); null: placed nowhere.
export interface TopoPlacement {
  room: string | null;
  rack: string | null;
  u: number | null;
}
// The record a device comes from.
export type DeviceSource = "cluster" | "module" | "switch-configuration" | "recorded" | "seen";
export interface TopoPlace {
  location: string | null;
  placement: TopoPlacement | null;
  source: DeviceSource;
}
export interface TopoNode extends TopoPlace {
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
export type PortRole = "node-lan" | "node-wan" | "isp" | "ap" | "switch" | "uplink" | "device" | "parked" | "peer-link" | "unmanaged";
// What the port is now: its drift, unless it is a peer-link member or disabled.
export type PortStatus = "in-sync" | "drift" | "unmanaged" | "disabled" | "peer-link";
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
  status: PortStatus;
  disabled: boolean; // admin-disabled (or, unmanaged, off the bridge)
  peerLink: boolean; // a member of the MLAG peer link
  bridged: boolean | null; // false: not on the switch's bridge; null: not known
  mlagId: number | null; // declared
  add: number[];
  remove: number[];
  seen: { node: string; nic: string } | null; // who LLDP says is on the other end
  neighbors: PortNeighbor[]; // what the controller reports behind it
}
export interface TopoLagMember {
  switch: string;
  port: string;
  active: boolean; // enabled, link not down, aggregated where the switch says
  why: "disabled" | "link down" | "not aggregated" | null;
}
export interface TopoLag {
  name: string;
  ports: string[]; // port ids; "<switch>:<port>" for a LAG across an MLAG pair
  formed: boolean; // every member active and the switch(es) report it formed
  live: string[];
  node: string | null;
  bond: string | null;
  switches: string[]; // the switch(es) its members are on
  mlagId: number | null;
  pair: string | null; // the MLAG pair it runs across
  members: TopoLagMember[];
  missing: string[]; // pair switches with no member
  peer: { kind: "switch" | "pair"; name: string } | null; // a switch uplink: the other end
}
export interface TopoMlagPair {
  name: string; // "<a>+<b>", as switch-manager keys it
  switches: string[];
  peerLink: { switch: string; port: string | null; members: string[] }[];
  lags: TopoLag[];
  live: string; // the verb that reads the pair's live state from the switches
}
export interface TopoSwitch extends TopoPlace {
  name: string;
  lldpName: string | null;
  vendor: string | null;
  model: string | null;
  managementIp: string | null;
  managed: string | null;
  controller: string | null;
  controllerAddress: string | null; // the controller's management URL (UniFi OS …)
  ports: TopoPort[];
  lags: TopoLag[]; // its own; a LAG across an MLAG pair is on the pair
  mlagPair: string | null;
}
export interface TopoAp extends TopoPlace {
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
  environments: string[]; // the environment(s) the zone names (#865)
}
export interface TopoOutside {
  kind: "buddy" | "satellite";
  name: string;
  role: string | null;
  location: string | null; // its place, as text
  at?: string | null; // the location it names (a satellite), when it names one
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
// A device the topology knows besides the nodes, switches and access points:
// a machine module, a device a switch port names, a device position-manager
// records, or one a switch port sees that nobody recorded. What a rack holds.
export interface TopoDevice extends TopoPlace {
  name: string;
  kind: "machine" | "device" | RecordedKind;
  vendor: string | null;
  model: string | null;
  // A device position-manager records (nothing manages it): its ports and how
  // it is shown.
  recorded?: true;
  ports?: string[];
  displayName?: string | null;
  description?: string | null;
  // A seen device: the port it is seen at and what is said about it there.
  seen?: { switch: string; port: string; mac: string | null; lldp: { name: string; port: string | null } | null; lease: { hostname: string | null; address: string | null } | null } | null;
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
  mlagPairs: TopoMlagPair[];
  accessPoints: TopoAp[];
  zones: TopoZone[];
  outside: TopoOutside[];
  devices: TopoDevice[];
  // Where the hardware is (position-manager): null when it was not read.
  positions: PositionsView | null;
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

// Port ids are opaque ("11" on UniFi, "sfp-sfpplus1" on MikroTik): ordered
// naturally, the digits within a name compared as numbers.
export const portCompare = (a: string, b: string): number => a.localeCompare(b, "en", { numeric: true });

// "sfp-sfpplus15", "sfp-sfpplus16" → "sfp-sfpplus15+16"; "11", "12" → "11+12".
export function compactPorts(ports: string[]): string {
  if (ports.length === 0) return "";
  const head = /^(.*?)(\d+)$/.exec(ports[0]);
  return ports
    .map((p, i) => {
      if (i === 0 || !head) return p;
      const m = /^(.*?)(\d+)$/.exec(p);
      return m && m[1] === head[1] ? m[2] : p;
    })
    .join("+");
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
    zones.push({
      name,
      vlan: num(z.vlantag),
      state: str(z.state),
      type: str(z.type),
      tier: num(z.tier),
      bridge: str(z.bridge),
      ip: str(z.ip),
      environments: (Array.isArray(z.environment) ? z.environment : [z.environment]).filter((e): e is string => typeof e === "string" && e.length > 0),
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

  // LLDP's port: the switch's own id when it has a port by that name
  // ("sfp-sfpplus1" on MikroTik), else the trailing number ("Port 11" → "11").
  const resolvePort = (sw: string, p: string): string => {
    const rows = portsBySwitch.get(sw) ?? [];
    if (rows.some((r) => r.port === p)) return p;
    return lldpPort(p);
  };

  // Legs, and who LLDP says sits on each switch port.
  const seenAt = new Map<string, { node: string; nic: string }>(); // `${switch}\0${port}`
  const key = (sw: string, port: string): string => `${sw}\u0000${port}`;
  const legOf = (node: string, p: NetPort): TopoLeg => {
    let peer: TopoPeerPort | null = null;
    if (p.lldp && p.lldp.name) {
      const sw = resolveSwitch(p.lldp.name);
      peer = { switch: sw.name, port: resolvePort(sw.name, p.lldp.port), known: sw.known, via: "lldp" };
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
      location: null,
      placement: null,
      source: "cluster",
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
  // MLAG pairs (switch-manager's actual.json): the pair, each side's peer-link
  // bond and the ports in it.
  const actual = src.actual ?? null;
  const actualPort = (sw: string, port: string): ActualPort | null => actual?.switches?.[sw]?.ports?.[port] ?? null;
  const pairDefs = Object.entries(actual?.mlagPairs ?? {})
    .filter(([, p]) => Array.isArray(p?.switches) && p.switches.length === 2)
    .map(([name, p]) => ({ name, switches: p.switches as string[], peerPort: p.peerPort ?? {} }));
  const pairOf = (sw: string): (typeof pairDefs)[number] | null => pairDefs.find((p) => p.switches.includes(sw)) ?? null;
  const peerBond = (sw: string): string | null =>
    str(pairOf(sw)?.peerPort[sw]) ?? str(actual?.switches?.[sw]?.mlag?.peerPort) ?? str(invSwitches.find((x) => x.name === sw)?.mlag?.peerPort);

  const switches: TopoSwitch[] = invSwitches.map((s) => {
    const rows = followLeads(portsBySwitch.get(s.name) ?? []);
    const ports: TopoPort[] = rows.map((r) => portOf(s.name, r));
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
      lags: [],
      mlagPair: pairOf(s.name)?.name ?? null,
      location: null,
      placement: null,
      source: "switch-configuration",
    };
  });
  const switchNamed = (name: string): TopoSwitch | undefined => switches.find((x) => x.name === name);

  // LAGs. A member is active when it is enabled, its link is not down, and the
  // switch counts it in the aggregate; formed is every member active, never
  // the configured members alone.
  const memberOf = (sw: string, port: string, live: string[]): TopoLagMember => {
    const p = switchNamed(sw)?.ports.find((x) => x.port === port);
    const why: TopoLagMember["why"] = p?.disabled ? "disabled" : p?.link === "down" ? "link down" : live.length > 0 && !live.includes(port) ? "not aggregated" : null;
    return { switch: sw, port, active: why === null, why };
  };
  const lagOwner = (members: TopoLagMember[]): Pick<TopoLag, "node" | "bond" | "peer"> => {
    const targets = members.map((m) => switchNamed(m.switch)?.ports.find((x) => x.port === m.port)?.target ?? null);
    const nodesOn = [...new Set(targets.map((t) => (t?.kind === "node" ? t.name : null)).filter((x): x is string => !!x))];
    const node = nodesOn.length === 1 ? nodesOn[0] : null;
    const bond = node ? (nodeNamed(node)?.uplinks.find((u) => u.name === "lan")?.bond ?? null) : null;
    let peer: TopoLag["peer"] = null;
    const sws = [...new Set(targets.map((t) => (t?.kind === "switch" ? t.name : null)).filter((x): x is string => !!x))];
    if (!node && sws.length > 0 && targets.every((t) => t?.kind === "switch")) {
      const resolved = sws.map((x) => switchByCanon.get(canon(x)) ?? x);
      const pair = resolved.length === 2 ? pairDefs.find((p) => resolved.every((x) => p.switches.includes(x))) : undefined;
      if (pair) peer = { kind: "pair", name: pair.name };
      else if (resolved.length === 1) peer = { kind: "switch", name: resolved[0] };
    }
    return { node, bond, peer };
  };
  const rowMlagId = (l: LagRow): number | null => {
    if (typeof l.mlagId === "number") return l.mlagId;
    for (const p of l.ports) {
      const id = actualPort(l.switch, p)?.mlagId;
      if (typeof id === "number") return id;
    }
    return null;
  };
  const acrossPair = new Map<string, Map<number, LagRow[]>>(); // pair → mlag-id → rows
  for (const l of src.lags ?? []) {
    const pair = pairOf(l.switch);
    const id = rowMlagId(l);
    if (pair && id !== null) {
      const byId = acrossPair.get(pair.name) ?? new Map<number, LagRow[]>();
      byId.set(id, [...(byId.get(id) ?? []), l]);
      acrossPair.set(pair.name, byId);
      continue;
    }
    const sw = switchNamed(l.switch);
    if (!sw) continue;
    const live = l.live.map(String);
    const members = [...l.ports].sort(portCompare).map((p) => memberOf(l.switch, p, live));
    sw.lags.push({
      name: l.name, ports: l.ports, formed: l.formed && members.every((m) => m.active), live,
      switches: [l.switch], mlagId: id, pair: null, members, missing: [], ...lagOwner(members),
    });
  }
  const mlagPairs: TopoMlagPair[] = pairDefs.map((pd) => {
    const lags: TopoLag[] = [...(acrossPair.get(pd.name) ?? new Map<number, LagRow[]>()).entries()]
      .sort(([a], [b]) => a - b)
      .map(([id, rows]) => {
        const members: TopoLagMember[] = [];
        for (const sw of pd.switches) {
          for (const r of rows.filter((x) => x.switch === sw)) {
            const live = r.live.map(String);
            for (const p of [...r.ports].sort(portCompare)) members.push(memberOf(sw, p, live));
          }
        }
        const missing = pd.switches.filter((sw) => !rows.some((r) => r.switch === sw));
        return {
          name: [...new Set(rows.map((r) => r.name))].join("/"),
          ports: members.map((m) => `${m.switch}:${m.port}`),
          formed: missing.length === 0 && rows.every((r) => r.formed) && members.every((m) => m.active),
          live: rows.flatMap((r) => r.live.map((p) => `${r.switch}:${p}`)),
          switches: pd.switches.filter((sw) => rows.some((r) => r.switch === sw)),
          mlagId: id,
          pair: pd.name,
          members,
          missing,
          ...lagOwner(members),
        };
      });
    const peerLink = pd.switches.map((sw) => ({
      switch: sw,
      port: peerBond(sw),
      members: (switchNamed(sw)?.ports ?? []).filter((p) => p.peerLink).map((p) => p.port).sort(portCompare),
    }));
    return { name: pd.name, switches: pd.switches, peerLink, lags, live: "switch-manager mlag-pair list" };
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
      const first = rows.filter((x) => x.lag === r.lag).map((x) => x.port).sort(portCompare)[0];
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
    const ap = actualPort(sw, r.port);
    const bond = peerBond(sw);
    const peerLink = ap?.peerLink === true || (bond !== null && ap?.bond === bond);
    const targetNode = nodeNamed(r.target);
    if (peerLink) {
      // A member of the MLAG peer link: to the other switch of the pair.
      const other = pairOf(sw)?.switches.find((x) => x !== sw) ?? null;
      target = { kind: "switch", name: other, port: other ? peerBond(other) : null };
      role = "peer-link";
    } else if (targetNode) {
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
    const bridged = ap ? ap.bridged !== false : null;
    const disabled = r.disabled === true || ap?.disabled === true;
    // Disabled is the port's state, unless it is a peer-link member or an
    // unmanaged port off the bridge (MikroTik ether1), which the switch reports
    // as disabled for being outside the bridge.
    const status: PortStatus = peerLink ? "peer-link" : disabled && !(r.drift === "unmanaged" && bridged === false) ? "disabled" : r.drift;
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
      status,
      disabled,
      peerLink,
      bridged,
      mlagId: typeof ap?.mlagId === "number" ? ap.mlagId : null,
      add: r.add,
      remove: r.remove,
      seen,
      neighbors: (r.neighbors ?? []).filter((x) => typeof x?.mac === "string" && x.mac !== ""),
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
    location: null,
    placement: null,
    source: "switch-configuration",
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
      location: [(p.place ?? p.physicalLocation)?.city, (p.place ?? p.physicalLocation)?.country].filter((x) => !!x).join(", ") || p.location || null,
      tunnel: str(p.tunnel),
      address: str(p.remoteHost),
      state: pulseState.get(p.name) ?? null,
    })),
    ...src.satellites.map((s): TopoOutside => {
      const l = s.location ? readLocations(src.site).locations[s.location] : undefined;
      return {
        kind: "satellite", name: s.name, role: null,
        location: l ? [l.city, l.country].filter((x) => !!x).join(", ") || l.displayName || l.name : s.location ?? null,
        at: s.location ?? null,
        tunnel: null, address: s.address, state: null,
      };
    }),
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
        for (const pr of mlagPairs) for (const l of pr.lags) if (l.node === on.name) refs.push({ kind: "lag", name: l.name, switch: pr.name });
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

  // The machines (a satellite is outside, not here) and the devices a switch
  // port names: what a rack may mount besides nodes, switches and APs.
  const devices: TopoDevice[] = [];
  const unplaced = { location: null, placement: null };
  const taken = new Set([...nodes.map((n) => n.name), ...switches.map((x) => x.name), ...accessPoints.map((a) => a.name)]);
  for (const m of src.modules ?? []) {
    if (m.kind !== "machine" || src.satellites.some((x) => x.name === m.name) || taken.has(m.name)) continue;
    taken.add(m.name);
    devices.push({ name: m.name, kind: "machine", vendor: null, model: null, ...unplaced, source: "module" });
  }
  for (const s of switches) {
    for (const p of s.ports) {
      if (p.target?.kind !== "device" || !p.target.name || taken.has(p.target.name)) continue;
      taken.add(p.target.name);
      devices.push({ name: p.target.name, kind: "device", vendor: null, model: null, ...unplaced, source: "switch-configuration" });
    }
  }
  // The devices position-manager records: what nothing above manages.
  const posDoc = src.positions?.doc ?? {};
  for (const [name, d] of Object.entries(posDoc.devices ?? {})) {
    if (taken.has(name)) continue;
    taken.add(name);
    devices.push({ name, kind: d.kind, vendor: null, model: d.model ?? null, recorded: true, ports: recordedPorts(d, src.positions!.catalog), displayName: d.displayName ?? null, description: d.description ?? null, ...unplaced, source: "recorded" });
  }

  // Where each device is. A location is the site's (site.json); a device names
  // its own on its record — a machine module (a node's pvehost instance), a
  // switch or an AP, a recorded device — else it is at the primary location.
  const sites = readLocations(src.site);
  const known = (l: unknown): string | null => (typeof l === "string" && sites.locations[l] ? l : null);
  const primary = sites.primary;
  const switchLoc = (sw: string): string | null => known(invSwitches.find((x) => x.name === sw)?.location) ?? primary;
  const machineLoc = (m: string): string | null => known(src.machineLocations?.[m]) ?? primary;
  // The devices a switch port sees and no record names: what its controller
  // reports behind the port (a MAC, LLDP, a lease), else a port that is up
  // with nothing recorded on it. A port of a node, an AP, a switch or the ISP
  // is accounted for, and so is one a recorded cable lands on or a MAC a
  // recorded device or a node's NIC has.
  const recordedMacs = new Set(Object.values(posDoc.devices ?? {}).map((d) => canon(d.mac)).filter((m) => m !== ""));
  const nodeMacs = new Set(nodes.flatMap((n) => n.uplinks.flatMap((u) => u.legs.map((l) => canon(l.mac)))).filter((m) => m !== ""));
  for (const net of Object.values(src.networks)) for (const p of net?.live.ports ?? []) if (p.mac) nodeMacs.add(canon(p.mac));
  const cabled = new Set(cablesOf(posDoc).flatMap((c) => [c.from, c.to]).map((e) => `${e.device}\u0000${e.port}`));
  const ACCOUNTED: PortRole[] = ["node-lan", "node-wan", "ap", "switch", "uplink", "peer-link", "isp"];
  for (const s of switches) {
    for (const p of s.ports) {
      if (ACCOUNTED.includes(p.role) || p.target?.name || p.disabled || cabled.has(`${s.name}\u0000${p.port}`)) continue;
      const seenHere = p.neighbors.filter((n) => !recordedMacs.has(canon(n.mac)) && !nodeMacs.has(canon(n.mac)));
      const add = (mac: string | null, n: PortNeighbor | null): void => {
        const name = mac ?? `${s.name}:${p.port}`;
        if (taken.has(name)) return;
        taken.add(name);
        const lldp = n?.lldp && (str(n.lldp.name) || str(n.lldp.port)) ? { name: str(n.lldp.name) ?? name, port: str(n.lldp.port) } : null;
        const lease = n?.lease && (str(n.lease.hostname) || str(n.lease.address)) ? { hostname: str(n.lease.hostname), address: str(n.lease.address) } : null;
        devices.push({
          name,
          kind: "device",
          vendor: null,
          model: null,
          ports: [lldp?.port ?? "1"],
          displayName: lldp?.name ?? lease?.hostname ?? null,
          description: null,
          source: "seen",
          seen: { switch: s.name, port: p.port, mac, lldp, lease },
          location: switchLoc(s.name),
          placement: null,
        });
      };
      if (seenHere.length) for (const n of seenHere) add(n.mac.toLowerCase(), n);
      else if (!p.neighbors.length && p.link === "up") add(null, null);
    }
  }
  const placements = placementsOf(posDoc);
  const placementOf = (name: string): TopoPlacement | null => {
    const m = placements[name];
    return m ? { room: roomOf(posDoc, m), rack: m.rack ?? null, u: m.u ?? null } : null;
  };
  for (const n of nodes) Object.assign(n, { location: machineLoc(n.name), placement: placementOf(n.name) });
  for (const x of switches) Object.assign(x, { location: switchLoc(x.name), placement: placementOf(x.name) });
  for (const a of accessPoints) Object.assign(a, { location: known((src.accessPoints ?? []).find((r) => r.name === a.name)?.location) ?? primary, placement: placementOf(a.name) });
  for (const d of devices) {
    if (d.source === "recorded") d.location = known(posDoc.devices?.[d.name]?.location) ?? posDoc.devices?.[d.name]?.location ?? primary;
    else if (d.source === "module") d.location = machineLoc(d.name);
    else if (d.source !== "seen") d.location = primary;
    d.placement = placementOf(d.name);
  }
  const locationOf = new Map<string, string | null>([...nodes, ...switches, ...accessPoints, ...devices].map((x) => [x.name, x.location]));

  // The positions, resolved against what was found; what does not reconcile
  // is a topology finding on the rack (a placement whose device is gone) or on
  // the device (placed nowhere, once the site has a rack).
  const positions = src.positions
    ? resolvePositions(src.positions.doc, src.positions.catalog, { nodes, switches, accessPoints, devices }, { locations: sites.locations, primary }, (d) => locationOf.get(d) ?? primary)
    : null;
  for (const f of positions?.findings ?? []) {
    if (f.kind === "gone") topoFinding(f.text, { kind: "rack", name: f.rack ?? "" });
    else {
      const kind: TopoKind = nodes.some((n) => n.name === f.device) ? "node" : switches.some((x) => x.name === f.device) ? "switch" : accessPoints.some((a) => a.name === f.device) ? "ap" : "module";
      topoFinding(f.text, { kind, name: f.device });
    }
  }

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
    mlagPairs,
    accessPoints,
    zones,
    outside,
    devices,
    positions,
    findings,
    sources: SOURCE_NAMES.filter((name) => name !== POSITIONS_SOURCE || src.positions !== undefined).map((name) => {
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
  "switch-configuration-actual.json",
  "position-manager export",
];
const POSITIONS_SOURCE = "position-manager export";

export type Runner = (bin: string, args: string[]) => ExecResult;

export interface CollectOpts {
  configDir: string;
  zonesFile: string;
  // A validate --json the caller already holds (the console's cache); null skips
  // health findings; undefined runs health-manager validate --json.
  health?: HealthDoc | null;
  run?: Runner;
  wanAddressFile?: string; // default $TAPPAAS_WAN_ADDRESS_FILE or /var/lib/tappaas/wan-address.json
  positions?: boolean; // read position-manager export (default); false for position-manager's own read
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
  // A satellite is a machine module of the satellite kind (ADR-010). Every
  // machine names the location it is at (ADR-036 D2); a `location` with a '/'
  // is the module directory field migration 0006 renamed, never a place.
  const satellites: { name: string; address: string | null; location?: string | null }[] = [];
  const machineLocations: Record<string, string> = {};
  for (const m of (modules ?? []).filter((x) => x.kind === "machine")) {
    let cfg: Record<string, unknown> | null = null;
    try {
      cfg = readJsonObject(join(o.configDir, `${m.name}.json`));
    } catch {
      cfg = null;
    }
    const at = typeof cfg?.location === "string" && cfg.location !== "" && !cfg.location.includes("/") ? cfg.location : null;
    if (at) machineLocations[m.name] = at;
    if (/\/satellite\/?$/.test(String(cfg?.moduleSource ?? ""))) satellites.push({ name: m.name, address: str(cfg?.address), location: at });
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
  // switch-manager's actual state: the MLAG pairs and peer links. No file is
  // not an error (no switch registered yet).
  let actual: SwitchActual | null = null;
  try {
    actual = readJsonObject(join(o.configDir, "switch-configuration-actual.json")) as SwitchActual | null;
  } catch (e) {
    errors.push({ source: "switch-configuration-actual.json", error: (e as Error).message });
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
    machineLocations,
    wanAddress,
    actual,
    // No positions.json is an empty document, not an error; no position-manager is.
    positions: o.positions === false ? undefined : json<{ doc: PositionsDoc; catalog: Faceplate[] }>(POSITIONS_SOURCE, "position-manager", ["export", "--json"]),
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
  // A leg names its switch when the site has more than one (or LLDP puts it on
  // one the inventory does not hold).
  const onlySwitch = t.switches.length === 1 ? t.switches[0].name : null;
  const legPeer = (p: TopoPeerPort): string => (p.switch === onlySwitch ? p.port : `${p.switch}:${p.port}`);
  for (const n of t.nodes) {
    const ups = n.uplinks
      .map((u) => `${u.name} ${u.mode}${u.bond ? ` ${u.bond}` : ""} ${u.legs.map((l) => `${l.nic}${l.speed ? `@${l.speed}` : ""}${l.up ? "" : "(down)"}→${l.peer ? legPeer(l.peer) : "?"}`).join(" ")}`)
      .join("; ");
    out.push(`  ${n.name.padEnd(12)}${ups || "(no network report)"}`);
    out.push(`  ${"".padEnd(12)}${n.guests.length} guest(s)${n.roles.length ? ` — ${n.roles.join(", ")}` : ""}`);
  }
  const pairLabel = (name: string): string => t.mlagPairs.find((p) => p.name === name)?.switches.join(" + ") ?? name.replace("+", " + ");
  const lagTail = (l: TopoLag): string => {
    const owner = l.node ? ` — ${l.node}${l.bond ? ` ${l.bond}` : ""}` : l.peer ? ` — ${l.peer.kind === "pair" ? `MLAG pair ${pairLabel(l.peer.name)}` : `switch ${l.peer.name}`}` : "";
    return `${lagState(l)}${owner}`;
  };
  const lagState = (l: TopoLag): string => {
    if (l.formed) return "formed";
    const across = l.pair !== null;
    const label = (m: TopoLagMember): string => (across ? `${m.switch}:${m.port}` : m.port);
    const reasons = [...l.members.filter((m) => !m.active).map((m) => `${label(m)} ${m.why}`), ...l.missing.map((sw) => `no member on ${sw}`)];
    const active = l.members.filter((m) => m.active).length;
    if (reasons.length === 0) return "not formed";
    return `${active} of ${l.members.length} member${l.members.length === 1 ? "" : "s"} active (${reasons.join(", ")})`;
  };
  out.push("", "Switches");
  for (const s of t.switches) {
    out.push(`  ${s.name}${s.lldpName ? ` (LLDP: ${s.lldpName})` : ""}  [${s.vendor ?? "?"}] ${s.managed ?? ""}  ${s.ports.length} port(s)${s.mlagPair ? `  MLAG pair ${pairLabel(s.mlagPair)}` : ""}`);
    const tgtOf = (p: TopoPort): string => (p.target ? `${p.target.kind}${p.target.name ? ` ${p.target.name}` : ""}${p.target.port ? `/${p.target.port}` : ""}` : "—");
    // Numbered ports (UniFi) right-aligned, named ones (MikroTik) left-aligned.
    const pw = Math.max(3, ...s.ports.map((p) => p.port.length));
    const numbered = s.ports.every((p) => /^\d+$/.test(p.port));
    const tw = Math.max(26, ...s.ports.map((p) => tgtOf(p).length + 1));
    for (const p of s.ports) {
      const vl = p.mode === "access" ? `access ${p.native}` : `trunk ${p.tagged.length}`;
      out.push(`    ${numbered ? p.port.padStart(pw) : p.port.padEnd(pw)}  ${p.role.padEnd(10)}${tgtOf(p).padEnd(tw)}${vl.padEnd(12)}${p.status}${p.lag ? `  LAG ${p.lag}` : ""}`);
    }
    for (const l of s.lags) out.push(`    LAG ${l.name}: ports ${compactPorts(l.ports)} ${lagTail(l)}`);
  }
  for (const pr of t.mlagPairs) {
    const links = pr.peerLink.map((x) => `${x.switch} ${x.port ?? "?"}${x.members.length ? ` (${compactPorts(x.members)})` : ""}`).join(", ");
    out.push(`  MLAG pair ${pr.switches.join(" + ")} — peer link ${links}`);
    for (const l of pr.lags) {
      out.push(`    LAG ${l.name} across ${l.switches.join(" + ") || pr.switches.join(" + ")}${l.mlagId !== null ? ` (mlag-id ${l.mlagId})` : ""}: ${l.ports.join(", ")} ${lagTail(l)}`);
    }
    out.push(`    live state: ${pr.live}`);
  }
  if (t.accessPoints.length) {
    out.push("", "Access points");
    for (const a of t.accessPoints) out.push(`  ${a.name}  ${a.address ?? "-"}  uplink ${a.uplink ? `${a.uplink.switch}:${a.uplink.port}` : "-"}  ssids ${a.ssids.length}`);
  }
  if (t.outside.length) {
    out.push("", "Outside");
    for (const o of t.outside) out.push(`  ${o.kind.padEnd(10)}${o.name}${o.location ? ` (${o.location})` : ""}${o.state ? `  ${o.state}` : ""}`);
  }
  const pv = t.positions;
  if (pv && (pv.racks.length || pv.rooms.some((r) => r.loose.length) || pv.unplaced.length)) {
    out.push("", "Positions");
    for (const l of pv.locations) {
      if (!l.rooms.length && !l.unplaced.length) continue;
      out.push(`  ${l.name}${l.primary ? " (primary)" : ""}${l.place?.city ? `  ${l.place.city}` : ""}`);
      for (const room of pv.rooms.filter((r) => r.location === l.name)) {
        out.push(`    room ${room.name}${room.loose.length ? `, loose: ${room.loose.map((m) => m.device).join(", ")}` : ""}`);
        for (const r of pv.racks.filter((x) => x.room === room.name)) {
          out.push(`      ${r.name}  ${r.units}U ${r.width}`);
          for (const m of r.placements) out.push(`        U${m.u}${m.height > 1 ? `-${m.u + m.height - 1}` : ""} ${m.face}  ${m.device}  ${m.faceplate ?? "no plate"}${m.suggested ? " (suggested)" : ""}`);
        }
      }
      if (l.unplaced.length) out.push(`    placed nowhere: ${l.unplaced.join(", ")}`);
    }
    for (const r of pv.racks.filter((x) => !x.room)) out.push(`  ${r.name}  ${r.units}U ${r.width} (in no room)`);
    const recorded = pv.cables.filter((c) => c.source === "recorded");
    out.push(`  cables: ${pv.cables.length - recorded.length} seen, ${recorded.length} recorded`);
  }
  const seen = t.devices.filter((d) => d.source === "seen");
  if (seen.length) {
    out.push("", "Seen at a port, recorded nowhere");
    for (const d of seen) out.push(`  ${d.seen!.switch}:${d.seen!.port}  ${d.seen!.mac ?? "(link up)"}${d.displayName ? `  ${d.displayName}` : ""}  — position-manager device record`);
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
