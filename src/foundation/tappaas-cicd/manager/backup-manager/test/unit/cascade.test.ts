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
  listBackupModules,
  listModules,
  listPeers,
  moduleEnvironment,
  moduleInPbsJob,
  moduleVmid,
  readPlacement,
  resolvePolicy,
} from "../../src/config";
import { retentionValid, validate } from "../../src/validate";
import { applyPlan, computePlan } from "../../src/reconcile";
import { restoreList } from "../../src/restore";
import { addToBackupJob, modifyBackup, removeFromBackupJob } from "../../src/modify";
import { FakeClient } from "./fake-client";

// Fixtures are JSON in the SOURCE tree (test/fixtures/config), not compiled.
// The compiled test runs from dist-test/manager/backup-manager/test/unit/
// (the shared tsconfig.base rootDir is the cicd root, so emit mirrors the
// tree), so walk back to the component root (unit → test → backup-manager →
// manager → dist-test → component) and into the real test/fixtures.
// Overridable via FIXTURE_DIR for relocation.
const FIX =
  process.env.FIXTURE_DIR ??
  join(__dirname, "..", "..", "..", "..", "..", "test", "fixtures", "config");

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

// applyPlan continues past a failing action and reports it: a client whose
// addToJob throws must not strand apply-schedule, and the outcome carries the
// applied / total / failure counts for the caller's "applied N of M" report.
{
  const fake = new FakeClient();
  fake.seedJob({ reachable: true, jobId: "tappaas-backup", vmids: [] });
  const plan = computePlan(FIX, fake.jobStatus());
  fake.failOn.add("addToJob");
  const res = applyPlan(fake, plan);
  check(res.total === plan.actions.length, "applyPlan outcome counts every planned action");
  check(res.failures.length >= 1, "applyPlan records the failing add-to-job action");
  check(res.applied === res.total - res.failures.length, "applyPlan applied = total - failed");
  check(
    fake.log.some((l) => l.startsWith("apply-schedule")),
    "applyPlan continues to apply-schedule after add-to-job fails",
  );
  check(
    res.failures.every((f) => f.message.includes("simulated addToJob failure")),
    "applyPlan failure carries the underlying error message",
  );
}

// ── malformed config JSON is an ERROR, not a silent default ───────────
// A present-but-unparseable site.json must throw (naming the file), not
// resolve every module to default policy while validate stays green.
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-badjson-"));
  writeFileSync(join(tmp, "site.json"), "{ this is not json", "utf8");
  writeFileSync(
    join(tmp, "m.json"),
    JSON.stringify({ vmname: "m", vmid: 300, dependsOn: ["cluster:vm", "backup:vm"] }),
    "utf8",
  );
  let threw = false;
  try {
    resolvePolicy(tmp, "m");
  } catch (e) {
    threw = e instanceof Error && e.message.includes("site.json");
  }
  check(threw, "resolvePolicy throws a clean error naming a malformed site.json");
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

// ── ADR-012 §3.2: the schedule cascade and its once/day ceiling ───────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-schedule-"));
  mkdirSync(join(tmp, "environments"), { recursive: true });
  const site = (o: unknown) => writeFileSync(join(tmp, "site.json"), JSON.stringify(o), "utf8");
  const env = (n: string, o: unknown) =>
    writeFileSync(join(tmp, "environments", `${n}.json`), JSON.stringify(o), "utf8");
  const mod = (n: string, o: unknown) => writeFileSync(join(tmp, `${n}.json`), JSON.stringify(o), "utf8");

  site({});
  env("prod", {});
  mod("app", { kind: "module", environment: "prod", dependsOn: ["backup:vm"] });
  eq(resolvePolicy(tmp, "app").schedule, "daily", "schedule defaults to daily");
  eq(resolvePolicy(tmp, "app").scheduleBucket, "daily", "…and to the daily bucket");

  site({ backup: { defaultSchedule: "weekly" } });
  eq(resolvePolicy(tmp, "app").schedule, "weekly", "site default applies when nothing overrides");

  env("prod", { backup: { schedule: "daily" } });
  eq(resolvePolicy(tmp, "app").schedule, "daily", "environment overrides the site");

  mod("app", { kind: "module", environment: "prod", dependsOn: ["backup:vm"], backup: { schedule: "monthly" } });
  eq(resolvePolicy(tmp, "app").schedule, "monthly", "module overrides the environment");
  eq(resolvePolicy(tmp, "app").scheduleBucket, "monthly", "…into the monthly bucket");

  // The ceiling: unsupported specs classify to null so validate can reject them
  // by name, rather than being rounded down to daily behind the operator's back.
  for (const bad of ["hourly", "*:00", "06,18:00", "mon,thu 06:00", "24:00", "9:00"]) {
    mod("app", { kind: "module", dependsOn: ["backup:vm"], backup: { schedule: bad } });
    eq(resolvePolicy(tmp, "app").scheduleBucket, null, `'${bad}' is not a supported schedule`);
  }
  for (const good of ["daily", "weekly", "monthly", "21:00", "00:00", "23:59", "Weekly"]) {
    mod("app", { kind: "module", dependsOn: ["backup:vm"], backup: { schedule: good } });
    check(resolvePolicy(tmp, "app").scheduleBucket !== null, `'${good}' is a supported schedule`);
  }

  // validate reports the ceiling breach as an ERROR naming the module.
  site({ backup: { target: "backup.mgmt.internal" } });
  mod("app", { kind: "module", vmid: 900, dependsOn: ["backup:vm"], backup: { schedule: "hourly" } });
  const res = validate(tmp);
  check(
    res.errors.some((e) => e.includes("app") && e.includes("hourly")),
    "validate rejects a sub-daily schedule, naming the module and the spec",
  );
}

// ── vmid is a NUMBER in a deployed config, a string in fixtures ───────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-vmid-"));
  writeFileSync(join(tmp, "numeric.json"), JSON.stringify({ kind: "module", vmid: 340 }), "utf8");
  writeFileSync(join(tmp, "stringy.json"), JSON.stringify({ kind: "module", vmid: "341" }), "utf8");
  writeFileSync(join(tmp, "none.json"), JSON.stringify({ kind: "module" }), "utf8");
  eq(moduleVmid(tmp, "numeric"), "340", "a numeric vmid resolves (what deployed configs write)");
  eq(moduleVmid(tmp, "stringy"), "341", "a string vmid still resolves");
  eq(moduleVmid(tmp, "none"), null, "a module with no vmid resolves to null");
  eq(moduleVmid(tmp, "absent"), null, "a missing config resolves to null");
}

// ── #544: discovery is shape-based, not a deny-list ───────────────────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-discovery-"));
  const w = (f: string, o: unknown) =>
    writeFileSync(join(tmp, f), typeof o === "string" ? o : JSON.stringify(o), "utf8");

  // Real modules — including a provider-only one with no vmid/vmname.
  w("nextcloud.json", { kind: "module", vmname: "nextcloud", vmid: "340", dependsOn: ["backup:vm"] });
  w("tappaas-cicd.json", { kind: "module", vmname: "tappaas-cicd", vmid: "130", integratesWith: ["backup:vm"] });
  w("templates.json", { provides: ["nixos", "debian"] });
  w("unifi-os.json", { kind: "module", vmname: "unifi-os", vmid: "811", dependsOn: ["cluster:vm"] });

  // The files #544 is about: state and cache files that a deny-list had to
  // know about by name, and so classified as modules the moment one was added.
  w("last-update-result.json", { started: "2026-09-09", modules: 12, failed: 0 });
  w("zones.effective.json", { mgmt: { vlan: 1 } });
  w("module-fields.json", { fields: {} });
  w("site.json", { name: "rossen" });
  w("nextcloud.json.orig", { kind: "module", vmname: "nextcloud" });
  w("broken.json", "{ not valid json");
  w("array.json", [1, 2, 3]);
  // Off-site peers are peers, not modules.
  w("remote-buddy.json", { remoteHost: "h1" });
  w("push-vault.json", { remoteHost: "h3" });

  const found = listModules(tmp);
  eq(found.join(","), "nextcloud,tappaas-cicd,templates,unifi-os", "only real modules are discovered");
  check(!found.includes("last-update-result"), "#544: a run-result file is not a module");
  check(!found.includes("zones.effective"), "#544: zone state is not a module");
  check(!found.includes("module-fields"), "#544: the schema cache is not a module");
  check(!found.includes("broken"), "unparseable JSON is skipped, not thrown on");
  check(!found.includes("array"), "a JSON array is not a module config");
  check(!found.includes("remote-buddy") && !found.includes("push-vault"), "peers are not modules");
  check(found.includes("templates"), "a provider-only module (no vmid/vmname) is still a module");

  // Target discovery narrows to the opted-in set.
  eq(listBackupModules(tmp).join(","), "nextcloud,tappaas-cicd", "backup targets = modules that opted in");
  check(!listBackupModules(tmp).includes("unifi-os"), "a module declaring neither is not a backup target");
}

// ── ADR-012 D18: PBS-job membership is dependsOn OR integratesWith ────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-membership-"));
  const mod = (name: string, o: Record<string, unknown>) =>
    writeFileSync(join(tmp, `${name}.json`), JSON.stringify({ vmname: name, vmid: "900", ...o }), "utf8");

  mod("app", { dependsOn: ["backup:vm"] });
  mod("mothership", { dependsOn: ["cluster:vm"], integratesWith: ["backup:vm"] });
  mod("hardware", { dependsOn: ["cluster:vm"] });
  mod("other", { dependsOn: ["backup:filesystem"], integratesWith: ["network:proxy"] });

  check(moduleInPbsJob(tmp, "app"), "dependsOn backup:vm is in the job");
  check(moduleInPbsJob(tmp, "mothership"), "integratesWith backup:vm is in the job (#501, D18)");
  check(!moduleInPbsJob(tmp, "hardware"), "declaring neither stays OUT — backup is opt-in");
  check(!moduleInPbsJob(tmp, "other"), "an unrelated integration does not opt a module in");
  check(!moduleInPbsJob(tmp, "absent"), "a module with no config is not in the job");
}

// ── ADR-012: placement + off-site peers ───────────────────────────────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-placement-"));
  // Default (no backup.json) → unresolved / defaults.
  const def = readPlacement(tmp);
  eq(def.placementState, null, "placementState null when unset");
  eq(def.kind, "unresolved", "kind unresolved when unset");
  eq(def.node, null, "node null when unresolved");
  eq(def.pbsUrl, "backup.mgmt.internal", "pbsUrl default");
  eq(def.pbsStorageName, "tappaas_backup", "pbsStorageName default");
  eq(def.pushTarget, null, "pushTarget null default");

  const writeBackup = (o: Record<string, unknown>) =>
    writeFileSync(join(tmp, "backup.json"), JSON.stringify(o), "utf8");

  // node:<name> — a local PBS; the resolved node comes from the state itself.
  writeBackup({ placementState: "node:tappaas3", storage: "tankc1", node: "" });
  let pl = readPlacement(tmp);
  eq(pl.placementState, "node:tappaas3", "placementState read");
  eq(pl.kind, "local", "node:<name> classifies as local");
  eq(pl.node, "tappaas3", "resolved node parsed out of the state");

  // shim — no datastore anywhere.
  writeBackup({ placementState: "shim" });
  pl = readPlacement(tmp);
  eq(pl.kind, "shim", "shim classifies as shim");
  eq(pl.node, null, "shim has no node");

  // external — a datastore elsewhere, named by pbsUrl.
  writeBackup({ placementState: "external", pbsUrl: "pbs.offsite.example" });
  pl = readPlacement(tmp);
  eq(pl.kind, "external", "external classifies as external");
  eq(pl.pbsUrl, "pbs.offsite.example", "pbsUrl read");

  // Legacy v0.2 states still read honestly until the module's next update
  // migrates them (§4.1): local → local (node from the legacy .node),
  // remote-only → external.
  writeBackup({ placementState: "local", node: "tappaas3", pbsStorageName: "pbs" });
  pl = readPlacement(tmp);
  eq(pl.kind, "local", "legacy local classifies as local");
  eq(pl.node, "tappaas3", "legacy local takes its node from .node");
  eq(pl.pbsStorageName, "pbs", "pbsStorageName override read");

  writeBackup({ placementState: "remote-only", pushTarget: "offsite" });
  pl = readPlacement(tmp);
  eq(pl.kind, "external", "legacy remote-only classifies as external");
  eq(pl.pushTarget, "offsite", "deprecated pushTarget still read");

  writeBackup({ placementState: "shim" });

  // No peers yet.
  eq(listPeers(tmp).length, 0, "no peers when none configured");
  // One of each role — pull/receive/push.
  writeFileSync(join(tmp, "remote-buddy.json"), JSON.stringify({ remoteHost: "h1", namespace: "remote/buddy" }), "utf8");
  writeFileSync(join(tmp, "external-nas.json"), JSON.stringify({ remoteHost: "h2", namespace: "external/nas" }), "utf8");
  writeFileSync(join(tmp, "push-vault.json"), JSON.stringify({ remoteHost: "h3", namespace: "external/mysite" }), "utf8");
  const peers = listPeers(tmp);
  eq(peers.length, 3, "three peers listed");
  eq(peers.filter((p) => p.role === "pull").length, 1, "one pull peer (remote-)");
  eq(peers.filter((p) => p.role === "receive").length, 1, "one receive peer (external-)");
  eq(peers.filter((p) => p.role === "push").length, 1, "one push peer (push-)");
  eq(peers.find((p) => p.role === "push")?.name ?? "", "vault", "push peer name stripped of prefix");
  // Peers are NOT counted as modules.
  eq(listModules(tmp).length, 0, "peers/backup are not deployed modules");
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
