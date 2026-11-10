// rules.test.ts — `rules list|check` (ADR-041 D3): the shipped file holds, and
// check refuses what it cannot place, by the check the controller applies at
// load; a rule's dependant clause validates and prints.

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
const ops = model.rules.filter((r) => r.source.type === "operational");
check(ops.length === 7 && ops.every((r) => r.source.status === "critical"), "…seven operational, and an operational warning crosses nothing");
check(ops.filter((r) => !r.dependant).every((r) => r.impact === "critical"), "…an operational critical crosses as critical");
const perf = model.rules.filter((r) => r.source.type === "performance");
check(perf.length === 4 && perf.every((r) => r.impact === "warning"), "…four performance rules (ADR-046 D6), each a warning impact");
const ha = model.rules.find((r) => r.dependant);
check(ha?.relation === "runs-on" && ha?.dependant?.haNode === true && ha?.impact === "warning", "…but to an HA-protected guest as a warning");
check(ruleLine(ha!) === "operational critical crosses runs-on to a dependant with haNode set as warning impact", `…and reads so (${ruleLine(ha!)})`);
check(ruleLine({ ...ha!, dependant: { stage: "operational", haNode: true } }).includes("with stage=operational, haNode set"), "a clause of several attributes reads each");
check(["runs-on", "depends-on", "member-of", "connects", "built-on"].every((t) => model.rules.some((r) => r.relation === t)), "…over the four relations of D3, and a disk's built-on");
const req = (n: string) => model.relations.find((r) => r.name === n);
check(req("built-on")?.dependant === "from" && req("built-on")?.required === true, "built-on: the pool is hurt when its disk fails");
check(req("stored-on")?.dependant === "from" && req("stored-on")?.required === true, "stored-on: a guest or datastore is hurt when its pool fails");
const so = model.rules.filter((r) => r.relation === "stored-on" && r.source.type === "operational");
check(so.length === 1 && so[0].source.status === "critical" && so[0].impact === "critical" && !so[0].dependant, "…crossed by an operational critical as critical");
check(model.rules.filter((r) => r.relation === "stored-on" && r.source.type === "performance").every((r) => r.to === "storage-pool" && r.impact === "warning"), "…and a slow pool's performance as a warning");
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
check(checkRules(rule({ dependant: { haNode: true, stage: "operational", vmid: 140 } }), model).length === 0, "a dependant clause of strings, numbers and true holds");
check(checkRules(rule({ dependant: {} }), model).some((p) => p.includes("dependant is an object")), "…an empty one is refused");
check(checkRules(rule({ dependant: "haNode" }), model).some((p) => p.includes("dependant is an object")), "…so is one that is no object");
check(checkRules(rule({ dependant: { haNode: ["a"] } }), model).some((p) => p.includes("dependant.haNode is a string")), "…and a value that is no scalar");
const withFields = { ...model, fields: ["haNode", "stage"] };
check(checkRules(rule({ dependant: { haNode: true } }), withFields).length === 0, "with the classes' attributes served: one some class declares holds");
check(checkRules(rule({ dependant: { haNod: true } }), withFields).some((p) => p.includes("dependant.haNod is no class's attribute")), "…a misspelt one is refused");

const lines: string[] = [];
const print = (l: string): void => void lines.push(l);
check(cmdRules(["list"], model, print) === 0 && lines.length === model.rules.length, "rules list prints each");
lines.length = 0;
check(cmdRules(["list", "--json"], model, print) === 0 && JSON.parse(lines.join("\n")).some((r: { dependant?: unknown }) => r.dependant), "rules list --json carries the dependant clause");
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
