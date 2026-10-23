// help.test.ts — position-manager's --help is its verb manifest (`--help --json`):
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
for (const r of ["validate", "rack list", "rack show", "place list", "place show", "cable list", "faceplates list", "faceplates show", "export"]) check(v(r)?.effect === "read", `${r} reads`);
for (const w of ["rack add", "rack modify", "rack delete", "place", "place modify", "unplace", "device record", "cable add", "cable remove"]) {
  check(v(w)?.effect === "write" && v(w).preview.kind === "dry-run-flag", `${w} writes, previewed with --check`);
}
for (const x of ["rack delete", "unplace", "cable remove"]) check(v(x).destructive, `${x} is destructive`);
for (const x of ["rack add", "rack modify", "place", "place modify", "device record", "cable add"]) check(!v(x).destructive, `${x} is not destructive`);
check(v("cable remove").object?.positional === "device:port", "cable remove names its port as the object");
check(v("place").positionals[0]?.name === "device", "place's positional is the device");
check(v("device record").positionals[0]?.name === "port-or-mac" && v("device record").object?.positional === "port-or-mac", "device record names the port it records from");
check(v("place").keys.some((k) => k.join(" ") === "mount add") && v("place modify").keys.some((k) => k.join(" ") === "mount modify") && v("unplace").keys.some((k) => k.join(" ") === "mount remove"), "mount add, modify and remove answer as aliases");

console.log(`\nposition-manager help: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
