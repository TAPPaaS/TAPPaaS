// client.test.ts — argument-vector tests for CliSiteClient (the real FFI
// boundary). The engine tests use a fake; these pin what is ACTUALLY spawned,
// because the cascade's whole failure mode was an argv the callee rejects.
//
// Stub binaries record their argv to a file, exactly as
// environment-manager/test/unit/config.test.ts pins module-manager's.
//
// Run after compiling via the test/unit tsconfig (see test.sh):
//   node dist-test/manager/site-manager/test/unit/client.test.js

import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { CliSiteClient } from "../../src/client";

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

const root = mkdtempSync(join(tmpdir(), "site-client-"));
try {
  const argvLog = join(root, "argv");
  // rc is echoed back so a test can model a child manager that ran and failed.
  const stub = (rc: number): string => {
    const p = join(root, `stub-${rc}`);
    writeFileSync(p, `#!/usr/bin/env bash\nprintf '%s\\n' "$*" > '${argvLog}'\nexit ${rc}\n`);
    chmodSync(p, 0o755);
    return p;
  };
  const spawned = (): string => readFileSync(argvLog, "utf8").trim();

  const c = new CliSiteClient();
  const prevEnv = process.env.SITE_ENVIRONMENT_BIN;
  const prevNet = process.env.SITE_NETWORK_BIN;
  try {
    // ── cascadeEnvironment ────────────────────────────────────────────
    // environment-manager dispatches on argv[0]. The old `<env> reconcile
    // --deep` form exited 1 with "Unknown command: <env>", so the environment
    // leg of every `site reconcile --deep` converged nothing — and said
    // nothing, because the rc was discarded. Verb FIRST.
    process.env.SITE_ENVIRONMENT_BIN = stub(0);
    c.cascadeEnvironment("rossen", true);
    check(
      spawned() === "reconcile rossen --deep --skip-network --apply",
      `cascadeEnvironment(apply) spawns verb-first, network skipped (got: ${spawned()})`,
    );

    c.cascadeEnvironment("rossen", false);
    check(
      spawned() === "reconcile rossen --deep --skip-network",
      `cascadeEnvironment(preview) omits --apply (got: ${spawned()})`,
    );

    // The child's exit code must reach the caller: a cascade that ran and
    // failed is a failure, not an applied action.
    process.env.SITE_ENVIRONMENT_BIN = stub(1);
    check(c.cascadeEnvironment("rossen", true) === 1, "cascadeEnvironment returns the child's rc");

    // ── cascade(network) ──────────────────────────────────────────────
    process.env.SITE_NETWORK_BIN = stub(0);
    c.cascade("network", true);
    check(spawned() === "reconcile --apply", `network cascade spawns 'reconcile --apply' (got: ${spawned()})`);
    process.env.SITE_NETWORK_BIN = stub(3);
    check(c.cascade("network", true) === 3, "cascade returns the child's rc");
  } finally {
    if (prevEnv === undefined) delete process.env.SITE_ENVIRONMENT_BIN;
    else process.env.SITE_ENVIRONMENT_BIN = prevEnv;
    if (prevNet === undefined) delete process.env.SITE_NETWORK_BIN;
    else process.env.SITE_NETWORK_BIN = prevNet;
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}

console.log("");
console.log(`client.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
