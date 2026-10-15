// suspend.test.ts — a suspended module is reported by the liveness gate,
// never counted as down (#428).

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkServiceLiveness } from "../../src/checks";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const dir = mkdtempSync(join(tmpdir(), "suspend-"));
try {
  writeFileSync(join(dir, "web.json"), JSON.stringify({ vmid: 200, status: "Production" }));
  writeFileSync(join(dir, "media.json"), JSON.stringify({ vmid: 210, status: "Production", suspended: true }));
  const c = new FakeClusterClient();
  c.guests = [
    { vmid: 200, name: "web", node: "tappaas1", status: "running", type: "qemu" },
    { vmid: 210, name: "media", node: "tappaas1", status: "stopped", type: "qemu" },
  ];
  const r = checkServiceLiveness(c, dir, "tappaas1");
  check(r.status === "pass", `a stopped suspended module is not down (${r.detail})`);
  check(r.detail.includes("suspended: media"), "…and is named as suspended");
  c.guests[0].status = "stopped";
  const r2 = checkServiceLiveness(c, dir, "tappaas1");
  check(r2.status === "fail" && r2.detail.includes("not running: web") && !r2.detail.includes("not running: media"),
    "a module that is not suspended and stopped still fails");
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
