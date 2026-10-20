// mlag.test.ts — the mlag-pairs gate (#847): no pair, a LAG across the pair as
// recorded, one with no member on a peer, and an mlag-id the switch has otherwise.

import { mlagPairsResult } from "../../src/mlag";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const pair = { "a+b": { switches: ["a", "b"] } };
check(mlagPairsResult({}).status === "skip", "no pair — skip");
{
  const r = mlagPairsResult({ mlagPairs: pair, switches: {
    a: { ports: { ether2: { lag: "n1-lan", mlagId: 10, liveMlagId: 10 } } },
    b: { ports: { ether2: { lag: "n1-lan", mlagId: 10 } } } } });
  check(r.status === "pass" && r.detail === "1 MLAG pair(s), 1 LAG(s) across them", `across the pair — pass (${r.detail})`);
}
{
  const r = mlagPairsResult({ mlagPairs: pair, switches: { a: { ports: { ether2: { lag: "n1-lan", mlagId: 10 } } }, b: { ports: {} } } });
  check(r.status === "warn" && /no member on b/.test(r.rows?.[0]?.text ?? ""), "no member on a peer — warn, naming it");
}
{
  const r = mlagPairsResult({ mlagPairs: pair, switches: {
    a: { ports: { ether2: { lag: "n1-lan", mlagId: 10, liveMlagId: 11 } } },
    b: { ports: { ether2: { lag: "n1-lan", mlagId: 10 } } } } });
  check(r.status === "warn" && r.rows?.[0]?.subject?.name === "a:ether2", "an mlag-id the switch has otherwise — warn, on the port");
}

console.log(`mlag: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
