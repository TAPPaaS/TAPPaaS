// media.test.ts — `node media`: what is wrong with the staged medium, and
// what prepare would run for it.

import { MediaStatus, mediaProblems, mediaReport, prepareArgv, prepareMedia } from "../../src/media";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

const ready: MediaStatus = {
  directory: "/var/lib/tappaas-pxe", staged: true, current: true, source: "/home/tappaas/pve-tappaas-netboot.iso", sourcePresent: true,
  stickImage: { path: "/var/lib/tappaas-pxe/tappaas-usb.iso", present: true, size: 1700000000, modified: "2026-10-28T16:00:00+0100" }, xorriso: true,
};
const noStick: MediaStatus = { ...ready, stickImage: { ...ready.stickImage, present: false, size: 0, modified: null } };
const stale: MediaStatus = { ...noStick, current: false };
const bare: MediaStatus = { ...stale, staged: false, sourcePresent: false };

check(mediaProblems(ready).length === 0 && mediaReport(ready).ready, "staged, current, with the stick image: nothing wrong");
check(mediaProblems(noStick).join() === "the installer stick image is missing (/var/lib/tappaas-pxe/tappaas-usb.iso)", "a missing stick image is the one problem");
check(mediaProblems(stale)[0] === "the netboot assets predate this version's installer hook", "stale assets are said first");
check(mediaProblems(bare)[0] === "the netboot assets are not staged (/var/lib/tappaas-pxe)", "nothing staged");
check(mediaProblems({ ...ready, xorriso: false }).length === 0, "no xorriso is no problem once the image is built");
check(mediaProblems({ ...noStick, xorriso: false }).join().includes("xorriso is not installed"), "…but is while the image is still to be built");

check(prepareArgv(ready, false) === null, "nothing to prepare when ready");
check(prepareArgv(ready, true)!.argv.join(" ") === "prepare-netboot.sh --force", "--force runs the whole script again");
check(prepareArgv(noStick, false)!.argv.join(" ") === "sudo node-provisioner prepare --iso /home/tappaas/pve-tappaas-netboot.iso", "the ISO already here: node-provisioner prepare alone");
check(prepareArgv(stale, false)!.argv[1] === "node-provisioner", "stale assets with their ISO: the same");
check(prepareArgv({ ...stale, sourcePresent: false }, false)!.argv.join(" ") === "prepare-netboot.sh --force", "stale assets and no ISO: the whole script, forced past its 'already staged' exit");
check(prepareArgv(bare, false)!.argv.join(" ") === "prepare-netboot.sh", "nothing staged: the whole script");

check(mediaReport(noStick).prepare!.argv[1] === "node-provisioner", "the report says what prepare would run");
check(mediaReport({ ...noStick, xorriso: false }).prepare === null, "…but nothing when only the image is missing and xorriso is not there to build it");
check(mediaReport({ ...stale, xorriso: false }).prepare !== null, "stale assets are worth re-staging even without xorriso");

// prepareMedia runs the chosen command and reads the status again.
const ran: string[][] = [];
let status = noStick;
// eslint-disable-next-line @typescript-eslint/no-require-imports
const cp = require("child_process") as { spawnSync: (...a: unknown[]) => unknown };
const origSpawn = cp.spawnSync;
cp.spawnSync = (cmd: unknown, args: unknown, ...rest: unknown[]) => {
  if (cmd === "node-provisioner" && (args as string[])[0] === "assets") return { status: 0, stdout: JSON.stringify(status), stderr: "" };
  return origSpawn(cmd, args, ...rest);
};
prepareMedia(false, (argv) => { ran.push(argv); status = ready; return 0; });
check(ran.length === 1 && ran[0][1] === "node-provisioner", "prepare ran node-provisioner prepare for a missing stick image");
ran.length = 0;
prepareMedia(false, (argv) => { ran.push(argv); return 0; });
check(ran.length === 0, "ready: nothing is run");
let died = "";
try {
  prepareMedia(false, () => 1);
} catch (e) { died = (e as Error).message; }
status = noStick;
try {
  prepareMedia(false, () => 1);
} catch (e) { died = (e as Error).message; }
check(died.includes("failed (rc 1)"), `a failing command is a failure (${died})`);
cp.spawnSync = origSpawn;

console.log(`media: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
