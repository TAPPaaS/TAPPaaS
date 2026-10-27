// fleet.test.ts — the `update` + `test` fleet verbs (#588). No cluster, no
// subprocesses: a FakeSiteClient records the delegation and scripts outcomes,
// so this asserts the CLI's argument vectors + iteration/exit-code behaviour.

import { HELP, run } from "../../src/main";
import { undocumentedOptions } from "../../../../lib/ts/src/help";
import { FakeSiteClient } from "./fake-client";
import { existsSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

// ── update: starts update-tappaas.service with a one-shot request (ADR-017 D4) ──
const cfg = mkdtempSync(join(tmpdir(), "upd-"));
writeFileSync(join(cfg, "site.json"), JSON.stringify({
  name: "t", repositories: [
    { name: "TAPPaaS", url: "u", branch: "main", path: "/repo/tappaas" },
    { name: "extra", url: "u2", branch: "stable", path: "/repo/extra" },
  ],
}));
const req = () => JSON.parse(readFileSync(join(cfg, ".update-request.json"), "utf8"));
const clean = () => { try { unlinkSync(join(cfg, ".update-request.json")); } catch { /* none */ } };
{
  const c = new FakeSiteClient(); clean();
  const rc = run(["update", "--config-dir", cfg], c);
  check(rc === 0 && c.log.includes("start-unit") && c.log.includes("follow inv-1"), "update starts the unit and follows this invocation");
  check(req().force === false && req().allowDisruption === false && req().noGitPull === false, "a plain update writes a request with no option set");
}
{
  const c = new FakeSiteClient(); clean();
  run(["update", "--force", "--no-git-pull", "--config-dir", cfg], c);
  check(req().force === true && req().noGitPull === true, "--force and --no-git-pull travel in the request");
  check(req().allowDisruption === false, "--force does not authorize downtime (ADR-020 v0.10 D8)");
}
{
  const c = new FakeSiteClient(); clean();
  run(["update", "--allow-disruption", "--config-dir", cfg], c);
  check(req().allowDisruption === true && req().force === false, "--allow-disruption travels alone");
}
{
  const c = new FakeSiteClient(); clean();
  c.unitStateValue = "activating";
  const rc = run(["update", "--config-dir", cfg], c);
  check(rc !== 0 && !c.log.includes("start-unit") && !existsSync(join(cfg, ".update-request.json")),
    "a running update is refused and no request is left for the next timer run");
}
{
  // --stop: a file the sweep reads between modules, naming the running invocation
  const stopFile = join(cfg, ".update-stop");
  const c = new FakeSiteClient(); clean();
  c.unitStateValue = "active"; c.unitInvocationValue = "inv-7";
  const rc = run(["update", "--stop", "--config-dir", cfg], c);
  const s = JSON.parse(readFileSync(stopFile, "utf8"));
  check(rc === 0 && s.invocation === "inv-7" && typeof s.requestedBy === "string" && s.at,
    "--stop asks the running invocation to stop, naming it");
  check(!c.log.includes("start-unit") && !existsSync(join(cfg, ".update-request.json")),
    "--stop starts nothing and leaves no run request");
  unlinkSync(stopFile);
  const idle = new FakeSiteClient();
  check(run(["update", "--stop", "--config-dir", cfg], idle) === 0 && !existsSync(stopFile),
    "--stop with nothing running says so and writes nothing");
}
{
  const c = new FakeSiteClient(); clean();
  c.startOk = false;
  const rc = run(["update", "--config-dir", cfg], c);
  check(rc !== 0 && !existsSync(join(cfg, ".update-request.json")), "a failed start drops the request");
}
{
  const c = new FakeSiteClient(); clean();
  c.unitResultValue = "exit-code";
  check(run(["update", "--config-dir", cfg], c) === 1, "a failed run is exit 1");
}
{
  const c = new FakeSiteClient(); clean();
  c.detach = true;
  check(run(["update", "--config-dir", cfg], c) === 0, "Ctrl-C detaches with exit 0 (the run continues)");
}
{
  const c = new FakeSiteClient(); clean();
  run(["repository", "hold", "extra", "--reason", "testing", "--config-dir", cfg], c);
  const rc = run(["update", "--dry-run", "--config-dir", cfg], c);
  check(rc === 0 && !c.log.includes("start-unit"), "update --dry-run starts nothing");
  check(c.log.includes("probe /repo/tappaas main") && !c.log.some((l) => l.startsWith("probe /repo/extra")),
    "--dry-run probes each repository against origin, except a held one");
  check(c.log.includes("update --dry-run"), "--dry-run prints the sweep plan");
  check(!existsSync(join(cfg, ".update-request.json")), "--dry-run writes no request");
}

// ── test: iterate every LIVE module, forward --deep, continue-on-failure ──
// One line per module; each module's output goes to a run directory here.
const logRoot = mkdtempSync(join(tmpdir(), "site-test-"));
process.env.TAPPAAS_LOG_DIR = logRoot;
const live = (name: string): { name: string; status: string } => ({ name, status: "Production" });
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("nextcloud"), live("litellm")];
  const rc = run(["test"], c);
  check(rc === 0, "test all-pass → exit 0");
  check(
    c.log.includes("test nextcloud >log") && c.log.includes("test litellm >log"),
    "test iterates every module the list returns, each into its own log",
  );
}
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("a"), live("b")];
  run(["test", "--deep"], c);
  check(
    c.log.includes("test a --deep >log") && c.log.includes("test b --deep >log"),
    "test --deep forwards --deep to each module",
  );
}
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("a"), live("b"), live("c")];
  c.testRc.set("b", 1);
  const rc = run(["test"], c);
  check(rc === 1, "test with a failing module → exit 1");
  check(c.log.includes("test c >log"), "…and it CONTINUES past the failure (c still tested)");
}
{
  // archived / external modules have no live VM — they are SKIPPED, never run,
  // so they never produce a false failure (regression for the makerfloss
  // portainer-lab1 finding).
  const c = new FakeSiteClient();
  c.deployedModules = [
    live("a"),
    { name: "portainer-lab1", status: "archived" },
    { name: "ext1", status: "external" },
  ];
  const rc = run(["test"], c);
  check(rc === 0, "test skips archived/external → the live module passes, exit 0");
  const tested = (m: string): boolean => c.log.some((l) => l === `test ${m}` || l.startsWith(`test ${m} `));
  check(
    !tested("portainer-lab1") && !tested("ext1"),
    "…and never invokes the test for a decommissioned module",
  );
  check(tested("a"), "…but the live module IS tested");
}
{
  const c = new FakeSiteClient();
  c.deployedModules = null;
  const rc = run(["test"], c);
  check(rc === 1, "test → exit 1 when the module list cannot be read");
}
{
  const c = new FakeSiteClient();
  c.deployedModules = [];
  const rc = run(["test"], c);
  check(rc === 0, "test → exit 0 when there are no deployed modules");
}

// ── #644: --help runs nothing; an option the verb does not take is refused ──
// `update --help` used to start the whole-site sweep.
{
  const quiet = (argv: string[]): { rc: number; out: string; err: string; log: string[] } => {
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
    const c = new FakeSiteClient();
    try {
      const rc = run(argv, c);
      return { rc, out, err, log: c.log };
    } finally {
      console.log = log;
      console.error = error;
    }
  };
  for (const argv of [
    ["update", "--help"],
    ["update", "--force", "-h"],
    ["test", "--deep", "--help"],
    ["node", "add", "tappaas3", "--pxe", "--help"],
    ["repo", "delete", "x", "--force", "--help"],
    ["reconcile", "--apply", "--help"],
  ]) {
    const r = quiet(argv);
    check(r.rc === 0 && r.out.includes("Usage:") && r.log.length === 0, `${argv.join(" ")}: help, rc 0, nothing delegated`);
  }
  check(quiet(["update", "--help"]).out.includes("--no-git-pull") && !quiet(["update", "--help"]).out.includes("--pxe"),
    "update --help prints update's options, not node add's");
  check(quiet(["node", "--help"]).out.includes("node reboot <name>"), "node --help lists every node verb");
  for (const argv of [["update", "--dryrun"], ["test", "--force"], ["site", "modify", "--colour", "red"], ["repo", "list", "--url", "u"]]) {
    const r = quiet(argv);
    check(r.rc === 1 && r.err.includes("unknown option") && r.log.length === 0, `${argv.join(" ")}: refused, nothing delegated`);
  }
  clean();
  check(quiet(["update", "--no-git-pull", "--force", "--config-dir", cfg]).log.includes("start-unit"), "declared options still pass");
  clean();
  check(undocumentedOptions(HELP).length === 0, `every usage option is described (${undocumentedOptions(HELP).join(", ")})`);
}

// ── repository sync (#814): one repository, delegated; reconcile says "behind" ──
function captured(argv: string[], c: FakeSiteClient): { rc: number; out: string; log: string[] } {
  const [log, error] = [console.log, console.error];
  let out = "";
  console.log = (...a: unknown[]): void => { out += a.map(String).join(" ") + "\n"; };
  console.error = (...a: unknown[]): void => { out += a.map(String).join(" ") + "\n"; };
  try {
    return { rc: run(argv, c), out, log: c.log };
  } finally {
    console.log = log;
    console.error = error;
  }
}
{
  const c = new FakeSiteClient();
  check(run(["repository", "sync", "extra", "--dry-run", "--config-dir", cfg], c) === 0
    && c.log.includes("repository.sh sync extra --dry-run"), "repository sync <name> --dry-run delegates to repository.sh");
  for (const argv of [["repository", "sync"], ["repository", "sync", "a", "b"]]) {
    const r = captured([...argv, "--config-dir", cfg], new FakeSiteClient());
    check(r.rc !== 0 && !r.log.some((l) => l.startsWith("repository.sh sync")), `${argv.join(" ")}: refused — one name, never the whole site`);
  }
  const f = new FakeSiteClient(); f.delegateRc = 1;
  check(run(["repository", "sync", "extra", "--config-dir", cfg], f) !== 0, "a refused sync is a non-zero exit");
}
{
  const c = new FakeSiteClient();
  c.seedClone("/repo/tappaas", "main");
  c.seedClone("/repo/extra", "stable");
  c.probes.set("/repo/tappaas", { head: "aaaa", tip: "bbbb", behind: 2 });
  const r = captured(["repository", "reconcile", "--config-dir", cfg], c);
  check(r.out.includes("2 commit(s) behind origin") && r.out.includes("repository sync TAPPaaS"),
    "reconcile reports a checkout behind origin and the sync that closes it");
  check(!r.out.includes("Converged"), "a checkout behind origin is not reported as Converged");
}

// ── test, in short: one line per module, the failures named, the output in a log ──
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("storage"), live("tappaas-cicd")];
  c.testOutput.set("storage", "[Info]   ✓ share mounted\n[Info] All tests passed for module 'storage'\n");
  c.testOutput.set("tappaas-cicd",
    "[Info]   ✓ 0 packages seen → SCAN FAILED, never clean\n" +
    "  ok: liveness FAILS when a module is down\n" +
    "\x1b[0;31m[Error]\x1b[0m   ✗ test-pipefail-grep-q.sh failed — rerun: scripts/test/test-pipefail-grep-q.sh\n" +
    "        FAIL: foundation/x/test.sh:12: grep -q under pipefail\n" +
    "[FAIL] the console answers\n" +
    "        FAIL: foundation/x/test.sh:12: grep -q under pipefail\n");
  c.testRc.set("tappaas-cicd", 1);
  const r = captured(["test", "--deep"], c);
  check(r.rc === 1, "short form: a failing module → exit 1");
  check(/✓.* storage /.test(r.out) && !r.out.includes("share mounted"), "a passing module is one line; its checks stay in its log");
  check(/✗ tappaas-cicd.*\(exit 1\)/.test(r.out), "a failing module says so, with its exit code");
  check(r.out.includes("✗ test-pipefail-grep-q.sh failed") && r.out.includes("[FAIL] the console answers"),
    "…and names its failed checks");
  check((r.out.match(/FAIL: foundation\/x\/test.sh:12/g) ?? []).length === 1, "…once each");
  check(!r.out.includes("SCAN FAILED") && !r.out.includes("liveness FAILS"), "…not passing checks that mention a failure");
  const m = /each module's output: (\S+)\/<module>\.log/.exec(r.out);
  check(m !== null && m[1].startsWith(logRoot), "the run directory is named up front");
  check(m !== null && readFileSync(join(m[1], "tappaas-cicd.log"), "utf8").includes("SCAN FAILED"),
    "…and holds each module's whole output");
}
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("a")];
  const r = captured(["test", "--verbose"], c);
  check(c.log.includes("test a") && !c.log.includes("test a >log") && r.out.includes("== test a =="),
    "--verbose streams each module test as before, with no log file");
}

console.log(`fleet.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
