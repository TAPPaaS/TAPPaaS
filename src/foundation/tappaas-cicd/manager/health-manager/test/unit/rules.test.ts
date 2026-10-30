// rules.test.ts — `rules list|check` (ADR-041 D3): the shipped file holds, and
// check refuses what it cannot place, by the check the controller applies at load.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkRules, cmdRules, ruleLine } from "../../src/rules";
import { shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const model = shippedModel();
const rule = (over: Record<string, unknown>) => ({ rules: [{ relation: "runs-on", source: { type: "operational", status: "critical" }, impact: "critical", ...over }] });

check(checkRules({ rules: model.rules }, model).length === 0, "the shipped rules hold");
check(model.rules.length === 4 && model.rules.every((r) => r.source.status === "critical" && r.impact === "critical"), "…four, and a warning crosses nothing");
check(["runs-on", "depends-on", "member-of", "connects"].every((t) => model.rules.some((r) => r.relation === t)), "…over the four relations of D3");
const req = (n: string) => model.relations.find((r) => r.name === n);
check(req("runs-on")?.required === true && req("depends-on")?.required === true && req("allocated-to")?.required === true && req("backs-up")?.required === false, "required: runs-on, depends-on, allocated-to; not backs-up");
check(req("allocated-to")?.dependant === "to" && req("runs-on")?.dependant === "from" && req("connects")?.dependant === "both", "each knows which end is hurt");
check(ruleLine(model.rules[0]) === "operational critical crosses runs-on as critical impact", "a rule reads as a line");
check(checkRules(rule({ relation: "powers" }), model).some((p) => p.includes("relation powers is not a relation type")), "check refuses an unknown relation type");
check(checkRules(rule({ relation: "provides" }), model).some((p) => p.includes("no dependant")), "…a relation that carries no health");
check(checkRules(rule({ from: "spaceship" }), model).some((p) => p.includes("spaceship is not a class")), "…an unknown class");
check(checkRules(rule({ source: { type: "impact", status: "critical" } }), model).length === 1, "…impact as a source: it is derived");
check(checkRules(rule({ source: { type: "operational", status: "ok" } }), model).length === 1, "…ok as a source");
check(checkRules(rule({ impact: "sick" }), model).length === 1, "…an unknown impact");
check(checkRules(rule({ relation: "runs-on", from: "vm", to: "machine", source: { type: "capacity", status: "warning" }, impact: "warning" }), model).length === 0, "a site's rule with classes holds");

const lines: string[] = [];
const print = (l: string): void => void lines.push(l);
check(cmdRules(["list"], model, print) === 0 && lines.length === 4, "rules list prints each");
const dir = mkdtempSync(join(tmpdir(), "hm-rules-"));
try {
  const bad = join(dir, "bad.json");
  writeFileSync(bad, JSON.stringify(rule({ relation: "powers" })));
  lines.length = 0;
  check(cmdRules(["check", "--file", bad], model, print) === 1 && lines[0].includes("powers"), "rules check --file: exit 1, naming it");
  check(cmdRules(["check"], model, print) === 0, "rules check: the rules in use hold");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
let threw = false;
try { cmdRules(["nope"], model, print); } catch { threw = true; }
check(threw, "another verb is refused");

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
