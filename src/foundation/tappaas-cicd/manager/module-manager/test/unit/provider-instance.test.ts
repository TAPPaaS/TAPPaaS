// provider-instance.test.ts — a provider reached through its instances (ADR-029
// D1, ADR-026 D6).
//
// pvehost has no config/pvehost.json: its instances are named after the nodes
// (tappaas1..3). A `pvehost:nfs` coordinate must still resolve, to the first
// instance by name — the same answer the bash _provider_instance_of and the
// Python provider_instance_of give — and never to an environment's own copy of a
// module (coturn-demo answering for coturn is the #438 defect).
//
// Offline: a temp config directory.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { providerInstanceOf, resolveProviderModule } from "../../src/config";

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

const dir = mkdtempSync(join(tmpdir(), "provider-instance-"));
try {
  const put = (name: string, body: unknown): void =>
    writeFileSync(join(dir, `${name}.json`), typeof body === "string" ? body : JSON.stringify(body));
  put("tappaas2", { moduleSource: "/home/tappaas/TAPPaaS/src/foundation/pvehost" });
  put("tappaas1", { moduleSource: "/home/tappaas/TAPPaaS/src/foundation/pvehost/" });
  put("0-half-written", "broken{");
  put("coturn-demo", { moduleSource: "/x/coturn" });
  put("cluster", { location: "/x/cluster" });

  check(resolveProviderModule(dir, "pvehost") === "tappaas1", "no config of the module's name → its first instance by name");
  check(providerInstanceOf(dir, "pvehost") === "tappaas1", "a half-written file is skipped, not fatal");
  check(resolveProviderModule(dir, "cluster") === "cluster", "a config of the module's own name wins");
  check(resolveProviderModule(dir, "coturn") === "coturn", "an environment's own copy never answers for the shared name (#438)");
  check(resolveProviderModule(dir, "coturn", "demo") === "coturn-demo", "the environment's copy still answers for its environment");
  check(resolveProviderModule(dir, "ghost") === "ghost", "no instance → the name comes back for the caller to report");
  check(providerInstanceOf(join(dir, "nope"), "pvehost") === null, "a missing config directory is no instance");
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
