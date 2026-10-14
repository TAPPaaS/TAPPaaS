// pools.test.ts — the storage-pools gate (#100) against seeded pools, and the
// parsers behind the live client.

import { checkStoragePools } from "../../src/checks";
import { parseStoragePools, sumVolsizes } from "../../src/client";
import { StoragePool } from "../../src/types";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const G = 1024 ** 3;
const pool = (node: string, storage: string, total: number, used: number, provisioned = -1): StoragePool =>
  ({ node, storage, type: "zfspool", total: total * G, used: used * G, provisioned: provisioned < 0 ? -1 : provisioned * G });

{
  const c = new FakeClusterClient();
  c.pools = [pool("tappaas1", "tanka1", 1000, 120, 300), pool("tappaas2", "tanka1", 500, 50)];
  const r = checkStoragePools(c);
  check(r.status === "pass", "pools under 80% pass");
  check(r.detail.includes("2 pool(s)"), `the pools are counted (got: ${r.detail})`);
}
{
  const c = new FakeClusterClient();
  c.pools = [pool("tappaas1", "tanka1", 1000, 850), pool("tappaas2", "tanka1", 1000, 100)];
  const r = checkStoragePools(c);
  check(r.status === "warn", "a pool at 85% warns");
  check(r.detail.includes("tappaas1/tanka1") && !r.detail.includes("tappaas2"), "only the full pool is named");
}
{
  const c = new FakeClusterClient();
  c.pools = [pool("tappaas3", "tanka1", 1000, 920)];
  check(checkStoragePools(c).status === "fail", "a pool at 92% fails");
}
{
  const c = new FakeClusterClient();
  c.pools = [pool("tappaas1", "tanka1", 1000, 100, 1500)];
  const r = checkStoragePools(c);
  check(r.status === "warn", "disks adding up past the pool warn, even when the pool is mostly empty");
  check(r.detail.includes("overcommitted"), "…and say why");
}
{
  const c = new FakeClusterClient();
  c.poolsThrow = "no nodes";
  check(checkStoragePools(c).status === "skip", "an unreachable cluster skips");
}
{
  const rows = [
    { type: "storage", node: "tappaas1", storage: "tanka1", plugintype: "zfspool", status: "available", maxdisk: 100, disk: 10 },
    { type: "storage", node: "tappaas1", storage: "tappaas_backup", plugintype: "pbs", shared: 1, status: "available", maxdisk: 100, disk: 10 },
    { type: "storage", node: "tappaas1", storage: "tankc1", plugintype: "zfspool", status: "unknown", maxdisk: 0, disk: 0 },
  ];
  const p = parseStoragePools(rows);
  check(p.length === 1 && p[0].storage === "tanka1", "backup stores and disabled pools are left out");
  const sums = sumVolsizes("tanka1/vm-100-disk-0\t1073741824\ntanka1/vm-101-disk-0\t1073741824\ntankb1/vm-1-disk-0\t5\n");
  check(sums.get("tanka1") === 2 * G && sums.get("tankb1") === 5, "zvol sizes add up per pool");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
