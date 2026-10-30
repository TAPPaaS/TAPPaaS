// cmdbreport.test.ts — what `storage-manager report` sends to the CMDB (ADR-040
// D4): the pools of an inventory over hrossen's captured reads, and the shares
// of a shares.json, with their classes, names and relations.
//
// Run: SM_FIXTURE_DIR=<storage-manager>/test/fixtures node cmdbreport.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { ClusterGuest, ProbeSection } from "../../../../lib/ts/src/cluster";
import { SharesDoc } from "../../../../lib/ts/src/nfs-shares";
import { buildStorageReport } from "../../src/cmdbreport";
import { InvSources, ModuleRow, buildInventory } from "../../src/inventory";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) { passed++; console.log(`  ok: ${msg}`); }
  else { failed++; console.log(`  FAIL: ${msg}`); }
}

const FIX = join(process.env.SM_FIXTURE_DIR ?? "test/fixtures", "inventory-hrossen");
const load = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;
const src: InvSources = {
  clusterNodes: load<{ name: string; storagePools: string[] }[]>("nodes.json"),
  only: null,
  smart: true,
  nodes: Object.fromEntries(["tappaas1", "tappaas2", "tappaas3"].map((n) => [n, { sections: load<Record<string, ProbeSection>>(`${n}.json`) }])),
  guests: load<ClusterGuest[]>("guests.json"),
  replicationJobs: load<Record<string, unknown>[]>("replication.json"),
  modules: load<{ modules: ModuleRow[] }>("modules.json").modules,
  shares: load<Record<string, unknown>>("shares.json"),
  errors: [],
};
const inv = buildInventory(src, new Date(readFileSync(join(FIX, "now.txt"), "utf8").trim()));
const r = buildStorageReport(load<SharesDoc>("shares.json"), inv).report();
const objs = r.objects ?? [];
const obj = (cls: string, name: string) => objs.find((o) => o.class === cls && o.name === name);

check(r.source === "storage-manager" && r.kind === "observation", "an observation from storage-manager");
const pools = objs.filter((o) => o.class === "storage-pool").map((o) => `${(o.attributes!.onNode as { name: string }).name}/${o.name}`).sort();
check(pools.join() === "tappaas1/tanka1,tappaas1/tankb1,tappaas2/tanka1,tappaas3/tanka1,tappaas3/tankc1", "one storage-pool per node and pool: its name, on its machine");
const c1 = objs.find((o) => o.ref === "storage-pool:tappaas3/tankc1")?.attributes ?? {};
check(c1.type === "zfs" && c1.zfsState === "DEGRADED", "a pool: zfs, and ZFS's word for it");
check(typeof c1.size === "number" && typeof c1.used === "number" && (c1.used as number) <= (c1.size as number), "…its size and used, in bytes");
check(JSON.stringify(c1.onNode) === JSON.stringify({ class: "machine", name: "tappaas3" }), "a pool is on its machine (by name)");
const media = obj("share", "media")?.attributes ?? {};
check(media.path === "/tappaas-nfs/media", "a managed share's path is where its Host exports it");
check(JSON.stringify(media.grants) === JSON.stringify([{ consumer: "jellyfin", access: "rw" }]), "…and its grants");
check(JSON.stringify(media.desired) === JSON.stringify({ file: "shares.json", key: "nfs.shares.media" }), "…and its desired record");
const off = buildStorageReport(null, { ...inv, nodes: inv.nodes.map((n) => ({ ...n, reachable: false })) }).report();
check((off.objects ?? []).length === 0, "an unreachable node's pools are left out");

console.log(`\n${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
