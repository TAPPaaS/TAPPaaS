// cascade.test.ts — offline unit tests for the backup-manager TS port. No PBS,
// no cluster; pure config reads over the fixture tree under test/fixtures/config,
// plus a FakeClient for the controller-facing paths. Tiny assert harness (no
// framework), mirroring identity-manager/test/unit/reconcile.test.ts. Run via the
// test/unit tsconfig.

import { join } from "path";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import {
  listEnvironments,
  listBackupModules,
  listModules,
  listPeers,
  moduleEnvironment,
  moduleArchived,
  moduleOptedIntoVmBackup,
  moduleVmid,
  readPlacement,
  resolvePolicy,
} from "../../src/config";
import { retentionValid, validate } from "../../src/validate";
import { asPlace, offsiteTargets, separation } from "../../src/offsite";
import { placementFinishReset, placementReset, urlHost } from "../../src/placement-reset";
import { applyPlan, computePlan, jobBucketIndex } from "../../src/reconcile";
import { restoreList, restoreRun } from "../../src/restore";
import {
  buildPeerConfig,
  findPeer,
  findPeers,
  normalizeKind,
  peerScript,
  removePeerConfig,
  writePeerConfig,
} from "../../src/peers";
import { addToBackupJob, modifyBackup, removeFromBackupJob } from "../../src/modify";
import { FakeClient } from "./fake-client";
import { HELP, run } from "../../src/main";
import { undocumentedOptions } from "../../../../lib/ts/src/help";

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
check(moduleOptedIntoVmBackup(FIX, "nextcloud"), "nextcloud opted in (dependsOn backup:vm)");
check(!moduleOptedIntoVmBackup(FIX, "scratch"), "scratch has NOT opted into backup");
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
    buckets: [{ bucket: "daily", jobId: "tappaas-backup", vmids: ["201"] }],
    reachable: true,
  });
  check(
    !plan.actions.some((a) => a.kind === "ensure-job-member"),
    "reconcile skips ensure-job-member when vmid already covered (idempotent)",
  );
  // #627 legacy fallback: a controller that predates `.buckets` reports only
  // the daily vmid list. The manager must still see that member, or a manager
  // newer than its controller re-adds every module on every reconcile.
  const legacy = computePlan(FIX, {
    jobId: "tappaas-backup",
    vmids: ["201"],
    storage: "tappaas_backup",
    buckets: [],
    reachable: true,
  });
  check(
    !legacy.actions.some((a) => a.kind === "ensure-job-member"),
    "reconcile honours a pre-buckets controller's daily vmid list (back-compat)",
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
  const plan = computePlan(FIX, {
    jobId: null,
    vmids: [],
    storage: null,
    buckets: [],
    reachable: false,
  });
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

// ── peer CRUD (ADR-012 §1.4): the three PBS relationships ────────────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-peers-"));
  writeFileSync(join(tmp, "site.json"), JSON.stringify({ name: "mysite" }), "utf8");

  eq(normalizeKind("pull"), "pull", "kind: pull — we pull theirs");
  eq(normalizeKind("remote"), "remote", "kind: remote — they pull ours");
  eq(normalizeKind("receive"), "receive", "kind: receive — they push into ours");
  eq(normalizeKind("push"), null, "there is no 'push' kind: we never push to another PBS");
  eq(normalizeKind("external"), null, "'external' is a PLACEMENT, not a peer");

  // PULL: we hold a read-only login on them, so no secret here; removeVanished
  // stays false — a compromised source must not make our copy disappear.
  writePeerConfig(tmp, "pull", { name: "buddy", host: "pbs.buddy", groupFilter: "type:vm" });
  const pull = JSON.parse(readFileSync(join(tmp, "pull-buddy.json"), "utf8"));
  eq(pull.namespace, "pull/buddy", "pull lands in pull/<peer> on our datastore");
  eq(pull.readAuthId, "", "pull config carries no credential");
  eq(pull.removeVanished, false, "pull never removes vanished — a source cannot erase our copy");
  eq(pull.groupFilter, "type:vm", "pull subset selector is written through");

  // REMOTE: they pull OUR backups. No namespace of ours is created — this is a
  // read grant on data we already hold, and it must not propagate.
  writePeerConfig(tmp, "remote", { name: "buddy", authId: "buddy@pbs" });
  const remote = JSON.parse(readFileSync(join(tmp, "remote-buddy.json"), "utf8"));
  eq(remote.authId, "buddy@pbs", "remote records the login they pull with");
  eq(remote.namespace, "", "remote defaults to the ROOT namespace — our VM backups");
  eq(
    remote.propagate,
    false,
    "remote does NOT propagate: a root grant would otherwise expose fs/ (config + secrets) and other peers",
  );
  check(remote.retention === undefined, "remote owns no retention — the copy is on their datastore");

  writePeerConfig(tmp, "remote", { name: "wide", authId: "w@pbs", propagate: true });
  eq(
    JSON.parse(readFileSync(join(tmp, "remote-wide.json"), "utf8")).propagate,
    true,
    "…but propagation can be asked for explicitly",
  );

  // RECEIVE: they push into us; we issue the login and own the retention.
  writePeerConfig(tmp, "receive", { name: "synology" });
  const recv = JSON.parse(readFileSync(join(tmp, "receive-synology.json"), "utf8"));
  eq(recv.namespace, "receive/synology", "receive lands in receive/<peer>");
  check(recv.retention !== undefined, "receive owns its retention (the data is on our datastore)");

  // One name, two relationships — the buddy pair. This is why delete needs the kind.
  eq(
    findPeers(tmp, "buddy").map((p) => p.kind).sort().join(","),
    "pull,remote",
    "a buddy is both: we pull theirs and they pull ours",
  );
  eq(findPeer(tmp, "pull", "buddy")?.kind ?? "none", "pull", "findPeer locates one relationship");
  eq(findPeer(tmp, "receive", "buddy"), null, "…and does not match a different kind");

  let threw = false;
  try {
    writePeerConfig(tmp, "pull", { name: "buddy", host: "other" });
  } catch {
    threw = true;
  }
  check(threw, "an existing peer is not silently overwritten");
  writePeerConfig(tmp, "pull", { name: "buddy", host: "other" }, true);
  eq(
    JSON.parse(readFileSync(join(tmp, "pull-buddy.json"), "utf8")).remoteHost,
    "other",
    "--force overwrites deliberately",
  );

  eq(removePeerConfig(tmp, "remote", "buddy").kind, "remote", "delete targets the named kind");
  eq(
    findPeers(tmp, "buddy").map((p) => p.kind).join(","),
    "pull",
    "…and leaves the other relationship intact",
  );

  check(
    peerScript("/mod", "pull", "onboard").endsWith("/mod/scripts/pull/onboard.sh"),
    "peer scripts resolve under <module>/scripts/<kind>/",
  );
  check(
    peerScript("/mod", "remote", "offboard").endsWith("/mod/scripts/remote/offboard.sh"),
    "…and offboard likewise",
  );
}

// ── restore: finds its script, and fails loudly when it cannot ────────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-restore-"));
  const modDir = join(tmp, "modsrc");
  mkdirSync(modDir, { recursive: true });
  const script = join(modDir, "restore.sh");
  writeFileSync(script, "#!/usr/bin/env bash\necho restored\n", "utf8");
  chmodSync(script, 0o755);   // spawning a non-executable file fails with EACCES

  // The module's own config says where it lives — the only answer that works
  // from the installed binary, whose __dirname is under /nix/store.
  writeFileSync(join(tmp, "backup.json"), JSON.stringify({ location: modDir }), "utf8");
  writeFileSync(join(tmp, "app.json"), JSON.stringify({ kind: "module", vmid: 340 }), "utf8");

  const prevEnv = process.env.RESTORE_SH;
  delete process.env.RESTORE_SH;
  const client = new FakeClient();
  const rc = restoreRun({ client, configDir: tmp }, "app", []);
  check(rc === 0, "restore resolves restore.sh from the module's declared location");

  // With the location pointing nowhere, this must FAIL — not print what it
  // would have done and exit 0, which is how a broken restore reads as success.
  writeFileSync(join(tmp, "backup.json"), JSON.stringify({ location: join(tmp, "gone") }), "utf8");
  process.env.RESTORE_SH = join(tmp, "gone", "restore.sh");
  const rcMissing = restoreRun({ client, configDir: tmp }, "app", []);
  check(rcMissing !== 0, "a missing restore.sh is a non-zero failure, never a silent success");
  if (prevEnv === undefined) delete process.env.RESTORE_SH;
  else process.env.RESTORE_SH = prevEnv;
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

  // #611: `kind` names the workload (ADR-022f). A config that authors one is a
  // module even with no other signal; the legacy marker alone still is —
  // migration 0004 keeps it exactly there so the module does not vanish; and an
  // unknown kind with no shape is not a module.
  w("vm-only.json", { kind: "vm" });
  w("marker-only.json", { kind: "module", vmid: "202" });
  w("odd-kind.json", { kind: "spaceship" });
  const f611 = listModules(tmp);
  check(f611.includes("vm-only"), "#611: an authored workload kind makes a module");
  check(f611.includes("marker-only"), "#611: the legacy marker alone still makes a module");
  check(!f611.includes("odd-kind"), "#611: an unknown kind is not a module signal");
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

  check(moduleOptedIntoVmBackup(tmp, "app"), "dependsOn backup:vm opts in");
  check(moduleOptedIntoVmBackup(tmp, "mothership"), "integratesWith backup:vm opts in (#501, D18)");
  check(!moduleOptedIntoVmBackup(tmp, "hardware"), "declaring neither stays OUT — backup is opt-in");
  check(!moduleOptedIntoVmBackup(tmp, "other"), "an unrelated integration does not opt a module in");
  check(!moduleOptedIntoVmBackup(tmp, "absent"), "a module with no config has not opted in");
}

// ── #627: the declaration is not job membership ───────────────────────
// `IN-PBS-JOB` was computed from dependsOn/integratesWith and never read the
// job. Both directions diverge; the dangerous half is false-true — reporting a
// module as backed up when no snapshot can be taken.
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-627-"));
  const mod = (name: string, o: Record<string, unknown>) =>
    writeFileSync(join(tmp, `${name}.json`), JSON.stringify({ vmname: name, ...o }), "utf8");

  // live:     declared, in the daily job          → member
  // weekly:   declared, in the WEEKLY job         → member (the bucket blind spot)
  // gone:     declared but archived, VM destroyed → NOT a member, and intended
  // pending:  declared, job has not caught up yet → NOT a member (bootstrap gap)
  mod("live", { vmid: 340, dependsOn: ["backup:vm"] });
  mod("weekly", { vmid: 341, dependsOn: ["backup:vm"], backup: { schedule: "weekly" } });
  mod("gone", { vmid: 411, status: "archived", dependsOn: ["backup:vm"] });
  mod("pending", { vmid: 500, integratesWith: ["backup:vm"] });

  check(moduleArchived(tmp, "gone"), "status=archived is read off the config");
  check(!moduleArchived(tmp, "live"), "a live module is not archived");
  check(moduleOptedIntoVmBackup(tmp, "gone"), "an archived module still DECLARES backup:vm");

  const fake = new FakeClient();
  fake.seedBucket("daily", ["340"]);
  fake.seedBucket("weekly", ["341"]);
  const idx = jobBucketIndex(fake.jobStatus());
  eq(idx.get("340"), "daily", "membership resolves from the daily job");
  eq(idx.get("341"), "weekly", "membership resolves from the WEEKLY job too (#627)");
  eq(idx.get("411"), undefined, "an archived module's destroyed VM is in no job");
  eq(idx.get("500"), undefined, "a declared-but-not-yet-added VM is in no job");

  // reconcile must not re-add the archived module: delete-service.sh removed
  // its VMID on purpose, and vzdump errors on a job naming a missing guest.
  const plan = computePlan(tmp, fake.jobStatus());
  check(
    !plan.actions.some((a) => a.target.includes("'gone'")),
    "reconcile does NOT re-add an archived module (#627)",
  );
  check(
    plan.actions.some((a) => a.target.includes("'pending'")),
    "reconcile still adds a declared module the job has not caught up with",
  );
  check(
    !plan.actions.some((a) => a.target.includes("'weekly'")),
    "reconcile leaves a correctly-placed weekly member alone (no churn)",
  );

  // A member sitting in the WRONG bucket is a move, not a no-op.
  const moved = new FakeClient();
  moved.seedBucket("monthly", ["341"]);
  check(
    computePlan(tmp, moved.jobStatus()).actions.some(
      (a) => a.target.includes("'weekly'") && a.target.includes("weekly PBS job"),
    ),
    "reconcile moves a member out of the wrong bucket",
  );
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

  // §2.1 as decided (#600): placementState "node", the Host in .node.
  writeBackup({ placementState: "node", node: "dh-test1", storage: "tankc1" });
  pl = readPlacement(tmp);
  eq(pl.kind, "local", "#600: node + .node classifies as local");
  eq(pl.node, "dh-test1", "#600: the Host is .node (a machine instance here)");
  writeBackup({ placementState: "node", node: "" });
  eq(readPlacement(tmp).kind, "unresolved", "#600: node naming no Host is unresolved");

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
  // One of each role — pull (we take theirs), remote (they take ours),
  // receive (they push into ours).
  writeFileSync(join(tmp, "pull-buddy.json"), JSON.stringify({ remoteHost: "h1", namespace: "pull/buddy" }), "utf8");
  writeFileSync(join(tmp, "remote-buddy.json"), JSON.stringify({ authId: "buddy@pbs" }), "utf8");
  writeFileSync(join(tmp, "receive-nas.json"), JSON.stringify({ namespace: "receive/nas" }), "utf8");
  const peers = listPeers(tmp);
  eq(peers.length, 3, "three peers listed");
  eq(peers.filter((p) => p.role === "pull").length, 1, "one pull peer (pull-)");
  eq(peers.filter((p) => p.role === "remote").length, 1, "one remote peer (remote-)");
  eq(peers.filter((p) => p.role === "receive").length, 1, "one receive peer (receive-)");
  eq(peers.find((p) => p.role === "receive")?.name ?? "", "nas", "peer name stripped of prefix");
  // Peers are NOT counted as modules.
  eq(listModules(tmp).length, 0, "peers/backup are not deployed modules");
}

// ── #609: an off-site copy is recorded, not asserted ─────────────────
{
  const DK = { country: "DK", city: "Aarhus" };
  eq(separation(DK, null), "unrecorded", "no physicalLocation → unrecorded");
  eq(separation(DK, { country: "DE" }), "separate", "another country → separate");
  eq(separation(DK, { country: "dk", city: "Odense" }), "separate", "same country, other city → separate (case-insensitive)");
  eq(separation({ country: "DK" }, { country: "DK", city: "Odense" }), "unproven", "the Site records no city → unproven");
  eq(separation(DK, { country: "DK", city: "aarhus" }), "unproven", "same city, no building → unproven");
  eq(separation({ ...DK, building: "A" }, { ...DK, building: "B" }), "separate", "same city, other building → separate");
  eq(separation({ ...DK, building: "A" }, { ...DK, building: "a" }), "same", "every level equal → same");
  eq(asPlace({ city: "Aarhus" }), null, "a place without a country is not recorded");

  const tmp = mkdtempSync(join(tmpdir(), "bm-offsite-"));
  writeFileSync(join(tmp, "site.json"), JSON.stringify({ name: "s", location: { country: "DK", timezone: "Europe/Copenhagen" } }));
  writeFileSync(join(tmp, "satellite-hel.json"), JSON.stringify({ kind: "machine", physicalLocation: { country: "FI", city: "Helsinki" } }));
  writeFileSync(join(tmp, "remote-buddy.json"), JSON.stringify({ authId: "buddy@pbs" }));
  writeFileSync(join(tmp, "pull-neighbour.json"), JSON.stringify({ remoteHost: "h", physicalLocation: { country: "DK" } }));
  writeFileSync(join(tmp, "receive-nas.json"), JSON.stringify({ namespace: "receive/nas" }));
  const t = offsiteTargets(tmp);
  eq(t.map((x) => `${x.role}:${x.name}:${x.separation}`).join(" "),
    "pull:neighbour:unproven remote:buddy:unrecorded satellite:hel:separate",
    "satellites, remote and pull peers are off-site targets; receive peers are not");
  const w = validate(tmp).warnings;
  eq(w.length, 2, "validate warns once per target not shown to be away");
  check(w.some((x) => x.includes("remote 'buddy'") && x.includes("records no physicalLocation")), "…naming the unrecorded one");
  check(w.some((x) => x.includes("pull 'neighbour'") && x.includes("record the city")), "…and saying what would settle the other");
  eq(validate(tmp).errors.filter((e) => e.includes("physicalLocation")).length, 0, "…as warnings, never errors");
  eq(listPeers(tmp).find((p) => p.name === "neighbour")?.physicalLocation?.country ?? "", "DK", "peers carry their physicalLocation");

  eq(JSON.stringify(buildPeerConfig("remote", { name: "b", authId: "b@pbs", physicalLocation: { country: "DE", city: "Berlin" } }).physicalLocation),
    '{"country":"DE","city":"Berlin"}', "peer add records the place it is given");
  eq(buildPeerConfig("pull", { name: "b", host: "h" }).physicalLocation, undefined, "…and invents none");
}

// ── #607: placement reset — the one door out of `external` ───────────
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-reset-"));
  const mod = join(tmp, "backupmod");
  const bj = join(tmp, "backup.json");
  const ext = { placementState: "external", pbsUrl: "https://pbs.lan.example:8007", pbsStorageName: "tappaas_backup" };
  type Call = { bin: string; args: string[] };
  const mk = (opts: { confirm?: boolean; updateRc?: number; updateLeaves?: string; resetRc?: number } = {}) => {
    const calls: Call[] = [];
    const msgs: string[] = [];
    const deps = {
      run: (bin: string, args: string[]): number => {
        calls.push({ bin, args });
        if (bin.endsWith("backup-manage.sh") && args[0] === "reset-external") {
          if (opts.resetRc) return opts.resetRc;
          // what the bash side does to backup.json
          const b = JSON.parse(readFileSync(bj, "utf8"));
          b.formerExternal = { pbsUrl: b.pbsUrl, storage: "tappaas_backup_former", datastore: "store1", namespace: "", peer: "former-pbs" };
          b.placementState = "shim";
          b.pbsUrl = "backup.mgmt.internal";
          writeFileSync(bj, JSON.stringify(b));
        }
        if (bin === "update-module.sh") {
          const b = JSON.parse(readFileSync(bj, "utf8"));
          b.placementState = opts.updateLeaves ?? "node:tappaas2";
          writeFileSync(bj, JSON.stringify(b));
          return opts.updateRc ?? 0;
        }
        return 0;
      },
      confirm: (): boolean => opts.confirm ?? true,
      info: (m: string): void => void msgs.push(m),
      warn: (m: string): void => void msgs.push(`WARN ${m}`),
    };
    return { calls, msgs, deps };
  };
  const ro = (o: Partial<{ yes: boolean; noUpdate: boolean }> = {}) =>
    ({ configDir: tmp, moduleDir: mod, yes: o.yes ?? false, noUpdate: o.noUpdate ?? false });
  const fresh = (b: Record<string, unknown>) => {
    for (const f of ["pull-former-pbs.json"]) { try { unlinkSync(join(tmp, f)); } catch { /* none */ } }
    writeFileSync(bj, JSON.stringify(b));
  };

  fresh({ placementState: "node:tappaas3" });
  let t = mk();
  eq(placementReset(ro(), t.deps), 1, "reset refuses a placement that is not external");
  eq(t.calls.length, 0, "…and runs nothing");

  fresh(ext);
  t = mk({ confirm: false });
  eq(placementReset(ro(), t.deps), 1, "declining the confirmation stops it");
  eq(t.calls.length, 0, "…before anything runs");

  fresh(ext);
  t = mk({ resetRc: 1 });
  eq(placementReset(ro({ yes: true }), t.deps), 1, "a refused reset-external (no tankc) is passed on");
  eq(t.calls.length, 1, "…and nothing runs after it");
  check(!existsSync(join(tmp, "pull-former-pbs.json")), "…and no peer is written");

  fresh(ext);
  t = mk();
  eq(placementReset(ro({ yes: true }), t.deps), 0, "reset: the whole door, in order");
  eq(t.calls.map((c) => `${c.bin.split("/").slice(-2).join("/")} ${c.args.join(" ")}`).join(" | "),
    "scripts/backup-manage.sh reset-external | update-module.sh backup | pull/onboard.sh former-pbs",
    "reset-external → the update that promotes the shim → the pull onboarding");
  const peer = JSON.parse(readFileSync(join(tmp, "pull-former-pbs.json"), "utf8"));
  eq(`${peer.remoteHost} ${peer.remoteStore} ${peer.namespace}`, "pbs.lan.example store1 pull/former-pbs",
    "the old PBS becomes a pull peer: its host (not URL), its datastore, landing in pull/<peer>");
  check(t.msgs.some((m) => m.includes("placement finish-reset")), "…and says how to finish");

  fresh(ext);
  t = mk({ updateLeaves: "shim", updateRc: 0 });
  check(placementReset(ro({ yes: true }), t.deps) !== 0, "an update that leaves no local PBS is a failure");
  check(!t.calls.some((c) => c.bin.endsWith("onboard.sh")), "…the pull is not onboarded with nothing to pull into");
  check(t.msgs.some((m) => m.startsWith("WARN") && m.includes("NOTHING IS BACKED UP")), "…and it says loudly that nothing is backed up");

  fresh(ext);
  t = mk();
  eq(placementReset(ro({ yes: true, noUpdate: true }), t.deps), 0, "--no-update stops after the config");
  eq(t.calls.length, 1, "…running only reset-external");
  check(t.msgs.some((m) => m.startsWith("WARN") && m.includes("NOTHING IS BACKED UP")), "…with the warning that nothing is backed up yet");

  // A second reset while one is unfinished is refused.
  const b = JSON.parse(readFileSync(bj, "utf8"));
  b.placementState = "external";
  writeFileSync(bj, JSON.stringify(b));
  eq(placementReset(ro({ yes: true }), mk().deps), 1, "reset refuses while a formerExternal is unfinished");

  // finish-reset
  fresh({ placementState: "node:tappaas2" });
  t = mk();
  eq(placementFinishReset(ro({ yes: true }), t.deps), 1, "finish-reset refuses with no formerExternal");
  fresh({ placementState: "node:tappaas2", formerExternal: { storage: "tappaas_backup_former", pbsUrl: "pbs.lan", peer: "former-pbs" } });
  t = mk({ confirm: false });
  eq(placementFinishReset(ro(), t.deps), 1, "finish-reset: declining stops it");
  eq(t.calls.length, 0, "…with nothing run");
  t = mk();
  eq(placementFinishReset(ro({ yes: true }), t.deps), 0, "finish-reset runs");
  eq(t.calls.map((c) => c.args.join(" ")).join(" | "), "finish-reset", "…the module's finish-reset, nothing else");
  eq(urlHost("https://pbs.example:8007/x"), "pbs.example", "urlHost strips scheme, port and path");
}

// ── #644: --help runs nothing; an option the verb does not take is refused ──
// `key export <dest> --help` used to write the keys to <dest>.
{
  const call = (argv: string[]): { rc: number; out: string; err: string; log: string[] } => {
    const log = console.log;
    const error = console.error;
    let out = "";
    let err = "";
    console.log = (...a: unknown[]): void => {
      out += a.map(String).join(" ") + "\n";
    };
    console.error = (...a: unknown[]): void => {
      err += a.map(String).join(" ") + "\n";
    };
    const c = new FakeClient();
    try {
      const rc = run(argv, c);
      return { rc, out, err, log: c.log };
    } finally {
      console.log = log;
      console.error = error;
    }
  };
  for (const argv of [
    ["key", "export", "/mnt/usb", "--help"],
    ["reconcile", "--apply", "-h"],
    ["peer", "add", "remote", "buddy", "--auth-id", "us@pbs", "--help"],
    ["restore", "restore", "nextcloud", "--node", "tappaas2", "--help"],
  ]) {
    const r = call(argv);
    check(r.rc === 0 && r.out.includes("Usage:") && r.log.length === 0, `${argv.join(" ")}: help, rc 0, nothing run`);
  }
  check(call(["peer", "--help"]).out.includes("peer delete"), "peer --help lists the peer verbs");
  check(call(["restore", "restore", "x", "--help"]).out.includes("--target-vmid"), "restore restore --help lists restore.sh's options");
  for (const argv of [["reconcile", "--aply"], ["key", "export", "/mnt", "--force"], ["modify", "nextcloud", "--retention=90d"]]) {
    const r = call(argv);
    check(r.rc === 1 && r.err.includes("unknown option") && r.log.length === 0, `${argv.join(" ")}: refused, nothing run`);
  }
  check(undocumentedOptions(HELP).length === 0, `every usage option is described (${undocumentedOptions(HELP).join(", ")})`);
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
