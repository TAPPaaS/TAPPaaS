// config.test.ts — unit tests for config load/write/validate, the bootstrap, and
// CliModuleClient consumer discovery. Tiny inline assert harness (zero-dep,
// mirrors people-manager). Run after compiling via the test/unit tsconfig:
// (rootDir is the cicd root, so emit mirrors the tree):
//   node dist-test/manager/environment-manager/test/unit/config.test.js
//
// Uses a throwaway config tree under the OS temp dir.

import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import {
  loadEnvironment,
  loadEnvironments,
  loadRefSources,
  serializeEnvironment,
  validateEnvironmentRefs,
  writeEnvironment,
} from "../../src/config";
import { bootstrap, firstOrg, resolveName } from "../../src/bootstrap";
import { CliModuleClient } from "../../src/clients";
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
jw(join(root, "zones.json"), { mgmt: {}, demo: {}, foo: {} });
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

  // load round-trip.
  const model = loadEnvironments(root);
  check(model.environments.has("mgmt") && model.environments.has("demo"), "loadEnvironments reads both");

  // write a single env + validate refs (valid).
  const env: Environment = {
    name: "foo",
    displayName: "Foo",
    ownerOrg: "acme",
    network: { zone: "foo" },
  };
  writeEnvironment(root, env);
  const refs = loadRefSources(root);
  const ok = validateEnvironmentRefs(env, env, refs);
  check(ok.errors.length === 0, "valid env passes ref validation");

  // unknown zone + unknown owner → errors.
  const bad: Environment = {
    name: "bad",
    displayName: "Bad",
    ownerOrg: "nope",
    network: { zone: "ghost" },
  };
  const badRes = validateEnvironmentRefs(bad, bad, refs);
  check(
    badRes.errors.some((e) => e.includes("unknown zone")) &&
      badRes.errors.some((e) => e.includes("unknown organization")),
    "unknown zone + owner produce errors",
  );

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

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
