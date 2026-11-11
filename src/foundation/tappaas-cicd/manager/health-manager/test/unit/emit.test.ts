// emit.test.ts — offline tests for the emitting half (ADR-041 D2, D4): the
// CMDB is a stub holding objects and the periods of their `conditions`.

import { mkdtempSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { ack, endedBeforeEmit, maintenanceStart, maintenanceStop, reconcileAcks, silenced, unack } from "../../src/ack";
import { Condition, HealthCmdb, HealthObject, Period, conditionsOf, splitRef } from "../../src/emit-cmdb";
import { Cursor, assessInterval, byClass, deliverNotices, emit, flapPercent, flappingNow, readCursor, runEmit, transitions, withEmitLock } from "../../src/emit";
import { historyLines, historyRows, listLines, listRows, rootDocs, rootLines, showDoc, showLines } from "../../src/emit-read";
import { AckEvent, HealthEvent, MaintenanceEvent, TransitionEvent, eventLine } from "../../src/events";
import { planNotices } from "../../src/notices";
import { EMIT_HELP, EmitContext, parseWhen, runEmitVerb } from "../../src/emit-verbs";

// test.sh turns the CMDB off for the verbs under test; this one is a stub.
delete process.env.TAPPAAS_CMDB;

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

const NOW = new Date("2026-10-30T12:00:00.000Z");
const T = (min: number): string => new Date(NOW.getTime() + min * 60000).toISOString();

const cond = (type: string, status: Condition["status"], since: string, more: Partial<Condition> = {}): Condition => ({ type, status, reason: `${type}-${status}`, message: `${type} is ${status}`, since, ...more });
const object = (id: string, cls: string, conditions: Condition[]): HealthObject => ({ id, class: cls, name: id, attributes: { conditions } });

class Stub implements HealthCmdb {
  written: { id: string; kind: string; verb?: string; conditions: Condition[] }[] = [];
  history = new Map<string, Period[]>();
  past: HealthObject[] = [];
  constructor(public all: HealthObject[]) {}
  objects(at?: string): HealthObject[] {
    return JSON.parse(JSON.stringify(at ? this.past : this.all)) as HealthObject[];
  }
  objectsOfClass(cls: string): HealthObject[] {
    return this.all.filter((o) => o.class === cls);
  }
  resolve(ref: string): HealthObject {
    const r = splitRef(ref).ref;
    const o = this.all.find((x) => x.id === r || x.name === r);
    if (!o) throw new Error(`no object ${ref}`);
    return o;
  }
  periods(id: string): Period[] {
    return this.history.get(id) ?? [];
  }
  write(o: HealthObject, conditions: Condition[], meta: { kind: string; verb?: string }): void {
    this.written.push({ id: o.id, kind: meta.kind, verb: meta.verb, conditions });
    const stored = this.all.find((x) => x.id === o.id);
    if (stored) stored.attributes.conditions = conditions;
  }
}

const period = (value: Condition[], from: string, change: number): Period => ({ name: "conditions", value, change, from, to: null });
const cursor = (minutesAgo: number, change: number, roots: Cursor["roots"] = {}): Cursor => ({ time: T(-minutesAgo), change, roots });
const transitionsIn = (es: HealthEvent[]): TransitionEvent[] => es.filter((e): e is TransitionEvent => e.event === "transition" || e.event === "flapping");

// A node down: the node is the root, its guest impacted.
function nodeDown(): Stub {
  const node = object("node1", "machine", [cond("operational", "critical", T(-3))]);
  const vm = object("vm1", "vm", [cond("operational", "critical", T(-3), { derived: true, rootCause: "node1" }), cond("impact", "critical", T(-3), { derived: true, rootCause: "node1" })]);
  const lone = object("vm2", "vm", [cond("capacity", "warning", T(-3))]);
  const site = object("site1", "site", [cond("operational", "critical", T(-3), { derived: true })]);
  site.attributes.rootCauses = [{ id: "node1", type: "operational", impactedCount: 1 }];
  const s = new Stub([node, vm, lone, site]);
  s.past = [object("node1", "machine", [cond("operational", "ok", T(-60))])];
  s.history.set("node1", [period([cond("operational", "ok", T(-60))], T(-60), 5), period([cond("operational", "critical", T(-3))], T(-3), 8)]);
  s.history.set("vm1", [period([cond("operational", "ok", T(-60))], T(-60), 5), period(vm.attributes.conditions!, T(-3), 8)]);
  s.history.set("vm2", [period([cond("capacity", "warning", T(-3))], T(-3), 8)]);
  s.history.set("site1", [period(site.attributes.conditions!, T(-3), 8)]);
  return s;
}

console.log("transitions");
{
  const ts = transitions([
    period([cond("drift", "ok", T(-30))], T(-30), 1),
    period([cond("drift", "warning", T(-20)), cond("backup", "ok", T(-20))], T(-20), 2),
    period([cond("drift", "warning", T(-20), { lastChecked: T(-10) }), cond("backup", "ok", T(-20)), cond("impact", "critical", T(-10))], T(-10), 3),
    period([cond("drift", "warning", T(-20))], T(-5), 4),
  ]);
  check(ts.length === 3, "only status changes are transitions; first seen ok is no news");
  check(ts[0].type === "drift" && ts[0].from === "ok" && ts[0].to === "warning", "ok to warning");
  check(ts[1].type === "impact" && ts[1].from === "unknown" && ts[1].to === "critical", "a new condition comes from unknown");
  check(ts[2].type === "impact" && ts[2].to === "ok", "a condition that goes away has returned to ok");
}

console.log("transitions: a CVE risk level (ADR-045 D4)");
{
  const sec = (status: Condition["status"], reason: string, since: string): Condition => ({ type: "security", status, reason, message: reason, since });
  const ts = transitions([
    period([sec("warning", "cve-medium", T(-30))], T(-30), 1),
    period([sec("warning", "cve-high", T(-20))], T(-20), 2),
    period([sec("warning", "cve-high", T(-20))], T(-15), 3),
    period([sec("warning", "cve-medium", T(-10))], T(-10), 4),
  ]);
  check(ts.length === 3, "medium → high and back are transitions, the status warning throughout; the same level is none");
  check(ts[1].from === "warning" && ts[1].to === "warning" && ts[1].after?.reason === "cve-high", "…the second one, warning to warning, to high");
  const other = transitions([period([cond("drift", "warning", T(-30))], T(-30), 1), period([cond("drift", "warning", T(-20), { reason: "other" })], T(-20), 2)]);
  check(other.length === 1, "another type's reason change is no transition");

  const mod = object("immich", "vm", [sec("warning", "cve-high", T(-3))]);
  const zone = object("rossen", "zone", [sec("warning", "cve-high", T(-3))]);
  const s = new Stub([mod, zone, object("site1", "site", [])]);
  s.past = [object("immich", "vm", [sec("warning", "cve-medium", T(-60))])];
  s.history.set("immich", [period([sec("warning", "cve-medium", T(-60))], T(-60), 5), period([sec("warning", "cve-high", T(-3))], T(-3), 8)]);
  s.history.set("rossen", [period([sec("warning", "cve-medium", T(-60))], T(-60), 5), period([sec("warning", "cve-high", T(-3))], T(-3), 8)]);
  const r = emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 });
  const ev = transitionsIn(r.events);
  const m = ev.find((e) => e.ci === "immich");
  check(m?.levelUp === true && m.reason === "cve-high", "a module rising to high: the event says levelUp");
  check(ev.find((e) => e.ci === "rossen")?.levelUp === undefined, "…a zone never does (its module did)");
  const rules = JSON.parse(readFileSync(join(__dirname, "../../../../../../../tappaas-cicd-alerts.json"), "utf8")) as { rules: { name: string; match: string }[] };
  const rule = (n: string): RegExp => new RegExp(rules.rules.find((x) => x.name === n)!.match.replace(/\(\?P</g, "(?<"));
  check(rule("cve-level-up").test(eventLine(m!)), "cve-level-up's match takes the module's line");
  check(!rule("cve-level-up").test(eventLine(ev.find((e) => e.ci === "rossen")!)), "…not the zone's");
  check(!rule("cve-level-up").test(eventLine({ ...m!, silenced: true })), "…nor an acknowledged one");
  s.history.set("immich", [period([sec("warning", "cve-high", T(-60))], T(-60), 5), period([sec("warning", "cve-medium", T(-3))], T(-3), 8)]);
  s.all[0].attributes.conditions = [sec("warning", "cve-medium", T(-3))];
  const down = transitionsIn(emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 }).events).find((e) => e.ci === "immich");
  check(down !== undefined && down.levelUp === undefined, "going down is told, without levelUp");
}

console.log("emit: kinds");
{
  const s = nodeDown();
  const r = emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 });
  const ts = transitionsIn(r.events);
  const of = (ci: string, type: string): TransitionEvent | undefined => ts.find((e) => e.ci === ci && e.type === type);
  check(of("node1", "operational")?.kind === "causal", "the root's transition is causal");
  check(of("node1", "operational")?.root === true && of("node1", "operational")?.symptoms === 1, "…and says it is a root, with its symptom count");
  check(of("vm1", "impact")?.kind === "symptom" && of("vm1", "impact")?.rootCause === "node1", "an impact is a symptom naming its root");
  check(of("vm1", "operational")?.kind === "symptom", "a derived condition is a symptom");
  check(of("vm2", "capacity")?.kind === "symptom", "failing and no root: a symptom");
  check(of("node1", "operational")!.correlated.includes(of("vm1", "impact")!.id), "the root lists its symptoms' events");
  check(of("vm1", "impact")!.correlated.includes(of("node1", "operational")!.id), "the symptom lists the root's event");
  const op = r.notices.open;
  check(op.length === 1 && op[0].ci === "node1" && op[0].type === "operational", "one notice to open, for the critical root");
  check(op[0].impacted === "1 vm" && of("node1", "operational")?.impacted === "1 vm", "…with the root's consequence by class, as on its event");
  check(!r.events.some((e) => (e as { event: string }).event === "rootcause"), "no rootcause events: nothing reads them");
  check(of("vm1", "impact")?.impacted === "nothing", "a symptom impacts nothing");
  check(/"symptoms":1,"impacted":"1 vm","silenced":false/.test(eventLine(of("node1", "operational")!)), "the journal line carries it beside the symptom count");
  check(r.cursor.change === 8, "the cursor moves to the last change read");
  const delivered = deliverNotices(r.notices, {}, () => true, r.cursor.time);
  const again = emit(s, { ...r.cursor, notices: delivered.open }, { now: NOW, intervalMin: 5 });
  check(transitionsIn(again.events).length === 0, "nothing is told twice");
  check(again.notices.open.length === 0 && again.notices.close.length === 0, "an open notice is not opened again");
  const line = eventLine(of("node1", "operational")!);
  check(/"kind":"causal".*"silenced":false/.test(line), "the journal line has kind before silenced (the rule reads them so)");
  const f = JSON.parse(line) as Record<string, unknown>;
  check(["ci", "class", "name", "type", "from", "to", "reason", "message", "kind", "rootCause", "correlated", "since", "at", "flapping"].every((k) => k in f), "every field of D4 is on the line");
}

console.log("emit: notices follow the root-cause set");
{
  const sent: { subject: string; key: string; resolve: boolean }[] = [];
  const ok = (m: { subject: string }, key: string, resolve: boolean): boolean => (sent.push({ subject: m.subject, key, resolve }), true);
  // A guest that stays down after its node came back: a symptom becomes a root
  // without any status change of its own, and is mailed.
  const s = nodeDown();
  const first = emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 });
  let open = deliverNotices(first.notices, {}, ok, NOW.toISOString()).open;
  s.all[0].attributes.conditions = [cond("operational", "ok", T(1))];
  s.all[1].attributes.conditions = [cond("operational", "critical", T(-3))];
  s.all[3].attributes.rootCauses = [{ id: "vm1", type: "operational", impactedCount: 0 }];
  const later = emit(s, { ...first.cursor, notices: open }, { now: new Date(NOW.getTime() + 120000), intervalMin: 5 });
  check(later.notices.open.length === 1 && later.notices.open[0].ci === "vm1", "a symptom that becomes a root, its status unchanged, opens a notice");
  check(later.notices.close.length === 1 && later.notices.close[0].why === "recovered", "…and the node's closes, recovered");
  sent.length = 0;
  open = deliverNotices(later.notices, open, ok, T(2)).open;
  check(sent.length === 2 && sent.some((x) => x.resolve && x.key === "health-root:node1:operational" && x.subject.includes("(recovered)")), "the close is a RESOLVED on the alert's key, saying why");
  // Eased to a warning: closed, saying so (the old rule never sent this one).
  s.all[1].attributes.conditions = [cond("operational", "warning", T(3))];
  const eased = emit(s, { ...later.cursor, notices: open }, { now: new Date(NOW.getTime() + 240000), intervalMin: 5 }).notices;
  check(eased.close.length === 1 && eased.close[0].why === "eased", "a root that eases to a warning closes its notice: eased");
  // Acknowledged while it holds: closed, acknowledged.
  s.all[1].attributes.conditions = [cond("operational", "critical", T(-3), { acknowledged: { by: "lars", note: "known", until: null } })];
  const acked = emit(s, { ...later.cursor, notices: open }, { now: new Date(NOW.getTime() + 240000), intervalMin: 5 }).notices;
  check(acked.close.length === 1 && acked.close[0].why === "acknowledged" && acked.open.length === 0, "an acknowledged root closes its notice and opens none");
  // A silence that ends while the fault holds: a notice again.
  s.all[1].attributes.conditions = [cond("operational", "critical", T(-3), { maintenance: { until: T(-1), note: "restart" } })];
  const ended = emit(s, { ...later.cursor, notices: {} }, { now: NOW, intervalMin: 5 }).notices;
  check(ended.open.length === 1 && ended.open[0].ci === "vm1", "a maintenance window that ended with the fault still there opens a notice");
  // Flapping holds the notice as it is.
  s.all[1].attributes.conditions = [cond("operational", "warning", T(3), { flapping: true })];
  const flap = planNotices(open, new Map(), s.objects(), [], NOW);
  check(flap.close.length === 0, "a flapping root neither closes nor opens its notice");
  s.all[1].attributes.conditions = [cond("operational", "warning", T(3))];
  check(planNotices(open, new Map(), s.objects(), [], NOW).close.length === 1, "…once it stops flapping, the close goes");
  // A delivery that fails is tried again: not recorded open, and a close stays open.
  const failed = deliverNotices(later.notices, {}, () => false, T(2));
  check(Object.keys(failed.open).length === 0 && failed.events.every((e) => !e.sent), "an undelivered notice is not recorded open");
  const kept = deliverNotices({ open: [], close: later.notices.close }, { "node1:operational": first.notices.open[0] as never }, () => false, T(2));
  check("node1:operational" in kept.open, "an undelivered close stays open, to be tried again");
}
{
  // Not a notice of its own: performance, a module's CVE level, a zone's score, a warning.
  const objs = [
    object("perf", "vm", [cond("performance", "critical", T(-3), { reason: "perf-cpu" })]),
    object("cve", "vm", [cond("security", "critical", T(-3), { reason: "cve-critical" })]),
    object("zone", "zone", [cond("security", "critical", T(-3), { reason: "cve-critical" })]),
    object("warn", "vm", [cond("operational", "warning", T(-3))]),
    object("site1", "site", []),
  ];
  objs[4].attributes.rootCauses = ["perf:performance", "cve:security", "zone:security", "warn:operational"].map((k) => ({ id: k.split(":")[0], type: k.split(":")[1] }));
  const r = emit(new Stub(objs), cursor(5, 6), { now: NOW, intervalMin: 5 });
  check(r.notices.open.length === 0, "performance, CVE levels, zone scores and warnings are no notice of their own");
}
{
  // The rules that stay on log lines, against the lines emit writes (S2).
  const rules = JSON.parse(readFileSync(join(__dirname, "../../../../../../../tappaas-cicd-alerts.json"), "utf8")) as { rules: { name: string; match: string }[] };
  const has = (n: string): boolean => rules.rules.some((x) => x.name === n);
  check(!has("health-root-cause") && !has("health-root-recovered"), "the critical-root mail is no log rule any more: emit sends it");
  const digest = new RegExp(rules.rules.find((x) => x.name === "health-daily-digest")!.match);
  const s = nodeDown();
  const ev = transitionsIn(emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 }).events);
  const root = ev.find((e) => e.ci === "node1")!;
  check(!digest.test(eventLine(root)), "the digest's match does not take a critical root");
  check(digest.test(eventLine({ ...root, to: "warning" })), "…it takes a warning root");
  check(!digest.test(eventLine({ ...root, to: "warning", silenced: true })), "…not a silenced one");
  check(digest.test(eventLine({ ...root, type: "performance", digestOnly: true })), "…and a performance root, digest only");
  check(!digest.test(eventLine({ ...root, to: "warning", kind: "symptom" })), "…never a symptom");
}

console.log("emit: a root's consequence by class");
{
  const objs = [object("a", "vm", []), object("b", "vm", []), object("c", "service", []), object("d", "vm", []), object("e", "service", []), object("f", "port", [])];
  check(byClass(["a", "b", "c", "d", "e", "f"], objs) === "3 vm, 2 service, 1 port", "most first: 3 vm, 2 service, 1 port");
  check(byClass(["c", "a"], objs) === "1 service, 1 vm", "a tie reads by class");
  check(byClass([], objs) === "nothing" && byClass(["gone"], objs) === "1 object", "none is nothing; an object no longer read is an object");
  const s = nodeDown();
  s.all.push(object("svc1", "service", [cond("impact", "critical", T(-3), { derived: true, rootCause: "node1" })]), object("vm3", "vm", [cond("impact", "warning", T(-3), { derived: true, rootCause: "node1" })]));
  s.all[3].attributes.rootCauses = [{ id: "node1", type: "operational", impactedCount: 3 }];
  const r = emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 });
  const root = transitionsIn(r.events).find((e) => e.ci === "node1");
  check(root?.symptoms === 3 && root?.impacted === "2 vm, 1 service", `a root's transition: the count and the classes (${root?.symptoms}: ${root?.impacted})`);
  check(r.cursor.roots["node1:operational"]?.impacted === "2 vm, 1 service", "…kept with the roots told");
  const open = deliverNotices(r.notices, {}, () => true, r.cursor.time).open;
  const gone = emit(new Stub([object("site1", "site", [])]), { ...r.cursor, notices: open }, { now: new Date(NOW.getTime() + 60000), intervalMin: 5 }).notices;
  check(gone.close.length === 1 && gone.close[0].why === "retired", "a root that is no longer in the CMDB closes its notice: retired");
}

console.log("emit: recovery of a root");
{
  const s = nodeDown();
  const first = emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 });
  const node = s.all[0];
  node.attributes.conditions = [cond("operational", "ok", T(1))];
  s.history.get("node1")!.push(period(node.attributes.conditions, T(1), 9));
  s.all[3].attributes.rootCauses = [];
  s.past = JSON.parse(JSON.stringify(s.all)) as HealthObject[];
  const later = new Date(NOW.getTime() + 2 * 60000);
  const open = deliverNotices(first.notices, {}, () => true, first.cursor.time).open;
  const r = emit(s, { ...first.cursor, notices: open }, { now: later, intervalMin: 5 });
  const e = transitionsIn(r.events).find((x) => x.ci === "node1")!;
  check(e.kind === "recovery" && e.root === true, "a recovery of what was a root says so, though it is a root no more");
  check(r.notices.close.length === 1 && r.notices.close[0].why === "recovered", "the root leaves the set: its notice closes, recovered");
}

console.log("emit: the first run and --since");
{
  const dir = mkdtempSync(join(tmpdir(), "health-emit-"));
  const s = nodeDown();
  const lines: string[] = [];
  const mails: string[] = [];
  const es = runEmit(s, (l) => lines.push(...l), dir, { now: NOW }, (m) => (mails.push(m.subject), true));
  check(transitionsIn(es).length === 0 && lines.length === 1 && JSON.parse(lines[0]).event === "notice", "the first run tells only the current roots: one notice");
  check(mails.length === 1 && mails[0].startsWith("ALERT: critical root cause node1"), `…mailed directly (${mails[0]})`);
  check(readCursor(dir)?.notices?.["node1:operational"]?.opened === NOW.toISOString(), "…and recorded open in the cursor");
  check(readCursor(dir)?.time === NOW.toISOString(), "and leaves a cursor");
  writeFileSync(join(dir, "site.json"), JSON.stringify({ health: { assessInterval: 15 } }));
  check(assessInterval(dir) === 15, "the interval is site.json's");
  check(assessInterval(mkdtempSync(join(tmpdir(), "health-emit-"))) === 5, "default 5");
  const again = runEmit(s, () => undefined, dir, { now: NOW, since: T(-10) }, () => true);
  check(transitionsIn(again).length > 0, "--since tells again from that time");
  check(JSON.parse(readFileSync(join(dir, ".health-emit-cursor"), "utf8")).change === 8, "the cursor file holds the change id");
  let inner = true;
  const outer = withEmitLock(dir, () => {
    inner = withEmitLock(dir, () => undefined);
  });
  check(outer && !inner, "a second run does not get the lock");
}

console.log("flapping");
{
  const m = 60000;
  const interval = 5 * m;
  const every = (n: number): number[] => Array.from({ length: Math.ceil(20 / n) }, (_, i) => NOW.getTime() - i * n * interval);
  check(Math.abs(flapPercent(every(1), NOW.getTime(), interval) - 100) < 1e-6, "a change every interval is 100 %");
  check(flapPercent([], NOW.getTime(), interval) === 0, "none is 0 %");
  check(flapPercent(every(2), NOW.getTime(), interval) > 50, "every other interval, newest weighted higher, is over half");
  check(flapPercent([NOW.getTime() - 19 * interval], NOW.getTime(), interval) < flapPercent([NOW.getTime()], NOW.getTime(), interval), "a new change weighs more than an old one");
  check(flappingNow(false, 31) && !flappingNow(false, 30), "starts above 30");
  check(flappingNow(true, 25) && flappingNow(true, 28) && !flappingNow(true, 24.9), "ends below 25, not at 28");

  // A fixture: ok/critical in turn every interval for an hour.
  const obj = object("sw1", "device", [cond("operational", "critical", T(-5))]);
  obj.attributes.conditions![0].since = T(-1);
  const site = object("site1", "site", []);
  site.attributes.rootCauses = [{ id: "sw1", type: "operational", impactedCount: 0 }];
  const s = new Stub([obj, site]);
  const ps: Period[] = [];
  for (let i = 0; i < 12; i++) ps.push(period([cond("operational", i % 2 ? "ok" : "critical", T(-60 + i * 5))], T(-60 + i * 5), i + 1));
  s.history.set("sw1", ps);
  const r = emit(s, cursor(10, 9), { now: NOW, intervalMin: 5 });
  const ts = transitionsIn(r.events);
  check(ts.length === 1 && ts[0].event === "flapping" && ts[0].phase === "start", "one flapping start replaces the storm");
  check(ts[0].to === "critical" && ts[0].flapping, "held at the worse value");
  check(ts[0].kind === "causal", "and mailed once, as a root's");
  const c = conditionsOf(r.objects[0])[0];
  check(c.flapping === true && c.flappingHeld === "critical" && r.writes.has("sw1"), "kept on the condition");
  s.write(r.objects[0], [c], { kind: "observation" });
  ps.push(period([cond("operational", "ok", T(-1))], T(-1), 20));
  const held = emit(s, r.cursor, { now: NOW, intervalMin: 5 });
  check(transitionsIn(held.events).length === 0, "while flapping, a transition tells nothing");
  // Long after: the changes have left the window, with no new transition.
  const quiet = new Date(NOW.getTime() + 200 * m);
  const end = emit(s, held.cursor, { now: quiet, intervalMin: 5 });
  const e = transitionsIn(end.events);
  check(e.length === 1 && e[0].phase === "end" && !e[0].flapping && e[0].from === "critical", "it ends by itself, from the held status");
  check(conditionsOf(end.objects[0])[0].flapping === false && end.writes.has("sw1"), "and the flag goes");
}

console.log("ack and unack");
{
  const s = nodeDown();
  const journal: string[] = [];
  const ctx = { cmdb: s, journal: (l: string[]) => void journal.push(...l), now: NOW, actor: "lars" };
  const es = ack(ctx, { ref: "node1", note: "known", sticky: false });
  const a = es.find((e): e is AckEvent => e.event === "ack")!;
  check(a.by === "lars" && a.symptoms.join() === "vm1", "the ack event names who and the symptoms");
  check(journal.length === 1 && JSON.parse(journal[0]).event === "ack", "the verb tells its event");
  check(s.written.every((w) => w.kind === "change" && w.verb === "ack"), "written as changes");
  const node = s.all[0];
  const vm = s.all[1];
  const impact = (): Condition => conditionsOf(vm).find((c) => c.type === "impact")!;
  check(silenced(conditionsOf(node)[0], NOW), "the root is silenced");
  check(impact().acknowledged?.via?.join() === "node1" && silenced(impact(), NOW), "its impact condition with it");
  check(impact().acknowledged?.sticky === true, "sticky, so assess leaves it to emit");
  check(!conditionsOf(vm).find((c) => c.type === "operational")!.acknowledged, "not the guest's other condition");

  // A symptom that gets a root of its own is heard again.
  impact().rootCause = ["node1", "switch1"];
  const objects = s.objects();
  reconcileAcks(objects, [{ id: "node1", type: "operational" }, { id: "switch1", type: "operational" }], NOW);
  check(!conditionsOf(objects[1]).find((c) => c.type === "impact")!.acknowledged, "a second root hears the symptom again");
  impact().rootCause = "node1";

  unack(ctx, "node1");
  check(!conditionsOf(node)[0].acknowledged, "unack ends the root's");
  check(!impact().acknowledged, "and restores the symptom");
  let thrown = false;
  try {
    unack(ctx, "node1");
  } catch {
    thrown = true;
  }
  check(thrown, "unack of nothing is refused");
}

console.log("acks end by themselves");
{
  const mk = (a: Partial<Condition>, status: Condition["status"] = "critical", since = T(-30)): HealthObject[] => [object("x", "vm", [cond("operational", status, since, a)])];
  const by = { by: "lars", at: T(-20) };
  const run = (o: HealthObject[]): HealthEvent[] => reconcileAcks(o, [], NOW).events;
  check((run(mk({ acknowledged: { ...by, until: T(-1) } }))[0] as AckEvent).why === "expired", "at its until");
  check((run(mk({ acknowledged: { ...by, sticky: true } }, "ok"))[0] as AckEvent).why === "recovered", "on a return to ok, sticky too");
  check((run(mk({ acknowledged: by }, "warning", T(-5)))[0] as AckEvent).why === "changed", "not sticky: at the next status change");
  check(run(mk({ acknowledged: { ...by, sticky: true } }, "warning", T(-5))).length === 0, "sticky: not at a status change");
  check(run(mk({ acknowledged: { ...by, until: T(10) } })).length === 0, "before its until, nothing");
}

console.log("what assess ended before emit ran");
{
  const by = { by: "lars", at: T(-20) };
  const was = (a: Partial<Condition>): HealthObject[] => [object("x", "vm", [cond("operational", "critical", T(-30), a)])];
  const now = (status: Condition["status"] = "critical", since = T(-30)): HealthObject[] => [object("x", "vm", [cond("operational", status, since)])];
  const ended = (b: HealthObject[], n: HealthObject[]): HealthEvent[] => endedBeforeEmit(b, n, NOW);
  check((ended(was({ acknowledged: { ...by, until: T(-1) } }), now())[0] as AckEvent).why === "expired", "an ack past its until is told");
  check((ended(was({ acknowledged: by }), now("warning", T(-2)))[0] as AckEvent).why === "changed", "one ended by a status change");
  check((ended(was({ acknowledged: { ...by, sticky: true } }), now("ok", T(-2)))[0] as AckEvent).why === "recovered", "one ended by recovery");
  check(ended(was({ acknowledged: by }), now()).length === 0, "the operator's unack told its own");
  check(ended(was({ acknowledged: { ...by, via: ["r"] } }), now("ok")).length === 0, "a root's ack on a symptom is not told apart");
  check((ended(was({ maintenance: { until: T(-1) } }), now())[0] as MaintenanceEvent).phase === "end", "a window past its until is told");
  check(ended(was({ maintenance: { until: T(30) } }), now()).length === 0, "one ended early was the operator's");
}

console.log("maintenance");
{
  const s = nodeDown();
  const j: string[] = [];
  const ctx = { cmdb: s, journal: (l: string[]) => void j.push(...l), now: NOW, actor: "lars" };
  const es = maintenanceStart(ctx, "vm2", T(60), "disk swap");
  check((es.at(-1) as MaintenanceEvent).phase === "start", "start is told");
  check(silenced(conditionsOf(s.all[2])[0], NOW), "a condition in a window is silenced");
  s.all[2].attributes.conditions!.push(cond("backup", "warning", T(0)));
  const r = reconcileAcks(s.all, [], NOW);
  check(conditionsOf(s.all[2])[1].maintenance?.until === T(60) && r.dirty.has("vm2"), "one that appears joins the window");
  const expired = reconcileAcks(s.objects(), [], new Date(NOW.getTime() + 3600001));
  check(expired.events.length === 1 && (expired.events[0] as MaintenanceEvent).phase === "end", "it ends at its until, once");
  check((maintenanceStop(ctx, "vm2", "cancel").at(-1) as MaintenanceEvent).phase === "cancel", "cancel is told");
  check(!conditionsOf(s.all[2])[0].maintenance, "and closes it");
  // A transition in a window is told, and silenced.
  maintenanceStart(ctx, "node1", T(60), "reboot");
  const t = transitionsIn(emit(s, cursor(5, 6), { now: NOW, intervalMin: 5 }).events).find((e) => e.ci === "node1")!;
  check(t.kind === "causal" && t.silenced && !/"kind":"causal".*"silenced":false/.test(eventLine(t)), "a window's transition is recorded, and the rule does not match it");
}

console.log("show, list, roots, history");
{
  const s = nodeDown();
  const objs = s.objects();
  const roots = objs[3].attributes.rootCauses!;
  const d = showDoc(objs[1], objs, roots);
  check(d.rootCauses.join() === "node1" && !d.isRoot, "show: a symptom's root");
  check(showLines(d, objs, NOW).some((l) => l === "root cause: machine/node1"), "…named in the table");
  const n = showDoc(objs[0], objs, roots);
  check(n.isRoot && n.impacts[0].id === "vm1", "show: what a root impacts");
  check(showLines(n, objs, NOW).at(-1) === "a root cause; impacts 1: vm/vm1", "…in the table");
  check(listRows(objs, roots, {}).length === 5, "list: everything not ok");
  check(listRows(objs, roots, { status: "ok" }).length === 0, "list --status");
  check(listRows(objs, roots, { type: "capacity" })[0].name === "vm2", "list --type");
  check(listRows(objs, roots, { rootCauses: true }).map((r) => r.name).join() === "node1", "list --root-causes");
  check(listRows(objs, roots, {})[0].status === "critical", "worst first");
  check(listLines(listRows(objs, roots, { type: "capacity" }), NOW)[0].startsWith("OBJECT"), "list: a table");
  const rd = rootDocs(objs, roots);
  check(rd[0].id === "node1" && rd[0].impactedCount === 1 && rd[0].impacted[0].name === "vm1", "roots: each with its impacted");
  check(rootLines(rd).join("\n") === "machine/node1  operational  impacts 1\n  vm/vm1", "roots: lines");
  check(rootLines([])[0] === "no root causes", "roots: none");
  const h = historyRows(s.periods("node1"));
  check(h.length === 1 && h[0].to === "critical", "history: a transition");
  check(historyRows(s.periods("node1"), T(0)).length === 0, "history --since");
  check(historyLines(h)[1].includes("ok") && historyLines([])[0] === "no transitions", "history: lines");
}

console.log("the verbs");
{
  const dir = mkdtempSync(join(tmpdir(), "health-emit-"));
  const s = nodeDown();
  const ctx: EmitContext = { cmdb: s, journal: () => undefined, configDir: dir, now: NOW, actor: "lars" };
  const log = console.log;
  const out: string[] = [];
  const quiet = (fn: () => number | undefined): number | undefined => {
    out.length = 0;
    console.log = (m: string) => void out.push(m);
    try {
      return fn();
    } finally {
      console.log = log;
    }
  };
  check(quiet(() => runEmitVerb("validate", [], ctx)) === undefined, "not a verb of these: left to main");
  check(quiet(() => runEmitVerb("roots", ["--json"], ctx)) === 0 && (JSON.parse(out.join("")) as unknown[]).length === 1, "roots --json");
  check(quiet(() => runEmitVerb("list", ["--class", "vm", "--json"], ctx)) === 0 && (JSON.parse(out.join("")) as { class: string }[]).every((r) => r.class === "vm"), "list --class");
  check(quiet(() => runEmitVerb("show", ["node1"], ctx)) === 0 && out[0].startsWith("machine/node1"), "show");
  check(quiet(() => runEmitVerb("history", ["node1", "--since", "1h", "--json"], ctx)) === 0 && (JSON.parse(out.join("")) as unknown[]).length === 1, "history --since 1h");
  check(quiet(() => runEmitVerb("ack", ["node1", "--note", "known", "--until", "2h"], ctx)) === 0 && conditionsOf(s.all[0])[0].acknowledged?.until === T(120), "ack --until 2h");
  check(quiet(() => runEmitVerb("unack", ["node1"], ctx)) === 0, "unack");
  check(quiet(() => runEmitVerb("maintenance", ["vm2", "--until", "1h", "--note", "x"], ctx)) === 0 && !!conditionsOf(s.all[2])[0].maintenance, "maintenance <ci>");
  check(quiet(() => runEmitVerb("maintenance", ["end", "vm2"], ctx)) === 0 && !conditionsOf(s.all[2])[0].maintenance, "maintenance end <ci>");
  check(quiet(() => runEmitVerb("emit", ["--json"], ctx)) === 0 && Array.isArray(JSON.parse(out.join(""))), "emit --json");
  check(parseWhen("30m", NOW, -1) === T(-30), "a span back");
  check(EMIT_HELP.every((v) => v.effect !== undefined), "every verb declares its effect");
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
