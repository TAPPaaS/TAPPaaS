// inventory.ts — `storage-manager inventory`: the site's storage as one derived
// document. Per cluster node: its boot device, its ZFS pools with their vdevs and
// physical disks, what each pool holds (the guests' volumes — their own, or the
// HA mirror copy of a guest that runs on another node — the PBS datastore, NFS
// shares, other datasets) and the free space; the replication jobs; and every
// entity's state (ok | warn | fail, with the reasons) for the console to colour.
// It stores nothing.
//
// The sources, all read-only:
//   the node records          the nodes (their pvehost instances) and the
//                             storagePools each declares (lib/ts nodes.ts)
//   per node, one ssh probe   (lib/ts cluster.ts nodeStorageProbe) disks/list,
//                             SMART per disk, zpool list/status, zfs list,
//                             lsblk, replication state, exported pools, PBS
//   pvesh /cluster/resources  which node each guest runs on
//   pvesh /cluster/replication  each job's guest, source, target, schedule
//   module-manager list       the module name behind a vmid
//   config/shares.json        which dataset is which NFS share
//
// buildInventory() is pure (the unit tests run it over hrossen's captured
// outputs); collectSources() runs the reads.

import { join } from "path";
import {
  ClusterGuest,
  ProbeSection,
  queryClusterGuests,
  queryClusterReplication,
  queryNodeStorage,
} from "../../../lib/ts/src/cluster";
import { ExecResult, captureResult } from "../../../lib/ts/src/exec";
import { clusterNodes as listClusterNodes } from "../../../lib/ts/src/nodes";
import { readJsonObject } from "../../../lib/ts/src/config-io";

// ── the document ──────────────────────────────────────────────────────

export type State = "ok" | "warn" | "fail";

export interface Smart {
  read: boolean; // false under --no-smart, or when the read failed
  health: "passed" | "failed" | "unknown";
  temperature: number | null; // °C
  reallocated: number | null; // sectors (ATA 5, SCSI grown defects)
  pending: number | null; // sectors (ATA 197)
  uncorrectable: number | null; // sectors (ATA 198) or reported (ATA 187)
  mediaErrors: number | null; // NVMe media and data integrity errors
  criticalWarning: number | null; // NVMe critical warning bits
  powerOnHours: number | null;
}

export interface ZfsDevice {
  pool: string;
  vdev: string;
  state: string; // ONLINE | DEGRADED | FAULTED | UNAVAIL | REMOVED | OFFLINE
  read: number;
  write: number;
  cksum: number;
  msg: string | null;
}

export interface Disk {
  device: string; // /dev/sdb
  byId: string | null;
  model: string | null;
  serial: string | null;
  wwn: string | null;
  size: number; // bytes
  type: "ssd" | "hdd" | "nvme" | "unknown";
  wearout: number | null; // % of rated life left (Proxmox's figure; 100 = new)
  smart: Smart;
  zfs: ZfsDevice | null; // its state as a pool member
  exportedPool: { name: string; state: string; deviceState: string } | null; // member of a pool not imported
  state: State;
  reasons: string[];
}

export interface Vdev {
  name: string; // mirror-0, raidz1-0, or the disk itself for a stripe
  type: "mirror" | "raidz" | "draid" | "stripe";
  parity: number | null; // raidz1/2/3
  role: "data" | "log" | "cache" | "spare" | "special" | "dedup";
  health: string; // ZFS's: ONLINE | DEGRADED | FAULTED | …
  state: State; // ONLINE ok, DEGRADED warn, anything else fail
  disks: Disk[];
  // Members ZFS names that are not among the node's disks (pulled, dead).
  missing: { name: string; state: string }[];
}

export type VolumeKind = "own" | "mirror" | "template" | "orphan";

export interface Volume {
  name: string; // tanka1/vm-110-disk-0
  vmid: number;
  module: string | null; // the module behind the vmid (module-manager list)
  guest: string | null; // the guest's name in Proxmox
  kind: VolumeKind;
  runsOn: string | null; // the node the guest runs on
  type: "volume" | "filesystem"; // zvol (VM disk) or subvol (container)
  size: number | null; // provisioned: volsize, or a subvol's refquota
  used: number; // what it takes from the pool: data, snapshots, reservation
  refer: number; // data written
  snapshots: number; // of `used`, held by snapshots
  // A mirror's (or a stale copy's) replication: the job, and when the last
  // replicated snapshot was taken (from its __replicate_<job>_<epoch>__ name).
  replica: { job: string | null; source: string | null; lastSync: string | null } | null;
  mirroredOn: string[]; // an own volume's replication targets: where its HA copy lives
  note: string | null;
}

export type DatasetKind = "pbs-datastore" | "nfs-share" | "dataset" | "volume";

export interface Dataset {
  name: string; // dataset, or <dataset>:<dir> for a datastore in a directory
  kind: DatasetKind;
  label: string; // tappaas_backup (PBS), media (NFS share), …
  mountpoint: string | null;
  used: number;
  // false when the number is the enclosing dataset's own data (a datastore that
  // is a directory, not a dataset of its own).
  exact: boolean;
}

export interface Scrub {
  state: "none" | "running" | "finished" | "canceled" | "resilvering" | "resilvered" | "unknown";
  last: string | null; // ISO, when it finished (or started, when running)
  errors: number | null;
  text: string | null; // zpool status' scan line
}

export interface Pool {
  name: string;
  declared: boolean; // in the node's storagePools (its pvehost record)
  present: boolean; // imported on the node
  health: string; // ONLINE | DEGRADED | FAULTED | UNAVAIL | SUSPENDED | MISSING
  status: string | null; // zpool status' status/action text
  size: number; // raw (zpool list)
  allocated: number;
  free: number;
  fragmentation: number | null; // %
  dedup: number | null; // ratio
  compression: string | null;
  compressRatio: number | null;
  // The dataset view — what Proxmox and the storage-pools gate count: used of
  // used+avail on the pool's top dataset.
  usable: { total: number; used: number; avail: number; pct: number } | null;
  scrub: Scrub;
  vdevs: Vdev[];
  volumes: Volume[];
  datasets: Dataset[];
  // The pie: own + mirror + other + free = total (the dataset view).
  totals: { total: number; own: number; mirror: number; other: number; free: number };
  state: State;
  reasons: string[];
}

export interface Replication {
  id: string; // 110-0
  vmid: number;
  module: string | null;
  source: string;
  target: string;
  schedule: string;
  lastSync: string | null;
  nextSync: string | null;
  failCount: number;
  error: string | null;
  state: State;
  reasons: string[];
}

export interface InvNode {
  name: string;
  reachable: boolean;
  boot: Disk[]; // the disk(s) holding / and /boot/efi
  pools: Pool[];
  otherDisks: Disk[]; // in no imported pool and not the boot device
  replication: Replication[]; // jobs sourced on this node
  state: State;
  reasons: string[];
}

export interface Finding {
  level: "warn" | "fail";
  cause: "smart" | "zfs" | "wear" | "temperature" | "health" | "usage" | "scrub" | "replication";
  on: { kind: "disk" | "pool" | "replication" | "node"; node: string; name: string };
  text: string;
}

export interface Inventory {
  version: 1;
  generated: string;
  smart: boolean; // false: --no-smart, the disks' SMART was not read
  nodes: InvNode[];
  findings: Finding[];
  sources: { name: string; ok: boolean; error: string | null }[];
}

// ── the thresholds behind the colours ─────────────────────────────────
// Pool usage: the storage-pools gate's (health-manager POOL_WARN/POOL_FAIL).
export const POOL_WARN = 80;
export const POOL_FAIL = 90;
export const WEAR_WARN = 20; // % life left
export const WEAR_FAIL = 10;
export const TEMP_WARN = { hdd: 60, ssd: 60, nvme: 70, unknown: 60 };
export const SCRUB_MAX_DAYS = 40; // Proxmox scrubs monthly
export const DEVICE_FAIL_STATES = ["DEGRADED", "FAULTED", "UNAVAIL", "REMOVED"];

// ── parsers (pure) ────────────────────────────────────────────────────

const num = (v: unknown): number | null => {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && /^-?\d+(\.\d+)?$/.test(v.trim())) return Number(v.trim());
  return null;
};
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);

// An error count as zpool status prints it: exact with -p, "17.6K" without.
export function zpoolCount(s: string): number {
  const m = /^(\d+(?:\.\d+)?)([KMGT])?$/.exec(s);
  if (!m) return 0;
  const mult = { K: 1e3, M: 1e6, G: 1e9, T: 1e12 }[m[2] as "K"] ?? 1;
  return Math.round(Number(m[1]) * mult);
}

export interface ZpoolRow {
  name: string;
  depth: number; // 0 = the pool (or a group header), 1 = top-level vdev, 2 = its member
  state: string | null;
  read: number;
  write: number;
  cksum: number;
  msg: string | null;
}

export interface ZpoolStatus {
  pool: string;
  state: string;
  status: string | null;
  action: string | null;
  scan: string | null;
  rows: ZpoolRow[];
  errors: string | null;
}

// `zpool status -P -p` (and the config table of `zpool import`).
export function parseZpoolStatus(text: string): ZpoolStatus[] {
  const out: ZpoolStatus[] = [];
  let cur: ZpoolStatus | null = null;
  let field: "status" | "action" | "scan" | null = null;
  let inConfig = false;
  for (const raw of text.split("\n")) {
    const kv = /^\s*(pool|state|status|action|scan|see|config|errors|id):\s?(.*)$/.exec(raw);
    if (kv && !(inConfig && raw.startsWith("\t"))) {
      const [, key, val] = kv;
      inConfig = false;
      field = null;
      if (key === "pool") {
        cur = { pool: val.trim(), state: "", status: null, action: null, scan: null, rows: [], errors: null };
        out.push(cur);
      } else if (!cur) continue;
      else if (key === "state") cur.state = val.trim();
      else if (key === "status" || key === "action" || key === "scan") {
        cur[key] = val.trim();
        field = key;
      } else if (key === "config") inConfig = true;
      else if (key === "errors") cur.errors = val.trim();
      continue;
    }
    if (!cur) continue;
    if (inConfig) {
      if (!raw.startsWith("\t")) continue;
      const body = raw.slice(1);
      const indent = body.length - body.trimStart().length;
      const f = body.trim().split(/\s+/);
      if (f.length === 0 || f[0] === "" || f[0] === "NAME") continue;
      const counted = f.length >= 5 && f.slice(2, 5).every((x) => /^\d+(\.\d+)?[KMGT]?$/.test(x));
      cur.rows.push({
        name: f[0],
        depth: Math.floor(indent / 2),
        state: f[1] ?? null,
        read: counted ? zpoolCount(f[2]) : 0,
        write: counted ? zpoolCount(f[3]) : 0,
        cksum: counted ? zpoolCount(f[4]) : 0,
        msg: counted ? f.slice(5).join(" ") || null : f.slice(2).join(" ") || null,
      });
      continue;
    }
    // A wrapped status/action/scan line continues with a tab.
    if (field && /^\t/.test(raw)) cur[field] = `${cur[field] ?? ""} ${raw.trim()}`.trim();
  }
  return out;
}

export interface ZpoolListRow {
  name: string;
  size: number;
  alloc: number;
  free: number;
  frag: number | null;
  cap: number | null;
  dedup: number | null;
  health: string;
}

// `zpool list -Hp -o name,size,alloc,free,frag,cap,dedup,health`
export function parseZpoolList(text: string): ZpoolListRow[] {
  return text
    .split("\n")
    .map((l) => l.split("\t"))
    .filter((f) => f.length >= 8 && f[0])
    .map((f) => ({
      name: f[0],
      size: num(f[1]) ?? 0,
      alloc: num(f[2]) ?? 0,
      free: num(f[3]) ?? 0,
      frag: num(f[4]),
      cap: num(f[5]),
      dedup: num(f[6]),
      health: f[7].trim(),
    }));
}

export interface ZfsRow {
  name: string;
  type: "filesystem" | "volume" | "snapshot" | string;
  used: number;
  avail: number | null;
  refer: number;
  volsize: number | null;
  refquota: number | null;
  usedsnap: number;
  origin: string | null;
  mountpoint: string | null;
  compression: string | null;
  compressratio: number | null;
}

// `zfs list -Hp -o name,type,used,avail,refer,volsize,refquota,usedsnap,origin,mountpoint,compression,compressratio`
export function parseZfsList(text: string): ZfsRow[] {
  const dash = (s: string | undefined): string | null => (s === undefined || s === "-" || s === "none" ? null : s);
  return text
    .split("\n")
    .map((l) => l.split("\t"))
    .filter((f) => f.length >= 12 && f[0])
    .map((f) => ({
      name: f[0],
      type: f[1],
      used: num(f[2]) ?? 0,
      avail: num(f[3]),
      refer: num(f[4]) ?? 0,
      volsize: num(f[5]),
      refquota: num(f[6]) || null,
      usedsnap: num(f[7]) ?? 0,
      origin: dash(f[8]),
      mountpoint: dash(f[9]),
      compression: dash(f[10]),
      compressratio: num(f[11]),
    }));
}

// The pvesh SMART reply (/nodes/<n>/disks/smart): ATA attributes, or the text
// smartctl prints for NVMe and SCSI.
export function parseSmart(doc: Record<string, unknown> | null): Smart {
  const s: Smart = {
    read: doc !== null,
    health: "unknown",
    temperature: null,
    reallocated: null,
    pending: null,
    uncorrectable: null,
    mediaErrors: null,
    criticalWarning: null,
    powerOnHours: null,
  };
  if (!doc) return s;
  s.health = smartHealth(doc.health);
  const firstInt = (raw: unknown): number | null => {
    const m = /^\s*(\d+)/.exec(String(raw ?? ""));
    return m ? Number(m[1]) : null;
  };
  if (Array.isArray(doc.attributes)) {
    const attr = new Map<number, unknown>();
    for (const a of doc.attributes as Record<string, unknown>[]) attr.set(Number(String(a.id).trim()), a.raw);
    const get = (id: number): number | null => (attr.has(id) ? firstInt(attr.get(id)) : null);
    s.reallocated = get(5);
    s.pending = get(197);
    s.uncorrectable = get(198) ?? get(187);
    // Some SSDs report 0 in attribute 194: no sensor, not a cold disk.
    s.temperature = get(194) || get(190) || null;
    s.powerOnHours = get(9);
  }
  const text = typeof doc.text === "string" ? doc.text : "";
  if (text) {
    const field = (re: RegExp): number | null => {
      const m = re.exec(text);
      return m ? Number(m[1].replace(/,/g, "")) : null;
    };
    s.temperature ??= field(/^Temperature:\s+(\d+) Celsius/m) ?? field(/^Current Drive Temperature:\s+(\d+) C/m);
    s.mediaErrors = field(/^Media and Data Integrity Errors:\s+([\d,]+)/m);
    const cw = /^Critical Warning:\s+(0x[0-9a-fA-F]+)/m.exec(text);
    s.criticalWarning = cw ? parseInt(cw[1], 16) : null;
    s.powerOnHours ??= field(/^Power On Hours:\s+([\d,]+)/m) ?? field(/^\s*Accumulated power on time, hours:minutes\s+([\d,]+)/m);
    s.reallocated ??= field(/^Elements in grown defect list:\s+([\d,]+)/m);
  }
  return s;
}

function smartHealth(v: unknown): Smart["health"] {
  const h = String(v ?? "").toUpperCase();
  if (h === "PASSED" || h === "OK") return "passed";
  if (h === "FAILED" || h.startsWith("FAIL")) return "failed";
  return "unknown";
}

interface BlockDev {
  name: string;
  type?: string;
  mountpoints?: (string | null)[];
  children?: BlockDev[];
}

// lsblk -J: the whole disks whose partitions (or the LVM on them) carry / or the
// EFI system partition.
export function bootDevices(doc: Record<string, unknown> | null): string[] {
  const devs = Array.isArray(doc?.blockdevices) ? (doc!.blockdevices as BlockDev[]) : [];
  const holds = (d: BlockDev): boolean =>
    (d.mountpoints ?? []).some((m) => m === "/" || m === "/boot/efi" || m === "/boot") || (d.children ?? []).some(holds);
  return devs.filter((d) => d.type === "disk" && holds(d)).map((d) => d.name);
}

// `__replicate_<job>_<epoch>__` → the job and the time.
export function replicateSnapshot(snap: string): { job: string; at: string } | null {
  const m = /^__replicate_(\d+-\d+)_(\d+)__$/.exec(snap);
  return m ? { job: m[1], at: new Date(Number(m[2]) * 1000).toISOString() } : null;
}

// A zpool status scan line → when the last scrub ran and how it ended.
export function parseScan(scan: string | null): Scrub {
  if (!scan) return { state: "unknown", last: null, errors: null, text: null };
  const when = (s: string | undefined): string | null => {
    if (!s) return null;
    const t = Date.parse(s.replace(/^\w{3} /, ""));
    return Number.isFinite(t) ? new Date(t).toISOString() : null;
  };
  let m: RegExpExecArray | null;
  if (/none requested/.test(scan)) return { state: "none", last: null, errors: null, text: scan };
  if ((m = /^scrub repaired .* with (\d+) errors on (.+)$/.exec(scan))) return { state: "finished", last: when(m[2]), errors: Number(m[1]), text: scan };
  if ((m = /^resilvered .* with (\d+) errors on (.+)$/.exec(scan))) return { state: "resilvered", last: when(m[2]), errors: Number(m[1]), text: scan };
  if ((m = /^scrub in progress since (.+?)(?:\s+\d.*)?$/.exec(scan))) return { state: "running", last: when(m[1]), errors: null, text: scan };
  if ((m = /^resilver in progress since (.+?)(?:\s+\d.*)?$/.exec(scan))) return { state: "resilvering", last: when(m[1]), errors: null, text: scan };
  if ((m = /^scrub canceled on (.+)$/.exec(scan))) return { state: "canceled", last: when(m[1]), errors: null, text: scan };
  return { state: "unknown", last: null, errors: null, text: scan };
}

// A schedule's interval in minutes, where it is a plain one ("*/15", "15",
// "hourly", "daily", "HH:MM"); null for a calendar event this does not read.
export function scheduleMinutes(schedule: string): number | null {
  const s = schedule.trim();
  let m: RegExpExecArray | null;
  if ((m = /^\*\/(\d+)$/.exec(s))) return Number(m[1]);
  if (/^\d+$/.test(s)) return 60; // a minute of every hour
  if (s === "hourly") return 60;
  if (s === "daily" || /^\d{1,2}:\d{2}$/.test(s)) return 24 * 60;
  if (s === "weekly") return 7 * 24 * 60;
  if ((m = /^\*:\*\/(\d+)$/.exec(s))) return Number(m[1]);
  return null;
}

// ── the sources ───────────────────────────────────────────────────────

export interface NodeSources {
  sections: Record<string, ProbeSection> | null; // null: unreachable
}

export interface ModuleRow {
  name: string;
  vmid: number | null;
}

export interface InvSources {
  // The cluster's nodes and their declared pools (clusterNodes), in node order.
  clusterNodes: { name: string; storagePools: string[] }[];
  only: string | null; // --node
  smart: boolean;
  nodes: Record<string, NodeSources>;
  guests: ClusterGuest[] | null;
  replicationJobs: Record<string, unknown>[] | null;
  modules: ModuleRow[] | null;
  shares: Record<string, unknown> | null;
  errors: { source: string; error: string }[];
}

// ── the join (pure) ───────────────────────────────────────────────────

const rank: Record<State, number> = { ok: 0, warn: 1, fail: 2 };
const worst = (...s: State[]): State => s.reduce((a, b) => (rank[b] > rank[a] ? b : a), "ok" as State);

export function gb(bytes: number): string {
  const u = [["TiB", 2 ** 40], ["GiB", 2 ** 30], ["MiB", 2 ** 20]] as const;
  for (const [name, size] of u) if (bytes >= size) return `${(bytes / size).toFixed(bytes / size >= 100 ? 0 : 1)} ${name}`;
  return bytes > 0 ? "<1 MiB" : "0";
}

function jsonSection(sec: ProbeSection | undefined): unknown {
  if (!sec || sec.rc !== 0) return null;
  try {
    return JSON.parse(sec.out);
  } catch {
    return null;
  }
}

// A vdev member (a kernel path from `zpool status -L`, a /dev/disk/by-id path,
// or a bare by-id name in `zpool import`) → the node's disk it is.
function matchDisk(member: string, disks: Disk[]): Disk | undefined {
  const base = member.replace(/^.*\//, "").replace(/-part\d+$/, "");
  const devpath = member.replace(/-part\d+$|p?\d+$/, "");
  const kernel = member.startsWith("/dev/") && !member.startsWith("/dev/disk/");
  return (
    disks.find((d) => kernel && (d.device === member || d.device === devpath)) ??
    disks.find((d) => !kernel && d.byId !== null && d.byId.replace(/^.*\//, "") === base) ??
    disks.find((d) => !kernel && d.wwn !== null && (base === `nvme-${d.wwn}` || base === `wwn-${d.wwn}`)) ??
    // A disk has several by-id links (an NVMe namespace suffix, the EUI) and
    // Proxmox names one of them: the serial at the end of the name decides.
    disks.find((d) => !kernel && d.serial !== null && d.serial.length >= 6 && (base.endsWith(`_${d.serial}`) || base.includes(`_${d.serial}_`)))
  );
}

function diskOf(row: Record<string, unknown>, smartDoc: Record<string, unknown> | null, smartRead: boolean): Disk {
  const type = String(row.type ?? "");
  const smart = smartRead ? parseSmart(smartDoc) : { ...parseSmart(null), read: false };
  if (smart.health === "unknown") smart.health = smartHealth(row.health); // disks/list ran smartctl -H
  return {
    device: String(row.devpath ?? ""),
    byId: str(row.by_id_link),
    model: str(row.model),
    serial: str(row.serial),
    wwn: str(row.wwn),
    size: num(row.size) ?? 0,
    type: type === "ssd" || type === "hdd" || type === "nvme" ? type : "unknown",
    wearout: num(row.wearout),
    smart,
    zfs: null,
    exportedPool: null,
    state: "ok",
    reasons: [],
  };
}

// The colour of a disk and why.
export function judgeDisk(d: Disk): void {
  const r: { s: State; t: string }[] = [];
  const s = d.smart;
  if (s.health === "failed") r.push({ s: "fail", t: "SMART health FAILED" });
  if (d.zfs && DEVICE_FAIL_STATES.includes(d.zfs.state)) {
    r.push({ s: "fail", t: `ZFS ${d.zfs.state} in ${d.zfs.pool}${d.zfs.msg ? `: ${d.zfs.msg}` : ""}` });
  }
  if (d.zfs && d.zfs.read + d.zfs.write + d.zfs.cksum > 0) {
    r.push({ s: "warn", t: `ZFS errors read ${d.zfs.read}, write ${d.zfs.write}, checksum ${d.zfs.cksum}` });
  }
  if (d.wearout !== null && d.wearout <= WEAR_FAIL) r.push({ s: "fail", t: `${d.wearout}% of its rated life left` });
  else if (d.wearout !== null && d.wearout <= WEAR_WARN) r.push({ s: "warn", t: `${d.wearout}% of its rated life left` });
  const sectors: string[] = [];
  if (s.reallocated) sectors.push(`${s.reallocated} reallocated`);
  if (s.pending) sectors.push(`${s.pending} pending`);
  if (s.uncorrectable) sectors.push(`${s.uncorrectable} uncorrectable`);
  if (sectors.length) r.push({ s: "warn", t: `SMART: ${sectors.join(", ")} sectors` });
  if (s.mediaErrors) r.push({ s: "warn", t: `SMART: ${s.mediaErrors} media errors` });
  if (s.criticalWarning) r.push({ s: "warn", t: `SMART: NVMe critical warning 0x${s.criticalWarning.toString(16)}` });
  if (s.temperature !== null && s.temperature >= TEMP_WARN[d.type]) r.push({ s: "warn", t: `${s.temperature}°C` });
  d.state = worst(...r.map((x) => x.s));
  d.reasons = r.map((x) => x.t);
}

export function buildInventory(src: InvSources, now: Date = new Date()): Inventory {
  const findings: Finding[] = [];
  const moduleOf = new Map<number, string>();
  for (const m of src.modules ?? []) if (typeof m.vmid === "number") moduleOf.set(m.vmid, m.name);
  const guestOf = new Map<number, ClusterGuest>();
  for (const g of src.guests ?? []) guestOf.set(g.vmid, g);
  const jobs = (src.replicationJobs ?? []).map((j) => ({
    id: String(j.id ?? ""),
    guest: num(j.guest) ?? -1,
    source: str(j.source),
    target: str(j.target),
    schedule: str(j.schedule) ?? "*/15",
    disabled: j.disable === 1 || j.disable === true,
  }));
  const shares = ((src.shares?.nfs as Record<string, unknown> | undefined)?.shares ?? {}) as Record<string, Record<string, unknown>>;

  const nodes: InvNode[] = [];
  for (const sn of src.clusterNodes) {
    if (src.only && sn.name !== src.only) continue;
    const ns = src.nodes[sn.name];
    const sec = ns?.sections ?? null;
    if (!sec) {
      nodes.push({ name: sn.name, reachable: false, boot: [], pools: [], otherDisks: [], replication: [], state: "warn", reasons: ["did not answer"] });
      findings.push({ level: "warn", cause: "health", on: { kind: "node", node: sn.name, name: sn.name }, text: `${sn.name} did not answer — its storage is not known` });
      continue;
    }
    const node = buildNode(sn, sec, src, { moduleOf, guestOf, jobs, shares }, now);
    nodes.push(node);
  }

  // Findings, each on its object.
  for (const n of nodes) {
    if (!n.reachable) continue;
    const diskFinding = (d: Disk, where: string): void => {
      if (d.state === "ok") return;
      const cause: Finding["cause"] = d.reasons.some((x) => x.startsWith("ZFS")) ? "zfs" : d.reasons.some((x) => x.startsWith("SMART")) ? "smart" : d.reasons.some((x) => /life left/.test(x)) ? "wear" : "temperature";
      const what = [d.model, d.serial].filter(Boolean).join(", ");
      findings.push({ level: d.state as "warn" | "fail", cause, on: { kind: "disk", node: n.name, name: d.device }, text: `${n.name} ${d.device}${what ? ` (${what})` : ""}${where}: ${d.reasons.join("; ")}` });
    };
    for (const d of n.boot) diskFinding(d, ", the boot device");
    for (const p of n.pools) {
      for (const v of p.vdevs) for (const d of v.disks) diskFinding(d, ` in ${p.name}`);
      for (const m of p.vdevs.flatMap((v) => v.missing)) {
        findings.push({ level: "fail", cause: "zfs", on: { kind: "disk", node: n.name, name: m.name }, text: `${n.name} ${p.name}: member ${m.name} is ${m.state} and not among the node's disks` });
      }
      if (p.state !== "ok") {
        for (const reason of p.reasons) {
          const cause: Finding["cause"] = /% used/.test(reason) ? "usage" : /scrub/.test(reason) ? "scrub" : "health";
          if (/^disk /.test(reason)) continue; // the disk's own finding says it
          const level: "warn" | "fail" = cause === "usage" && (p.usable?.pct ?? 0) >= POOL_FAIL ? "fail" : cause === "health" && ["FAULTED", "UNAVAIL", "SUSPENDED", "MISSING"].includes(p.health) ? "fail" : "warn";
          findings.push({ level, cause, on: { kind: "pool", node: n.name, name: p.name }, text: `${n.name}/${p.name}: ${reason}` });
        }
      }
    }
    for (const d of n.otherDisks) diskFinding(d, d.exportedPool ? `, in the pool ${d.exportedPool.name} that is not imported` : ", in no pool");
    for (const j of n.replication) {
      if (j.state === "ok") continue;
      findings.push({ level: "warn", cause: "replication", on: { kind: "replication", node: n.name, name: j.id }, text: `replication ${j.id} (${j.module ?? `vmid ${j.vmid}`}) ${j.source} → ${j.target}: ${j.reasons.join("; ")}` });
    }
  }

  const sources: Inventory["sources"] = [];
  const err = (name: string): string | null => src.errors.find((e) => e.source === name)?.error ?? null;
  for (const name of ["node records", "cluster resources", "cluster replication", "module-manager list", "shares.json"]) {
    sources.push({ name, ok: err(name) === null, error: err(name) });
  }
  for (const n of nodes) sources.push({ name: `${n.name} storage`, ok: n.reachable, error: n.reachable ? null : "did not answer" });
  return { version: 1, generated: now.toISOString(), smart: src.smart, nodes, findings, sources };
}

interface Ctx {
  moduleOf: Map<number, string>;
  guestOf: Map<number, ClusterGuest>;
  jobs: { id: string; guest: number; source: string | null; target: string | null; schedule: string; disabled: boolean }[];
  shares: Record<string, Record<string, unknown>>;
}

function buildNode(sn: { name: string; storagePools: string[] }, sec: Record<string, ProbeSection>, src: InvSources, ctx: Ctx, now: Date): InvNode {
  const name = sn.name;
  const list = jsonSection(sec.disks);
  const rows = Array.isArray(list) ? (list as Record<string, unknown>[]) : [];
  const disks = rows.map((r) => {
    const dev = String(r.devpath ?? "");
    const smartSec = sec[`smart ${dev}`];
    const smartDoc = jsonSection(smartSec) as Record<string, unknown> | null;
    return diskOf(r, smartDoc, src.smart && smartDoc !== null);
  });

  // Pools: zpool status for the tree, zpool list for the sizes, zfs list for
  // what they hold.
  const status = sec["zpool-status"] && sec["zpool-status"].rc === 0 ? parseZpoolStatus(sec["zpool-status"].out) : [];
  const zl = sec["zpool-list"] && sec["zpool-list"].rc === 0 ? parseZpoolList(sec["zpool-list"].out) : [];
  const zfs = sec.zfs && sec.zfs.rc === 0 ? parseZfsList(sec.zfs.out) : [];
  const pbs = jsonSection(sec.pbs);
  const datastores = (Array.isArray(pbs) ? (pbs as Record<string, unknown>[]) : [])
    .map((d) => ({ name: String(d.name ?? ""), path: String(d.path ?? "") }))
    .filter((d) => d.name && d.path);
  const used = new Set<Disk>();

  const poolNames = [...new Set([...sn.storagePools, ...status.map((s) => s.pool), ...zl.map((z) => z.name)])];
  const pools: Pool[] = [];
  for (const pn of poolNames.sort()) {
    const st = status.find((s) => s.pool === pn);
    const li = zl.find((z) => z.name === pn);
    const pool = buildPool(name, pn, sn.storagePools.includes(pn), st, li, zfs, disks, used, datastores, ctx, now);
    pools.push(pool);
  }

  const bootNames = bootDevices(jsonSection(sec.lsblk) as Record<string, unknown> | null);
  const boot = disks.filter((d) => bootNames.includes(d.device) && !used.has(d));
  for (const d of boot) used.add(d);
  // A ZFS-root node boots from its rpool.
  const rpool = pools.find((p) => p.name === "rpool");
  if (rpool) for (const d of rpool.vdevs.flatMap((v) => v.disks)) if (!boot.includes(d)) boot.push(d);

  // Disks in no imported pool: a pool on them that is not imported says so.
  const exported = sec.exported && sec.exported.rc === 0 ? parseZpoolStatus(sec.exported.out) : [];
  const otherDisks = disks.filter((d) => !used.has(d));
  for (const ex of exported) {
    for (const row of ex.rows.filter((r) => r.depth >= 1)) {
      const d = matchDisk(row.name, otherDisks);
      if (d) d.exportedPool = { name: ex.pool, state: ex.state, deviceState: row.state ?? "" };
    }
  }
  for (const d of [...boot, ...otherDisks]) judgeDisk(d);

  // The replication jobs sourced here, with their state.
  const repl = jsonSection(sec.replication);
  const replication = (Array.isArray(repl) ? (repl as Record<string, unknown>[]) : []).map((j) => judgeReplication(j, ctx, now));

  const reasons: string[] = [];
  for (const p of pools) if (p.state !== "ok") reasons.push(`${p.name} ${p.state}`);
  for (const d of [...boot, ...otherDisks]) if (d.state !== "ok") reasons.push(`${d.device} ${d.state}`);
  for (const j of replication) if (j.state !== "ok") reasons.push(`replication ${j.id} ${j.state}`);
  const state = worst(...pools.map((p) => p.state), ...boot.map((d) => d.state), ...otherDisks.map((d) => d.state), ...replication.map((j) => j.state));
  return { name, reachable: true, boot, pools, otherDisks, replication, state, reasons };
}

const vdevState = (h: string | null): State => (h === "ONLINE" || h === "AVAIL" ? "ok" : h === "DEGRADED" ? "warn" : "fail");

function buildPool(
  node: string,
  pn: string,
  declared: boolean,
  st: ZpoolStatus | undefined,
  li: ZpoolListRow | undefined,
  zfs: ZfsRow[],
  disks: Disk[],
  used: Set<Disk>,
  datastores: { name: string; path: string }[],
  ctx: Ctx,
  now: Date,
): Pool {
  const present = !!(st || li);
  const health = li?.health ?? st?.state ?? "MISSING";

  // vdevs: depth 1 under the pool (or under a logs/cache/spares header).
  const vdevs: Vdev[] = [];
  let role: Vdev["role"] = "data";
  let curVdev: Vdev | null = null;
  const groups: Record<string, Vdev["role"]> = { logs: "log", cache: "cache", spares: "spare", special: "special", dedup: "dedup" };
  for (const row of st?.rows ?? []) {
    if (row.depth === 0) {
      if (groups[row.name]) role = groups[row.name];
      continue;
    }
    const member = (r: ZpoolRow, v: Vdev): void => {
      const d = matchDisk(r.name, disks);
      if (d) {
        d.zfs = { pool: pn, vdev: v.name, state: r.state ?? "", read: r.read, write: r.write, cksum: r.cksum, msg: r.msg };
        used.add(d);
        v.disks.push(d);
      } else v.missing.push({ name: r.name, state: r.state ?? "" });
    };
    if (row.depth === 1) {
      const m = /^(mirror|raidz(\d)?|draid(\d)?)[-:]/.exec(row.name);
      if (m) {
        const type: Vdev["type"] = m[1] === "mirror" ? "mirror" : m[1].startsWith("raidz") ? "raidz" : "draid";
        curVdev = { name: row.name, type, parity: type === "raidz" ? Number(m[2] ?? 1) : type === "draid" ? Number(m[3] ?? 1) : null, role, health: row.state ?? "", state: vdevState(row.state), disks: [], missing: [] };
        vdevs.push(curVdev);
      } else {
        curVdev = null;
        const v: Vdev = { name: row.name.replace(/^.*\//, "").replace(/-part\d+$/, ""), type: "stripe", parity: null, role, health: row.state ?? "", state: vdevState(row.state), disks: [], missing: [] };
        vdevs.push(v);
        member(row, v);
        const d0 = v.disks[0];
        if (d0?.byId && d0.zfs) v.name = d0.zfs.vdev = d0.byId.replace(/^.*\//, "");
      }
    } else if (curVdev) member(row, curVdev);
  }
  for (const d of vdevs.flatMap((v) => v.disks)) judgeDisk(d);

  // What the pool holds.
  const root = zfs.find((z) => z.name === pn);
  const usable = root && root.avail !== null ? { total: root.used + root.avail, used: root.used, avail: root.avail, pct: Math.round((1000 * root.used) / (root.used + root.avail)) / 10 } : null;
  const inPool = zfs.filter((z) => z.name.startsWith(`${pn}/`));
  const snaps = inPool.filter((z) => z.type === "snapshot");
  const volumes: Volume[] = [];
  const datasets: Dataset[] = [];
  const shareOf = (ds: string): string | null => {
    const m = new RegExp(`^${pn}/tappaas-nfs/([^/]+)$`).exec(ds);
    if (!m) return null;
    // A share's dataset is <pool>/tappaas-nfs/<name>; one shares.json does not
    // name (or names on another server) is a leftover, said so.
    const s = ctx.shares[m[1]];
    return s && s.server === node && s.pool === pn ? m[1] : `${m[1]} (not declared here in shares.json)`;
  };
  for (const z of inPool.filter((x) => x.type !== "snapshot")) {
    const rel = z.name.slice(pn.length + 1);
    const g = /^(vm|base|subvol|basevol)-(\d+)-(.+)$/.exec(rel);
    if (g && !rel.includes("/")) {
      const vmid = Number(g[2]);
      const guest = ctx.guestOf.get(vmid) ?? null;
      const mySnaps = snaps.filter((s) => s.name.startsWith(`${z.name}@`)).map((s) => replicateSnapshot(s.name.slice(z.name.length + 1))).filter((x): x is { job: string; at: string } => x !== null);
      const lastRep = mySnaps.sort((a, b) => b.at.localeCompare(a.at))[0] ?? null;
      let kind: VolumeKind;
      let note: string | null = null;
      let replica: Volume["replica"] = null;
      const job = ctx.jobs.find((j) => j.guest === vmid && j.target === node);
      if (!guest) {
        kind = "orphan";
        note = `no guest ${vmid} in the cluster`;
      } else if (guest.template || g[1].startsWith("base")) {
        kind = "template";
      } else if (guest.node === node) {
        kind = "own";
      } else if (job) {
        kind = "mirror";
        replica = { job: job.id, source: job.source ?? guest.node, lastSync: lastRep?.at ?? null };
      } else {
        kind = "orphan";
        note = `a copy of a guest that runs on ${guest.node}; no replication job targets ${node}`;
        if (lastRep) replica = { job: lastRep.job, source: null, lastSync: lastRep.at };
      }
      volumes.push({
        name: z.name,
        vmid,
        module: ctx.moduleOf.get(vmid) ?? null,
        guest: guest?.name ?? null,
        kind,
        runsOn: guest?.node ?? null,
        type: z.type === "filesystem" ? "filesystem" : "volume",
        size: z.type === "volume" ? z.volsize : z.refquota,
        used: z.used,
        refer: z.refer,
        snapshots: z.usedsnap,
        replica,
        mirroredOn: kind === "own" ? ctx.jobs.filter((j) => j.guest === vmid && j.source === node && j.target).map((j) => j.target as string) : [],
        note,
      });
      continue;
    }
    if (rel === "tappaas-nfs") continue; // the shares' parent: its shares are listed
    const share = shareOf(z.name);
    if (share) {
      datasets.push({ name: z.name, kind: "nfs-share", label: share, mountpoint: z.mountpoint, used: z.used, exact: true });
      continue;
    }
    if (rel.includes("/") && !rel.startsWith("tappaas-nfs/")) continue; // inside a dataset already listed
    datasets.push({ name: z.name, kind: z.type === "volume" ? "volume" : "dataset", label: rel, mountpoint: z.mountpoint, used: z.used, exact: true });
  }
  // A PBS datastore: a dataset of its own, or a directory in one.
  const mounted = [root, ...inPool].filter((z): z is ZfsRow => !!z && z.type === "filesystem" && !!z.mountpoint);
  for (const ds of datastores) {
    const holder = mounted
      .filter((z) => ds.path === z.mountpoint || ds.path.startsWith(`${z.mountpoint}/`))
      .sort((a, b) => (b.mountpoint ?? "").length - (a.mountpoint ?? "").length)[0];
    if (!holder) continue;
    if (holder.mountpoint === ds.path) {
      const known = datasets.find((d) => d.name === holder.name);
      if (known) {
        known.kind = "pbs-datastore";
        known.label = ds.name;
      } else datasets.push({ name: holder.name, kind: "pbs-datastore", label: ds.name, mountpoint: ds.path, used: holder.used, exact: true });
    } else {
      datasets.push({ name: `${holder.name}:${ds.path.slice((holder.mountpoint ?? "").length + 1)}`, kind: "pbs-datastore", label: ds.name, mountpoint: ds.path, used: holder.refer, exact: false });
    }
  }
  volumes.sort((a, b) => a.vmid - b.vmid || a.name.localeCompare(b.name));
  datasets.sort((a, b) => a.name.localeCompare(b.name));

  const own = volumes.filter((v) => v.kind === "own").reduce((s, v) => s + v.used, 0);
  const mirror = volumes.filter((v) => v.kind === "mirror").reduce((s, v) => s + v.used, 0);
  const totals = usable
    ? { total: usable.total, own, mirror, other: Math.max(0, usable.used - own - mirror), free: usable.avail }
    : { total: 0, own, mirror, other: 0, free: 0 };

  const scrub = parseScan(st?.scan ?? null);
  const r: { s: State; t: string }[] = [];
  if (!present) r.push({ s: "fail", t: declared ? "declared in the node's storagePools but not imported on the node" : "not imported" });
  else if (["FAULTED", "UNAVAIL", "SUSPENDED"].includes(health)) r.push({ s: "fail", t: `${health}${st?.status ? `: ${firstSentence(st.status)}` : ""}` });
  else if (health !== "ONLINE") r.push({ s: "warn", t: `${health}${st?.status ? `: ${firstSentence(st.status)}` : ""}` });
  if (usable && usable.pct >= POOL_FAIL) r.push({ s: "fail", t: `${usable.pct.toFixed(0)}% used (fails at ${POOL_FAIL}%)` });
  else if (usable && usable.pct >= POOL_WARN) r.push({ s: "warn", t: `${usable.pct.toFixed(0)}% used (warns at ${POOL_WARN}%)` });
  if (scrub.errors) r.push({ s: "warn", t: `the last scrub found ${scrub.errors} error(s)` });
  if (scrub.state === "finished" && scrub.last && now.getTime() - Date.parse(scrub.last) > SCRUB_MAX_DAYS * 86400e3) {
    r.push({ s: "warn", t: `last scrub ${localDay(scrub.last)}, over ${SCRUB_MAX_DAYS} days ago` });
  }
  for (const d of vdevs.flatMap((v) => v.disks)) if (d.state !== "ok") r.push({ s: "warn", t: `disk ${d.device} ${d.state}` });
  for (const m of vdevs.flatMap((v) => v.missing)) r.push({ s: "warn", t: `disk ${m.name} ${m.state}, not on the node` });
  if (!declared && present && pn !== "rpool") r.push({ s: "warn", t: "not in the node's storagePools (its pvehost record)" });

  return {
    name: pn,
    declared,
    present,
    health,
    status: [st?.status, st?.action].filter(Boolean).join(" ") || null,
    size: li?.size ?? 0,
    allocated: li?.alloc ?? 0,
    free: li?.free ?? 0,
    fragmentation: li?.frag ?? null,
    dedup: li?.dedup ?? null,
    compression: root?.compression ?? null,
    compressRatio: root?.compressratio ?? null,
    usable,
    scrub,
    vdevs,
    volumes,
    datasets,
    totals,
    state: worst(...r.map((x) => x.s)),
    reasons: r.map((x) => x.t),
  };
}

const firstSentence = (t: string): string => (/^(.*?\.)(\s|$)/.exec(t)?.[1] ?? t).replace(/\.$/, "").replace(/^One /, "one ");

function judgeReplication(j: Record<string, unknown>, ctx: Ctx, now: Date): Replication {
  const vmid = num(j.guest) ?? -1;
  const iso = (v: unknown): string | null => (num(v) ? new Date((num(v) as number) * 1000).toISOString() : null);
  const schedule = str(j.schedule) ?? "*/15";
  const rep: Replication = {
    id: String(j.id ?? ""),
    vmid,
    module: ctx.moduleOf.get(vmid) ?? null,
    source: str(j.source) ?? "",
    target: str(j.target) ?? "",
    schedule,
    lastSync: iso(j.last_sync),
    nextSync: iso(j.next_sync),
    failCount: num(j.fail_count) ?? 0,
    error: str(j.error),
    state: "ok",
    reasons: [],
  };
  if (j.disable === 1 || j.disable === true) return rep;
  if (rep.error) rep.reasons.push(`error: ${rep.error}`);
  else if (rep.failCount > 0) rep.reasons.push(`${rep.failCount} failed attempt(s)`);
  const last = num(j.last_sync);
  const every = scheduleMinutes(schedule);
  if (!last) rep.reasons.push("never synced");
  else if (every !== null) {
    const age = (now.getTime() / 1000 - last) / 60;
    if (age > Math.max(2 * every, every + 15)) rep.reasons.push(`last sync ${Math.round(age)} min ago, the schedule is every ${every} min`);
  } else {
    const next = num(j.next_sync);
    if (next && now.getTime() / 1000 > next + 30 * 60) rep.reasons.push("its next sync is over 30 min overdue");
  }
  rep.state = rep.reasons.length ? "warn" : "ok";
  return rep;
}

// ── reading the sources ───────────────────────────────────────────────

export type Runner = (bin: string, args: string[]) => ExecResult;

// The cluster reads, injectable for tests.
export interface ClusterReads {
  nodeStorage(node: string, smart: boolean): Record<string, ProbeSection> | null;
  guests(node: string): ClusterGuest[] | null;
  replication(node: string): Record<string, unknown>[] | null;
}

export const liveReads: ClusterReads = {
  nodeStorage: (node, smart) => queryNodeStorage(node, { smart }),
  guests: queryClusterGuests,
  replication: queryClusterReplication,
};

export interface CollectOpts {
  configDir: string;
  only?: string | null;
  smart: boolean;
  reads?: ClusterReads;
  run?: Runner;
}

export function collectSources(o: CollectOpts): InvSources {
  const reads = o.reads ?? liveReads;
  const run = o.run ?? captureResult;
  const errors: { source: string; error: string }[] = [];
  const clusterNodes = listClusterNodes(o.configDir).map((n) => ({ name: n.name, storagePools: n.storagePools }));
  if (clusterNodes.length === 0) errors.push({ source: "node records", error: `no cluster node is registered (no pvehost instance in ${o.configDir})` });
  const names = clusterNodes.map((n) => n.name);
  const nodes: Record<string, NodeSources> = {};
  for (const n of names) {
    if (o.only && n !== o.only) continue;
    nodes[n] = { sections: reads.nodeStorage(n, o.smart) };
  }
  // The cluster-wide reads go through the first node that answered.
  const via = Object.keys(nodes).find((n) => nodes[n].sections) ?? names[0];
  let guests: ClusterGuest[] | null = null;
  let replicationJobs: Record<string, unknown>[] | null = null;
  if (via) {
    guests = reads.guests(via);
    if (!guests) errors.push({ source: "cluster resources", error: `no answer from ${via}` });
    replicationJobs = reads.replication(via);
    if (!replicationJobs) errors.push({ source: "cluster replication", error: `no answer from ${via}` });
  }
  let modules: ModuleRow[] | null = null;
  const r = run("module-manager", ["list", "--json"]);
  if (!r.ran) errors.push({ source: "module-manager list", error: "module-manager not found" });
  else {
    try {
      modules = ((JSON.parse(r.stdout) as { modules?: ModuleRow[] }).modules ?? []).map((m) => ({ name: m.name, vmid: m.vmid }));
    } catch {
      errors.push({ source: "module-manager list", error: `exit ${r.rc}: no JSON` });
    }
  }
  // No shares.json is not an error: no share declared yet.
  let shares: Record<string, unknown> | null = null;
  try {
    shares = readJsonObject(join(o.configDir, "shares.json"));
  } catch (e) {
    errors.push({ source: "shares.json", error: (e as Error).message });
  }
  return { clusterNodes, only: o.only ?? null, smart: o.smart, nodes, guests, replicationJobs, modules, shares, errors };
}

// ── the text view ─────────────────────────────────────────────────────

const WIDTH = 96;
// A date as the operator's clock shows it (the nodes and the mothership share
// the site's timezone).
function localDay(iso: string): string {
  const d = new Date(iso);
  const p = (n: number): string => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
function localTime(iso: string): string {
  const d = new Date(iso);
  return `${localDay(iso)} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}
function line(text: string, state: State | string): string {
  return `${text.padEnd(WIDTH - 1)} ${state}`;
}

function diskLine(d: Disk): string {
  const what = [d.model, d.serial ? `(${d.serial})` : null].filter(Boolean).join(" ");
  const facts = [gb(d.size), d.type];
  if (d.wearout !== null) facts.push(`${d.wearout}% life left`);
  if (d.smart.temperature !== null) facts.push(`${d.smart.temperature}°C`);
  if (d.smart.read || d.smart.health !== "unknown") facts.push(`SMART ${d.smart.health}`);
  const why = d.reasons.length ? ` — ${d.reasons.join("; ")}` : "";
  return `${d.device} ${what}, ${facts.join(", ")}${why}`;
}

export function renderInventory(inv: Inventory): string[] {
  const out: string[] = [];
  for (const n of inv.nodes) {
    out.push(line(n.name, n.reachable ? n.state : "unknown"));
    if (!n.reachable) {
      out.push("  did not answer");
      continue;
    }
    for (const d of n.boot) out.push(line(`  boot  ${diskLine(d)}`, d.state));
    for (const p of n.pools) {
      const u = p.usable;
      const facts = [
        p.present ? gb(p.size) : "not imported",
        u ? `${u.pct.toFixed(0)}% used, ${gb(u.avail)} free` : null,
        p.fragmentation !== null ? `frag ${p.fragmentation}%` : null,
        p.scrub.last ? `scrub ${localDay(p.scrub.last)}` : p.present ? "no scrub on record" : null,
        p.health === "ONLINE" || !p.present ? p.health : null,
      ].filter(Boolean);
      out.push(line(`  pool ${p.name}  ${facts.join(", ")}${p.reasons.length ? ` — ${p.reasons.filter((x) => !/^disk /.test(x)).join("; ")}` : ""}`.replace(/ — $/, ""), p.state));
      for (const v of p.vdevs) {
        const indent = v.type === "stripe" ? "    " : "      ";
        if (v.type !== "stripe") out.push(line(`    ${v.name}${v.role !== "data" ? ` (${v.role})` : ""} ${v.health}`, v.state));
        for (const d of v.disks) out.push(line(`${indent}${diskLine(d)}`, d.state));
        for (const m of v.missing) out.push(line(`${indent}${m.name} ${m.state} — not among the node's disks`, "fail"));
      }
      const t = p.totals;
      const mirrors = p.volumes.filter((v) => v.kind === "mirror");
      const from = [...new Set(mirrors.map((v) => v.runsOn))].join(", ");
      out.push(`    holds: own ${gb(t.own)}, mirror copies ${gb(t.mirror)}${from ? ` (of ${from})` : ""}, other ${gb(t.other)}, free ${gb(t.free)} of ${gb(t.total)}`);
      for (const v of p.volumes) {
        const who = `${v.module ?? v.guest ?? "?"} (${v.vmid})`;
        const size = v.size !== null ? `${gb(v.size)}, ` : "";
        const kind = v.kind === "mirror" ? `mirror of ${v.runsOn}` : v.kind === "own" && v.mirroredOn.length ? `own, mirrored on ${v.mirroredOn.join(", ")}` : v.kind;
        out.push(`      ${who.padEnd(26)} ${v.name.slice(p.name.length + 1).padEnd(22)} ${size}takes ${gb(v.used)}  ${kind}${v.note ? ` — ${v.note}` : ""}`);
      }
      for (const d of p.datasets) {
        const label = d.kind === "pbs-datastore" ? `PBS datastore ${d.label}` : d.kind === "nfs-share" ? `NFS share ${d.label}` : d.label;
        out.push(`      ${label.padEnd(26)} ${(d.mountpoint ?? d.name).padEnd(22)} takes ${d.exact ? "" : "≈"}${gb(d.used)}`);
      }
    }
    if (n.otherDisks.length) {
      out.push("  disks in no pool");
      for (const d of n.otherDisks) {
        const ex = d.exportedPool ? ` [pool ${d.exportedPool.name} ${d.exportedPool.state}, not imported]` : "";
        out.push(line(`    ${diskLine(d)}${ex}`, d.state));
      }
    }
    for (const j of n.replication) {
      out.push(line(`  replication ${j.id} ${j.module ?? j.vmid} → ${j.target}, every ${j.schedule}, last ${j.lastSync ? localTime(j.lastSync) : "never"}${j.reasons.length ? ` — ${j.reasons.join("; ")}` : ""}`, j.state));
    }
  }
  if (!inv.smart) out.push("", "SMART was not read (--no-smart): disk health is ZFS's view and Proxmox's disk list only");
  const bad = inv.sources.filter((s) => !s.ok);
  if (bad.length) {
    out.push("", "Sources that did not answer");
    for (const s of bad) out.push(`  ${s.name}: ${s.error}`);
  }
  return out;
}
