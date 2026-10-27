// storage.test.ts — `node storage add` refuses what is not precise (ADR-037 D4),
// and what the console proposes from the inventory.

import { proposedLayout, proposedPoolName, storageAddProblems } from "../../src/storage";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

const ok = (pool: string, disks: string[], layout: string, pools: string[] = []): boolean =>
  storageAddProblems(pool, disks, layout, pools).length === 0;

check(ok("tanka1", ["S7HENJ0X100001", "S7HENJ0X100002"], "mirror"), "a mirror on two serials");
check(ok("tankb1", ["/dev/disk/by-id/ata-ST8000VN004_ZA1"], "single"), "one disk by id");
check(ok("tanka2", ["a1", "a2", "a3"], "raidz1") && ok("tankc1", ["a", "b", "c", "d"], "raidz2"), "raidz1 on 3, raidz2 on 4");
check(!ok("local-zfs", ["S1"], "single") && !ok("rpool", ["S1"], "single") && !ok("Tanka1", ["S1"], "single"),
  "the boot pool, Proxmox's names and anything not tank<...>: refused");
check(!ok("tanka1", ["S1"], "single", ["tanka1"]), "a pool the node has: refused");
check(!ok("tanka1", ["S1"], "mirror") && !ok("tanka1", ["S1", "S2"], "single") && !ok("tanka1", ["a", "b"], "raidz1"),
  "a disk count the layout does not take: refused");
check(!ok("tanka1", ["S1", "S1"], "mirror"), "the same disk twice: refused");
check(!ok("tanka1", ["nvme0n1"], "single"), "a kernel name: refused");
check(!ok("tanka1", [], "single") && !ok("tanka1", ["S1"], "stripe") && !ok("tanka1", ["S1"], ""),
  "no disks, an unknown or no layout: refused");
const many = storageAddProblems("x", ["nvme0n1"], "mirror", []);
check(many.length === 3, `every problem at once (${many.length})`);

check(proposedPoolName("nvme", ["tanka1"]) === "tanka2" && proposedPoolName("ssd", []) === "tanka1", "SSD/NVMe: the next tanka<N>");
check(proposedPoolName("hdd", ["tanka1", "tankb1"]) === "tankb2", "spinning disks: the next tankb<N>");
check(proposedLayout(1) === "single" && proposedLayout(2) === "mirror" && proposedLayout(4) === "raidz1", "the layout for a count");

console.log(`storage: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
