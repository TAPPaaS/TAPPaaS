// schedule.test.ts — updateSchedule in both shapes (ADR-017 D7, migration 0003).
//
// The object is what `site modify` writes from here on. The legacy
// [frequency, weekday, hour] triple is still READ, because a restored backup or
// a site on an older release can hold one — a CLI that refused it would report
// "(unset)" for a site that is updating perfectly well, and a modify that wrote
// the triple back would undo a migration the ledger says is done.

import { mkdtempSync, writeFileSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { HELP, run, readSchedule, writeSchedule } from "../../src/main";
import { loadSite, refusedField, siteSchema } from "../../src/config";
import { FakeSiteClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

// ── reading ──────────────────────────────────────────────────────────────
const obj = readSchedule({ frequency: "weekly", weekday: "Tuesday", hour: 4 });
check(obj.frequency === "weekly" && obj.weekday === "Tuesday" && obj.hour === 4, "reads the object form");

const tri = readSchedule(["weekly", "Tuesday", 4]);
check(tri.frequency === "weekly" && tri.weekday === "Tuesday" && tri.hour === 4, "reads the legacy triple");

check(readSchedule(["daily", "Tuesday", 2]).weekday === null, "a weekday under daily is inert in the triple");
check(readSchedule({ frequency: "daily", weekday: "Tuesday", hour: 2 }).weekday === null,
  "…and inert in the object too");
check(readSchedule(["none", "Monday", 2]).weekday === null, "none carries no weekday");
check(readSchedule(["weekly", "Tuesday", "4"]).hour === 4, "a numeric string hour reads as a number");
check(readSchedule(undefined).frequency === undefined, "an absent schedule reads as nothing");
check(readSchedule("daily").frequency === undefined, "a bare string is not a schedule");

// ── writing ──────────────────────────────────────────────────────────────
check(JSON.stringify(writeSchedule("weekly", "Tuesday", 4)) === '{"frequency":"weekly","weekday":"Tuesday","hour":4}',
  "weekly writes frequency, weekday and hour");
check(JSON.stringify(writeSchedule("daily", "Tuesday", 3)) === '{"frequency":"daily","hour":3}',
  "daily drops the weekday rather than storing an inert one");
check(JSON.stringify(writeSchedule("none", "Monday", 2)) === '{"frequency":"none"}',
  "none carries neither");
check(JSON.stringify(writeSchedule("weekly", "Tuesday", undefined)) === '{"frequency":"weekly","weekday":"Tuesday","hour":2}',
  "a missing hour defaults to 02:00");

// ── site modify writes the object, from either starting shape ────────────
const c = new FakeSiteClient();
const dir = mkdtempSync(join(tmpdir(), "sched-"));
const siteFile = join(dir, "site.json");
const sched = (): unknown => JSON.parse(readFileSync(siteFile, "utf8")).updateSchedule;

writeFileSync(siteFile, JSON.stringify({ name: "s", updateSchedule: ["weekly", "Tuesday", 2] }));
check(run(["site", "modify", "--updateHour", "5", "--config-dir", dir], c) === 0, "modify accepts a site still on the triple");
check(JSON.stringify(sched()) === '{"frequency":"weekly","weekday":"Tuesday","hour":5}',
  "…and rewrites it as the object, keeping what was not changed");

writeFileSync(siteFile, JSON.stringify({ name: "s", updateSchedule: { frequency: "weekly", weekday: "Tuesday", hour: 2 } }));
run(["site", "modify", "--updateFrequency", "daily", "--config-dir", dir], c);
check(JSON.stringify(sched()) === '{"frequency":"daily","hour":2}',
  "switching to daily drops the weekday it no longer honours");

run(["site", "modify", "--updateFrequency", "none", "--config-dir", dir], c);
check(JSON.stringify(sched()) === '{"frequency":"none"}', "switching to none leaves only the frequency");

// weekly needs a weekday: coming from none there is none to inherit.
check(run(["site", "modify", "--updateFrequency", "weekly", "--config-dir", dir], c) !== 0,
  "weekly without a weekday is refused, not guessed");
check(JSON.stringify(sched()) === '{"frequency":"none"}', "…and nothing is written");

writeFileSync(siteFile, JSON.stringify({ name: "s" }));
run(["site", "modify", "--updateFrequency", "daily", "--config-dir", dir], c);
check(JSON.stringify(sched()) === '{"frequency":"daily","hour":2}', "a site with no schedule at all gets the object");

// The help still documents the flags that edit it.
const opts = HELP.verbs.flatMap((v) => (v.options ?? []).map(([f]) => f)).join(" ");
check(opts.includes("--updateFrequency") && opts.includes("--updateWeekday") && opts.includes("--updateHour"),
  "help documents the three schedule flags");

// ── ipv6 (#149): a boolean the network update applies; absent reads as false ──
{
  const ipv6 = (): unknown => JSON.parse(readFileSync(siteFile, "utf8")).ipv6;
  writeFileSync(siteFile, JSON.stringify({ name: "s" }));
  check(run(["site", "modify", "--ipv6", "true", "--config-dir", dir], c) === 0 && ipv6() === true,
    "site modify --ipv6 true writes a boolean true");
  run(["site", "modify", "--ipv6", "false", "--config-dir", dir], c);
  check(ipv6() === false, "…and --ipv6 false writes false");
}

// ── requireSigned (ADR-033 D9): a boolean; absent reads as false ──
{
  const req = (): unknown => JSON.parse(readFileSync(siteFile, "utf8")).requireSigned;
  writeFileSync(siteFile, JSON.stringify({ name: "s" }));
  check(run(["site", "modify", "--requireSigned", "true", "--config-dir", dir], c) === 0 && req() === true,
    "site modify --requireSigned true writes a boolean true");
  run(["site", "modify", "--requireSigned", "false", "--config-dir", dir], c);
  check(req() === false, "…and --requireSigned false writes false");
}

// ── the settings the schema calls in-place: dnssec, dnsBlocklists, diskAutoGrow ──
{
  const doc = (): Record<string, unknown> => JSON.parse(readFileSync(siteFile, "utf8"));
  writeFileSync(siteFile, JSON.stringify({ name: "s", version: "1.0", defaultEnvironment: "home" }));
  check(run(["site", "modify", "--dnssec", "false", "--config-dir", dir], c) === 0 && doc().dnssec === false, "--dnssec false writes a boolean");
  check(run(["site", "modify", "--dnssec", "maybe", "--config-dir", dir], c) !== 0, "…and anything but true|false is refused");
  run(["site", "modify", "--dnsBlocklistsLists", "atf, hgz011", "--dnsBlocklistsZones", "home,guest", "--dnsBlocklistsAllow", "example.org", "--config-dir", dir], c);
  check(JSON.stringify(doc().dnsBlocklists) === '{"lists":["atf","hgz011"],"zones":["home","guest"],"allow":["example.org"]}', "dnsBlocklists: three comma lists");
  run(["site", "modify", "--dnsBlocklistsZones", "", "--config-dir", dir], c);
  check(JSON.stringify(doc().dnsBlocklists) === '{"lists":["atf","hgz011"],"zones":[],"allow":["example.org"]}', "…'' empties one, the others kept");
  run(["site", "modify", "--diskAutoGrowThreshold", "85", "--diskAutoGrowPoolCeiling", "75", "--diskAutoGrowEnabled", "true", "--config-dir", dir], c);
  check(JSON.stringify(doc().diskAutoGrow) === '{"enabled":true,"threshold":85,"poolCeiling":75}', "diskAutoGrow: integers and a boolean, by key");
  run(["site", "modify", "--diskAutoGrowGrowPercent", "100", "--diskAutoGrowMinGrowGB", "10", "--config-dir", dir], c);
  check((doc().diskAutoGrow as Record<string, unknown>).minGrowGB === 10 && (doc().diskAutoGrow as Record<string, unknown>).threshold === 85, "…a later one keeps the rest");
  for (const [flag, v] of [["--diskAutoGrowThreshold", "101"], ["--diskAutoGrowPoolCeiling", "0"], ["--diskAutoGrowMinGrowGB", "1.5"], ["--diskAutoGrowGrowPercent", "x"]]) {
    check(run(["site", "modify", flag, v, "--config-dir", dir], c) !== 0, `${flag} ${v} is refused`);
  }
  run(["site", "modify", "--brandingLogo", "branding/logo.svg", "--config-dir", dir], c);
  check(JSON.stringify(doc().branding) === '{"logo":"branding/logo.svg"}', "branding.logo");

  // name, version and defaultEnvironment: immutable, refused with the schema's reason, nothing written
  const before = readFileSync(siteFile, "utf8");
  const err = console.error;
  for (const [flag, words] of [["--name", "cluster"], ["--version", "installed from"], ["--defaultEnvironment", "renamed srv"]]) {
    let said = "";
    console.error = (...a: unknown[]): void => { said += a.map(String).join(" "); };
    let rc: number;
    try { rc = run(["site", "modify", flag, "x", "--displayName", "Y", "--config-dir", dir], c); } finally { console.error = err; }
    check(rc! !== 0 && said.includes(`${flag} is refused — immutable:`) && said.includes(words), `${flag} is refused with the schema's reason (${said.trim()})`);
  }
  check(readFileSync(siteFile, "utf8") === before, "…and nothing is written, not even the field given beside it");

  // Every field the schema calls in-place has an option; the others have a reason.
  const schema = siteSchema("");
  const props = (schema?.properties ?? {}) as Record<string, { changeClass?: string; changeNote?: string }>;
  check(Object.keys(props).length > 15 && Object.values(props).every((p) => typeof p.changeClass === "string"), "site-fields.json classes every field");
  const modify = HELP.verbs.find((v) => v.usage.startsWith("site modify"))!;
  const flags = (modify.options ?? []).map(([f]) => f.split(" ")[0]);
  const missing = Object.entries(props).filter(([k, p]) => p.changeClass === "in-place" && !flags.some((f) => f.startsWith(k === "updateSchedule" ? "--update" : `--${k}`)));
  check(missing.length === 0, `every in-place field has a site modify option (missing: ${missing.map(([k]) => k).join(", ")})`);
  check(Object.entries(props).filter(([, p]) => p.changeClass !== "in-place").every(([, p]) => (p.changeNote ?? "").length > 20), "every other field says why");
  check(refusedField(schema, "dnssec") === null && refusedField(schema, "hardware")!.startsWith("manual:"), "refusedField: in-place none, manual its reason");
}


// ── repository trust (ADR-033 D5): add forwards every --signer; introduce exists ──
{
  const fp = "SHA256:" + "A".repeat(43);
  const fp2 = "SHA256:" + "B".repeat(43);
  c.log.length = 0;
  run(["repository", "add", "codeberg.org/x/y", "--branch", "stable", "--signer", fp, "--signer", fp2, "--config-dir", dir], c);
  check(c.log.includes(`repository.sh add codeberg.org/x/y --branch stable --signer ${fp} --signer ${fp2}`),
    "repository add forwards each --signer");
  c.log.length = 0;
  check(run(["repository", "add", "codeberg.org/x/y", "--introduction", "v1.2", "--config-dir", dir], c) !== 0,
    "…and --introduction no longer exists");
  c.log.length = 0;
  run(["repository", "add", "codeberg.org/x/y", "--unsigned", "--config-dir", dir], c);
  check(c.log.includes("repository.sh add codeberg.org/x/y --unsigned"), "…and --unsigned, as a flag");
  c.log.length = 0;
  run(["repository", "introduce", "y", "--config-dir", dir], c);
  check(c.log.includes("repository.sh introduce y"), "repository introduce delegates to repository.sh");
  c.log.length = 0;
  run(["repository", "introduce", "y", "--signer", fp, "--signer", fp2, "--config-dir", dir], c);
  check(c.log.includes(`repository.sh introduce y --signer ${fp} --signer ${fp2}`), "…with each --signer");
  writeFileSync(siteFile, JSON.stringify({ name: "s", repositories: [{ name: "y", url: "u", trust: { signers: [fp, fp2] } }] }));
  check(loadSite(siteFile).repositories[0].trust?.signers.join(" ") === `${fp} ${fp2}`, "loadSite reads repositories[].trust.signers");
  writeFileSync(siteFile, JSON.stringify({ name: "s", repositories: [{ name: "y", url: "u", trust: { introduction: "v1.2", introductionCommit: "b".repeat(40), signer: fp } }] }));
  check(loadSite(siteFile).repositories[0].trust?.signers.join(" ") === fp, "…and an older entry's single signer as a list of one");
}

console.log(`schedule: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
