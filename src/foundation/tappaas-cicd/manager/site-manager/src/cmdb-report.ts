// cmdb-report.ts — what site-manager reports to the CMDB (ADR-040 D4): the site,
// its locations, the cluster, every node (a machine: its pvehost instance) and
// every guest the cluster runs (a vm or lxc; the node CI of the module it is,
// when it is one).
//
// The live reads are one ssh to the first reachable node for the cluster
// (status, guests, their configs from /etc/pve, HA) and one per node for what
// only the node knows (os, addresses, pve version, tank pools): the parse is
// here, the ssh in client.ts. A cluster that does not answer leaves what
// config/ says: the site, its locations, the cluster and its nodes, no guests.

import { join } from "path";
import { CmdbObject, CmdbRelation, CmdbReport } from "../../../lib/ts/src/cmdb";
import { compact, moduleNodeAttributes } from "../../../lib/ts/src/cmdb-source";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { readLocations } from "../../../lib/ts/src/locations";
import { clusterNodes } from "../../../lib/ts/src/nodes";
import { discoverModules } from "../../../lib/ts/src/module-discovery";
import { NodeDiscovery, discoveryObjects, parseCorosync } from "./cmdb-discover";

type Obj = Record<string, unknown>;

export const SOURCE = "site-manager";

export interface GuestNic {
  name: string;
  model?: string;
  mac?: string;
  bridge?: string;
  tag?: number;
}

export interface GuestRead {
  vmid: number;
  name: string;
  node: string;
  type: "qemu" | "lxc";
  status?: string;
  template?: boolean;
  cores?: number;
  memory?: number; // MiB
  disks?: { storage: string; size: string }[];
  rootfs?: string;
  unprivileged?: boolean;
  haPolicy?: string;
  nics?: GuestNic[];
  mountpoints?: { storage: string; size: string }[];
}

export interface HostRead {
  hostname?: string;
  os?: string;
  osVersion?: string;
  pveVersion?: string;
  addresses?: string[];
  pools?: string[];
  discovery?: NodeDiscovery; // --discover (D15)
  network?: Obj; // `node network show --json`: what network-manager topology reads
}

export interface ClusterRead {
  quorate?: boolean;
  members: { name: string; online?: boolean; ip?: string }[];
  guests: GuestRead[];
  hosts: Record<string, HostRead>;
  corosync?: Record<string, unknown>[]; // --discover
}

// ── the probes ────────────────────────────────────────────────────────
// One ssh prints every cluster-wide read, each after an `@@<section>` line;
// the guest configs come from pmxcfs, which every member holds whole.
export const CLUSTER_PROBE = [
  "echo @@status; pvesh get /cluster/status --output-format json",
  "echo @@resources; pvesh get /cluster/resources --type vm --output-format json",
  "echo @@ha; pvesh get /cluster/ha/resources --output-format json 2>/dev/null || echo []",
  'for f in /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf; do [ -e "$f" ] && echo "@@conf $f" && cat "$f"; done',
].join("; ");

// `report --discover` adds the corosync links to the cluster-wide read.
export const CLUSTER_DISCOVERY = `${CLUSTER_PROBE}; echo @@corosync; corosync-cfgtool -n 2>/dev/null || true`;

export const HOST_PROBE = [
  ". /etc/os-release",
  'echo "os=$ID"',
  'echo "osVersion=$VERSION_ID"',
  'echo "hostname=$(hostname -f)"',
  'echo "addresses=$(hostname -I)"',
  "echo \"pve=$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\\([^/ ]*\\).*|\\1|p')\"",
  "echo \"pools=$(zpool list -H -o name 2>/dev/null | grep '^tank' | tr '\\n' ' ')\"",
].join("; ");

function sections(stdout: string): { head: string; body: string }[] {
  const out: { head: string; body: string[] }[] = [];
  for (const line of stdout.split("\n")) {
    if (line.startsWith("@@")) out.push({ head: line.slice(2).trim(), body: [] });
    else if (out.length) out[out.length - 1].body.push(line);
  }
  return out.map((s) => ({ head: s.head, body: s.body.join("\n") }));
}

function json(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

const num = (v: unknown): number | undefined => (typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : undefined);

const DISK_KEY = /^(scsi|virtio|sata|ide|efidisk|tpmstate)\d+$/;

/** A guest's /etc/pve config: its own section only (snapshots follow `[…]`). */
export function parseGuestConf(text: string): Partial<GuestRead> {
  const g: Partial<GuestRead> = {};
  const disks: { storage: string; size: string }[] = [];
  const nics: GuestNic[] = [];
  const mountpoints: { storage: string; size: string }[] = [];
  for (const line of text.split("\n")) {
    if (line.startsWith("[")) break;
    const m = /^([a-z0-9_-]+):\s*(.*)$/.exec(line.trim());
    if (!m) continue;
    const [, k, v] = m;
    if (k === "cores") g.cores = num(v);
    else if (k === "memory") g.memory = num(v);
    else if (k === "template") g.template = v.trim() === "1";
    else if (k === "unprivileged") g.unprivileged = v.trim() === "1";
    else if (k === "rootfs") g.rootfs = v.split(",")[0];
    else if (/^net\d+$/.test(k)) nics.push(parseGuestNic(k, v));
    else if (/^mp\d+$/.test(k) && v.includes(":")) mountpoints.push({ storage: v.split(":")[0], size: /(?:^|,)size=([^,]+)/.exec(v)?.[1] ?? "" });
    else if (DISK_KEY.test(k) && !/media=cdrom/.test(v) && v.includes(":")) {
      const size = /(?:^|,)size=([^,]+)/.exec(v)?.[1];
      disks.push({ storage: v.split(":")[0], size: size ?? "" });
    }
  }
  if (disks.length) g.disks = disks;
  if (nics.length) g.nics = nics;
  if (mountpoints.length) g.mountpoints = mountpoints;
  return g;
}

// `net0: virtio=BC:24:…,bridge=lan,tag=200` (qemu), `name=eth0,hwaddr=…,bridge=lan` (lxc).
function parseGuestNic(key: string, v: string): GuestNic {
  const kv = new Map(v.split(",").map((p) => p.split("=", 2) as [string, string]));
  const model = [...kv.keys()].find((k) => /^(virtio|e1000e?|rtl8139|vmxnet3)$/.test(k));
  return compact({
    name: kv.get("name") ?? key,
    model,
    mac: (kv.get("hwaddr") ?? (model ? kv.get(model) : undefined))?.toLowerCase(),
    bridge: kv.get("bridge"),
    tag: kv.has("tag") ? Number(kv.get("tag")) : undefined,
  }) as unknown as GuestNic;
}

/** The cluster probe's output → members, quorum and guests. */
export function parseClusterProbe(stdout: string): ClusterRead {
  const read: ClusterRead = { members: [], guests: [], hosts: {} };
  const confs = new Map<number, Partial<GuestRead>>();
  const ha = new Map<number, string>();
  let resources: unknown = null;
  for (const s of sections(stdout)) {
    if (s.head === "status") {
      const arr = json(s.body);
      for (const e of Array.isArray(arr) ? (arr as Obj[]) : []) {
        if (e.type === "cluster") read.quorate = e.quorate === 1 || e.quorate === true;
        if (e.type === "node" && typeof e.name === "string") {
          read.members.push({ name: e.name, online: e.online === 1 || e.online === true, ip: typeof e.ip === "string" ? e.ip : undefined });
        }
      }
    } else if (s.head === "corosync") read.corosync = parseCorosync(s.body);
    else if (s.head === "resources") resources = json(s.body);
    else if (s.head === "ha") {
      const arr = json(s.body);
      for (const e of Array.isArray(arr) ? (arr as Obj[]) : []) {
        const m = /^(?:vm|ct):(\d+)$/.exec(String(e.sid ?? ""));
        if (m) ha.set(Number(m[1]), [e.state, e.group].filter((x) => typeof x === "string" && x).join("/") || "managed");
      }
    } else if (s.head.startsWith("conf ")) {
      const m = /\/(\d+)\.conf$/.exec(s.head);
      if (m) confs.set(Number(m[1]), parseGuestConf(s.body));
    }
  }
  for (const e of Array.isArray(resources) ? (resources as Obj[]) : []) {
    if (e.type !== "qemu" && e.type !== "lxc") continue;
    const vmid = num(e.vmid);
    if (vmid === undefined) continue;
    const conf = confs.get(vmid) ?? {};
    read.guests.push({
      vmid,
      name: typeof e.name === "string" ? e.name : `vm${vmid}`,
      node: String(e.node ?? ""),
      type: e.type,
      status: typeof e.status === "string" ? e.status : undefined,
      template: e.template === 1 || e.template === true || conf.template === true,
      cores: conf.cores ?? num(e.maxcpu),
      memory: conf.memory ?? (num(e.maxmem) !== undefined ? Math.round((num(e.maxmem) as number) / 1048576) : undefined),
      disks: conf.disks,
      rootfs: conf.rootfs,
      unprivileged: conf.unprivileged,
      haPolicy: ha.get(vmid),
      nics: conf.nics,
      mountpoints: conf.mountpoints,
    });
  }
  read.guests.sort((a, b) => a.vmid - b.vmid);
  return read;
}

/** A node's host probe → what it says about itself. */
export function parseHostProbe(stdout: string): HostRead {
  const kv = new Map<string, string>();
  for (const line of stdout.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) kv.set(line.slice(0, i).trim(), line.slice(i + 1).trim());
  }
  const words = (k: string): string[] | undefined => {
    const v = kv.get(k);
    return v === undefined ? undefined : v.split(/\s+/).filter(Boolean);
  };
  return compact({
    os: kv.get("os") || undefined,
    osVersion: kv.get("osVersion") || undefined,
    hostname: kv.get("hostname") || undefined,
    addresses: words("addresses"),
    pveVersion: kv.get("pve") || undefined,
    pools: words("pools")?.sort(),
  }) as HostRead;
}

// ── the report ────────────────────────────────────────────────────────

/** What config/ and the cluster say, as one observation. The cluster's name
 *  is the site's code (cluster/install.sh: pvecm create <site-code>). */
export function siteObservation(configDir: string, live: ClusterRead | null, tappaasVersion: string | null, discover = false): CmdbReport {
  const site = readJsonObject(join(configDir, "site.json")) ?? {};
  const code = typeof site.name === "string" && site.name ? site.name : "site";
  const objects: CmdbObject[] = [];
  const relations: CmdbRelation[] = [];

  // Locations, then the site at its primary one.
  const { locations, primary } = readLocations(site);
  const net = (site.network ?? {}) as Obj;
  for (const l of Object.values(locations)) {
    objects.push({
      ref: `location/${l.name}`,
      class: "location",
      name: l.name,
      attributes: compact({ displayName: l.displayName, kind: l.kind, country: l.country, city: l.city, address: l.address, timezone: l.timezone, latitude: l.latitude, longitude: l.longitude }),
    });
  }
  objects.push({
    ref: "site",
    class: "site",
    name: code,
    attributes: compact({
      desired: { file: "site.json" },
      displayName: typeof site.displayName === "string" ? site.displayName : undefined,
      code,
      version: tappaasVersion ?? undefined,
      publicIp: typeof net.publicIp === "string" && net.publicIp ? net.publicIp : undefined,
      isp: typeof net.isp === "string" && net.isp ? net.isp : undefined,
      ipv6: typeof site.ipv6 === "boolean" ? site.ipv6 : undefined,
      primaryLocation: primary && locations[primary] ? { ref: `location/${primary}` } : undefined,
      stage: "operational",
    }),
  });

  objects.push({ ref: "cluster", class: "cluster", name: code, attributes: compact({ quorum: live?.quorate, stage: "operational", corosyncLinks: discover ? live?.corosync : undefined }) });

  // Nodes: every pvehost instance, and any member the cluster has that no
  // instance records yet (node reconcile registers it).
  const nodes = clusterNodes(configDir);
  const members = new Set(live?.members.map((m) => m.name) ?? []);
  const names = [...new Set([...nodes.map((n) => n.name), ...members])];
  for (const name of names) {
    const raw = readJsonObject(join(configDir, `${name}.json`)) ?? {};
    const cfg = nodes.find((n) => n.name === name);
    const host = live?.hosts[name];
    const ip = live?.members.find((m) => m.name === name)?.ip;
    const attrs: Obj = {
      ...(cfg ? moduleNodeAttributes(name, raw, "machine") : {}),
      hostname: host?.hostname ?? cfg?.address,
      os: host?.os,
      osVersion: host?.osVersion,
      addresses: host?.addresses ?? (ip ? [ip] : cfg ? [cfg.address] : undefined),
      clusterMember: live ? members.has(name) : true,
      storagePools: host?.pools ?? cfg?.storagePools,
      network: host?.network,
      environment: { class: "environment", name: "mgmt" },
      management: "managed",
      stage: "operational",
    };
    const found = discover && host?.discovery ? discoveryObjects(configDir, name, `machine/${name}`, host.discovery, attrs) : [];
    objects.push({ ref: `machine/${name}`, class: "machine", name, attributes: compact(attrs) }, ...found);
    if (!live || members.has(name)) relations.push({ type: "member-of", from: { ref: `machine/${name}` }, to: { ref: "cluster" } });
    const at = cfg?.location ?? (primary && locations[primary] ? primary : undefined);
    if (at && locations[at]) relations.push({ type: "at", from: { ref: `machine/${name}` }, to: { ref: `location/${at}` } });
    // The hypervisor is an app on the machine (D3: pve on tappaas1).
    if (host?.pveVersion) {
      objects.push({ class: "app", name: "pve", attributes: { version: host.pveVersion, onNode: { ref: `machine/${name}` }, upstream: { project: "proxmox-ve" } } });
    }
  }

  // Guests: a module's guest is that module's node CI.
  if (live) {
    const byVmid = new Map<number, { name: string; raw: Obj }>();
    for (const m of discoverModules(configDir)) {
      const v = num(m.raw.vmid);
      if (v !== undefined && m.raw.status !== "archived") byVmid.set(v, m);
    }
    const nameOf = new Map(live.guests.map((g) => [g.vmid, g.name]));
    for (const g of live.guests) {
      const cls = g.type === "lxc" ? "lxc" : "vm";
      const mod = byVmid.get(g.vmid);
      const name = mod?.name ?? g.name;
      const image = mod && mod.raw.imageType === "clone" ? num(mod.raw.image) : undefined;
      const attrs: Obj = {
        ...(mod ? moduleNodeAttributes(mod.name, mod.raw, cls) : {}),
        vmid: g.vmid,
        cores: g.cores,
        memory: g.memory,
        haPolicy: g.haPolicy,
        state: g.template ? "template" : g.status,
        onNode: g.node ? { class: "machine", name: g.node } : undefined,
        stage: "operational",
      };
      if (cls === "vm") {
        attrs.disks = g.disks;
        if (image !== undefined) attrs.template = nameOf.get(image) ?? String(image);
      } else {
        attrs.rootfs = g.rootfs;
        attrs.unprivileged = g.unprivileged;
        if (discover) attrs.disks = g.mountpoints;
      }
      if (discover) attrs.nics = g.nics;
      objects.push({ class: cls, name, attributes: compact(attrs) });
    }
  }

  return { source: SOURCE, kind: "observation", objects, relations };
}

/** What a node reconcile read — membership and pools — as an observation:
 *  the side effect of `node reconcile` / `reconcile` (D4: no new polling). */
export function membershipObservation(configDir: string, live: string[], pools: Map<string, string[]>): CmdbReport {
  const site = readJsonObject(join(configDir, "site.json")) ?? {};
  const code = typeof site.name === "string" && site.name ? site.name : "site";
  const objects: CmdbObject[] = [{ ref: "cluster", class: "cluster", name: code }];
  const relations: CmdbRelation[] = [];
  for (const name of live) {
    objects.push({ ref: `machine/${name}`, class: "machine", name, attributes: compact({ clusterMember: true, storagePools: pools.get(name) }) });
    relations.push({ type: "member-of", from: { ref: `machine/${name}` }, to: { ref: "cluster" } });
  }
  return { source: SOURCE, kind: "observation", objects, relations };
}

/** The node CI a node verb touched: config/<name>.json as it is now. */
export function nodeObject(configDir: string, name: string, end = false): CmdbObject {
  const raw = readJsonObject(join(configDir, `${name}.json`)) ?? {};
  const o: CmdbObject = { class: "machine", name, attributes: moduleNodeAttributes(name, raw, "machine") };
  if (end) o.end = true;
  return o;
}

/** The site and its locations as config/ has them: what `site modify` and the
 *  location verbs change. */
export function siteObjects(configDir: string): CmdbObject[] {
  return (siteObservation(configDir, null, null).objects ?? []).filter((o) => o.class === "site" || o.class === "location");
}

/** A SiteClient that keeps what the node slice of a reconcile reads, so it
 *  can be reported after (the client itself is unchanged). */
export function recordingClient<C extends { clusterNodes(c: string[]): string[] | null; nodeStoragePools(n: string): string[] | null }>(
  client: C,
): { client: C; live: () => string[] | null; pools: Map<string, string[]> } {
  let live: string[] | null = null;
  const pools = new Map<string, string[]>();
  const rec = Object.create(client) as C;
  rec.clusterNodes = (c: string[]) => (live = client.clusterNodes(c));
  rec.nodeStoragePools = (n: string) => {
    const p = client.nodeStoragePools(n);
    if (p !== null) pools.set(n, p);
    return p;
  };
  return { client: rec, live: () => live, pools };
}
