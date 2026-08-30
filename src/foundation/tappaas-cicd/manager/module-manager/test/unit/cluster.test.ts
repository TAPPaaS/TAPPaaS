// cluster.test.ts — offline unit tests for the shared cluster ssh helpers.
//
// Covers operatorHome() — the #518 fix that restores the invoking operator's
// HOME so `sudo -n` manager reads keep using the operator's ~/.ssh identity
// instead of root's (empty) one. No cluster, no ssh: operatorHome is a pure
// function of the process env. Tiny assert harness (same style as
// module.test.ts). Run via the test/unit tsconfig (see test.sh).

import { operatorHome } from "../../../../lib/ts/src/cluster";

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

// Save/restore the three env vars operatorHome reads, so tests are isolated
// and leave the process env as they found it.
const saved = {
  TAPPAAS_OPERATOR_HOME: process.env.TAPPAAS_OPERATOR_HOME,
  SUDO_USER: process.env.SUDO_USER,
};
function setEnv(over: Partial<Record<"TAPPAAS_OPERATOR_HOME" | "SUDO_USER", string>>): void {
  delete process.env.TAPPAAS_OPERATOR_HOME;
  delete process.env.SUDO_USER;
  for (const [k, v] of Object.entries(over)) process.env[k] = v;
}

// ── 1. not under sudo → undefined (inherited HOME already the operator's) ──
setEnv({});
check(operatorHome() === undefined, "no SUDO_USER / no override → undefined");

// ── 2. sudo -n as the operator → their home is restored ───────────────────
setEnv({ SUDO_USER: "tappaas" });
check(operatorHome() === "/home/tappaas", "SUDO_USER=tappaas → /home/tappaas");

// ── 3. SUDO_USER=root is a no-op (root has no operator identity to restore) ─
setEnv({ SUDO_USER: "root" });
check(operatorHome() === undefined, "SUDO_USER=root → undefined");

// ── 4. explicit override wins over SUDO_USER (tests / relocated installs) ──
setEnv({ SUDO_USER: "tappaas", TAPPAAS_OPERATOR_HOME: "/srv/op" });
check(operatorHome() === "/srv/op", "TAPPAAS_OPERATOR_HOME overrides SUDO_USER");

// ── 5. override alone (no sudo) is still honoured ─────────────────────────
setEnv({ TAPPAAS_OPERATOR_HOME: "/srv/op" });
check(operatorHome() === "/srv/op", "TAPPAAS_OPERATOR_HOME honoured without sudo");

// restore original env
setEnv({});
if (saved.TAPPAAS_OPERATOR_HOME !== undefined)
  process.env.TAPPAAS_OPERATOR_HOME = saved.TAPPAAS_OPERATOR_HOME;
if (saved.SUDO_USER !== undefined) process.env.SUDO_USER = saved.SUDO_USER;

console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
