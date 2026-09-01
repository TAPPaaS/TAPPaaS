// cli.test.ts — offline unit tests for the shared preflight guard (#533).
//
// requireOperator(uid) refuses uid 0 (root) by throwing DieError, and is a
// no-op for any non-root uid. Passing uid explicitly keeps the test hermetic —
// no need to actually be root. No cluster, no ssh. Tiny assert harness, same
// style as cluster.test.ts.

import { requireOperator, DieError } from "../../../../lib/ts/src/cli";

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

// ── 1. non-root uid → no throw ──────────────────────────────────────────
let threw = false;
try {
  requireOperator(1000);
} catch {
  threw = true;
}
check(!threw, "requireOperator(1000) does not throw (operator, not root)");

// ── 2. uid 0 (root) → throws DieError ───────────────────────────────────
let err: unknown = undefined;
try {
  requireOperator(0);
} catch (e) {
  err = e;
}
check(err instanceof DieError, "requireOperator(0) throws DieError (refuses root)");

// ── 3. -1 (uid unavailable) → treated as non-root, no throw ──────────────
threw = false;
try {
  requireOperator(-1);
} catch {
  threw = true;
}
check(!threw, "requireOperator(-1) does not throw (uid unavailable → allowed)");

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
