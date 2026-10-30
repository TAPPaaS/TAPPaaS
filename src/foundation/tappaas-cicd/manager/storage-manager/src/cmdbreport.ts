// cmdbreport.ts — what storage-manager reports to the CMDB (ADR-040 D4): the
// ZFS pools `inventory` reads (storage-pool, runs-on its machine) and the NFS
// shares of config/shares.json (share: its export path and grants).
//
// A pool is named <node>/<pool>: ZFS pool names repeat across the nodes
// (replication needs the same name on each) and a storage-pool has no key on
// its node, so the bare name would make the pools of three nodes one CI.

import { CmdbBatch } from "../../../lib/ts/src/cmdb-reporter";
import { Share, SharesDoc, sharesOf } from "../../../lib/ts/src/nfs-shares";
import { Inventory } from "./inventory";

export const SOURCE = "storage-manager";
// lib/nfs-lib.sh's NFS_MOUNT_ROOT: where a managed Host exports each share.
const NFS_MOUNT_ROOT = "/tappaas-nfs";

export const poolName = (node: string, pool: string): string => `${node}/${pool}`;

export function putShare(b: CmdbBatch, name: string, s: Share): string {
  return b.put("share", name, {
    path: s.pool ? `${NFS_MOUNT_ROOT}/${name}` : s.path,
    grants: Object.entries(s.grants ?? {}).map(([consumer, access]) => ({ consumer, access })),
    description: s.pool ? `${s.server}:${s.pool}` : s.server,
    desired: { file: "shares.json", key: `nfs.shares.${name}` },
  });
}

export function buildStorageReport(shares: SharesDoc | null, inv: Inventory | null): CmdbBatch {
  const b = new CmdbBatch(SOURCE);
  for (const n of inv?.nodes ?? []) {
    if (!n.reachable) continue;
    for (const p of n.pools) {
      if (!p.present) continue;
      const ref = b.put("storage-pool", poolName(n.name, p.name), {
        displayName: p.name,
        type: "zfs",
        size: p.usable?.total ?? p.size,
        used: p.usable?.used ?? p.allocated,
        health: p.health,
      });
      b.relate("runs-on", ref, { class: "machine", name: n.name });
    }
  }
  for (const [name, s] of Object.entries(sharesOf(shares))) putShare(b, name, s);
  return b;
}
