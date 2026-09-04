// evacuate.test.ts — ADR-019 scenario C, offline.
//
// What is asserted is the LAYERING and the downtime contract, not Proxmox: a
// fleet loop that drives module-manager per module, and never reports a node
// clear when it is not.

import { evacuateNode, evacuateExitCode } from "../../src/evacuate";
import { FakeSiteClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    console.log(`  ok: ${msg}`);
    passed++;
  } else {
    console.log(`  FAIL: ${msg}`);
    failed++;
  }
}

const guests = (...names: string[]) =>
  names.map((n, i) => ({ vmid: 100 + i, name: n, type: "qemu" }));

// ── the happy path ──────────────────────────────────────────────────────
{
  const c = new FakeSiteClient();
  c.guests.set("tappaas3", guests("nextcloud", "identity"));
  const r = evacuateNode("tappaas3", c, false);
  check(r.moved.length === 2 && r.deferred.length === 0, "every guest moves → node clear");
  check(evacuateExitCode(r) === 0, "…and that is exit 0");
  check(
    c.log.includes("migrate nextcloud") && c.log.includes("migrate identity"),
    "each guest is moved through module-manager, one module at a time",
  );
  check(
    !c.log.some((l) => l.includes("migrate-vm") || l.includes("proxmox-controller")),
    "…and never by calling the controller directly (the ADR-019 layering)",
  );
}

// ── downtime is never implied ───────────────────────────────────────────
{
  const c = new FakeSiteClient();
  c.guests.set("tappaas3", guests("nextcloud", "db"));
  c.migrateRc.set("db", 10); // cannot move live
  const r = evacuateNode("tappaas3", c, false);
  check(r.deferred.includes("db"), "a guest needing downtime is DEFERRED, not stopped");
  check(r.moved.includes("nextcloud"), "…while the others still move");
  check(
    evacuateExitCode(r) === 10,
    "a node that is not clear must NOT report success — ADR-017's reboot pass gates on this",
  );
  check(!c.log.includes("migrate db --force"), "…and --force is never added on the caller's behalf");
}

// ── with --force the same evacuation completes ──────────────────────────
{
  const c = new FakeSiteClient();
  c.guests.set("tappaas3", guests("db"));
  const r = evacuateNode("tappaas3", c, true);
  check(c.log.includes("migrate db --force"), "--force is forwarded per module when given");
  check(evacuateExitCode(r) === 0, "…and the node comes back clear");
}

// ── failure is distinct from deferral ───────────────────────────────────
{
  const c = new FakeSiteClient();
  c.guests.set("tappaas3", guests("broken"));
  c.migrateRc.set("broken", 1);
  const r = evacuateNode("tappaas3", c, false);
  check(r.failed.length === 1 && r.deferred.length === 0, "a real failure is not a deferral");
  check(evacuateExitCode(r) === 1, "…and exits 1, not 10 — 'broken' is not 'your call'");
}

// ── an empty or unreachable node ────────────────────────────────────────
{
  const c = new FakeSiteClient();
  const r = evacuateNode("tappaas3", c, false);
  check(evacuateExitCode(r) === 0 && r.considered.length === 0, "a node with no guests is already clear");

  const c2 = new FakeSiteClient();
  c2.guestsUnreachable = true;
  const r2 = evacuateNode("tappaas3", c2, false);
  check(r2.unreachable && evacuateExitCode(r2) === 1, "a cluster that cannot be asked is an error, never 'clear'");
  check(!c2.log.some((l) => l.startsWith("migrate ")), "…and nothing is moved on a guess");
}

console.log("");
console.log(`evacuate.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
