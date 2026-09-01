// reconcile.test.ts — unit tests for the environment reconcile engine.
//
// Tiny inline assert harness (no test framework, no node:assert) — mirrors the
// people-manager zero-dep convention. Run after compiling via the test/unit
// tsconfig (see test.sh):
// (rootDir is the cicd root, so emit mirrors the tree):
//   node dist-test/manager/environment-manager/test/unit/reconcile.test.js

import { Environment, NetworkUnreachable } from "../../src/types";
import { applyPlan, computePlan } from "../../src/reconcile";
import { FakeDnsTlsClient, FakeModuleClient, FakeNetworkClient } from "./fake-clients";

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

// ADR-014 D1: a MISSING zone is now materialized, not merely warned about.
// Before D1 this only warned, so an environment could name a zone that never
// existed and never converge — the operator had to know to run
// `network-manager add` first (an undocumented ordering trap).
{
  const net = new FakeNetworkClient(); // no zones seeded
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: false });
  const create = plan.actions.filter((a) => a.kind === "create-service-zone");
  check(
    create.length === 1 && create[0].value === "foo",
    "D1: a missing zone is PLANNED for creation, not warned about",
  );
  check(
    plan.actions.some((a) => a.kind === "reconcile-network"),
    "D1: the network reconcile is still planned alongside the zone creation",
  );
  check((plan.errors ?? []).length === 0, "D1: a missing zone is not an error — it is materialized");
}

// ADR-014 D1: an environment pointed at a NON-Service zone is a hard error.
// This is the case the ADR calls out — reconcile must not paper over it by
// minting a second zone underneath the operator.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo", "Client"); // the environment names a CLIENT zone
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: false });
  check(
    (plan.errors ?? []).some((e) => e.includes("is a Client zone, not a Service zone")),
    "D1: an environment bound to a Client zone is a hard ERROR",
  );
  check(
    !plan.actions.some((a) => a.kind === "create-service-zone"),
    "D1: a wrongly-typed zone is NOT silently replaced by a new one",
  );
}

// ADR-014 D1: applying the plan authors the zone through the network client —
// environment-manager never writes zones.json itself.
{
  const net = new FakeNetworkClient();
  const mod = new FakeModuleClient();
  const e = env("foo", "foo");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: false });
  const res = applyPlan(e, plan, net, mod, true);
  check(
    net.log.includes("create-service-zone foo"),
    "D1: apply authors the zone via network-manager (the ownership boundary holds)",
  );
  check(net.zoneExists("foo") && res.failures.length === 0, "D1: the zone exists after apply");
  // ORDER IS LOAD-BEARING: the zone must be authored BEFORE the network pass,
  // or the reconcile converges a zones.json that does not yet contain it.
  check(
    eqJson(net.log, ["create-service-zone foo", "reconcile-network apply"]),
    "D1: the zone is authored BEFORE the network converges, not after",
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

// #461 + ADR-014 D1: --skip-network still resolves the zone reference. Skipping
// the (system-wide) network PASS says nothing about whether this environment's
// zone is correctly configured, so the D1 materialization is still planned.
{
  const net = new FakeNetworkClient(); // no zones seeded
  const mod = new FakeModuleClient();
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: true });
  check(
    plan.actions.some((a) => a.kind === "create-service-zone"),
    "--skip-network still plans the missing zone's creation",
  );
  check(
    !plan.actions.some((a) => a.kind === "reconcile-network"),
    "--skip-network still omits the system-wide network pass",
  );
}

// ── #537: wildcard DNS + cert-refid runtime state ─────────────────────
// A wildcard-mode environment created after site bootstrap must get its
// split-horizon `*.<domain>` override and its cert refid from reconcile, not
// only from the manual acme-setup.sh.
function wildcardEnv(name: string, zone: string, domain: string): Environment {
  return {
    name,
    displayName: name,
    ownerOrg: "acme",
    network: { zone },
    domains: { primary: domain, dnsMode: "wildcard" },
  };
}

// A per-service (non-wildcard) or domain-less environment plans NO DNS/TLS work.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  const plan = computePlan(env("foo", "foo"), net, mod, { deep: false, skipNetwork: true }, dt);
  check(
    !plan.actions.some((a) =>
      ["register-wildcard-dns", "record-cert-refid", "issue-wildcard-cert"].includes(a.kind),
    ),
    "a non-wildcard environment plans no DNS/TLS actions",
  );
}

// TLS: an issued cert whose refid is not yet recorded → a record-cert-refid
// action carrying the refid; DNS already correct so no DNS action.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedWildcard("app.example.com", "10.9.0.1"); // DNS already converged
  dt.seedIssuedCert("app.example.com", "REFID-ABC"); // cert exists on the firewall
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  const rec = plan.actions.find((a) => a.kind === "record-cert-refid");
  check(
    rec !== undefined && rec.value === "REFID-ABC" && rec.scope === "environment",
    "an issued-but-unrecorded refid plans a record-cert-refid carrying it",
  );
  check(
    !plan.actions.some((a) => a.kind === "register-wildcard-dns"),
    "no DNS action when the wildcard already resolves correctly",
  );
}

// TLS: cert issued AND already recorded → idempotent, no TLS action, a note.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedWildcard("app.example.com", "10.9.0.1");
  dt.seedIssuedCert("app.example.com", "REFID-ABC");
  dt.seedRecordedRefid("foo", "REFID-ABC");
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  check(
    !plan.actions.some((a) => a.kind === "record-cert-refid") &&
      plan.notes.some((n) => n.includes("already records REFID-ABC")),
    "a matching recorded refid is left alone (idempotent) with a note",
  );
}

// TLS: no cert issued + creds present → an issue-wildcard-cert action, and the
// separate DNS action is SKIPPED because acme-setup.sh registers DNS itself.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1"); // DNS underived-target would otherwise plan
  dt.credsPresent = true;
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  check(
    plan.actions.some((a) => a.kind === "issue-wildcard-cert"),
    "no cert + creds present plans an issue-wildcard-cert",
  );
  check(
    !plan.actions.some((a) => a.kind === "register-wildcard-dns") &&
      plan.notes.some((n) => n.includes("as part of certificate issuance")),
    "issuance bundles DNS registration, so no separate DNS action is planned",
  );
}

// TLS: no cert issued + NO creds → a warning (never silently succeeds); DNS is
// still evaluated independently.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1"); // wildcard missing → DNS action expected
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  check(
    !plan.actions.some((a) => a.kind === "issue-wildcard-cert") &&
      plan.warnings.some((w) => w.includes("acme-dns-credentials.txt is absent")),
    "no cert + no creds warns to run acme-setup, never issues",
  );
  check(
    plan.actions.some((a) => a.kind === "register-wildcard-dns"),
    "the wildcard DNS is still planned even when the cert cannot be issued",
  );
}

// DNS: wildcard override missing/wrong → a register-wildcard-dns action pointed
// at the env's own service-zone gateway.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedIssuedCert("app.example.com", "R"); // isolate: TLS already settled
  dt.seedRecordedRefid("foo", "R");
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  const dns = plan.actions.find((a) => a.kind === "register-wildcard-dns");
  check(
    dns !== undefined && dns.value === "10.9.0.1" && dns.zone === "foo" && dns.scope === "environment",
    "a missing wildcard override plans register-wildcard-dns at the service-zone gateway",
  );
}

// DNS: target correct but a colliding per-service override exists → still plans
// the register (which prunes the collision).
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedWildcard("app.example.com", "10.9.0.1"); // target already correct
  dt.seedCollisions("app.example.com", ["logging"]); // but a collision lingers
  dt.seedIssuedCert("app.example.com", "R");
  dt.seedRecordedRefid("foo", "R");
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  const dns = plan.actions.find((a) => a.kind === "register-wildcard-dns");
  check(
    dns !== undefined && dns.target.includes("prune 1 colliding"),
    "a lingering per-service collision still plans a wildcard register (to prune it)",
  );
}

// DNS: already correct, no collisions → no DNS action, just a note.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedWildcard("app.example.com", "10.9.0.1");
  dt.seedIssuedCert("app.example.com", "R");
  dt.seedRecordedRefid("foo", "R");
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  check(
    !plan.actions.some((a) => a.kind === "register-wildcard-dns") &&
      plan.notes.some((n) => n.includes("already resolves to 10.9.0.1")),
    "an already-correct wildcard override plans no DNS action (idempotent)",
  );
}

// DNS: no gateway derivable (zone has no subnet, no dmz fallback) → a warning,
// no DNS action.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient(); // no gateways seeded → underivable
  dt.seedIssuedCert("app.example.com", "R");
  dt.seedRecordedRefid("foo", "R");
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  check(
    !plan.actions.some((a) => a.kind === "register-wildcard-dns") &&
      plan.warnings.some((w) => w.includes("could not derive a gateway IP")),
    "an underivable gateway warns instead of planning a broken DNS record",
  );
}

// DNS falls back to the dmz gateway when the env's own zone has no subnet.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("dmz", "10.6.0.1"); // only dmz has a gateway
  dt.seedIssuedCert("app.example.com", "R");
  dt.seedRecordedRefid("foo", "R");
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    dt,
  );
  const dns = plan.actions.find((a) => a.kind === "register-wildcard-dns");
  check(
    dns !== undefined && dns.value === "10.6.0.1" && dns.zone === "dmz",
    "the wildcard falls back to the dmz gateway when the service zone has no subnet",
  );
}

// wildcard mode but domains.primary unset → a warning, no actions.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  const e = wildcardEnv("foo", "foo", "");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true }, dt);
  check(
    plan.warnings.some((w) => w.includes("domains.primary is unset")) &&
      !plan.actions.some((a) =>
        ["register-wildcard-dns", "record-cert-refid", "issue-wildcard-cert"].includes(a.kind),
      ),
    "wildcard mode with no primary domain warns and plans nothing",
  );
}

// wildcard mode but NO DnsTlsClient injected → a warning, never silent.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const plan = computePlan(
    wildcardEnv("foo", "foo", "app.example.com"),
    net,
    mod,
    { deep: false, skipNetwork: true },
    // no dt
  );
  check(
    plan.warnings.some((w) => w.includes("no DNS/TLS client available")),
    "wildcard mode without a DNS/TLS client warns rather than silently skipping",
  );
}

// apply: register-wildcard-dns drives the client (prunes collisions + sets target).
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedCollisions("app.example.com", ["logging"]);
  dt.seedIssuedCert("app.example.com", "R");
  dt.seedRecordedRefid("foo", "R");
  const e = wildcardEnv("foo", "foo", "app.example.com");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true }, dt);
  const res = applyPlan(e, plan, net, mod, true, undefined, dt);
  check(
    res.failures.length === 0 &&
      dt.log.some((l) => l.startsWith("register-wildcard app.example.com -> 10.9.0.1")) &&
      dt.log.some((l) => l.includes("prune=[logging]")),
    "apply registers the wildcard and prunes the colliding override",
  );
}

// apply: record-cert-refid persists the refid via the client.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedWildcard("app.example.com", "10.9.0.1");
  dt.seedIssuedCert("app.example.com", "REFID-XYZ");
  const e = wildcardEnv("foo", "foo", "app.example.com");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true }, dt);
  const res = applyPlan(e, plan, net, mod, true, undefined, dt);
  check(
    res.failures.length === 0 &&
      dt.recordedCertRefid("foo") === "REFID-XYZ" &&
      dt.log.includes("write-cert-refid foo=REFID-XYZ"),
    "apply records the issued cert's refid in cert-refids.json",
  );
}

// apply: issue-wildcard-cert delegates to the client (acme-setup.sh).
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.credsPresent = true;
  const e = wildcardEnv("foo", "foo", "app.example.com");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true }, dt);
  const res = applyPlan(e, plan, net, mod, true, undefined, dt);
  check(
    res.failures.length === 0 &&
      dt.log.includes("issue-wildcard-cert foo") &&
      dt.recordedCertRefid("foo") === "REFID-ISSUED",
    "apply issues the wildcard cert and records the resulting refid",
  );
}

// apply: a planned DNS/TLS action with NO client is a loud failure, not a drop.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.seedIssuedCert("app.example.com", "REFID-XYZ"); // → a record-cert-refid action
  const e = wildcardEnv("foo", "foo", "app.example.com");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true }, dt);
  const res = applyPlan(e, plan, net, mod, true); // no dt passed to apply
  check(
    res.failures.some((f) => f.error.includes("no DNS/TLS client available")),
    "a planned DNS/TLS action fails loudly when apply has no client",
  );
}

// A firewall/manager binary missing on PATH aborts (NetworkUnreachable), like
// the network/module clients — it is an environment fault, not a per-item one.
{
  const net = new FakeNetworkClient();
  net.seedZone("foo");
  const mod = new FakeModuleClient();
  const dt = new FakeDnsTlsClient();
  dt.seedGateway("foo", "10.9.0.1");
  dt.credsPresent = true;
  dt.issueError = new NetworkUnreachable("acme-setup.sh: ENOENT");
  const e = wildcardEnv("foo", "foo", "app.example.com");
  const plan = computePlan(e, net, mod, { deep: false, skipNetwork: true }, dt);
  let threw = false;
  try {
    applyPlan(e, plan, net, mod, true, undefined, dt);
  } catch (err) {
    threw = err instanceof NetworkUnreachable;
  }
  check(threw, "an unreachable issuance binary propagates instead of being collected");
}

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
