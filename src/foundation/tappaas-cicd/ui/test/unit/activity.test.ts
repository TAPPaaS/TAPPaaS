// activity.test.ts — the sweep's runs cut from its journal (hrossen,
// 2026-10-10..17), the failures ledger, and a module's slice of the sweep.

import { readFileSync } from "fs";
import { join } from "path";
import { linesNaming, parseJournal, parseLedger, sweepRuns } from "../../src/activity";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const entries = parseJournal(readFileSync(join(FIX, "sweep-journal.txt"), "utf8"));
const runs = sweepRuns(entries);
check(entries.length > 100, `the journal parses (${entries.length} lines)`);
check(runs.length >= 14, `a run per "Starting TAPPaaS scheduler" (${runs.length})`);
check(runs[0].start.startsWith("2026-10-17T02:00") && runs[0].result === "ok" && runs[0].end !== null, "newest first: 2026-10-17 02:00, succeeded");
const failed = runs.find((r) => r.start.startsWith("2026-10-14T02:00"));
check(failed?.result === "failed" && failed.end?.startsWith("2026-10-14T02:33") === true, "2026-10-14 02:00 failed at 02:33");
check(!!failed?.lines.some((l) => l.level === "error" && /nixos-rebuild on 10\.2\.0\.163/.test(l.text)), "…and keeps the error that failed it");
check(runs.every((r) => r.lines.every((l) => l.level === "error" || l.level === "warning")), "only errors and warnings are kept");
check(entries.filter((e) => e.pid1).every((e) => !/\x1b/.test(e.message)), "colour codes are stripped");

const mid = sweepRuns(parseJournal(
  "2026-10-18T02:00:00+02:00 h systemd[1]: Starting TAPPaaS scheduler — update foundation and app modules...\n" +
  "2026-10-18T02:01:00+02:00 h bash[9]: [Error] immich: pre-update test failed\n",
));
check(mid[0].result === "running" && mid[0].end === null, "a run with no end yet is running");
check(linesNaming(mid, "immich").length === 1 && linesNaming(mid, "imm").length === 0, "a module's lines are matched by its whole name");

const ledger = parseLedger(readFileSync(join(FIX, "update-tappaas.failures"), "utf8"));
check(ledger.length > 0 && ledger[0].at !== null && ledger[0].at >= (ledger[ledger.length - 1].at ?? ""), "the ledger, newest first");
check(ledger.some((l) => /FAILED/.test(l.text)), "…with its FAILED lines");

done("activity");
