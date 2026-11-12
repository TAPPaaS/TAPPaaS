// observations.test.ts — ADR-041 step 2: the judgements of assess-observations.ts
// over object fixtures, each through assess so settle and the owner are real; and
// the colour an object nothing judges takes from its parent (derive.ts).

import { AssessResult, assess } from "../../src/assess";
import { CmdbItem, CmdbRel, Condition } from "../../src/assess-model";
import { PEER_STALE_DAYS, RESTORE_STALE_DAYS } from "../../src/assess-observations";
import { NOW, StubIO, obj, rel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const site = obj("site", "home");
const run = (items: CmdbItem[], rels: CmdbRel[] = [], retired: CmdbItem[] = []): AssessResult => {
  const io = new StubIO([site, ...items], rels);
  io.retired = retired;
  return assess(io, {}, NOW);
};
const got = (r: AssessResult, o: CmdbItem, type = "operational"): Condition | undefined => r.objects.find((x) => x.id === o.id)?.conditions.find((c) => c.type === type);
const is = (r: AssessResult, o: CmdbItem, status: string, reason: string, type = "operational"): boolean => got(r, o, type)?.status === status && got(r, o, type)?.reason === reason;
const days = (d: number): string => new Date(NOW.getTime() + d * 86_400_000).toISOString();

// ── ports ──
{
  const sw = obj("network-device", "sw-01");
  const free = obj("port", "1", { link: "down" });
  const lan = obj("port", "2", { link: "down", role: "lan" });
  const up = obj("port", "3", { link: "up", role: "lan" });
  const fast = obj("port", "4", { link: "up", speed: "10g", linkSpeed: "1g" });
  const peer = obj("port", "5", { link: "up", speed: "10g", linkSpeed: "10g" });
  const c1 = obj("port", "6", { link: "up", speed: "10g", linkSpeed: "1g" });
  const c2 = obj("port", "7", { link: "up", speed: "1g", linkSpeed: "1g" });
  const c3 = obj("port", "8", { link: "up", speed: "10g", linkSpeed: "2.5g" });
  const c4 = obj("port", "9", { link: "up", speed: "10g" });
  const rels = [rel("connects", fast, peer), rel("connects", c1, c2), rel("connects", c3, c4, { linkSpeed: "10g" })];
  const r = run([sw, free, lan, up, fast, peer, c1, c2, c3, c4], rels);
  check(is(r, free, "ok", "ok"), "a free port that is down is no failure");
  check(is(r, lan, "warning", "role-port-down"), "a port with a declared role and no link warns");
  check(is(r, up, "ok", "ok"), "…with a link it is ok");
  check(is(r, fast, "warning", "link-slow"), "under what both ends of the cable can do");
  check(is(r, peer, "ok", "ok"), "…the end at full speed is ok");
  check(is(r, c1, "ok", "ok"), "the slower end's speed limits the cable");
  check(is(r, c3, "warning", "link-slow"), "under the cable's recorded link speed");
  check(got(r, c4)?.status === "ok", "no negotiated speed: the cable's link alone");
}

// ── addresses ──
{
  const m = obj("machine", "n1", { addresses: ["10.0.0.10"] });
  const lost = obj("machine", "n2", { addresses: ["10.0.0.11"], stage: "unseen" });
  const dev = obj("device", "sw", { managementAddress: "10.0.0.21" });
  const vm = obj("vm", "app", { nics: [{ mac: "aa:aa:aa:aa:aa:aa" }] });
  const name = obj("dns-name", "app.mgmt.internal", { target: "10.0.0.30", public: false });
  const ip = (s: string, extra = {}): CmdbItem => obj("address", s, { ip: s, ...extra });
  const held = ip("10.0.0.10");
  const unseen = ip("10.0.0.11");
  const mgmt = ip("10.0.0.21");
  const viaName = ip("10.0.0.30");
  const lease = ip("10.0.0.100", { leaseUntil: days(1) });
  const over = ip("10.0.0.101", { leaseUntil: days(-1) });
  const res = ip("10.0.0.102", { reservation: "AA:AA:AA:AA:AA:AA" });
  const orphan = ip("10.0.0.103", { reservation: "bb:bb:bb:bb:bb:bb" });
  const seenMac = ip("10.0.0.104", { reservation: "cc:cc:cc:cc:cc:cc" });
  const sw = obj("port", "1", { seen: [{ mac: "cc:cc:cc:cc:cc:cc" }] });
  const gone = ip("10.0.0.40");
  const reused = ip("10.0.0.41", { leaseUntil: days(1) });
  const retired = [obj("machine", "old", { addresses: ["10.0.0.40", "10.0.0.41"] })];
  const r = run([m, lost, dev, vm, name, held, unseen, mgmt, viaName, lease, over, res, orphan, seenMac, sw, gone, reused], [], retired);
  check(is(r, held, "ok", "ok") && /machine n1/.test(got(r, held)!.message), "an address held by a node");
  check(is(r, unseen, "warning", "address-holder-unseen"), "…whose CI is unseen warns");
  check(is(r, gone, "warning", "address-holder-retired"), "…whose CI is retired warns");
  check(is(r, reused, "ok", "ok"), "…unless someone holds a lease on it again");
  check(is(r, mgmt, "ok", "ok"), "a device's management address");
  check(is(r, viaName, "ok", "ok") && /vm app/.test(got(r, viaName)!.message), "a private name ties an address to its node");
  check(is(r, lease, "ok", "ok") && /leased/.test(got(r, lease)!.message), "a running lease is no failure: a client has no CI");
  check(is(r, over, "ok", "ok"), "…nor an ended one");
  check(is(r, res, "ok", "ok"), "a reservation for a NIC the CMDB has");
  check(is(r, seenMac, "ok", "ok"), "…or a MAC a port sees");
  check(is(r, orphan, "warning", "address-no-ci"), "a reservation for a MAC the CMDB has nowhere");
}

// ── DNS names ──
{
  const addr = obj("address", "10.0.0.5", { ip: "10.0.0.5" });
  const m = obj("machine", "n1", { addresses: ["10.0.0.6"], stage: "unseen" });
  const none = obj("dns-name", "a.x", { public: false });
  const fine = obj("dns-name", "b.x", { target: "10.0.0.5", public: false });
  const lost = obj("dns-name", "c.x", { target: "10.0.0.99", public: false });
  const down = obj("dns-name", "d.x", { target: "10.0.0.6", public: false });
  const old = obj("dns-name", "e.x", { target: "10.0.0.7", public: false });
  const pub = obj("dns-name", "f.example", { target: "2001:db8::1", public: true });
  const cname = obj("dns-name", "g.x", { target: "n1.mgmt.internal", public: false });
  const noCname = obj("dns-name", "h.x", { target: "nope.mgmt.internal", public: false });
  const r = run([addr, m, none, fine, lost, down, old, pub, cname, noCname], [], [obj("vm", "gone", { addresses: ["10.0.0.7"] })]);
  check(is(r, none, "warning", "dns-no-target"), "a DNS name with no target");
  check(is(r, fine, "ok", "ok"), "…pointing at an address the CMDB has");
  check(is(r, lost, "warning", "dns-target-unknown"), "…at an address it does not have");
  check(is(r, down, "warning", "dns-target-unseen"), "…at an unseen CI");
  check(is(r, old, "warning", "dns-target-retired"), "…at a retired CI");
  check(is(r, pub, "ok", "ok"), "a public name's target is the WAN's: no address object");
  check(is(r, cname, "ok", "ok") && is(r, noCname, "warning", "dns-target-unknown"), "a target that is a name");
}

// ── proxy routes ──
{
  const vm = obj("vm", "app");
  const lost = obj("vm", "lost", { stage: "unseen" });
  const a = obj("proxy-route", "a.x", { target: "http://app.srv.internal:80" });
  const b = obj("proxy-route", "b.x", { target: "http://lost.srv.internal:80" });
  const c = obj("proxy-route", "c.x", { target: "https://gone.srv.internal:443" });
  const d = obj("proxy-route", "d.x", { target: "http://nobody.srv.internal:80" });
  const r = run([vm, lost, a, b, c, d], [], [obj("vm", "gone")]);
  check(is(r, a, "ok", "ok"), "a route to a node");
  check(is(r, b, "warning", "route-target-unseen"), "…unseen");
  check(is(r, c, "warning", "route-target-retired"), "…retired");
  check(is(r, d, "warning", "route-target-unknown"), "…known to nothing");
}

// ── zones, VLANs, SSIDs ──
{
  const on = (vlan: number, extra = {}): Record<string, unknown> => ({ vlan, dhcp: { start: "a", end: "b" }, interface: { enabled: true, device: "vlan0" }, ...extra });
  const good = obj("zone", "good", on(200));
  const off = obj("zone", "off", on(300, { interface: { enabled: false, device: "vlan0.300" } }));
  const missing = obj("zone", "missing", { vlan: 310, dhcp: { start: "a", end: "b" } });
  const unc = obj("zone", "unc", on(320));
  const idle = obj("zone", "idle", { vlan: 330 });
  const wg = obj("zone", "wg", { vlan: 0, interface: { enabled: true, device: "wg0" } });
  const sw = obj("device", "sw", { vlans: [{ tag: 1, declared: false }, { tag: 200, declared: true }, { tag: 300, declared: true }, { tag: 298, declared: false }] });
  const clean = obj("device", "sw2", { vlans: [{ tag: 1, declared: false }, { tag: 200, declared: true }] });
  const ssid = obj("ssid", "home", { zone: "good", broadcastOn: ["ap"] });
  const noZone = obj("ssid", "x", { zone: "nope", broadcastOn: ["ap"] });
  const dark = obj("ssid", "y", { zone: "good", broadcastOn: [] });
  const r = run([good, off, missing, unc, idle, wg, sw, clean, ssid, noZone, dark]);
  check(is(r, good, "ok", "ok"), "a zone with its interface, on a switch");
  check(is(r, off, "critical", "zone-interface-disabled"), "an active zone's interface disabled");
  check(is(r, missing, "warning", "zone-no-interface"), "an active zone the firewall lacks");
  check(is(r, unc, "warning", "zone-vlan-uncarried"), "an active zone's VLAN on no switch");
  check(is(r, idle, "ok", "ok") && is(r, wg, "ok", "ok"), "a zone not active, and one with no VLAN");
  check(is(r, sw, "warning", "vlan-undeclared", "drift") && /298/.test(got(r, sw, "drift")!.message) && !/\b1\b/.test(got(r, sw, "drift")!.message), "a VLAN on a switch that no zone declares, not VLAN 1");
  check(got(r, clean, "drift")?.status === "ok", "…none is ok");
  const first = run([obj("zone", "z", { vlan: 310, dhcp: { start: "a", end: "b" } })]);
  check(first.objects.find((o) => o.name === "z")?.conditions[0].status === "ok", "before any firewall read no interface is missing");
  check(is(r, ssid, "ok", "ok") && is(r, noZone, "warning", "ssid-no-zone") && is(r, dark, "warning", "ssid-not-broadcast"), "an SSID: its zone, its access points");
}

// ── software ──
{
  const m = obj("machine", "n1");
  const lost = obj("machine", "n2", { stage: "unseen" });
  const pinned = obj("app", "backup", { version: "1.0.0", release: { module: "backup", version: "1.0.0" } });
  const off = obj("app", "cluster", { version: "0.7.0", release: { module: "cluster", version: "0.8.0" } });
  const svc = obj("service", "x:y", { version: "1.0.0" });
  const mgr = obj("manager", "site-manager");
  const stray = obj("controller", "c");
  const r = run([m, lost, pinned, off, svc, mgr, stray], [rel("runs-on", pinned, m), rel("runs-on", off, m), rel("runs-on", svc, lost), rel("runs-on", mgr, m)]);
  check(is(r, pinned, "ok", "ok") && is(r, pinned, "ok", "ok", "upkeep"), "an app on its node at its release");
  check(is(r, off, "warning", "version-off-pin", "upkeep"), "a version off its release pin");
  check(is(r, svc, "warning", "software-node-unseen"), "software whose node is unseen");
  check(is(r, stray, "warning", "software-no-node"), "software on no node: its node is retired");
  check(is(r, mgr, "ok", "ok") && got(r, mgr, "upkeep") === undefined, "a manager, with no release");
}

// ── assets, backup, shares, lifecycle ──
{
  const bad = obj("server", "srv", { faulty: true, faultNote: "fan" });
  const fine = obj("appliance", "modem", { faulty: false });
  const v1 = obj("vm", "a", { vmid: 101 });
  const v2 = obj("vm", "b", { vmid: 102 });
  const m = obj("machine", "n1");
  const ds = obj("datastore", "main", { gc: { "last-run-state": "ERROR" }, restorePoints: [
    { type: "vm", id: "101", newest: days(-(RESTORE_STALE_DAYS + 1)) }, { type: "vm", id: "102", newest: days(-1) },
    { type: "vm", id: "999", newest: days(-100) }, { type: "host", id: "n1", newest: days(-1) }] });
  const peerOld = obj("backup-peer", "p1", { lastSeen: days(-(PEER_STALE_DAYS + 1)) });
  const peerNew = obj("backup-peer", "p2", { lastSeen: days(-1) });
  const share = obj("share", "media", { grants: [{ consumer: "a" }] });
  const orphan = obj("share", "old", { grants: [{ consumer: "gone" }] });
  const user = obj("user", "lars", { stage: "operational" });
  const lostUser = obj("user", "x", { stage: "unseen" });
  const r = run([bad, fine, v1, v2, m, ds, peerOld, peerNew, share, orphan, user, lostUser]);
  check(is(r, bad, "warning", "asset-faulty", "upkeep") && /fan/.test(got(r, bad, "upkeep")!.message), "a faulty asset (D1)");
  check(is(r, fine, "ok", "ok", "upkeep"), "…an asset not marked faulty is ok");
  check(is(r, ds, "warning", "gc-failed", "upkeep"), "a datastore's GC that failed");
  check(is(r, v1, "warning", "restore-point-stale", "backup"), "a guest's newest restore point too old");
  check(is(r, v2, "ok", "ok", "backup") && is(r, m, "ok", "ok", "backup"), "…a fresh one, a guest's and a host's");
  check(!r.objects.some((o) => o.name === "999"), "…a group whose guest is gone is nobody's");
  check(is(r, peerOld, "warning", "peer-stale", "backup") && is(r, peerNew, "ok", "ok", "backup"), "a backup peer's last sync");
  check(is(r, share, "ok", "ok") && is(r, orphan, "warning", "share-consumer-gone"), "a share's consumers");
  check(is(r, user, "ok", "ok") && is(r, lostUser, "warning", "unseen"), "what only reports: seen or unseen");
}

// ── held and taken back by its own source ──
{
  const a = obj("address", "10.0.0.1", { ip: "10.0.0.1" });
  const m = obj("machine", "n1", { addresses: ["10.0.0.1"], stage: "unseen" });
  const io = new StubIO([site, m, a], []);
  check(got(assess(io, {}, NOW), a)?.reason === "address-holder-unseen", "a finding of this source");
  m.attributes.stage = "operational";
  const later = new Date(NOW.getTime() + 300_000);
  check(got(assess(io, {}, later), a)?.status === "ok", "…ends when it looks again and the holder is back");
}

// ── an object nothing judges takes its parent's colour ──
{
  const asset = obj("network-device", "sw-01");
  const dev = obj("device", "sw", { stage: "operational" });
  const free = obj("port", "1");
  const cabled = obj("port", "2", { link: "up" });
  const passive = obj("passive-device", "panel", { faulty: false });
  const pp = obj("port", "p1");
  const lone = obj("network-device", "spare");
  const rels = [rel("allocated-to", asset, dev), rel("part-of", free, asset), rel("part-of", cabled, asset), rel("part-of", pp, passive)];
  const io = new StubIO([site, asset, dev, free, cabled, passive, pp, lone], [...rels, rel("connects", cabled, pp)]);
  const r = assess(io, {}, NOW);
  check(got(r, free)?.reason === "follows" && got(r, free)?.status === "ok" && got(r, free)?.derived === true, "a free port follows its switch, up the chain");
  check(/network-device sw-01/.test(got(r, free)!.message), "…and says whom");
  check(got(r, asset)?.reason === "follows", "an asset follows its node");
  check(got(r, cabled)?.reason !== "follows", "what is judged follows nothing");
  check(got(r, pp)?.status === "ok", "a parent judged only in another type: ok");
  check(got(r, lone)?.reason !== "follows", "no parent: nothing to follow");
  io.checks = () => [{ name: "switch-ports", status: "warn", detail: "d", rows: [{ status: "warn", text: "sw never read", subject: { kind: "switch", name: "sw" } }] }];
  const later = new Date(NOW.getTime() + 300_000);
  const r2 = assess(io, {}, later);
  const c = got(r2, free)!;
  check(c.status === "warning" && c.derived && c.rootCause === dev.id, "a parent's failure is the follower's colour, derived, naming the root");
  check(!r2.rootCauses.some((x) => x.id === free.id || x.id === asset.id), "…never a root");
  io.checks = () => [];
  check(got(assess(io, {}, new Date(later.getTime() + 300_000)), free)?.reason === "follows", "a run later it is worked out again, not held");
}

// ── disks (ADR-042 D5) ──
{
  const srv = obj("server", "srv-01");
  const vdevs = (states: [string, string][]) => [{ name: "mirror-0", state: "DEGRADED", members: states.map(([serial, state]) => ({ device: `/dev/disk/by-id/ata-X_${serial}-part1`, serial, state })) }];
  const pool = obj("storage-pool", "tanka1", { zfsState: "DEGRADED", vdevs: vdevs([["S6P1", "FAULTED"], ["S6P2", "ONLINE"]]) });
  const failedZfs = obj("disk", "dsk-01", { serial: "S6P1", health: "PASSED", displayName: "ata-X_S6P1" });
  const fine = obj("disk", "dsk-02", { serial: "s6p-2", health: "PASSED" });
  const dead = obj("disk", "dsk-03", { serial: "WD77", health: "FAILED" });
  const sectors = obj("disk", "dsk-04", { serial: "ZA11", health: "PASSED", smart: { reallocated: 8, pending: 2 } });
  const worn = obj("disk", "dsk-05", { serial: "NV1", wearout: 7, kind: "ssd" });
  const lightly = obj("disk", "dsk-06", { serial: "NV2", wearout: 12, kind: "ssd" });
  const hot = obj("disk", "dsk-07", { serial: "NV3", temperature: 72, kind: "nvme" });
  const warm = obj("disk", "dsk-08", { serial: "NV4", temperature: 65, kind: "nvme" });
  const warmHdd = obj("disk", "dsk-09", { serial: "HD1", temperature: 65, kind: "hdd" });
  const quiet = obj("disk", "dsk-10", { serial: "Q1", faulty: true, faultNote: "clicks" });
  const pulled = obj("disk", "dsk-11", { serial: "GONE42" });
  const pool2 = obj("storage-pool", "tankb1", { zfsState: "DEGRADED", vdevs: [{ name: "mirror-0", members: [{ device: "/dev/disk/by-id/ata-HGST_GONE42-part1", state: "UNAVAIL" }, { device: "/dev/sdq1", serial: "OTHER", state: "ONLINE" }] }] });
  const disks = [failedZfs, fine, dead, sectors, worn, lightly, hot, warm, warmHdd, quiet, pulled];
  const mirror = { redundancyGroup: "tappaas1:tanka1:mirror-0" };
  const rels = [...disks.map((d) => rel("part-of", d, srv)), rel("built-on", pool, failedZfs, mirror), rel("built-on", pool, fine, mirror), rel("built-on", pool2, pulled)];
  const r = run([srv, pool, pool2, ...disks], rels);
  check(is(r, failedZfs, "critical", "zfs") && /ZFS FAULTED in tanka1/.test(got(r, failedZfs)?.message ?? "") && /ata-X_S6P1/.test(got(r, failedZfs)?.message ?? ""), "a disk ZFS faulted in a pool built on it is critical, zfs, its by-id name in the message");
  check(is(r, fine, "ok", "ok"), "…its mirror partner, ONLINE (its serial as compared), is ok");
  check(is(r, dead, "critical", "smart"), "Proxmox's health FAILED: critical, smart");
  check(is(r, sectors, "warning", "smart") && /8 reallocated, 2 pending/.test(got(r, sectors)?.message ?? ""), "reallocated or pending sectors: a warning, smart");
  check(is(r, worn, "warning", "wear") && is(r, lightly, "ok", "ok"), "under 10 % of its rated life: a warning, wear; 12 % is ok");
  check(is(r, hot, "warning", "temperature") && is(r, warm, "ok", "ok") && is(r, warmHdd, "warning", "temperature"), "over its kind's temperature (NVMe 70 °C, HDD 60 °C): a warning");
  check(got(r, quiet)?.reason === "follows" && got(r, quiet, "upkeep")?.reason === "asset-faulty", "nothing observed: it follows its asset; the faulty flag is upkeep, as an asset's");
  check(is(r, pulled, "critical", "zfs"), "a pulled disk ZFS names by its by-id path, UNAVAIL: critical");
  check(got(r, pool)?.derived === true && got(r, pool)?.rootCause === failedZfs.id, "the pool's own DEGRADED is the disk's failure seen from above");
  check(got(r, pool, "impact")?.status === "warning" && got(r, pool, "impact")?.reason === "redundancy-degraded", "…and it is degraded, not down");
  check(got(r, pool2, "impact")?.status === "critical" && got(r, pool2, "impact")?.rootCause === pulled.id, "a vdev's only recorded member down, no group: the pool down");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
