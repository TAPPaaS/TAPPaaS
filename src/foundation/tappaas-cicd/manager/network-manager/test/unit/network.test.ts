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

import { copyFileSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { PLANE_ORDER } from "../../src/types";
import { parseTemplate, validateName, zonesInit } from "../../src/zonesinit";
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
import { runChecks } from "../../src/zonescheck";
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

// ── 8. zones-init transform (offline; against the REAL distributed template) ─
// NM_TEMPLATE points at the canonical manager/network-manager/zones.json. We
// transform it in memory (the CLI's atomic write to --out is exercised by the
// shell tier); here we assert the transform rules + referential integrity.
{
  const tplPath = process.env.NM_TEMPLATE;
  if (!tplPath) {
    check(false, "NM_TEMPLATE env must point at the distributed zones.json template");
  } else {
    const template = parseTemplate(tplPath);
    const { raw, alreadyInitialised } = zonesInit(template, "acme", false);

    check(!alreadyInitialised, "transforming the distributed template is not a no-op");

    // renames
    check("acme" in raw && !("srv" in raw), "srv renamed to <N> (acme); srv key gone");
    check("acme-private" in raw && !("home" in raw), "home renamed to <N>-private; home key gone");
    check("acme-guest" in raw && !("guest" in raw), "guest renamed to <N>-guest; guest key gone");

    // <N> carried srv's config + state Active
    const acme = raw["acme"] as Record<string, unknown>;
    check(acme["type"] === "Service" && acme["vlantag"] === 200, "<N> carried srv's config (type/vlan)");
    check(acme["state"] === "Active", "<N> state forced Active");

    // <N>-private access-to has <N> and NOT srvHome
    const priv = raw["acme-private"] as Record<string, unknown>;
    const privAccess = priv["access-to"] as string[];
    check(privAccess.includes("acme"), "<N>-private access-to contains <N> (was srvHome)");
    check(!privAccess.includes("srvHome"), "<N>-private access-to no longer references srvHome");

    // inactivations
    for (const z of ["srvHome", "srvWork", "srvCust", "srvDev", "work"]) {
      const zz = raw[z] as Record<string, unknown>;
      check(zz !== undefined && zz["state"] === "Inactive", `${z} state forced Inactive`);
    }

    // untouched zones still present
    for (const z of ["srvTest", "iotLocal", "iotCloud", "iotCams", "mgmt", "dmz", "netbird", "test"]) {
      check(z in raw, `${z} still present (untouched)`);
    }
    // srvTest state unchanged from template
    check(
      (raw["srvTest"] as Record<string, unknown>)["state"] ===
        (template["srvTest"] as Record<string, unknown>)["state"],
      "srvTest state unchanged",
    );

    // referential integrity: NO zone's access-to / pinhole-allowed-from still
    // references the bare srv / home / guest keys.
    let refOk = true;
    for (const [k, v] of Object.entries(raw)) {
      if (k.startsWith("_")) continue;
      const zone = v as Record<string, unknown>;
      for (const field of ["access-to", "pinhole-allowed-from"]) {
        const arr = zone[field];
        if (Array.isArray(arr)) {
          for (const ref of arr) {
            if (ref === "srv" || ref === "home" || ref === "guest") {
              refOk = false;
            }
          }
        }
      }
    }
    check(refOk, "no zone references bare srv/home/guest after transform (referential integrity)");

    // mgmt access-to was rewritten srv→acme, home→acme-private, guest→acme-guest
    const mgmtAccess = (raw["mgmt"] as Record<string, unknown>)["access-to"] as string[];
    check(
      mgmtAccess.includes("acme") && mgmtAccess.includes("acme-private") && mgmtAccess.includes("acme-guest"),
      "mgmt.access-to rewritten to the renamed zone names",
    );
    // other srvHome refs preserved (NOT globally rewritten to <N>)
    check(mgmtAccess.includes("srvHome"), "mgmt.access-to still lists srvHome (not globally rewritten)");

    // idempotency: re-running on the transformed doc (srv absent, acme present) is a no-op
    const second = zonesInit(raw, "acme", false);
    check(second.alreadyInitialised, "second zones-init run on transformed doc is a no-op");

    // --force re-applies (but the transformed doc lacks srv → expected to error
    // since the template keys are gone); confirm it throws rather than silently no-op.
    let forceThrew = false;
    try {
      zonesInit(raw, "acme", true);
    } catch {
      forceThrew = true;
    }
    check(forceThrew, "--force on an already-transformed doc errors (template keys gone)");

    // doc-block preserved
    check("_README" in raw, "_README doc block preserved through the transform");
  }
}

// ── 9. zones-init name validation + edge fixture ──────────────────────
{
  for (const bad of ["", "Acme", "9acme", "ac me", "acme-", "-acme", "acme_x"]) {
    let threw = false;
    try {
      validateName(bad);
    } catch {
      threw = true;
    }
    check(threw, `invalid --name '${bad}' is rejected`);
  }
  for (const good of ["acme", "acme-corp", "a", "x1", "my-tappaas-1"]) {
    let threw = false;
    try {
      validateName(good);
    } catch {
      threw = true;
    }
    check(!threw, `valid --name '${good}' is accepted`);
  }

  // edge fixture: a minimal template missing 'guest' → clear error
  const d = mkdtempSync(join(tmpdir(), "nm-init-"));
  const edge = join(d, "edge.json");
  writeFileSync(edge, JSON.stringify({ srv: { state: "Inactive" }, home: { "access-to": ["srvHome"] } }), "utf8");
  let edgeThrew = false;
  try {
    zonesInit(parseTemplate(edge), "acme", false);
  } catch {
    edgeThrew = true;
  }
  check(edgeThrew, "template missing the 'guest' key is rejected with a clear error");
}

// ── 10. zones-check consistency audit (offline; temp fixtures) ────────
// Read-only checks against an in-memory doc + a temp config-dir. The good
// fixture passes; targeted mutations each produce a hard error; --strict
// promotes an Inactive-ref warning to an error.
{
  // Build a self-contained good doc (mgmt Active, dmz, two service zones).
  function goodRaw(): Record<string, unknown> {
    return {
      _README: { _comment: "doc block" },
      mgmt: {
        type: "Management",
        state: "Manual",
        typeId: "0",
        subId: "0",
        vlantag: 0,
        ip: "10.0.0.0/24",
        bridge: "lan",
        "access-to": ["internet", "srvHome", "dmz"],
        "pinhole-allowed-from": [],
      },
      dmz: {
        type: "DMZ",
        state: "Mandatory",
        typeId: "6",
        subId: "10",
        vlantag: 610,
        ip: "10.6.0.0/24",
        bridge: "lan",
        "access-to": ["internet"],
        "pinhole-allowed-from": ["internet"],
      },
      srvHome: {
        type: "Service",
        state: "Active",
        typeId: "2",
        subId: "10",
        vlantag: 210,
        ip: "10.2.10.0/24",
        bridge: "lan",
        "access-to": ["internet", "dmz"],
        "pinhole-allowed-from": ["dmz"],
      },
      srvOff: {
        type: "Service",
        state: "Inactive",
        typeId: "2",
        subId: "20",
        vlantag: 220,
        ip: "10.2.20.0/24",
        bridge: "lan",
        "access-to": ["internet"],
        "pinhole-allowed-from": [],
      },
    };
  }

  // Write a doc to a temp zones.json + return a fresh temp config-dir.
  function writeDoc(raw: Record<string, unknown>): { zonesFile: string; configDir: string } {
    const d = mkdtempSync(join(tmpdir(), "nm-check-"));
    const zonesFile = join(d, "zones.json");
    writeFileSync(zonesFile, JSON.stringify(raw, null, 2), "utf8");
    return { zonesFile, configDir: d };
  }
  function addModule(configDir: string, name: string, zone: string, field: "zone" | "zone0"): void {
    writeFileSync(join(configDir, name), JSON.stringify({ vmname: name.replace(/\.json$/, ""), [field]: zone }), "utf8");
  }

  // (a) good fixture passes (0 errors)
  {
    const { zonesFile, configDir } = writeDoc(goodRaw());
    addModule(configDir, "app.json", "srvHome", "zone0");
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors === 0, `good fixture: 0 errors (got ${r.errors}; warnings ${r.warnings})`);
  }

  // (b) dangling access-to ref → hard error
  {
    const raw = goodRaw();
    (raw.srvHome as Record<string, unknown>)["access-to"] = ["internet", "nosuchzone"];
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors > 0, `dangling access-to ref → hard error (got ${r.errors})`);
  }

  // (c) duplicate VLAN tag → hard error
  {
    const raw = goodRaw();
    (raw.srvOff as Record<string, unknown>).vlantag = 210; // collides with srvHome
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors > 0, `duplicate VLAN tag → hard error (got ${r.errors})`);
  }

  // (c2) duplicate subId within a type band → hard error
  {
    const raw = goodRaw();
    (raw.srvOff as Record<string, unknown>).subId = "10"; // band 2 already uses subId 10
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors > 0, `duplicate subId in a type band → hard error (got ${r.errors})`);
  }

  // (d) missing mgmt → hard error
  {
    const raw = goodRaw();
    delete raw.mgmt;
    // drop the now-dangling mgmt ref so we isolate the mgmt-invariant error
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors > 0, `missing mgmt zone → hard error (got ${r.errors})`);
  }

  // (d2) mgmt present but Inactive → hard error
  {
    const raw = goodRaw();
    (raw.mgmt as Record<string, unknown>).state = "Inactive";
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors > 0, `mgmt zone Inactive → hard error (got ${r.errors})`);
  }

  // (e) module config naming a non-existent zone → hard error
  {
    const { zonesFile, configDir } = writeDoc(goodRaw());
    addModule(configDir, "ghost.json", "nowhere", "zone0");
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors > 0, `module config zone missing from zones.json → hard error (got ${r.errors})`);
  }

  // (e2) module config naming an Inactive zone → hard error
  {
    const { zonesFile, configDir } = writeDoc(goodRaw());
    addModule(configDir, "off.json", "srvOff", "zone");
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors > 0, `module config zone Inactive → hard error (got ${r.errors})`);
  }

  // (f) Inactive-ref is a NOTE in normal mode but the check is otherwise clean,
  //     and --strict does NOT turn a note into an error (notes are informational).
  //     An Inactive-ref must not block; a MISSING field warns, and --strict
  //     promotes THAT warning to an error.
  {
    const raw = goodRaw();
    // srvHome references srvOff (Inactive) — allowed, noted, not an error.
    (raw.srvHome as Record<string, unknown>)["access-to"] = ["internet", "dmz", "srvOff"];
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors === 0, `Inactive-zone ref is allowed (noted), not an error (got ${r.errors})`);
  }

  // (g) --strict promotes a missing-field WARNING to an error.
  {
    const raw = goodRaw();
    delete (raw.srvOff as Record<string, unknown>)["access-to"]; // → missing-field warning
    const { zonesFile, configDir } = writeDoc(raw);
    const lenient = runChecks(loadZones(zonesFile), configDir, false);
    check(lenient.errors === 0 && lenient.warnings > 0, `missing field warns (lenient): warn ${lenient.warnings}, err ${lenient.errors}`);
    const strict = runChecks(loadZones(zonesFile), configDir, true);
    check(strict.errors > 0, `--strict promotes the warning to an error (got ${strict.errors})`);
  }
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
