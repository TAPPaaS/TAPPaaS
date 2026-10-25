// gate.test.ts — the gate's key cache (gate.ts): a key is fetched once per
// console route, other routes are never looked up, and a refused token makes
// the key be fetched again, at most every 30 s, while the old one stays in use.

import { GateKeys, isConsoleHost } from "../../src/gate";
import { check, done } from "./check";
import { TEST_KEY } from "./gate-fixture";

async function main(): Promise<void> {
  let fetched = 0;
  let t = 0;
  const g = new GateKeys(async (h) => (fetched++, h.startsWith("console.") ? TEST_KEY : null), () => undefined, () => t);
  await g.ensure("console.hrossen.dk");
  await g.ensure("console.hrossen.dk");
  check(fetched === 1 && g.get("CONSOLE.hrossen.dk") === TEST_KEY, "a key is fetched once and cached (host without case)");
  await g.ensure("woodpecker.hrossen.dk");
  check(fetched === 1 && !isConsoleHost("woodpecker.hrossen.dk") && isConsoleHost("status.hrossen.dk"), "only the console's routes are looked up");
  g.forget("console.hrossen.dk");
  await g.ensure("console.hrossen.dk");
  check(fetched === 1 && g.get("console.hrossen.dk") === TEST_KEY, "a refused token keeps the key in use (a forgery locks nobody out), no refetch within 30 s");
  t += 31_000;
  await g.ensure("console.hrossen.dk");
  check(fetched === 2 && g.get("console.hrossen.dk") === TEST_KEY, "…and the key is fetched again after it");
  await g.ensure("console.hrossen.dk");
  check(fetched === 2, "a fresh key is not fetched again");
  const rotated = { ...TEST_KEY, secret: "new-secret" };
  let next: typeof TEST_KEY | null = rotated;
  const r = new GateKeys(async () => next, () => undefined, () => t);
  await r.ensure("console.hrossen.dk");
  next = null;
  r.forget("console.hrossen.dk");
  t += 31_000;
  await r.ensure("console.hrossen.dk");
  check(r.get("console.hrossen.dk") === rotated, "a refetch that finds nothing keeps the key it had");
  const bad = new GateKeys(async () => {
    throw new Error("connection refused");
  });
  await bad.ensure("console.hrossen.dk");
  check(bad.get("console.hrossen.dk") === null, "Authentik unreachable: no key, no crash");
  done("gate");
}

void main();
