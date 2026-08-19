// reconcile.test.ts — unit tests for the environment reconcile engine.
//
// Tiny inline assert harness (no test framework, no node:assert) — mirrors the
// people-manager zero-dep convention. Run after compiling via the test/unit
// tsconfig (see test.sh):
// (rootDir is the cicd root, so emit mirrors the tree):
//   node dist-test/manager/environment-manager/test/unit/reconcile.test.js

import { Environment, NetworkUnreachable } from "../../src/types";
import { applyPlan, computePlan } from "../../src/reconcile";
import { FakeModuleClient, FakeNetworkClient } from "./fake-clients";

let passed = 0;
let failed = 0;
function check(cond: boolean, label: string): void {
  if (cond) {
    passed++;
    console.log(`ok - ${label}`);
  } else {
    failed++;
    console.error(`FAIL - ${label}`);
  }
}
function eqJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function env(name: string, zone: string): Environment {
  return { name, displayName: name, ownerOrg: "acme", network: { zone } };
}

// ── ownerOrg backfill ────────────────────────────────────────────────
// An environment bootstrapped before any organization existed carries
// ownerOrg:"" and fails the schema. Reconcile is the verb that repairs it.
function envNoOwner(name: string, zone: string): Environment {
  return { name, displayName: name, ownerOrg: "", network: { zone } };
}

// empty ownerOrg + a resolved candidate → a backfill action carrying the org.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const plan = computePlan(envNoOwner("foo", "foo"), net, mod, {
    deep: false,
    skipNetwork: true,
    ownerOrgCandidate: "acme",
  });
  const a = plan.actions.find((x) => x.kind === "backfill-owner-org");
  check(
    plan.actions.length === 1 && a !== undefined && a.value === "acme" && a.scope === "environment",
    "empty ownerOrg + candidate plans a backfill carrying the org",
  );
}

// empty ownerOrg + NO candidate → warning, never a silent guess.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const plan = computePlan(envNoOwner("foo", "foo"), net, mod, { deep: false, skipNetwork: true });
  check(
    plan.actions.length === 0 && plan.warnings.some((w) => w.includes("ownerOrg is empty")),
    "empty ownerOrg without a candidate warns instead of guessing",
  );
}

// already set → nothing planned (idempotent).
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, {
    deep: false,
    skipNetwork: true,
    ownerOrgCandidate: "other",
  });
  check(plan.actions.length === 0, "a populated ownerOrg is left alone (idempotent)");
}

// apply writes through the injected writer and mutates the environment.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const e = envNoOwner("foo", "foo");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true, ownerOrgCandidate: "acme" });
  const written: Environment[] = [];
  const res = applyPlan(e, plan, net, mod, true, (x) => written.push(x));
  check(
    res.applied === 1 && res.failures.length === 0 && e.ownerOrg === "acme" &&
      written.length === 1 && written[0].ownerOrg === "acme",
    "applyPlan backfills ownerOrg and persists via the writer",
  );
}

// no writer injected → reported as a failure, never silently dropped.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const e = envNoOwner("foo", "foo");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true, ownerOrgCandidate: "acme" });
  const res = applyPlan(e, plan, net, mod, true);
  check(
    res.applied === 0 && res.failures.length === 1 &&
      res.failures[0].error.includes("no environment writer"),
    "a planned backfill with no writer fails loudly",
  );
}

// shallow: exactly one network reconcile, no module reconciles.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "nextcloud");
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: false });
  check(
    plan.actions.length === 1 && plan.actions[0].kind === "reconcile-network",
    "shallow plan reconciles only the network",
  );
}

// deep: network + one action per consuming module.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "nextcloud");
  mod.seedModule("foo", "gitea");
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: true, skipNetwork: false });
  check(
    eqJson(
      plan.actions.map((a) => a.kind),
      ["reconcile-network", "reconcile-module", "reconcile-module"],
    ),
    "deep plan adds a reconcile-module per consuming module",
  );
}

// #474: a --deep reconcile of the DEFAULT environment also reconciles the
// mgmt-zone identity module (whose Authentik self-config tracks this domain).
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedDeployed("identity"); // deployed, environment: null (not a consumer)
  const plan = computePlan(env("foo", "foo"), net, mod, {
    deep: true,
    skipNetwork: false,
    isDefaultEnv: true,
  });
  check(
    eqJson(plan.actions.map((a) => a.target).filter((t) => t.includes("identity")), [
      "module 'identity'",
    ]),
    "default-env deep reconcile adds a reconcile-module for identity (#474)",
  );
}

// #474: a NON-default environment does NOT reconcile identity.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedDeployed("identity");
  const plan = computePlan(env("foo", "foo"), net, mod, {
    deep: true,
    skipNetwork: false,
    isDefaultEnv: false,
  });
  check(
    !plan.actions.some((a) => a.target.includes("identity")),
    "non-default env deep reconcile does NOT touch identity (#474)",
  );
}

// #474: if identity is not deployed, it is not added (no failure on identity-less systems).
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient(); // identity not seeded
  const plan = computePlan(env("foo", "foo"), net, mod, {
    deep: true,
    skipNetwork: false,
    isDefaultEnv: true,
  });
  check(
    !plan.actions.some((a) => a.target.includes("identity")),
    "default-env deep reconcile skips identity when it is not deployed (#474)",
  );
}

// #474: identity is not duplicated if it is ever also a direct consumer.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "identity"); // already a consumer of this env
  const plan = computePlan(env("foo", "foo"), net, mod, {
    deep: true,
    skipNetwork: false,
    isDefaultEnv: true,
  });
  check(
    plan.actions.filter((a) => a.target === "module 'identity'").length === 1,
    "identity is reconciled exactly once even as default-env consumer (#474)",
  );
}

// unknown zone → warning, but still plans the network reconcile.
{
  const net = new FakeNetworkClient(); // no zones seeded
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: false });
  check(
    plan.actions.length === 1 &&
      plan.warnings.some((w) => w.includes("not present in zones.json")),
    "unknown zone warns but still reconciles the network",
  );
}

// apply drives the clients in order.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "nextcloud");
  const e = env("foo", "foo");
  const plan = computePlan(e, net, mod, { deep: true, skipNetwork: false });
  const res = applyPlan(e, plan, net, mod, true);
  check(
    res.applied === 2 &&
      res.failures.length === 0 &&
      eqJson(net.log, ["reconcile-network apply"]) &&
      eqJson(mod.log, ["reconcile-module nextcloud apply"]),
    "applyPlan drives network then module clients",
  );
}

// #454: one failing module no longer strands the modules planned after it.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "alpha");
  mod.seedModule("foo", "beta");
  mod.seedModule("foo", "gamma");
  mod.seedFailure("beta", new Error("module-manager reconcile beta failed (exit 1): boom"));
  const e = env("foo", "foo");
  const plan = computePlan(e, net, mod, { deep: true, skipNetwork: false });
  const res = applyPlan(e, plan, net, mod, true);
  check(
    eqJson(mod.log, [
      "reconcile-module alpha apply",
      "reconcile-module beta apply",
      "reconcile-module gamma apply",
    ]),
    "a failing module does not stop the cascade",
  );
  check(
    res.applied === 3 && res.failures.length === 1,
    `partial converge is counted (applied=${res.applied}, failures=${res.failures.length})`,
  );
  check(
    res.failures[0].target === "beta" && res.failures[0].error.includes("boom"),
    "the failing module is named, with its child error",
  );
}

// #454: an unspawnable binary is NOT a per-module fault — it still aborts.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "alpha");
  mod.seedModule("foo", "beta");
  mod.seedFailure("alpha", new NetworkUnreachable("module-manager reconcile: ENOENT"));
  const e = env("foo", "foo");
  const plan = computePlan(e, net, mod, { deep: true, skipNetwork: false });
  let threw = false;
  try {
    applyPlan(e, plan, net, mod, true);
  } catch (err) {
    threw = err instanceof NetworkUnreachable;
  }
  check(threw, "NetworkUnreachable propagates instead of being collected");
  check(
    eqJson(mod.log, ["reconcile-module alpha apply"]),
    "no further modules are attempted once the binary is unreachable",
  );
}

// deep with no consuming modules → warning, network-only plan.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: true, skipNetwork: false });
  check(
    plan.actions.length === 1 && plan.warnings.some((w) => w.includes("nothing downstream")),
    "deep with no consumers warns",
  );
}

// #461: the network action must declare the scope it ACTS on, not the scope it
// was asked about. It converges every zone on every plane; the environment's
// zone is merely included.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: false });
  const a = plan.actions[0];
  check(a.scope === "system-wide", "the network action is labelled system-wide");
  check(
    a.target.includes("ALL zones") && a.target.includes("system-wide"),
    `the network target names its real extent (got: ${a.target})`,
  );
  check(
    plan.notes.some((n) => n.includes("no zone or environment filter")),
    "the plan notes why the network pass cannot be narrowed",
  );
}

// #461: modules ARE environment-scoped — the tag must distinguish them.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "nextcloud");
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: true, skipNetwork: false });
  check(
    eqJson(
      plan.actions.map((x) => x.scope),
      ["system-wide", "environment"],
    ),
    "module actions are environment-scoped, the network action is not",
  );
}

// #461: --skip-network drops the system-wide action so a multi-environment run
// performs ONE network pass, not one per environment.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "nextcloud");
  const e = env("foo", "foo");
  const plan = computePlan(e, net, mod, { deep: true, skipNetwork: true });
  check(
    eqJson(
      plan.actions.map((a) => a.kind),
      ["reconcile-module"],
    ),
    "--skip-network omits the network action, keeps the module cascade",
  );
  check(
    plan.notes.some((n) => n.includes("SKIPPED")),
    "--skip-network is reported, not silent",
  );
  applyPlan(e, plan, net, mod, true);
  check(eqJson(net.log, []), "--skip-network never calls network-manager");
}

// #461: --skip-network still checks the zone reference (the warning is about
// config correctness, not about who runs the pass).
{
  const net = new FakeNetworkClient(); // no zones seeded
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: true });
  check(
    plan.warnings.some((w) => w.includes("not present in zones.json")),
    "--skip-network keeps the unknown-zone warning",
  );
}

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
