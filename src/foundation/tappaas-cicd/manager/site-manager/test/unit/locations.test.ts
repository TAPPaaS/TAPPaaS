// locations.test.ts — the site's locations (ADR-036 D1, D5): the lib/ts
// helper every manager reads them through, and the rules site-manager
// validate and the location verbs keep.

import { EMAIL, run } from "../../src/main";
import { defaultSchemaDir, siteSchema } from "../../src/config";
import { FakeSiteClient } from "./fake-client";
import {
  addLocation, deleteLocation, ensureLocation, findLocation, locationErrors, locationName, locationNamers,
  modifyLocation, primaryLocation, readLocations, siteLocale, siteLocation,
} from "../../../../lib/ts/src/locations";
import { mkdtempSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}
function throws(f: () => unknown, re: RegExp, msg: string): void {
  try {
    f();
    check(false, `${msg} (did not throw)`);
  } catch (e) {
    check(re.test(String((e as Error).message)), `${msg} (threw: ${(e as Error).message})`);
  }
}
type Obj = Record<string, unknown>;
const clone = (o: Obj): Obj => JSON.parse(JSON.stringify(o)) as Obj;

const SITE: Obj = {
  name: "rossen",
  locations: {
    rodovre: { displayName: "Rødovre", country: "DK", city: "Rodovre", timezone: "Europe/Copenhagen" },
    hareskov: { kind: "remote", country: "DK", city: "Hareskov" },
  },
  primaryLocation: "rodovre",
  locale: "en_US",
  keyboard: "dk",
};

function dir(site: Obj, files: Record<string, Obj> = {}): string {
  const d = mkdtempSync(join(tmpdir(), "loc-"));
  writeFileSync(join(d, "site.json"), JSON.stringify(site));
  for (const [f, v] of Object.entries(files)) writeFileSync(join(d, f), JSON.stringify(v));
  return d;
}

// ── names ──────────────────────────────────────────────────────────────
check(locationName("Rødovre") === "roedovre", "a Danish ø becomes oe");
check(locationName("Kgs. Lyngby") === "kgs-lyngby", "punctuation and spaces become one '-'");
check(locationName("Hetzner FSN1-DC14") === "hetzner-fsn1-dc14", "a data centre keeps its digits");
check(locationName("10 Downing St") === "loc-10-downing-st", "a name starts with a letter");
check(locationName("  ") === "" && locationName(undefined) === "", "nothing usable is ''");

// ── reading ────────────────────────────────────────────────────────────
{
  const r = readLocations(SITE);
  check(r.primary === "rodovre" && !r.legacy && Object.keys(r.locations).join() === "rodovre,hareskov", "locations and the primary are read");
  check(r.locations.hareskov.kind === "remote" && r.locations.rodovre.timezone === "Europe/Copenhagen", "…with their fields");
}
{
  // Before migration 0019: the retired location reads as the primary it becomes.
  const old = { name: "rossen", location: { country: "DK", timezone: "Europe/Copenhagen", city: "Rodovre", building: "Hus 2", locale: "en_US", keyboard: "dk" } };
  const r = readLocations(old);
  check(r.legacy && r.primary === "hus-2", "a pre-0019 site reads as one location named from its building");
  check(r.locations["hus-2"].address === "Hus 2" && r.locations["hus-2"].city === "Rodovre", "…building as its address");
  check(readLocations({ name: "x", location: { country: "DK", timezone: "UTC", city: "Kgs. Lyngby" } }).primary === "kgs-lyngby", "…else from its city");
  check(readLocations({ name: "Acme1", location: { country: "DK", timezone: "UTC" } }).primary === "acme1", "…else from the site's code");
  check(siteLocale(old).keyboard === "dk" && siteLocale(old).locale === "en_US", "locale and keyboard read from the retired shape too");
}
check(siteLocale(SITE).keyboard === "dk", "locale and keyboard are site-wide fields");
{
  const d = dir(SITE);
  check(primaryLocation(d)?.name === "rodovre", "primaryLocation() reads the config's");
  check(siteLocation("hareskov", d)?.city === "Hareskov" && siteLocation("nowhere", d) === null, "siteLocation(name) finds one, or null");
}
check(findLocation(readLocations(SITE).locations, { country: "dk", city: " rodovre " }) === "rodovre", "a place matches case and spaces ignored");
check(findLocation(readLocations(SITE).locations, { country: "DK", city: "Rodovre", address: "Hus 2" }) === null, "…but an address only an address");

// ── the edits ──────────────────────────────────────────────────────────
{
  const doc: Obj = { name: "new" };
  throws(() => addLocation(doc, "home", { country: "DK" }), /needs --timezone/, "the first own location is the primary and needs a timezone");
  addLocation(doc, "home", { country: "dk", timezone: "Europe/Copenhagen" });
  check(doc.primaryLocation === "home" && (doc.locations as Obj).home !== undefined, "…and becomes primary");
  check(((doc.locations as Obj).home as Obj).country === "DK", "a country is written upper-case");
  addLocation(doc, "dc", { country: "DE", city: "Falkenstein" });
  check(doc.primaryLocation === "home", "a second does not move the primary");
  addLocation(doc, "dc2", { country: "DE", timezone: "Europe/Berlin" }, true);
  check(doc.primaryLocation === "dc2", "…unless it is made primary");
  throws(() => addLocation(doc, "Home", { country: "DK" }), /not a location name/, "a name with a capital is refused");
  throws(() => addLocation(doc, "dc", { country: "DE" }), /already exists/, "an existing name is refused");
  throws(() => addLocation(doc, "x", {}), /needs --country/, "a location needs a country");
  throws(() => addLocation(doc, "x", { country: "Denmark" }), /alpha-2/, "…as a code");
  const buddyOnly: Obj = { name: "b" };
  addLocation(buddyOnly, "far", { country: "DE", kind: "remote" });
  check(buddyOnly.primaryLocation === undefined, "a remote location never becomes the primary by being first");
  throws(() => addLocation({ name: "o", location: { country: "DK" } }, "x", { country: "DK" }), /migration 0019/, "an unmigrated site.json is not edited");
}
{
  const doc = clone(SITE);
  modifyLocation(doc, "hareskov", { address: "Skovvej 1" });
  check(((doc.locations as Obj).hareskov as Obj).address === "Skovvej 1", "modify sets a field");
  modifyLocation(doc, "hareskov", {}, ["address"]);
  check(((doc.locations as Obj).hareskov as Obj).address === undefined, "…and unsets one");
  throws(() => modifyLocation(doc, "hareskov", {}, ["country"]), /keeps its country/, "the country cannot be unset");
  throws(() => modifyLocation(doc, "rodovre", {}, ["timezone"]), /primary location/, "nor the primary's timezone");
  throws(() => modifyLocation(doc, "nowhere", { city: "x" }), /does not exist/, "an unknown location is refused");
}
{
  const d = dir(SITE, { "remote-rasmus.json": { authId: "r@pbs", location: "hareskov" }, "nextcloud.json": { location: "/home/tappaas/TAPPaaS/src/x" } });
  check(locationNamers(d, "hareskov").join() === "remote-rasmus.json", "a peer naming a location is found — a module path is no name");
  throws(() => deleteLocation(clone(SITE), "hareskov", d), /named by remote-rasmus.json/, "a named location cannot be deleted");
  throws(() => deleteLocation(clone(SITE), "rodovre", d), /primary location/, "nor the primary one");
  const sw = dir(SITE, {
    "switch-configuration-desired.json": { switches: { "crs-a": { location: "hareskov" }, "crs-b": { location: "Rack 1" } }, accessPoints: { "Nano HD": { location: "hareskov" } } },
    "satellite-hel.json": { kind: "machine", location: "hareskov" },
  });
  check(locationNamers(sw, "hareskov").join("|") === "satellite-hel.json|switch-configuration-desired.json switch crs-a|switch-configuration-desired.json access point Nano HD", "a machine, a switch and an access point naming a location are found — free text is no name");
  throws(() => deleteLocation(clone(SITE), "hareskov", sw), /named by satellite-hel.json, switch-configuration-desired.json switch crs-a/, "…and keep it from being deleted");
  const empty = dir(SITE);
  const doc = deleteLocation(clone(SITE), "hareskov", empty);
  check(!("hareskov" in (doc.locations as Obj)), "an unnamed one can");
}
{
  const doc = clone(SITE);
  check(JSON.stringify(ensureLocation(doc, { country: "DK", city: "hareskov" }, "rasmus")) === '{"name":"hareskov","created":false}', "a place the site has is reused");
  const made = ensureLocation(doc, { country: "DE", city: "Berlin" }, "buddy");
  check(made.created && made.name === "berlin" && ((doc.locations as Obj).berlin as Obj).kind === "remote", "a new place is a remote location named from its city");
  const clash = ensureLocation(doc, { country: "US", city: "Berlin" }, "other");
  check(clash.name === "berlin-2", "a name already taken by another place gets -2");
  check(ensureLocation(doc, { country: "FR" }, "Pierre").name === "pierre", "no city: named after the peer");
}

// ── validate ───────────────────────────────────────────────────────────
{
  check(locationErrors(SITE, dir(SITE)).length === 0, "a sound site has no location errors");
  const errs = (s: Obj, files: Record<string, Obj> = {}): string[] => locationErrors(s, dir(s, files));
  check(errs({ ...SITE, primaryLocation: "nowhere" }).some((e) => e.includes("primaryLocation 'nowhere'")), "a primary naming no location is an error");
  check(errs({ ...SITE, primaryLocation: undefined }).some((e) => e.includes("names no primaryLocation")), "…and no primary at all");
  const noTz = clone(SITE);
  delete ((noTz.locations as Obj).rodovre as Obj).timezone;
  check(errs(noTz).some((e) => e.includes("records no timezone")), "the primary needs the timezone");
  check(errs({ ...SITE, location: { country: "DK" } }).some((e) => e.includes("migration 0019")), "the retired location is refused");
  check(errs(SITE, { "pull-far.json": { location: "berlin" } }).some((e) => e.includes("pull-far.json names location 'berlin'")), "a peer naming a missing location is an error");
  check(errs({ name: "x" }).some((e) => e.includes("records no locations")), "no locations at all is an error");
}
{
  // site-manager validate runs them, beside the schema check.
  const d = dir({ ...SITE, primaryLocation: "nowhere" });
  const errOut: string[] = [];
  const e = console.error;
  console.error = (m: string) => void errOut.push(String(m));
  let rc: number;
  try {
    rc = run(["validate", join(d, "site.json")], new FakeSiteClient());
  } finally {
    console.error = e;
  }
  check(rc !== 0 && errOut.some((l) => l.includes("primaryLocation 'nowhere'")), `validate fails on a dangling primary (rc ${rc}: ${errOut.join(" | ")})`);
}

// ── the dry run and the apply say the change in one line ───────────────
{
  const say = (args: string[]): { rc: number; out: string[]; err: string[] } => {
    const out: string[] = [];
    const err: string[] = [];
    const [l, e] = [console.log, console.error];
    console.log = (m: string) => void out.push(String(m));
    console.error = (m: string) => void err.push(String(m));
    try {
      return { rc: run(args, new FakeSiteClient()), out, err };
    } finally {
      [console.log, console.error] = [l, e];
    }
  };
  const d = dir(SITE);
  const before = readFileSync(join(d, "site.json"), "utf8");
  let r = say(["location", "modify", "hareskov", "--displayName", "Rasmus", "--check", "--config-dir", d]);
  check(r.rc === 0 && r.out.join("\n") === "[check] would modify location 'hareskov': displayName=Rasmus; site.json otherwise unchanged", `location modify --check: one line (${r.out.join(" | ")})`);
  check(readFileSync(join(d, "site.json"), "utf8") === before, "…and writes nothing");
  r = say(["location", "modify", "hareskov", "--displayName", "Rasmus", "--check", "--json", "--config-dir", d]);
  check(r.rc === 0 && ((JSON.parse(r.out.join("\n")) as { locations: Record<string, Obj> }).locations.hareskov.displayName === "Rasmus"), "--check --json: the whole resulting site.json");
  r = say(["location", "add", "stue", "--country", "dk", "--city", "Lyngby", "--check", "--config-dir", d]);
  check(r.rc === 0 && r.out.length === 1 && /^\[check\] would add location 'stue' \(.*Lyngby.*\)$/.test(r.out[0]), `location add --check: one line (${r.out.join(" | ")})`);
  r = say(["location", "delete", "rodovre", "--check", "--config-dir", d]);
  check(r.rc === 1 && r.out.length === 1 && /^\[refused\] location delete: .*primary/.test(r.out[0]) && r.err.length === 0, `a refusal is one [refused] line, exit 1 (${r.out.join(" | ")} / ${r.err.join(" | ")})`);
  r = say(["location", "delete", "rodovre", "--config-dir", d]);
  check(r.rc === 1 && r.err.some((l) => l.includes("[Error]")), "…without --check, the [Error] it always was");
  r = say(["location", "modify", "hareskov", "--displayName", "Rasmus", "--config-dir", d]);
  check(r.rc === 0 && r.out[0].includes("modified location 'hareskov': displayName=Rasmus; site.json otherwise unchanged") && !r.out[0].includes("[check]"), `the apply reports the same line, done (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--displayName", "Rossen", "--updateFrequency", "daily", "--updateHour", "3", "--check", "--config-dir", d]);
  check(r.rc === 0 && r.out.length === 1 && /^\[check\] would modify site: displayName=Rossen, updateSchedule=\{.*"hour":3.*\}; site.json otherwise unchanged$/.test(r.out[0]), `site modify --check: one line (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--primaryLocation", "hareskov", "--check", "--config-dir", d]);
  check(r.rc === 1 && r.out.length === 1 && /^\[refused\] site modify: 'hareskov' records no timezone/.test(r.out[0]), `site modify --check refusal: one line (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--displayName", "Rossen", "--config-dir", d]);
  check(r.rc === 0 && /modified site: displayName=Rossen; site.json otherwise unchanged/.test(r.out.join("\n")), `site modify reports the same line (${r.out.join(" | ")})`);
  // #883: supportEmail — one address, "" clears it.
  r = say(["site", "modify", "--supportEmail", "a@b.org, c@d.org", "--check", "--config-dir", d]);
  check(r.rc === 1 && /^\[refused\] --supportEmail must be one e-mail address/.test(r.out[0] ?? ""), `supportEmail: a list is refused (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--supportEmail", "support@tappaas.example", "--config-dir", d]);
  check(r.rc === 0 && (JSON.parse(readFileSync(join(d, "site.json"), "utf8")) as Obj).supportEmail === "support@tappaas.example", `supportEmail is written (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--supportEmail", "", "--config-dir", d]);
  check(r.rc === 0 && !("supportEmail" in (JSON.parse(readFileSync(join(d, "site.json"), "utf8")) as Obj)), `supportEmail "" clears it (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--supportEmail", "support@localhost", "--check", "--config-dir", d]);
  check(r.rc === 1, `supportEmail: an address without a domain is refused (${r.out.join(" | ")})`);
  // site-fields.json's pattern and the check site modify makes are one rule.
  const sf = siteSchema(defaultSchemaDir()) as { properties: Record<string, { pattern?: string; format?: string }> };
  check(sf.properties.supportEmail.pattern === EMAIL.source && sf.properties.supportEmail.format === "email", `supportEmail: the schema's pattern is site modify's (${sf.properties.supportEmail.pattern})`);

  // ADR-020 D11: --set field=value is the general form; the flags are its shortcuts.
  r = say(["site", "modify", "--set", "supportEmail=help@tappaas.example", "--set", "backup.target=pbs2", "--set", "dnsBlocklists.lists=[\"a\",\"b\"]", "--config-dir", d]);
  let sj = JSON.parse(readFileSync(join(d, "site.json"), "utf8")) as Obj;
  check(r.rc === 0 && sj.supportEmail === "help@tappaas.example" && (sj.backup as Obj).target === "pbs2" && JSON.stringify((sj.dnsBlocklists as Obj).lists) === '["a","b"]',
    `--set writes fields by name, dotted, and a JSON list (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--set", "supportEmail=nope", "--check", "--config-dir", d]);
  check(r.rc === 1 && /must be one e-mail address/.test(r.out.join(" ")), `--set is checked as its shortcut is (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--set", "name=other", "--check", "--config-dir", d]);
  check(r.rc === 1 && /^\[refused\] site modify: name cannot be set — immutable/.test(r.out[0] ?? ""), `--set name: refused with its change class (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--set", "nosuch=1", "--check", "--config-dir", d]);
  check(r.rc === 1 && /nosuch/.test(r.out.join(" ")), `--set of no field is refused (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--set", "email=a@b.org", "--email", "c@d.org", "--check", "--config-dir", d]);
  check(r.rc === 1 && /disagree/.test(r.out.join(" ")), `a shortcut and --set that disagree are refused (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--unset", "supportEmail", "--config-dir", d]);
  sj = JSON.parse(readFileSync(join(d, "site.json"), "utf8")) as Obj;
  check(r.rc === 0 && !("supportEmail" in sj) && /supportEmail=\(removed\)/.test(r.out.join(" ")), `--unset removes an optional field (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--unset", "displayName", "--check", "--config-dir", d]);
  check(r.rc === 1 && /required/.test(r.out.join(" ")), `--unset of a required field is refused (${r.out.join(" | ")})`);
  r = say(["site", "modify", "--unset", "updateSchedule.hour", "--check", "--config-dir", d]);
  check(r.rc === 1 && /frequency=none/.test(r.out.join(" ")), `--unset of the schedule is refused, naming the way to stop it (${r.out.join(" | ")})`);
  r = say(["location", "modify", "hareskov", "--set", "city=Værløse", "--config-dir", d]);
  check(r.rc === 0 && ((JSON.parse(readFileSync(join(d, "site.json"), "utf8")) as { locations: Record<string, Obj> }).locations.hareskov.city === "Værløse"), `location modify --set (${r.out.join(" | ")})`);
}

console.log(`locations.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
