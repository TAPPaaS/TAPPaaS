// reconcile.test.ts — unit tests for the environment reconcile engine.
//
// Tiny inline assert harness (no test framework, no node:assert) — mirrors the
// people-manager zero-dep convention. Run after compiling via the test/unit
// tsconfig (see test.sh):
//   node dist-test/test/unit/reconcile.test.js

import { Environment } from "../../src/types";
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

// shallow: exactly one network reconcile, no module reconciles.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  mod.seedModule("foo", "nextcloud");
  const plan = computePlan(env("foo", "foo"), net, mod, false);
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
  const plan = computePlan(env("foo", "foo"), net, mod, true);
  check(
    eqJson(
      plan.actions.map((a) => a.kind),
      ["reconcile-network", "reconcile-module", "reconcile-module"],
    ),
    "deep plan adds a reconcile-module per consuming module",
  );
}

// unknown zone → warning, but still plans the network reconcile.
{
  const net = new FakeNetworkClient(); // no zones seeded
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, false);
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
  const plan = computePlan(e, net, mod, true);
  const n = applyPlan(e, plan, net, mod, true);
  check(
    n === 2 &&
      eqJson(net.log, ["reconcile-network apply"]) &&
      eqJson(mod.log, ["reconcile-module nextcloud apply"]),
    "applyPlan drives network then module clients",
  );
}

// deep with no consuming modules → warning, network-only plan.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, true);
  check(
    plan.actions.length === 1 && plan.warnings.some((w) => w.includes("nothing downstream")),
    "deep with no consumers warns",
  );
}

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
