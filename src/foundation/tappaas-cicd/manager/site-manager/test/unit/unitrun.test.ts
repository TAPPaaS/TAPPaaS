// unitrun.test.ts — pure helpers of `site-manager update` (ADR-017 D4).
import { buildRequest, repoStatusLine, summaryLine } from "../../src/unitrun";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

const r = buildRequest(true, false, "lars", new Date("2026-09-15T12:00:00Z"));
check(r.force && !r.noGitPull && r.requestedBy === "lars" && r.at === "2026-09-15T12:00:00.000Z", "buildRequest records options, who and when");

check(summaryLine(null).startsWith("no last-update-result.json"), "no result file is said plainly");
check(summaryLine({ stage: "rebuild", end_time: "t" }).includes("FAILED in the rebuild step"), "a run that stopped before the sweep names the step");
const line = summaryLine({ end_time: "t", control_plane: "refreshed", total: 10, succeeded: 10, failed: 0, not_attempted: 0, skipped: 1, reboot: "ok" });
check(line === "update-tappaas completed: t | control_plane=refreshed total=10 succeeded=10 failed=0 not_attempted=0 skipped=1 reboot=ok",
  "the summary matches update-tappaas's own last line");

check(repoStatusLine("T", "main", "a1", "a1", 0, null) === "T (main): current", "same tip: current");
check(repoStatusLine("T", "main", "a1", "b2b2b2b2b2", 3, null) === "T (main): 3 commit(s) behind origin", "behind: counted");
check(repoStatusLine("T", "main", "a1", "b2b2b2b2b2", null, null).includes("not fetched yet"), "unfetched tip: said so");
check(repoStatusLine("T", "main", "a1", null, null, null).includes("origin not reachable"), "no origin: drift unknown");
check(repoStatusLine("T", "main", null, null, null, "HELD until x").includes("HELD"), "a hold is shown instead of a probe");

console.log(`unitrun: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
