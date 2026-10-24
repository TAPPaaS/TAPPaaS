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
import { asPlace, offsiteTargets, pbsOnSatelliteWarnings, separation } from "../../src/offsite";
import { placementFinishReset, placementReset, placementUseExternal, urlHost } from "../../src/placement-reset";
import { applyPlan, computePlan, jobBucketIndex } from "../../src/reconcile";
import { restoreArgs, restoreList, restoreRun, shapeRuns, targetKind, upidTime } from "../../src/restore";
import {
  buildPeerConfig,
  findPeer,
  findPeers,
  normalizeKind,
  peerScript,
  removePeerConfig,
  isEmail,
  setPeerContact,
  writePeerConfig,
} from "../../src/peers";
import { addToBackupJob, modifyBackup, removeFromBackupJob } from "../../src/modify";
import { FakeClient } from "./fake-client";
import { HELP, run } from "../../src/main";
import { keyStampArgs, keyTarget, keysUsb } from "../../src/keys";
import { undocumentedOptions } from "../../../../lib/ts/src/help";
import { allocateNet, allocatePort, buddyPool, nextServe, slash30Error, tunnelErrors, tunnelHosts } from "../../src/tunnel";

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

  // ADR-031 D5: the other site's operator, for the pulse's mail.
  writePeerConfig(tmp, "pull", { name: "buddy", host: "other", contact: "ops@buddy.example" }, true);
  eq(JSON.parse(readFileSync(join(tmp, "pull-buddy.json"), "utf8")).contact, "ops@buddy.example",
    "a pull records the buddy's contact");
  setPeerContact(tmp, "remote", "buddy", "them@buddy.example");
  eq(JSON.parse(readFileSync(join(tmp, "remote-buddy.json"), "utf8")).contact, "them@buddy.example",
    "peer modify sets a contact on an existing peer");
  setPeerContact(tmp, "remote", "buddy", "");
  check(JSON.parse(readFileSync(join(tmp, "remote-buddy.json"), "utf8")).contact === undefined,
    "…and an empty one clears it");
  check(isEmail("a@b.example") && !isEmail("a@b") && !isEmail("a@b.example,c@d.example") && !isEmail("x"),
    "a contact is one address — the pulse puts it in a To: line");

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

// ── --from: another guest's backup INTO this module's guest (#729, RESTORE.md §2) ──
{
  const known: Record<string, string> = { openwebui: "311", "openwebui-r": "921" };
  const resolve = (m: string) => known[m] ?? null;
  const args = (o: string[]) => {
    const r = restoreArgs("921", o, resolve);
    return "args" in r ? r.args.join(" ") : `ERROR ${r.error}`;
  };
  check(args([]) === "--vmid 921", "plain restore: the module's own backup, over its own guest");
  check(args(["--from", "openwebui"]) === "--vmid 311 --target-vmid 921 --replace",
    "--from a module: its backup is the source, THIS module's guest the destination");
  check(args(["--from", "4711", "--storage", "tanka1"]) === "--vmid 4711 --target-vmid 921 --replace --storage tanka1",
    "--from a bare VMID (a backup this config never had); other options pass through");
  check(args(["--from", "nope"]).startsWith("ERROR --from nope: no such module"),
    "an unknown module is refused, not guessed");
  check(args(["--from", "openwebui", "--target-vmid", "930"]).startsWith("ERROR --from restores INTO"),
    "--from and --target-vmid are refused together");
  check(args(["--from", "921"]).startsWith("ERROR --from 921 is this module's own VMID"),
    "--from its own VMID is refused");
  check(args(["--from"]).startsWith("ERROR --from needs"), "--from without a value is refused");
  // The destination can never be the source: the trap --from replaces was a
  // second --vmid, which restore.sh reads as source AND destination.
  check(!args(["--from", "openwebui"]).includes("--target-vmid 311"),
    "the source module's guest is never the destination");
  const onNode = (o: string[]) => {
    const r = restoreArgs("921", o, resolve, "tappaas2");
    return "args" in r ? r.args.join(" ") : `ERROR ${r.error}`;
  };
  check(onNode(["--from", "openwebui"]) === "--vmid 311 --target-vmid 921 --replace --node tappaas2",
    "--node defaults to the node the module is declared on");
  check(onNode(["--node", "tappaas3"]) === "--vmid 921 --node tappaas3",
    "an explicit --node wins");
  // #829: an in-place restore is confirmed with --yes, passed to restore.sh — not
  // turned into --replace, which restores ANOTHER guest and leaves it stopped.
  check(args(["--yes"]) === "--vmid 921 --yes", "--yes reaches restore.sh for an in-place restore");
  check(!args(["--yes"]).includes("--replace"), "…and is not turned into --replace");
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
  // Satellites (ADR-010 §8.4): a pre-§8.4 satellite-<name>.json and an instance
  // of the satellite module count when they hold a copy — the vault's backup
  // role, or being the Site's PBS Host; a relay holds none and does not count.
  const SAT = "/repo/src/foundation/satellite";
  writeFileSync(join(tmp, "satellite-hel.json"), JSON.stringify({ kind: "machine", roles: ["backup"], physicalLocation: { country: "FI", city: "Helsinki" } }));
  writeFileSync(join(tmp, "vault.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, roles: ["reverse-proxy", "backup"], physicalLocation: { country: "DE" } }));
  writeFileSync(join(tmp, "relay.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, roles: ["reverse-proxy", "admin-vpn"] }));
  writeFileSync(join(tmp, "pbshost.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, roles: ["reverse-proxy"] }));
  writeFileSync(join(tmp, "backup.json"), JSON.stringify({ placementState: "node", node: "pbshost" }));
  writeFileSync(join(tmp, "dh1.json"), JSON.stringify({ kind: "machine", moduleSource: "/repo/src/foundation/debianhost", roles: ["backup"] }));
  writeFileSync(join(tmp, "remote-buddy.json"), JSON.stringify({ authId: "buddy@pbs" }));
  writeFileSync(join(tmp, "remote-vault.json"), JSON.stringify({ authId: "vault@pbs", physicalLocation: { country: "DE" } })); // the vault's own grant: counted once
  writeFileSync(join(tmp, "pull-neighbour.json"), JSON.stringify({ remoteHost: "h", physicalLocation: { country: "DK" } }));
  writeFileSync(join(tmp, "receive-nas.json"), JSON.stringify({ namespace: "receive/nas" }));
  const t = offsiteTargets(tmp);
  eq(t.map((x) => `${x.role}:${x.name}:${x.separation}`).join(" "),
    "satellite:pbshost:unrecorded pull:neighbour:unproven remote:buddy:unrecorded satellite:satellite-hel:separate satellite:vault:separate",
    "satellites holding a copy, remote and pull peers are off-site targets; a relay satellite, a non-satellite and receive peers are not");
  const w = validate(tmp).warnings;
  eq(w.length, 3, "validate warns once per target not shown to be away");
  check(w.some((x) => x.includes("satellite 'pbshost'") && x.includes("names no location") && x.includes("module modify pbshost --set location=")), "…the satellite that is the PBS Host included, with the fix");
  check(w.some((x) => x.includes("remote 'buddy'") && x.includes("names no location")), "…naming the unrecorded one");
  check(w.some((x) => x.includes("pull 'neighbour'") && x.includes("record the city")), "…and saying what would settle the other");
  eq(validate(tmp).errors.filter((e) => e.includes("physicalLocation") || e.includes("location")).length, 0, "…as warnings, never errors");
  eq(listPeers(tmp).find((p) => p.name === "neighbour")?.place?.country ?? "", "DK", "a peer migration 0019 has not reached shows its physicalLocation as its place");

  // ADR-010 §8.4.3: a PBS on a managed satellite warns until something home
  // cannot reach pulls it — a locked-down satellite (the vault) or a remote peer.
  {
    const d = mkdtempSync(join(tmpdir(), "bm-satpbs-"));
    writeFileSync(join(d, "backup.json"), JSON.stringify({ placementState: "node", node: "sat1" }));
    writeFileSync(join(d, "sat1.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, management: "managed", roles: ["reverse-proxy"] }));
    eq(pbsOnSatelliteWarnings(d).length, 1, "a PBS on a satellite with nothing pulling it elsewhere warns");
    check(validate(d).warnings.some((x) => x.includes("no copy home cannot reach")), "…through validate");
    writeFileSync(join(d, "vault.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, management: "managed", roles: ["backup"] }));
    eq(pbsOnSatelliteWarnings(d).length, 1, "…a vault that is still managed is not one (home can reach it)");
    writeFileSync(join(d, "vault.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, management: "unmanaged", roles: ["backup"] }));
    eq(pbsOnSatelliteWarnings(d).length, 0, "…a locked-down vault settles it");
    unlinkSync(join(d, "vault.json"));
    writeFileSync(join(d, "remote-buddy.json"), JSON.stringify({ authId: "buddy@pbs" }));
    eq(pbsOnSatelliteWarnings(d).length, 0, "…so does a remote peer pulling it");
    writeFileSync(join(d, "backup.json"), JSON.stringify({ placementState: "node", node: "tappaas3" }));
    unlinkSync(join(d, "remote-buddy.json"));
    eq(pbsOnSatelliteWarnings(d).length, 0, "a PBS on a cluster node is not this case");
  }

  eq(buildPeerConfig("remote", { name: "b", authId: "b@pbs", location: "berlin" }).location, "berlin", "peer add records the location it is given");
  eq(buildPeerConfig("pull", { name: "b", host: "h" }).location, undefined, "…and invents none");
}

// ── ADR-036 D5: a peer names a location; the Site is its primary location ──
{
  const tmp = mkdtempSync(join(tmpdir(), "bm-locations-"));
  writeFileSync(join(tmp, "site.json"), JSON.stringify({
    name: "rossen", primaryLocation: "rodovre", keyboard: "dk",
    locations: {
      rodovre: { country: "DK", city: "Rodovre", address: "Hus 2", timezone: "Europe/Copenhagen" },
      hareskov: { kind: "remote", displayName: "Rasmus", country: "DK", city: "Hareskov" },
      nextdoor: { kind: "remote", country: "DK", city: "Rodovre", address: "Hus 4" },
      sameplace: { kind: "remote", country: "DK", city: "Rodovre", address: "hus 2" },
    },
  }));
  writeFileSync(join(tmp, "remote-rasmus.json"), JSON.stringify({ authId: "r@pbs", location: "hareskov" }));
  writeFileSync(join(tmp, "pull-neighbour.json"), JSON.stringify({ remoteHost: "h", location: "nextdoor" }));
  writeFileSync(join(tmp, "pull-home.json"), JSON.stringify({ remoteHost: "h2", location: "rodovre" }));
  writeFileSync(join(tmp, "pull-twin.json"), JSON.stringify({ remoteHost: "h3", location: "sameplace" }));
  writeFileSync(join(tmp, "pull-ghost.json"), JSON.stringify({ remoteHost: "h4", location: "atlantis" }));
  const t = offsiteTargets(tmp);
  eq(t.map((x) => `${x.name}:${x.location}:${x.separation}`).join(" "),
    "ghost:atlantis:unrecorded home:rodovre:same neighbour:nextdoor:separate twin:sameplace:same rasmus:hareskov:separate",
    "each peer is judged by the location it names against the primary one");
  const w = validate(tmp).warnings;
  check(w.some((x) => x.includes("pull 'home'") && x.includes("location 'rodovre'") && x.includes("the Site's own place")), "naming the primary location is not off-site");
  check(w.some((x) => x.includes("pull 'twin'") && x.includes("the Site's own place")), "…nor is a location at the same address");
  check(w.some((x) => x.includes("pull 'ghost'") && x.includes("which site.json does not have")), "a location site.json lacks is named");
  check(!w.some((x) => x.includes("'rasmus'") || x.includes("'neighbour'")), "another city, or another address in the same city, is off-site");
  const rasmus = listPeers(tmp).find((p) => p.name === "rasmus");
  eq(JSON.stringify([rasmus?.location, rasmus?.place]), '["hareskov",{"country":"DK","displayName":"Rasmus","city":"Hareskov"}]', "peers list the location and its place");

  // peer add: --location names one; --country finds or makes one; not both.
  const out: string[] = [];
  const call = (argv: string[]): number => {
    const log = console.log;
    const error = console.error;
    console.log = (m: string) => void out.push(String(m));
    console.error = (m: string) => void out.push(String(m));
    try {
      return run([...argv, "--config-dir", tmp, "--config-only"], new FakeClient());
    } finally {
      console.log = log;
      console.error = error;
    }
  };
  const cfg = (f: string) => JSON.parse(readFileSync(join(tmp, f), "utf8"));
  eq(call(["peer", "add", "remote", "erik", "--auth-id", "e@pbs", "--location", "hareskov"]), 0, "peer add --location");
  eq(cfg("remote-erik.json").location, "hareskov", "…the peer names it");
  check(!("physicalLocation" in cfg("remote-erik.json")), "…and records no physicalLocation");
  check(call(["peer", "add", "remote", "x", "--auth-id", "x@pbs", "--location", "atlantis"]) !== 0, "…a location the site lacks is refused");
  check(call(["peer", "add", "remote", "x", "--auth-id", "x@pbs", "--location", "hareskov", "--country", "DK"]) !== 0, "…and so is --location with --country");
  eq(call(["peer", "add", "pull", "bo", "--host", "h", "--country", "dk", "--city", "hareskov"]), 0, "peer add --country --city at a place the site has");
  eq(cfg("pull-bo.json").location, "hareskov", "…names that location");
  eq(call(["peer", "add", "pull", "cy", "--host", "h", "--country", "DE", "--city", "Berlin", "--building", "Haus 1"]), 0, "…at a new place");
  eq(cfg("pull-cy.json").location, "haus-1", "…names a new location after its building");
  eq(JSON.stringify(cfg("site.json").locations["haus-1"]), '{"displayName":"Haus 1","kind":"remote","country":"DE","city":"Berlin","address":"Haus 1"}', "…which site.json now has, kind remote");
  eq(cfg("site.json").primaryLocation, "rodovre", "…and the primary is where it was");
  eq(call(["peer", "add", "pull", "cy", "--host", "h", "--force"]), 0, "a --force re-add without a place");
  eq(cfg("pull-cy.json").location, "haus-1", "…keeps the location it had");

  // ADR-036 D2: a satellite names its location the way a peer does.
  const SAT = "/repo/src/foundation/satellite";
  writeFileSync(join(tmp, "vault.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, roles: ["backup"], location: "haus-1" }));
  writeFileSync(join(tmp, "homevault.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, roles: ["backup"], location: "rodovre" }));
  writeFileSync(join(tmp, "lostvault.json"), JSON.stringify({ kind: "machine", moduleSource: SAT, roles: ["backup"], location: "atlantis" }));
  writeFileSync(join(tmp, "oldvault.json"), JSON.stringify({ kind: "machine", location: `${SAT}`, roles: ["backup"] }));
  const sats = offsiteTargets(tmp).filter((x) => x.role === "satellite").map((x) => `${x.name}:${x.location ?? "-"}:${x.separation}`).join(" ");
  eq(sats, "homevault:rodovre:same lostvault:atlantis:unrecorded oldvault:-:unrecorded vault:haus-1:separate",
    "a satellite is judged by the location it names; a location with a '/' is the old directory field (it still makes the config a satellite)");
  const sw = validate(tmp).warnings;
  check(sw.some((x) => x.includes("satellite 'homevault'") && x.includes("the Site's own place")), "…the primary location is not off-site");
  check(sw.some((x) => x.includes("satellite 'lostvault'") && x.includes("which site.json does not have")), "…a location the site lacks is named");
  check(!sw.some((x) => x.includes("satellite 'vault'")), "…another country is off-site");
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

  // use-external (#456): one command, delegated whole to the module's script.
  t = mk();
  eq(placementUseExternal({ configDir: tmp, moduleDir: mod, url: "pbs.lan", datastore: "ds1", fingerprint: "aa:bb" }, t.deps), 0,
    "use-external runs");
  eq(t.calls.map((c) => `${c.bin.split("/").slice(-2).join("/")} ${c.args.join(" ")}`).join(" | "),
    "scripts/backup-manage.sh use-external pbs.lan --datastore ds1 --fingerprint aa:bb",
    "…as backup-manage.sh use-external, with its options");
  t = mk();
  eq(placementUseExternal({ configDir: tmp, moduleDir: mod, url: "" }, t.deps), 1, "use-external without a URL is refused");
  eq(t.calls.length, 0, "…and runs nothing");
}

// ── key export|import --usb | --file (the scripts are an implementation detail) ──
{
  const t = (v: "export" | "import", a: string[]) => {
    const r = keyTarget(v, a);
    return "error" in r ? `ERROR ${r.error}` : r.kind === "usb" ? `usb ${r.node ?? "-"}${r.format ? " format" : ""}` : `file ${r.dir}`;
  };
  eq(t("export", ["--usb"]), "usb -", "--usb: a stick in the default node");
  eq(t("export", ["--usb", "--node", "tappaas2"]), "usb tappaas2", "--usb --node: a stick in another node");
  eq(t("import", ["--file", "/tmp/k"]), "file /tmp/k", "--file <dir>");
  eq(t("export", ["/tmp/k"]), "file /tmp/k", "a bare directory is --file (the original form keeps working)");
  check(t("export", []).startsWith("ERROR key export: say where"), "neither: refused, naming both");
  check(t("export", ["--usb", "--file", "/x"]).includes("not both"), "both: refused");
  check(t("import", ["--file", "/x", "--node", "n"]).includes("--node goes with --usb"), "--node without --usb: refused");
  check(t("export", ["--file"]).includes("a directory is required"), "--file without a directory: refused");
  eq(t("export", ["--usb", "--format"]), "usb - format", "export --usb --format: erase even a key stick");
  check(t("import", ["--usb", "--format"]).includes("--format goes with export --usb"), "--format on import: refused");
  check(t("export", ["--file", "/x", "--format"]).includes("--format goes with export --usb"), "--format with --file: refused");

  // --usb runs the module's own script, on this terminal; a missing script is a failure.
  const tmp = mkdtempSync(join(tmpdir(), "bm-keys-"));
  const mod = join(tmp, "backup");
  mkdirSync(join(mod, "scripts"), { recursive: true });
  writeFileSync(join(tmp, "backup.json"), JSON.stringify({ moduleSource: mod }), "utf8");
  writeFileSync(join(mod, "scripts", "keys-to-usb.sh"), "#!/bin/sh\n", "utf8");
  const calls: string[] = [];
  const runner = (bin: string, args: string[]) => { calls.push(`${bin.split("/").slice(-2).join("/")} ${args.join(" ")}`.trim()); return 0; };
  eq(keysUsb("export", "tappaas2", tmp, runner), 0, "key export --usb runs");
  eq(calls.join(" | "), "scripts/keys-to-usb.sh --node tappaas2", "…as the module's keys-to-usb.sh, with the node");
  calls.length = 0;
  keysUsb("export", null, tmp, runner, true);
  eq(calls.join(" | "), "scripts/keys-to-usb.sh --format", "…and passes --format on");
  const errs: string[] = [];
  const origErr = console.error;
  console.error = (...x: unknown[]) => void errs.push(x.join(" "));
  try {
    check(keysUsb("import", null, tmp, runner) !== 0, "key import --usb without keys-from-usb.sh is a failure, not a no-op");
  } finally {
    console.error = origErr;
  }

  // --file still goes to the controller, as before.
  const c = new FakeClient();
  eq(run(["key", "export", "--file", "/media/k", "--config-dir", FIX], c), 0, "key export --file runs");
  eq(run(["key", "import", "/media/k", "--config-dir", FIX], c), 0, "key import <dir> still runs");
  eq(c.log.filter((l) => l.startsWith("key")).join(" | "), "key export /media/k | key import /media/k",
    "…both through the controller, to that directory");
}

// ── #874: key status, and the stamp the USB scripts record ───────────────
{
  const c = new FakeClient();
  eq(run(["key", "status", "--json", "--config-dir", FIX], c), 0, "key status --json runs");
  eq(run(["key", "stamp", "--dir", "/tmp/k", "--label", "tappaas1: SanDisk", "--config-dir", FIX], c), 0, "key stamp runs");
  eq(c.log.filter((l) => l.startsWith("key")).join(" | "), "key status --json | key stamp /tmp/k tappaas1: SanDisk",
    "…both through the controller");
  const sa = (a: string[]): string => {
    const r = keyStampArgs(a);
    return "error" in r ? `ERROR ${r.error}` : `${r.dir}|${r.label}`;
  };
  eq(sa(["--dir", "/k"]), "/k|null", "stamp: the label is optional");
  check(sa([]).startsWith("ERROR key stamp: --dir"), "stamp: --dir is required");
  check(sa(["--dir", "--label", "x"]).startsWith("ERROR key stamp --dir: a value"), "stamp: --dir needs a value");
  check(sa(["--dir", "/k", "extra"]).startsWith("ERROR key stamp: unexpected"), "stamp: a stray word is refused");
}

// ── #759: backup <module>... — take it now, through the controller ───────
{
  const c = new FakeClient();
  const errs: string[] = [];
  const origErr = console.error;
  console.error = (...a: unknown[]) => void errs.push(a.join(" "));
  try {
    eq(run(["backup", "nextcloud", "--config-dir", FIX], c), 0, "backup runs");
    eq(c.log.filter((l) => l.startsWith("backup")).join(" | "), "backup nextcloud",
      "…as one controller call with the module names");
    c.log.length = 0;
    c.backupRc = 1;
    eq(run(["backup", "nextcloud", "--config-dir", FIX], c), 1,
      "a failed backup is the controller's exit code, never 0");
    c.log.length = 0;
    c.backupRc = 0;
    check(run(["backup", "nextcloud", "nope", "--config-dir", FIX], c) !== 0,
      "an unknown module among several is refused");
    eq(c.log.filter((l) => l.startsWith("backup")).length, 0,
      "…before ANY backup runs: a typo in one name does not cost the others");
    check(run(["backup", "--config-dir", FIX], c) !== 0, "backup without a module is refused");
  } finally {
    console.error = origErr;
  }
}

// ── #789: purge — erase a removed guest's restore points ──────────────
{
  const c = new FakeClient();
  c.purgePlans.set("350", { vmid: "350", store: "tappaas_backup", snapshots: 3, bytes: 3 * 2 ** 30, refused: [] });
  c.purgePlans.set("201", { vmid: "201", store: "tappaas_backup", snapshots: 22, bytes: 9 * 2 ** 30,
    refused: ["vmid 201 belongs to the deployed module 'nextcloud' — delete the module first"] });
  let lines: string[] = [];
  // Run the CLI with its output captured; the assertions print normally.
  const cli = (argv: string[]): number => {
    lines = [];
    const orig = console.log, origErr = console.error;
    console.log = (...a: unknown[]) => void lines.push(a.join(" "));
    console.error = (...a: unknown[]) => void lines.push(a.join(" "));
    try {
      return run([...argv, "--config-dir", FIX], c);
    } finally {
      console.log = orig;
      console.error = origErr;
    }
  };
  const yesCalls = () => c.log.filter((l) => l.endsWith("--yes")).length;

  eq(cli(["purge", "350", "--yes"]), 0, "purge <vmid> --yes runs");
  eq(c.log.filter((l) => l.startsWith("purge")).join(" | "), "purge 350 | purge 350 --yes", "…plan first, then the purge");
  check(lines.some((l) => l.includes("3 restore point(s)") && l.includes("3.0 GiB")), "purge shows what goes");

  c.log.length = 0;
  check(cli(["purge", "350"]) !== 0, "purge without --yes in a non-interactive session is refused");
  eq(yesCalls(), 0, "…and nothing is deleted");

  c.log.length = 0;
  check(cli(["purge", "nextcloud", "--yes"]) !== 0, "purge of a deployed module is refused");
  eq(c.log.length, 0, "…before asking the controller anything");

  c.log.length = 0;
  check(cli(["purge", "201", "--yes"]) !== 0, "purge of a VMID the controller refuses fails");
  eq(yesCalls(), 0, "…and nothing is deleted");
  check(lines.some((l) => l.includes("deployed module 'nextcloud'")), "…naming why");

  c.log.length = 0;
  eq(cli(["purge", "999", "--yes"]), 0, "purge of a VMID with no restore points is a no-op");
  eq(yesCalls(), 0, "…that deletes nothing");

  check(cli(["purge", "gone-module"]) !== 0, "purge of an unknown module name asks for the VMID");
  check(cli(["purge"]) !== 0, "purge without an argument is refused");
}

// ── #554: coverage — which jobs back a module's VM up ─────────────────
{
  const c = new FakeClient();
  c.coverageOf.set("nextcloud", [
    { jobId: "backup-mine", how: "explicit", storage: "tappaas_backup", schedule: "21:00", enabled: true, managed: true },
    { jobId: "backup-ops", how: "explicit", storage: "nfs", schedule: "02:00", enabled: true, managed: false },
  ]);
  c.coverageOf.set("offline", null);
  const lines: string[] = [];
  const orig = console.log;
  const origErr = console.error;
  console.log = (...a: unknown[]) => void lines.push(a.join(" "));
  console.error = (...a: unknown[]) => void lines.push(a.join(" "));
  try {
    eq(run(["coverage", "nextcloud"], c), 0, "coverage runs");
    check(lines.some((l) => l.includes("backup-ops") && l.includes("not TAPPaaS")), "coverage lists a job TAPPaaS did not create");
    check(lines.some((l) => l.includes("2 enabled jobs cover nextcloud")), "coverage flags the duplicate");
    lines.length = 0;
    eq(run(["coverage", "offline"], c), 0, "coverage with the cluster silent still exits 0");
    check(lines.some((l) => l.includes("not reachable")), "…and says it cannot tell");
    check(run(["coverage"], c) !== 0, "coverage without a module is refused");
  } finally {
    console.log = orig;
    console.error = origErr;
  }
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

// ── #796: buddy tunnels — one /30 per pull, served by the pulled site ──
{
  eq(slash30Error("10.255.2.4/30"), null, "a /30 on its boundary is a tunnel net");
  check((slash30Error("10.255.2.5/30") ?? "").includes("10.255.2.4/30"), "…off the boundary names the right one");
  check((slash30Error("10.255.2.0/24") ?? "").includes("/30"), "…a wider net is refused");
  eq(JSON.stringify(tunnelHosts("10.255.2.8/30")), '{"serve":"10.255.2.9","dial":"10.255.2.10"}', ".1 serves, .2 dials");
  eq(allocateNet("10.255.2.0/24", []), "10.255.2.0/30", "first /30 of the pool");
  eq(allocateNet("10.255.2.0/24", ["10.255.2.0/30", "10.255.2.8/30"]), "10.255.2.4/30", "…skips the ones in use");
  eq(allocateNet("10.255.2.0/29", ["10.255.2.0/30", "10.255.2.4/30"]), null, "…null when the pool is full");
  eq(allocatePort([51830, 51831]), 51832, "next free listen port from 51830");

  const d = mkdtempSync(join(tmpdir(), "bm-tunnel-"));
  writeFileSync(join(d, "site.json"), JSON.stringify({ name: "s", locations: { home: { country: "DK", timezone: "UTC" } }, primaryLocation: "home" }));
  eq(buddyPool(d), "10.255.2.0/24", "no zones.json: the default pool");
  writeFileSync(join(d, "zones.json"), JSON.stringify({
    mgmt: { ip: "10.0.0.0/24" }, buddy: { ip: "172.31.9.0/24" }, _profiles: {},
  }));
  eq(buddyPool(d), "172.31.9.0/24", "the pool follows zones.json buddy.ip (the site-wide override)");

  const out: string[] = [];
  const call = (argv: string[]): number => {
    const log = console.log;
    const error = console.error;
    console.log = (m: string) => void out.push(String(m));
    console.error = (m: string) => void out.push(String(m));
    try {
      return run([...argv, "--config-dir", d, "--config-only"], new FakeClient());
    } finally {
      console.log = log;
      console.error = error;
    }
  };
  const cfg = (f: string) => JSON.parse(readFileSync(join(d, f), "utf8"));

  eq(call(["peer", "add", "remote", "anna", "--auth-id", "anna@pbs", "--country", "DE", "--tunnel", "serve"]), 0, "remote --tunnel serve");
  eq(JSON.stringify(cfg("remote-anna.json").tunnel), '{"role":"serve","net":"172.31.9.0/30","listenPort":51830}',
    "…gets the first /30 of the pool and port 51830");
  eq(call(["peer", "add", "remote", "bo", "--auth-id", "bo@pbs", "--country", "DE", "--tunnel", "serve", "--mtu", "1340"]), 0, "a second serve");
  eq(JSON.stringify(cfg("remote-bo.json").tunnel), '{"role":"serve","net":"172.31.9.4/30","mtu":1340,"listenPort":51831}',
    "…gets the next /30 and port");
  const key = "x".repeat(42) + "A=";
  eq(call(["peer", "add", "remote", "anna", "--auth-id", "anna@pbs", "--country", "DE", "--peer-key", key, "--force"]), 0,
    "re-run with the puller's key (--force)");
  eq(JSON.stringify(cfg("remote-anna.json").tunnel), `{"role":"serve","net":"172.31.9.0/30","peerKey":"${key}","listenPort":51830}`,
    "…keeps its /30 and port, adds the key");
  eq(call(["peer", "add", "remote", "cy", "--auth-id", "cy@pbs", "--country", "DE", "--tunnel", "serve", "--tunnel-net", "10.99.0.8/30"]), 0,
    "--tunnel-net pins one tunnel outside the pool");
  eq(cfg("remote-cy.json").tunnel.net, "10.99.0.8/30", "…and is kept");

  check(call(["peer", "add", "pull", "anna", "--country", "DE", "--tunnel", "dial", "--tunnel-net", "172.31.9.0/30",
    "--endpoint", "203.0.113.7:51830", "--peer-key", key]) !== 0, "a dial /30 that one of ours already holds is refused");
  check(out.some((l) => l.includes("--tunnel-net 172.31.9.8/30")), "…telling the serving side which /30 is free here");
  eq(call(["peer", "add", "pull", "anna", "--country", "DE", "--tunnel", "dial", "--tunnel-net", "10.255.2.0/30",
    "--endpoint", "203.0.113.7:51830", "--peer-key", key]), 0, "pull --tunnel dial");
  const pa = cfg("pull-anna.json");
  eq(pa.remoteHost, "10.255.2.1", "…pulls from the serving side's .1");
  eq(pa.tunnel.endpoint, "203.0.113.7:51830", "…dialing their endpoint");

  check(call(["peer", "add", "pull", "z", "--tunnel", "dial", "--tunnel-net", "10.255.3.0/30"]) !== 0, "dial without endpoint/key is refused");
  check(call(["peer", "add", "pull", "z", "--tunnel", "serve", "--host", "h"]) !== 0, "a pull cannot serve");
  check(call(["peer", "add", "remote", "z", "--auth-id", "z@pbs", "--tunnel", "dial"]) !== 0, "a remote cannot dial");
  check(call(["peer", "add", "receive", "z", "--tunnel", "serve"]) !== 0, "a receive has no tunnel");
  check(call(["peer", "add", "pull", "z", "--host", "h", "--tunnel-net", "10.255.3.0/30"]) !== 0, "tunnel flags need --tunnel");
  check(call(["peer", "add", "remote", "z", "--auth-id", "z@pbs", "--tunnel", "serve", "--tunnel-net", "10.0.0.4/30"]) !== 0,
    "a /30 inside a zone (mgmt) is refused");
  check(call(["peer", "add", "remote", "z", "--auth-id", "z@pbs", "--tunnel", "serve", "--peer-key", "nope"]) !== 0, "a malformed key is refused");
  eq(nextServe(d).net, "172.31.9.8/30", "nextServe skips every tunnel in use");

  eq(tunnelErrors(d).length, 0, `the configs written are valid (${tunnelErrors(d).join("; ")})`);
  const bo = cfg("remote-bo.json");
  bo.tunnel.net = "172.31.9.0/30";
  writeFileSync(join(d, "remote-bo.json"), JSON.stringify(bo));
  check(validate(d).errors.some((e) => e.includes("used by both")), "validate: two tunnels on one /30 is an error");
  bo.tunnel.net = "172.31.9.5/30";
  writeFileSync(join(d, "remote-bo.json"), JSON.stringify(bo));
  check(validate(d).errors.some((e) => e.includes("boundary")), "validate: a misaligned /30 is an error");
  check(listPeers(d).some((p) => p.tunnel === "serve 172.31.9.0/30 :51830"), "peers shows the tunnel");

  eq(`${pa.remotePort}/${pa.maxDepth}`, "8007/undefined", "a pull says its port, and no depth unless asked (placement reset needs fs/)");
  eq(call(["peer", "add", "pull", "deep", "--host", "h", "--country", "DE", "--port", "8443", "--remote-namespace", "site/a", "--max-depth", "2"]), 0,
    "pull --port --remote-namespace --max-depth");
  const deep = cfg("pull-deep.json");
  eq(`${deep.remotePort} ${deep.remoteNamespace} ${deep.maxDepth}`, "8443 site/a 2", "…recorded");
  check(call(["peer", "add", "pull", "z", "--host", "h", "--max-depth", "9"]) !== 0, "max-depth beyond PBS's 7 is refused");
  check(call(["peer", "add", "remote", "z", "--auth-id", "z@pbs", "--port", "8443"]) !== 0, "--port on a remote is refused");
}

// ── restore list-all --json: last backup, last verify (shapeRuns) ─────
{
  console.log("\n== restore list-all --json ==");
  const NOW = 1_800_000_000;
  const H = 3600;
  // PBS UPID (task field before the start), and PVE's (without it).
  const pbsUpid = (t: number) => `UPID:tappaas3:000006AA:0000034C:00000014:${t.toString(16).toUpperCase()}:verify:tappaas_backup\\x3act-312:tappaas@pbs:`;
  eq(upidTime(pbsUpid(NOW - H)), NOW - H, "a PBS UPID's start time");
  eq(upidTime(`UPID:tappaas3:00134A47:00E832A3:${(NOW).toString(16)}:vzdump::root@pam:`), NOW, "a PVE UPID's start time");
  eq(upidTime("nonsense"), null, "not a UPID: no time");
  eq(["", "fs/tappaas1", "pull/rasmus", "receive", "external/x", "remote"].map(targetKind).join(" "),
    "own host pull receive receive other", "namespaces become target kinds");

  const M = "TAPPaaS-backup-vm-managed";
  const raw = {
    reachable: true, node: "tappaas3", store: "tappaas_backup", marker: M,
    backupJobs: [
      { id: "daily1", comment: M, schedule: "21:00", enabled: true, vmid: "110,311,999", storage: "tappaas_backup" },
      { id: "weekly1", comment: `${M}-weekly`, schedule: "sun 21:00", enabled: true, vmid: "312", storage: "tappaas_backup" },
      { id: "other", comment: "", schedule: "02:00", enabled: false, vmid: "500", storage: "x" },
    ],
    snapshots: [
      { ns: "", type: "vm", id: "110", time: NOW - 2 * H, verification: null },
      { ns: "", type: "vm", id: "110", time: NOW - 26 * H, verification: { state: "ok", upid: pbsUpid(NOW - 20 * H) } },
      { ns: "", type: "vm", id: "311", time: NOW - 40 * H, verification: { state: "failed", upid: pbsUpid(NOW - 30 * H) } },
      { ns: "", type: "ct", id: "312", time: NOW - 5 * 24 * H, verification: { state: "ok", upid: pbsUpid(NOW - 4 * 24 * H) } },
      { ns: "", type: "vm", id: "777", time: NOW - 90 * 24 * H, verification: { state: "ok", upid: pbsUpid(NOW - 80 * 24 * H) } },
      { ns: "fs/tappaas1", type: "host", id: "tappaas1", time: NOW - 3 * H, verification: { state: "ok", upid: pbsUpid(NOW - H) } },
      { ns: "pull/rasmus", type: "vm", id: "110", time: NOW - 10 * H, verification: null },
    ],
    verifyJobs: [{ id: "verify-tappaas_backup", schedule: "04:00", "last-run-endtime": NOW - 5 * H, "last-run-state": "OK",
      "last-run-upid": pbsUpid(NOW - 6 * H), "next-run": NOW + 18 * H }],
    syncJobs: [{ id: "s1", remote: "rasmus", ns: "pull/rasmus", schedule: "04:00", "last-run-state": "connection refused", "last-run-endtime": NOW - 9 * H }],
    tasks: [
      { node: "tappaas3", id: "", starttime: NOW - 3 * H, endtime: NOW - 2 * H, status: "OK" },
      { node: "tappaas1", id: "811", starttime: NOW - 30 * H, endtime: NOW - 29 * H, status: "job errors" },
    ],
  };
  const mods: Record<string, string> = { "110": "nextcloud", "311": "openwebui", "312": "jellyfin" };
  const r = shapeRuns(raw, (v) => mods[v] ?? null, NOW);
  const g = (ns: string, id: string) => r.guests.find((x) => x.ns === ns && x.id === id)!;
  eq(r.reachable && r.node === "tappaas3" && r.store === "tappaas_backup", true, "reachable, node and store carried");
  eq(`${g("", "110").module} ${g("", "110").snapshots} ${g("", "110").lastBackup}`, `nextcloud 2 ${NOW - 2 * H}`, "a guest: its module, count, newest backup");
  eq(`${g("", "110").outcome} ${g("", "110").job} ${g("", "110").bucket}`, "ok daily1 daily", "backed up within its daily job's interval: ok");
  eq(g("", "110").latestVerify, "unverified", "the newest snapshot not yet verified: unverified");
  eq(JSON.stringify(g("", "110").lastVerify), JSON.stringify({ time: NOW - 20 * H, state: "ok" }), "…and the last verify of any snapshot, with its time");
  eq(`${g("", "311").outcome} ${g("", "311").latestVerify} ${g("", "311").failedVerifies}`, "late failed 1", "40 h old in a daily job: late; a failed verify counted");
  eq(`${g("", "312").outcome} ${g("", "312").bucket}`, "ok weekly", "5 days old in the weekly job: ok");
  eq(`${g("", "777").outcome} ${g("", "777").module}`, "not-in-job null", "a guest no job covers: not-in-job");
  eq(`${g("", "999").snapshots} ${g("", "999").outcome} ${g("", "999").lastBackup}`, "0 late null", "a job's guest with no snapshot: listed, late, never backed up");
  eq(`${g("pull/rasmus", "110").module} ${g("pull/rasmus", "110").outcome}`, "null not-in-job", "another site's copy is not this site's module");
  check(!r.guests.some((x) => x.id === "500"), "a disabled job's guests are not expected");
  eq(r.targets.map((t) => `${t.ns || "-"}:${t.kind}:${t.groups}:${t.snapshots}`).join(" "),
    "-:own:4:5 fs/tappaas1:host:1:1 pull/rasmus:pull:1:1", "targets per namespace, the never-backed-up guest not among them");
  const own = r.targets[0];
  eq(`${own.lastBackup} ${own.lastVerify?.time} ${own.lastVerify?.state} ${own.unverified} ${own.failedVerifies}`,
    `${NOW - 2 * H} ${NOW - 20 * H} ok 1 1`, "a target: newest backup, newest verify, unverified and failed counts");
  eq(r.jobs.map((j) => `${j.id}:${j.managed}:${j.bucket}:${j.guests}`).join(" "), "daily1:true:daily:3 weekly1:true:weekly:1 other:false:null:1", "jobs, TAPPaaS's marked");
  eq(`${r.runs[0].node} ${r.runs[0].state} ${r.runs[0].guest} | ${r.runs[1].state} ${r.runs[1].guest}`, "tappaas3 OK null | job errors 811", "runs newest first, an on-demand one names its guest");
  eq(JSON.stringify(r.verifyJobs[0]), JSON.stringify({ id: "verify-tappaas_backup", schedule: "04:00", lastRun: { time: NOW - 6 * H, end: NOW - 5 * H, state: "OK" }, nextRun: NOW + 18 * H }),
    "the verify job: last run start, end, state, next run");
  eq(`${r.syncJobs[0].remote} ${r.syncJobs[0].lastRun?.state} ${r.syncJobs[0].lastRun?.time}`, `rasmus connection refused ${NOW - 9 * H}`, "a sync job's last run, its end standing in for a start");
  const off = shapeRuns({ reachable: false }, () => null, NOW);
  eq(`${off.reachable} ${off.guests.length} ${off.targets.length}`, "false 0 0", "PBS not answering: reachable false, nothing guessed");

  // The CLI: --json goes to the controller, without it the text table.
  const fake = new FakeClient();
  fake.rawRuns = raw;
  const lines: string[] = [];
  const orig = console.log;
  console.log = (...a: unknown[]) => { lines.push(a.join(" ")); };
  let rc: number;
  try { rc = run(["restore", "list-all", "--json", "--config-dir", FIX], fake); } finally { console.log = orig; }
  eq(rc!, 0, "restore list-all --json exits 0");
  check(fake.log.includes("runs"), "…asked the controller for its runs");
  let parsed: { guests?: unknown[] } = {};
  try { parsed = JSON.parse(lines.join("\n")); } catch { /* checked below */ }
  check(Array.isArray(parsed.guests), "…and printed one JSON document");
  const lsa = HELP.verbs.find((v) => v.name === "restore list-all");
  check(lsa?.effect === "read", "the manifest marks restore list-all a read");
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
