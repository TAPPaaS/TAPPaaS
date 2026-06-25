// reconcile.test.ts — offline unit tests for the site reconcile engine.
// No cluster, no git; a FakeSiteClient holds in-memory state. Tiny assert
// harness (no test framework). Run via the test/unit tsconfig (see test.sh).

import { Repository, Site } from "../../src/types";
import { CASCADE_ORDER, applyPlan, computePlan } from "../../src/reconcile";
import { FakeSiteClient } from "./fake-client";

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

function site(repos: Repository[]): Site {
  return {
    name: "demo",
    displayName: "Demo",
    owner: "demo",
    location: { country: "NL", timezone: "Europe/Amsterdam" },
    hardware: { nodes: [{ name: "tappaas1", storagePools: ["tanka1"] }] },
    repositories: repos,
  };
}

const TAPPAAS: Repository = {
  name: "TAPPaaS",
  url: "github.com/TAPPaaS/TAPPaaS",
  branch: "stable",
  path: "/home/tappaas/TAPPaaS",
};

// 1. Missing clone → clone action.
{
  const c = new FakeSiteClient();
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: true, siteFile: "x" });
  check(plan.actions.length === 1 && plan.actions[0].kind === "clone-repo", "missing clone → clone-repo");
  applyPlan(c, plan);
  check(c.clones.has(TAPPAAS.path!), "apply created the clone");
}

// 2. Idempotent: present clone on correct branch → no actions.
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: true, siteFile: "x" });
  check(plan.actions.length === 0, "in-sync repo → no actions");
}

// 3. Branch drift → checkout action.
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "main");
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: true, siteFile: "x" });
  check(plan.actions.length === 1 && plan.actions[0].kind === "checkout-repo", "branch drift → checkout-repo");
  applyPlan(c, plan);
  check(c.branches.get(TAPPAAS.path!) === "stable", "apply checked out the configured branch");
}

// 4. validateSite errors surface as warnings (non-fatal in the plan).
{
  const c = new FakeSiteClient();
  c.validationErrors = ["(root): missing required field 'owner'"];
  c.seedClone(TAPPAAS.path!, "stable");
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: true, siteFile: "x" });
  check(plan.warnings.length === 1 && plan.warnings[0].includes("validation"), "validation error → warning");
}

// 5. --deep adds the cascade actions: people → network → (every) environment.
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  c.environments = ["home", "work"];
  const plan = computePlan(site([TAPPAAS]), c, { deep: true, apply: true, siteFile: "x" });
  const cascade = plan.actions.filter((a) => a.kind.startsWith("cascade-"));
  // people + network + one per environment.
  check(
    cascade.length === CASCADE_ORDER.length + c.environments.length,
    "--deep = people + network + one action per environment",
  );
  check(
    cascade.map((a) => a.kind).join(",") ===
      "cascade-people,cascade-network,cascade-environment,cascade-environment",
    "cascade order = people, network, then environments",
  );
  applyPlan(c, plan);
  check(
    c.log.filter((l) => l.startsWith("cascade")).join("|") ===
      "cascade people apply|cascade network apply|" +
        "cascade environment home apply|cascade environment work apply",
    "apply drives people, network, then each environment (apply mode)",
  );
}

// 5b. --deep with no environments → just people + network.
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  const plan = computePlan(site([TAPPAAS]), c, { deep: true, apply: false, siteFile: "x" });
  const cascade = plan.actions.filter((a) => a.kind.startsWith("cascade-"));
  check(cascade.length === CASCADE_ORDER.length, "--deep with no environments → people + network only");
}

// 6. shallow reconcile does NOT cascade.
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: true, siteFile: "x" });
  check(plan.actions.every((a) => !a.kind.startsWith("cascade-")), "shallow reconcile → no cascade");
}

// 7. repo with no .path → warning, no action.
{
  const c = new FakeSiteClient();
  const noPath: Repository = { name: "x", url: "github.com/x/x", branch: "main" };
  const plan = computePlan(site([noPath]), c, { deep: false, apply: true, siteFile: "x" });
  check(plan.actions.length === 0 && plan.warnings.some((w) => w.includes("no .path")), "repo without .path → warning only");
}

console.log("");
console.log(`reconcile.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
