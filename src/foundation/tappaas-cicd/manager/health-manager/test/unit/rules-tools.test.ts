// rules-tools.test.ts — contract scenarios, `rules explain`, `rules simulate`,
// and what assess records of the rules: the rule-set hash, the records that
// changed since the last run, and a conflict told as drift on the site.

import { assess } from "../../src/assess";
import { CmdbItem, Condition } from "../../src/assess-model";
import { cmdRules } from "../../src/rules";
import { diffSim, explainObject, parseFailure, simulate } from "../../src/rules-tools";
import { runScenarios } from "../../src/scenarios";
import { NOW, StubIO, cond, obj, rel, shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const now = "2026-10-30T09:00:00.000Z";
const model = shippedModel();
const withConds = (o: CmdbItem, cs: Condition[]): CmdbItem => ({ ...o, attributes: { ...o.attributes, conditions: cs } });

// ── contract scenarios ──
{
  check((model.scenarios ?? []).length >= 8, `the core ships its scenarios (${(model.scenarios ?? []).length})`);
  check(runScenarios(model.scenarios ?? [], model).length === 0, "…and every one holds under the core records");
  const broken = { ...model, records: model.records.filter((r) => r.id !== "core.propagate.runs-on.down") };
  const fails = runScenarios(model.scenarios ?? [], broken);
  check(fails.some((f) => f.id === "core.scenario.node-down" && f.problems.some((p) => p.includes("impact on vm/identity"))), "a set without the runs-on record passes the static check but fails node-down");
  check(runScenarios(model.scenarios ?? [], broken, new Set(fails.map((f) => f.id))).length === 0, "…a retired scenario is not run");
  const lines: string[] = [];
  check(cmdRules(["check"], broken, (l) => lines.push(l)) === 1 && lines.some((l) => l.includes("core.scenario.node-down") && l.includes("no longer holds")), "rules check refuses it, naming the scenario");
}

// ── explain and simulate on a snapshot ──
const node = obj("machine", "tappaas1");
const guest = obj("vm", "identity");
const ha = obj("vm", "firewall", { haNode: "tappaas2" });
const svc = obj("service", "identity:identity");
const nc = obj("vm", "nextcloud");
const rels = [rel("runs-on", guest, node), rel("runs-on", ha, node), rel("runs-on", svc, guest), rel("depends-on", nc, svc)];
{
  const snap = { objects: [withConds(node, [cond("operational", "critical", "node-down", { since: "2026-10-30T02:00:00.000Z" })]), withConds(guest, [cond("operational", "critical", "guest-stopped", { since: "2026-10-30T02:01:00.000Z" }), cond("capacity", "critical", "disk-full")]), ha, svc, withConds(nc, [{ ...cond("impact", "critical", "x"), owner: "derive", derived: true }])], relations: rels };
  const x = explainObject(snap, model, now, "identity");
  const op = x.conditions.find((c) => c.type === "operational");
  const cap = x.conditions.find((c) => c.type === "capacity");
  const imp = x.conditions.find((c) => c.type === "impact");
  check(op?.how === "derived" && op.rootCause === node.id && op.rule === "core.explain.same-failure", "explain: the guest's stop is derived from its node, by the same-failure record");
  check(cap?.how === "covered" && cap.rule === "core.explain.down-covers", "…its full disk is covered while the node is down");
  check(imp?.how === "impact" && imp.path?.[0]?.rule === "core.propagate.runs-on.down" && imp.path[0].relation === "runs-on", "…its impact: the hop from the node, over runs-on, with the record");
  const xh = explainObject(snap, model, now, "firewall");
  const hop = xh.conditions.find((c) => c.type === "impact")?.path?.[0];
  check(hop?.rule === "core.propagate.runs-on.down-ha" && hop.lost.some((l) => l.id === "core.propagate.runs-on.down"), "…for an HA guest the HA record won, and the plain one lost to it");
  const nx = explainObject(snap, model, now, nc.id);
  check(nx.conditions.find((c) => c.type === "impact")?.path?.length === 3, "…a stored impact is computed again, three hops from the node");
  const lines: string[] = [];
  check(cmdRules(["explain", "identity"], model, (l) => lines.push(l), undefined, { snapshot: () => snap, now: () => now }) === 0 && lines[0] === "vm identity" && lines.some((l) => l.includes("lost") === false && l.includes("core.propagate.runs-on.down")), "rules explain prints it");
}
{
  const snap = { objects: [node, guest, ha, svc, nc], relations: rels };
  check(JSON.stringify(parseFailure("identity:identity")) === JSON.stringify({ object: "identity:identity", type: "operational", status: "critical" }) && parseFailure("tank:performance:warning").type === "performance", "a failure: <object>[:type[:status]], a name may hold a colon");
  const before = simulate(snap, model, now, []);
  const after = simulate(snap, model, now, [parseFailure("tappaas1")]);
  check(before.roots.length === 0 && after.roots.length === 1 && after.roots[0].id === node.id && after.roots[0].impacted === 4, `simulate --fail tappaas1: one root, impacting four (${after.roots[0]?.impacted})`);
  const d = diffSim(before, after, snap.objects);
  check(d.rootsNew.length === 1 && d.colours.some((c) => c.id === ha.id && c.to === "warning") && d.colours.some((c) => c.id === nc.id && c.to === "critical"), "…the diff: a new root, the HA guest warning, nextcloud critical");
  const without = simulate(snap, model, now, [parseFailure("tappaas1")], { without: ["core.propagate.runs-on.down-ha"] });
  check(without.colours[ha.id] === "critical", "--without the HA record: the HA guest goes critical");
  const soft = simulate(snap, model, now, [parseFailure("tappaas1")], { with: [{ id: "site.propagate.nc", kind: "propagate", when: { relation: "depends-on", dependant: { name: "nextcloud" }, condition: { type: "operational", status: "critical" } }, as: "none" }] });
  check(soft.colours[nc.id] === undefined || soft.colours[nc.id] === "ok", "--with a softening record: nextcloud untouched");
  const lines: string[] = [];
  check(cmdRules(["simulate", "--fail", "tappaas1", "--diff"], model, (l) => lines.push(l), undefined, { snapshot: () => snap, now: () => now }) === 0 && lines.some((l) => l.startsWith("+ root machine tappaas1")), "rules simulate --diff prints it");
}

// ── explain a sum of others (a classify record's aggregate) ──
{
  const unit = withConds(obj("vm", "coturn"), [{ ...cond("vulnerability", "warning", "cve-medium"), owner: "cve", aggregate: true }]);
  const x = explainObject({ objects: [unit], relations: [] }, model, now, "coturn");
  check(x.conditions.find((c) => c.type === "vulnerability")?.how === "sum", "explain: a condition a classify record made a sum is said to be one, never a root, and names no root");
  const lines: string[] = [];
  cmdRules(["explain", "coturn"], model, (l) => lines.push(l), undefined, { snapshot: () => ({ objects: [unit], relations: [] }), now: () => now });
  check(lines.some((l) => l.includes("a sum of others") && !l.includes("same failure as ,")), "…and reads so");
}

// ── assess records the rules ──
{
  const site = obj("site", "home");
  const io = new StubIO([site, node, guest], [rel("runs-on", guest, node)]);
  const r = assess(io, {}, NOW);
  const stamp = (r.report?.objects?.find((o) => o.id === site.id)?.attributes as { assessment?: { rules?: { hash: string; records: Record<string, string>; changed?: string[] } } }).assessment?.rules;
  check(/^[0-9a-f]{64}$/.test(stamp?.hash ?? "") && Object.keys(stamp?.records ?? {}).length === model.records.filter((x) => x.enabled !== false).length && !stamp?.changed, "the site's assessment carries the rule-set hash and each record's");
  io.model = { ...io.model, records: io.model.records.map((x) => (x.id === "core.follow.port" ? { ...x, enabled: false } : x)) };
  const r2 = assess(io, {}, NOW);
  const s2 = (r2.report?.objects?.find((o) => o.id === site.id)?.attributes as { assessment?: { rules?: { hash: string; changed?: string[] } } }).assessment?.rules;
  check(s2?.hash !== stamp?.hash && JSON.stringify(s2?.changed) === '["core.follow.port"]', `…a changed set: a new hash, and the records that changed (${JSON.stringify(s2?.changed)})`);
  io.model = shippedModel([{ id: "site.propagate.dmz", kind: "propagate", when: { relation: "runs-on", dependant: { zone: "dmz" }, condition: { type: "operational", status: "critical" } }, as: { status: "critical" } }]);
  const r3 = assess(io, {}, NOW);
  const drift = r3.objects.find((o) => o.id === site.id)?.conditions.find((c) => c.type === "drift");
  check(drift?.status === "warning" && drift.reason === "rules-conflict" && drift.message.includes("site.propagate.dmz"), "a conflict in the set: a drift warning on the site");
  io.model = shippedModel();
  const r4 = assess(io, {}, NOW);
  check(r4.objects.find((o) => o.id === site.id)?.conditions.find((c) => c.type === "drift")?.status === "ok", "…over once the set holds again");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
