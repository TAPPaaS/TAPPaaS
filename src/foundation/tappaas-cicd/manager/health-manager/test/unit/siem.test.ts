// siem.test.ts — security hits hold their condition (ADR-050 D12): a warning
// for 24 h from its last hit, a critical until acknowledged after its last hit;
// one finding per rule and CI with its count; info never a condition; a record
// may re-rate a hit and set its hold; a security critical from a hit is not
// put in maintenance by an open window; a security alert is not also an
// operational alert.

import { assess } from "../../src/assess";
import { Condition } from "../../src/assess-model";
import { fromAlerts } from "../../src/assess-sources";
import { SiteIndex } from "../../src/assess-model";
import { SiemItem, held, readSiem } from "../../src/siem";
import { HealthRecord, checkRecord } from "../../../../lib/ts/src/health-records";
import { StubIO, obj, rel, shippedModel } from "./assess-fixture";
import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const H = 3600_000;
const T = Date.parse("2026-11-12T08:00:00.000Z");
const iso = (ms: number): string => new Date(ms).toISOString();

const site = obj("site", "rossen");
const node = obj("machine", "tappaas1");
const nc = obj("vm", "nextcloud", { module: "nextcloud" });
const rels = [rel("runs-on", nc, node)];

function hit(alertname: string, level: SiemItem["level"], last: number, extra: Partial<SiemItem> = {}): SiemItem {
  return { alertname, host: "nextcloud", module: "nextcloud", level, labels: { src_ip: "203.0.113.9" }, first: iso(last - H), last: iso(last), count: 7, subject: { kind: "module", name: "nextcloud" }, ...extra };
}

function run(io: StubIO & { hits?: SiemItem[] }, at: number): Condition | undefined {
  io.siem = () => io.hits ?? [];
  assess(io, {}, new Date(at));
  const cs = (io.items.find((o) => o.id === nc.id)!.attributes.conditions ?? []) as Condition[];
  return cs.find((c) => c.type === "security");
}

function fresh(extra: HealthRecord[] = []): StubIO & { hits?: SiemItem[] } {
  const items = [obj("site", "rossen"), obj("machine", "tappaas1"), obj("vm", "nextcloud", { module: "nextcloud" })];
  return new StubIO(items, rels, shippedModel(extra)) as StubIO & { hits?: SiemItem[] };
}

console.log("== hold ==");
check(held("24h", T, T + 23 * H, null), "a 24h hold holds inside the day");
check(!held("24h", T, T + 25 * H, null), "and ends after it");
check(held("until-ack", T, T + 30 * 24 * H, null), "until-ack holds without an ack");
check(!held("until-ack", T, T + H, T + H / 2), "an ack after the last hit ends it");
check(held("until-ack", T, T + H, T - H), "an ack before the last hit does not");

console.log("== warning: 24 h from the last hit ==");
{
  const io = fresh();
  io.hits = [hit("SshBruteForce", "warning", T)];
  let c = run(io, T + H);
  check(c?.status === "warning" && c.owner === "siem" && c.reason === "siem-ssh-brute-force", "a warning hit is a security warning on its CI, owned by siem");
  check(!!c?.message.includes("7 hits"), "one finding with the count");
  c = run(io, T + 23 * H);
  check(c?.status === "warning", "still held after 23 h");
  io.hits = [hit("SshBruteForce", "warning", T + 22 * H)];
  c = run(io, T + 30 * H);
  check(c?.status === "warning", "a new hit moves the hold on");
  c = run(io, T + 47 * H);
  check(c?.status === "ok", "over 24 h after the last hit: ok");
}

console.log("== critical: until acknowledged ==");
{
  const io = fresh();
  io.hits = [hit("LoginAfterBruteForce", "critical", T)];
  let c = run(io, T + H);
  check(c?.status === "critical", "a critical hit is critical");
  c = run(io, T + 10 * 24 * H);
  check(c?.status === "critical", "still critical ten days later, unacknowledged");
  // The ack verb's word, as ack.ts writes it.
  const o = io.items.find((x) => x.id === nc.id)!;
  o.attributes.acknowledgements = { security: { ack: { by: "lars", note: "known pen test", until: null, sticky: false, at: iso(T + 10 * 24 * H + 60_000) }, at: iso(T + 10 * 24 * H + 60_000) } };
  c = run(io, T + 10 * 24 * H + 120_000);
  check(c?.status === "ok", "an ack after the last hit closes it");
  io.hits = [hit("LoginAfterBruteForce", "critical", T + 11 * 24 * H)];
  c = run(io, T + 11 * 24 * H + 60_000);
  check(c?.status === "critical" && !c.acknowledged, "a new hit after the ack opens it again, unacknowledged");
}

console.log("== info, records, alerts ==");
{
  const io = fresh();
  io.hits = [hit("SudoUsed", "info", T)];
  const c = run(io, T + H);
  check(!c || c.status === "ok", "an info hit is no condition");
}
{
  const site12: HealthRecord = { id: "site.classify.ssh-12h", kind: "classify", when: { finding: { source: "siem", reason: "siem-ssh-brute-force" } }, overrides: ["core.classify.siem-warning"], hold: "12h" } as HealthRecord;
  check(checkRecord(site12, null).filter((x) => x.level === "error").length === 0, "a record that only holds is valid");
  check(checkRecord({ id: "site.classify.bad", kind: "classify", when: { finding: { source: "siem" } }, hold: "soon" }, null).some((x) => x.level === "error"), "a hold that is no duration is refused");
  const io = fresh([site12]);
  io.hits = [hit("SshBruteForce", "warning", T)];
  check(run(io, T + 11 * H)?.status === "warning", "a site's 12h hold holds at 11 h");
  check(run(io, T + 13 * H)?.status === "ok", "and ends at 13 h");
}
{
  const raise: HealthRecord = { id: "site.classify.ssh-critical", kind: "classify", when: { finding: { source: "siem", reason: "siem-ssh-brute-force" }, object: { name: "nextcloud" } }, set: { status: "critical" } } as HealthRecord;
  const io = fresh([raise]);
  io.hits = [hit("SshBruteForce", "warning", T)];
  const c = run(io, T + 30 * H);
  check(c?.status === "critical", "a record raising a hit to critical holds it until ack, past 24 h");
}
{
  const io = fresh();
  io.hits = [hit("LoginAfterBruteForce", "critical", T)];
  io.windows = () => [{ name: "update", scope: ["nextcloud"], until: Math.floor((T + 5 * H) / 1000), reason: "update" }];
  const c = run(io, T + H);
  check(c?.status === "critical" && !c.maintenance, "a security critical from a hit is not in maintenance");
  const io2 = fresh();
  io2.hits = [hit("SshBruteForce", "warning", T)];
  io2.windows = io.windows;
  const w = run(io2, T + H);
  check(w?.status === "warning" && !!w.maintenance, "a warning hit is, as any warning");
}
{
  const idx = new SiteIndex([site, node, nc], rels);
  const fs = fromAlerts([{ state: "recent", alertname: "SshBruteForce", host: "nextcloud", module: "nextcloud", kind: "event", labels: { type: "security", level: "warning" }, since: iso(T), subject: { kind: "module", name: "nextcloud" } }], idx);
  check(fs.length === 0, "a security alert is not also an operational alert finding");
}
{
  const dir = mkdtempSync(join(tmpdir(), "siem-"));
  const f = join(dir, "s.json");
  writeFileSync(f, JSON.stringify({ version: 1, findings: { a: { alertname: "SshBruteForce", host: "nextcloud", module: "nextcloud", level: "bogus", labels: {}, first: iso(T), last: iso(T), count: 3 }, b: { host: "x" } } }));
  const items = readSiem(f, () => null)!;
  check(items.length === 1 && items[0].level === "warning", "the state file is read; an unknown level reads as warning, a broken entry is skipped");
  writeFileSync(f, "{not json");
  check(readSiem(f, () => null) === null, "an unreadable file is null: the source has not looked");
  check(readSiem(join(dir, "none.json"), () => null)?.length === 0, "a missing file is no hit");
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
