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
    defaultEnvironment: "demo",
    displayName: "Demo",
    owner: "demo",
    location: { country: "NL", timezone: "Europe/Amsterdam" },
    hardware: { nodes: [{ name: "tappaas1", storagePools: ["tanka1"] }] },
    repositories: repos,
  };
}

const TAPPAAS: Repository = {
  name: "TAPPaaS",
  url: "codeberg.org/TAPPaaS/TAPPaaS",
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
  // #461: the network leg must state that its ONE pass covers every
  // environment, and the environment legs must show they skip theirs.
  const netAction = cascade.find((a) => a.kind === "cascade-network")!;
  check(
    netAction.target.includes("system-wide") && netAction.target.includes("all 2 environment(s)"),
    `network cascade reports 1 system-wide pass for all environments (got: ${netAction.target})`,
  );
  check(
    cascade
      .filter((a) => a.kind === "cascade-environment")
      .every((a) => a.target.includes("--skip-network")),
    "each environment cascade skips the already-run network pass",
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

// 8. node capture (N1): a joined-but-unregistered cluster node is planned as
// register-node; departed nodes warn only; unreachable cluster warns only;
// the repositories scope never plans node actions.
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  c.liveNodes = ["tappaas1", "tappaas2"];
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: true, siteFile: "x" });
  const reg = plan.actions.filter((a) => a.kind === "register-node");
  check(reg.length === 1 && reg[0].target.includes("tappaas2"), "joined node planned as register-node");
  applyPlan(c, plan);
  check(c.registeredNodes.join(",") === "tappaas2", "apply registers exactly the missing node");
}
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  c.liveNodes = []; // site knows tappaas1, cluster reports none
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: false, siteFile: "x" });
  check(
    plan.actions.length === 0 && plan.warnings.some((w) => w.includes("not in the live cluster")),
    "departed node → warning only, never auto-removed",
  );
}
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  c.liveNodes = null; // unreachable
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: false, siteFile: "x" });
  check(
    plan.actions.length === 0 && plan.warnings.some((w) => w.includes("cluster unreachable")),
    "unreachable cluster → warning, no node actions",
  );
}
{
  const c = new FakeSiteClient();
  c.liveNodes = ["tappaas1", "tappaas2"]; // node drift present...
  const plan = computePlan(site([TAPPAAS]), c, {
    deep: false, apply: false, siteFile: "x", scope: "repositories",
  });
  check(
    !plan.actions.some((a) => a.kind === "register-node"),
    "repositories scope plans no node actions (repository reconcile unaffected by node drift)",
  );
  const plan2 = computePlan(site([TAPPAAS]), c, {
    deep: false, apply: false, siteFile: "x", scope: "nodes",
  });
  check(
    plan2.actions.every((a) => a.kind === "register-node") && plan2.actions.length === 1,
    "nodes scope plans ONLY node actions",
  );
}

// 9. storagePools discovery (N1 follow-up): registration carries discovered
// pools; a known node with EMPTY declared pools gets them filled; a declared
// non-empty mismatch warns only.
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  c.liveNodes = ["tappaas1", "tappaas3"];
  c.livePools.set("tappaas3", ["tanka1", "tankb1"]);
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: true, siteFile: "x" });
  const reg = plan.actions.filter((a) => a.kind === "register-node");
  check(reg.length === 1 && reg[0].target.includes("tanka1, tankb1"), "registration discovers the node's tank pools");
  applyPlan(c, plan);
  check(c.log.some((l) => l === "register-node tappaas3 [tanka1,tankb1]"), "apply registers WITH the discovered pools");
}
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  const s2 = site([TAPPAAS]);
  s2.hardware.nodes = [{ name: "tappaas1", storagePools: [] }]; // registered pre-discovery
  const plan = computePlan(s2, c, { deep: false, apply: true, siteFile: "x" });
  const upd = plan.actions.filter((a) => a.kind === "update-node-pools");
  check(upd.length === 1 && upd[0].target.includes("tanka1"), "empty declared pools get a fill action from discovery");
  applyPlan(c, plan);
  check(c.log.some((l) => l === "set-node-pools tappaas1 [tanka1]"), "apply fills the pools");
}
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  c.livePools.set("tappaas1", ["tanka1", "tankz9"]); // node reports MORE than declared
  const plan = computePlan(site([TAPPAAS]), c, { deep: false, apply: false, siteFile: "x" });
  check(
    !plan.actions.some((a) => a.kind === "update-node-pools") &&
      plan.warnings.some((w) => w.includes("not auto-changed")),
    "non-empty declared pools that mismatch discovery → warning only",
  );
}

// A cascade that ran and FAILED must be counted as a failure, not as applied —
// and must not strand the cascades planned after it. Before this, stream()
// handed back the child's rc, nothing looked at it, and a --deep run that
// converged nothing still reported "Applied N action(s)".
{
  const c = new FakeSiteClient();
  c.seedClone(TAPPAAS.path!, "stable");
  c.environments = ["home", "work"];
  c.cascadeRc.set("home", 1);
  const plan = computePlan(site([TAPPAAS]), c, { deep: true, apply: true, siteFile: "x" });
  const res = applyPlan(c, plan);
  check(
    res.failures.length === 1 && res.failures[0].error === "exit 1",
    `a non-zero cascade rc is a failure (applied=${res.applied}, failures=${res.failures.length})`,
  );
  check(
    res.failures[0].target.includes("environment home"),
    "the failing cascade is named by its target",
  );
  check(
    res.applied === plan.actions.length - 1,
    "every other action still counts as applied",
  );
  check(
    c.log.some((l) => l === "cascade environment work apply"),
    "a failing environment does not stop the cascade",
  );
}

console.log("");
console.log(`reconcile.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
