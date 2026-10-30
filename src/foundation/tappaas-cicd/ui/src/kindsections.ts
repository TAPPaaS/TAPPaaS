// kindsections.ts — the sections a module has by its kind (ADR-034 D11): a vm or
// lxc its Resources and Backups, a machine its Guests, Pools, Ports and links
// and Cluster membership, a device its Ports and, for an access point, its
// radios and SSIDs. Each reads the CMDB first; `health-manager guests` gives the
// live numbers; the topology and the storage inventory stand in when the CMDB
// has no record. Pure: reads.ts gathers the input.

import { CmdbEnd, CmdbObject, CmdbRelationRow, CmdbShow } from "./cmdb";
import { BackupRunsDoc, ModuleRow, StorageDoc } from "./model";
import { Block, Gauge, Section, section } from "./sections";

type Obj = Record<string, unknown>;

// `health-manager guests --json`, the parts read here.
export interface GuestLive {
  vmid: number;
  name: string;
  module: string | null;
  type: string;
  status: string;
  declaredMem: number;
  usedMem: number;
  residentMem: number;
  measured: boolean;
  availableMem?: number;
  cacheMem?: number;
  ha?: boolean;
}
export interface VolumeLive {
  module: string | null;
  vmid: number;
  pool: string;
  volume: string;
  used: number;
  size: number | null;
  replica: boolean;
}
export interface NodeLive {
  node: string;
  physicalMem: number;
  usedMem: number;
  committedMem: number;
  guests: GuestLive[];
  volumes: VolumeLive[];
}

// What the CMDB says about one module's node object.
export interface CmdbView {
  self: CmdbObject;
  relations: CmdbShow["relations"];
  objects: Map<string, CmdbObject>; // the objects its relations reach, by id
  asset: CmdbObject | null; // the box allocated to it
  ports: CmdbObject[]; // that box's ports
  connects: CmdbRelationRow[]; // the cables and SSIDs on those ports
  owners: Map<string, string>; // a port's id → its box's name
  members: CmdbEnd[]; // who else is in its cluster
}

export interface KindInput {
  module: Pick<ModuleRow, "name" | "kind" | "vmid" | "node" | "actualNode" | "running">;
  cmdb: CmdbView | null;
  cmdbError: string | null;
  live: NodeLive[] | null;
  liveError: string | null;
  modules: ModuleRow[];
  topology: Obj | null;
  storage: StorageDoc | null;
  backup: { policy?: Obj; coverage?: Obj } | null;
  runs: BackupRunsDoc | null;
  snapshots: string | null;
  snapshotsError: string | null;
  ssids: Obj[] | null;
}

const MIB = 1024 * 1024;
const arr = (v: unknown): Obj[] => (Array.isArray(v) ? (v as Obj[]) : []);
const obj = (v: unknown): Obj => (typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Obj) : {});
const num = (v: unknown): number | null => (typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : null);
const nameOf = (v: unknown): string | null => (typeof v === "string" ? v : typeof obj(v).name === "string" ? (obj(v).name as string) : null);
const attr = (o: CmdbObject | null | undefined, k: string): unknown => o?.attributes?.[k];

// The sources behind a section, and what could not be read: a note, never a gap.
function notes(i: KindInput, live: boolean): Block[] {
  return [
    ...(i.cmdb ? [] : [{ kind: "note" as const, text: i.cmdbError ? `The CMDB did not answer: ${i.cmdbError}` : "The CMDB holds no record of this object yet." }]),
    ...(live && i.liveError ? [{ kind: "note" as const, text: `No live numbers: ${i.liveError}` }] : []),
  ];
}
const sourceOf = (i: KindInput, ...others: string[]): string => [...(i.cmdb ? ["CMDB"] : []), ...others].join(" · ");
const related = (i: KindInput, type: string, direction: "in" | "out", cls?: string[]): CmdbObject[] =>
  (i.cmdb?.relations ?? [])
    .filter((r) => r.type === type && r.direction === direction && (!cls || cls.includes(r.other.class)))
    .map((r) => i.cmdb!.objects.get(r.other.id) ?? { id: r.other.id, class: r.other.class, name: r.other.name, attributes: {} });
const topoDevice = (i: KindInput, list: string): Obj | null => arr(i.topology?.[list]).find((d) => d.name === i.module.name || d.lldpName === i.module.name) ?? null;

// ── vm and lxc ───────────────────────────────────────────────────────

function resources(i: KindInput): Section {
  const m = i.module;
  const self = i.cmdb?.self ?? null;
  const g = (i.live ?? []).flatMap((n) => n.guests).find((x) => x.vmid === m.vmid) ?? null;
  const declaredMib = num(attr(self, "memory"));
  const declared = g?.declaredMem ?? (declaredMib === null ? null : declaredMib * MIB);
  const host = nameOf(attr(self, "onNode")) ?? related(i, "runs-on", "out")[0]?.name ?? m.actualNode ?? m.node;
  const ha = g?.ha === undefined ? null : g.ha ? "an HA resource" : "not HA";
  const blocks: Block[] = [...notes(i, true)];
  if (g && declared) blocks.push({ kind: "gauges", gauges: [{ label: g.measured ? "memory in use" : "memory in use (the host's view: the guest reports none)", value: g.usedMem, max: declared, format: "bytes" }] });
  blocks.push({
    kind: "kv",
    rows: [
      { label: "memory declared", value: declared, format: "bytes" },
      { label: "allocated", value: g && g.residentMem > 0 ? g.residentMem : null, format: "bytes" },
      { label: "used", value: g?.measured ? g.usedMem : null, format: "bytes" },
      { label: "available", value: g?.availableMem ?? null, format: "bytes" },
      { label: "page cache", value: g?.cacheMem ?? null, format: "bytes" },
      { label: "cores", value: num(attr(self, "cores")) },
      { label: "node", value: host, format: "module" },
      { label: "run state", value: g?.status ?? m.running, format: "status" },
      { label: "HA", value: [attr(self, "haPolicy"), ha].filter(Boolean).join(" · ") || null },
    ],
  });
  const volumes = (i.live ?? []).flatMap((n) => n.volumes.filter((v) => v.vmid === m.vmid).map((v) => ({ ...v, node: n.node })));
  const rootfs = typeof attr(self, "rootfs") === "string" ? [{ storage: String(attr(self, "rootfs")).split(":")[0], size: null }] : [];
  const declaredDisks = [...rootfs, ...arr(attr(self, "disks"))];
  blocks.push(
    volumes.length
      ? {
          kind: "table",
          title: "Disks and their pools",
          columns: [{ key: "pool", label: "pool" }, { key: "volume", label: "volume" }, { key: "node", label: "on" }, { key: "size", label: "size", format: "bytes" }, { key: "used", label: "used", format: "bytes" }, { key: "copy", label: "" }],
          rows: volumes.map((v) => ({ pool: v.pool, volume: v.volume, node: v.node, size: v.size, used: v.used, copy: v.replica ? "replica" : "" })),
        }
      : {
          kind: "table",
          title: "Disks and their pools",
          columns: [{ key: "storage", label: "pool" }, { key: "size", label: "size" }],
          rows: declaredDisks.map((d) => ({ storage: d.storage ?? null, size: d.size ?? null })),
          empty: "no disks recorded",
        },
  );
  blocks.push(i.snapshots !== null ? { kind: "text", title: "Snapshots", text: i.snapshots.trim() || "none" } : { kind: "note", text: `Snapshots could not be read: ${i.snapshotsError ?? "not read"}` });
  return section("resources", "Resources", "kind", { source: sourceOf(i, "health-manager guests", "module-manager snapshot-vm"), blocks });
}

function backups(i: KindInput): Section {
  const p = obj(i.backup?.policy);
  const c = obj(i.backup?.coverage);
  const run = (i.runs?.guests ?? []).find((g) => g.module === i.module.name) as (Obj & { outcome?: string; latestVerify?: string }) | undefined;
  const jobs = arr(c.jobs);
  return section("backups", "Backups", "kind", {
    source: "backup-manager",
    blocks: i.backup
      ? [{
          kind: "kv",
          rows: [
            { label: "enabled", value: p.enabled ?? null },
            { label: "in the PBS job", value: p.inPbsJob ?? null },
            { label: "schedule", value: p.schedule ?? null },
            { label: "retention", value: p.retention ?? null },
            { label: "last backup", value: run?.outcome ?? null, format: "status" },
            { label: "last verify", value: run?.latestVerify ?? null, format: "status" },
            { label: "PBS jobs", value: jobs.length ? jobs.map((j) => j.storage).join(", ") : null },
          ],
        }]
      : [{ kind: "note", text: "The backup policy could not be read." }],
  });
}

// ── a machine ────────────────────────────────────────────────────────

function guestsOf(i: KindInput): Section {
  const name = i.module.name;
  const live = (i.live ?? []).find((n) => n.node === name)?.guests ?? [];
  const module = (n: string): ModuleRow | undefined => i.modules.find((x) => x.name === n);
  const rows = new Map<string, Obj>();
  const put = (key: string, row: Obj): void => void rows.set(key, { ...rows.get(key), ...row });
  const onIt = i.cmdb ? related(i, "runs-on", "in", ["vm", "lxc"]) : arr(arr(i.topology?.nodes).find((n) => n.name === name)?.guests).map((g) => ({ id: "", class: String(g.kind), name: String(g.module), attributes: { vmid: g.vmid } }) as CmdbObject);
  for (const o of onIt) {
    const vmid = num(attr(o, "vmid"));
    const mib = num(attr(o, "memory"));
    put(String(vmid ?? o.name), { module: o.name, kind: o.class, vmid, state: module(o.name)?.running ?? null, declared: mib === null ? null : mib * MIB, used: null, ha: null });
  }
  for (const g of live) {
    put(String(g.vmid), { module: g.module ?? g.name, kind: g.type === "qemu" ? "vm" : g.type, vmid: g.vmid, state: g.status, declared: g.declaredMem, used: g.measured ? g.usedMem : null, ha: g.ha ? "HA" : "" });
  }
  const sorted = [...rows.values()].sort((a, b) => Number(b.declared ?? 0) - Number(a.declared ?? 0));
  return section("guests", "Guests", "kind", {
    source: sourceOf(i, "health-manager guests"),
    blocks: [...notes(i, true), {
      kind: "table",
      columns: [{ key: "module", label: "guest", format: "module" }, { key: "kind", label: "kind" }, { key: "vmid", label: "id" }, { key: "state", label: "state", format: "status" }, { key: "declared", label: "declared", format: "bytes" }, { key: "used", label: "used", format: "bytes" }, { key: "ha", label: "HA" }],
      rows: sorted,
      empty: "nothing runs here",
    }],
  });
}

function poolGauge(label: string, used: number, size: number, state: string | null): Gauge {
  const level = !state || state === "ONLINE" ? undefined : state === "DEGRADED" ? "warn" : "fail";
  return { label: state ? `${label} · ${state}` : label, value: used, max: size, format: "bytes", level };
}

function pools(i: KindInput): Section {
  const recorded = related(i, "runs-on", "in", ["storage-pool"]);
  const inv = (i.storage?.nodes ?? []).find((n) => n.name === i.module.name);
  const gauges = recorded.length
    ? recorded.flatMap((p) => {
        const size = num(attr(p, "size"));
        return size === null ? [] : [poolGauge(p.name, num(attr(p, "used")) ?? 0, size, nameOf(attr(p, "zfsState")))];
      })
    : (inv?.pools ?? []).flatMap((raw) => {
        const p = raw as unknown as Obj;
        const u = obj(p.usable);
        const size = num(u.total) ?? num(p.size);
        return size === null ? [] : [poolGauge(String(p.name), num(u.used) ?? num(p.allocated) ?? 0, size, nameOf(p.health))];
      });
  return section("pools", "Pools", "kind", {
    source: recorded.length ? "CMDB" : "storage-manager inventory",
    blocks: [{ kind: "gauges", gauges, empty: "no pools on this machine" }],
  });
}

const PORT_COLUMNS = [{ key: "port", label: "port" }, { key: "kind", label: "kind" }, { key: "speed", label: "speed" }, { key: "link", label: "link", format: "status" as const }, { key: "role", label: "role" }, { key: "connects", label: "connects to" }];

// What each recorded port's cable reaches: <box>:<port>, or an SSID.
function portRows(v: CmdbView): Obj[] {
  const other = (id: string): string[] =>
    v.connects
      .filter((c) => c.from.id === id || c.to.id === id)
      .map((c) => (c.from.id === id ? c.to : c.from))
      .map((e) => (v.owners.has(e.id) ? `${v.owners.get(e.id)}:${e.name}` : e.name));
  return v.ports.map((p) => ({
    port: p.name,
    kind: attr(p, "kind") ?? null,
    speed: attr(p, "linkSpeed") ?? attr(p, "speed") ?? null,
    link: attr(p, "link") ?? null,
    role: attr(p, "role") ?? null,
    connects: other(p.id).join(", ") || null,
  }));
}

function nodePorts(i: KindInput): Section {
  const legs = arr(arr(i.topology?.nodes).find((n) => n.name === i.module.name)?.uplinks).flatMap((u) => arr(u.legs).map((l): Obj => ({ ...l, uplink: u.name })));
  const nics = arr(attr(i.cmdb?.asset, "nics")).length ? arr(attr(i.cmdb?.asset, "nics")) : arr(attr(i.cmdb?.self, "nics"));
  const speedOf = (nic: string): unknown => legs.find((l) => l.nic === nic)?.speed ?? null;
  const reach = (nic: string): string | null => {
    const p = obj(legs.find((l) => l.nic === nic)?.peer);
    return typeof p.switch === "string" ? `${p.switch}:${String(p.port)}` : null;
  };
  let rows: Obj[];
  if (i.cmdb?.ports.length) rows = portRows(i.cmdb);
  else if (nics.length) rows = nics.map((n) => ({ port: n.name ?? null, kind: n.kind ?? null, speed: n.speed ?? speedOf(String(n.name)), link: n.link === true ? "up" : n.link === false ? "down" : null, role: n.bond ?? n.bridge ?? null, connects: reach(String(n.name)) }));
  else rows = legs.map((l) => ({ port: l.nic ?? null, kind: null, speed: l.speed ?? null, link: l.up === true ? "up" : "down", role: l.uplink ?? null, connects: reach(String(l.nic)) }));
  return section("ports", "Ports and links", "kind", {
    source: i.cmdb?.ports.length || nics.length ? "CMDB" : "network-manager topology",
    blocks: [{ kind: "table", columns: PORT_COLUMNS, rows, empty: "no ports recorded" }],
  });
}

function cluster(i: KindInput): Section {
  const c = related(i, "member-of", "out", ["cluster"])[0] ?? null;
  const env = related(i, "member-of", "out", ["environment"])[0]?.name ?? nameOf(attr(i.cmdb?.self, "environment"));
  const t = arr(i.topology?.nodes).find((n) => n.name === i.module.name) ?? null;
  const member = attr(i.cmdb?.self, "clusterMember") ?? (c ? true : t ? t.kind === "cluster-member" : null);
  const corosync = obj(t?.corosync);
  return section("cluster", "Cluster membership", "kind", {
    source: sourceOf(i, "network-manager topology"),
    blocks: [...notes(i, false), {
      kind: "kv",
      rows: [
        { label: "member", value: member },
        { label: "cluster", value: c?.name ?? null },
        { label: "quorum", value: attr(c, "quorum") ?? null },
        { label: "other members", value: (i.cmdb?.members ?? []).filter((x) => x.name !== i.module.name).map((x) => x.name).join(", ") || null },
        { label: "corosync links", value: num(corosync.links) ?? null },
        { label: "disconnected links", value: num(corosync.disconnected) ?? null },
        { label: "HA", value: obj(t?.ha).lrm ?? null },
        { label: "roles", value: arr(t?.roles).join(", ") || null },
        { label: "environment", value: env },
      ],
    }],
  });
}

// ── a device ─────────────────────────────────────────────────────────

function devicePorts(i: KindInput): Section {
  const sw = topoDevice(i, "switches");
  const ap = topoDevice(i, "accessPoints");
  let rows: Obj[];
  if (i.cmdb?.ports.length) rows = portRows(i.cmdb);
  else if (sw) {
    rows = arr(sw.ports).map((p) => {
      const t = obj(p.target);
      return { port: p.port ?? null, kind: p.type ?? null, speed: null, link: null, role: p.role ?? null, connects: typeof t.name === "string" ? `${t.name}${t.port ? `:${String(t.port)}` : ""}` : null };
    });
  } else {
    const up = obj(ap?.uplink);
    rows = typeof up.switch === "string" ? [{ port: "uplink", kind: null, speed: null, link: null, role: "uplink", connects: `${up.switch}:${String(up.port)}` }] : [];
  }
  return section("ports", "Ports and what they connect", "kind", {
    source: i.cmdb?.ports.length ? "CMDB" : "network-manager topology",
    blocks: [...notes(i, false), { kind: "table", columns: PORT_COLUMNS, rows, empty: "no ports recorded" }],
  });
}

function radios(i: KindInput): Section {
  const radioPorts = (i.cmdb?.ports ?? []).filter((p) => attr(p, "kind") === "wifi");
  const onAir = new Map<string, CmdbObject | null>();
  for (const c of i.cmdb?.connects ?? []) {
    for (const e of [c.from, c.to]) if (e.class === "ssid") onAir.set(e.name, i.cmdb!.objects.get(e.id) ?? null);
  }
  const ap = topoDevice(i, "accessPoints");
  // The topology's SSIDs of this access point, and ap-manager's that name it.
  for (const s of arr(ap?.ssids)) if (typeof s.name === "string" && !onAir.has(s.name)) onAir.set(s.name, null);
  const listed = new Map((i.ssids ?? []).map((s) => [String(s.name), s]));
  for (const s of listed.values()) {
    if (Array.isArray(s.accessPoints) && s.accessPoints.includes(i.module.name) && !onAir.has(String(s.name))) onAir.set(String(s.name), null);
  }
  return section("radios", "Radios and SSIDs", "kind", {
    source: sourceOf(i, "ap-manager"),
    blocks: [
      {
        kind: "table",
        title: "Radios",
        columns: [{ key: "radio", label: "radio" }, { key: "standard", label: "standard" }, { key: "bands", label: "bands" }],
        rows: radioPorts.map((p) => ({ radio: p.name, standard: attr(p, "standard") ?? null, bands: arr(attr(p, "bands")).join(", ") || null })),
        empty: "no radios recorded",
      },
      {
        kind: "table",
        title: "SSIDs",
        columns: [{ key: "ssid", label: "SSID" }, { key: "zone", label: "zone" }, { key: "security", label: "security" }],
        rows: [...onAir].map(([name, o]) => ({ ssid: name, zone: nameOf(attr(o, "zone")) ?? listed.get(name)?.zone ?? null, security: attr(o, "security") ?? listed.get(name)?.security ?? null })),
        empty: "no SSIDs on this access point",
      },
    ],
  });
}

const isAccessPoint = (i: KindInput): boolean => attr(i.cmdb?.asset, "deviceType") === "access-point" || topoDevice(i, "accessPoints") !== null;

export function kindSections(i: KindInput): Section[] {
  switch (i.module.kind) {
    case "vm":
    case "lxc":
      return [resources(i), backups(i)];
    case "machine":
      return [guestsOf(i), pools(i), nodePorts(i), cluster(i)];
    case "device":
      return [devicePorts(i), ...(isAccessPoint(i) ? [radios(i)] : [])];
    default:
      return [];
  }
}
