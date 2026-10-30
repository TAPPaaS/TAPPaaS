// topology-cmdb.ts — `network-manager topology` as a view of the CMDB (ADR-040
// D10, plan step 4; docs/plans/adr-040-step4-topology-from-cmdb.md says where
// each field comes from). sourcesFromCmdb() turns the CMDB's objects and
// relations into the TopoSources buildTopology() joins, so the document and
// every reconciliation rule have one implementation; the live join stays for
// `--live`, for `--diff`, and for when the CMDB does not answer or does not yet
// hold what is needed (missingFromCmdb).
//
// Two things stay read here, neither of them a plane: wan-address.json, this
// manager's own record, and the faceplate catalog, which is reference data.
//
// sourcesFromCmdb() and diffTopology() are pure; the unit tests run them over
// a fake answer. readTopologyFromCmdb() does the reading.

import { CmdbOptions, CmdbRefused, CmdbUnavailable, cmdbQuery, cmdbRelations } from "../../../lib/ts/src/cmdb";
import { ExecResult, captureResult } from "../../../lib/ts/src/exec";
import { Faceplate } from "../../../lib/ts/src/positions";
import { CmdbAnswer, positionsFromCmdb } from "../../../lib/ts/src/positions-cmdb";
import { WanAddress, readWanAddress, wanAddressFile } from "../../../lib/ts/src/wan-address";
import {
  ActualPort, ApRow, HealthDoc, LagRow, ModuleRow, NodeNetwork, POSITIONS_SOURCE, PeerRow, SwitchActual, SwitchList, SwitchPortRow, SwitchPorts, TopoSources, Topology,
  buildTopology, portCompare,
} from "./topology";

type Obj = Record<string, unknown>;

export interface CmdbItem {
  id: string;
  class: string;
  name: string;
  displayName?: string | null;
  recorded?: boolean;
  lastSeen?: string | null;
  attributes: Obj;
}
export interface CmdbLink {
  type: string;
  from: { id: string; class: string; name: string };
  to: { id: string; class: string; name: string };
  attributes: Obj;
  recorded?: boolean;
}
export interface CmdbRead {
  objects: CmdbItem[];
  relations: CmdbLink[];
}

const CMDB_SOURCE = "cmdb";
const WAN_SOURCE = "wan-address.json";
// A report older than this is said in `sources`: cmdb-refresh runs every 5 minutes.
const STALE_MS = 30 * 60 * 1000;

const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const obj = (v: unknown): Obj | null => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);

const isSwitch = (o: CmdbItem): boolean => o.class === "device" && o.attributes.deviceType === "switch";
const isAp = (o: CmdbItem): boolean => o.class === "device" && o.attributes.deviceType === "access-point";
const isMember = (o: CmdbItem): boolean => o.class === "machine" && o.attributes.clusterMember === true;
// A module's CI names its config/ record; a switch's names the switch
// configuration, and pve on a node names nothing.
const isModule = (o: CmdbItem): boolean => str(obj(o.attributes.desired)?.file) === `${o.name}.json`;

const MODULE_KIND: Record<string, string> = { vm: "vm", lxc: "lxc", machine: "machine", device: "device", app: "application" };

class Index {
  private readonly outOf = new Map<string, CmdbLink[]>();
  constructor(readonly read: CmdbRead) {
    for (const r of read.relations) this.outOf.set(r.from.id, [...(this.outOf.get(r.from.id) ?? []), r]);
  }
  ofClass(cls: string): CmdbItem[] {
    return this.read.objects.filter((o) => o.class === cls);
  }
  /** The name at the end of a relation from the object, to the given class if any. */
  to(type: string, o: CmdbItem, cls?: string): string | null {
    return (this.outOf.get(o.id) ?? []).find((r) => r.type === type && (!cls || r.to.class === cls))?.to.name ?? null;
  }
  // The site: the one every site-manager report puts at its location; a site
  // object with none is an old name's leftover.
  get site(): CmdbItem | null {
    const sites = this.ofClass("site");
    return sites.find((s) => this.to("at", s) !== null) ?? null;
  }
}

/** What the CMDB does not hold yet, in words; empty: the document can be built
 *  from it. A report older than the fields of step 4 lacks them. */
export function missingFromCmdb(read: CmdbRead): string[] {
  const x = new Index(read);
  const out: string[] = [];
  if (!x.site) out.push("no site at a location (site-manager report)");
  const members = read.objects.filter(isMember);
  if (members.length === 0) out.push("no cluster member (site-manager report)");
  const noNet = members.filter((m) => !obj(m.attributes.network)).map((m) => m.name);
  if (noNet.length) out.push(`no network of ${noNet.join(", ")} (site-manager report)`);
  const assigned = new Set(x.ofClass("port").map((p) => str(obj(p.attributes.assignment)?.switch)));
  const notSwitch = x.ofClass("device").filter((d) => !d.attributes.deviceType && str(obj(d.attributes.desired)?.file)?.startsWith("switch-configuration")).map((d) => d.name);
  if (notSwitch.length) out.push(`no device type on ${notSwitch.join(", ")} (switch-manager, ap-manager report)`);
  const noPorts = read.objects.filter(isSwitch).filter((s) => !assigned.has(s.name)).map((s) => s.name);
  if (noPorts.length) out.push(`no port assignment on ${noPorts.join(", ")} (switch-manager report)`);
  if (!x.ofClass("zone").some((z) => str(z.attributes.state))) out.push("no zone state (network-manager report)");
  if (!read.objects.some((o) => isModule(o) && str(o.attributes.maturity))) out.push("no module maturity (module-manager report)");
  const noRole = x.ofClass("backup-peer").filter((p) => !str(p.attributes.role)).map((p) => p.name);
  if (noRole.length) out.push(`no role of backup peer ${noRole.join(", ")} (backup-manager report)`);
  return out;
}

// The newest report behind a class of objects.
function newest(objects: CmdbItem[]): number | null {
  const times = objects.map((o) => Date.parse(o.lastSeen ?? "")).filter((t) => Number.isFinite(t));
  return times.length ? Math.max(...times) : null;
}

function staleness(name: string, objects: CmdbItem[], now: Date): { source: string; error: string } | null {
  const at = newest(objects);
  if (at === null || now.getTime() - at <= STALE_MS) return null;
  return { source: name, error: `last reported ${Math.round((now.getTime() - at) / 60000)} minutes ago` };
}

export interface CmdbSourceOpts {
  // A validate --json the caller holds; null leaves findings out; undefined
  // reads the assessment stored on the site.
  health?: HealthDoc | null;
  catalog?: Faceplate[] | null; // undefined: --no-positions; null: asset-manager did not answer
  wanAddress?: WanAddress | null;
  errors?: { source: string; error: string }[];
  now?: Date;
}

/** The sources buildTopology() joins, as the CMDB holds them. */
export function sourcesFromCmdb(read: CmdbRead, o: CmdbSourceOpts = {}): TopoSources {
  const x = new Index(read);
  const now = o.now ?? new Date();
  const site = x.site;
  const at = site?.attributes ?? {};
  const members = read.objects.filter(isMember);
  // In the order of the inventory: a cable between two switches starts at the first.
  const switches = read.objects.filter(isSwitch).sort((a, b) => (num(a.attributes.order) ?? 1e9) - (num(b.attributes.order) ?? 1e9));

  const locations: Record<string, Obj> = {};
  for (const l of x.ofClass("location")) locations[l.name] = { ...l.attributes, displayName: l.displayName ?? l.attributes.displayName };
  const siteDoc: Obj | null = site && {
    name: site.name,
    displayName: site.displayName ?? at.displayName,
    ipv6: at.ipv6,
    network: { publicIp: at.publicIp, isp: at.isp },
    primaryLocation: x.to("at", site),
    locations,
  };

  // Two port objects can claim one switch port (an asset renamed by a later
  // report): the one seen last.
  const rows = new Map<string, Map<string, { row: SwitchPortRow; actual: ActualPort; seen: number }>>();
  for (const p of x.ofClass("port")) {
    const a = obj(p.attributes.assignment);
    const sw = str(a?.switch);
    if (!a || !sw) continue;
    const { switch: _s, actual, ...row } = a;
    const seen = Date.parse(p.lastSeen ?? "") || 0;
    const on = rows.get(sw) ?? new Map<string, { row: SwitchPortRow; actual: ActualPort; seen: number }>();
    if ((on.get(p.name)?.seen ?? -1) < seen) on.set(p.name, { row: { ...row, port: p.name } as unknown as SwitchPortRow, actual: (obj(actual) ?? {}) as ActualPort, seen });
    rows.set(sw, on);
  }
  const ports: SwitchPorts[] = switches.map((s) => ({
    switch: s.name,
    ports: [...(rows.get(s.name)?.values() ?? [])].map((r) => r.row).sort((a, b) => portCompare(a.port, b.port)),
  }));

  const actual: SwitchActual = { mlagPairs: {}, switches: {} };
  for (const s of switches) {
    const mlag = obj(s.attributes.mlag);
    const pair = obj(mlag?.pair);
    if (pair && str(pair.name)) actual.mlagPairs![pair.name as string] = { switches: pair.switches as string[], peerPort: pair.peerPort as Record<string, string> };
    const own: Record<string, ActualPort> = {};
    for (const [port, r] of rows.get(s.name) ?? []) own[port] = r.actual;
    actual.switches![s.name] = { mlag: mlag ? { peerPort: str(mlag.peerPort) ?? undefined, bridge: str(mlag.bridge) ?? undefined } : null, ports: own };
  }

  const controllers = new Map<string, string | undefined>();
  for (const s of switches) {
    const c = str(s.attributes.controller);
    if (c) controllers.set(c, str(s.attributes.controllerAddress) ?? undefined);
  }
  const switchList: SwitchList = {
    controllers: [...controllers].map(([name, managementIp]) => ({ name, managementIp })),
    switches: switches.map((s) => ({
      name: s.name,
      vendor: str(s.attributes.vendor) ?? undefined,
      model: str(s.attributes.model) ?? undefined,
      managementIp: str(s.attributes.managementAddress) ?? undefined,
      controller: str(s.attributes.controller) ?? undefined,
      managed: str(s.attributes.managed) ?? undefined,
      location: x.to("at", s) ?? undefined,
      description: str(s.attributes.description) ?? undefined,
      mlag: obj(s.attributes.mlag) as { peerPort?: string; bridge?: string } | null,
    })),
  };

  const accessPoints: ApRow[] = read.objects.filter(isAp).map((a) => ({
    name: a.name,
    vendor: str(a.attributes.vendor) ?? undefined,
    model: str(a.attributes.model) ?? undefined,
    managementIp: str(a.attributes.managementAddress) ?? undefined,
    location: x.to("at", a) ?? undefined,
    uplink: obj(a.attributes.uplink) as ApRow["uplink"],
    ssids: (Array.isArray(a.attributes.ssids) ? a.attributes.ssids : []) as ApRow["ssids"],
  }));

  const modules: ModuleRow[] = read.objects.filter((m) => isModule(m) && MODULE_KIND[m.class]).map((m) => {
    const a = m.attributes;
    const app = m.class === "app";
    const runs = m.class === "vm" || m.class === "lxc" ? x.to("runs-on", m, "machine") : null;
    return {
      name: m.name,
      kind: MODULE_KIND[m.class],
      vmname: null,
      vmid: num(a.vmid),
      node: app ? str(a.moduleNode) : runs,
      zone0: str(a.zone),
      stack: str(a.stack),
      status: str(a.maturity),
      environment: app ? str(a.environment) : x.to("member-of", m, "environment"),
      running: str(a.state) ?? "-",
      actualNode: runs,
    };
  });

  const peers: PeerRow[] = x.ofClass("backup-peer").map((p) => {
    const location = x.to("at", p);
    const place = location ? obj(locations[location]) : null;
    return {
      name: p.name,
      role: str(p.attributes.role) ?? "",
      remoteHost: str(p.attributes.remoteHost),
      namespace: null,
      location,
      place: place ? { country: str(place.country) ?? undefined, city: str(place.city) ?? undefined } : null,
      tunnel: str(p.attributes.tunnel),
    };
  });

  const satellites = x.ofClass("machine")
    .filter((m) => !isMember(m) && str(obj(m.attributes.release)?.module) === "satellite")
    .map((m) => ({ name: m.name, address: str(m.attributes.hostname) ?? str((m.attributes.addresses as unknown[] | undefined)?.[0]), location: x.to("at", m) }));

  const machineLocations: Record<string, string> = {};
  for (const m of x.ofClass("machine")) {
    const l = x.to("at", m);
    if (l) machineLocations[m.name] = l;
  }

  const fw = x.ofClass("vm").find((v) => v.name === "network") ?? null;
  const networks: Record<string, NodeNetwork | null> = {};
  for (const m of members) networks[m.name] = obj(m.attributes.network) as unknown as NodeNetwork | null;

  const assessment = obj(at.assessment);
  // A gate holds its findings in `rows`, `findings` or both, as `validate --json`
  // prints them together; one that passed may hold neither.
  const gates = ((assessment?.gates ?? []) as (HealthDoc["gates"][number] & { rows?: HealthDoc["gates"][number]["findings"] })[])
    .map(({ rows: gateRows, ...g }) => ({ ...g, findings: [...(gateRows ?? []), ...(g.findings ?? [])] }));
  const health: HealthDoc | null = o.health !== undefined ? o.health : assessment ? { status: "", gates } : null;

  const errors = [...(o.errors ?? [])];
  const stale = [staleness("cmdb: nodes", members, now), staleness("cmdb: switches", switches, now)].filter((e): e is { source: string; error: string } => e !== null);
  errors.push(...stale);

  return {
    site: siteDoc,
    nodes: members.map((m) => ({ name: m.name, storagePools: (m.attributes.storagePools ?? []) as string[] })),
    networks,
    switches: switchList,
    ports,
    lags: switches.flatMap((s) => (Array.isArray(s.attributes.lags) ? (s.attributes.lags as LagRow[]) : [])),
    accessPoints,
    zones: Object.fromEntries(x.ofClass("zone").map((z) => [z.name, zoneRecord(z, read)])),
    modules,
    peers,
    health,
    firewall: fw && { vmid: fw.attributes.vmid, node: x.to("runs-on", fw, "machine"), HANode: fw.attributes.haNode },
    satellites,
    machineLocations,
    wanAddress: o.wanAddress ?? null,
    actual,
    positions: o.catalog === undefined ? undefined : o.catalog === null ? null : { doc: positionsFromCmdb(read as unknown as CmdbAnswer), catalog: o.catalog },
    errors,
    reads: [CMDB_SOURCE, ...(o.catalog === undefined ? [] : [POSITIONS_SOURCE]), WAN_SOURCE, ...stale.map((e) => e.source)],
  };
}

// A zone as zones.json spells it, which is what buildTopology reads.
function zoneRecord(z: CmdbItem, read: CmdbRead): Obj {
  const a = z.attributes;
  const tier = typeof a.tier === "string" && a.tier !== "" ? Number(a.tier) : a.tier;
  const environment = read.relations.filter((r) => r.type === "serves" && r.from.id === z.id).map((r) => r.to.name);
  return { vlantag: a.vlan, state: a.state, type: a.type, tier, bridge: a.bridge, ip: a.subnet, environment };
}

// ── reading ───────────────────────────────────────────────────────────

export interface CmdbReadOpts {
  health?: HealthDoc | null;
  positions?: boolean; // default true
  run?: (bin: string, args: string[]) => ExecResult;
  cmdb?: CmdbOptions;
  read?: () => CmdbRead; // instead of asking the service (tests)
  wanAddressFile?: string;
  env?: Record<string, string | undefined>;
  now?: Date;
}

/** The document from the CMDB, or why not: the caller reads the planes. */
export function readTopologyFromCmdb(o: CmdbReadOpts = {}): { topology: Topology; why?: undefined } | { topology: null; why: string } {
  const env = o.env ?? process.env;
  if (env.TAPPAAS_CMDB === "off") return { topology: null, why: "the CMDB is off here (TAPPAAS_CMDB=off)" };
  let read: CmdbRead;
  try {
    read = o.read ? o.read() : { objects: cmdbQuery({ class: "object" }, o.cmdb) as unknown as CmdbItem[], relations: cmdbRelations({}, o.cmdb) as unknown as CmdbLink[] };
  } catch (e) {
    if (e instanceof CmdbUnavailable || e instanceof CmdbRefused) return { topology: null, why: `the CMDB does not answer (${e.message})` };
    throw e;
  }
  const missing = missingFromCmdb(read);
  if (missing.length) return { topology: null, why: `the CMDB does not hold it all yet: ${missing.join("; ")}` };

  const errors: { source: string; error: string }[] = [];
  // The catalog is asset-manager's and no CI: its export is the one place it is printed whole.
  let catalog: Faceplate[] | null | undefined;
  if (o.positions !== false) {
    const r = (o.run ?? captureResult)("asset-manager", ["export", "--json"]);
    try {
      catalog = (JSON.parse(r.stdout) as { catalog: Faceplate[] }).catalog;
    } catch {
      catalog = null;
      errors.push({ source: POSITIONS_SOURCE, error: r.ran ? `exit ${r.rc}: no JSON` : "asset-manager not found" });
    }
  }
  let wanAddress: WanAddress | null = null;
  try {
    wanAddress = readWanAddress(o.wanAddressFile ?? wanAddressFile());
  } catch (e) {
    errors.push({ source: WAN_SOURCE, error: (e as Error).message });
  }
  return { topology: buildTopology(sourcesFromCmdb(read, { health: o.health, catalog, wanAddress, errors, now: o.now }), o.now) };
}

// ── --diff ────────────────────────────────────────────────────────────

export interface TopoDifference {
  path: string;
  live?: unknown; // absent: only the CMDB has it
  cmdb?: unknown; // absent: only the live join has it
}

const IGNORED = new Set(["generated", "sources"]);
const KEYS = ["name", "port", "module", "nic", "device"];

const canonical = (v: unknown): string => JSON.stringify(v, (_k, x: unknown) => {
  const o = obj(x);
  return o ? Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]])) : x;
});

function keyOf(v: unknown): string | null {
  const o = obj(v);
  if (!o) return null;
  if (typeof o.gate === "string") return `${o.gate} ${canonical(o.on)} ${String(o.text)}`;
  for (const k of KEYS) if (typeof o[k] === "string") return o[k] as string;
  return null;
}

// Arrays compare by what names their members, not by position: a CMDB answer
// is ordered by name, a file or a verb is not.
function keyed(a: unknown[]): Map<string, unknown> | null {
  const m = new Map<string, unknown>();
  for (const v of a) {
    const k = keyOf(v);
    if (k === null || m.has(k)) return null;
    m.set(k, v);
  }
  return m;
}

function walk(path: string, live: unknown, cmdb: unknown, out: TopoDifference[]): void {
  if (canonical(live) === canonical(cmdb)) return;
  const pair = (k: string, a: Map<string, unknown>, b: Map<string, unknown>, at: (x: string) => string): void => {
    if (!a.has(k)) out.push({ path: at(k), cmdb: b.get(k) });
    else if (!b.has(k)) out.push({ path: at(k), live: a.get(k) });
    else walk(at(k), a.get(k), b.get(k), out);
  };
  if (Array.isArray(live) && Array.isArray(cmdb)) {
    const a = keyed(live) ?? new Map(live.map((v) => [canonical(v), v]));
    const b = keyed(cmdb) ?? new Map(cmdb.map((v) => [canonical(v), v]));
    for (const k of new Set([...a.keys(), ...b.keys()])) pair(k, a, b, (x) => `${path}[${x}]`);
    return;
  }
  const lo = obj(live);
  const co = obj(cmdb);
  if (lo && co) {
    const a = new Map(Object.entries(lo).filter(([, v]) => v !== undefined));
    const b = new Map(Object.entries(co).filter(([, v]) => v !== undefined));
    for (const k of new Set([...a.keys(), ...b.keys()])) pair(k, a, b, (x) => (path ? `${path}.${x}` : x));
    return;
  }
  out.push({ path, live, cmdb });
}

/** What differs between the live join and the CMDB's document, by the name of
 *  each thing: `generated` and `sources` always do. */
export function diffTopology(live: Topology, cmdb: Topology): TopoDifference[] {
  const strip = (t: Topology): Obj => Object.fromEntries(Object.entries(t).filter(([k]) => !IGNORED.has(k)));
  const out: TopoDifference[] = [];
  walk("", strip(live), strip(cmdb), out);
  return out;
}

export function renderDiff(d: TopoDifference[]): string[] {
  if (d.length === 0) return ["the CMDB and the planes agree"];
  const short = (v: unknown): string => {
    const s = JSON.stringify(v) ?? "undefined";
    return s.length > 100 ? `${s.slice(0, 97)}...` : s;
  };
  return [
    `${d.length} difference(s) (live → cmdb):`,
    ...d.map((x) => (!("cmdb" in x) ? `  - ${x.path}: ${short(x.live)}` : !("live" in x) ? `  + ${x.path}: ${short(x.cmdb)}` : `  ~ ${x.path}: ${short(x.live)} → ${short(x.cmdb)}`)),
  ];
}
