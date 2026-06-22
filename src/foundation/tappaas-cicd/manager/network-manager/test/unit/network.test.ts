// network.test.ts — offline unit tests for network-manager.
//
// No cluster, no controllers: a FakePlaneClient records orchestration calls and
// a temp copy of the fixture zones.json exercises CRUD. Covers the chunk's
// Test Criteria:
//   - zone CRUD (add/list/exists/get/delete) on a temp zones.json
//   - reconcile orchestration calls all 4 planes in dependency order with the
//     correct dry-run/apply flag
//   - the switch plane IS invoked on zone add (the #372/#373 fix)
//   - per-plane rc aggregation (a plane error → overall fail; rc 2 dry-run →
//     drift reported, NOT a failure; proxmox rc 2 on apply → fail)
//   - delta/dry-run mutates nothing on disk
//
// Tiny assert harness (no test framework).

import { copyFileSync, mkdtempSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { PLANE_ORDER } from "../../src/types";
import {
  authorZone,
  getZone,
  listZoneNames,
  loadZones,
  removeZone,
  saveZones,
  zoneExists,
} from "../../src/zones";
import { reconcileAll } from "../../src/reconcile";
import { addZone, deleteZone } from "../../src/zonelifecycle";
import { FakePlaneClient } from "./fake-plane-client";

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

// __dirname points into the compiled dist-test tree (no fixtures there); the
// runner exports NM_FIXTURE_DIR pointing at the SOURCE test/fixtures.
const FIXTURE_DIR = process.env.NM_FIXTURE_DIR ?? join(__dirname, "..", "fixtures");
const FIXTURE = join(FIXTURE_DIR, "zones.json");

// Make a fresh temp copy of the fixture; tests mutate the copy, never the live
// config and never the fixture itself.
function tmpZones(): string {
  const d = mkdtempSync(join(tmpdir(), "nm-test-"));
  const f = join(d, "zones.json");
  copyFileSync(FIXTURE, f);
  return f;
}

// ── 1. zone CRUD on a temp zones.json ────────────────────────────────
{
  const f = tmpZones();
  let doc = loadZones(f);
  check(listZoneNames(doc).join(",") === "dmz,mgmt,srvHome", "list returns sorted real zones (no _README)");
  check(zoneExists(doc, "srvHome") && !zoneExists(doc, "nope"), "exists true/false correct");
  check(getZone(doc, "dmz")?.vlantag === 600, "get returns the zone with its vlantag");

  // add (author) → vlan auto-allocated in band 2 → highest free sub (299)
  const z = authorZone(doc, "srvTenant", { fromZone: "srvHome", variant: "tenant1" });
  check(z.vlantag === 299, `add auto-allocates highest free VLAN in band (got ${z.vlantag})`);
  check(z.ip === "10.2.99.0/24", `add computes ip from typeId.sub (got ${z.ip})`);
  check(z.parent === "srvHome" && z.variant === "tenant1", "add inherits parent + tags variant");
  check(z["access-to"]?.includes("internet") === true, "add inherits access-to from --from-zone");
  saveZones(f, doc);

  // reload → present + persisted, and mgmt.access-to now lists it (#372/#373 invariant)
  doc = loadZones(f);
  check(zoneExists(doc, "srvTenant"), "added zone persists across reload");
  const mgmt = doc.raw["mgmt"] as Record<string, unknown>;
  check(
    Array.isArray(mgmt["access-to"]) && (mgmt["access-to"] as string[]).includes("srvTenant"),
    "add appends zone to mgmt.access-to (operational-visibility invariant)",
  );

  // delete → removed + mgmt cleaned up
  removeZone(doc, "srvTenant");
  saveZones(f, doc);
  doc = loadZones(f);
  check(!zoneExists(doc, "srvTenant"), "deleted zone removed across reload");
  const mgmt2 = doc.raw["mgmt"] as Record<string, unknown>;
  check(
    !(mgmt2["access-to"] as string[]).includes("srvTenant"),
    "delete removes zone from mgmt.access-to",
  );
}

// ── 2. duplicate / bad-name authoring is rejected ─────────────────────
{
  const f = tmpZones();
  const doc = loadZones(f);
  let threw = false;
  try {
    authorZone(doc, "dmz", {});
  } catch {
    threw = true;
  }
  check(threw, "authoring an existing zone name is rejected");

  threw = false;
  try {
    authorZone(doc, "Bad-Name", {});
  } catch {
    threw = true;
  }
  check(threw, "non-camelCase zone name is rejected (#278)");
}

// ── 3. reconcile orchestration: all 4 planes, dependency order, flags ─
{
  const f = tmpZones();
  const c = new FakePlaneClient();
  const report = reconcileAll(c, { apply: false, zonesFile: f });
  check(
    c.planesCalled().join(",") === PLANE_ORDER.join(","),
    `reconcile calls all 4 planes in dependency order (got ${c.planesCalled().join(",")})`,
  );
  check(
    c.calls.every((x) => x.apply === false),
    "dry-run reconcile passes apply=false to every plane",
  );
  check(report.failed.length === 0, "all-in-sync dry-run reports no failures");

  const c2 = new FakePlaneClient();
  reconcileAll(c2, { apply: true, zonesFile: f });
  check(c2.calls.every((x) => x.apply === true), "--apply reconcile passes apply=true to every plane");

  // --only switch runs ONLY the switch plane
  const c3 = new FakePlaneClient();
  reconcileAll(c3, { apply: false, only: "switch", zonesFile: f });
  check(c3.planesCalled().join(",") === "switch", "--only switch runs just the switch plane");
}

// ── 4. the switch plane IS invoked on zone add (the #372/#373 fix) ────
{
  const f = tmpZones();
  const c = new FakePlaneClient();
  const res = addZone(c, f, "srvTenant", { fromZone: "srvHome" });
  check(
    c.planesCalled().includes("switch"),
    "zone add reconciles the SWITCH plane (#372/#373 fix that zone-controller.sh omitted)",
  );
  check(
    c.planesCalled().join(",") === PLANE_ORDER.join(","),
    "zone add reconciles ALL 4 planes in dependency order",
  );
  check(c.calls.every((x) => x.apply === true), "zone add reconciles with apply=true");
  check(res.report.failed.length === 0, "zone add succeeds when all planes in sync");
}

// ── 5. zone delete reconciles the switch plane too, and the order ─────
{
  const f = tmpZones();
  // seed a deletable zone first
  let doc = loadZones(f);
  authorZone(doc, "srvTenant", { fromZone: "srvHome" });
  saveZones(f, doc);

  const c = new FakePlaneClient();
  deleteZone(c, f, "srvTenant", {});
  check(c.planesCalled().includes("switch"), "zone delete reconciles the SWITCH plane");
  check(c.planesCalled().join(",") === PLANE_ORDER.join(","), "zone delete reconciles all 4 planes in order");

  doc = loadZones(f);
  check(!zoneExists(doc, "srvTenant"), "zone delete removes the key after reconcile");
}

// ── 6. per-plane rc aggregation ───────────────────────────────────────
{
  const f = tmpZones();

  // a plane ERROR (rc 1) → overall fail
  const cErr = new FakePlaneClient();
  cErr.setRc("ap", 1);
  const rErr = reconcileAll(cErr, { apply: true, zonesFile: f });
  check(rErr.failed.includes("ap"), "a plane rc=1 (error) → overall failure");

  // rc 2 in DRY-RUN → drift REPORTED, not a failure
  const cDrift = new FakePlaneClient();
  cDrift.setRc("proxmox", 2);
  const rDrift = reconcileAll(cDrift, { apply: false, zonesFile: f });
  const proxRes = rDrift.results.find((x) => x.plane === "proxmox");
  check(proxRes?.status === "drift", "rc=2 in dry-run classifies as drift");
  check(rDrift.failed.length === 0, "rc=2 in dry-run is reported, NOT a failure");

  // proxmox rc 2 on APPLY (still drifting) → failure
  const cApply = new FakePlaneClient();
  cApply.setRc("proxmox", 2);
  const rApply = reconcileAll(cApply, { apply: true, zonesFile: f });
  check(rApply.failed.includes("proxmox"), "proxmox rc=2 after --apply → failure (still drifting)");

  // switch/ap rc 2 on APPLY (needs-manual) → reported, NOT a hard failure
  const cManual = new FakePlaneClient();
  cManual.setRc("switch", 2);
  const rManual = reconcileAll(cManual, { apply: true, zonesFile: f });
  const swRes = rManual.results.find((x) => x.plane === "switch");
  check(swRes?.status === "needs-manual", "switch rc=2 on apply → needs-manual");
  check(!rManual.failed.includes("switch"), "switch needs-manual is surfaced but not a hard failure");
}

// ── 7. delta / dry-run mutates nothing on disk ────────────────────────
{
  const f = tmpZones();
  const before = readFileSync(f, "utf8");

  // dry-run reconcile
  reconcileAll(new FakePlaneClient(), { apply: false, zonesFile: f });
  check(readFileSync(f, "utf8") === before, "dry-run reconcile does not touch zones.json");

  // zone add --check (dryRun) mutates nothing
  addZone(new FakePlaneClient(), f, "srvTenant", { fromZone: "srvHome", dryRun: true });
  check(readFileSync(f, "utf8") === before, "zone add --check mutates nothing on disk");

  // zone delete --check mutates nothing
  deleteZone(new FakePlaneClient(), f, "dmz", { dryRun: true });
  check(readFileSync(f, "utf8") === before, "zone delete --check mutates nothing on disk");
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
