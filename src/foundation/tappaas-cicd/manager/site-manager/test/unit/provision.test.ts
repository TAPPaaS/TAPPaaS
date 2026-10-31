// provision.test.ts — boot disks named before a PXE install (ADR-037 D4; #729 §3:
// nvme0n1 and nvme1n1 swapped between boots).

import { bootDiskProblems, bootDiskWarnings, isKernelDiskName, nodeLogDots, nodeLogLines, quorumAdvice } from "../../src/provision";

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

// ADR-037 D4: two fields the installer matches; blank is the automatic choice.
for (const [d, m] of [[undefined, undefined], ["2TB", ""], ["Samsung 990", "none"], ["25414A800205", "S6B0NL0W1"],
                      ["nvme0n1", "nvme1n1"], ["ask", ""], ["auto", "none"], ["1.92T", "1.92T x"]] as [string | undefined, string | undefined][]) {
  check(bootDiskProblems(d, m).length === 0, `--boot-disk ${d} --boot-mirror ${m}: accepted`);
}
check(bootDiskProblems(undefined, "nvme1n1").length === 1, "a named mirror without a named boot disk: refused");
check(bootDiskProblems("ask", "2TB").length === 1, "a named mirror of a console choice: refused");
check(bootDiskProblems("nvme0n1", "nvme0n1").length === 1, "a mirror onto the boot disk itself: refused");
check(bootDiskProblems("nvme0n1", "auto").length === 1, "an automatic mirror is the blank one: refused");
check(bootDiskProblems("/dev/sda").length === 1 && bootDiskProblems("*").length === 1, "a path or a glob: refused");
check(bootDiskWarnings("nvme0n1", "nvme1n1").length === 2 && bootDiskWarnings("2TB", "").length === 0,
  "kernel names are warned about, descriptions are not");

// #835: two votes and no QDevice — the survivor of a node failure fences itself.
check(quorumAdvice(2, false).includes("loses quorum") && quorumAdvice(2, false).includes("node qdevice add"),
  "two nodes without a QDevice: warned, with the way out");
check(quorumAdvice(3, false) === "" && quorumAdvice(2, true) === "" && quorumAdvice(1, false) === "",
  "three votes, a QDevice, or a single node: nothing to say");

// The node step's progress, as stage 3 shows it.
{
  const log = " - \x1b[33mConfiguring SSD lifecycle...\x1b[K \x1b[1;92m✓\x1b[m \x1b[1;92mConfigured SSD lifecycle\x1b[m\n" +
    " - Updating Proxmox VE (Patience — a dot per package step)........\n" +
    "......................................\n" +
    "    |_/_/    \\_\\_|\n" +
    " - Refreshing apt...\r\x1b[K ✓ Refreshed apt\n";
  const shown = new Set<string>();
  const first = nodeLogLines(log, shown);
  check(first.join("|") === "✓ Configured SSD lifecycle|Updating Proxmox VE (Patience — a dot per package step)|✓ Refreshed apt",
    `finished steps and the one under way, no dots, no art (${first.join("|")})`);
  check(nodeLogLines(log, shown).length === 0, "each is said once over the polls");
  check(nodeLogLines("✓ Updated Proxmox VE\n", shown).join() === "✓ Updated Proxmox VE", "a new step is said");
  check(nodeLogDots(" - Updating Proxmox VE (Patience — a dot per package step).....") === 5, "the dots after the step's line");
  check(nodeLogDots(" - Updating (step)....\n.....\n") === 9, "and on their own lines");
  check(nodeLogDots(" - Refreshing apt...") === 0, "a step's own dots are not progress");
  check(nodeLogDots(" - Updating (step)....\n ✓ Updated Proxmox VE\n") === 0, "none once the step has ended");
}

console.log(`provision: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
