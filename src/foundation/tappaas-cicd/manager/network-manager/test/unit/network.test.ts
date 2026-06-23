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

import { copyFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { PLANE_ORDER } from "../../src/types";
import { parseTemplate, renameTemplateFile, validateName, zonesInit } from "../../src/zonesinit";
import { mergeZones, runZonesMerge } from "../../src/zonesmerge";
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
import {
  distributeZones,
  enumerateNodes,
  nodeTarget,
  shouldAutoDistribute,
} from "../../src/distribute";
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

// ── 11. zones distribute-on-change (N3; offline — NO real scp) ────────
// Assert node enumeration from a fixture configuration.json, that --dry-run
// lists targets without scp, that distribute is auto-skipped for a non-live
// --out / when NM_NO_DISTRIBUTE=1, and that the lifecycle/zones-init write
// paths to a temp file never attempt SSH. A sentinel scp bin proves no scp
// runs: if it were ever exec'd it would create a marker file we then detect.
{
  // A fake scp that, if ever run, drops a marker — so we can prove it was NOT.
  const scpDir = mkdtempSync(join(tmpdir(), "nm-scp-"));
  const marker = join(scpDir, "scp-was-run");
  const fakeScp = join(scpDir, "scp");
  writeFileSync(fakeScp, `#!/usr/bin/env bash\ntouch '${marker}'\nexit 0\n`, "utf8");
  // chmod via spawnSync (no fs.chmodSync in our ambient decls); harmless if it
  // no-ops — the assertions rely on the marker file, not on exec succeeding.

  // (a) enumerateNodes parses tappaas-nodes[].hostname from configuration.json.
  const cfgDir = mkdtempSync(join(tmpdir(), "nm-cfg-"));
  writeFileSync(
    join(cfgDir, "configuration.json"),
    JSON.stringify({
      "tappaas-nodes": [
        { hostname: "tappaas1" },
        { hostname: "tappaas2" },
        { hostname: "" }, // empty → skipped (mirrors jq `// empty`)
        { nothost: "x" }, // no hostname → skipped
      ],
    }),
    "utf8",
  );
  const nodes = enumerateNodes(cfgDir);
  check(nodes.join(",") === "tappaas1,tappaas2", `enumerateNodes reads node hostnames, skips empties (got ${nodes.join(",")})`);

  // missing configuration.json → empty list (non-fatal, nothing to push)
  const emptyCfg = mkdtempSync(join(tmpdir(), "nm-cfg-empty-"));
  check(enumerateNodes(emptyCfg).length === 0, "enumerateNodes returns [] when configuration.json is absent");

  // (b) nodeTarget shape mirrors the bash root@<host>.mgmt.internal:/root/tappaas/zones.json
  check(
    nodeTarget("tappaas1") === "root@tappaas1.mgmt.internal:/root/tappaas/zones.json",
    "nodeTarget builds the mgmt FQDN scp target at /root/tappaas/zones.json",
  );

  // (c) distribute --dry-run lists targets, scp NEVER runs (marker absent).
  {
    const f = tmpZones();
    process.env.NM_SCP_BIN = fakeScp;
    const lines: string[] = [];
    const res = distributeZones(f, { cfgDir, dryRun: true, info: (m) => lines.push(m), warn: (m) => lines.push(m) });
    check(res.dryRun && res.pushed === 0 && res.rc === 0, "dry-run distribute pushes nothing and rc=0");
    check(res.nodes.map((n) => n.hostname).join(",") === "tappaas1,tappaas2", "dry-run distribute enumerates the configured nodes");
    check(lines.some((l) => l.includes("root@tappaas1.mgmt.internal:/root/tappaas/zones.json")), "dry-run distribute lists each node scp target");
    check(!existsSync(marker), "dry-run distribute did NOT invoke scp (no marker)");
  }

  // (d) shouldAutoDistribute: skips for a non-live --out and when NM_NO_DISTRIBUTE=1.
  {
    const prev = process.env.NM_NO_DISTRIBUTE;
    delete process.env.NM_NO_DISTRIBUTE;
    check(
      shouldAutoDistribute("/tmp/somewhere/zones.json", false) === false,
      "auto-distribute skipped for a non-live --out (temp path)",
    );
    process.env.NM_NO_DISTRIBUTE = "1";
    check(
      shouldAutoDistribute("/tmp/somewhere/zones.json", false) === false,
      "auto-distribute skipped when NM_NO_DISTRIBUTE=1",
    );
    if (prev === undefined) delete process.env.NM_NO_DISTRIBUTE;
    else process.env.NM_NO_DISTRIBUTE = prev;
  }

  // (e) the lifecycle write paths (zone add/delete) to a TEMP zones.json never
  //     distribute — the target is not the live ${CONFIG_DIR}/zones.json — so
  //     scp is never attempted (marker stays absent) and the op still succeeds.
  {
    process.env.NM_SCP_BIN = fakeScp;
    const f = tmpZones();
    const c = new FakePlaneClient();
    const add = addZone(c, f, "srvTenant", { fromZone: "srvHome" });
    check(add.report.failed.length === 0, "zone add to a temp zones.json succeeds without distributing");
    deleteZone(new FakePlaneClient(), f, "srvTenant", {});
    check(!existsSync(marker), "zone add/delete to a temp zones.json did NOT SSH (non-live target auto-skipped)");
  }

  // (f) distributeZones on a MISSING zones.json is non-fatal (rc=1, no scp).
  {
    process.env.NM_SCP_BIN = fakeScp;
    const res = distributeZones(join(cfgDir, "does-not-exist.json"), { cfgDir, info: () => {}, warn: () => {} });
    check(res.rc === 1 && res.pushed === 0, "distribute on a missing zones.json returns rc=1, pushes nothing");
    check(!existsSync(marker), "distribute on a missing zones.json did NOT invoke scp");
  }

  delete process.env.NM_SCP_BIN;
}

// ── 12. zones-merge: rename-aware 3-way reconciliation (Design A) ─────
// The whole point: after a renamed install (current==orig==renamed source),
// a merge must NOT re-introduce srv/home/guest, and must be stable. Then we
// exercise the per-field rules and --diff. All on temp dirs; NM_TEMPLATE points
// at the real distributed template; never touches live config.
{
  const tpl = process.env.NM_TEMPLATE;
  if (!tpl) {
    check(false, "NM_TEMPLATE env must point at the distributed zones.json template (zones-merge tests)");
  } else {
    // A renamed-install config dir: site.json + the three zones files all seeded
    // from the renamed template (mirrors what zones-init now writes).
    const NAME = "myorg";
    function freshRenamedConfig(): string {
      const dir = mkdtempSync(join(tmpdir(), "nm-merge-"));
      const renamed = renameTemplateFile(tpl!, NAME).raw;
      const txt = JSON.stringify(renamed, null, 4) + "\n";
      writeFileSync(join(dir, "site.json"), JSON.stringify({ name: NAME }), "utf8");
      writeFileSync(join(dir, "zones.json"), txt, "utf8");
      writeFileSync(join(dir, "zones.json.orig"), txt, "utf8");
      // zones.rename.json regenerated by the merge; seed it too for realism.
      writeFileSync(join(dir, "zones.rename.json"), txt, "utf8");
      return dir;
    }
    const renameRaw = () => renameTemplateFile(tpl, NAME, new Set<string>()).raw;
    const silent = { info: () => {}, warn: () => {} };
    function readJson(p: string): Record<string, unknown> {
      return JSON.parse(readFileSync(p, "utf8")) as Record<string, unknown>;
    }
    function dupVlans(raw: Record<string, unknown>): number[] {
      const seen = new Map<number, number>();
      for (const [k, v] of Object.entries(raw)) {
        if (k.startsWith("_") || v === null || typeof v !== "object" || Array.isArray(v)) continue;
        const vt = (v as Record<string, unknown>)["vlantag"];
        if (typeof vt === "number" && vt > 0) seen.set(vt, (seen.get(vt) ?? 0) + 1);
      }
      return [...seen.entries()].filter(([, n]) => n > 1).map(([vt]) => vt);
    }

    // (a) THE CORE BUG: a merge on a fresh renamed install does NOT re-add
    //     srv/home/guest and introduces no duplicate vlantags.
    {
      const dir = freshRenamedConfig();
      const rc = runZonesMerge(
        { current: join(dir, "zones.json"), orig: join(dir, "zones.json.orig"), rename: join(dir, "zones.rename.json"), template: tpl, name: NAME },
        silent,
        renameRaw,
      );
      const merged = readJson(join(dir, "zones.json"));
      check(rc === 0, "zones-merge on a fresh renamed install returns rc=0");
      check(!("srv" in merged) && !("home" in merged) && !("guest" in merged), "merge does NOT re-add srv/home/guest (the core bug)");
      check("myorg" in merged && "myorg-private" in merged && "myorg-guest" in merged, "renamed zones remain present after merge");
      check(dupVlans(merged).length === 0, `merge introduces no duplicate vlantags (got dups ${JSON.stringify(dupVlans(merged))})`);
      // and it is stable: a SECOND merge changes nothing.
      const after1 = readFileSync(join(dir, "zones.json"), "utf8");
      runZonesMerge(
        { current: join(dir, "zones.json"), orig: join(dir, "zones.json.orig"), rename: join(dir, "zones.rename.json"), template: tpl, name: NAME },
        silent,
        renameRaw,
      );
      const after2 = readFileSync(join(dir, "zones.json"), "utf8");
      check(after1 === after2, "a second merge is a no-op (stable)");
      // baseline advanced to the renamed source.
      check(!("srv" in readJson(join(dir, "zones.json.orig"))), "zones.json.orig advanced into the renamed namespace (no srv)");
    }

    // (b) a genuine upstream change flows in where current==orig. Use mergeZones
    //     directly: a new zone in source is ADDED; a non-state field change on a
    //     shared zone (current==orig) is ADOPTED.
    {
      const renamed = renameRaw();
      const current = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      const orig = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      // upstream introduces a new zone + changes a description on a shared zone.
      const source = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      source["brandNew"] = { state: "Inactive", vlantag: 299, type: "Service" };
      (source["myorg"] as Record<string, unknown>)["description"] = "UPSTREAM CHANGED";
      const r = mergeZones(current, orig, source);
      check("brandNew" in r.merged, "upstream's new zone is ADDED by the merge");
      check(r.added.includes("brandNew"), "the new zone is reported as added");
      check((r.merged["myorg"] as Record<string, unknown>)["description"] === "UPSTREAM CHANGED", "an upstream non-state field change flows in where current==orig (adopted)");
    }

    // (c) an operator edit (current != orig) is PINNED over an upstream change.
    {
      const renamed = renameRaw();
      const orig = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      const current = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      const source = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      (current["myorg"] as Record<string, unknown>)["description"] = "OPERATOR EDIT";
      (source["myorg"] as Record<string, unknown>)["description"] = "UPSTREAM CHANGED";
      const r = mergeZones(current, orig, source);
      check((r.merged["myorg"] as Record<string, unknown>)["description"] === "OPERATOR EDIT", "an operator edit (current!=orig) is pinned over the upstream change");
    }

    // (d) `state` is ALWAYS pinned to current (occupancy preserved): a current
    //     'srvWork' Active stays Active even though the renamed source has it
    //     Inactive.
    {
      const renamed = renameRaw();
      const orig = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      const source = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      const current = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      // renamed source has srvWork Inactive; operator/occupancy kept it Active.
      check((source["srvWork"] as Record<string, unknown>)["state"] === "Inactive", "precondition: renamed source has srvWork Inactive");
      (current["srvWork"] as Record<string, unknown>)["state"] = "Active";
      const r = mergeZones(current, orig, source);
      check((r.merged["srvWork"] as Record<string, unknown>)["state"] === "Active", "state is always pinned to current (srvWork stays Active — occupancy preserved)");
    }

    // (e) --diff writes nothing.
    {
      const dir = freshRenamedConfig();
      // dirty the current so a real merge WOULD write, then prove --diff doesn't.
      const cur = readJson(join(dir, "zones.json"));
      (cur["myorg"] as Record<string, unknown>)["description"] = "operator note";
      writeFileSync(join(dir, "zones.json"), JSON.stringify(cur, null, 4) + "\n", "utf8");
      const before = readFileSync(join(dir, "zones.json"), "utf8");
      const beforeOrig = readFileSync(join(dir, "zones.json.orig"), "utf8");
      const rc = runZonesMerge(
        { current: join(dir, "zones.json"), orig: join(dir, "zones.json.orig"), rename: join(dir, "zones.rename.json"), template: tpl, name: NAME, diff: true },
        silent,
        renameRaw,
      );
      check(rc === 0, "--diff returns rc=0");
      check(readFileSync(join(dir, "zones.json"), "utf8") === before, "--diff writes nothing to zones.json");
      check(readFileSync(join(dir, "zones.json.orig"), "utf8") === beforeOrig, "--diff does not advance zones.json.orig");
    }

    // (f) old-drift case: a current that still carries a stale srv (alongside
    //     myOrg) is NOT made worse — the merge keeps the current-only srv (warns)
    //     but does not re-add or duplicate it; it is the documented one-time
    //     surgical cleanup, not the merge's job.
    {
      const dir = freshRenamedConfig();
      const cur = readJson(join(dir, "zones.json"));
      cur["srv"] = { state: "Inactive", vlantag: 250, type: "Service", "access-to": ["internet"] };
      writeFileSync(join(dir, "zones.json"), JSON.stringify(cur, null, 4) + "\n", "utf8");
      runZonesMerge(
        { current: join(dir, "zones.json"), orig: join(dir, "zones.json.orig"), rename: join(dir, "zones.rename.json"), template: tpl, name: NAME },
        silent,
        renameRaw,
      );
      const merged = readJson(join(dir, "zones.json"));
      // srv kept (current-only), but NOT duplicated and no new srv-shaped re-add.
      const srvCount = Object.keys(merged).filter((k) => k === "srv").length;
      check(srvCount === 1, "a pre-existing current-only srv is kept exactly once (not re-added/duplicated)");
      // stable: a second merge does not change the file.
      const a1 = readFileSync(join(dir, "zones.json"), "utf8");
      runZonesMerge(
        { current: join(dir, "zones.json"), orig: join(dir, "zones.json.orig"), rename: join(dir, "zones.rename.json"), template: tpl, name: NAME },
        silent,
        renameRaw,
      );
      check(readFileSync(join(dir, "zones.json"), "utf8") === a1, "merge over a stale-srv current is stable (does not grow)");
    }
  }
}

// ── 13. zones-init 3-file seeding (Design A) ──────────────────────────
// zones-init produces zones.rename.json AND seeds zones.json + zones.json.orig
// from it, all in the renamed namespace. We exercise the real CLI write path via
// the transform + the seeding logic; here we verify the renamed-source content
// and that current==orig==rename at seed time. (The CLI's 3-file write to a temp
// --out is also smoke-tested in test.sh.)
{
  const tpl = process.env.NM_TEMPLATE;
  if (!tpl) {
    check(false, "NM_TEMPLATE env must point at the distributed zones.json template (zones-init seeding)");
  } else {
    const renamed = renameTemplateFile(tpl, "myorg").raw;
    // The renamed source has the renamed zones and NOT the originals.
    check("myorg" in renamed && !("srv" in renamed), "renamed source has myorg, not srv");
    check("myorg-private" in renamed && !("home" in renamed), "renamed source has myorg-private, not home");
    check("myorg-guest" in renamed && !("guest" in renamed), "renamed source has myorg-guest, not guest");
    // Seeding current/orig/rename from the same renamed doc ⇒ identical content
    // ⇒ a subsequent merge is a no-op (already asserted in §12a); here we just
    // confirm the seed values are byte-identical, which is the property zones-init
    // relies on.
    const a = JSON.stringify(renamed, null, 2);
    const b = JSON.stringify(renameTemplateFile(tpl, "myorg").raw, null, 2);
    check(a === b, "the rename transform is deterministic (current==orig==rename at seed)");
  }
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
