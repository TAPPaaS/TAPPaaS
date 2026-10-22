// backupruns.test.ts — the Backup overview's last backup and last verify over
// hrossen's answer (test/fixtures/backup-runs.json, 2026-10-22: 20 guests in
// the daily job, all verified; the four hosts' file backups): the cached read,
// and what the page makes of it.

import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Reads, TTL } from "../../src/reads";
import { BackupRuns } from "../../web/src/types";
import { ago, attention, byModule, guestLevel, latestRuns, runLevel, summary, targetLabel, targetLevel, verifyLevel } from "../../web/src/backupruns";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

async function main(): Promise<void> {
  // ── the read ────────────────────────────────────────────────────────
  let t = 0;
  const site = fakeSite();
  const dir = mkdtempSync(join(tmpdir(), "console-backupruns-"));
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7, now: () => t });
  check(!reads.timed().includes(reads.backupRuns as never), "no timer of its own: read when the Backup page asks");
  const e = await reads.backupRuns.get();
  const r = e.value as unknown as BackupRuns;
  check(site.calls.filter((c) => c === "backup-manager restore list-all --json").length === 1, "the read is `backup-manager restore list-all --json`");
  await reads.backupRuns.get();
  check(site.calls.filter((c) => c.startsWith("backup-manager restore")).length === 1, "…cached");
  t = TTL.backupRuns + 1;
  await reads.backupRuns.get();
  await reads.backupRuns.refresh();
  check(site.calls.filter((c) => c.startsWith("backup-manager restore")).length >= 2, "…and read again once older than its TTL");
  check((await reads.refresh("backup-runs")).join() === "backup-runs", "refresh names it backup-runs");
  site.fail.add("backup-manager restore");
  await reads.backupRuns.refresh();
  check(reads.backupRuns.peek().error !== null && reads.backupRuns.peek().value !== null, "a failed read keeps the last answer and says why");

  // ── hrossen's answer ────────────────────────────────────────────────
  check(r.reachable && r.store === "tappaas_backup" && r.node === "tappaas3", "reachable: tappaas_backup on tappaas3");
  const own = r.guests.filter((g) => g.ns === "");
  check(own.length === 20 && own.every((g) => g.outcome === "ok" && g.bucket === "daily" && g.module !== null), "20 own guests, each in the daily job, each with its module");
  check(attention(r).length === 0, "nothing needs a look");
  check(summary(r) === "20 guests backed up on time, all verified", `the summary line (${summary(r)})`);
  check(r.targets.map((x) => targetLabel(x)).join(" | ") === "this site's guests | tappaas-cicd: files | tappaas1: files | tappaas2: files | tappaas3: files", "targets named for a person");
  check(r.targets.every((x) => targetLevel(x) === "pass"), "every target verified");
  check(byModule(r).get("vaultwarden")?.id === "610" && byModule(r).get("immich")?.id === "361", "a module's own guest, for its row");
  check(latestRuns(r).length === 1 && latestRuns(r)[0].node === "tappaas3" && runLevel(latestRuns(r)[0]) === "pass", "the newest scheduled run per node; the on-demand one of 811 left out");
  check(r.verifyJobs.length === 1 && runLevel(r.verifyJobs[0].lastRun) === "pass", "the verify job's last run: OK");

  // ── what the page says about trouble ────────────────────────────────
  const now = 1_800_000_000;
  check(ago(now - 30, now) === "just now" && ago(now - 600, now) === "10 min ago" && ago(now - 5 * 3600, now) === "5 h ago" && ago(now - 3 * 86400, now) === "3 d ago" && ago(null, now) === "never", "ago");
  const late = { ...own[0], outcome: "late" as const };
  const never = { ...own[1], outcome: "late" as const, snapshots: 0, lastBackup: null };
  const bad = { ...own[2], latestVerify: "failed" as const, failedVerifies: 1 };
  const gone = { ...own[3], outcome: "not-in-job" as const };
  check(guestLevel(late) === "warn" && guestLevel(never) === "fail" && guestLevel(bad) === "fail" && guestLevel(gone) === "skip" && guestLevel(own[4]) === "pass", "a guest's level: late warn, never or failed verify fail, no job skip");
  const r2: BackupRuns = { ...r, guests: [late, never, bad, gone, ...own.slice(4)] };
  check(attention(r2).map((g) => g.id).join(" ") === [late.id, never.id, bad.id].join(" "), "needs a look: late, never backed up, failed verify — not a guest no job has");
  check(summary(r2) === "2 of 19 guests late, 1 failed verify", `trouble in the summary (${summary(r2)})`);
  check(verifyLevel(null) === "warn" && verifyLevel({ time: 1, state: "failed" }) === "fail", "never verified warns, failed fails");
  check(targetLevel({ ...r.targets[0], unverified: 2 }) === "warn" && targetLevel({ ...r.targets[0], failedVerifies: 1 }) === "fail", "a target: unverified warns, a failed verify fails");
  check(runLevel({ state: "job errors" }) === "fail" && runLevel(null) === "skip", "a run that is not OK fails");
  check(targetLabel({ ns: "pull/rasmus", kind: "pull" }) === "rasmus: their copy, pulled here", "a buddy's copy kept here");
  done("backupruns");
}

void main();
