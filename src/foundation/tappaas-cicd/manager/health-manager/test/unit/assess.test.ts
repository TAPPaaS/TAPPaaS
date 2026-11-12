// assess.test.ts — ADR-041 D2 with a fake cluster client and a stubbed CMDB:
// each gate's condition on its object; alerts, the sweep's drift, thresholds and
// the CVE scan; what changes since and what only lastChecked; a failure held
// until its source looks again; the report's shape; validate over the result.

import { Window } from "../../src/windows";
import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { AssessResult, assess } from "../../src/assess";
import { CmdbItem, Condition, SiteIndex, conditionsOf } from "../../src/assess-model";
import { assessmentOf, readValidate } from "../../src/assess-validate";
import { GATES, fromGates } from "../../src/assess-sources";
import { checkDiskThreshold, checkPendingReboot, checkPulse, checkQuorum, checkServiceLiveness, checkSiteTimezone, runHealthGates } from "../../src/checks";
import { CveItem, ScanStatus } from "../../src/security";
import { siteSecurity } from "../../src/site-score";
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
  check(got(r, nc, "upkeep")?.reason === "reboot-pending" && got(r, m1, "upkeep")?.reason === "timezone-off", "pending-reboot, site-timezone: upkeep");
  check(got(r, cluster, "operational")?.reason === "quorum-at-risk", "quorum: operational on the cluster");
  check(got(r, m1, "operational")?.reason === "lan-uplink", "lan-uplink: operational on the machine");
  check(got(r, port, "operational")?.reason === "switch-port" && got(r, sw, "operational")?.reason === "switch-port", "switch-ports: on the port, and the device");
  check(got(r, peer, "operational")?.reason === "pulse", "pulse: operational on the backup-peer");
  check(got(r, net, "operational")?.reason === "ipv6-egress", "ipv6-egress: operational on the network vm");
  check(got(r, pool, "capacity")?.reason === "pool-usage", "storage-pools: capacity on the pool, found on its node");
  // On its own: the site's backup condition above is the roll-up of nextcloud's.
  const keys = fromGates([gate("backup-keys", "warn", [], { findings: [{ status: "warn", text: "the keys changed", subject: mod("ghost") }] })], new SiteIndex(io.objects(), io.relations())).findings;
  check(keys.some((f) => f.object === site.id && f.type === "backup" && f.message === "module ghost: the keys changed"), "what the CMDB does not have lands on the site, naming its subject");
  check(io.written.length === 1 && io.written[0].source === "health-manager" && io.written[0].assessment === true, "one report, an assessment, from health-manager");
  check((io.written[0].objects ?? []).every((o) => typeof o.id === "string"), "…naming its objects by id");
  check(Object.keys(GATES).length === 21, "every gate that is no source of its own is mapped");
  const cs = got(r, nc, "operational")!;
  check(Object.keys(cs).sort().join() === "acknowledged,derived,lastChecked,maintenance,message,owner,reason,rootCause,since,source,status,type", "a condition has D1's fields, and the owner that takes it back");
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
  check(got(r, net, "threat")?.reason === "alert-firewall-cert-changed", "a rule that says exposed is a threat");
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
  io.open = [];
  io.recent = [alert("HealthDailyDigest", {}, { kind: "module", name: "nextcloud" }, "recent")];
  const r4 = assess(io, {}, later(20));
  check(got(r4, nc, "operational")?.status === "ok", "health-manager's own rule is no condition: the digest cannot feed itself");
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
  // A changed attribute the store still marks as drift shows; once a change
  // put it right (the store cleared the drift), it does not wait for the night.
  const rec = io.sweepRecord!;
  io.sweepRecord = { ...rec, differences: [{ kind: "changed", class: "vm", name: "nextcloud", attribute: "cores", expected: false }] };
  s.items.find((o) => o.id === nc.id)!.attributes.drift = { since: T0, attributes: { cores: { was: 4, now: 6 } } };
  check(got(assess(io, {}, later(1)), nc, "drift")?.reason === "sweep-changed", "a drifted attribute the store still marks is drift");
  delete s.items.find((o) => o.id === nc.id)!.attributes.drift;
  check(got(assess(io, {}, later(2)), nc, "drift")?.status === "ok", "…and is over once a change cleared it, before the next sweep");
  // Names repeat (a pool per node): the sweep's id says which one drifted.
  const twin = { ...obj("storage-pool", "tanka1"), id: "pool-tanka1-on-tappaas2" };
  s.items.push({ ...twin, attributes: { drift: { since: T0, attributes: { size: { was: 1, now: 2 } } } } });
  io.sweepRecord = { ...rec, differences: [{ kind: "changed", class: "storage-pool", name: "tanka1", id: twin.id, attribute: "size", expected: false }] };
  const r2 = assess(io, {}, later(3));
  check(got(r2, twin, "drift")?.reason === "sweep-changed" && got(r2, pool, "drift")?.status !== "warning", "a drift on one of two same-named objects lands on the one the sweep names by id");
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
  check(got(r, net, "upkeep")?.reason === "certificate-expiry" && got(r, net, "upkeep")?.status === "warning", "a certificate: the newest of its name");
  check(got(r, nc, "impact") === undefined, "…no plane was asked: the sources are the CMDB's");
}

// ── the CVE scan: the vulnerability condition from the risk level (ADR-045 D4) ──
{
  const s = fresh();
  const zr = obj("zone", "rossen");
  const zm = obj("zone", "mgmt");
  const env = obj("environment", "rossen");
  s.items.push(zr, zm, env);
  s.rels.push(rel("serves", zr, env), rel("member-of", m1, env));
  const io = new StubIO(s.items, s.rels);
  const crit = (id: string): CveItem => ({ id, state: "open", severity: "Critical", pkg: "brotli", version: "1.1.0" });
  const high = (id: string): CveItem => ({ id, state: "open", severity: "High", pkg: "p", version: "1" });
  const target = (id: string, verdict: string, items: CveItem[], layer = "debian"): unknown =>
    ({ id, name: id, verdict, coverage: verdict === "failed" ? "fail" : "ok", fixable: 3, critHighFixable: 1, note: "n", layer, items, targets: [], new: [], critHighKeys: [] });
  const scan = (ts: unknown[]): ScanStatus => ({ generated: NOW.toISOString(), targets: ts } as unknown as ScanStatus);
  const place = { placement: { nextcloud: ["rossen"], "node:tappaas1": ["mgmt"], network: ["mgmt"] }, zones: { rossen: { tier: 1, environment: "rossen" }, mgmt: { tier: 0 } } };
  io.security = (sc) => siteSecurity(sc, place);
  io.scan = scan([target("nextcloud", "act", [crit("CVE-1")]), target("node:tappaas1", "watch", []), target("image:network/x", "failed", [])]);
  const r = assess(io, {}, NOW);
  check(got(r, nc, "vulnerability")?.status === "warning" && got(r, nc, "vulnerability")?.reason === "cve-high", "one open critical: high, a warning on the module");
  check(got(r, nc, "vulnerability")?.message === "score 20, high: 1 critical · 1 unread", "…the message gives the score, what counts and what nobody has read");
  check(got(r, m1, "vulnerability")?.status === "ok", "…nothing counted is ok on the node");
  check(got(r, net, "vulnerability")?.reason === "cve-scan-failed", "…a failed image is its module's warning");
  check(got(r, zr, "vulnerability")?.reason === "cve-high" && got(r, zr, "vulnerability")?.message.includes("×1") === true, "the zone has its own score, with its multiplier");
  check(got(r, env, "vulnerability")?.reason === "cve-high" && got(r, env, "vulnerability")?.derived === true && got(r, env, "vulnerability")?.owner === "cve", "…and the environment its own score, not a roll-up; derived from its modules, so never a root");
  check(!r.rootCauses.some((x) => x.id === env.id || x.id === zr.id), "…neither the zone nor the environment is a root cause");

  // The same critical in the management zone: ×2, critical there; the module stays high.
  io.scan = scan([target("nextcloud", "watch", []), target("node:tappaas1", "watch", [crit("CVE-2")], "debian")]);
  const r2 = assess(io, {}, later(5));
  check(got(r2, m1, "vulnerability")?.status === "warning" && got(r2, m1, "vulnerability")?.reason === "cve-high", "a node's own level: high");
  check(got(r2, zm, "vulnerability")?.status === "critical" && got(r2, zm, "vulnerability")?.reason === "cve-critical", "…the management zone ×2: critical");
  check(got(r2, nc, "vulnerability")?.status === "ok", "a module whose CVEs went is ok again");
  check(got(r2, env, "vulnerability")?.status === "ok" && got(r2, env, "vulnerability")?.owner === "cve", "the environment follows its own zones, not its node member's level");

  // A level change inside warning is a transition: medium → high.
  io.scan = scan([target("nextcloud", "watch", [high("CVE-3")])]);
  const r3 = assess(io, {}, later(10));
  check(got(r3, nc, "vulnerability")?.reason === "cve-medium", "one open high: medium");
  io.scan = scan([target("nextcloud", "watch", [crit("CVE-4")])]);
  const r4 = assess(io, {}, later(15));
  check(r4.transitions.some((t) => t.id === nc.id && t.type === "vulnerability" && t.from === "warning" && t.to === "warning" && t.reason === "cve-high"), "medium → high is a transition, the status still warning");
  check(got(r4, nc, "vulnerability")?.since === later(15).toISOString(), "…with a new since");

  // Low is ok: an analysed low risk.
  io.scan = scan([target("nextcloud", "watch", [{ id: "CVE-5", state: "risk", rating: "low", severity: "Critical", pkg: "x", version: "1" }])]);
  check(got(assess(io, {}, later(20)), nc, "vulnerability")?.status === "ok", "low is ok");
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

// ── a source still speaking a type from before the split ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  const was = { sig: GATES["signature-status"].type, sys: GATES["guest-system"].type };
  (GATES["signature-status"] as { type: string }).type = "security";
  (GATES["guest-system"] as { type: string }).type = "security";
  io.checks = () => [gate("signature-status", "warn", [], { findings: [{ status: "warn", text: "unsigned", subject: mod }] }), gate("guest-system", "fail", [], { findings: [{ status: "fail", text: "hand-made", subject: mod }] })];
  const r = assess(io, {}, NOW);
  GATES["signature-status"].type = was.sig;
  GATES["guest-system"].type = was.sys;
  check(got(r, nc, "vulnerability")?.reason === "repository-unverified" && got(r, nc, "threat")?.reason === "system-not-built" && !got(r, nc, "security" as never), "a source that still says security lands as vulnerability or threat, by its reason and source");
}

// ── a finding the CMDB cannot place lands on the site, and the gate takes it back ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  const ghost = { kind: "module" as const, name: "ghost" };
  io.checks = () => [gate("service-liveness", "fail", [], { findings: [{ status: "fail", text: "not running", subject: ghost }], judged: [mod] })];
  const r1 = assess(io, {}, NOW);
  const d1 = got(r1, site, "drift");
  check(d1?.status === "warning" && d1.reason === "not-in-cmdb" && d1.message.startsWith("module ghost: in the cluster, not in the CMDB"), "a guest the CMDB does not have is a discovery finding on the site, named, not a site outage");
  check(got(r1, site, "operational")?.reason !== "guest-stopped", "…the site's operational is not taken by it");
  io.checks = () => [gate("service-liveness", "pass", [], { judged: [mod] })];
  const r2 = assess(io, {}, later(5));
  check(got(r2, site, "drift")?.reason !== "not-in-cmdb", "the gate ran again without it: the finding is over, though the site is in no judged list");
  io.checks = () => [gate("service-liveness", "skip")];
  check(got(assess(io, {}, later(10)), site, "drift")?.reason !== "not-in-cmdb", "…and it stays over when the gate later skips");
}

// ── maintenance windows: the update's, the receiver's, the conditions' ──
{
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  io.checks = () => [gate("service-liveness", "fail", [], { findings: [{ status: "fail", text: "not running", subject: mod }], judged: [mod] })];
  const inSec = (min: number): number => Math.floor(NOW.getTime() / 1000) + min * 60;
  const w = (scope: Window["scope"], until: number): Window => ({ name: "restart-x", scope, until, reason: "x restarted by its update" });
  io.windows = () => [w(["tappaas1"], inSec(60))];
  const r = assess(io, {}, NOW);
  check(got(r, nc, "operational")?.maintenance?.note === "x restarted by its update", "a window on a node covers the guests that run on it");
  check(got(r, nc, "operational")?.maintenance?.until === new Date(inSec(60) * 1000).toISOString(), "…until the window's end");
  check(got(r, m1, "drift") === undefined || got(r, m1, "drift")?.maintenance !== null, "…and the node itself");
  io.windows = () => [w(["nextcloud"], inSec(-1))];
  check(got(assess(io, {}, NOW), nc, "operational")?.maintenance === null, "a window that has ended silences nothing, though the fault holds");
  io.windows = () => [w("site", inSec(30))];
  const all = assess(io, {}, NOW);
  check(all.objects.every((o) => o.conditions.every((c) => c.maintenance !== null)), "a site window covers every object");
  io.windows = () => [w(["network"], inSec(30))];
  check(got(assess(io, {}, NOW), nc, "operational")?.maintenance === null, "a window on another guest covers nothing here");
}

// ── ageing: stale inputs, unconfirmed oks, frozen counts ──
{
  // Switch ports last reported eleven days ago: their link is no judgement.
  const s = fresh();
  const p2 = obj("port", "nic0");
  const items = [...s.items.filter((o) => o.id !== port.id), { ...port, attributes: { link: "up" }, lastSeen: "2026-10-19T12:58:00.000Z", seen: { "switch-manager": "2026-10-19T12:58:00.000Z" } }, { ...p2, attributes: { link: "up" }, lastSeen: NOW.toISOString() }];
  const rels = [...s.rels, rel("connects", port, p2)];
  const io = new StubIO(items, rels);
  const r = assess(io, {}, NOW);
  check(got(r, port, "operational")?.status === "unknown" && got(r, port, "operational")?.reason === "not-observed", "a port last observed eleven days ago is unknown, not green");
  check(/not observed since 2026-10-19/.test(got(r, port, "operational")?.message ?? ""), "…and says since when");
  check(got(r, p2, "operational")?.status === "ok", "the other end, observed now, is judged");
  // The reverse: a port last seen down before its switch went away.
  const items2 = items.map((o) => ({ ...o, attributes: o.id === port.id ? { link: "down" } : { ...o.attributes, conditions: undefined } }));
  const down = got(assess(new StubIO(items2, rels), {}, NOW), port, "operational");
  check(down?.status === "unknown" && /it was critical/.test(down?.message ?? ""), "a stale port that was down is unknown too, saying what it was");
}
{
  // An ok whose owner stops looking ages to unknown; one it no longer gives goes.
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  io.checks = () => [gate("disk-threshold", "pass", [], { judged: [mod] })];
  check(got(assess(io, {}, NOW), nc, "capacity")?.status === "ok", "a gate's ok is stored");
  io.checks = () => [];
  check(got(assess(io, {}, later(30)), nc, "capacity")?.status === "ok", "the gate did not run: the ok holds a while");
  const aged = got(assess(io, {}, later(90)), nc, "capacity");
  check(aged?.status === "unknown" && aged?.reason === "not-checked" && aged?.owner === "disk-threshold", "…and after an hour nobody confirmed is unknown, owned still");
  io.checks = () => [gate("disk-threshold", "pass", [], { judged: [mod] })];
  check(got(assess(io, {}, later(95)), nc, "capacity")?.status === "ok", "the gate looks again: ok");
  // A failure the gate cannot see (an unreachable guest) holds for a day.
  io.checks = () => [gate("disk-threshold", "fail", [], { findings: [{ status: "fail", text: "full", subject: mod }], judged: [mod] })];
  assess(io, {}, later(100));
  io.checks = () => [gate("disk-threshold", "fail", [], { judged: [] })];
  check(got(assess(io, {}, later(300)), nc, "capacity")?.status === "critical", "a failure its gate could not look at stands for hours");
  check(got(assess(io, {}, later(100 + 25 * 60)), nc, "capacity")?.status === "unknown", "…and is unknown after a day unchecked");
}
{
  // An ok stored before the owner was (reason "ok" names nobody), that no
  // source gives any more, goes: it is not aged into an unknown.
  const s = fresh();
  s.items.find((o) => o.id === nc.id)!.attributes.conditions = [cond("drift", "ok", "ok", { lastChecked: "2026-10-01T00:00:00.000Z" })];
  s.items.find((o) => o.id === cluster.id)!.attributes.conditions = [cond("capacity", "ok", "ok", { lastChecked: "2026-10-01T00:00:00.000Z", message: "3 of 3 ok" })];
  const r = assess(new StubIO(s.items, s.rels), {}, NOW);
  check(got(r, nc, "drift") === undefined || got(r, nc, "drift")?.status !== "unknown", "a legacy ok nobody gives is dropped, not unknown");
  check(got(r, cluster, "capacity")?.message !== "3 of 3 ok", "…and a frozen roll-up count with it");
}
{
  // A condition whose reason no table knows (stored by a later release) is
  // taken back by the owner stored with it.
  const s = fresh();
  const vm = s.items.find((o) => o.id === nc.id)!;
  vm.attributes.conditions = [cond("capacity", "critical", "disk-renamed", { owner: "disk-threshold" })];
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  io.checks = () => [gate("disk-threshold", "pass", [], { judged: [mod] })];
  check(got(assess(io, {}, NOW), nc, "capacity")?.status === "ok", "a renamed reason clears: the owner is on the condition");
}
{
  // A roll-up's count is recomputed every run, and an ok one is not carried.
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  io.checks = () => [gate("disk-threshold", "fail", [], { findings: [{ status: "fail", text: "full", subject: mod }], judged: [mod] })];
  const one = got(assess(io, {}, NOW), site, "capacity");
  const net2 = { kind: "module" as const, name: "network" };
  io.checks = () => [gate("disk-threshold", "fail", [], { findings: [{ status: "fail", text: "full", subject: mod }, { status: "fail", text: "full", subject: net2 }], judged: [mod, net2] })];
  const two = got(assess(io, {}, later(5)), site, "capacity");
  check(one?.status === "critical" && two?.status === "critical" && one.message !== two.message, `a roll-up's count follows its members (${one?.message} → ${two?.message})`);
  io.checks = () => [gate("disk-threshold", "pass", [], { judged: [mod, net2] })];
  const ok1 = got(assess(io, {}, later(10)), site, "capacity");
  const ok2 = got(assess(io, {}, later(15)), site, "capacity");
  check(/^1 of/.test(ok1?.message ?? "") && ok2?.derived === true && ok2.owner === "derive", `…and drops when members recover, owned by derive (${ok1?.message})`);
  const vm = s.items.find((o) => o.id === nc.id)!;
  vm.attributes.conditions = [];
  s.items.find((o) => o.id === net.id)!.attributes.conditions = [];
  check(got(assess(io, {}, later(20)), site, "drift")?.message !== "3 of 3 ok" , "a roll-up nobody computes is not carried as a judgement of its own");
}

// ── an ack the split moved to another type no longer holds this one ──
{
  const s = fresh();
  const vm = s.items.find((o) => o.id === nc.id)!;
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  io.checks = () => [gate("disk-threshold", "fail", [], { findings: [{ status: "fail", text: "t", subject: mod }], judged: [mod] })];
  assess(io, {}, NOW);
  const at = later(1).toISOString();
  const word = { ack: { by: "lars", note: "about the hit", until: null, sticky: false, at }, at };
  // Stored as the migration leaves it: the condition still carries the ack, the word stands under threat.
  const carry = (): void => { for (const c of vm.attributes.conditions as Condition[]) if (c.type === "capacity") { c.acknowledged = word.ack; c.operatorAt = at; } };
  carry();
  vm.attributes.acknowledgements = { threat: word };
  check(got(assess(io, {}, later(2)), nc, "capacity")?.acknowledged === null, "a carried ack whose word now stands under another type no longer holds the condition: it is heard again");
  carry();
  vm.attributes.acknowledgements = { capacity: word };
  check(got(assess(io, {}, later(3)), nc, "capacity")?.acknowledged?.by === "lars", "…one whose word stands under its own type still holds");
}

// ── the operator's word and emit's flapping: attributes of their own ──
{
  const s = fresh();
  const vm = s.items.find((o) => o.id === nc.id)!;
  const io = new StubIO(s.items, s.rels);
  const mod = { kind: "module" as const, name: "nextcloud" };
  const fail = (st: "fail" | "warn" | "pass"): void => void (io.checks = () => [gate("disk-threshold", st, [], { findings: st === "pass" ? [] : [{ status: st, text: "t", subject: mod }], judged: [mod] })]);
  fail("fail");
  assess(io, {}, NOW);
  const say = (ack: Record<string, unknown> | null, at: string): void => void (vm.attributes.acknowledgements = { capacity: { ack, at } });
  say({ by: "lars", note: "known", until: null, sticky: false, at: later(1).toISOString() }, later(1).toISOString());
  const taken = got(assess(io, {}, later(2)), nc, "capacity");
  check(taken?.acknowledged?.by === "lars" && taken.operatorAt === later(1).toISOString(), "assess takes the operator's word onto the condition");
  check(got(assess(io, {}, later(3)), nc, "capacity")?.acknowledged?.by === "lars", "…and keeps it");
  fail("warn");
  check(got(assess(io, {}, later(4)), nc, "capacity")?.acknowledged === null, "a plain ack ends with the status, the word staying as it was");
  check(got(assess(io, {}, later(5)), nc, "capacity")?.acknowledged === null, "…and is not taken again");
  say({ by: "lars", note: "k", until: null, sticky: true, at: later(6).toISOString() }, later(6).toISOString());
  assess(io, {}, later(7));
  fail("fail");
  check(got(assess(io, {}, later(8)), nc, "capacity")?.acknowledged?.sticky === true, "a sticky ack lasts across a change of status");
  fail("pass");
  check((got(assess(io, {}, later(9)), nc, "capacity")?.acknowledged ?? null) === null, "…and ends at ok");
  fail("fail");
  say({ by: "lars", note: "k", until: later(20).toISOString(), sticky: false, at: later(10).toISOString() }, later(10).toISOString());
  check(got(assess(io, {}, later(11)), nc, "capacity")?.acknowledged !== null, "an ack with an until holds before it");
  check(got(assess(io, {}, later(21)), nc, "capacity")?.acknowledged === null, "…and ends at it");
  say({ by: "lars", note: "again", until: null, sticky: false, at: later(22).toISOString() }, later(22).toISOString());
  assess(io, {}, later(23));
  say(null, later(24).toISOString());
  check(got(assess(io, {}, later(25)), nc, "capacity")?.acknowledged === null, "unack: the word without an ack clears it");
  // Concurrent writers: an ack written while assess runs is not lost.
  const racer = new StubIO(s.items, s.rels);
  racer.checks = io.checks;
  const objects = racer.objects.bind(racer);
  racer.objects = () => {
    const read = objects().map((o) => ({ ...o, attributes: { ...o.attributes } }));
    // the operator acks after assess read the CMDB, before it writes
    say({ by: "ops", note: "during", until: null, sticky: false, at: later(26).toISOString() }, later(26).toISOString());
    return read;
  };
  assess(racer, {}, later(27));
  check((vm.attributes.acknowledgements as Record<string, { ack: { by: string } }>).capacity.ack.by === "ops", "an ack made during an assess run survives it: assess never writes the operator's attribute");
  check(got(assess(io, {}, later(28)), nc, "capacity")?.acknowledged?.by === "ops", "…and the next run takes it");
  // Flapping is emit's attribute, projected.
  vm.attributes.flapping = { capacity: { held: "critical" } };
  const f = got(assess(io, {}, later(29)), nc, "capacity");
  check(f?.flapping === true && f.flappingHeld === "critical", "emit's flapping is projected onto the condition");
  vm.attributes.flapping = {};
  check(got(assess(io, {}, later(30)), nc, "capacity")?.flapping === undefined, "…and goes when emit ends it");
}
{
  // A root's ack silences its impact, via; a second root hears it again.
  const s = fresh();
  const io = new StubIO(s.items, s.rels);
  const node = { kind: "node" as const, name: "tappaas1" };
  io.checks = () => [gate("pulse", "fail", [], { findings: [{ status: "fail", text: "offline", subject: node }], judged: [node] })];
  assess(io, {}, NOW);
  s.items.find((o) => o.id === m1.id)!.attributes.acknowledgements = { operational: { ack: { by: "lars", note: "n", until: null, sticky: false, at: later(1).toISOString() }, at: later(1).toISOString() } };
  const r = assess(io, {}, later(2));
  check(got(r, nc, "impact")?.acknowledged?.via?.[0] === m1.id, "a root's ack silences its impact, via the root");
  s.items.find((o) => o.id === m1.id)!.attributes.acknowledgements = { operational: { ack: null, at: later(3).toISOString() } };
  check(got(assess(io, {}, later(4)), nc, "impact")?.acknowledged === null, "…and the impact is heard again when the root is unacknowledged");
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
  vm.attributes.conditions = [cond("capacity", "critical", "disk-full", { acknowledged: { by: "lars", note: "n", until: null, sticky: false, at: T0 } })];
  vm.attributes.flapping = { capacity: { held: "critical" } };
  const kept = got(assess(io, {}, NOW), nc, "capacity")!;
  check(kept.flapping === true && kept.flappingHeld === "critical" && kept.acknowledged?.at === T0, "an ack set before the attribute existed, and emit's flapping, survive a run");
  io.checks = () => [gate("disk-threshold", "pass", [], { judged: [mod] })];
  check(got(assess(io, {}, later(1)), nc, "capacity")?.flapping === true, "…also across a change of status");
  vm.attributes.flapping = {};
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
