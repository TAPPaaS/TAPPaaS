// config.test.ts — unit tests for config load/write/validate, the bootstrap, and
// CliModuleClient consumer discovery. Tiny inline assert harness (zero-dep,
// mirrors identity-manager). Run after compiling via the test/unit tsconfig:
// (rootDir is the cicd root, so emit mirrors the tree):
//   node dist-test/manager/environment-manager/test/unit/config.test.js
//
// Uses a throwaway config tree under the OS temp dir.

import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import {
  environmentZone,
  loadEnvironment,
  loadEnvironments,
  loadRefSources,
  serializeEnvironment,
  validateEnvironmentRefs,
  withBinding,
  writeEnvironment,
} from "../../src/config";
import { bootstrap, buildBootstrapEnvironments, firstOrg, resolveName } from "../../src/bootstrap";
import { CliModuleClient } from "../../src/clients";
import { parseEnvironment as parseEnvironmentFor } from "../../src/config";
import { Environment } from "../../src/types";

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

// ── temp config tree ──────────────────────────────────────────────────
const root = join(tmpdir(), `envmgr-test-${Date.now()}`);
function mk(p: string): void {
  mkdirSync(p, { recursive: true });
}
function jw(p: string, o: unknown): void {
  writeFileSync(p, JSON.stringify(o, null, 2));
}

mk(join(root, "environments"));
mk(join(root, "people", "organizations"));
jw(join(root, "people", "organizations", "acme.json"), { name: "acme" });
jw(join(root, "people", "organizations", "zeta.json"), { name: "zeta" });
// site code (.name) is decoupled from the default env/org (.defaultEnvironment) — #426.
jw(join(root, "site.json"), { name: "warmelo1", defaultEnvironment: "demo" });
jw(join(root, "zones.json"), {
  mgmt: { type: "Management", environment: "mgmt" },
  demo: { type: "Service", environment: "demo" },
  foo: { type: "Service", environment: "foo" },
});
// A deployed module config consuming the 'demo' environment.
jw(join(root, "nextcloud.json"), { name: "nextcloud", environment: "demo" });
jw(join(root, "gitea.json"), { name: "gitea", environment: "foo" });

try {
  // firstOrg = sorted first org slug.
  check(firstOrg(root) === "acme", "firstOrg returns the sorted-first organization");

  // resolveName = site.json '.defaultEnvironment' (NOT '.name' — decoupled, #426).
  check(resolveName(root) === "demo", "resolveName derives <N> from site.json .defaultEnvironment");

  // bootstrap seeds mgmt + demo.
  const res = bootstrap({ configDir: root, force: false });
  check(
    existsSync(join(root, "environments", "mgmt.json")) &&
      existsSync(join(root, "environments", "demo.json")),
    "bootstrap writes mgmt.json + <N>.json",
  );
  check(res.owner === "acme", "bootstrap derives ownerOrg from first org");
  {
    const { mgmt, def } = buildBootstrapEnvironments("demo", "acme", "demo.home.arpa", "local");
    check(mgmt.domains?.dnsMode === "local" && def.domains?.dnsMode === "local" && def.domains?.primary === "demo.home.arpa", "the install's dnsMode reaches both bootstrap environments (ADR-043 D4)");
    check(buildBootstrapEnvironments("demo", "acme", "x.org").def.domains?.dnsMode === undefined, "…and none given leaves the default");
  }

  // load round-trip.
  const model = loadEnvironments(root);
  check(model.environments.has("mgmt") && model.environments.has("demo"), "loadEnvironments reads both");

  // write a single env + validate refs (valid).
  const env: Environment = {
    name: "foo",
    displayName: "Foo",
    ownerOrg: "acme",
  };
  writeEnvironment(root, env);
  const refs = loadRefSources(root);
  const ok = validateEnvironmentRefs(env, env, refs);
  check(ok.errors.length === 0, "valid env passes ref validation");

  // Before the identity bootstrap (ADR-043 D7): an empty owner is a warning, an absent one an error.
  const early = validateEnvironmentRefs({ ...env, ownerOrg: "" }, { ...env, ownerOrg: "" }, refs);
  check(early.errors.length === 0 && early.warnings.some((w) => w.includes("ownerOrg is empty")), "an empty ownerOrg is a warning, not a refusal");
  const absent = validateEnvironmentRefs({ ...env, ownerOrg: "" }, { name: env.name, displayName: env.displayName }, refs);
  check(absent.errors.some((e) => e.includes("missing required field 'ownerOrg'")), "…but an absent one is still refused");

  // unknown zone + unknown owner → errors.
  const bad: Environment = {
    name: "bad",
    displayName: "Bad",
    ownerOrg: "nope",
  };
  const badRes = validateEnvironmentRefs(bad, bad, refs);
  check(
    badRes.errors.some((e) => e.includes("no Service or Management zone names")) &&
      badRes.errors.some((e) => e.includes("unknown organization")),
    "no zone + unknown owner produce errors",
  );
  // withBinding: the refs as they will be once a zone is the environment's own.
  const after = withBinding(refs, "barZone", "bad");
  check(environmentZone(after, "bad") === "barZone" && environmentZone(refs, "bad") === undefined,
    "withBinding links the zone without touching the loaded refs");

  // authored tlsCertRefid → rejected.
  const tls = { ...env, tlsCertRefid: "x" } as unknown;
  const tlsRes = validateEnvironmentRefs(env, tls, refs);
  check(
    tlsRes.errors.some((e) => e.includes("tlsCertRefid")),
    "authored tlsCertRefid is rejected",
  );

  // loadEnvironment(one) + serialize is stable.
  const one = loadEnvironment(root, "demo");
  check(one !== null && one.name === "demo", "loadEnvironment reads a single env");
  if (one) check(serializeEnvironment(one).endsWith("\n"), "serializeEnvironment ends with newline");

  // CliModuleClient consumer discovery: which modules consume 'demo' / 'foo'.
  const mc = new CliModuleClient(root);
  check(
    JSON.stringify(mc.modulesForEnvironment("demo")) === JSON.stringify(["nextcloud"]),
    "modulesForEnvironment finds the consuming module",
  );
  check(
    JSON.stringify(mc.modulesForEnvironment("foo")) === JSON.stringify(["gitea"]),
    "modulesForEnvironment scopes by environment",
  );
  check(
    mc.modulesForEnvironment("none").length === 0,
    "modulesForEnvironment returns empty for an unused env",
  );

  // CliModuleClient argument vector (#454): the shipped module-manager CLI
  // dispatches on argv[0], so the verb MUST come first. This used to build
  // `<module> reconcile`, which exited 1 with "Unknown verb: <module>" and
  // stalled the whole --deep --apply cascade at its first module. A stub
  // binary records what was actually spawned.
  const argvLog = join(root, "module-manager-argv");
  const stub = join(root, "stub-module-manager");
  writeFileSync(stub, `#!/usr/bin/env bash\nprintf '%s\\n' "$*" > '${argvLog}'\n`);
  chmodSync(stub, 0o755);
  const prevBin = process.env.MODULE_MANAGER_BIN;
  process.env.MODULE_MANAGER_BIN = stub;
  try {
    mc.reconcileModule("backup", true);
    const applyArgv = readFileSync(argvLog, "utf8").trim();
    check(applyArgv === "reconcile backup --apply", `reconcileModule(apply) spawns verb-first (got: ${applyArgv})`);

    // The PREVIEW opts out of module-manager's dependency-service check (#458):
    // a --deep preview walks every consuming module, so it must not pay one
    // firewall round-trip per dependency per module.
    mc.reconcileModule("backup", false);
    const previewArgv = readFileSync(argvLog, "utf8").trim();
    check(
      previewArgv === "reconcile backup --no-services",
      `reconcileModule(preview) spawns verb-first and skips service checks (got: ${previewArgv})`,
    );
  } finally {
    if (prevBin === undefined) delete process.env.MODULE_MANAGER_BIN;
    else process.env.MODULE_MANAGER_BIN = prevBin;
  }

  // idempotent bootstrap: existing files left untouched (no force).
  const res2 = bootstrap({ configDir: root, force: false });
  check(res2.wrote.length === 0 && res2.skipped.length === 2, "bootstrap is idempotent without --force");
} finally {
  rmSync(root, { recursive: true, force: true });
}


// ADR-046: an environment's performance level survives a parse and a write;
// trace reads as service; nothing else comes in.
{
  const e = parseEnvironmentFor({ name: "lab", displayName: "Lab", ownerOrg: "o", performance: { level: "service", resolution: "fine" } });
  check(e.performance?.level === "service" && e.performance?.resolution === "fine", "performance is read");
  check(JSON.parse(serializeEnvironment(e)).performance.level === "service", "performance is written back");
  check(parseEnvironmentFor({ name: "lab", performance: { level: "trace" } }).performance?.level === "service", "a record saying trace reads as service");
  check(parseEnvironmentFor({ name: "lab", performance: { level: "loud", colour: "red" } }).performance === undefined, "an unknown level is not read");
  check(!("performance" in JSON.parse(serializeEnvironment(parseEnvironmentFor({ name: "lab", displayName: "Lab", ownerOrg: "o" })))), "no performance, none written");
}

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
