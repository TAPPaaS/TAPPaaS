// assess.test.ts — ADR-041 D2 with a fake cluster client and a stubbed CMDB:
// each gate's condition on its object; alerts, the sweep's drift, thresholds and
// the CVE scan; what changes since and what only lastChecked; a failure held
// until its source looks again; the report's shape; validate over the result.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { AssessResult, assess } from "../../src/assess";
import { CmdbItem, Condition, SiteIndex, conditionsOf } from "../../src/assess-model";
import { assessmentOf, readValidate } from "../../src/assess-validate";
import { GATES } from "../../src/assess-sources";
import { checkDiskThreshold, checkPendingReboot, checkPulse, checkQuorum, checkServiceLiveness, checkSiteTimezone, runHealthGates } from "../../src/checks";
import { ScanStatus } from "../../src/security";
import { CheckResult } from "../../src/types";
import { NOW, StubIO, T0, cond, obj, rel } from "./assess-fixture";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const later = (min: number): Date => new Date(NOW.getTime() + min * 60_000);
const got = (r: AssessResult, o: CmdbItem, type: string): Condition | undefined => r.objects.find((x) => x.id === o.id)?.conditions.find((c) => c.type === type);
const gate = (name: string, status: CheckResult["status"], rows: CheckResult["rows"] = [], extra: Partial<CheckResult> = {}): CheckResult => ({ name, status, detail: `${name} ${status}`, rows, ...extra });

const site = obj("site", "home");
const cluster = obj("cluster", "c1");
const m1 = obj("machine", "tappaas1");
const nc = obj("vm", "nextcloud");
const net = obj("vm", "network");
const ct = obj("lxc", "dns");
const sw = obj("device", "sw1");
const swa = obj("network-device", "sw-01");
const port = obj("port", "7");
const pool = obj("storage-pool", "tanka1", { used: 85, size: 100, zfsState: "DEGRADED" });
const ds = obj("datastore", "main", { used: 95, size: 100 });
const peer = obj("backup-peer", "aunt");
const fresh = (): { items: CmdbItem[]; rels: ReturnType<typeof rel>[] } => {
  const items = [site, cluster, m1, nc, net, ct, sw, swa, port, pool, ds, peer].map((o) => ({ ...o, attributes: { ...o.attributes } }));
  const rels = [rel("runs-on", nc, m1), rel("runs-on", net, m1), rel("runs-on", ct, m1), rel("runs-on", pool, m1), rel("allocated-to", swa, sw), rel("part-of", port, swa), rel("member-of", m1, cluster)];
  return { items, rels };
};

// ── each gate's condition lands on its object ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = (name: string) => ({ kind: "module" as const, name });
  io.checks = () => [
    gate("service-liveness", "fail", [], { findings: [{ status: "fail", text: "not running", subject: mod("nextcloud") }, { status: "skip", text: "suspended", subject: mod("dns") }], judged: [mod("nextcloud"), mod("dns")] }),
    gate("disk-threshold", "fail", [], { findings: [{ status: "fail", text: "/ at 91%, over 80%", subject: mod("nextcloud") }], judged: [mod("nextcloud")] }),
    gate("memory-commitment", "pass", [], { findings: [{ status: "pass", text: "12/64G", subject: { kind: "node", name: "tappaas1" } }] }),
    gate("guest-memory", "warn", [{ status: "warn", text: "dns  80%", subject: mod("dns") }, { status: "pass", text: "── VM totals" }]),
    gate("backup-status", "fail", [], { findings: [{ status: "fail", text: "opted in, not in the PBS job", subject: mod("nextcloud") }] }),
    gate("pending-reboot", "warn", [{ status: "warn", text: "nextcloud  booted a, next b", subject: mod("nextcloud") }]),
    gate("site-timezone", "warn", [{ status: "warn", text: "node tappaas1  UTC", subject: { kind: "node", name: "tappaas1" } }]),
    gate("quorum", "warn", [], { findings: [{ status: "warn", text: "two votes, no QDevice", subject: { kind: "site", name: "quorum" } }] }),
    gate("lan-uplink", "warn", [{ status: "warn", text: "tappaas1  one leg down", subject: { kind: "node", name: "tappaas1" } }]),
    gate("switch-ports", "warn", [{ status: "warn", text: "sw1 port 7: no record", subject: { kind: "port", name: "sw1:7" } }, { status: "warn", text: "sw1: never read", subject: { kind: "switch", name: "sw1" } }]),
    gate("pulse", "warn", [], { findings: [{ status: "warn", text: "aunt DOWN", subject: { kind: "peer", name: "aunt" } }] }),
    gate("ipv6-egress", "warn", [{ status: "warn", text: "no IPv6 router", subject: mod("network") }]),
    gate("storage-pools", "warn", [{ status: "warn", text: "tappaas1/tanka1: 85% used", subject: { kind: "pool", name: "tappaas1/tanka1" } }]),
    gate("backup-keys", "warn", [], { findings: [{ status: "warn", text: "the keys changed", subject: mod("ghost") }] }),
    gate("open-alerts", "warn", [{ status: "warn", text: "open Foo", subject: mod("nextcloud") }]),
    gate("cve-status", "warn", [{ status: "warn", text: "x", subject: mod("nextcloud") }]),
  ];
  const r = assess(io, {}, NOW);
  check(got(r, nc, "operational")?.status === "critical" && got(r, nc, "operational")?.reason === "guest-stopped" && got(r, nc, "operational")?.message === "not running", "service-liveness: operational on the vm");
  check(got(r, ct, "operational")?.status === "ok" && got(r, ct, "operational")?.reason === "ok", "…a suspended module is ok: stopped on purpose");
  check(got(r, nc, "capacity")?.reason === "disk-full" && got(r, nc, "capacity")?.status === "critical", "disk-threshold: capacity on the guest");
  check(got(r, m1, "capacity")?.status === "ok", "memory-commitment: capacity on the machine");
  check(got(r, ct, "capacity")?.reason === "guest-memory-short", "guest-memory: capacity on the guest");
  check(got(r, nc, "backup")?.status === "critical", "backup-status: backup on the guest");
  check(got(r, nc, "maintenance")?.reason === "reboot-pending" && got(r, m1, "maintenance")?.reason === "timezone-off", "pending-reboot, site-timezone: maintenance");
  check(got(r, cluster, "operational")?.reason === "quorum-at-risk", "quorum: operational on the cluster");
  check(got(r, m1, "operational")?.reason === "lan-uplink", "lan-uplink: operational on the machine");
  check(got(r, port, "operational")?.reason === "switch-port" && got(r, sw, "operational")?.reason === "switch-port", "switch-ports: on the port, and the device");
  check(got(r, peer, "operational")?.reason === "pulse", "pulse: operational on the backup-peer");
  check(got(r, net, "operational")?.reason === "ipv6-egress", "ipv6-egress: operational on the network vm");
  check(got(r, pool, "capacity")?.reason === "pool-usage", "storage-pools: capacity on the pool, found on its node");
  check(got(r, site, "maintenance")?.message === "the keys changed", "what the CMDB does not have lands on the site");
  check(io.written.length === 1 && io.written[0].source === "health-manager" && io.written[0].assessment === true, "one report, an assessment, from health-manager");
  check((io.written[0].objects ?? []).every((o) => typeof o.id === "string"), "…naming its objects by id");
  check(Object.keys(GATES).length === 19, "every gate that is no source of its own is mapped");
  const cs = got(r, nc, "operational")!;
  check(Object.keys(cs).sort().join() === "acknowledged,derived,lastChecked,maintenance,message,reason,rootCause,since,source,status,type", "a condition has D1's fields");
  const a = (io.written[0].objects ?? []).find((o) => o.id === site.id)?.attributes as { rootCauses: unknown[]; assessment: { time: string; gates: unknown[] } };
  check(Array.isArray(a.rootCauses) && a.assessment.gates.length === 16 && a.assessment.time === NOW.toISOString(), "the site carries the root causes and the run");
}

// ── from the real gates, with the fake client ──
{
  const dir = mkdtempSync(join(tmpdir(), "hm-assess-"));
  try {
    writeFileSync(join(dir, "nextcloud.json"), JSON.stringify({ vmid: 200, vmname: "nextcloud", node: "tappaas1" }));
    writeFileSync(join(dir, "network.json"), JSON.stringify({ vmid: 100, vmname: "network", node: "tappaas1" }));
    const c = new FakeClusterClient();
    c.guests = [{ vmid: 100, name: "network", node: "tappaas1", status: "running", type: "qemu" }];
    c.diskUsage.set("nextcloud.mgmt.internal", 95);
    c.quorumState = { expectedVotes: 2, qdevice: false };
    const s = fresh();
    const io = new StubIO(s.items, s.rels);
    io.checks = () => [
      checkServiceLiveness(c, dir, "tappaas1"), checkDiskThreshold(c, dir, "tappaas1", 80), checkPendingReboot(c, dir, "tappaas1"),
      checkSiteTimezone(c, dir, "tappaas1"), checkQuorum(c), checkPulse(c, dir),
    ];
    const r = assess(io, {}, NOW);
    check(got(r, nc, "operational")?.status === "critical", "a real gate: nextcloud not running");
    check(got(r, net, "operational")?.status === "ok", "…network running is ok, not absent");
    check(got(r, nc, "capacity")?.reason === "disk-full" && got(r, net, "capacity") === undefined, "…disk: over on the one probed, nothing on the unreachable");
    check(got(r, cluster, "operational")?.status === "warning", "…quorum on the cluster");
    check(typeof runHealthGates === "function", "the gates stay as they were");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── alerts ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const alert = (alertname: string, labels: Record<string, string>, subject: { kind: "module"; name: string } | null, state: "open" | "recent" = "open") =>
    ({ state, alertname, host: "", module: "", kind: state === "open" ? "state" : "event", labels, since: T0, subject });
  io.open = [alert("ReplicationFailed", { tappaas_ci_id: m1.id }, { kind: "module", name: "nextcloud" }), alert("FirewallCertChanged", {}, { kind: "module", name: "network" })];
  io.recent = [alert("HaFencing", {}, null, "recent")];
  const r = assess(io, {}, NOW);
  check(got(r, m1, "operational")?.reason === "alert-replication-failed", "the alert's CI id wins over its host");
  check(got(r, net, "security")?.reason === "alert-firewall-cert-changed", "a rule that says exposed is security");
  check(got(r, site, "operational")?.status === "warning", "an event of the last day, placed nowhere: on the site");
  io.open = [];
  io.recent = [];
  const r2 = assess(io, {}, later(5));
  check(got(r2, m1, "operational")?.status === "ok", "an alert that cleared is over");
  io.open = [alert("Again", {}, { kind: "module", name: "nextcloud" })];
  assess(io, {}, later(10));
  io.open = null;
  const r3 = assess(io, {}, later(15));
  check(got(r3, nc, "operational")?.reason === "alert-again", "Grafana not answering takes nothing back");
}

// ── the sweep's drift ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  io.sweepRecord = {
    time: NOW.toISOString(), counts: { expected: 1, drift: 1, desired: 0, unmanaged: 1, missing: 1, unread: 0, sourcesFailed: 1 },
    sources: [{ source: "switch-manager", ok: false }],
    differences: [
      { kind: "drift", class: "vm", name: "nextcloud", attribute: "memory", expected: false },
      { kind: "unmanaged", class: "lxc", name: "dns", attribute: null, expected: false },
      { kind: "missing", class: "vm", name: "network", attribute: null, expected: false },
      { kind: "missing", class: "vm", name: "gone", attribute: null, expected: false },
      { kind: "drift", class: "machine", name: "tappaas1", attribute: "x", expected: true },
    ],
  };
  const r = assess(io, {}, NOW);
  check(got(r, nc, "drift")?.status === "warning" && got(r, nc, "drift")?.reason === "sweep-drift" && /memory/.test(got(r, nc, "drift")!.message), "the sweep's drift is drift on the object");
  check(got(r, ct, "drift")?.reason === "sweep-unmanaged", "…unmanaged too");
  check(got(r, net, "drift")?.status === "critical", "…missing is critical");
  check(got(r, m1, "drift") === undefined, "…an expected change is nothing");
  check(got(r, site, "drift")?.status === "critical" && /gone|switch-manager/.test(got(r, site, "drift")!.message), "a source that failed, or what has no object: on the site");
  io.sweepRecord = null;
  check(got(assess(io, {}, later(5)), site, "drift")?.reason === "sweep-none", "no sweep at all is critical on the site");
}

// ── thresholds over what the CMDB holds ──
{
  const s = fresh();
  const wg = obj("vpn-peer", "lars", { lastHandshake: "2026-10-01T00:00:00Z" });
  const wg2 = obj("vpn-peer", "new", { lastHandshake: "120" });
  const pa = obj("port", "a", { link: "down" });
  const pb = obj("port", "b", { link: "up" });
  const pc = obj("port", "c", { link: "down" });
  s.items.push(wg, wg2, pa, pb, pc);
  const fw = s.items.find((o) => o.id === net.id)!;
  const inDays = (d: number): string => new Date(NOW.getTime() + d * 86_400_000).toISOString();
  fw.attributes.firewall = { certificates: [{ name: "old", commonName: "*.x", validTo: inDays(-100) }, { name: "new", commonName: "*.x", validTo: inDays(20) }] };
  s.rels.push(rel("connects", pa, pb));
  const io = new StubIO(s.items, s.rels);
  const r = assess(io, {}, NOW);
  check(got(r, pool, "capacity")?.status === "warning" && got(r, pool, "capacity")?.message.includes("85%") === true, "a threshold over a pool's used");
  check(got(r, pool, "operational")?.reason === "pool-state" && got(r, pool, "operational")?.status === "warning", "ZFS's word for a pool");
  check(got(r, ds, "capacity")?.status === "critical" && got(r, ds, "capacity")?.reason === "datastore-usage", "…and a datastore's");
  check(got(r, pa, "operational")?.reason === "link-down" && got(r, pb, "operational")?.status === "ok", "a cabled port's link");
  check(got(r, pc, "operational")?.status === "ok", "…a port with no cable that is down is no failure");
  check(got(r, wg, "operational")?.reason === "vpn-handshake-stale" && got(r, wg2, "operational")?.status === "ok", "a peer's last handshake");
  check(got(r, net, "security")?.reason === "certificate-expiry" && got(r, net, "security")?.status === "warning", "a certificate: the newest of its name");
  check(got(r, nc, "impact") === undefined, "…no plane was asked: the sources are the CMDB's");
}

// ── the CVE scan ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const target = (id: string, verdict: string): unknown => ({ id, name: id, verdict, fixable: 3, critHighFixable: 1, note: "n", layer: "os" });
  io.scan = { generated: NOW.toISOString(), targets: [target("nextcloud", "act"), target("node:tappaas1", "watch"), target("image:network/x", "failed")] } as unknown as ScanStatus;
  const r = assess(io, {}, NOW);
  check(got(r, nc, "security")?.status === "warning" && got(r, nc, "security")?.reason === "cve-act", "act: security on the module, a warning");
  check(got(r, m1, "security")?.status === "ok", "…watch is ok on the node");
  check(got(r, net, "security")?.reason === "cve-scan-failed", "…an image is its module's");
}

// ── since and lastChecked; held until the source looks ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  const down = (text: string): CheckResult => gate("service-liveness", "fail", [], { findings: [{ status: "fail", text, subject: mod }], judged: [mod] });
  io.checks = () => [down("not running")];
  const r1 = assess(io, {}, NOW);
  const c1 = got(r1, nc, "operational")!;
  check(c1.since === NOW.toISOString() && c1.lastChecked === NOW.toISOString(), "a new condition: since now");
  io.checks = () => [down("not running, 2 hours")];
  const r2 = assess(io, {}, later(5));
  const c2 = got(r2, nc, "operational")!;
  check(c2.since === c1.since && c2.lastChecked === later(5).toISOString() && c2.message === "not running", "unchanged status and reason: only lastChecked moves");
  check(!r2.transitions.some((t) => t.id === nc.id), "…no transition");
  io.checks = () => [gate("service-liveness", "skip")];
  const r3 = assess(io, {}, later(10));
  const c3 = got(r3, nc, "operational")!;
  check(c3.status === "critical" && c3.lastChecked === later(5).toISOString(), "a gate that skipped takes nothing back, and confirms nothing");
  io.checks = () => [gate("service-liveness", "pass", [], { judged: [] })];
  check(got(assess(io, {}, later(15)), nc, "operational")?.status === "critical", "a gate that did not reach it takes nothing back");
  io.checks = () => [gate("service-liveness", "pass", [], { judged: [mod] })];
  const r5 = assess(io, {}, later(20));
  const c5 = got(r5, nc, "operational")!;
  check(c5.status === "ok" && c5.since === later(20).toISOString(), "recovered: ok, with a new since");
  check(r5.transitions.some((t) => t.id === nc.id && t.from === "critical" && t.to === "ok"), "…a transition");
  const before = io.written.length;
  assess(io, { dryRun: true }, later(25));
  check(io.written.length === before, "--dry-run writes nothing");
}

// ── a finding the CMDB cannot place lands on the site, and the gate takes it back ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  const ghost = { kind: "module" as const, name: "ghost" };
  io.checks = () => [gate("service-liveness", "fail", [], { findings: [{ status: "fail", text: "not running", subject: ghost }], judged: [mod] })];
  const r1 = assess(io, {}, NOW);
  check(got(r1, site, "operational")?.status === "critical" && got(r1, site, "operational")?.reason === "guest-stopped", "a failure about something the CMDB does not have is the site's");
  io.checks = () => [gate("service-liveness", "pass", [], { judged: [mod] })];
  const r2 = assess(io, {}, later(5));
  const c2 = got(r2, site, "operational")!;
  check(c2.reason === "roll-up" && c2.status === "warning", "the gate ran again without it: the site's own failure is over, though the site is in no judged list; its members' roll-up remains");
  check(r2.transitions.some((t) => t.id === site.id && t.from === "critical" && t.to === "warning"), "…a transition");
  io.checks = () => [gate("service-liveness", "skip")];
  check(got(assess(io, {}, later(10)), site, "operational")?.reason === "roll-up", "…and it stays over when the gate later skips");
}

// ── what the operator set ──
{
  const s = fresh();
  const vm = s.items.find((o) => o.id === nc.id)!;
  vm.attributes.conditions = [cond("capacity", "critical", "disk-full", { acknowledged: { by: "lars", note: "n", until: null, sticky: false }, maintenance: { until: "2026-10-30T08:30:00.000Z", note: "m" } })];
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  io.checks = () => [gate("disk-threshold", "fail", [], { findings: [{ status: "fail", text: "t", subject: mod }], judged: [mod] })];
  const r = assess(io, {}, NOW);
  check(got(r, nc, "capacity")?.acknowledged?.by === "lars", "an acknowledgement survives a run");
  vm.attributes.conditions = [cond("capacity", "critical", "disk-full", { flapping: true, flappingHeld: "critical", acknowledged: { by: "lars", note: "n", until: null, sticky: false, at: T0, via: ["machine/x"] } })];
  const kept = got(assess(io, {}, NOW), nc, "capacity")!;
  check(kept.flapping === true && kept.flappingHeld === "critical" && kept.acknowledged?.at === T0 && kept.acknowledged?.via?.[0] === "machine/x", "emit's members survive a run");
  io.checks = () => [gate("disk-threshold", "pass", [], { judged: [mod] })];
  check(got(assess(io, {}, later(1)), nc, "capacity")?.flapping === true, "…also across a change of status");
  io.checks = () => [gate("disk-threshold", "fail", [], { findings: [{ status: "fail", text: "t", subject: mod }], judged: [mod] })];
  vm.attributes.conditions = [cond("capacity", "critical", "disk-full", { acknowledged: { by: "lars", note: "n", until: null, sticky: false } })];
  check(got(r, nc, "capacity")?.maintenance === null, "…a window past its until does not");
  io.checks = () => [gate("disk-threshold", "warn", [], { findings: [{ status: "warn", text: "t", subject: mod }], judged: [mod] })];
  check(got(assess(io, {}, later(5)), nc, "capacity")?.acknowledged === null, "a plain acknowledgement ends with the status");
}

// ── --only ──
{
  const s = fresh();
  s.items.find((o) => o.id === ct.id)!.attributes.conditions = [cond("operational", "warning", "alert-old")];
  const io = new StubIO(s.items, s.rels);
  io.open = [{ state: "open", alertname: "Foo", host: "", module: "", kind: "state", labels: {}, since: T0, subject: { kind: "module", name: "nextcloud" } }];
  let asked = 0;
  io.checks = () => { asked++; return []; };
  const r = assess(io, { only: "nextcloud" }, NOW);
  check(asked === 0, "--only runs no gate");
  check(got(r, nc, "operational")?.status === "warning", "…the object's alert lands");
  check(got(r, ct, "operational")?.status === "warning", "…another object's condition stands");
  check(!(io.written[0].objects ?? []).some((o) => o.id === ct.id), "…and is not rewritten");
  let refused = "";
  try { assess(io, { only: "nope" }, NOW); } catch (e) { refused = (e as Error).message; }
  check(refused.includes("no object nope"), "--only an object the CMDB does not have is refused");
}

// ── placeholders are left alone ──
{
  const ph = obj("machine", "later", { placeholder: true });
  const io = new StubIO([obj("site", "home"), ph], []);
  const r = assess(io, {}, NOW);
  check(!r.objects.some((o) => o.id === ph.id), "a placeholder gets no conditions");
}

// ── validate as a read ──
{
  const make = (extra: Condition[], rows?: CheckResult["findings"]) => {
    const m = obj("machine", "tappaas1", { conditions: [cond("operational", "critical", "node-down")] });
    const v = obj("vm", "nextcloud", { conditions: extra });
    const st = obj("site", "home", { assessment: { time: NOW.toISOString(), gates: [{ name: "service-liveness", status: "fail", detail: "not running: nextcloud", findings: rows ?? [{ status: "fail", text: "not running", subject: { kind: "module", name: "nextcloud" } }] }] } });
    return { idx: new SiteIndex([st, v], []), withNode: new SiteIndex([st, v, m], []), a: assessmentOf([st])! };
  };
  const nowMs = NOW.getTime();
  const crit = make([cond("operational", "critical", "guest-stopped")]);
  const r = readValidate(crit.idx, crit.a, nowMs);
  check(r.failed > 0 && r.checks[0].status === "fail", "critical, on its own: exit 1");
  const der = make([cond("operational", "critical", "guest-stopped", { derived: true, rootCause: "machine/tappaas1" })]);
  const r2 = readValidate(der.withNode, der.a, nowMs);
  check(r2.failed > 0, "derived, with its root's critical standing: the root fails it");
  check(r2.checks[0].findings?.[0].text.includes("follows from tappaas1") === true && r2.checks[0].findings?.[0].status === "warn", "…the guest's row says what it follows from");
  const r3 = readValidate(der.idx, der.a, nowMs);
  check(r3.failed === 0 && r3.checks.every((c) => c.status !== "fail"), "derived alone: exit 0");
  const ack = make([cond("operational", "critical", "guest-stopped", { acknowledged: { by: "lars", note: "", until: null, sticky: false } })]);
  const r4 = readValidate(ack.idx, ack.a, nowMs);
  check(r4.failed === 0 && r4.checks[0].findings?.[0].text.includes("acknowledged by lars") === true, "acknowledged: exit 0, and it says so");
  const past = make([cond("operational", "critical", "guest-stopped", { acknowledged: { by: "lars", note: "", until: "2026-10-30T08:00:00.000Z", sticky: true } })]);
  check(readValidate(past.idx, past.a, nowMs).failed > 0, "an expired acknowledgement: exit 1");
  const mnt = make([cond("operational", "critical", "guest-stopped", { maintenance: { until: null, note: "update" } })]);
  const r5 = readValidate(mnt.idx, mnt.a, nowMs);
  check(r5.failed === 0 && r5.checks[0].findings?.[0].text.includes("in maintenance") === true, "in maintenance: exit 0");
  const warn = make([cond("operational", "warning", "x")], []);
  check(readValidate(warn.idx, warn.a, nowMs).failed === 0, "a warning never fails it");
  const thr = make([cond("capacity", "critical", "datastore-usage", { message: "main: 95% used" })], []);
  const r6 = readValidate(thr.idx, thr.a, nowMs);
  const line = r6.checks.find((c) => c.name === "conditions");
  check(r6.failed > 0 && line?.status === "fail" && line.rows?.[0].text.includes("95%") === true, "a critical no gate printed gets a line of its own");
  check(conditionsOf(obj("vm", "x")).length === 0 && assessmentOf([obj("site", "s")]) === null, "no assessment yet: nothing to read");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
