// hold.test.ts — `repository hold` / `release` and the hold marker (#653).
// No cluster: a temp config dir with a site.json holding one repository.

import { mkdtempSync, writeFileSync, existsSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { HELP, run } from "../../src/main";
import { isActive, makeHold, parseUntil, readHolds, holdDir } from "../../src/hold";
import { FakeSiteClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

const NOW = 1_800_000_000;

// parseUntil: durations, ISO dates, and refusals.
check(parseUntil("30m", NOW) === NOW + 1800, "30m is 1800 s ahead");
check(parseUntil("12h", NOW) === NOW + 43200, "12h is 43200 s ahead");
check(parseUntil("7d", NOW) === NOW + 7 * 86400, "7d is a week ahead");
check(parseUntil("2030-01-01T00:00:00Z", NOW) === Date.parse("2030-01-01T00:00:00Z") / 1000, "an ISO date-time is taken as given");
for (const bad of ["tomorrow", "0h", "2020-01-01"]) {
  let threw = false;
  try {
    parseUntil(bad, NOW);
  } catch {
    threw = true;
  }
  check(threw, `--until ${bad} is refused`);
}

// isActive: the hold ends exactly at untilEpoch.
const h = makeHold("TAPPaaS", "testing", "lars", NOW + 60, NOW);
check(isActive(h, NOW), "a hold is active before its end");
check(!isActive(h, NOW + 60), "a hold is over at its end");
check(h.until === new Date((NOW + 60) * 1000).toISOString(), "until is written as ISO for the reader");

// The verbs, against a temp config dir.
const dir = mkdtempSync(join(tmpdir(), "hold-"));
writeFileSync(join(dir, "site.json"), JSON.stringify({
  name: "test", repositories: [{ name: "TAPPaaS", url: "https://example.org/x.git", branch: "main", path: "/tmp/x" }],
}));
const c = new FakeSiteClient();
const rcHold = run(["repository", "hold", "TAPPaaS", "--reason", "unpushed G0.3", "--until", "2h", "--config-dir", dir], c);
const marker = join(holdDir(dir), "TAPPaaS.json");
check(rcHold === 0 && existsSync(marker), "repository hold writes config/.repo-hold/<repo>.json");
const written = JSON.parse(readFileSync(marker, "utf8"));
check(written.reason === "unpushed G0.3" && typeof written.untilEpoch === "number", "the marker carries reason and untilEpoch");
check(readHolds(dir).has("TAPPaaS"), "readHolds finds it");
check(run(["repository", "hold", "nosuch", "--reason", "x", "--config-dir", dir], c) !== 0, "a hold on an unknown repository is refused");
check(run(["repository", "hold", "TAPPaaS", "--config-dir", dir], c) !== 0, "a hold without --reason is refused");
check(run(["repository", "release", "TAPPaaS", "--config-dir", dir], c) === 0 && !existsSync(marker), "repository release removes the marker");

// Help documents both verbs and their options.
const usages = HELP.verbs.map((v) => v.usage).join("\n");
check(usages.includes("repository hold <name> --reason") && usages.includes("repository release <name>"), "help lists hold and release");

console.log(`hold: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
