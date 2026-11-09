// cmdbreport.ts — what backup-manager reports to the CMDB (ADR-040 D4), from
// what `restore list-all` already reads (`pbs-controller runs --json`) and the
// peer records in config/: the datastore (size, used, retention; runs-on the
// machine PBS runs on; stored-on the pool its path is on), a `backs-up` from
// it to every guest and machine of
// this site it holds restore points for, and each buddy as a backup-peer
// (direction, at its location, lastSeen: its sync's last run).

import { CmdbBatch } from "../../../lib/ts/src/cmdb-reporter";
import { BackupRuns, Peer, RawDiscover, RawRuns } from "./types";

/** A node's ZFS pools (config/<node>.json storagePools): what a datastore's
 *  path may be on. */
export type PoolsOf = (node: string) => string[];

export const SOURCE = "backup-manager";

const iso = (t: number | null | undefined): string | undefined => (t ? new Date(t * 1000).toISOString() : undefined);

/** A prune job's keep-* settings for the store, as {last, daily, …}. */
export function retentionOf(raw: RawRuns, store: string): Record<string, number> | undefined {
  const job = (raw.pruneJobs ?? []).find((j) => j.store === store && (j.ns ?? "") === "");
  if (!job) return undefined;
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(job)) if (k.startsWith("keep-") && typeof v === "number") out[k.slice(5)] = v;
  return Object.keys(out).length ? out : undefined;
}

// pull: we pull theirs; receive: they push into ours. A buddy that pulls ours
// (remote) has no direction in the metamodel's enum: it is left unset.
const DIRECTION: Record<string, "pull" | "receive" | "pulled-by"> = { pull: "pull", receive: "receive", remote: "pulled-by" };

export function putPeer(b: CmdbBatch, p: Peer, lastSeen?: string): string {
  const ref = b.put("backup-peer", p.name, {
    direction: DIRECTION[p.role],
    role: p.role,
    remoteHost: p.remoteHost ?? undefined,
    tunnel: p.tunnel ?? undefined,
    lastSeen,
    description: p.remoteHost ?? undefined,
  });
  if (p.location) b.relate("at", ref, { class: "location", name: p.location });
  return ref;
}

/** The datastore's `stored-on`: to the pool of its node its path is on
 *  (`/<pool>/…`, a pool mounted where ZFS mounts it), and an end to the node's
 *  other pools. A path on no pool (the root disk) relates to none. */
export function storedOn(b: CmdbBatch, ds: string, node: string | null | undefined, path: string | null | undefined, poolsOf: PoolsOf): void {
  if (!node) return;
  const on = typeof path === "string" ? /^\/([^/]+)/.exec(path)?.[1] : undefined;
  for (const pool of [...new Set(poolsOf(node))].sort()) {
    const ref = b.stub("storage-pool", pool, { onNode: { class: "machine", name: node } }, `storage-pool:${node}/${pool}`);
    if (pool === on) b.relate("stored-on", ds, ref);
    else b.relations.push({ type: "stored-on", from: ds, to: ref, end: true });
  }
}

/** Whether a host's file backups are of something this site still has (its
 *  config/<name>.json): a removed node's restore points stay in PBS, but a
 *  `backs-up` to it would bring back a CI its removal retired. */
export type SiteHas = (name: string) => boolean;

export function buildBackupReport(raw: RawRuns | null, runs: BackupRuns | null, peers: Peer[], poolsOf: PoolsOf = () => [], siteHas: SiteHas = () => true): CmdbBatch {
  const b = new CmdbBatch(SOURCE);
  if (raw && runs?.reachable && runs.store) {
    const status = raw.status ?? null;
    const ds = b.put("datastore", runs.store, {
      size: typeof status?.total === "number" ? status.total : undefined,
      used: typeof status?.used === "number" ? status.used : undefined,
      retention: retentionOf(raw, runs.store),
    });
    if (runs.node) b.relate("runs-on", ds, { class: "machine", name: runs.node });
    storedOn(b, ds, runs.node, raw.path, poolsOf);
    // This site's own restore points: its guests' and its hosts' file backups,
    // not the copies of other sites pulled or pushed here.
    const own = new Set(runs.targets.filter((t) => t.kind === "own" || t.kind === "host").map((t) => t.ns));
    for (const g of runs.guests) {
      if (!own.has(g.ns) || g.snapshots === 0) continue;
      if (g.type === "host") {
        if (siteHas(g.id)) b.relate("backs-up", ds, { class: "node", name: g.id }); // a file backup: of a machine or a guest
      }
      else if (g.module) b.relate("backs-up", ds, { class: g.type === "ct" ? "lxc" : "vm", name: g.module });
    }
  }
  const pulled = new Map<string, number>();
  for (const s of runs?.syncJobs ?? []) if (s.lastRun?.time) pulled.set(s.remote, Math.max(pulled.get(s.remote) ?? 0, s.lastRun.time));
  // One CI per buddy: a buddy we pull from and that pulls ours is one site.
  const order = { pull: 0, receive: 1, remote: 2 };
  for (const p of [...peers].sort((x, y) => order[x.role] - order[y.role])) {
    if (b.has(`backup-peer:${p.name}`)) continue;
    putPeer(b, p, iso(pulled.get(p.name) ?? pulled.get(`remote-${p.name}`)));
  }
  return b;
}

/** report --discover (ADR-040 D15): every datastore, not only the one the
 *  site's jobs use, with its GC state, each restore-point group's age, its
 *  prune settings and the sync jobs. */
export function buildBackupDiscover(raw: RawDiscover, now: number, poolsOf: PoolsOf = () => []): CmdbBatch {
  const b = new CmdbBatch(SOURCE);
  for (const d of raw.datastores ?? []) {
    const ds = b.put("datastore", d.name, {
      size: typeof d.status?.total === "number" ? d.status.total : undefined,
      used: typeof d.status?.used === "number" ? d.status.used : undefined,
      retention: retentionOf({ reachable: true, pruneJobs: raw.pruneJobs }, d.name),
      gc: d.gc ?? undefined,
      restorePoints: (d.groups ?? []).map((g) => ({
        ns: g.ns, type: g.type, id: g.id, snapshots: g.snapshots,
        newest: iso(g.newest), ageSeconds: now - g.newest,
      })),
      syncJobs: (raw.syncJobs ?? []).filter((s) => s.store === d.name),
    });
    if (raw.node) b.relate("runs-on", ds, { class: "machine", name: raw.node });
    storedOn(b, ds, raw.node, d.path, poolsOf);
  }
  return b;
}
