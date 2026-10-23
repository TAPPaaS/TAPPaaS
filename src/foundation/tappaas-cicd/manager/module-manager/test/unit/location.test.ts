// location.test.ts — where a machine is (ADR-036 D2): `add`/`adopt` with
// --location or --country/--city/--building, `modify --set location=`, and
// validate's check that the name is one of the site's locations.

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { parseSetArg, preGateSet } from "../../src/converge";
import { locationFindings, locationRefusal, resolvePlace, takePlaceFlags } from "../../src/location";
import { validateModules } from "../../src/validate";
import { listModules } from "../../src/config";
import { run } from "../../src/main";
import { FakeModuleClient } from "./fake-client";
import { AddOptions, AdoptOptions } from "../../src/types";

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

const root = mkdtempSync(join(tmpdir(), "mm-location-"));
const cfg = join(root, "config");
const repo = join(root, "repo");
mkdirSync(cfg, { recursive: true });
mkdirSync(join(repo, "src", "foundation", "satellite"), { recursive: true });
mkdirSync(join(repo, "src", "apps", "wiki"), { recursive: true });
const site = {
  name: "rossen",
  primaryLocation: "knudanchersvej95",
  locations: {
    knudanchersvej95: { country: "DK", city: "Rodovre", address: "KnudAnchersVej95", timezone: "Europe/Copenhagen" },
    hareskov: { kind: "remote", country: "DK", city: "Hareskov" },
  },
  repositories: [{ name: "TAPPaaS", path: repo, branch: "main", catalog: "src/module-catalog.json" }],
};
writeFileSync(join(cfg, "site.json"), JSON.stringify(site));
writeFileSync(join(repo, "src", "module-catalog.json"), JSON.stringify({
  modules: [
    { moduleName: "satellite", moduleJson: "src/foundation/satellite/satellite.json", stack: "foundation" },
    { moduleName: "wiki", moduleJson: "src/apps/wiki/wiki.json", stack: "apps" },
  ],
}));
writeFileSync(join(repo, "src", "foundation", "satellite", "satellite.json"), JSON.stringify({ kind: "machine" }));
writeFileSync(join(repo, "src", "apps", "wiki", "wiki.json"), JSON.stringify({ kind: "vm" }));
const siteNow = () => JSON.parse(readFileSync(join(cfg, "site.json"), "utf8")) as { locations: Record<string, Record<string, string>>; primaryLocation: string };
const quiet = <T>(f: () => T): T => {
  const [log, err] = [console.log, console.error];
  console.log = () => undefined;
  console.error = () => undefined;
  try {
    return f();
  } finally {
    console.log = log;
    console.error = err;
  }
};

// ── the flags ───────────────────────────────────────────────────────────
{
  const t = takePlaceFlags(["--address", "1.2.3.4", "--country", "fi", "--city", "Helsinki", "--roles", "[]"]);
  check(JSON.stringify(t.place) === '{"country":"fi","city":"Helsinki"}' && t.rest.join(" ") === "--address 1.2.3.4 --roles []", "the place flags are taken out, the rest left in order");
  let threw = false;
  try {
    takePlaceFlags(["--location"]);
  } catch {
    threw = true;
  }
  check(threw, "--location with no value is refused");
  check(locationRefusal(cfg, "hareskov") === null, "a location the site has is one");
  check((locationRefusal(cfg, "atlantis") ?? "").includes("site-manager location add atlantis"), "one it lacks is refused with the verb that adds it");
  check(locationRefusal(cfg, "/home/tappaas/TAPPaaS/src/foundation/satellite") !== null, "a path is never a location");
  const at = resolvePlace(cfg, { country: "dk", city: "hareskov" }, "x", false);
  check(at?.name === "hareskov" && at.created === false, "--country --city at a place the site has: that location");
  let both = "";
  try {
    resolvePlace(cfg, { location: "hareskov", country: "DK" }, "x", false);
  } catch (e) {
    both = (e as Error).message;
  }
  check(both.includes("one or the other"), "--location with --country is refused");
  check(resolvePlace(cfg, {}, "x") === null, "no place flag: no location, the primary");
}

// ── add ─────────────────────────────────────────────────────────────────
{
  const c = new FakeModuleClient();
  const rc = quiet(() => run(["add", "satellite", "--config-dir", cfg, "--address", "37.27.5.237", "--country", "FI", "--city", "Helsinki"], c));
  const pt = (c.log[0]?.opts as AddOptions | undefined)?.passthrough ?? [];
  check(rc === 0 && pt.join(" ") === "--address 37.27.5.237 --location helsinki", "add satellite --country FI --city Helsinki: install-module gets --location helsinki");
  check(JSON.stringify(siteNow().locations.helsinki) === '{"displayName":"Helsinki","kind":"remote","country":"FI","city":"Helsinki"}' && siteNow().primaryLocation === "knudanchersvej95", "…a location of kind remote added to site.json, the primary unchanged");
  const c2 = new FakeModuleClient();
  quiet(() => run(["add", "satellite", "--config-dir", cfg, "--instance", "sat2", "--country", "fi", "--city", "helsinki"], c2));
  check(((c2.log[0]?.opts as AddOptions).passthrough ?? []).join(" ") === "--instance sat2 --location helsinki" && Object.keys(siteNow().locations).length === 3, "the same place again: the same location, nothing added");
  const c3 = new FakeModuleClient();
  check(quiet(() => run(["add", "satellite", "--config-dir", cfg, "--location", "hareskov"], c3)) === 0 && ((c3.log[0]?.opts as AddOptions).passthrough ?? []).join(" ") === "--location hareskov", "--location hareskov is passed as it is");
  const c4 = new FakeModuleClient();
  check(quiet(() => run(["add", "satellite", "--config-dir", cfg, "--location", "atlantis"], c4)) !== 0 && c4.log.length === 0, "--location naming no location: refused, nothing installed");
  const c5 = new FakeModuleClient();
  check(quiet(() => run(["add", "wiki", "--config-dir", cfg, "--location", "hareskov"], c5)) !== 0 && c5.log.length === 0, "a guest module takes no location");
  const c6 = new FakeModuleClient();
  check(quiet(() => run(["add", "satellite", "--config-dir", cfg, "--physicalLocation", '{"country":"FI"}'], c6)) !== 0 && c6.log.length === 0, "--physicalLocation is refused with the new spelling");
  const c7 = new FakeModuleClient();
  check(quiet(() => run(["add", "wiki", "--config-dir", cfg, "--environment", "dev"], c7)) === 0 && !((c7.log[0]?.opts as AddOptions).passthrough ?? []).includes("--location"), "an add without a place passes none");
}

// ── adopt ───────────────────────────────────────────────────────────────
{
  const c = new FakeModuleClient();
  check(quiet(() => run(["adopt", "10.0.0.51", "--config-dir", cfg, "--location", "hareskov", "--set", "sshKeyOnly=false"], c)) === 0, "adopt --location hareskov");
  check(JSON.stringify((c.log[0]?.opts as AdoptOptions).sets) === '["sshKeyOnly=false","location=hareskov"]', "…forwarded as --set location=hareskov");
  const c2 = new FakeModuleClient();
  quiet(() => run(["adopt", "10.0.0.52", "--config-dir", cfg, "--instance", "nas", "--country", "SE", "--city", "Malmo", "--building", "Hus 7"], c2));
  check(JSON.stringify((c2.log[0]?.opts as AdoptOptions).sets) === '["location=hus-7"]' && siteNow().locations["hus-7"]?.address === "Hus 7", "adopt --country --city --building: a location named after the building");
  const c3 = new FakeModuleClient();
  check(quiet(() => run(["adopt", "10.0.0.53", "--config-dir", cfg, "--set", "location=hareskov"], c3)) !== 0, "adopt --set location= is refused (the place has its own flags)");
}

// ── modify --set location= ──────────────────────────────────────────────
{
  writeFileSync(join(cfg, "sat1.json"), JSON.stringify({ kind: "machine", moduleSource: join(repo, "src", "foundation", "satellite"), dependsOn: [] }));
  writeFileSync(join(cfg, "wiki.json"), JSON.stringify({ kind: "vm", moduleSource: join(repo, "src", "apps", "wiki"), dependsOn: [] }));
  const SCHEMA = { location: { usedBy: ["general"] } };
  const MM = { location: { class: "in-place" } };
  const g = (m: string, v: string) => preGateSet(cfg, m, [parseSetArg(`location=${v}`)!], SCHEMA, MM);
  const ok = g("sat1", "hareskov");
  check(ok.ok && ok.plan[0].class === "config-only", "a machine's location=hareskov: written, config-only");
  const bad = g("sat1", "atlantis");
  check(!bad.ok && bad.rejections[0].reason.includes("no location 'atlantis'"), "…a location the site lacks is refused");
  const guest = g("wiki", "hareskov");
  check(!guest.ok && guest.rejections[0].reason.includes("not a machine"), "a guest's location is refused: it is where its node is");
  const listed = preGateSet(cfg, "sat1", [{ field: "location", value: "" }], SCHEMA, MM);
  check(listed.ok, "asked with no value (module-manager fields), a machine's location is settable");
}

// ── validate ────────────────────────────────────────────────────────────
{
  check(locationFindings(cfg, { kind: "machine", location: "hareskov" }).errors.length === 0, "a machine naming a location of the site: clean");
  check(locationFindings(cfg, { kind: "machine", location: "atlantis" }).errors.some((e) => e.includes("'atlantis'")), "naming one the site lacks: an error");
  check(locationFindings(cfg, { kind: "machine", moduleSource: "/x/satellite", location: "/x/satellite" }).errors.length === 0, "a location with a '/' is the old directory field, not checked");
  check(locationFindings(cfg, { kind: "machine", physicalLocation: { country: "FI" } }).warnings.some((w) => w.includes("migration 0021")), "a physicalLocation left: a warning naming the migration");
  check(locationFindings(cfg, { kind: "vm", location: "hareskov" }).warnings.some((w) => w.includes("only a machine")), "a guest naming a location: a warning");
  writeFileSync(join(cfg, "sat1.json"), JSON.stringify({ kind: "machine", stack: "foundation", moduleSource: join(repo, "src", "foundation", "satellite"), location: "atlantis" }));
  const r = validateModules(listModules(cfg).filter((m) => m.name === "sat1"), { configDir: cfg });
  check(r.errors === 1 && r.findings.some((f) => f.module === "sat1" && f.message.includes("atlantis")), "module validate reports the machine naming no location");
}

console.log(`\nlocation: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
