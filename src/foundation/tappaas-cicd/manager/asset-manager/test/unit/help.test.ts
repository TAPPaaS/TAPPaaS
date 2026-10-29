// help.test.ts — asset-manager's --help is its verb manifest (`--help --json`):
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
for (const r of ["validate", "rack list", "rack show", "place list", "place show", "cable list", "asset list", "asset show", "faceplates list", "faceplates show", "export"]) check(v(r)?.effect === "read", `${r} reads`);
for (const w of ["rack add", "rack modify", "rack delete", "place", "place modify", "unplace", "asset add", "asset modify", "asset remove", "asset record", "asset receive", "asset fault", "asset repaired", "asset dispose", "asset allocate", "asset release", "port add", "port modify", "port remove", "cable add", "cable remove"]) {
  check(v(w)?.effect === "write" && v(w).preview.kind === "dry-run-flag", `${w} writes, previewed with --check`);
}
for (const x of ["rack delete", "unplace", "cable remove", "asset dispose", "port remove"]) check(v(x).destructive, `${x} is destructive`);
for (const x of ["rack add", "rack modify", "place", "place modify", "asset add", "asset record", "asset allocate", "asset release", "port add", "cable add"]) check(!v(x).destructive, `${x} is not destructive`);
check(v("cable remove").object?.positional === "device:port", "cable remove names its port as the object");
check(v("place").positionals[0]?.name === "device", "place's positional is the device");
check(v("asset record").positionals[0]?.name === "port-or-mac" && v("asset record").object?.positional === "port-or-mac", "asset record names the port it records from");
check(v("asset add").positionals[0]?.name === "asset" && v("asset add").positionals[0]?.optional, "asset add: its name is optional (the next tag of its kind)");
check(v("port add").object?.positional === "port" && v("port add").object?.within.join() === "asset", "port add names the port within its asset");
for (const [verb, old] of [["asset list", "device list"], ["asset show", "device show"], ["asset add", "device add"], ["asset modify", "device modify"], ["asset remove", "device remove"], ["asset record", "device record"]]) {
  check(v(verb).keys.some((k) => k.join(" ") === old), `${old} answers as ${verb}'s alias`);
}
check(v("place").keys.some((k) => k.join(" ") === "mount add") && v("place modify").keys.some((k) => k.join(" ") === "mount modify") && v("unplace").keys.some((k) => k.join(" ") === "mount remove"), "mount add, modify and remove answer as aliases");

console.log(`\nasset-manager help: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
