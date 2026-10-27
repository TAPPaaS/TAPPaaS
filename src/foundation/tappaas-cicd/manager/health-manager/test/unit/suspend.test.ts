// suspend.test.ts — a suspended module is reported by the liveness gate,
// never counted as down (#428).

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { SUSPENDED_STALE_DAYS, checkServiceLiveness, daysSince } from "../../src/checks";
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
  c.guests[0].status = "running";

  // #890: the nightly update patches a suspended module; one it has not reached
  // for two weeks (it never fitted on its node) is a warning.
  const now = new Date(2026, 9, 27, 9, 0, 0);
  check(Math.round(daysSince("20261020-09:00:00", now)) === 7 && daysSince("garbage", now) === 0, "daysSince reads updateTime");
  writeFileSync(join(dir, "media.json"), JSON.stringify({ vmid: 210, status: "Production", suspended: true, updateTime: "20261001-02:00:00" }));
  const r3 = checkServiceLiveness(c, dir, "tappaas1", now);
  check(r3.status === "warn" && r3.detail.includes(`over ${SUSPENDED_STALE_DAYS} days: media`), `a suspended module unpatched for 26 days warns (${r3.detail})`);
  check(r3.findings?.some((f) => f.status === "warn" && f.text.includes("not patched since 20261001-02:00:00")) === true, "…and its row says since when");
  writeFileSync(join(dir, "media.json"), JSON.stringify({ vmid: 210, status: "Production", suspended: true, updateTime: "20261026-02:00:00" }));
  check(checkServiceLiveness(c, dir, "tappaas1", now).status === "pass", "one patched last night passes");
  writeFileSync(join(dir, "media.json"), JSON.stringify({ vmid: 210, status: "Production", suspended: true, suspendedNoUpdate: true, updateTime: "20261001-02:00:00" }));
  check(checkServiceLiveness(c, dir, "tappaas1", now).status === "pass", "one suspended with --no-update is not expected to be patched");
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
