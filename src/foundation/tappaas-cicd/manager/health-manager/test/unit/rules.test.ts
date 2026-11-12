// rules.test.ts — the health records and `rules list|check`: the shipped core
// records hold, each kind's schema is checked, the match language decides
// containment, overlap and the winner, a conflict is found statically, and a
// record reads as a sentence. Dependency cycles in the relations still fail check.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { cmdRules, cycleProblems, markdownList, modelInfo } from "../../src/rules";
import { sentence } from "../../src/rule-text";
import { HealthRecord, checkRecord, checkSet, conflicts, flatten, holds, matches, pick, ruleSetHash, strictlyMoreSpecific } from "../../../../lib/ts/src/health-records";
import { obj, rel, shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const model = shippedModel();
const info = modelInfo(model);
const anc = model.ancestors;
const byId = (id: string): HealthRecord => model.records.find((r) => r.id === id)!;
const errors = (r: unknown): string[] => checkRecord(r, info).filter((p) => p.level === "error").map((p) => p.message);

// ── the shipped records ──
{
  const problems = checkSet(model.records, info);
  check(problems.length === 0, `the core records hold, with no conflict (${problems.map((p) => p.message).join("; ")})`);
  const kinds = new Set(model.records.map((r) => r.kind));
  check(["propagate", "combine", "explain", "follow", "rollup"].every((k) => kinds.has(k as HealthRecord["kind"])), "…every kind today's engine needs");
  check(model.records.every((r) => r.id.startsWith("core.")), "…all of origin core");
  check(model.records.filter((r) => r.kind === "propagate").length === 9, "…today's eleven rules as nine propagate records");
  const ha = byId("core.propagate.runs-on.down-ha");
  const down = byId("core.propagate.runs-on.down");
  check(strictlyMoreSpecific(flatten(ha), flatten(down), anc) && !strictlyMoreSpecific(flatten(down), flatten(ha), anc), "HA is strictly more specific than the plain runs-on record");
  check(sentence(ha) === "a critical operational failure crosses runs-on to its dependant with haNode as a warning impact", `…and reads so (${sentence(ha)})`);
  check(strictlyMoreSpecific(flatten(byId("core.rollup.site")), flatten(byId("core.rollup.collection")), anc), "the site's roll-up beats a collection's: a site is a collection");
  check(strictlyMoreSpecific(flatten(byId("core.rollup.environment-score")), flatten(byId("core.rollup.collection")), anc), "…and the environment's score beats both for security");
  const md = markdownList(model.records);
  check(md.includes("**propagate**") && md.some((l) => l.startsWith("- `core.propagate.runs-on.down-ha`: ")), "the README block: by kind, one line per record with its id");
}

// ── predicates ──
{
  check(holds({ isA: ["node"] } as never, "vm", anc) && !holds({ isA: ["node"] } as never, "port", anc), "a class matches its subclasses");
  check(holds({ exists: true }, "tappaas2", anc) && !holds({ exists: true }, "", anc) && !holds({ exists: true }, undefined, anc), "exists: set to something");
  check(holds({ glob: "alert-*" }, "alert-backup", anc) && !holds({ glob: "alert-*" }, "pool-usage", anc) && holds({ glob: "*-usage" }, "pool-usage", anc), "a glob at either end");
  check(holds(["a", "b"], "b", anc) && !holds(["a", "b"], "c", anc), "a list is one of");
  check(holds({ over: "24h" }, 25 * 3600e3, anc) && !holds({ over: "24h" }, 23 * 3600e3, anc), "an age over");
  check(matches({ relation: "runs-on", "dependant.attr.haNode": { exists: true } }, (k) => ({ relation: "runs-on", "dependant.attr.haNode": "n2" } as Record<string, unknown>)[k], anc), "a flat when matches its context");
}

// ── specificity and the winner ──
{
  const p = (id: string, when: object, status: "warning" | "critical" = "critical", extra: object = {}): HealthRecord => ({ id, kind: "propagate", when, as: { status }, ...extra }) as HealthRecord;
  const vm = p("site.propagate.vm", { relation: "runs-on", dependant: { class: "vm" } }, "warning");
  const node = p("site.propagate.node", { relation: "runs-on", dependant: { class: "node" } });
  check(strictlyMoreSpecific(flatten(vm), flatten(node), anc), "class vm is more specific than class node");
  const two = p("site.propagate.two", { relation: "runs-on", dependant: { class: ["vm", "machine"] } }, "warning");
  check(!strictlyMoreSpecific(flatten(two), flatten(p("x.y", { relation: "runs-on", dependant: { class: "vm" } })), anc), "a list of two classes is not more specific than one of them");
  const zone = p("site.propagate.dmz", { relation: "runs-on", dependant: { zone: "dmz" } }, "warning");
  const ha = byId("core.propagate.runs-on.down-ha");
  const zc = p("site.propagate.dmz", { relation: "runs-on", dependant: { zone: "dmz" }, condition: { type: "operational", status: "critical" } }, "critical");
  check(conflicts([ha, zc], anc).length === 1, "HA and a DMZ rule that decide differently, neither more specific: a conflict");
  check(conflicts([ha, { ...zc, overrides: [ha.id] } as HealthRecord], anc).length === 0, "…none once one names the other in overrides");
  check(conflicts([zone, { ...zone, id: "site.propagate.dmz2" } as HealthRecord], anc).length === 0, "two that agree are no conflict");
  const cands = [ha, zc].map((rec) => ({ rec, flat: flatten(rec) }));
  const got = pick(cands, anc);
  check(got.winner?.id === zc.id && got.conflict.length === 2, "evaluated anyway: the more severe outcome, reported as a conflict");
  const ov = pick([{ rec: ha, flat: flatten(ha) }, { rec: { ...zc, overrides: [ha.id] } as HealthRecord, flat: flatten(zc) }], anc);
  check(ov.winner?.id === zc.id && ov.conflict.length === 0 && ov.beaten[0]?.why === "overridden", "…an override decides, and says so");
  const e1: HealthRecord = { id: "core.explain.a", kind: "explain", when: { cause: { sameType: true } }, effect: "derived" };
  const e2: HealthRecord = { id: "core.explain.b", kind: "explain", when: { cause: { status: "critical" } }, effect: "covered" };
  const e3: HealthRecord = { id: "site.explain.sec", kind: "explain", when: { cause: { status: "critical" }, condition: { type: "security" } }, effect: "none" };
  check(conflicts([e1, e2, e3], anc).length === 0, "explain: derived and covered answer different questions; a none is an exception to what it beats");
}

// ── each kind's schema ──
{
  check(errors({ id: "core.x", kind: "spread", when: {} }).some((m) => m.includes("kind spread")), "an unknown kind is refused");
  check(errors({ id: "Core X", kind: "follow", when: {}, relation: "part-of", types: ["operational"] }).some((m) => m.includes("id is")), "…an id that is not <origin>.<name>");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "powers" }, as: { status: "critical" } }).some((m) => m.includes("powers is not a relation")), "…an unknown relation");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "provides" }, as: { status: "critical" } }).some((m) => m.includes("no dependant end")), "…a relation without a dependant, unless the record names one");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "provides" }, as: { status: "critical" }, dependantEnd: "to" }).length === 0, "…which it may");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "runs-on", dependant: { class: "spaceship" } }, as: { status: "critical" } }).some((m) => m.includes("spaceship is not a class")), "…an unknown class");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "runs-on", dependant: { attr: { haNod: true } } }, as: { status: "critical" } }).length === 0, "an attribute is not checked without the classes' fields");
  check(checkRecord({ id: "site.p", kind: "propagate", when: { relation: "runs-on", dependant: { attr: { haNod: true } } }, as: { status: "critical" } }, { ...info, fields: ["haNode"] }).some((p) => p.message.includes("haNod is no class's attribute")), "…with them, a misspelt one is refused");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "runs-on" }, as: { status: "ok" } }).length === 1, "…an impact that is not a failure");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "runs-on", condition: { type: "nope" } }, as: "none" }).some((m) => m.includes("nope is not a condition type")), "…an unknown condition type");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "runs-on", dependant: { attr: { cores: { gte: 4 } } } }, as: "none" }).some((m) => m.includes("numeric")), "…a numeric predicate, not available yet");
  check(errors({ id: "site.p", kind: "propagate", when: { relation: "runs-on", dependant: { name: { glob: "a*b" } } }, as: "none" }).some((m) => m.includes("glob")), "…a glob with * in the middle");
  check(errors({ id: "site.p", kind: "propagate", when: { finding: {} }, as: "none" }).some((m) => m.includes("when.finding")), "…a selector the kind does not have");
  check(errors({ id: "site.c", kind: "combine", when: { relation: "depends-on" }, groupBy: "dependant", steps: [{ down: 1, as: "critical" }, { down: 3, as: "warning" }] }).some((m) => m.includes("softer")), "combine: steps that soften as more fail are refused");
  check(errors({ id: "site.c", kind: "combine", when: { relation: "member-of" }, groupBy: "dependant", steps: [{ down: 1, as: "warning" }, { down: "half", as: "rule" }] }).length === 0, "…a quorum holds");
  check(errors({ id: "site.q", kind: "classify", when: { finding: { status: "warning" } }, quiet: true }).some((m) => m.includes("quiet record names")), "classify: a quiet record must name a reason, a label or an object");
  check(errors({ id: "site.q", kind: "classify", when: { finding: { reason: "alert-ups" } }, quiet: true }).length === 0, "…one that names a reason holds");
  check(errors({ id: "site.q", kind: "classify", when: { finding: {} }, set: { status: "ok" } }).length === 1, "…a rule never makes a failure ok");
  check(errors({ id: "site.n", kind: "notify", when: { condition: { status: "critical" } }, notify: "none" }).some((m) => m.includes("names a reason")), "notify none names what it is about");
  check(errors({ id: "site.r", kind: "rollup", when: { object: { class: "cluster" } }, fn: { kOfN: { warning: 1, critical: "half" } }, members: [{ relations: ["member-of"], walk: "inbound" }] }).length === 0, "rollup: k of n holds");
  check(errors({ id: "site.r", kind: "rollup", when: { object: { class: "cluster" } }, fn: "worst" }).some((m) => m.includes("names its members")), "…a sum needs its members");
  const dup = checkSet([byId("core.follow.port"), byId("core.follow.port")], info);
  check(dup.some((p) => p.message.includes("used 2 times")), "an id twice in a set is refused");
}

// ── the hash ──
{
  const h = ruleSetHash(model.records);
  check(/^[0-9a-f]{64}$/.test(h) && h === ruleSetHash([...model.records].reverse()), "the rule-set hash: SHA-256, independent of order");
  check(h !== ruleSetHash(model.records.map((r) => (r.id === "core.follow.port" ? { ...r, enabled: false } : r))), "…a record turned off changes it");
  check(h === ruleSetHash(model.records.map((r) => ({ ...r, when: JSON.parse(JSON.stringify(r.when)) }))), "…key order inside a record does not");
}

// ── the verbs ──
const lines: string[] = [];
const print = (l: string): void => void lines.push(l);
check(cmdRules(["list"], model, print) === 0 && lines.length === model.records.length && lines[0].includes(": "), "rules list prints one sentence each");
lines.length = 0;
check(cmdRules(["list", "--kind", "explain"], model, print) === 0 && lines.length === 2, "…--kind filters");
lines.length = 0;
check(cmdRules(["list", "--json"], model, print) === 0 && JSON.parse(lines.join("\n")).every((r: { origin: string; sentence: string }) => r.origin === "core" && r.sentence), "…--json carries origin and sentence");
const dir = mkdtempSync(join(tmpdir(), "hm-rules-"));
try {
  const bad = join(dir, "bad.json");
  writeFileSync(bad, JSON.stringify({ records: [{ id: "site.propagate.x", kind: "propagate", when: { relation: "powers" }, as: { status: "critical" } }] }));
  lines.length = 0;
  check(cmdRules(["check", "--file", bad], model, print) === 1 && lines[0].includes("powers"), "rules check --file: exit 1, naming it");
  const clash = join(dir, "clash.json");
  writeFileSync(clash, JSON.stringify({ records: [{ id: "site.propagate.dmz", kind: "propagate", when: { relation: "runs-on", dependant: { zone: "dmz" }, condition: { type: "operational", status: "critical" } }, as: { status: "critical" } }] }));
  lines.length = 0;
  check(cmdRules(["check", "--file", clash], model, print) === 1 && lines.some((l) => l.includes("conflicts with") && l.includes("core.propagate.runs-on.down-ha") && l.includes("site.propagate.dmz")), "…a file that conflicts with the rules in use");
  lines.length = 0;
  check(cmdRules(["check"], model, print) === 0, "rules check: the rules in use hold");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
let threw = false;
try { cmdRules(["nope"], model, print); } catch { threw = true; }
check(threw, "another verb is refused");

// ── dependency cycles (the identity stop of 2026-11-05) ──
{
  const m1 = obj("machine", "tappaas1");
  const vm = obj("vm", "identity");
  const svc = obj("service", "identity:identity");
  const app = obj("app", "console");
  const port1 = obj("port", "p1");
  const port2 = obj("port", "p2");
  const acyclic = [rel("runs-on", vm, m1), rel("runs-on", svc, vm), rel("runs-on", app, m1), rel("depends-on", app, svc), rel("connects", port1, port2)];
  check(cycleProblems(acyclic, model).length === 0, "an app that depends on a service on its own host: no cycle (a cable's two ends are none either)");
  const cyclic = [...acyclic, rel("depends-on", m1, svc)];
  const found = cycleProblems(cyclic, model);
  check(found.length === 1 && found[0].includes("machine/tappaas1") && found[0].includes("vm/identity") && found[0].includes("service/identity:identity"), `a machine that depends on a service on its own guest is a cycle (${found[0]})`);
  const out: string[] = [];
  check(cmdRules(["check"], model, (l) => out.push(l), () => cyclic) === 1 && out.some((l) => l.includes("cycle")), "rules check fails on it");
  const ok: string[] = [];
  check(cmdRules(["check"], model, (l) => ok.push(l), () => acyclic) === 0 && ok[0].includes("no dependency cycle"), "…and passes without it");
  const optional = [...acyclic, { ...rel("depends-on", m1, svc), attributes: { required: false } }];
  check(cycleProblems(optional, model).length === 0, "an optional relation closes no cycle");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
