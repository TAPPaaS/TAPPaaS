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

console.log(`schedule: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
