// fleet.test.ts — the `update` + `test` fleet verbs (#588). No cluster, no
// subprocesses: a FakeSiteClient records the delegation and scripts outcomes,
// so this asserts the CLI's argument vectors + iteration/exit-code behaviour.

import { HELP, run } from "../../src/main";
import { undocumentedOptions } from "../../../../lib/ts/src/help";
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

// ── update: always runs now (--force scheduling is implicit in the client) ──
{
  const c = new FakeSiteClient();
  const rc = run(["update"], c);
  check(rc === 0 && c.log.includes("update"), "update delegates to the sweep with no extra flags");
}
{
  const c = new FakeSiteClient();
  run(["update", "--dry-run"], c);
  check(c.log.includes("update --dry-run"), "update --dry-run forwards --dry-run");
}
{
  const c = new FakeSiteClient();
  run(["update", "--force"], c);
  check(c.log.includes("update --force"), "update --force → per-module disruption force");
}
{
  const c = new FakeSiteClient();
  run(["update", "--no-git-pull"], c);
  check(c.log.includes("update --no-git-pull"), "update --no-git-pull forwards the toggle");
}
{
  const c = new FakeSiteClient();
  run(["update", "--force", "--no-git-pull", "--dry-run"], c);
  check(
    c.log.includes("update --dry-run --force --no-git-pull"),
    "update forwards all three flags together",
  );
}

// ── test: iterate every LIVE module, forward --deep, continue-on-failure ──
const live = (name: string): { name: string; status: string } => ({ name, status: "Production" });
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("nextcloud"), live("litellm")];
  const rc = run(["test"], c);
  check(rc === 0, "test all-pass → exit 0");
  check(
    c.log.includes("test nextcloud") && c.log.includes("test litellm"),
    "test iterates every module the list returns",
  );
}
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("a"), live("b")];
  run(["test", "--deep"], c);
  check(
    c.log.includes("test a --deep") && c.log.includes("test b --deep"),
    "test --deep forwards --deep to each module",
  );
}
{
  const c = new FakeSiteClient();
  c.deployedModules = [live("a"), live("b"), live("c")];
  c.testRc.set("b", 1);
  const rc = run(["test"], c);
  check(rc === 1, "test with a failing module → exit 1");
  check(c.log.includes("test c"), "…and it CONTINUES past the failure (c still tested)");
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
  check(
    !c.log.includes("test portainer-lab1") && !c.log.includes("test ext1"),
    "…and never invokes the test for a decommissioned module",
  );
  check(c.log.includes("test a"), "…but the live module IS tested");
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
  check(quiet(["update", "--dry-run", "--no-git-pull"]).log.includes("update --dry-run --no-git-pull"), "declared options still pass");
  check(undocumentedOptions(HELP).length === 0, `every usage option is described (${undocumentedOptions(HELP).join(", ")})`);
}

console.log(`fleet.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
