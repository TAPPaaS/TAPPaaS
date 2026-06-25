// cascade.test.ts — offline unit tests for the backup-manager TS port. No PBS,
// no cluster; pure config reads over the fixture tree under test/fixtures/config,
// plus a FakeClient for the controller-facing paths. Tiny assert harness (no
// framework), mirroring people-manager/test/unit/reconcile.test.ts. Run via the
// test/unit tsconfig.

import { join } from "path";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import {
  listEnvironments,
  listModules,
  moduleEnvironment,
  moduleInPbsJob,
  moduleVmid,
  resolvePolicy,
} from "../../src/config";
import { retentionValid, validate } from "../../src/validate";
import { applyPlan, computePlan } from "../../src/reconcile";
import { restoreList } from "../../src/restore";
import { addToBackupJob, modifyBackup, removeFromBackupJob } from "../../src/modify";
import { FakeClient } from "./fake-client";

// Fixtures are JSON in the SOURCE tree (test/fixtures/config), not compiled.
// The compiled test runs from dist-test/test/unit/, so walk back to the
// component root (dist-test → component) and into the real test/fixtures.
// Overridable via FIXTURE_DIR for relocation.
const FIX =
  process.env.FIXTURE_DIR ??
  join(__dirname, "..", "..", "..", "test", "fixtures", "config");

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
function eq<T>(got: T, want: T, msg: string): void {
  check(JSON.stringify(got) === JSON.stringify(want), `${msg} (got ${JSON.stringify(got)})`);
}

// ── cascade resolution (lib-cascade.sh bc_resolve) ────────────────────
{
  const pol = resolvePolicy(FIX, "nextcloud");
  eq(pol.retention, "90d", "module retention wins over env/site (90d)");
  eq(pol.environment, "prod", "environment resolved from module .environment");
  eq(pol.residency, "eu-only", "residency from env (eu-only)");
  eq(pol.schedule, "daily", "schedule inherited from environment");
  eq(pol.target, "pbs.mgmt.internal:tappaas_backup", "target from site");
  eq(pol.offsite, "remote-lars", "offsite from site");
  eq(pol.enabled, true, "enabled defaults true");
  eq(pol.exclude, ["/var/cache"], "exclude from module");
}

// retention falls back to env when module has none.
{
  // scratch.json has no retention → env prod 30d.
  const pol = resolvePolicy(FIX, "scratch");
  eq(pol.retention, "30d", "retention falls back to environment (30d)");
  eq(pol.enabled, false, "module backup.enabled:false honoured");
}

// retention falls back to site default for an unknown module (no file).
{
  const pol = resolvePolicy(FIX, "does-not-exist");
  eq(pol.retention, "7y", "unknown module → site defaultRetention (7y)");
  eq(pol.environment, null, "unknown module → no environment");
  eq(pol.enabled, true, "unknown module → enabled default true");
}

// --environment override.
{
  const env = moduleEnvironment(FIX, "nextcloud", "staging");
  eq(env, "staging", "moduleEnvironment honours override");
}

// ── listModules / wiring / vmid ───────────────────────────────────────
eq(listModules(FIX), ["nextcloud", "scratch"], "listModules skips site/environments");
eq(listEnvironments(FIX), ["prod"], "listEnvironments lists env files");
check(moduleInPbsJob(FIX, "nextcloud"), "nextcloud is wired into PBS job (dependsOn backup:vm)");
check(!moduleInPbsJob(FIX, "scratch"), "scratch is NOT wired into PBS job");
eq(moduleVmid(FIX, "nextcloud"), "201", "moduleVmid reads .vmid");

// ── retentionValid ────────────────────────────────────────────────────
check(retentionValid("7y") && retentionValid("14d") && retentionValid("6m"), "valid retentions");
check(!retentionValid("7") && !retentionValid("7x") && !retentionValid(""), "invalid retentions");

// ── validate (validate-backup.sh) ─────────────────────────────────────
{
  const res = validate(FIX);
  eq(res.errors, [], "fixture hierarchy validates with no errors");
  check(res.oks.some((o) => o.includes("target")), "validate reports site target set");
  check(
    res.oks.some((o) => o.includes("scratch") && o.includes("disabled")),
    "validate reports scratch disabled honoured",
  );
}

// ── reconcile plan (backup-manager.sh reconcile, preview) ─────────────
{
  // Live job does NOT yet cover nextcloud's vmid (201) → plan adds it.
  const fake = new FakeClient();
  fake.seedJob({ reachable: true, jobId: "tappaas-backup", vmids: [] });
  const plan = computePlan(FIX, fake.jobStatus());
  // only enabled + wired modules → nextcloud, not scratch (disabled/unwired).
  check(
    plan.actions.some((a) => a.kind === "ensure-job-member" && a.target.includes("nextcloud")),
    "reconcile plans nextcloud (enabled + wired)",
  );
  check(
    !plan.actions.some((a) => a.target.includes("scratch")),
    "reconcile skips scratch (disabled)",
  );
  check(
    plan.actions.some((a) => a.kind === "apply-schedule" && a.target.includes("daily")),
    "reconcile plans apply-schedule from resolved env schedule",
  );
}

// reconcile is IDEMPOTENT: vmid already in the live job → no ensure-job-member.
{
  const plan = computePlan(FIX, {
    jobId: "tappaas-backup",
    vmids: ["201"],
    storage: "tappaas_backup",
    reachable: true,
  });
  check(
    !plan.actions.some((a) => a.kind === "ensure-job-member"),
    "reconcile skips ensure-job-member when vmid already covered (idempotent)",
  );
}

// reconcile APPLY drives the controller mutations (addToJob + applySchedule).
{
  const fake = new FakeClient();
  fake.seedJob({ reachable: true, jobId: "tappaas-backup", vmids: [] });
  const plan = computePlan(FIX, fake.jobStatus());
  applyPlan(fake, plan);
  check(
    fake.log.some((l) => l.startsWith("add-to-job 201")),
    "reconcile apply calls controller add-to-job for nextcloud vmid 201",
  );
  check(
    fake.log.some((l) => l.startsWith("apply-schedule daily")),
    "reconcile apply calls controller apply-schedule",
  );
}

// reconcile offline → warns preview-only.
{
  const plan = computePlan(FIX, { jobId: null, vmids: [], storage: null, reachable: false });
  check(
    plan.warnings.some((w) => w.includes("not reachable")),
    "reconcile warns when controller offline",
  );
}

// ── restore list (delegates to controller via Client) ─────────────────
{
  const fake = new FakeClient();
  fake.seedSnapshots("nextcloud", ["2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z"]);
  const rc = restoreList({ client: fake, configDir: FIX }, "nextcloud");
  eq(rc, 0, "restore list returns 0");
  check(fake.log.includes("list nextcloud"), "restore list shells out to controller list");
}

// ── modify / add / delete: write the module .backup layer (decision 7) ─
{
  // Build a writable copy of the config in a temp dir (the fixtures are read-only).
  const tmp = mkdtempSync(join(tmpdir(), "bm-test-"));
  mkdirSync(join(tmp, "environments"), { recursive: true });
  // Minimal module file (no backup, not wired).
  writeFileSync(
    join(tmp, "demo.json"),
    JSON.stringify({ name: "demo", vmid: "300" }, null, 2),
    "utf8",
  );

  // modify: write enabled/retention/exclude atomically.
  const backup = modifyBackup(tmp, "demo", {
    enabled: false,
    retention: "14d",
    exclude: ["/tmp"],
  });
  eq(backup, { enabled: false, retention: "14d", exclude: ["/tmp"] }, "modify returns new .backup");
  const reread = JSON.parse(readFileSync(join(tmp, "demo.json"), "utf8"));
  eq(reread.backup.retention, "14d", "modify persisted retention to disk");
  eq(reread.backup.enabled, false, "modify persisted enabled to disk");
  eq(reread.vmid, "300", "modify preserved unrelated fields (vmid)");

  // modify again, only retention → enabled/exclude preserved.
  modifyBackup(tmp, "demo", { retention: "30d" });
  const reread2 = JSON.parse(readFileSync(join(tmp, "demo.json"), "utf8"));
  eq(reread2.backup.retention, "30d", "second modify updates only retention");
  eq(reread2.backup.enabled, false, "second modify preserves enabled");

  // add: wire into the PBS job (dependsOn backup:vm), idempotent.
  check(addToBackupJob(tmp, "demo"), "add wires dependsOn backup:vm (changed=true)");
  check(!addToBackupJob(tmp, "demo"), "add is idempotent (changed=false second time)");
  const reread3 = JSON.parse(readFileSync(join(tmp, "demo.json"), "utf8"));
  check(reread3.dependsOn.includes("backup:vm"), "add persisted dependsOn backup:vm");

  // delete: un-wire, idempotent.
  check(removeFromBackupJob(tmp, "demo"), "delete removes dependsOn backup:vm (changed=true)");
  check(!removeFromBackupJob(tmp, "demo"), "delete is idempotent (changed=false second time)");
  const reread4 = JSON.parse(readFileSync(join(tmp, "demo.json"), "utf8"));
  check(!(reread4.dependsOn ?? []).includes("backup:vm"), "delete persisted removal");

  // modify on a missing module throws.
  let threw = false;
  try {
    modifyBackup(tmp, "nope", { retention: "7d" });
  } catch {
    threw = true;
  }
  check(threw, "modify throws on a missing module");
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
