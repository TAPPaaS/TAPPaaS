// provision.test.ts — disks named before a PXE install (#729 §3: nvme0n1 and
// nvme1n1 swapped between boots, so a pool declared on nvme0n1 hit the boot disk).

import { isKernelDiskName, pxeDiskProblems, quorumAdvice } from "../../src/provision";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

for (const k of ["sda", "sdab", "vdb", "nvme0n1", "nvme10n2", "mmcblk0"]) {
  check(isKernelDiskName(k), `${k} is a kernel name`);
}
for (const s of ["25414A800205", "50026B73842AD86F", "disk/by-id/nvme-KINGSTON_X", "ask", "nvme0n1p1"]) {
  check(!isKernelDiskName(s), `${s} is not a kernel name`);
}

check(pxeDiskProblems(undefined, []).length === 0, "nothing named: nothing to refuse");
check(pxeDiskProblems("25414A800205", ["tanka1=single:disk/by-id/nvme-KINGSTON_X"]).length === 0,
  "serial boot disk + by-id pool pass");
check(pxeDiskProblems("50026B73842AD86F", ["tanka1=single:50026B73842AD86F"]).length === 0,
  "a pool disk by bare serial passes");
const boot = pxeDiskProblems("nvme0n1", []);
check(boot.length === 1 && boot[0].includes("SERIAL"), "a kernel-name boot disk is refused, pointing at the serial");
const pool = pxeDiskProblems(undefined, ["tankb1=mirror:disk/by-id/a,sdc"]);
check(pool.length === 1 && pool[0].includes("sdc") && !pool[0].includes("disk/by-id/a is"),
  "only the kernel name in a pool is named");
check(pxeDiskProblems("sda", ["tanka1=single:nvme0n1"]).length === 2, "both refused at once");

// #835: two votes and no QDevice — the survivor of a node failure fences itself.
check(quorumAdvice(2, false).includes("loses quorum") && quorumAdvice(2, false).includes("QDevice"),
  "two nodes without a QDevice: warned, with the way out");
check(quorumAdvice(3, false) === "" && quorumAdvice(2, true) === "" && quorumAdvice(1, false) === "",
  "three votes, a QDevice, or a single node: nothing to say");

console.log(`provision: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
