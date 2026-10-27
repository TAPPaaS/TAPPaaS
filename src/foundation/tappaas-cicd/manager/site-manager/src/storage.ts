// storage.ts — `site-manager node storage`: a node's data pools (ADR-037 D4).
//
// `node add` stands a node up on its boot pool; its data pools are this second,
// separate step, with precise arguments and no questions:
//
//   node storage <node>                       the node's disks in no pool
//   node storage add <node> <pool> --disks <d>[,<d>...] --layout <l> [--wipe]
//
// The pool is built on the node by cluster/config-storage.sh (fed over ssh from
// this checkout: the boot disk and a live pool's disks are refused there, by the
// name the disk has on this boot), registered as the node's storage, and
// recorded in the node's record (storagePools), which the storage nodes-list
// reconcile then reads. The console's storage page proposes the arguments from
// the inventory; this verb decides.

import { spawnSync } from "child_process";
import * as fs from "fs";

import { GN, YW, CL, die, info, warn } from "../../../lib/ts/src/cli";
import { mgmtDomain } from "../../../lib/ts/src/cluster";
import { writeJsonAtomic } from "../../../lib/ts/src/config-io";
import { clusterNode } from "../../../lib/ts/src/nodes";
import { clusterScript, defaultConfigDir } from "./config";
import { isKernelDiskName } from "./provision";

// The layouts and how many disks each takes; config-storage.sh's topology names.
export const LAYOUTS: Record<string, { min: number; max?: number; topology: string }> = {
  single: { min: 1, max: 1, topology: "single" },
  mirror: { min: 2, topology: "mirror" },
  raidz1: { min: 3, topology: "raidz" },
  raidz2: { min: 4, topology: "raidz2" },
};

// What is wrong with `node storage add` arguments, before the node is touched.
// <pools> are the pools the node's record already carries. Pure.
export function storageAddProblems(pool: string, disks: string[], layout: string, pools: string[]): string[] {
  const p: string[] = [];
  if (!/^tank[a-z0-9_-]{1,28}$/.test(pool)) p.push(`'${pool}' is no data pool name: tank<class><N> — tanka1 for SSD/NVMe, tankb1 for spinning disks`);
  else if (pools.includes(pool)) p.push(`the node already has '${pool}'`);
  const l = LAYOUTS[layout];
  if (!l) p.push(`--layout '${layout}': one of ${Object.keys(LAYOUTS).join(", ")}`);
  if (disks.length === 0) p.push("--disks: name the disk(s) by serial or /dev/disk/by-id name (node storage <node> lists them)");
  const dup = disks.filter((d, i) => disks.indexOf(d) !== i);
  if (dup.length) p.push(`--disks names ${[...new Set(dup)].join(", ")} more than once`);
  const kernel = disks.filter(isKernelDiskName);
  if (kernel.length) p.push(`--disks ${kernel.join(", ")}: a kernel name changes between boots — name the disk by its serial or /dev/disk/by-id name (node storage <node> lists them)`);
  if (l && disks.length > 0 && (disks.length < l.min || (l.max !== undefined && disks.length > l.max))) {
    p.push(`--layout ${layout} takes ${l.max === l.min ? `${l.min} disk` : `${l.min} or more disks`}, not ${disks.length}`);
  }
  return p;
}

// The pool name the console proposes for disks of a type: the next free
// tank<class><N>, class a for SSD/NVMe, b for spinning disks. Pure.
export function proposedPoolName(type: string, taken: string[]): string {
  const cls = type === "hdd" ? "b" : "a";
  for (let n = 1; ; n++) if (!taken.includes(`tank${cls}${n}`)) return `tank${cls}${n}`;
}

// The layout the console proposes for a number of disks. Pure.
export function proposedLayout(count: number): string {
  return count <= 1 ? "single" : count === 2 ? "mirror" : "raidz1";
}

function nodeRecordPath(name: string): string {
  return `${defaultConfigDir().replace(/\/$/, "")}/${name}.json`;
}

function requireNode(name: string): string[] {
  const n = clusterNode(defaultConfigDir(), name);
  if (!n) die(`'${name}' is not a cluster node (site-manager node list)`);
  return n.storagePools;
}

function humanSize(bytes: number): string {
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let v = bytes, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

interface FreeDisk {
  device: string; byId?: string; model?: string; serial?: string; size: number; type?: string;
  state?: string; reasons?: string[]; exportedPool?: { name: string } | null;
}

// `node storage <node>`: the disks in no pool, as storage-manager's inventory
// reads them (the console's storage page reads the same document).
export function listNodeStorage(name: string, json: boolean): void {
  const pools = requireNode(name);
  const r = spawnSync("storage-manager", ["inventory", "--node", name, "--json"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0 && !r.stdout) die(`storage-manager inventory failed: ${(r.stderr ?? "").trim()}`);
  let free: FreeDisk[] = [];
  try {
    const doc = JSON.parse(r.stdout ?? "") as { nodes?: { name: string; otherDisks?: FreeDisk[] }[] };
    free = doc.nodes?.find((n) => n.name === name)?.otherDisks ?? [];
  } catch { die("storage-manager inventory: unreadable output"); }
  if (json) { info(JSON.stringify({ node: name, pools, freeDisks: free }, null, 2)); return; }
  info(`${name}: pools ${pools.length ? pools.join(", ") : "none — the boot pool (local-zfs) carries its guests"}`);
  if (free.length === 0) { info("  no disk in no pool"); return; }
  info("  disks in no pool (name one by its serial):");
  for (const d of free) {
    const notes = [
      d.exportedPool ? `old pool '${d.exportedPool.name}' on it: --wipe to reuse` : "",
      d.state && d.state !== "ok" ? `${d.state}: ${(d.reasons ?? []).join("; ")}` : "",
    ].filter(Boolean).join(" · ");
    info(`    ${(d.serial ?? "?").padEnd(22)} ${humanSize(d.size).padStart(7)}  ${(d.type ?? "?").padEnd(4)}  ${d.model ?? ""}${notes ? `  ${YW}${notes}${CL}` : ""}`);
  }
  // The example never proposes a disk whose health is not ok.
  const healthy = free.filter((d) => (d.state ?? "ok") === "ok");
  if (healthy.length === 0) { info("  no healthy disk to propose a pool on"); return; }
  const ssd = healthy.filter((d) => d.type !== "hdd");
  const pick = ssd.length ? ssd : healthy;
  const layout = proposedLayout(Math.min(pick.length, 2));
  info(`  e.g.: site-manager node storage add ${name} ${proposedPoolName(pick[0].type ?? "ssd", pools)} ` +
       `--disks ${pick.slice(0, layout === "single" ? 1 : 2).map((d) => d.serial ?? d.byId).join(",")} --layout ${layout}`);
}

export interface StorageAddOpts { node: string; pool: string; disks: string[]; layout: string; wipe: boolean }

// `node storage add`: build the pool on the node, register it, record it.
export function addNodeStorage(o: StorageAddOpts): void {
  const pools = requireNode(o.node);
  const problems = storageAddProblems(o.pool, o.disks, o.layout, pools);
  if (problems.length) die(`node storage add: ${problems.join("; ")}`);
  const script = clusterScript("config-storage.sh");
  if (!script) die("cluster/config-storage.sh not found — is the cluster module installed?");
  const host = `root@${o.node}.${mgmtDomain()}`;

  // A storage of that name elsewhere in the cluster must be the same kind of
  // thing: a zfspool on a pool of that name (tanka1 on several nodes).
  const kind = spawnSync("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
    `awk -v s='${o.pool}' '$2==s && $1 ~ /:$/ {t=$1; f=1; next} f && $1=="pool" {p=$2} f && $1 ~ /:$/ {exit} END {print t, p}' /etc/pve/storage.cfg`],
    { encoding: "utf8" });
  if (kind.status !== 0) die(`cannot reach ${host}: ${(kind.stderr ?? "").trim()}`);
  const [type, dataset] = (kind.stdout ?? "").trim().split(/\s+/);
  if (type && (type !== "zfspool:" || dataset !== o.pool)) {
    die(`node storage add: the cluster already has a storage '${o.pool}' that is ${type === "zfspool:" ? `on the pool '${dataset}'` : `a ${type.replace(/:$/, "")}`} — name the pool otherwise`);
  }

  if (spawnSync("ssh", ["-o", "BatchMode=yes", host, `zpool list -H -o name ${o.pool}`], { encoding: "utf8" }).status === 0) {
    die(`node storage add: ${o.node} has a pool '${o.pool}' already, not in its record — check it (zpool status ${o.pool}) and name the new pool otherwise`);
  }

  const spec = `${o.pool}=${LAYOUTS[o.layout].topology}:${o.disks.join(",")}`;
  info(`building ${o.pool} (${o.layout}: ${o.disks.join(", ")}) on ${o.node}${o.wipe ? ` — ${YW}disks that carry data are erased${CL}` : ""}`);
  const r = spawnSync("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
    "bash", "-s", "--", "--non-interactive", ...(o.wipe ? ["--yes"] : []), "--pool", `'${spec}'`],
    { input: fs.readFileSync(script, "utf8"), stdio: ["pipe", "inherit", "inherit"] });
  if (r.status !== 0) die(`node storage add: ${o.pool} was not built on ${o.node} (see above) — the node's record is unchanged`);
  const built = spawnSync("ssh", ["-o", "BatchMode=yes", host, `zpool list -H -o name ${o.pool}`], { encoding: "utf8" });
  if (built.status !== 0) die(`node storage add: ${o.pool} is not on ${o.node} after the build — the node's record is unchanged`);

  const file = nodeRecordPath(o.node);
  const rec = JSON.parse(fs.readFileSync(file, "utf8")) as { storagePools?: string[] };
  rec.storagePools = [...new Set([...(rec.storagePools ?? []), o.pool])].sort();
  writeJsonAtomic(file, rec);
  info(`  ${GN}✓${CL} ${o.node}'s record carries ${rec.storagePools.join(", ")}`);

  const reconcile = clusterScript("reconcile-storage-nodes.sh");
  if (!reconcile || spawnSync("bash", [reconcile], { stdio: "inherit" }).status !== 0) {
    warn(`  the storage nodes lists were not reconciled — the next cluster update does it`);
  }
  info(`${GN}✓ ${o.pool} is ${o.node}'s storage${CL} — new guests that name it are built there`);
}
