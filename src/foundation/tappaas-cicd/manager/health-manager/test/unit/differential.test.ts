// differential.test.ts — the record-driven engine against the oracle (derive.ts
// as it was after P0, frozen in oracle/ with today's health-rules.json) on
// random sites: identical conditions and root lists. And the engine's answer
// does not depend on the order of objects, relations and sources.
//
// HM_DIFF_SITES sets how many sites (default 2000).

import { Condition } from "../../src/assess-model";
import { derive } from "../../src/derive";
import { deriveP0, oracleModel } from "./oracle/derive-p0";
import { rng, site } from "./gen-site";
import { shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const now = "2026-10-30T09:00:00.000Z";
const model = shippedModel();
const oracle = oracleModel(model);
const N = Number(process.env.HM_DIFF_SITES ?? 2000);
const clone = (m: Map<string, Condition[]>): Map<string, Condition[]> => new Map([...m].map(([k, v]) => [k, v.map((c) => ({ ...c }))]));
const norm = (d: { conditions: Map<string, Condition[]>; rootCauses: unknown[] }): string =>
  JSON.stringify([[...d.conditions].sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, v.map((x) => JSON.stringify(x)).sort()]), d.rootCauses]);

for (const [label, cycles, faults] of [["with depends-on loops", true, 0.12], ["acyclic, more faults", false, 0.25], ["many faults", true, 0.4]] as const) {
  let differ = 0;
  let first = "";
  for (let i = 1; i <= N; i++) {
    const s = site(i, 1, faults, cycles);
    const a = norm(deriveP0(s.objects, clone(s.source), s.relations, oracle, now));
    const b = norm(derive(s.objects, clone(s.source), s.relations, model, now));
    if (a !== b) { differ++; if (!first) first = ` (first: seed ${i})`; }
  }
  check(differ === 0, `${N} random sites ${label}: identical to the oracle${differ ? `; ${differ} differ${first}` : ""}`);
}

// Shuffled input: the same answer.
{
  let differ = 0;
  for (let i = 1; i <= Math.min(N, 1500); i++) {
    const s = site(i, 1, 0.2);
    const r = rng(i * 7919);
    const sh = <X>(xs: X[]): X[] => xs.map((x) => [r(), x] as [number, X]).sort((p, q) => p[0] - q[0]).map((p) => p[1]);
    const a = norm(derive(s.objects, clone(s.source), s.relations, model, now));
    const b = norm(derive(sh(s.objects), new Map(sh([...clone(s.source)])), sh(s.relations), model, now));
    if (a !== b) differ++;
  }
  check(differ === 0, `${Math.min(N, 1500)} sites with objects, relations and sources shuffled: the same conditions and roots${differ ? `; ${differ} differ` : ""}`);
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
