// classify-notify.test.ts — the two kinds that decide what a finding becomes
// and how a root is told, through assess, emit and the notices over several
// runs: a site record raises an alert and the alert's source clears it; an
// age-based raise keeps its clock; a quiet record keeps the condition, closes
// its notice as quiet and is heard again when the rule goes; a sum of others is
// never a root; a warning root told at once; a critical root told nowhere.

import { readFileSync } from "fs";
import { join } from "path";
import { CmdbItem } from "../../src/assess-model";
import { assess } from "../../src/assess";
import { Condition, HealthCmdb, HealthObject, Period, splitRef } from "../../src/emit-cmdb";
import { Cursor, deliverNotices, emit } from "../../src/emit";
import { CORE_NOTIFY, NotifyRules } from "../../src/notices";
import { HealthRecord } from "../../../../lib/ts/src/health-records";
import { StubIO, coreRecords, obj, rel, shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const CICD = process.env.HM_CICD_DIR ?? join(__dirname, "../../../../../../..");
const T0 = Date.parse("2026-11-12T08:00:00.000Z");
const at = (min: number): Date => new Date(T0 + min * 60_000);

check(JSON.stringify(CORE_NOTIFY) === JSON.stringify((JSON.parse(readFileSync(join(CICD, "controller/cmdb-controller/metamodel/health/notify.json"), "utf8")) as { records: unknown[] }).records), "the core notify records in the code are the released file's");

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

/** A small site run through assess, emit and the notices, with the records given. */
function site(extra: HealthRecord[]) {
  const s = obj("site", "rossen");
  const m1 = obj("machine", "tappaas1");
  const nc = obj("vm", "nextcloud", { module: "nextcloud" });
  const ups = obj("device", "ups-rack1");
  const items: CmdbItem[] = [s, m1, nc, ups].map((o) => ({ ...o, attributes: { ...o.attributes } }));
  const io = new StubIO(items, [rel("runs-on", nc, m1)], shippedModel(extra));
  const cmdb = new Cmdb(items);
  const notify: NotifyRules = { records: io.model.records, ancestors: io.model.ancestors };
  let cursor: Cursor | null = null;
  const mails: { subject: string; body: string; resolve: boolean }[] = [];
  const alert = (alertname: string, subject: string) => ({ state: "open" as const, alertname, host: "", module: "", kind: "state" as const, labels: {}, since: at(0).toISOString(), subject: { kind: "module" as const, name: subject } });
  const run = (min: number, alerts: ReturnType<typeof alert>[]) => {
    io.open = alerts;
    io.recent = [];
    io.sweepRecord = { time: at(min).toISOString(), counts: { expected: 0, drift: 0, desired: 0, unmanaged: 0, missing: 0, unread: 0, sourcesFailed: 0 } };
    const r0 = assess(io, {}, at(min));
    cmdb.record(at(min));
    const r = emit(cmdb, cursor, { now: at(min), intervalMin: 5, windows: [], notify });
    const d = deliverNotices(r.notices, r.cursor.notices ?? {}, (m, _k, resolve) => (mails.push({ ...m, resolve }), true), r.cursor.time);
    cursor = { ...r.cursor, notices: d.open };
    return { assessed: r0, events: [...r.events, ...d.events] };
  };
  const cond = (o: CmdbItem, type: string): Condition | undefined => ((items.find((x) => x.id === o.id)!.attributes.conditions ?? []) as Condition[]).find((c) => c.type === type);
  return { io, run, cond, mails, alert, nc, ups, m1, s, items, notify };
}

// ── a site record raises a failed backup of nextcloud, and its source clears it ──
{
  const raise: HealthRecord = { id: "site.classify.backup-failed-nextcloud", kind: "classify", description: "Nextcloud holds the family's photos.",
    when: { finding: { source: "alerts", labels: { alertname: "BackupJobFailed" } }, object: { name: "nextcloud" } }, set: { status: "critical" } };
  const t = site([raise]);
  t.run(0, [t.alert("BackupJobFailed", "nextcloud")]);
  const c = t.cond(t.nc, "operational");
  check(c?.status === "critical" && c.raw?.status === "warning" && c.raw.rule === raise.id && c.raw.since === at(0).toISOString(), "a local override raises the alert to critical, keeping what its source said beside it");
  check(t.mails.some((m) => !m.resolve && m.subject.includes("critical root cause nextcloud")), "…a critical root: told at once");
  t.run(5, []);
  check(t.cond(t.nc, "operational")?.status === "ok" && t.mails.some((m) => m.resolve && m.subject.includes("recovered")), "…and clears with its source: the alert gone, the condition ok, the notice closed as recovered");
  const plain = site([]);
  plain.run(0, [plain.alert("BackupJobFailed", "nextcloud")]);
  check(plain.cond(plain.nc, "operational")?.status === "warning" && !plain.cond(plain.nc, "operational")?.raw, "without it: the core record's warning, no raw");
}

// ── an age-based raise reads the source's own since ──
{
  const long = coreRecords().find((r) => r.id === "core.classify.long-warning")!;
  const t = site([{ ...long, id: "site.classify.long-warning", enabled: true } as HealthRecord]);
  t.run(0, [t.alert("DiskSlow", "nextcloud")]);
  check(t.cond(t.nc, "operational")?.status === "warning", "a warning younger than a day stays a warning");
  t.run(25 * 60, [t.alert("DiskSlow", "nextcloud")]);
  const c = t.cond(t.nc, "operational");
  check(c?.status === "critical" && c.raw?.status === "warning" && c.raw.since === at(0).toISOString(), "after a day: critical, the source's since kept");
  t.run(25 * 60 + 5, [t.alert("DiskSlow", "nextcloud")]);
  check(t.cond(t.nc, "operational")?.status === "critical", "…and it does not flip back on the next run: the raise does not reset its own clock");
}

// ── quiet: kept, silenced, closes its notice as quiet, heard again when the rule goes ──
{
  const quiet: HealthRecord = { id: "site.classify.quiet-ups-selftest", kind: "classify", description: "The UPS self-test every Monday is not news.",
    when: { finding: { source: "alerts", labels: { alertname: "UpsOnBattery" } }, object: { name: "ups-rack1" } }, quiet: true };
  const raiseUps: HealthRecord = { id: "site.classify.ups-critical", kind: "classify", when: { finding: { source: "alerts", labels: { alertname: "UpsOnBattery" } } }, set: { status: "critical" } };
  const t = site([raiseUps]);
  t.run(0, [t.alert("UpsOnBattery", "ups-rack1")]);
  check(t.mails.some((m) => !m.resolve && m.subject.includes("ups-rack1")), "an alert raised to a critical root: a notice opens");
  t.io.model = shippedModel([raiseUps, { ...quiet, overrides: [raiseUps.id] } as HealthRecord]);
  const r = t.run(5, [t.alert("UpsOnBattery", "ups-rack1")]);
  const c = t.cond(t.ups, "operational");
  check(c?.status === "warning" && c.quieted?.rule === quiet.id, "a quiet record: the condition is kept as its source gave it, quieted by the rule");
  check(t.mails.some((m) => m.resolve && m.subject.includes("quieted by a health rule")), "…its notice closes as quiet");
  check(r.assessed.rootCauses.some((x) => x.id === t.ups.id), "…it is still a root underneath, for roots --all and rules explain");
  t.io.model = shippedModel([raiseUps]);
  t.run(10, [t.alert("UpsOnBattery", "ups-rack1")]);
  const back = t.cond(t.ups, "operational");
  check(!back?.quieted && back?.status === "critical" && t.mails.filter((m) => !m.resolve && m.subject.includes("ups-rack1")).length === 2, "the rule gone: heard again, a new notice");
}

// ── an impact whose only root is quiet is quiet with it ──
{
  const q: HealthRecord = { id: "site.classify.quiet-node", kind: "classify", when: { finding: { reason: "guest-stopped" }, object: { name: "tappaas1" } }, quiet: true };
  const t = site([q]);
  t.io.checks = () => [{ name: "service-liveness", status: "fail", detail: "x", rows: [{ status: "fail", text: "down", subject: { kind: "node", name: "tappaas1" } }], judged: [{ kind: "node", name: "tappaas1" }] }];
  const r = t.run(0, []);
  const node = t.cond(t.m1, "operational");
  const imp = t.cond(t.nc, "impact");
  check(node?.status === "critical" && node.quieted?.rule === q.id && r.assessed.rootCauses.some((x) => x.id === t.m1.id), "a quieted root: critical as its source said, quiet, still a root underneath");
  check(imp?.status === "critical" && imp.quieted?.via?.[0] === t.m1.id && imp.quieted.rule === q.id, "…what it impacts is still marked, quietly, with it");
  check(!t.mails.some((m) => m.subject.includes("tappaas1")), "…and nothing is told");
}

// ── notify: a warning root told at once, a critical root told nowhere ──
{
  const warnAtOnce: HealthRecord = { id: "site.notify.nextcloud-warnings", kind: "notify", when: { object: { name: "nextcloud" }, condition: { status: "warning" } }, notify: "at-once" };
  const t = site([warnAtOnce]);
  t.run(0, [t.alert("Anything", "nextcloud")]);
  check(t.mails.some((m) => !m.resolve && m.subject.startsWith("ALERT: root cause nextcloud")), "a warning root a record tells at once: a notice, its subject says root cause, not critical");
  t.run(5, []);
  check(t.mails.some((m) => m.resolve && m.subject.startsWith("RESOLVED: root cause nextcloud")), "…closed when it recovers");
  const hush: HealthRecord = { id: "site.notify.ups-none", kind: "notify", when: { object: { name: "ups-rack1" } }, notify: "none", overrides: ["core.notify.critical-root", "core.notify.root"] };
  const raiseUps: HealthRecord = { id: "site.classify.ups-critical", kind: "classify", when: { finding: { source: "alerts", labels: { alertname: "UpsOnBattery" } } }, set: { status: "critical" } };
  const u = site([raiseUps, hush]);
  u.run(0, [u.alert("UpsOnBattery", "ups-rack1")]);
  check(u.cond(u.ups, "operational")?.status === "critical" && !u.mails.some((m) => m.subject.includes("ups-rack1")), "a critical root a record tells nowhere: no notice, the condition stays visible");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
