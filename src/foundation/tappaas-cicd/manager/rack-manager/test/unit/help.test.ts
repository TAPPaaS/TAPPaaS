// help.test.ts — rack-manager's --help is its verb manifest (`--help --json`):
// every option a usage names is described, the reads are reads, the writes
// preview with --check, and what removes something is destructive.

import { renderManifest, undocumentedOptions } from "../../../../lib/ts/src/help";
import { HELP } from "../../src/main";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}

const m = renderManifest(HELP);
const v = (name: string) => m.verbs.find((x) => x.verb === name)!;
check(undocumentedOptions(HELP).length === 0, `every option is described (${undocumentedOptions(HELP).join(", ")})`);
for (const r of ["validate", "rack list", "rack show", "mount list", "mount show", "cable list", "faceplates list", "faceplates show", "export"]) check(v(r)?.effect === "read", `${r} reads`);
for (const w of ["rack add", "rack modify", "rack delete", "mount add", "mount modify", "mount remove", "cable add", "cable remove"]) {
  check(v(w)?.effect === "write" && v(w).preview.kind === "dry-run-flag", `${w} writes, previewed with --check`);
}
for (const x of ["rack delete", "mount remove", "cable remove"]) check(v(x).destructive, `${x} is destructive`);
for (const x of ["rack add", "rack modify", "mount add", "mount modify", "cable add"]) check(!v(x).destructive, `${x} is not destructive`);
check(v("cable remove").object?.positional === "device:port", "cable remove names its port as the object");
check(v("mount add").positionals[0]?.name === "device", "mount add's positional is the device");

console.log(`\nrack-manager help: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
