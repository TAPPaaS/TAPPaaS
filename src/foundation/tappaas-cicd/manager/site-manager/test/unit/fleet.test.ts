// fleet.test.ts — the `update` + `test` fleet verbs (#588). No cluster, no
// subprocesses: a FakeSiteClient records the delegation and scripts outcomes,
// so this asserts the CLI's argument vectors + iteration/exit-code behaviour.

import { run } from "../../src/main";
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

// ── test: iterate every deployed module, forward --deep, continue-on-failure ──
{
  const c = new FakeSiteClient();
  c.moduleNames = ["nextcloud", "litellm"];
  const rc = run(["test"], c);
  check(rc === 0, "test all-pass → exit 0");
  check(
    c.log.includes("test nextcloud") && c.log.includes("test litellm"),
    "test iterates every module the list returns",
  );
}
{
  const c = new FakeSiteClient();
  c.moduleNames = ["a", "b"];
  run(["test", "--deep"], c);
  check(
    c.log.includes("test a --deep") && c.log.includes("test b --deep"),
    "test --deep forwards --deep to each module",
  );
}
{
  const c = new FakeSiteClient();
  c.moduleNames = ["a", "b", "c"];
  c.testRc.set("b", 1);
  const rc = run(["test"], c);
  check(rc === 1, "test with a failing module → exit 1");
  check(c.log.includes("test c"), "…and it CONTINUES past the failure (c still tested)");
}
{
  const c = new FakeSiteClient();
  c.moduleNames = null;
  const rc = run(["test"], c);
  check(rc === 1, "test → exit 1 when the module list cannot be read");
}
{
  const c = new FakeSiteClient();
  c.moduleNames = [];
  const rc = run(["test"], c);
  check(rc === 0, "test → exit 0 when there are no deployed modules");
}

console.log(`fleet.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
