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

import { opnsenseDryRunResult, proxmoxNeedsRecheck, proxmoxStatus } from "../../src/planes";
import { gatewayIpOf, resolveSplitHorizonTarget } from "../../src/splithorizon";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "fs";
import { HELP, run } from "../../src/main";
import { renderManifest, undocumentedOptions } from "../../../../lib/ts/src/help";
import { dirname, join } from "path";
import { tmpdir } from "os";
import { PLANE_ORDER } from "../../src/types";
import {
  initProfile,
  parseTemplate,
  renameTemplateFile,
  validateName,
  zonesInit,
} from "../../src/zonesinit";
import { mergeZones, runZonesMerge } from "../../src/zonesmerge";
import { collisionOf, describeHolder, ipv4Overlaps, occupancyFrom } from "../../src/occupancy";
import {
  allocateIpv6Subnet,
  allocateVlan,
  authorZone,
  changeZoneState,
  getZone,
  listZoneNames,
  loadZones,
  removeZone,
  saveZones,
  zoneExists,
  zoneReferrers,
} from "../../src/zones";
import { reconcileAll } from "../../src/reconcile";
import { addZone, deleteZone } from "../../src/zonelifecycle";
import { runChecks } from "../../src/zonescheck";
import { ARCHETYPES, TIER_EXEMPT_TYPES, archetypeNames } from "../../src/archetypes";
import { backfillServes, environmentValue, environmentZoneIn, isSharedServiceZone, renderEffective, sharedZonesOf, zoneEnvironment, zoneEnvironments } from "../../src/serves";
import {
  ZonesFieldsSchema,
  applyZoneSet,
  coerce,
  parseSetArg,
  preGateZoneSet,
  preGateZoneUnset,
} from "../../src/zonemodify";
import { RETIRED_ZONES, retireZones } from "../../src/retire";
import {
  distributeZones,
  enumerateNodes,
  nodeTarget,
  shouldAutoDistribute,
} from "../../src/distribute";
import { FakePlaneClient } from "./fake-plane-client";
import { Plane, PlaneResult } from "../../src/types";

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

// ── 1b. the `all` sentinel (#375): mgmt says it once, add/delete never edit it ──
{
  const f = tmpZones();
  let doc = loadZones(f);
  (doc.raw["mgmt"] as Record<string, unknown>)["access-to"] = ["internet", "all"];
  authorZone(doc, "srvTenant", { fromZone: "srvHome", variant: "tenant1" });
  saveZones(f, doc);
  doc = loadZones(f);
  const acc = () => ((doc.raw["mgmt"] as Record<string, unknown>)["access-to"] as string[]).join(",");
  check(acc() === "internet,all", `add leaves mgmt.access-to = [internet, all] alone (got ${acc()})`);
  removeZone(doc, "srvTenant");
  check(acc() === "internet,all", `delete leaves mgmt.access-to = [internet, all] alone (got ${acc()})`);
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

// ── 5b. zone delete drops the zone from other zones' lists first (#791) ─
{
  const f = tmpZones();
  let doc = loadZones(f);
  authorZone(doc, "srvTenant", { fromZone: "srvHome" });
  // two other zones name it: one in access-to, one in pinhole-allowed-from
  const others = listZoneNames(doc).filter((z) => z !== "srvTenant" && z !== "mgmt").slice(0, 2);
  const a = doc.raw[others[0]] as Record<string, unknown>;
  const b = doc.raw[others[1]] as Record<string, unknown>;
  a["access-to"] = [...((a["access-to"] as string[]) ?? []), "srvTenant"];
  b["pinhole-allowed-from"] = [...((b["pinhole-allowed-from"] as string[]) ?? []), "srvTenant"];
  saveZones(f, doc);
  // every zone that names it (authorZone may already have added some)
  const referrers = zoneReferrers(loadZones(f), "srvTenant").sort();
  check(others.every((o) => referrers.includes(o)), "the seeded references are in place");

  // --check names them and changes nothing
  const before = readFileSync(f, "utf8");
  const dry = deleteZone(new FakePlaneClient(), f, "srvTenant", { dryRun: true });
  check(JSON.stringify([...(dry.strippedFrom ?? [])].sort()) === JSON.stringify(referrers),
    `zone delete --check names the zones whose lists would change (${referrers.join(",")})`);
  check(readFileSync(f, "utf8") === before, "zone delete --check still mutates nothing");

  // the reconcile already sees the references gone (one run converges)
  class Peek extends FakePlaneClient {
    refsAtReconcile = -1;
    reconcile(plane: Plane, apply: boolean, zonesFile: string): PlaneResult {
      if (this.refsAtReconcile < 0) this.refsAtReconcile = zoneReferrers(loadZones(zonesFile), "srvTenant").length;
      return super.reconcile(plane, apply, zonesFile);
    }
  }
  const c = new Peek();
  const res = deleteZone(c, f, "srvTenant", { noDistribute: true });
  check(c.refsAtReconcile === 0, "references are stripped BEFORE the reconcile runs");
  check(JSON.stringify([...(res.strippedFrom ?? [])].sort()) === JSON.stringify(referrers),
    "zone delete reports every zone it stripped");
  doc = loadZones(f);
  check(zoneReferrers(doc, "srvTenant").length === 0, "no zone names the deleted zone afterwards");
  check(!((doc.raw[others[0]] as Record<string, unknown>)["access-to"] as string[]).includes("srvTenant"),
    "access-to of the referring zone no longer lists it");
  check(!((doc.raw[others[1]] as Record<string, unknown>)["pinhole-allowed-from"] as string[]).includes("srvTenant"),
    "pinhole-allowed-from of the referring zone no longer lists it");
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

// ── 8. the rename transform (offline; against the REAL distributed template) ─
// NM_TEMPLATE points at the canonical manager/network-manager/zones.json.
// `zonesInit` now renders the WHOLE template into the renamed namespace — this
// is the MERGE SOURCE, not what a fresh install writes (that is `initProfile`,
// section 21). The D7 template no longer ships srv{Home,…}/work/iot/test*, so
// the old "force these Inactive" assertions are gone with them.
{
  const tplPath = process.env.NM_TEMPLATE;
  if (!tplPath) {
    check(false, "NM_TEMPLATE env must point at the distributed zones.json template");
  } else {
    const template = parseTemplate(tplPath);
    const { raw, alreadyInitialised } = zonesInit(template, "acme", false);

    check(!alreadyInitialised, "transforming the distributed template is not a no-op");

    // renames — only srv is renamed; home/guest are site-local role zones (#425)
    check("acme" in raw && !("srv" in raw), "srv renamed to <N> (acme); srv key gone");
    check("home" in raw && !("acme-private" in raw), "home kept (site-local role zone; not renamed)");
    check("guest" in raw && !("acme-guest" in raw), "guest kept (site-local role zone; not renamed)");

    // <N> carried srv's config + state Active
    const acme = raw["acme"] as Record<string, unknown>;
    check(acme["type"] === "Service" && acme["vlantag"] === 200, "<N> carried srv's config (type/vlan)");
    check(acme["state"] === "Active", "<N> state forced Active");
    check(acme["tier"] === 1, "<N> carries the service tier (ADR-014)");

    // D7: the retired zones are GONE from the shipped template.
    for (const z of ["srvHome", "srvWork", "srvCust", "srvDev", "srvTest", "work",
                     "iot", "test", "testAllowA", "testAllowB", "testPinhole"]) {
      check(!(z in raw), `D7: '${z}' is no longer shipped in the template`);
    }

    // guest is left fully untouched: its client DNS domain (guest.internal) and
    // isolation must survive the transform (#425).
    check(
      JSON.stringify(raw["guest"]) === JSON.stringify(template["guest"]),
      "guest zone is byte-identical to the template (untouched)",
    );

    // `environment` is a PLACEHOLDER in the template and must follow the rename:
    // the default environment shares its name with the default service zone
    // (ADR-007d/#426), so `environment: "srv"` becomes `environment: "<N>"`. This
    // is how the service zone comes out of init as the default environment's
    // zone, and a shipped client/IoT zone already bound — no literal
    // service-zone reference left to go stale (#424).
    check((raw["acme"] as Record<string, unknown>)["environment"] === "acme",
      "the renamed service zone names the default environment (srv → <N>)");
    check((raw["mgmt"] as Record<string, unknown>)["environment"] === "mgmt",
      "the mgmt zone names the mgmt environment");
    check((raw["home"] as Record<string, unknown>)["environment"] === "acme",
      "home.environment follows the rename: srv → <N> (the default environment)");
    check((raw["iotCams"] as Record<string, unknown>)["environment"] === "acme",
      "iotCams.environment follows the rename too");

    // referential integrity: NO zone still references the bare srv key.
    let refOk = true;
    for (const [k, v] of Object.entries(raw)) {
      if (k.startsWith("_")) continue;
      const zone = v as Record<string, unknown>;
      for (const field of ["access-to", "pinhole-allowed-from"]) {
        const arr = zone[field];
        if (Array.isArray(arr) && arr.includes("srv")) refOk = false;
      }
    }
    check(refOk, "no zone references bare srv after transform (srv renamed; home/guest kept)");

    const mgmtAccess = (raw["mgmt"] as Record<string, unknown>)["access-to"] as string[];
    // The template's mgmt says `all` (#375), so the srv rename has nothing to
    // rewrite there and the new service zone is covered without being named.
    check(
      JSON.stringify(mgmtAccess) === JSON.stringify(["internet", "all"]),
      `mgmt.access-to stays [internet, all] through the srv→<N> rename (got ${JSON.stringify(mgmtAccess)})`,
    );

    // idempotency: re-running on the transformed doc (srv absent, acme present) is a no-op
    const second = zonesInit(raw, "acme", false);
    check(second.alreadyInitialised, "second zones-init run on transformed doc is a no-op");

    // --force on an already-transformed doc errors (the srv key is gone).
    let forceThrew = false;
    try {
      zonesInit(raw, "acme", true);
    } catch {
      forceThrew = true;
    }
    check(forceThrew, "--force on an already-transformed doc errors (template keys gone)");

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

  // edge fixture: a template with no `srv` cannot be renamed.
  const d = mkdtempSync(join(tmpdir(), "nm-init-"));
  const edge = join(d, "edge.json");
  writeFileSync(edge, JSON.stringify({ home: { state: "Active" } }), "utf8");
  let edgeThrew = false;
  try {
    zonesInit(parseTemplate(edge), "acme", false);
  } catch {
    edgeThrew = true;
  }
  check(edgeThrew, "a template with no 'srv' key is rejected with a clear error");

  // D7: a profile naming a zone the template does not define is a broken
  // template — it must fail loudly, not silently install half a profile.
  const broken = join(d, "broken.json");
  writeFileSync(broken, JSON.stringify({
    _profiles: { core: { zones: ["srv", "home", "nosuch"] } },
    srv: { state: "Inactive" },
    home: { state: "Active" },
  }), "utf8");
  let brokenThrew = "";
  try {
    initProfile(parseTemplate(broken), {}, "acme", "core");
  } catch (e) {
    brokenThrew = (e as Error).message;
  }
  check(brokenThrew.includes("nosuch"), "a profile naming an undefined zone is rejected, naming it");
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

  // (a2) #257: mdns on two VLAN zones is fine; on mgmt or a non-boolean it is refused.
  {
    const raw = goodRaw();
    (raw.srvHome as Record<string, unknown>).mdns = true;
    (raw.dmz as Record<string, unknown>).mdns = true;
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors === 0, `mdns on two zones: 0 errors (got ${r.errors})`);
    check(r.lines.some((l) => l.includes("srvHome, dmz share mDNS") || l.includes("dmz, srvHome share mDNS")),
      "mdns: the group is reported");
  }
  {
    const raw = goodRaw();
    (raw.mgmt as Record<string, unknown>).mdns = true;
    (raw.srvHome as Record<string, unknown>).mdns = "yes";
    const { zonesFile, configDir } = writeDoc(raw);
    const r = runChecks(loadZones(zonesFile), configDir, false);
    check(r.errors === 2, `mdns on mgmt and a non-boolean mdns: 2 errors (got ${r.errors})`);
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

  // (a) enumerateNodes parses tappaas-nodes[].hostname from configuration.json
  //     (the legacy fallback path — no site.json in this fixture).
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

  // (a2) the node records are canonical: the pvehost instances win over the legacy file.
  const siteCfg = mkdtempSync(join(tmpdir(), "nm-cfg-site-"));
  writeFileSync(join(siteCfg, "site.json"), JSON.stringify({ name: "s" }), "utf8");
  for (const n of ["beta", "alpha"]) {
    writeFileSync(join(siteCfg, `${n}.json`), JSON.stringify({ kind: "machine", moduleSource: "/x/pvehost", address: `${n}.mgmt.internal` }), "utf8");
  }
  writeFileSync(join(siteCfg, "nas.json"), JSON.stringify({ kind: "machine", moduleSource: "/x/debianhost", address: "10.0.0.90" }), "utf8");
  writeFileSync(
    join(siteCfg, "configuration.json"),
    JSON.stringify({ "tappaas-nodes": [{ hostname: "legacy1" }] }),
    "utf8",
  );
  check(
    enumerateNodes(siteCfg).join(",") === "alpha,beta",
    `enumerateNodes prefers the pvehost instances (got ${enumerateNodes(siteCfg).join(",")})`,
  );

  // (a3) an empty canonical node list falls through to the legacy file, so a
  //      not-yet-migrated system keeps distributing.
  const siteEmpty = mkdtempSync(join(tmpdir(), "nm-cfg-site-empty-"));
  writeFileSync(join(siteEmpty, "site.json"), JSON.stringify({ name: "s" }), "utf8");
  writeFileSync(
    join(siteEmpty, "configuration.json"),
    JSON.stringify({ "tappaas-nodes": [{ hostname: "legacy1" }] }),
    "utf8",
  );
  check(
    enumerateNodes(siteEmpty).join(",") === "legacy1",
    "enumerateNodes falls back to configuration.json when no node is registered",
  );

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
// a merge must NOT re-introduce srv (home/guest are kept and converge in place),
// and must be stable. Then we
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

    // (a) THE CORE BUG: a merge on a fresh renamed install does NOT re-add srv
    //     (home/guest are kept in both source and current → converge, not
    //     re-added) and introduces no duplicate vlantags.
    {
      const dir = freshRenamedConfig();
      const rc = runZonesMerge(
        { current: join(dir, "zones.json"), orig: join(dir, "zones.json.orig"), rename: join(dir, "zones.rename.json"), template: tpl, name: NAME },
        silent,
        renameRaw,
      );
      const merged = readJson(join(dir, "zones.json"));
      check(rc === 0, "zones-merge on a fresh renamed install returns rc=0");
      check(!("srv" in merged), "merge does NOT re-add srv (renamed away — the core bug)");
      check("myorg" in merged && "home" in merged && "guest" in merged, "renamed default zone + kept home/guest present after merge");
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

    // (d) `state` is ALWAYS pinned to current (occupancy preserved): an operator
    //     who disabled a shipped zone keeps it disabled across a release that
    //     ships it Active. (Was expressed with srvWork, retired by D7.)
    {
      const renamed = renameRaw();
      const orig = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      const source = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      const current = JSON.parse(JSON.stringify(renamed)) as Record<string, unknown>;
      check((source["guest"] as Record<string, unknown>)["state"] === "Active", "precondition: the renamed source ships guest Active");
      (current["guest"] as Record<string, unknown>)["state"] = "Inactive";
      const r = mergeZones(current, orig, source);
      check((r.merged["guest"] as Record<string, unknown>)["state"] === "Inactive", "state is always pinned to current (an operator-disabled zone stays disabled)");
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
    check("home" in renamed && !("myorg-private" in renamed), "renamed source keeps home (site-local role zone)");
    check("guest" in renamed && !("myorg-guest" in renamed), "renamed source keeps guest (site-local role zone)");
    // Seeding current/orig/rename from the same renamed doc ⇒ identical content
    // ⇒ a subsequent merge is a no-op (already asserted in §12a); here we just
    // confirm the seed values are byte-identical, which is the property zones-init
    // relies on.
    const a = JSON.stringify(renamed, null, 2);
    const b = JSON.stringify(renameTemplateFile(tpl, "myorg").raw, null, 2);
    check(a === b, "the rename transform is deterministic (current==orig==rename at seed)");
  }
}

// ── 14. zone state verbs (enable/disable/manual — port of zone-state.sh) ─
// The guarded transition contract: verb→state mapping, no-op on same state,
// unknown zone/verb rejected, and the Mandatory guard (+ --force override).
{
  function threw(fn: () => void): boolean {
    try {
      fn();
      return false;
    } catch {
      return true;
    }
  }

  const f = tmpZones();

  // enable / disable / manual map to Active / Inactive / Manual and persist.
  {
    let doc = loadZones(f);
    const r = changeZoneState(doc, "srvHome", "disable");
    check(r.changed && r.from === "Active" && r.to === "Inactive", "disable: Active → Inactive");
    saveZones(f, doc);
    doc = loadZones(f);
    check(getZone(doc, "srvHome")?.state === "Inactive", "state change persists across reload");

    const r2 = changeZoneState(doc, "srvHome", "enable");
    check(r2.changed && r2.to === "Active", "enable: Inactive → Active");
    const r3 = changeZoneState(doc, "srvHome", "manual");
    check(r3.changed && r3.to === "Manual", "manual: Active → Manual");
    saveZones(f, doc);
  }

  // no-op when already in the target state (changed=false, disk untouched).
  {
    const doc = loadZones(f);
    const before = readFileSync(f, "utf8");
    const r = changeZoneState(doc, "srvHome", "manual");
    check(!r.changed && r.from === "Manual" && r.to === "Manual", "same-state verb is a no-op (changed=false)");
    check(readFileSync(f, "utf8") === before, "no-op state change leaves zones.json untouched");
  }

  // unknown zone / unknown verb / missing state field are rejected.
  {
    const doc = loadZones(f);
    check(threw(() => changeZoneState(doc, "nope", "enable")), "unknown zone is rejected");
    check(threw(() => changeZoneState(doc, "srvHome", "toggle")), "unknown state verb is rejected");
    const noState = loadZones(f);
    delete (noState.raw["srvHome"] as Record<string, unknown>)["state"];
    delete noState.zones.get("srvHome")!.state;
    check(threw(() => changeZoneState(noState, "srvHome", "enable")), "zone without a 'state' field is rejected");
  }

  // Mandatory guard: refused without force, state preserved; --force allows.
  {
    let doc = loadZones(f);
    check(threw(() => changeZoneState(doc, "dmz", "disable")), "leaving Mandatory without --force is refused");
    check(getZone(doc, "dmz")?.state === "Mandatory", "refused Mandatory change leaves the state untouched");
    const r = changeZoneState(doc, "dmz", "disable", true);
    check(r.changed && r.from === "Mandatory" && r.to === "Inactive", "--force allows leaving Mandatory");
    saveZones(f, doc);
    doc = loadZones(f);
    check(getZone(doc, "dmz")?.state === "Inactive", "forced Mandatory change persists");
  }
}

// ── 15. init preserves existing configured zones (#427, now via initProfile) ─
// `initProfile` subsumes the retired mergeInitWithExisting: it carries the
// EXISTING live document forward (with the srv → <N> rename applied to keys AND
// references) and contributes only zones that are not already present. An init
// re-run therefore never rebuilds a live file from template defaults.
{
  const tpl = process.env.NM_TEMPLATE;
  if (!tpl) {
    check(false, "NM_TEMPLATE env must point at the distributed template (init-preserve tests)");
  } else {
    const template = parseTemplate(tpl);

    // A live doc: a not-yet-renamed 'srv' (operator set Active + custom access),
    // a custom zone absent from the template, an in-use client 'home' whose
    // access-to still points at the retired srvHome, and 'work' left Active.
    const existing: Record<string, unknown> = {
      _README: "keep me",
      srv: { type: "Service", state: "Active", vlantag: 200, "access-to": ["internet", "dmz"] },
      lab: { type: "Service", state: "Active", vlantag: 250, "access-to": ["internet"] },
      home: { type: "Client", state: "Active", vlantag: 310, "access-to": ["internet", "srvHome"] },
      work: { type: "Client", state: "Active", vlantag: 320, "access-to": ["srv"] },
    };

    const m = initProfile(template, existing, "acme", "core");

    // srv carried over to <N>, keeping the operator's Active state + config.
    check("acme" in m.raw && !("srv" in m.raw), "existing srv renamed to <N> (carried over)");
    check((m.raw["acme"] as Record<string, unknown>).state === "Active", "renamed <N> keeps the operator's Active state (not template default)");
    check(m.renamedFromSrv, "renamedFromSrv reported for the carried-over srv");

    // custom zone absent from the template is NOT dropped.
    check("lab" in m.raw, "custom zone 'lab' (absent from template) is preserved, not dropped");

    // 'work' is no longer shipped, but an existing one is NEVER removed by init —
    // it is a legitimate client zone that is merely switched off elsewhere.
    check("work" in m.raw && (m.raw["work"] as Record<string, unknown>).state === "Active",
      "a zone the template dropped is PRESERVED by init (removal is `retire`'s job)");

    // home's reference to the retired srvHome is NOT redirected (kept verbatim);
    // its 'srv' ref is renamed to <N> like every other reference.
    const homeAccess = (m.raw["home"] as Record<string, unknown>)["access-to"] as string[];
    check(homeAccess.includes("srvHome"), "existing home keeps its srvHome reference (not redirected)");
    check(((m.raw["work"] as Record<string, unknown>)["access-to"] as string[]).includes("acme"),
      "existing refs are srv→<N> renamed (work.access-to now lists <N>)");

    // preserved lists the existing zones; a template-only zone is ADDED.
    check(m.preserved.includes("acme") && m.preserved.includes("lab") && m.preserved.includes("home"), "preserved lists the discovered existing zones");
    check(m.added.includes("guest") && m.added.includes("dmz"), "core-profile zones absent from the live doc are added");
    check(!m.added.includes("lab"), "added vs preserved are disjoint by origin");

    // an existing zone is never re-stamped from the template without --force.
    check((m.raw["home"] as Record<string, unknown>)["environment"] === undefined,
      "an existing zone is NOT re-stamped from the template (no environment injected)");

    // doc block survives; install-time metadata does not leak into the live file.
    check(m.raw["_README"] === "keep me", "_README doc block preserved through init");
    check(!("_profiles" in m.raw), "_profiles is install-time metadata and is NOT written to the live doc");
  }
}

// ── 15b. ADR-014 D7: composable, additive, idempotent profiles ────────
{
  const tpl = process.env.NM_TEMPLATE;
  if (!tpl) {
    check(false, "NM_TEMPLATE env must point at the distributed template (profile tests)");
  } else {
    const template = parseTemplate(tpl);
    const zonesOf = (r: Record<string, unknown>) =>
      Object.keys(r).filter((k) => !k.startsWith("_")).sort();

    // core on a FRESH install: exactly the core set, renamed.
    const core = initProfile(template, {}, "acme", "core");
    check(
      zonesOf(core.raw).join(",") === ["mgmt", "wan", "netbird", "edge", "admin", "buddy", "acme", "home", "guest", "dmz"].sort().join(","),
      `init core emits exactly the core set (got ${zonesOf(core.raw).join(",")})`,
    );
    check(!zonesOf(core.raw).some((z) => z.startsWith("iot")), "init core ships NO IoT zones (opt-in)");
    check(!zonesOf(core.raw).some((z) => z.startsWith("test")), "init core ships NO test zones");

    // a core-only doc must be referentially clean — no dangling IoT references.
    {
      const doc = { raw: core.raw, zones: new Map(Object.entries(core.raw).filter(([k, v]) => !k.startsWith("_") && !!v).map(([k, v]) => [k, { ...(v as object), name: k }])) };
      let dangling: string[] = [];
      for (const [k, v] of Object.entries(core.raw)) {
        if (k.startsWith("_")) continue;
        for (const f of ["access-to", "pinhole-allowed-from"]) {
          const arr = (v as Record<string, unknown>)[f];
          if (!Array.isArray(arr)) continue;
          for (const r of arr) {
            if (typeof r === "string" && r !== "internet" && r !== "all" && !(r in core.raw)) dangling.push(`${k}.${f}→${r}`);
          }
        }
      }
      check(dangling.length === 0, `init core has no dangling references (${dangling.join(", ") || "clean"})`);
      void doc;
    }

    // iot composes ON TOP, adding its zones and the reach they need.
    const both = initProfile(template, core.raw, "acme", "iot");
    check(
      ["iotLocal", "iotCloud", "iotCams", "iotUntrust"].every((z) => z in both.raw),
      "init iot adds the four IoT zones on top of core",
    );
    check(
      ["mgmt", "acme", "home", "guest", "dmz"].every((z) => z in both.raw),
      "init iot leaves the core zones in place",
    );
    const acmeAccess = (both.raw["acme"] as Record<string, unknown>)["access-to"] as string[];
    check(acmeAccess.includes("iotLocal") && acmeAccess.includes("iotCloud"),
      "init iot grants the service zone reach to the controlled IoT zones");
    const mgmtAccess2 = (both.raw["mgmt"] as Record<string, unknown>)["access-to"] as string[];
    check(["iotLocal", "iotCloud", "iotCams", "iotUntrust"].every((z) => mgmtAccess2.includes(z)),
      "init iot grants the control plane visibility of the IoT zones");
    check((both.raw["iotUntrust"] as Record<string, unknown>)["state"] === "Active",
      "D7: iotUntrust ships Active with the profile (isolated anyway)");

    // ORDER-INDEPENDENT: iot then core == core then iot.
    const iotFirst = initProfile(template, {}, "acme", "iot");
    const thenCore = initProfile(template, iotFirst.raw, "acme", "core");
    check(zonesOf(thenCore.raw).join(",") === zonesOf(both.raw).join(","),
      "profiles are order-independent (iot→core == core→iot)");

    // IDEMPOTENT: re-applying adds nothing and changes nothing.
    const again = initProfile(template, both.raw, "acme", "iot");
    check(again.added.length === 0, "re-applying a profile adds no zone (idempotent)");
    check(JSON.stringify(again.raw) === JSON.stringify(both.raw), "re-applying a profile is a byte-level no-op");

    // grants never author a dangling reference: applying `iot` when a granted
    // target is absent must skip it rather than point at nothing.
    const noHome = { ...core.raw };
    delete (noHome as Record<string, unknown>)["home"];
    const g = initProfile(template, noHome, "acme", "iot");
    check(!("home" in g.raw), "a zone the operator deleted is not resurrected by a grant");

    // an unknown profile is refused, with the known set named.
    let threwUnknown = false;
    try { initProfile(template, {}, "acme", "nope"); } catch (e) { threwUnknown = (e as Error).message.includes("core"); }
    check(threwUnknown, "an unknown profile is rejected and names the known ones");
  }
}

// ── 16. ADR-014 P1: tier / isolated / environment are carried, not mangled
// P1 is a PURE schema addition: nothing reads the three new fields yet, so the
// only thing to prove is that they survive every existing code path untouched —
// load→save round-trip, the 3-way merge, and the rename transform — and that
// `environment` is operator-pinned like `state`.
{
  const d = mkdtempSync(join(tmpdir(), "nm-adr014-"));

  // A zone doc carrying all three new fields, on the zone kinds that use them.
  const authored = {
    _README: "doc block",
    mgmt: {
      type: "Management", state: "Manual", typeId: "0", subId: "0", vlantag: 0,
      ip: "10.0.0.0/24", bridge: "lan", tier: 0,
      "access-to": ["internet", "acme", "home", "iotCams", "dmz"], "pinhole-allowed-from": [],
    },
    acme: {
      type: "Service", state: "Active", typeId: "2", subId: "0", vlantag: 200,
      ip: "10.2.0.0/24", bridge: "lan", tier: 1, environment: "acme",
      "access-to": ["internet", "dmz"], "pinhole-allowed-from": ["dmz"],
    },
    home: {
      type: "Client", state: "Active", typeId: "3", subId: "10", vlantag: 310,
      ip: "10.3.10.0/24", bridge: "lan", tier: 2, environment: "acme",
      "access-to": ["internet"], "pinhole-allowed-from": [],
    },
    iotCams: {
      type: "IoT", state: "Active", typeId: "4", subId: "30", vlantag: 430,
      ip: "10.4.30.0/24", bridge: "lan", tier: 6, isolated: true, environment: "acme",
      "access-to": [], "pinhole-allowed-from": [],
    },
    dmz: {
      type: "DMZ", state: "Mandatory", typeId: "6", subId: "10", vlantag: 610,
      ip: "10.6.0.0/24", bridge: "lan", tier: 4,
      "access-to": ["internet"], "pinhole-allowed-from": ["internet"],
    },
  };

  // (a) load → save round-trips the new fields losslessly.
  const f = join(d, "zones.json");
  writeFileSync(f, JSON.stringify(authored, null, 4) + "\n", "utf8");
  const doc = loadZones(f);
  const home = getZone(doc, "home");
  const cams = getZone(doc, "iotCams");
  check(home?.tier === 2 && home?.environment === "acme", "P1: loadZones surfaces tier + environment on a Client zone");
  check(cams?.tier === 6 && cams?.isolated === true && cams?.environment === "acme", "P1: loadZones surfaces tier + isolated + environment on an IoT zone");
  check(getZone(doc, "acme")?.isolated === undefined, "P1: absent `isolated` stays absent (not defaulted on load)");

  const g = join(d, "roundtrip.json");
  saveZones(g, doc);
  check(
    JSON.stringify(JSON.parse(readFileSync(g, "utf8"))) === JSON.stringify(authored),
    "P1: load→save round-trips a tier/isolated/environment doc byte-for-byte (by value)",
  );

  // (b) the new fields do not disturb the existing checks — a conforming doc
  //     still passes zones-check with no errors (P1 adds no new gate).
  //     The doc names environment "acme", so it must exist: an unresolvable
  //     link is an ERROR by design (P3 checkServes).
  mkdirSync(join(d, "environments"), { recursive: true });
  writeFileSync(join(d, "environments", "acme.json"),
    JSON.stringify({ name: "acme" }), "utf8");
  const res = runChecks(loadZones(f), d, false);
  check(res.errors === 0, "P1: zones-check still reports 0 errors on an ADR-014-annotated doc");

  // (c) 3-way merge: `environment` is operator-pinned; `tier` is adoptable.
  //     current has the operator's binding + an old tier; source (a later
  //     release) drops the link and corrects the tier; baseline == source for
  //     tier so the correction is adoptable, while the link must survive.
  const current = { home: { state: "Active", tier: 9, environment: "acme", "access-to": ["internet"] } };
  const baseline = { home: { state: "Active", tier: 9, "access-to": ["internet"] } };
  const source = { home: { state: "Inactive", tier: 2, "access-to": ["internet"] } };
  const m = mergeZones(current, baseline, source);
  const merged = m.merged["home"] as Record<string, unknown>;
  check(merged["environment"] === "acme", "P1: merge PINS `environment` — a release without it cannot clear the operator's binding");
  check(merged["state"] === "Active", "P1: merge still pins `state` (unchanged #209 behaviour)");
  check(merged["tier"] === 2, "P1: merge ADOPTS a corrected `tier` when the operator has not edited it");

  // and an operator-edited tier is pinned like any other field.
  const m2 = mergeZones(
    { home: { state: "Active", tier: 5 } },
    { home: { state: "Active", tier: 9 } },
    { home: { state: "Active", tier: 2 } },
  );
  check((m2.merged["home"] as Record<string, unknown>)["tier"] === 5, "P1: an operator-edited `tier` is pinned over the release value");

  // (c2) a release zone the operator renamed (same VLAN) or removed is not
  //      added back: two zones on one VLAN tag break the network.
  {
    const cur = { private: { state: "Active", vlantag: 310 }, kids: { state: "Active", vlantag: 520 } };
    const src = { home: { state: "Active", vlantag: 310 }, guest: { state: "Active", vlantag: 510 }, lab: { state: "Active", vlantag: 610 } };
    const base = { home: { state: "Active", vlantag: 310 }, guest: { state: "Active", vlantag: 510 } };
    const r1 = mergeZones(cur, base, src);
    check(!("home" in r1.merged) && r1.notAdded.some((n) => n.zone === "home" && /private/.test(n.reason)),
      "#832: a release zone on a VLAN a current zone holds is not added (reported as a rename)");
    check(!("guest" in r1.merged) && r1.notAdded.some((n) => n.zone === "guest" && /removed/.test(n.reason)),
      "#832: a zone the operator removed since the last merge is not added back");
    check("lab" in r1.merged && r1.added.includes("lab"), "#832: a zone the release really adds still comes in");
    const r2 = mergeZones(cur, src, src, true);
    check(!("home" in r2.merged) && "guest" in r2.merged,
      "#832: with a backfilled baseline only the VLAN clash holds a zone back");
  }

  // (d) the rename transform carries the new fields through untouched.
  const tpl = {
    srv: { type: "Service", state: "Inactive", typeId: "2", vlantag: 200, tier: 1, "access-to": ["internet"], "pinhole-allowed-from": [] },
    home: { type: "Client", state: "Active", typeId: "3", vlantag: 310, tier: 2, environment: "srv", "access-to": ["internet", "srv"], "pinhole-allowed-from": [] },
    guest: { type: "Guest", state: "Active", typeId: "5", vlantag: 510, tier: 3, "access-to": ["internet"], "pinhole-allowed-from": [] },
  };
  const r = zonesInit(tpl, "acme", false);
  const rHome = r.raw["home"] as Record<string, unknown>;
  check((r.raw["acme"] as Record<string, unknown>)["tier"] === 1, "P1: rename carries `tier` onto the renamed default zone");
  check(rHome["tier"] === 2, "P1: rename leaves an untouched zone's `tier` alone");
  check((rHome["access-to"] as string[]).includes("acme"), "P1: rename still rewrites zone-name refs in access-to");
}

// ── 17. ADR-014 P2: the archetype catalog matches the shipped schema ──
// archetypes.ts is the OPERATIVE copy (the nix build cannot see foundation/
// schemas/), so this test pins it to the documented one. If they ever diverge,
// this fails rather than shipping two disagreeing definitions of the model.
{
  // fixtures -> test -> network-manager -> manager -> tappaas-cicd -> foundation
  const schemaPath = join(
    FIXTURE_DIR, "..", "..", "..", "..", "..", "schemas", "zones-fields.json",
  );
  if (!existsSync(schemaPath)) {
    check(false, `P2: zones-fields.json reachable for the drift check (looked in ${schemaPath})`);
  } else {
    const schema = JSON.parse(readFileSync(schemaPath, "utf8")) as Record<string, any>;
    const cat = schema["archetypes"]["catalog"] as Record<string, any>;

    check(
      Object.keys(cat).sort().join(",") === archetypeNames().sort().join(","),
      "P2: archetype NAMES match schemas/zones-fields.json",
    );
    const mismatched = ARCHETYPES.filter((a) => {
      const c = cat[a.name];
      return !c || c.type !== a.type || c.typeId !== a.typeId || c.tier !== a.tier ||
        c.isolated !== a.isolated ||
        JSON.stringify(c["access-to"]) !== JSON.stringify(a.accessTo);
    }).map((a) => a.name);
    check(mismatched.length === 0, `P2: every archetype's type/typeId/tier/isolated/access-to matches the schema${mismatched.length ? ` (drift: ${mismatched.join(", ")})` : ""}`);
    check(
      JSON.stringify((schema["tier_exempt_types"]["types"] as string[]).slice().sort()) ===
        JSON.stringify(Array.from(TIER_EXEMPT_TYPES).sort()),
      "P2: tier_exempt_types matches the schema",
    );
  }
}

// ── 18. ADR-014 P2: the tier invariants I1-I4 ─────────────────────────
{
  const d = mkdtempSync(join(tmpdir(), "nm-p2-"));
  // Write a doc and run ONLY the check pass over it (no config dir → the
  // installation check is a note, not an error).
  const run = (zones: Record<string, unknown>, strict = false) => {
    const f = join(d, `z-${Math.random().toString(36).slice(2)}.json`);
    writeFileSync(f, JSON.stringify(zones, null, 2), "utf8");
    return runChecks(loadZones(f), join(d, "no-such-config"), strict);
  };
  const hits = (r: { lines: string[] }, id: string) => r.lines.filter((l) => l.includes(`${id}:`) && !l.includes("✓")).length;

  const mgmt = {
    type: "Management", state: "Manual", typeId: "0", subId: "0", vlantag: 0,
    ip: "10.0.0.0/24", tier: 0, "access-to": ["internet"], "pinhole-allowed-from": [],
  };
  const svc = {
    type: "Service", state: "Active", typeId: "2", subId: "0", vlantag: 200,
    ip: "10.2.0.0/24", tier: 1, "access-to": ["internet"], "pinhole-allowed-from": [],
  };

  // (a) a conforming doc trips nothing.
  {
    const r = run({
      mgmt, acme: svc,
      home: { type: "Client", state: "Active", typeId: "3", subId: "10", vlantag: 310, ip: "10.3.10.0/24", tier: 2, "access-to": ["internet"], "pinhole-allowed-from": [] },
      iotCams: { type: "IoT", state: "Active", typeId: "4", subId: "30", vlantag: 430, ip: "10.4.30.0/24", tier: 6, isolated: true, "access-to": [], "pinhole-allowed-from": ["acme"] },
    });
    check(r.warnings === 0 && r.errors === 0, "P2: a conforming ADR-014 doc trips no invariant");
  }

  // (b) I1 — an upward edge (client tier 2 → service tier 1) warns, not errors.
  {
    const z = {
      mgmt, acme: svc,
      home: { type: "Client", state: "Active", typeId: "3", subId: "10", vlantag: 310, ip: "10.3.10.0/24", tier: 2, "access-to": ["internet", "acme"], "pinhole-allowed-from": [] },
    };
    const r = run(z);
    check(hits(r, "I1") === 1, "P2 I1: an upward access-to edge is flagged");
    check(r.errors === 0 && r.warnings > 0, "P2 I1: it is a WARNING, not an error (R3 — warn-only by default)");
    const rs = run(z, true);
    check(rs.errors > 0, "P2 I1: --strict promotes it to an error");
  }

  // (b2) #620 — an untiered zone's edges are counted as NOT checked, never as
  //      clean: a lattice authored on a third of the zones must say so.
  {
    const r = run({
      mgmt, acme: svc,
      work: { type: "Client", state: "Active", typeId: "3", subId: "20", vlantag: 320, ip: "10.3.20.0/24", "access-to": ["internet", "acme"], "pinhole-allowed-from": [] },
    });
    const note = r.lines.find((l) => l.includes("not checked by I1")) ?? "";
    check(note.includes("2 access-to edge(s)") && note.includes("work→acme") && note.includes("work→internet"),
      "#620: edges with no tier at one end are named as not checked");
    check(r.lines.some((l) => l.includes("I1:") && l.includes("1 checked, 2 not checked")),
      "#620: the I1 verdict states its coverage");
    check(hits(r, "I1") === 0, "#620: the coverage note is not itself an I1 finding");
  }

  // (c) I1 — mgmt is exempt: it reaches everything by design.
  {
    const r = run({
      mgmt: { ...mgmt, "access-to": ["internet", "acme", "iotCams"] },
      acme: svc,
      iotCams: { type: "IoT", state: "Active", typeId: "4", subId: "30", vlantag: 430, ip: "10.4.30.0/24", tier: 6, isolated: true, "access-to": [], "pinhole-allowed-from": [] },
    });
    check(hits(r, "I1") === 0 && hits(r, "I2") === 0, "P2 I1/I2: the mgmt control plane is exempt from both");
  }

  // (d) I1/I3/I4 — Overlay and WAN are skipped entirely (R2). `admin` carries
  //     access-to:["mgmt"], an upward edge into tier 0, and must NOT be flagged.
  {
    const r = run({
      mgmt, acme: svc,
      admin: { type: "Overlay", state: "Manual", typeId: "7", subId: "2", vlantag: 0, ip: "10.255.1.0/24", "access-to": ["mgmt"], "pinhole-allowed-from": [] },
      wan: { type: "WAN", state: "Manual", typeId: "1", subId: "0", vlantag: 100, ip: "10.1.0.0/24", "access-to": [], "pinhole-allowed-from": [] },
    });
    check(hits(r, "I1") === 0, "P2 R2: an Overlay's upward access-to ['mgmt'] is NOT flagged by I1");
    check(hits(r, "I4") === 0, "P2 R2: Overlay/WAN are skipped by archetype conformance");
    check(r.lines.some((l) => l.includes("tier:") && l.includes("skipped")) === false ||
      !r.lines.some((l) => l.includes("admin")), "P2 R2: exempt zones are not listed as untiered");
  }

  // (d2) I5 — a zone-wide DMZ edge (ADR-021 D3b / #618). The edge compiles to
  //      the whole DMZ subnet on every port, and the DMZ gateway is the firewall
  //      itself, so it hands out the admin GUI (8443) and SSH (22).
  {
    const dmz = { type: "DMZ", state: "Mandatory", typeId: "6", subId: "0", vlantag: 610, ip: "10.6.0.0/24", tier: 4, "access-to": ["internet"], "pinhole-allowed-from": ["internet"] };
    const r = run({ mgmt, dmz, acme: { ...svc, "access-to": ["internet", "dmz"] } });
    check(hits(r, "I5") === 1, "P2 I5: a zone with 'dmz' in access-to is flagged (#618)");
    const rs = run({ mgmt, dmz, acme: { ...svc, "access-to": ["internet", "dmz"] } }, true);
    check(rs.errors > 0, "P2 I5: --strict promotes it to an error");
    // …and the clean case stays clean.
    const ok = run({ mgmt, dmz, acme: svc });
    check(hits(ok, "I5") === 0, "P2 I5: a service zone without 'dmz' passes");
    // mgmt keeps its full visibility list.
    const m = run({ mgmt: { ...mgmt, "access-to": ["internet", "dmz", "acme"] }, dmz, acme: svc });
    check(hits(m, "I5") === 0, "P2 I5: the mgmt control plane is exempt");
  }

  // (e) I2 — an isolated zone in someone's access-to.
  {
    const r = run({
      mgmt, acme: { ...svc, "access-to": ["internet", "iotCams"] },
      iotCams: { type: "IoT", state: "Active", typeId: "4", subId: "30", vlantag: 430, ip: "10.4.30.0/24", tier: 6, isolated: true, "access-to": [], "pinhole-allowed-from": [] },
    });
    check(hits(r, "I2") === 1, "P2 I2: an isolated zone appearing in a non-mgmt access-to is flagged");
  }

  // (f) I3 — a tier-6 zone claiming internet egress. It is also an I4 miss
  //     (IoT/6/false with internet is still the iot-local triple, so I4 passes).
  {
    const r = run({
      mgmt, acme: svc,
      iotLocal: { type: "IoT", state: "Active", typeId: "4", subId: "10", vlantag: 410, ip: "10.4.10.0/24", tier: 6, "access-to": ["internet"], "pinhole-allowed-from": [] },
    });
    check(hits(r, "I3") === 1, "P2 I3: a tier-6 zone listing internet is flagged");
  }

  // (g) I4 — a Service zone mis-tiered as 3 matches no archetype.
  {
    const r = run({ mgmt, acme: { ...svc, tier: 3 } });
    check(hits(r, "I4") === 1, "P2 I4: a Service zone at tier 3 matches no archetype");
  }

  // (h) an untiered doc (every pre-ADR-014 zones.json) produces ONE note and no
  //     warnings — the back-fill must not drown the operator.
  {
    const bare = (o: Record<string, unknown>) => { const c = { ...o }; delete c.tier; delete c.isolated; return c; };
    const r = run({ mgmt: bare(mgmt), acme: bare(svc) });
    check(r.warnings === 0, "P2: a pre-ADR-014 (untiered) doc produces NO tier warnings");
    check(r.lines.filter((l) => l.includes("tier:") && l.includes("carry no 'tier'")).length === 1, "P2: untiered zones are reported once, as a single note");
  }
}

// ── 19. ADR-014 P3 / #865: environment links, rendering, and back-fill ─
{
  const d = mkdtempSync(join(tmpdir(), "nm-p3-"));
  mkdirSync(join(d, "environments"), { recursive: true });
  writeFileSync(join(d, "environments", "warmelo.json"),
    JSON.stringify({ name: "warmelo" }), "utf8");
  writeFileSync(join(d, "environments", "mgmt.json"),
    JSON.stringify({ name: "mgmt" }), "utf8");

  const base = () => ({
    mgmt: { type: "Management", state: "Manual", typeId: "0", subId: "0", vlantag: 0, ip: "10.0.0.0/24", tier: 0, environment: "mgmt", "access-to": ["internet"], "pinhole-allowed-from": [] },
    warmelo: { type: "Service", state: "Active", typeId: "2", subId: "0", vlantag: 200, ip: "10.2.0.0/24", tier: 1, environment: "warmelo", "access-to": ["internet"], "pinhole-allowed-from": [] },
    home: { type: "Client", state: "Active", typeId: "3", subId: "10", vlantag: 310, ip: "10.3.10.0/24", tier: 2, environment: "warmelo", "access-to": ["internet"], "pinhole-allowed-from": [] },
    iotLocal: { type: "IoT", state: "Active", typeId: "4", subId: "10", vlantag: 410, ip: "10.4.10.0/24", tier: 6, environment: "warmelo", "access-to": [], "pinhole-allowed-from": [] },
    iotCams: { type: "IoT", state: "Active", typeId: "4", subId: "30", vlantag: 430, ip: "10.4.30.0/24", tier: 6, isolated: true, environment: "warmelo", "access-to": [], "pinhole-allowed-from": [] },
  });
  const write = (o: Record<string, unknown>, n = "zones.json") => {
    const f = join(d, n);
    writeFileSync(f, JSON.stringify(o, null, 2), "utf8");
    return f;
  };

  // (a) the role asymmetry: client consumes, service drives IoT.
  {
    const eff = renderEffective(loadZones(write(base())), d);
    const z = (k: string) => eff.raw[k] as Record<string, unknown>;
    check((z("home")["access-to"] as string[]).includes("warmelo"), "P3: a Client zone's environment derives home.access-to += <service zone>");
    check((z("iotLocal")["pinhole-allowed-from"] as string[]).includes("warmelo"), "P3: an IoT zone's environment derives iotLocal.pinhole-allowed-from += <service zone>");
    // THE LOCALITY RULE: the link only ever modifies the zone that declares it.
    // A symmetric derivation invented edges the authored doc never had — caught
    // against the live reference config, see the serves.ts header.
    check(!(z("warmelo")["pinhole-allowed-from"] as string[]).includes("home"), "P3: the link does NOT invent an entry on the service zone (locality rule)");
    check(!(z("warmelo")["access-to"] as string[]).includes("iotLocal"), "P3: the link does NOT invent zone-wide service→IoT reach (locality rule)");
    // R2 is now structural: the IoT branch never touches access-to at all.
    check((z("iotCams")["pinhole-allowed-from"] as string[]).includes("warmelo"), "P3 R2: an isolated IoT zone still records who may pinhole into it");
    check(!(z("warmelo")["access-to"] as string[]).includes("iotCams"), "P3 R2: an isolated IoT zone is added to NOBODY's access-to");
    check(eff.errors.length === 0, "P3: a well-formed environment graph resolves without errors");
  }

  // (a2) #865: a Service or Management zone names exactly one environment, as a
  //      string; a consumer zone one or a list of distinct ones. An environment
  //      named by two Service zones is an error, and one named by none fails the
  //      zones that serve it. A DMZ zone may name one and derives nothing.
  {
    const b = base() as Record<string, Record<string, unknown>>;
    b.mgmt.environment = ["mgmt"];
    const e1 = renderEffective(loadZones(write(b, "zones-multi.json")), d);
    check(e1.errors.some((x) => x.includes("'mgmt'") && x.includes("exactly one environment")), "#865: a list on the Management zone is an error");
    for (const [label, v] of [["an empty list", []], ["a repeated name", ["warmelo", "warmelo"]], ["a non-name", [7]]] as [string, unknown][]) {
      const bl = base() as Record<string, Record<string, unknown>>;
      bl.home.environment = v;
      const el = renderEffective(loadZones(write(bl, "zones-bad-list.json")), d);
      check(el.errors.some((x) => x.includes("'home'") && x.includes("list of distinct names")), `#865: ${label} on a client zone is an error`);
    }
    const b2 = base() as Record<string, Record<string, unknown>>;
    b2.lab = { type: "Service", state: "Active", typeId: "2", subId: "1", vlantag: 299, ip: "10.2.99.0/24", tier: 1, environment: "warmelo", "access-to": ["internet"], "pinhole-allowed-from": [] };
    const e2 = renderEffective(loadZones(write(b2, "zones-two.json")), d);
    check(e2.errors.some((x) => x.includes("named by 2")), "#865: an environment named by two Service zones is an error");
    const b3 = base() as Record<string, Record<string, unknown>>;
    delete b3.warmelo.environment;
    const e3 = renderEffective(loadZones(write(b3, "zones-orphan.json")), d);
    check(e3.errors.some((x) => x.includes("'home'") && x.includes("no Service zone")), "#865: serving an environment with no zone is an error");
    const b4 = base() as Record<string, Record<string, unknown>>;
    b4.dmz = { type: "DMZ", state: "Mandatory", typeId: "6", subId: "10", vlantag: 610, ip: "10.6.0.0/24", tier: 4, environment: "warmelo", "access-to": ["internet"], "pinhole-allowed-from": ["internet"] };
    const e4 = renderEffective(loadZones(write(b4, "zones-dmz.json")), d);
    check(e4.errors.length === 0 && JSON.stringify((e4.raw["dmz"] as Record<string, unknown>)["access-to"]) === '["internet"]',
      "#865: a DMZ zone may name an environment and derives no edge");
    check(environmentZoneIn(loadZones(write(base(), "zones-own.json")), "warmelo") === "warmelo"
      && environmentZoneIn(loadZones(write(base(), "zones-own.json")), "mgmt") === "mgmt",
      "#865: an environment's zone is the Service/Management zone naming it");
    check(zoneEnvironment({ environment: "a" }) === "a" && zoneEnvironment({}) === undefined, "#865: zoneEnvironment reads the field");
  }

  // (a3) #865: a zone serving several environments gets the union of their edges.
  {
    writeFileSync(join(d, "environments", "lab.json"), JSON.stringify({ name: "lab" }), "utf8");
    const b = base() as Record<string, Record<string, unknown>>;
    b.lab = { type: "Service", state: "Active", typeId: "2", subId: "1", vlantag: 299, ip: "10.2.99.0/24", tier: 1, environment: "lab", "access-to": ["internet"], "pinhole-allowed-from": [] };
    b.home.environment = ["warmelo", "lab"];
    b.iotLocal.environment = ["warmelo", "lab"];
    const eff = renderEffective(loadZones(write(b, "zones-union.json")), d);
    const z = (k: string) => eff.raw[k] as Record<string, unknown>;
    const at = z("home")["access-to"] as string[];
    check(at.includes("warmelo") && at.includes("lab"), "#865: a client serving two environments reaches both of their zones");
    const paf = z("iotLocal")["pinhole-allowed-from"] as string[];
    check(paf.includes("warmelo") && paf.includes("lab"), "#865: an IoT zone serving two environments accepts pinholes from both");
    check(eff.edges.filter((e) => e.zone === "home").length === 2 && eff.errors.length === 0, "#865: one derived edge per environment, no errors");
    check(zoneEnvironments({ environment: ["a", "b"] }).join() === "a,b" && zoneEnvironments({ environment: "a" }).join() === "a" && zoneEnvironment({ environment: ["a"] }) === undefined,
      "#865: zoneEnvironments reads both forms; zoneEnvironment only the single one");
    check(JSON.stringify(environmentValue(["a"])) === '"a"' && JSON.stringify(environmentValue(["a", "b", "a"])) === '["a","b"]' && environmentValue([]) === undefined,
      "#865: one environment is written as a string, several as a list");
    // the back-fill prunes each derived literal of a zone that already serves several
    const legacy = JSON.parse(JSON.stringify(b)) as Record<string, any>;
    legacy.home["access-to"] = ["internet", "warmelo", "lab"];
    const bf = backfillServes(legacy, d);
    check(JSON.stringify(legacy.home["access-to"]) === '["internet"]' && bf.changes.filter((c) => c.zone === "home").length === 2,
      "#865: the back-fill drops every literal a listed environment now derives");
  }

  // (b) the authored document is never mutated by rendering.
  {
    const f = write(base());
    const before = readFileSync(f, "utf8");
    renderEffective(loadZones(f), d);
    check(readFileSync(f, "utf8") === before, "P3 D-C4: rendering does NOT write back into the authored zones.json");
  }

  // (c) clearing a link drops its derived edges — the whole reason for D-C4.
  {
    const b = base();
    delete (b.home as Record<string, unknown>).environment;
    const eff = renderEffective(loadZones(write(b)), d);
    check(!((eff.raw["home"] as Record<string, unknown>)["access-to"] as string[]).includes("warmelo"), "P3 D-C4: clearing the link cleanly drops the derived access-to edge");
    const b2 = base() as Record<string, any>;
    delete b2.iotLocal.environment;
    const eff2 = renderEffective(loadZones(write(b2, "unbound-iot.json")), d);
    check(!((eff2.raw["iotLocal"] as Record<string, unknown>)["pinhole-allowed-from"] as string[]).includes("warmelo"), "P3 D-C4: clearing the link on an IoT zone drops its derived pinhole entry");
  }

  // (d) error cases: unknown environment, and a link on an Overlay zone.
  {
    const b = base() as Record<string, any>;
    b.home.environment = "nope";
    const e1 = renderEffective(loadZones(write(b)), d);
    check(e1.errors.length === 1 && e1.errors[0].includes("nope"), "P3: a link naming an unknown environment is an error");

    const b2 = base() as Record<string, any>;
    b2.edge = { type: "Overlay", state: "Manual", typeId: "0", subId: "0", vlantag: 0, ip: "10.9.0.0/24", environment: "warmelo", "access-to": [], "pinhole-allowed-from": [] };
    const e2 = renderEffective(loadZones(write(b2)), d);
    check(e2.errors.some((x) => x.includes("must not name an environment")), "P3: a link on an Overlay zone is an error");
  }

  // (e) rendering is idempotent — no duplicated refs on a second pass.
  {
    const f = write(base());
    const once = renderEffective(loadZones(f), d);
    writeFileSync(join(d, "twice.json"), JSON.stringify(once.raw), "utf8");
    const twice = renderEffective(loadZones(join(d, "twice.json")), d);
    check(JSON.stringify(twice.raw) === JSON.stringify(once.raw), "P3: rendering an already-rendered doc is a no-op (idempotent)");
  }

  // (f) THE MIGRATION INVARIANT (F2): back-fill changes the AUTHORED doc but
  //     leaves the EFFECTIVE doc byte-identical. This is what makes the
  //     migration safe to run against a live firewall.
  {
    // A pre-ADR-014 doc: literal service-zone references, no consumer links.
    const legacy: Record<string, any> = base();
    for (const k of ["home", "iotLocal", "iotCams"]) delete legacy[k].environment;
    legacy.home["access-to"] = ["internet", "warmelo"];
    legacy.iotLocal["pinhole-allowed-from"] = ["warmelo"];
    legacy.iotCams["pinhole-allowed-from"] = ["warmelo"];
    // Authored service-zone state that NO link reproduces. The
    // back-fill must leave it exactly as it is — narrowing it would be a
    // silent firewall change.
    legacy.warmelo["access-to"] = ["internet", "iotLocal"];
    legacy.warmelo["pinhole-allowed-from"] = ["home"];

    const effBefore = renderEffective(loadZones(write(legacy, "legacy.json")), d);

    const authored = JSON.parse(JSON.stringify(legacy)) as Record<string, unknown>;
    const bf = backfillServes(authored, d);
    const effAfter = renderEffective(loadZones(write(authored, "backfilled.json")), d);

    check(bf.changes.length === 3, `P3 back-fill: linked all three zones (got ${bf.changes.length})`);
    check((authored["home"] as any).environment === "warmelo", "P3 back-fill: home gains environment='warmelo'");
    check(!((authored["home"] as any)["access-to"] as string[]).includes("warmelo"), "P3 back-fill: the now-derived literal is dropped from the authored doc");
    check((authored["iotCams"] as any).environment === "warmelo", "P3 back-fill: an isolated IoT zone is linked from its pinhole literal");
    check(
      JSON.stringify((authored["warmelo"] as any)["access-to"]) === JSON.stringify(["internet", "iotLocal"]) &&
      JSON.stringify((authored["warmelo"] as any)["pinhole-allowed-from"]) === JSON.stringify(["home"]),
      "P3 back-fill: authored service-zone state is left untouched (no silent narrowing)",
    );

    const norm = (o: Record<string, unknown>) => JSON.stringify(Object.fromEntries(
      Object.entries(o).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => {
        if (v === null || typeof v !== "object" || Array.isArray(v)) return [k, v];
        const z = { ...(v as Record<string, unknown>) };
        if (["home", "iotLocal", "iotCams"].includes(k)) delete z.environment; // authored-only, absent before the back-fill
        for (const f of ["access-to", "pinhole-allowed-from"]) {
          if (Array.isArray(z[f])) z[f] = (z[f] as string[]).slice().sort();
        }
        return [k, z];
      })));
    check(norm(effBefore.raw) === norm(effAfter.raw), "P3 back-fill: THE EFFECTIVE DOCUMENT IS UNCHANGED — authored-only migration (F2)");

    // and it converges: a second back-fill is a no-op.
    const again = backfillServes(JSON.parse(JSON.stringify(authored)), d);
    check(again.changes.length === 0, "P3 back-fill: idempotent — a converged install re-runs it as a no-op");

    // a literal naming a NON-environment zone is left alone (that is `retire`'s job).
    const stale: Record<string, any> = base();
    delete stale.home.environment;
    stale.home["access-to"] = ["internet", "srvHome"];
    const bf2 = backfillServes(stale, d);
    check(!bf2.changes.some((c) => c.zone === "home"), "P3 back-fill: a stale literal that is no environment's zone is NOT converted");
  }
}

// ── 20. ADR-014 P4: every archetype produces a conforming zone ────────
// The acceptance line from the ADR: `add --archetype <A>` yields a zone with
// the correct type/tier/isolated/access-to seed and an auto-allocated vlan/ip,
// with NO hand editing — and that zone must pass the P2 invariants.
{
  const d = mkdtempSync(join(tmpdir(), "nm-p4-"));
  mkdirSync(join(d, "environments"), { recursive: true });
  writeFileSync(join(d, "environments", "warmelo.json"),
    JSON.stringify({ name: "warmelo" }), "utf8");

  // A minimal but conforming starting document.
  const seed = {
    mgmt: { type: "Management", state: "Manual", typeId: "0", subId: "0", vlantag: 0, ip: "10.0.0.0/24", tier: 0, "access-to": ["internet"], "pinhole-allowed-from": [] },
    warmelo: { type: "Service", state: "Active", typeId: "2", subId: "0", vlantag: 200, ip: "10.2.0.0/24", tier: 1, environment: "warmelo", "access-to": ["internet"], "pinhole-allowed-from": [] },
    // the `service` archetype seeds access-to: [internet, dmz], so dmz must exist
    dmz: { type: "DMZ", state: "Mandatory", typeId: "6", subId: "10", vlantag: 610, ip: "10.6.0.0/24", tier: 4, "access-to": ["internet"], "pinhole-allowed-from": ["internet"] },
  };
  const f = join(d, "zones.json");
  writeFileSync(f, JSON.stringify(seed, null, 2), "utf8");

  // Author one zone per archetype into a single doc (they must coexist: each
  // gets its own VLAN out of its type band).
  const doc = loadZones(f);
  let allOk = true;
  const created: string[] = [];
  for (const a of ARCHETYPES) {
    // camelCase the archetype name into a legal zone key: iot-cams -> zIotCams
    const zn = "z" + a.name.split("-").map((p) => p[0].toUpperCase() + p.slice(1)).join("");
    try {
      const z = authorZone(doc, zn, {
        archetype: a.name,
        environment: a.type === "Client" || a.type === "IoT" || a.type === "Guest" ? "warmelo" : undefined,
      });
      created.push(zn);
      const good =
        z.type === a.type &&
        z.typeId === String(a.typeId) &&
        z.tier === a.tier &&
        (a.isolated ? z.isolated === true : z.isolated === undefined) &&
        JSON.stringify(z["access-to"]) === JSON.stringify(a.accessTo) &&
        typeof z.vlantag === "number" && z.vlantag > 0 &&
        typeof z.ip === "string" && z.ip.startsWith(`10.${a.typeId}.`);
      if (!good) {
        allOk = false;
        console.log(`    (archetype ${a.name} produced ${JSON.stringify(z)})`);
      }
    } catch (e) {
      allOk = false;
      console.log(`    (archetype ${a.name} threw: ${(e as Error).message})`);
    }
  }
  check(created.length === ARCHETYPES.length, `P4: every archetype authors a zone (${created.length}/${ARCHETYPES.length})`);
  check(allOk, "P4: each archetype stamps the right type/typeId/tier/isolated/access-to + auto vlan/ip");

  // The whole set must pass the P2 invariants with no edits — this is what
  // "tier-correct by construction" has to mean.
  saveZones(f, doc);
  const res = runChecks(loadZones(f), d, false);
  if (res.errors !== 0) for (const l of res.lines) if (l.includes("✗")) console.log(`    ${l}`);
  check(res.errors === 0, `P4: an all-archetype document has no errors (got ${res.errors})`);
  // `control` is a SINGLETON archetype: it seeds access-to: ["all"], and I2
  // permits that wildcard only on the real `mgmt` control plane. A second
  // control zone therefore trips I2 by design — that is the check earning its
  // keep, not a defect, so it is the one expected warning here.
  const i2OnControl = res.lines.filter((l) => l.includes("I2:") && l.includes("zControl")).length;
  check(i2OnControl === 1, "P4: a SECOND control-plane zone trips I2 (the 'all' wildcard is mgmt-only)");
  check(res.warnings === 1, `P4: no archetype other than the control singleton trips an invariant (got ${res.warnings} warning(s))`);

  // --environment composes with --archetype, and R2 still holds for the isolated ones.
  {
    const eff = renderEffective(loadZones(f), d);
    const cams = eff.raw["zIotCams"] as Record<string, unknown>;
    check((cams["pinhole-allowed-from"] as string[]).includes("warmelo"), "P4: --archetype + --environment binds the new zone in one command");
    const svc = eff.raw["warmelo"] as Record<string, unknown>;
    check(!(svc["access-to"] as string[]).includes("zIotCams"), "P4 R2: an isolated archetype zone is in nobody's access-to");
  }

  // An unknown archetype is refused, not silently defaulted.
  {
    const d2 = loadZones(f);
    let threw = false;
    try { authorZone(d2, "zNope", { archetype: "not-a-thing" }); } catch { threw = true; }
    check(threw, "P4: an unknown archetype is rejected");
  }
}

// ── 21. ADR-014 D7 / F3: `retire` — remove what a release stopped shipping ─
{
  const d = mkdtempSync(join(tmpdir(), "nm-retire-"));
  const mk = (zones: Record<string, unknown>) => {
    const f = join(d, `z-${Math.random().toString(36).slice(2)}.json`);
    writeFileSync(f, JSON.stringify(zones, null, 2), "utf8");
    return f;
  };
  const zone = (o: Record<string, unknown> = {}) => ({
    type: "Service", state: "Inactive", typeId: "2", subId: "9", vlantag: 299,
    ip: "10.2.99.0/24", "access-to": [], "pinhole-allowed-from": [], ...o,
  });

  // (a) an Inactive, unoccupied retired zone is removed, and every reference to
  //     it is stripped from the zones that named it.
  {
    const f = mk({
      mgmt: zone({ type: "Management", state: "Manual", "access-to": ["internet", "acme", "srvHome", "iot"] }),
      acme: zone({ state: "Active", "access-to": ["internet"], "pinhole-allowed-from": ["srvHome"] }),
      srvHome: zone({ state: "Inactive" }),
      iot: zone({ type: "IoT", state: "Inactive" }),
    });
    const doc = loadZones(f);
    const res = retireZones(doc, join(d, "no-config"), true);
    check(res.retired.sort().join(",") === "iot,srvHome", `retire removes the eligible set (got ${res.retired.join(",")})`);
    check(!zoneExists(doc, "srvHome") && !zoneExists(doc, "iot"), "retire deletes the zone keys");
    const mgmtAccess = getZone(doc, "mgmt")?.["access-to"] as string[];
    check(!mgmtAccess.includes("srvHome") && !mgmtAccess.includes("iot") && mgmtAccess.includes("acme"),
      "retire strips references to the retired zones and leaves the others");
    check(!(getZone(doc, "acme")?.["pinhole-allowed-from"] as string[]).includes("srvHome"),
      "retire strips pinhole-allowed-from references too");
  }

  // (b) THE GUARD: a live zone is never retired automatically.
  {
    const f = mk({ mgmt: zone({ type: "Management", state: "Manual" }), srvWork: zone({ state: "Active" }) });
    const doc = loadZones(f);
    const res = retireZones(doc, join(d, "no-config"), true);
    check(res.retired.length === 0 && res.kept.includes("srvWork"), "an ACTIVE retired-set zone is kept, not deleted");
    check(zoneExists(doc, "srvWork"), "the live zone survives");
    check(res.items.some((i) => i.zone === "srvWork" && i.detail.includes("disable")), "the keep reason tells the operator how to proceed");
  }

  // (c) THE GUARD: a zone still hosting a deployed module is never retired.
  {
    const cfg = mkdtempSync(join(tmpdir(), "nm-retire-cfg-"));
    writeFileSync(join(cfg, "nextcloud.json"), JSON.stringify({ zone0: "srvCust" }), "utf8");
    const f = mk({ mgmt: zone({ type: "Management", state: "Manual" }), srvCust: zone({ state: "Inactive" }) });
    const doc = loadZones(f);
    const res = retireZones(doc, cfg, true);
    check(res.retired.length === 0 && res.kept.includes("srvCust"), "an OCCUPIED retired-set zone is kept, not deleted");
    check(zoneExists(doc, "srvCust"), "the occupied zone survives (its module is not orphaned)");
  }

  // (d) THE SET IS EXPLICIT: `work` and `srv` are Inactive+unoccupied here and
  //     must still be untouched — retire is a named list, never "everything off".
  {
    const f = mk({
      mgmt: zone({ type: "Management", state: "Manual" }),
      work: zone({ type: "Client", state: "Inactive" }),
      srv: zone({ state: "Inactive" }),
      lab: zone({ state: "Inactive" }),
    });
    const doc = loadZones(f);
    const res = retireZones(doc, join(d, "no-config"), true);
    check(res.retired.length === 0, "retire touches nothing outside its explicit set");
    check(zoneExists(doc, "work") && zoneExists(doc, "srv") && zoneExists(doc, "lab"),
      "work, srv and an operator zone all survive retire");
  }

  // (e) dry-run mutates nothing but reports the same verdicts.
  {
    const f = mk({ mgmt: zone({ type: "Management", state: "Manual", "access-to": ["srvHome"] }), srvHome: zone({ state: "Inactive" }) });
    const before = readFileSync(f, "utf8");
    const doc = loadZones(f);
    const res = retireZones(doc, join(d, "no-config"), false);
    check(res.retired.includes("srvHome"), "dry-run reports what would be retired");
    check(res.items.find((i) => i.zone === "srvHome")?.strippedFrom.includes("mgmt") === true,
      "dry-run reports which zones would lose a reference");
    check(res.changed === false, "dry-run reports changed=false");
    check(readFileSync(f, "utf8") === before, "dry-run does not touch the file");
    check(zoneExists(doc, "srvHome"), "dry-run does not mutate the in-memory doc either");
  }

  // (f) idempotent: a second apply finds nothing.
  {
    const f = mk({ mgmt: zone({ type: "Management", state: "Manual" }), srvDev: zone({ state: "Inactive" }) });
    const doc = loadZones(f);
    retireZones(doc, join(d, "no-config"), true);
    const second = retireZones(doc, join(d, "no-config"), true);
    check(second.retired.length === 0 && second.kept.length === 0, "a second retire pass is a no-op (idempotent)");
  }

  // (g) the retired set never includes the rename source or a client zone.
  check(!RETIRED_ZONES.includes("srv") && !RETIRED_ZONES.includes("work") &&
        !RETIRED_ZONES.includes("home") && !RETIRED_ZONES.includes("guest"),
    "the retired set excludes srv (rename source) and the client/role zones");
}

// ── §14. writeJsonAtomic leaves no temp directory behind (#527) ────────
// The atomic write creates a temp dir, writes into it and renames the file out.
// Before the fix the directory itself was never removed, so every merge and
// every init leaked one empty .zones-merge-* directory into the config dir —
// 28 of them had accumulated on the reference install over three weeks.
{
  console.log("");
  console.log("== §14. atomic write leaves no temp directory (#527) ==");

  const tpl14 = process.env.NM_TEMPLATE;
  if (!tpl14) {
    check(false, "NM_TEMPLATE env must point at the distributed zones.json template (#527 tests)");
  } else {
    const NAME14 = "myorg";
    const silent14 = { info: () => {}, warn: () => {} };
    const renameRaw14 = () => renameTemplateFile(tpl14, NAME14, new Set<string>()).raw;
    const freshCfg14 = (): string => {
      const dir = mkdtempSync(join(tmpdir(), "nm-527-"));
      const txt = JSON.stringify(renameTemplateFile(tpl14, NAME14).raw, null, 4) + "\n";
      writeFileSync(join(dir, "site.json"), JSON.stringify({ name: NAME14 }), "utf8");
      writeFileSync(join(dir, "zones.json"), txt, "utf8");
      writeFileSync(join(dir, "zones.json.orig"), txt, "utf8");
      writeFileSync(join(dir, "zones.rename.json"), txt, "utf8");
      return dir;
    };
    const leaked = (dir: string) => readdirSync(dir).filter((e) => e.startsWith(".zones-merge-"));
    const merge14 = (dir: string) => runZonesMerge(
      { current: join(dir, "zones.json"), orig: join(dir, "zones.json.orig"), rename: join(dir, "zones.rename.json"), template: tpl14, name: NAME14 },
      silent14,
      renameRaw14,
    );

    // (a) a merge leaves the config dir clean.
    {
      const dir = freshCfg14();
      check(leaked(dir).length === 0, "no leftover temp dir before the merge (baseline)");
      const rc = merge14(dir);
      check(rc === 0, "merge returns rc=0");
      check(leaked(dir).length === 0,
        `merge leaves no .zones-merge-* temp dir behind (found ${JSON.stringify(leaked(dir))})`);
    }

    // (b) repeated writes do not accumulate — this is what made it visible in
    //     the field: one directory per call, growing without bound.
    {
      const dir = freshCfg14();
      for (let i = 0; i < 3; i++) merge14(dir);
      check(leaked(dir).length === 0,
        `three merges leave no temp dirs (found ${leaked(dir).length})`);
    }
  }
}

// ── DHCP boot options 66/67 (#546): authoring, clone, override, validate ──
{
  // authoring with both flags stamps the two zone fields
  const f = tmpZones();
  let doc = loadZones(f);
  const z = authorZone(doc, "pxeZone", {
    tftpServerName: "10.4.0.10",
    bootfileName: "pxelinux.0",
  });
  check(
    z["tftp-server-name"] === "10.4.0.10" && z["bootfile-name"] === "pxelinux.0",
    "authorZone stamps tftp-server-name + bootfile-name from flags",
  );

  // --from-zone inherits both boot options from the source zone
  const clone = authorZone(doc, "pxeClone", { fromZone: "pxeZone" });
  check(
    clone["tftp-server-name"] === "10.4.0.10" && clone["bootfile-name"] === "pxelinux.0",
    "clone (--from-zone) inherits both boot options",
  );

  // flags OVERRIDE the inherited values on clone
  const over = authorZone(doc, "pxeClone2", {
    fromZone: "pxeZone",
    tftpServerName: "10.9.9.9",
    bootfileName: "grubx64.efi",
  });
  check(
    over["tftp-server-name"] === "10.9.9.9" && over["bootfile-name"] === "grubx64.efi",
    "clone flags override the inherited boot options",
  );

  // a half-configured pair is rejected at authoring time
  let threw = false;
  try {
    authorZone(doc, "pxeBad", { tftpServerName: "10.4.0.10" });
  } catch {
    threw = true;
  }
  check(threw, "authoring only one of tftp-server-name/bootfile-name is rejected");
}

// ── validate (runChecks) catches a hand-edited half-configured pair ───
{
  function bootDoc(bootZone: Record<string, unknown>): { zonesFile: string; configDir: string } {
    const d = mkdtempSync(join(tmpdir(), "nm-boot-"));
    const raw: Record<string, unknown> = {
      mgmt: {
        type: "Management", state: "Active", typeId: "0", subId: "0",
        vlantag: 0, ip: "10.0.0.0/24", bridge: "lan",
        "access-to": ["internet"], "pinhole-allowed-from": [],
      },
      iotLocal: {
        type: "IoT", state: "Active", typeId: "4", subId: "0",
        vlantag: 400, ip: "10.4.0.0/24", bridge: "lan",
        "access-to": [], "pinhole-allowed-from": [],
        ...bootZone,
      },
    };
    const zonesFile = join(d, "zones.json");
    writeFileSync(zonesFile, JSON.stringify(raw, null, 2), "utf8");
    return { zonesFile, configDir: d };
  }

  const both = bootDoc({ "tftp-server-name": "10.4.0.10", "bootfile-name": "pxelinux.0" });
  const rOk = runChecks(loadZones(both.zonesFile), both.configDir, false);
  const half = bootDoc({ "tftp-server-name": "10.4.0.10" });
  const rBad = runChecks(loadZones(half.zonesFile), half.configDir, false);
  check(rBad.errors > rOk.errors, `half-configured boot pair → hard error (ok=${rOk.errors}, half=${rBad.errors})`);
}

// ── `modify --set` on a zone's policy (ADR-020 D6, #538) ───────────────
//
// The second-manager proof: the same declared-field change model, one manager
// over. What is asserted is the PRE-GATE — which zone fields may be changed by
// a verb at all — because that is what turns "hand-edit zones.json" into an
// operation with a stated cost.
//
// Two kinds of refusal, deliberately worded differently:
//   - `immutable` (vlantag, ip, type, bridge): a zone's identity. Changing it
//     would strand every guest tagged into it, so it is delete-and-re-add.
//   - `manual` (state, environment): these HAVE a verb, and that verb carries guards
//     a generic --set would bypass — leaving Mandatory needs --force, binding
//     resolves the environment first. The refusal names the verb.
{
  // The REAL schema — the change classes under test are the ones shipped, not a
  // fixture's idea of them. FIXTURE_DIR is test/fixtures in the source tree, so
  // three levels up is manager/, and two more reach foundation/schemas.
  const schemaPath = join(
    FIXTURE_DIR, "..", "..", "..", "..", "..", "schemas", "zones-fields.json",
  );
  const schema = (JSON.parse(readFileSync(schemaPath, "utf8")) as {
    fields: ZonesFieldsSchema;
  }).fields;

  // A throwaway zones.json with one real zone to write into.
  const mkZones = (): string => {
    const d = mkdtempSync(join(tmpdir(), "nm-modify-"));
    const f = join(d, "zones.json");
    writeFileSync(
      f,
      JSON.stringify(
        {
          rossen: {
            type: "Service", state: "Active", typeId: "2", subId: "0",
            vlantag: 200, ip: "10.2.0.0/24", bridge: "lan",
            "access-to": ["internet", "dmz"], "pinhole-allowed-from": ["dmz"],
          },
        },
        null,
        2,
      ),
      "utf8",
    );
    return f;
  };

  const gate = (...pairs: string[]) =>
    preGateZoneSet("rossen", pairs.map((p) => parseSetArg(p)!), schema);
  const why = (r: ReturnType<typeof gate>, needle: string): boolean =>
    !r.ok && r.rejections.some((x) => x.reason.includes(needle));

  // Every zone field carries a declared class — the coverage rule, applied to
  // the real schema rather than a fixture.
  const unclassified = Object.entries(schema)
    .filter(([, v]) => !v.changeClass)
    .map(([k]) => k);
  check(unclassified.length === 0, `every zone field declares a changeClass${unclassified.length ? " — missing: " + unclassified.join(", ") : ""}`);

  // The three fields #538 names.
  check(gate("access-to=internet,mgmt").ok, "#538: access-to can be changed by a verb");
  check(gate("pinhole-allowed-from=home").ok, "#538: pinhole-allowed-from can be changed by a verb");
  check(gate("description=a new description").ok, "#538: description can be changed by a verb");

  // Refusals that follow from the schema alone.
  const vlan = gate("vlantag=250");
  check(!vlan.ok, "vlantag is refused before anything is written");
  check(why(vlan, "strand every guest"), "…and the message says what it would break, not just 'no'");
  check(!gate("ip=10.9.0.0/24").ok, "a zone's subnet is refused — re-addressing every guest is a migration");
  check(!gate("bridge=wan").ok, "a zone's trunk is refused");

  // Refusals that point at the verb that does carry the guards.
  const state = gate("state=Inactive");
  check(!state.ok && why(state, "enable|disable|manual"), "state is refused, naming the verb that has the guards");
  const envLink = gate("environment=acme");
  check(!envLink.ok && why(envLink, "bind"), "environment is refused, naming bind");
  const ssid = gate("SSID=rossen-home");
  check(!ssid.ok && why(ssid, "ap-manager ssid add"), "#889: SSID is refused, naming the ap-manager verbs that own it");

  // Reject the WHOLE command, so zones.json and the planes never move apart.
  const mixed = gate("description=fine", "vlantag=250");
  check(!mixed.ok, "a mixed --set with one immutable field is rejected");
  check(!mixed.ok && mixed.rejections.length === 1, "…naming only the field at fault");
  check(!mixed.ok && !("plan" in mixed), "…and yielding no plan, so nothing is written");

  const unknown = gate("nosuchfield=1");
  check(!unknown.ok && why(unknown, "spelling"), "a field zones-fields.json does not declare is refused");

  // Value coercion: a list field must not end up holding a string.
  check(
    JSON.stringify(coerce("internet,mgmt", "array")) === JSON.stringify({ ok: true, value: ["internet", "mgmt"] }),
    "a list takes the comma form an operator actually types",
  );
  check(
    JSON.stringify(coerce('["a","b"]', "array")) === JSON.stringify({ ok: true, value: ["a", "b"] }),
    "…and JSON, for scripts",
  );
  check(
    JSON.stringify(coerce("", "array")) === JSON.stringify({ ok: true, value: [] }),
    "…and empty, which is how an access-to list is cleared",
  );
  // A value that LOOKS like JSON is held to it; anything else is a plain list
  // token. That split matters: `access-to=[bad` is a typo worth refusing, while
  // a bare word containing a bracket is just an (unknown) zone name, which
  // validate reports later with far more context than a coercion error could.
  check(coerce('["a", bad]', "array").ok === false, "a value that looks like JSON but is not is refused");
  check(
    JSON.stringify(coerce("weird[name", "array")) === JSON.stringify({ ok: true, value: ["weird[name"] }),
    "…while a bare token is just a list entry, left for validate to judge",
  );
  check(coerce("lots", "integer").ok === false, "a non-number is refused for a numeric field");
  check(coerce("maybe", "boolean").ok === false, "a non-boolean is refused for a boolean field");

  // Applying the plan writes through to the document.
  {
    const doc = loadZones(mkZones());
    const g = preGateZoneSet("rossen", [parseSetArg("access-to=internet,mgmt")!], schema);
    if (g.ok) applyZoneSet(doc, "rossen", g.plan);
    check(
      JSON.stringify((doc.raw.rossen as Record<string, unknown>)["access-to"]) === '["internet","mgmt"]',
      "the plan writes a real array into the zone document",
    );
  }
}

// ── the proxmox plane's status aggregation (#zone-add regression) ──────
//
// `reconcile --apply` applies per-VM trunks but only REPORTS node bridge-vids
// drift; `bridge-vids --apply` is what applies it. Taking the worst of the two
// meant a correctly-converged run still failed on reconcile's stale rc=2, so
// EVERY zone add that widened a node's VLAN set reported failure after
// succeeding. When applying, the verdict comes from a dry-run re-check taken
// after both.
{
  const ok = (rc: number) => ({ rc, stdout: "", stderr: "", ran: true });
  const gone = { rc: -1, stdout: "", stderr: "", ran: false };

  check(
    proxmoxNeedsRecheck(ok(2), ok(0), true) === true,
    "a re-check is taken when applying and neither command hard-errored",
  );
  check(
    proxmoxNeedsRecheck(ok(2), ok(0), false) === false,
    "…but never in a dry-run, where drift is the answer, not a failure",
  );
  check(
    proxmoxNeedsRecheck(ok(1), ok(0), true) === false,
    "…nor after a hard error, which already decides the status",
  );

  // The regression itself: reconcile reports drift, bridge-vids fixes it, the
  // re-check finds nothing left. That is convergence, not a failure.
  check(
    proxmoxStatus(ok(2), ok(0), ok(0), true) === "in-sync",
    "reconcile's stale drift does not condemn a run that bridge-vids converged",
  );
  check(
    proxmoxStatus(ok(2), ok(0), ok(2), true) === "needs-manual",
    "drift that SURVIVES both applies is still needs-manual",
  );
  check(
    proxmoxStatus(ok(0), ok(0), gone, true) === "error",
    "a re-check that could not run is an error, not a silent pass",
  );

  // Dry-run keeps the old worst-wins aggregation: nothing was applied, so
  // neither command's report is stale.
  check(
    proxmoxStatus(ok(2), ok(0), null, false) === "drift",
    "a dry-run still reports drift by worst-wins",
  );
  check(
    proxmoxStatus(ok(1), ok(0), null, true) === "error",
    "a hard error from either command wins over the other's success",
  );
}

// #645: the opnsense dry-run is zone-manager's check mode with
// --detailed-exitcode, so pending rule changes surface as drift instead of the
// old unconditional "reported (dry-run)".
{
  check(opnsenseDryRunResult("zm", 2, 0).status === "drift",
    "#645: rule changes pending → the opnsense dry-run reports drift");
  check(opnsenseDryRunResult("zm", 0, 0).status === "in-sync",
    "#645: nothing pending → in sync");
  check(opnsenseDryRunResult("zm", 1, 0).status === "error",
    "#645: a failed check mode is an error, not in sync");
  check(opnsenseDryRunResult("zm", 0, 2).status === "error",
    "#645: pinhole-validator schema errors still fail the dry-run");
}


// ── ADR-021 D5: the split-horizon resolver, as a pure function ────────
{
  console.log("");
  console.log("== split-horizon-target (ADR-021 D5) ==");

  check(gatewayIpOf("10.6.0.0/24") === "10.6.0.1", "D5: gateway of a /24 is .1");
  check(gatewayIpOf("10.255.1.0/24") === "10.255.1.1", "D5: gateway of another /24");
  check(gatewayIpOf("10.255.0.0/31") === "10.255.0.1", "D5: a /31 tunnel link still has a first host");
  check(gatewayIpOf(undefined) === undefined, "D5: a missing CIDR has no gateway");
  check(gatewayIpOf("not-a-cidr") === undefined, "D5: a malformed CIDR has no gateway");
  check(gatewayIpOf("10.6.0.0/99") === undefined, "D5: an impossible prefix has no gateway");

  const docOf = (zones: Record<string, unknown>) => ({
    raw: zones,
    zones: new Map(Object.entries(zones).map(([k, v]) => [k, { name: k, ...(v as object) }])),
  }) as never;

  const withDmz = docOf({ dmz: { type: "DMZ", ip: "10.6.0.0/24" } });

  // Published → the DMZ gateway, for every caller. That is the whole rule (D2).
  const ok1 = resolveSplitHorizonTarget(withDmz, "openwebui.example.org", true);
  check(ok1.status === "ok" && ok1.ip === "10.6.0.1" && ok1.zone === "dmz",
    "D5: a published name resolves to the DMZ gateway");
  // …and it does not depend on the name: one answer, not one per service.
  const ok2 = resolveSplitHorizonTarget(withDmz, "cloud.example.org", true);
  check(ok2.status === "ok" && ok2.ip === "10.6.0.1",
    "D5: a different published name gets the SAME address (no per-service derivation)");

  // Not publicly resolvable → UNPUBLISHED, a supported state (R3), not an error.
  const un = resolveSplitHorizonTarget(withDmz, "internal-only.example.org", false);
  check(un.status === "unpublished", "D5: an unpublishable name is UNPUBLISHED, not an error");
  check(un.status === "unpublished" && un.domain === "internal-only.example.org",
    "D5: …and it names the domain it could not publish");

  // No dmz zone at all → ERROR: the site cannot express an answer.
  const noDmz = resolveSplitHorizonTarget(docOf({ srv: { ip: "10.2.0.0/24" } }), "x.example.org", true);
  check(noDmz.status === "error", "D5: a site with no dmz zone is an ERROR");

  // A dmz zone with an unusable ip is an error too — never a silent bad address.
  const badIp = resolveSplitHorizonTarget(docOf({ dmz: { type: "DMZ", ip: "nonsense" } }), "x.example.org", true);
  check(badIp.status === "error", "D5: a dmz zone with an unusable ip is an ERROR");

  // UNPUBLISHED wins over a missing dmz: "this name is not published" is the
  // more useful answer, and it is the one that must not read as breakage.
  const both = resolveSplitHorizonTarget(docOf({}), "x.example.org", false);
  check(both.status === "unpublished", "D5: unpublished is reported ahead of a site-level error");
}

// ── #644: --help never runs a verb; an unknown option is refused ─────
// `distribute --help` used to push zones.json to every node. Every case runs
// against a temp config dir whose zones.json must stay byte-identical, with a
// FakePlaneClient that must record no call and an scp that must never run.
{
  console.log("");
  console.log("== argument gate (#644) ==");

  const cfg = mkdtempSync(join(tmpdir(), "nm-gate-"));
  const zf = join(cfg, "zones.json");
  copyFileSync(FIXTURE, zf);
  writeFileSync(join(cfg, "configuration.json"), JSON.stringify({ "tappaas-nodes": [{ hostname: "tappaas1" }] }), "utf8");
  const marker = join(cfg, "scp-was-run");
  const fakeScp = join(cfg, "scp");
  writeFileSync(fakeScp, `#!/usr/bin/env bash\ntouch '${marker}'\n`, "utf8");
  chmodSync(fakeScp, 0o755);
  const before = readFileSync(zf, "utf8");
  const prevEnv = { cfg: process.env.TAPPAAS_CONFIG, scp: process.env.NM_SCP_BIN };
  process.env.TAPPAAS_CONFIG = cfg;
  process.env.NM_SCP_BIN = fakeScp;

  const call = (argv: string[]): { rc: number; out: string; err: string; planes: number } => {
    const log = console.log;
    const error = console.error;
    let out = "";
    let err = "";
    console.log = (...a: unknown[]): void => {
      out += a.map(String).join(" ") + "\n";
    };
    console.error = (...a: unknown[]): void => {
      err += a.map(String).join(" ") + "\n";
    };
    const c = new FakePlaneClient();
    try {
      const rc = run(argv, c);
      return { rc, out, err, planes: c.calls.length };
    } finally {
      console.log = log;
      console.error = error;
    }
  };
  const untouched = (): boolean => readFileSync(zf, "utf8") === before && !existsSync(marker);

  const helpCases: string[][] = [
    ["reconcile", "--help"],
    ["reconcile", "--apply", "-h"],
    ["distribute", "--help"],
    ["zones-distribute", "--zones", zf, "-h"],
    ["add", "srvTenant", "--from-zone", "srvHome", "--help"],
    ["delete", "dmz", "--help"],
    ["modify", "dmz", "--set", "description=x", "-h"],
    ["enable", "srvTest", "--help"],
    ["bind", "home", "--environment", "srv", "--help"],
    ["retire", "--apply", "--help"],
    ["merge", "--help"],
    ["zone", "add", "srvTenant", "--help"],
    ["zone", "--help"],
  ];
  for (const argv of helpCases) {
    const r = call(argv);
    check(
      r.rc === 0 && r.out.includes("Usage:") && r.planes === 0 && untouched(),
      `'${argv.join(" ")}' prints help, rc 0, runs nothing (rc=${r.rc}, planes=${r.planes})`,
    );
  }

  const dist = call(["distribute", "--help"]);
  check(
    dist.out.includes("distribute [--zones <file>] [--dry-run]") && !dist.out.includes("reconcile [--apply]"),
    "'distribute --help' prints the distribute usage, not the whole manual",
  );
  check(call(["zones-distribute", "--help"]).out.includes("distribute [--zones"), "an alias prints its verb's help");
  check(call(["snat", "--help"]).out.includes("snat verify <module>"), "'snat --help' prints the snat usage");
  const bogus = call(["bogus", "--help"]);
  check(bogus.rc === 0 && bogus.out.includes("reconcile [--apply]"), "an unknown verb with --help prints the full help");

  const refused: Array<[string[], string]> = [
    [["delete", "dmz", "--dry-run"], "--dry-run"], // delete's dry-run is --check
    [["reconcile", "--aply"], "--aply"],
    [["distribute", "--force"], "--force"],
    [["add", "srvTenant", "--vlan=70"], "write '--vlan 70'"],
  ];
  for (const [argv, want] of refused) {
    const r = call(argv);
    check(
      r.rc === 1 && r.err.includes(want) && r.planes === 0 && untouched(),
      `'${argv.join(" ")}' is refused before anything runs (rc=${r.rc})`,
    );
  }

  const rec = call(["reconcile", "--only", "switch", "--zones", zf]);
  check(rec.rc === 0 && rec.planes === 1, "declared and hidden options still pass the gate (reconcile --only … --zones …)");
  const tier = call(["list", "--tier", "-1", "--json"]);
  check(!tier.err.includes("unknown option"), "an option value that starts with '-' is not taken for an option");
  check(undocumentedOptions(HELP).length === 0, `every option in a usage line is described (${undocumentedOptions(HELP).join(", ")})`);

  for (const [k, v] of [["TAPPAAS_CONFIG", prevEnv.cfg], ["NM_SCP_BIN", prevEnv.scp]] as const) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
}

// ── ipv6Subnet (ADR-030 D4): allocated by default, unique, removable ──
{
  const f = tmpZones();
  const doc = loadZones(f);
  check(allocateIpv6Subnet(doc, 310) === 0x31, "VLAN 310 reads as subnet 0x31");
  check(allocateIpv6Subnet(doc, 465) === 1, "a VLAN off the ten-step grid gets the lowest free number");
  const z = authorZone(doc, "work", { type: "Client", typeId: "3", vlan: 320 });
  check(z.ipv6Subnet === 0x32, `a new zone gets its subnet number (got ${z.ipv6Subnet})`);
  // The readable number is taken: the next zone gets the lowest free one.
  doc.zones.set("work", z);
  doc.raw["work"] = { ...z };
  const z2 = authorZone(doc, "work2", { type: "Client", typeId: "3", vlan: 330 });
  check(z2.ipv6Subnet === 0x33, `the next zone gets its own (got ${z2.ipv6Subnet})`);
  const w = authorZone(loadZones(f), "wan2", { type: "WAN", typeId: "1", vlan: 160 });
  check(w.ipv6Subnet === undefined, "a WAN zone never gets one");
}
{
  const schema = { ipv6Subnet: { type: "integer", changeClass: "immutable", unset: true },
                   vlantag: { type: "integer", changeClass: "immutable" } };
  check(preGateZoneUnset(["ipv6Subnet"], schema).length === 0, "--unset ipv6Subnet is allowed");
  const r = preGateZoneUnset(["vlantag", "nosuch"], schema);
  check(r.length === 2 && r[0].reason.includes("cannot be removed"),
    "--unset of a field the schema does not allow is refused");
  const set = preGateZoneSet("home", [{ field: "ipv6Subnet", value: "7" }], schema);
  check(!set.ok, "--set ipv6Subnet is refused: it is immutable");
}

// ── render: zones.effective.json without touching any plane (review D13) ──
{
  const f = tmpZones();
  const eff = join(dirname(f), "zones.effective.json");
  check(!existsSync(eff), "no effective document before render");
  const rc = run(["render", "--zones", f]);
  check(rc === 0 && existsSync(eff), "render writes zones.effective.json next to zones.json");
  check(JSON.stringify(Object.keys(JSON.parse(readFileSync(eff, "utf8"))).sort())
        === JSON.stringify(Object.keys(JSON.parse(readFileSync(f, "utf8"))).sort()),
    "the effective document carries the same zones");
}

// ── #862: what the firewall carries is detected, never re-allocated ──
{
  // A hand-built NAS segment on VLAN 100 / 10.1.0.0/24 (label 'storage'), a
  // bare VLAN device 150 with no interface, lan untagged on 10.0.0.0/24.
  const occ = occupancyFrom({
    vlans: [
      { tag: 100, device: "vlan0.100", parent: "vtnet0", description: "storage" },
      { tag: 150, device: "vlan0.150", parent: "vtnet0", description: "spare" },
    ],
    interfaces: [
      { identifier: "lan", description: "lan", device: "vtnet0", tag: null, ipv4: "10.0.0.0/24" },
      { identifier: "opt3", description: "storage", device: "vlan0.100", tag: 100, ipv4: "10.1.0.0/24" },
      { identifier: "opt9", description: "parked", device: "vlan0.300", tag: 300, ipv4: null },
    ],
  });
  const h100 = occ.tag(100);
  check(h100?.kind === "interface" && h100.name === "storage", "a tag held by an assigned interface names that interface");
  check(describeHolder(h100!) === "interface 'storage' (opt3, VLAN 100, 10.1.0.0/24)", "the holder is described with identifier, tag and subnet");
  check(occ.tag(150)?.kind === "vlan", "a VLAN device with no interface is a holder too");
  check(describeHolder(occ.tag(150)!).startsWith("VLAN device 'spare'"), "…described as a bare device");
  check(occ.tag(200) === undefined, "a free tag has no holder");
  check(occ.subnet("10.1.0.0/24")?.identifier === "opt3", "the same subnet is held");
  check(occ.subnet("10.1.0.128/25")?.identifier === "opt3" && occ.subnet("10.0.0.0/16")?.identifier === "lan",
    "overlap in either direction is held");
  check(occ.subnet("10.2.0.0/24") === undefined, "a free subnet has no holder");
  check(!ipv4Overlaps("garbage", "10.1.0.0/24") && !ipv4Overlaps("10.1.0.0/24", "10.1.0.0/33"),
    "unparseable input never overlaps");
  check(collisionOf({ vlantag: 300, ip: "10.9.0.0/24" }, occ)?.reason === "VLAN 300 is already on the firewall: interface 'parked' (opt9, VLAN 300)",
    "a tag collision is reported before the subnet");
  check(collisionOf({ vlantag: 275, ip: "10.1.0.0/24" }, occ)?.reason === "10.1.0.0/24 overlaps the firewall's interface 'storage' (opt3, VLAN 100, 10.1.0.0/24)",
    "a subnet collision is reported on its own");
  check(collisionOf({ vlantag: 275, ip: "10.2.75.0/24" }, occ) === undefined, "no collision, no report");

  // add: --vlan on a held tag is refused with the holder named …
  const doc = loadZones(tmpZones());
  let msg = "";
  try { authorZone(doc, "nas", { vlan: 100, occupancy: occ }); } catch (e) { msg = (e as Error).message; }
  check(msg.includes("VLAN 100 is already on the firewall: interface 'storage'") && msg.includes("TAPPaaS's own numbers stay"),
    "add --vlan <held tag> is refused, naming the holder and the way out");
  check(!zoneExists(doc, "nas"), "…and nothing is authored");
  // … and the band allocation is NOT retried when the firewall holds the tag it picks.
  const picked = allocateVlan(doc, 2);
  const occTop = occupancyFrom({ interfaces: [{ identifier: "opt5", description: "lab", device: `vlan0.${picked}`, tag: picked, ipv4: null }] });
  msg = "";
  try { authorZone(doc, "lab2", { occupancy: occTop }); } catch (e) { msg = (e as Error).message; }
  check(msg.includes(`VLAN ${picked} is already on the firewall: interface 'lab'`),
    "an auto-allocated tag the firewall holds is refused, not skipped to the next");
  check(authorZone(doc, "lab3", { occupancy: occ }).vlantag === picked, "a free allocation authors as before");
  check(authorZone(doc, "lab4", {}).vlantag !== undefined, "without an occupancy the check is skipped (as before #862)");

  // merge: a source-only zone the firewall's segment collides with is not added.
  const cur = { mgmt: { vlantag: 0, ip: "10.0.0.0/24", state: "Active" } };
  const src = { mgmt: { vlantag: 0, ip: "10.0.0.0/24", state: "Active" },
                wan: { type: "WAN", vlantag: 100, ip: "10.1.0.0/24", state: "Manual" },
                srv: { vlantag: 200, ip: "10.2.0.0/24", state: "Inactive" } };
  const r = mergeZones(cur, cur, src, true, occ);
  check(r.added.length === 1 && r.added[0] === "srv", "merge: the free zone is added");
  check(r.notAdded.length === 1 && r.notAdded[0].zone === "wan" && r.notAdded[0].reason.includes("interface 'storage'") && r.notAdded[0].reason.includes("then merge again"),
    "merge: the colliding zone is not added, the holder named");
  check(!("wan" in r.merged), "…and is absent from the merged document");
  check(mergeZones(cur, cur, src, true).added.length === 2, "merge without an occupancy adds both (zones.json only, as before)");

  // Through the CLI: a stub opnsense-firewall answers `segments --json`.
  const stubDir = mkdtempSync(join(tmpdir(), "nm-fw-"));
  const stub = join(stubDir, "opnsense-firewall");
  writeFileSync(stub, "#!/bin/sh\n[ \"$1\" = segments ] || exit 2\ncat <<'J'\n" +
    JSON.stringify({ interfaces: [{ identifier: "opt3", description: "storage", device: "vlan0.100", tag: 100, ipv4: "10.1.0.0/24" }] }) +
    "\nJ\n");
  chmodSync(stub, 0o755);
  const prevBin = process.env.NM_OPNSENSE_FIREWALL_BIN;
  process.env.NM_OPNSENSE_FIREWALL_BIN = stub;
  const f = tmpZones();
  const before = readFileSync(f, "utf8");
  check(run(["add", "nas", "--vlan", "100", "--zones", f, "--check"]) !== 0, "add --check refuses a tag the stub firewall holds");
  check(run(["add", "nas", "--vlan", "100", "--zones", f, "--no-activate"]) !== 0 && readFileSync(f, "utf8") === before,
    "add refuses it for real too, and writes nothing");
  check(run(["add", "lab5", "--zones", f, "--check"]) === 0, "add --check passes a free allocation");
  process.env.NM_OPNSENSE_FIREWALL_BIN = join(stubDir, "no-such-bin");
  check(run(["add", "lab6", "--zones", f, "--check"]) === 0, "a firewall that cannot be asked is said, and add goes on (zones.json only)");
  if (prevBin === undefined) delete process.env.NM_OPNSENSE_FIREWALL_BIN; else process.env.NM_OPNSENSE_FIREWALL_BIN = prevBin;
}

// ── wan ipv6-relearn (#875): --check is the controller's check mode, --apply is not ──
{
  const dir = mkdtempSync(join(tmpdir(), "nm-wan-"));
  const log = join(dir, "args");
  const stub = join(dir, "ipv6-manager");
  writeFileSync(stub, `#!/bin/sh\necho "$@" >> '${log}'\n`);
  chmodSync(stub, 0o755);
  const prev = process.env.NM_IPV6_BIN;
  process.env.NM_IPV6_BIN = stub;
  check(run(["wan", "ipv6-relearn", "--check", "--config-dir", dir]) === 0, "wan ipv6-relearn --check runs the controller");
  check(run(["wan", "ipv6-relearn", "--config-dir", dir]) === 0, "…and so does no flag");
  check(run(["wan", "ipv6-relearn", "--apply", "--config-dir", dir]) === 0, "wan ipv6-relearn --apply runs it");
  const calls = readFileSync(log, "utf8").trim().split("\n");
  check(calls.length === 3 && calls[0] === `relearn --config-dir ${dir} --no-ssl-verify --check-mode` && calls[1] === calls[0],
    `--check and no flag are ipv6-manager relearn --check-mode (${calls[0]})`);
  check(calls[2] === `relearn --config-dir ${dir} --no-ssl-verify`, "--apply drops --check-mode");
  check(run(["wan", "ipv6-relearn", "--check", "--apply"]) !== 0, "--check and --apply together are refused");
  check(run(["wan", "ipv6-relearn", "--force"]) !== 0, "an option the verb does not take is refused");
  check(readFileSync(log, "utf8").trim().split("\n").length === 3, "…and neither ran the controller");
  if (prev === undefined) delete process.env.NM_IPV6_BIN; else process.env.NM_IPV6_BIN = prev;
  const v = renderManifest(HELP).verbs.find((x) => x.verb === "wan ipv6-relearn");
  check(!!v && v.effect === "write" && v.preview.kind === "apply-flag" && "flag" in v.preview && v.preview.flag === "--apply",
    "help --json: wan ipv6-relearn previews without --apply");
}

// ── #876: a shared service zone, over Erik's shape ────────────────────
// Environments gridtefy and acmeco each have a Service zone of their own;
// srvWork lists both (shared), and the client zone work serves both.
{
  const src = join(FIXTURE_DIR, "shared-service-zone");
  const fresh = (): string => {
    const dir = mkdtempSync(join(tmpdir(), "nm-876-"));
    mkdirSync(join(dir, "environments"));
    for (const f of readdirSync(join(src, "environments"))) copyFileSync(join(src, "environments", f), join(dir, "environments", f));
    copyFileSync(join(src, "zones.json"), join(dir, "zones.json"));
    return dir;
  };
  const prevDist = process.env.NM_NO_DISTRIBUTE;
  process.env.NM_NO_DISTRIBUTE = "1";
  const quiet = <T>(fn: () => T): T => {
    const [log, err] = [console.log, console.error];
    console.log = () => {};
    console.error = () => {};
    try {
      return fn();
    } finally {
      [console.log, console.error] = [log, err];
    }
  };
  const nm = (argv: string[]): number => quiet(() => run(argv));
  const zenv = (dir: string, z: string): unknown => (JSON.parse(readFileSync(join(dir, "zones.json"), "utf8")) as Record<string, Record<string, unknown>>)[z]?.environment;
  const validate = (dir: string): number => nm(["validate", "--zones", join(dir, "zones.json"), "--config-dir", dir]);

  // The case that failed on Erik's site: own zone gridtefy plus srvWork listing gridtefy.
  const d = fresh();
  const doc = loadZones(join(d, "zones.json"));
  const eff = renderEffective(doc, d);
  check(eff.errors.length === 0, `#876: own zone gridtefy + shared srvWork resolve without errors (${eff.errors.join("; ")})`);
  check(validate(d) === 0, "#876: validate passes on the Erik-shaped config");
  check(environmentZoneIn(doc, "gridtefy") === "gridtefy" && environmentZoneIn(doc, "acmeco") === "acmeco",
    "#876: each environment's zone is its own zone, not the shared one");
  check(JSON.stringify(sharedZonesOf(doc, "gridtefy")) === '["srvWork"]' && sharedZonesOf(doc, "erik").length === 0,
    "#876: the shared service zones of an environment are listed separately");
  check(isSharedServiceZone({ type: "Service", environment: ["a"] }) && !isSharedServiceZone({ type: "Service", environment: "a" })
    && !isSharedServiceZone({ type: "Client", environment: ["a", "b"] }), "#876: a Service zone's list, even of one, is the shared form");

  // The derived firewall graph is the same with or without the shared zone's link.
  {
    const unlinked = JSON.parse(readFileSync(join(d, "zones.json"), "utf8")) as Record<string, Record<string, unknown>>;
    delete unlinked.srvWork.environment;
    writeFileSync(join(d, "zones-unlinked.json"), JSON.stringify(unlinked), "utf8");
    const base = renderEffective(loadZones(join(d, "zones-unlinked.json")), d);
    const strip = (raw: Record<string, unknown>) => {
      const c = JSON.parse(JSON.stringify(raw)) as Record<string, Record<string, unknown>>;
      delete c.srvWork.environment;
      return JSON.stringify(c);
    };
    check(base.errors.length === 0 && strip(eff.raw) === strip(base.raw), "#876: the shared zone changes nothing in the derived firewall graph");
    const w = eff.raw["work"] as Record<string, unknown>;
    check(JSON.stringify(w["access-to"]) === '["internet","gridtefy","acmeco"]' && !(w["access-to"] as string[]).includes("srvWork"),
      "#876: a client serving both environments reaches their own zones, not the shared one");
    check(eff.edges.every((e) => e.zone !== "srvWork" && e.serviceZone !== "srvWork"), "#876: the shared zone derives no edge and is no edge's target");
  }

  // Errors: a shared zone naming an environment that does not exist; a shared
  // zone listing an environment that has no zone of its own.
  {
    const bad = JSON.parse(readFileSync(join(d, "zones.json"), "utf8")) as Record<string, Record<string, unknown>>;
    bad.srvWork.environment = ["gridtefy", "nosuch"];
    writeFileSync(join(d, "zones-bad.json"), JSON.stringify(bad), "utf8");
    const e = renderEffective(loadZones(join(d, "zones-bad.json")), d);
    check(e.errors.some((x) => x.includes("'srvWork'") && x.includes("'nosuch'")), "#876: each name a shared zone lists must exist");
    const orphan = JSON.parse(readFileSync(join(d, "zones.json"), "utf8")) as Record<string, Record<string, unknown>>;
    delete orphan.acmeco.environment;
    const od = fresh();
    writeFileSync(join(od, "zones.json"), JSON.stringify(orphan), "utf8");
    check(validate(od) !== 0, "#876: an environment served only by a shared zone has no zone of its own — validate fails");
  }

  // bind: --add on a Service zone makes it shared; a plain bind on a shared zone
  // is refused; --unbind back to one leaves a list of one; --own turns it into
  // that environment's own zone.
  {
    const b = fresh();
    const zf = ["--zones-file", join(b, "zones.json")];
    check(nm(["bind", "srvWork", "--environment", "erik", "--add", ...zf]) === 0 && JSON.stringify(zenv(b, "srvWork")) === '["gridtefy","acmeco","erik"]',
      "#876: bind --add adds an environment to a shared service zone");
    check(nm(["bind", "srvWork", "--environment", "erik", ...zf]) !== 0, "#876: a plain bind on a shared service zone is refused");
    check(nm(["bind", "srvWork", "--unbind", "--environment", "erik", ...zf]) === 0
      && nm(["bind", "srvWork", "--unbind", "--environment", "acmeco", ...zf]) === 0
      && JSON.stringify(zenv(b, "srvWork")) === '["gridtefy"]' && validate(b) === 0,
      "#876: --unbind back to the last one leaves a list of one, still shared, and validate passes");
    check(nm(["bind", "srvWork", "--unbind", "--environment", "gridtefy", "--own", ...zf]) !== 0
      && JSON.stringify(zenv(b, "srvWork")) === '["gridtefy"]', "#876: --own is refused when there is none left to own");
    check(nm(["bind", "srvWork", "--environment", "acmeco", "--add", ...zf]) === 0
      && nm(["bind", "srvWork", "--unbind", "--environment", "gridtefy", "--own", ...zf]) !== 0,
      "#876: --own is refused while the last environment already has its own zone");
    check(nm(["bind", "acmeco", "--unbind", ...zf]) === 0
      && nm(["bind", "srvWork", "--unbind", "--environment", "gridtefy", "--own", ...zf]) === 0
      && zenv(b, "srvWork") === "acmeco" && validate(b) === 0,
      "#876: --unbind --environment … --own makes the shared zone the last environment's own zone");
    check(nm(["bind", "gridtefy", "--environment", "erik", "--add", ...zf]) === 0
      && JSON.stringify(zenv(b, "gridtefy")) === '["gridtefy","erik"]' && validate(b) !== 0,
      "#876: bind --add on an own zone makes it shared (string → list), and its environment then needs another");
    check(nm(["bind", "erik", "--environment", "erik", "--add", ...zf]) !== 0, "#876: --add of the zone's own environment is refused");
    check(nm(["bind", "mgmt", "--environment", "erik", "--add", ...zf]) !== 0, "#876: the Management zone is never shared");
  }
  if (prevDist === undefined) delete process.env.NM_NO_DISTRIBUTE; else process.env.NM_NO_DISTRIBUTE = prevDist;
}

// ── #889: the zone's SSID, written for ap-manager by set-ssid ─────────
{
  const dir = mkdtempSync(join(tmpdir(), "nm-889-"));
  copyFileSync(join(FIXTURE_DIR, "shared-service-zone", "zones.json"), join(dir, "zones.json"));
  const zf = ["--zones-file", join(dir, "zones.json")];
  const zssid = (z: string): unknown => (JSON.parse(readFileSync(join(dir, "zones.json"), "utf8")) as Record<string, Record<string, unknown>>)[z]?.SSID;
  const [log, err] = [console.log, console.error];
  console.log = () => {};
  console.error = () => {};
  let r: number[];
  try {
    r = [
      run(["set-ssid", "home", "rossen-home", ...zf]),
      run(["set-ssid", "home", "rossen-home", ...zf]),
      run(["set-ssid", "mgmt", "admin-wifi", ...zf]),
      run(["set-ssid", "guest", "<GUEST_SSID>", ...zf]),
      run(["set-ssid", "guest", "a=b", ...zf]),
      run(["set-ssid", "nosuch", "x", ...zf]),
      run(["modify", "home", "--set", "SSID=other", ...zf]),
    ];
  } finally {
    [console.log, console.error] = [log, err];
  }
  check(r[0] === 0 && zssid("home") === "rossen-home", "#889: set-ssid writes the zone's SSID");
  check(r[1] === 0, "#889: …and again is no change");
  check(r[2] !== 0 && zssid("mgmt") === undefined, "#889: the Management zone carries no WiFi");
  check(r[3] !== 0 && r[4] !== 0, "#889: a placeholder or a name with '=' is refused");
  check(r[5] !== 0, "#889: an unknown zone is refused");
  check(r[6] !== 0 && zssid("home") === "rossen-home", "#889: modify --set SSID is refused and writes nothing");
  console.log = () => {};
  const c = run(["set-ssid", "home", "--clear", ...zf]);
  console.log = log;
  check(c === 0 && zssid("home") === undefined, "#889: set-ssid --clear removes it");
  const v = renderManifest(HELP).verbs.find((x) => x.verb === "set-ssid");
  check(!!v && v.effect === "write", "#889: set-ssid is in the verb manifest as a write");
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
