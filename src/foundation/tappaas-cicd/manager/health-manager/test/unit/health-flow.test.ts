// health-flow.test.ts — assess, then emit, then the notices, over several runs:
// the case of 2026-11-05 on hrossen. A machine carries a standing warning, the
// identity VM stops and comes back, a second fault comes and goes, and one root
// is retired. Each critical root gets one notice and one close, saying why.

import { CmdbItem } from "../../src/assess-model";
import { assess } from "../../src/assess";
import { Condition, HealthCmdb, HealthObject, Period, splitRef } from "../../src/emit-cmdb";
import { Cursor, deliverNotices, emit } from "../../src/emit";
import { StubIO, obj, rel } from "./assess-fixture";
import { CheckResult } from "../../src/types";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const T0 = Date.parse("2026-11-05T11:40:00.000Z");
const at = (min: number): Date => new Date(T0 + min * 60_000);

// The CMDB both halves read: assess's StubIO writes conditions into the items,
// and the history emit reads is kept per object here.
class Cmdb implements HealthCmdb {
  history = new Map<string, Period[]>();
  change = 0;
  constructor(public items: CmdbItem[]) {}
  objects(): HealthObject[] { return JSON.parse(JSON.stringify(this.items)) as HealthObject[]; }
  objectsOfClass(cls: string): HealthObject[] { return this.objects().filter((o) => o.class === cls); }
  resolve(ref: string): HealthObject { return this.objects().find((o) => o.id === splitRef(ref).ref || o.name === splitRef(ref).ref)!; }
  periods(id: string): Period[] { return this.history.get(id) ?? []; }
  write(o: HealthObject, attributes: Record<string, unknown>): void { Object.assign(this.items.find((x) => x.id === o.id)!.attributes, attributes); }
  record(when: Date): void {
    this.change++;
    for (const o of this.items) {
      const cs = (o.attributes.conditions ?? []) as Condition[];
      const ps = this.history.get(o.id) ?? [];
      const last = ps[ps.length - 1];
      const sig = (v: unknown): string => JSON.stringify(((v ?? []) as Condition[]).map(({ lastChecked: _, ...c }) => c));
      if (last && sig(last.value) === sig(cs)) continue;
      if (last) last.to = when.toISOString();
      ps.push({ name: "conditions", value: JSON.parse(JSON.stringify(cs)), change: this.change, from: when.toISOString(), to: null });
      this.history.set(o.id, ps);
    }
  }
}

const site = obj("site", "rossen");
const m1 = obj("machine", "tappaas1");
const m3 = obj("machine", "tappaas3");
const idv = obj("vm", "identity");
const sso = obj("service", "identity:identity");
const app = obj("app", "tappaas-console");
const nc = obj("vm", "nextcloud");
const items: CmdbItem[] = [site, m1, m3, idv, sso, app, nc].map((o) => ({ ...o, attributes: { ...o.attributes } }));
const rels = [rel("runs-on", idv, m1), rel("runs-on", sso, idv), rel("runs-on", app, m1), rel("depends-on", app, sso), rel("runs-on", nc, m3)];

const gate = (name: string, rows: CheckResult["rows"], judged: CheckResult["judged"]): CheckResult => ({ name, status: rows?.some((r) => r.status === "fail") ? "fail" : rows?.some((r) => r.status === "warn") ? "warn" : "pass", detail: name, rows, judged });
const mod = (name: string): { kind: "module"; name: string } => ({ kind: "module", name });
const node = (name: string): { kind: "node"; name: string } => ({ kind: "node", name });

const cmdb = new Cmdb(items);
const io = new StubIO(items, rels);
let cursor: Cursor | null = null;
const mails: { subject: string; key: string; resolve: boolean }[] = [];
const run = (min: number, idStopped: boolean, ncStopped: boolean): void => {
  io.checks = () => [
    gate("lan-uplink", [{ status: "warn", text: "fencing is armed and lan has one port", subject: node("tappaas3") }], [node("tappaas1"), node("tappaas3")]),
    gate("service-liveness", [
      ...(idStopped ? [{ status: "fail" as const, text: "not running", subject: mod("identity") }] : []),
      ...(ncStopped ? [{ status: "fail" as const, text: "not running", subject: mod("nextcloud") }] : []),
    ], [mod("identity"), mod("nextcloud")]),
  ];
  io.sweepRecord = { time: at(min).toISOString(), counts: { expected: 0, drift: 0, desired: 0, unmanaged: 0, missing: 0, unread: 0, sourcesFailed: 0 } };
  assess(io, {}, at(min));
  cmdb.record(at(min));
  const r = emit(cmdb, cursor, { now: at(min), intervalMin: 5, windows: [] });
  const d = deliverNotices(r.notices, r.cursor.notices ?? {}, (m, key, resolve) => (mails.push({ subject: m.subject, key, resolve }), true), r.cursor.time);
  cursor = { ...r.cursor, notices: d.open };
};

run(0, false, false);
check(mails.length === 0, "a standing warning on a machine mails nothing at once");
run(11, true, false);
const opened = mails.filter((m) => !m.resolve);
check(opened.length === 1 && opened[0].subject.startsWith("ALERT: critical root cause identity"), `identity stopping is its own critical root and is mailed (${opened.map((m) => m.subject).join("; ")})`);
check(/impacts .*app/.test(opened[0]?.subject ?? ""), "…naming what it impacts: the console app, not its machine");
const roots = (items[0].attributes.rootCauses as { id: string }[]).map((r) => r.id);
check(roots.includes(idv.id) && !roots.includes(m1.id), "the machine is no symptom, and no root, of identity");
check(((items.find((o) => o.id === m1.id)!.attributes.conditions ?? []) as Condition[]).every((c) => c.type !== "impact"), "…and carries no impact: no cycle through it");
run(13, true, true);
check(mails.filter((m) => !m.resolve).length === 2 && mails.at(-1)!.subject.includes("nextcloud"), "a second, independent fault is mailed too");
run(16, false, true);
const closed = mails.filter((m) => m.resolve);
check(closed.length === 1 && closed[0].key === `health-root:${idv.id}:operational` && closed[0].subject.includes("(recovered)"), "identity back: one RESOLVED on its own key, recovered");
// nextcloud is retired while down: its notice closes, retired.
const i = items.findIndex((o) => o.id === nc.id);
items.splice(i, 1);
run(20, false, false);
const last = mails.filter((m) => m.resolve).at(-1)!;
check(last.key === `health-root:${nc.id}:operational` && last.subject.includes("(retired from the CMDB)"), "a root retired while critical closes its notice, retired");
check(Object.keys(cursor!.notices ?? {}).length === 0, "nothing is left open");
check(mails.filter((m) => !m.resolve).length === mails.filter((m) => m.resolve).length, "every ALERT has its RESOLVED");

console.log(`\nhealth-flow: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
