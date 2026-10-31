// derive.test.ts — ADR-041 D3 over a small graph: a node down takes its guests,
// its services and what depends on them; a redundancy group partly down
// degrades its dependant, wholly down crosses; a warning crosses nothing,
// unless a rule says so; a common ancestor is the root; a cable's two ends;
// roll-ups.

import { CmdbItem, Condition } from "../../src/assess-model";
import { derive } from "../../src/derive";
import { T0, cond, obj, rel, shippedModel } from "./assess-fixture";
import { ConditionType } from "../../../../lib/ts/src/health-rules";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const now = "2026-10-30T09:00:00.000Z";
const src = (...e: [CmdbItem, Condition[]][]): Map<string, Condition[]> => new Map(e.map(([o, c]) => [o.id, c]));
const at = (m: Map<string, Condition[]>, o: CmdbItem, t: ConditionType): Condition | undefined => m.get(o.id)?.find((c) => c.type === t);

const m1 = obj("machine", "tappaas1");
const m2 = obj("machine", "tappaas2");
const vm1 = obj("vm", "nextcloud");
const vm2 = obj("vm", "identity");
const svc = obj("service", "identity:identity");
const vm3 = obj("vm", "other");
const site = obj("site", "home");
const cluster = obj("cluster", "c1");
const all = [m1, m2, vm1, vm2, svc, vm3, site, cluster];
const rels = [
  rel("runs-on", vm1, m1), rel("runs-on", vm2, m2), rel("runs-on", svc, vm2), rel("depends-on", vm1, svc), rel("runs-on", vm3, m1),
  rel("member-of", m1, cluster), rel("member-of", m2, cluster), rel("backs-up", obj("datastore", "ds"), vm1),
];

// ── a node down ──
{
  const d = derive(all, src(
    [m2, [cond("operational", "critical", "node-down", { since: "2026-10-30T02:14:00.000Z" })]],
    [vm2, [cond("operational", "critical", "guest-stopped", { since: "2026-10-30T02:15:00.000Z" })]],
  ), rels, shippedModel(), now);
  const c = d.conditions;
  check(at(c, vm2, "impact")?.status === "critical" && at(c, vm2, "impact")?.rootCause === m2.id, "a node down: impact on its guest, naming the node");
  check(at(c, vm2, "operational")?.derived === true && at(c, vm2, "operational")?.rootCause === m2.id, "…the guest's own liveness is derived");
  check(at(c, svc, "impact")?.rootCause === m2.id, "…transitively on its service");
  check(at(c, vm1, "impact")?.rootCause === m2.id, "…and a module that depends on that service, on another node");
  check(at(c, m2, "operational")?.derived === false && at(c, m2, "impact") === undefined, "the node itself is no symptom");
  check(at(c, vm3, "impact") === undefined, "a guest on the other node is untouched");
  check(d.rootCauses.length === 1 && d.rootCauses[0].id === m2.id && d.rootCauses[0].impactedCount === 3 && d.rootCauses[0].type === "operational", "one root, with what it impacts");
  check(at(c, site, "impact")?.status === "critical" && at(c, site, "impact")?.derived === true, "the site rolls it up, derived");
  check(/3 of \d+ critical/.test(at(c, site, "impact")?.message ?? ""), "…counted");
  check(!d.rootCauses.some((r) => r.id === site.id), "a roll-up is never a root");
}

// ── a failure that is not explained below ──
{
  const d = derive(all, src(
    [m2, [cond("operational", "critical")]],
    [vm2, [cond("capacity", "critical", "disk-full")]],
  ), rels, shippedModel(), now);
  check(at(d.conditions, vm2, "capacity")?.derived === false, "another type on an impacted object stays its own");
  check(d.rootCauses.length === 1, "…and is no root while its node is down");
}
{
  const d = derive(all, src([vm1, [cond("maintenance", "warning", "reboot-pending")]]), rels, shippedModel(), now);
  check(d.rootCauses.length === 1 && d.rootCauses[0].impactedCount === 0, "a warning nothing explains is a root of nothing");
}

// ── a warning crosses nothing, until a rule says so ──
{
  const input = () => src([m2, [cond("operational", "warning", "lan-uplink")]], [vm2, [cond("operational", "warning", "guest-slow")]]);
  const off = derive(all, input(), rels, shippedModel(), now);
  check(at(off.conditions, vm2, "impact") === undefined, "shipped: a warning crosses nothing");
  const on = derive(all, input(), rels, shippedModel([{ relation: "runs-on", from: "vm", to: "machine", source: { type: "operational", status: "warning" }, impact: "warning" }]), now);
  check(at(on.conditions, vm2, "impact")?.status === "warning" && at(on.conditions, vm2, "operational")?.derived === true, "a rule added in health-rules.json changes it");
  check(at(on.conditions, svc, "impact") === undefined, "…and only over the class it names");
  const worse = derive(all, src([m2, [cond("operational", "warning")]], [vm2, [cond("operational", "critical", "guest-stopped")]]), rels, shippedModel([{ relation: "runs-on", source: { type: "operational", status: "warning" }, impact: "warning" }]), now);
  check(at(worse.conditions, vm2, "operational")?.derived === false, "a warning does not silence a critical");
}

// ── required, redundancy ──
{
  const node = obj("machine", "n");
  const a = obj("port", "uplink-a");
  const b = obj("port", "uplink-b");
  const group = { redundancyGroup: "uplinks" };
  const nic = obj("port", "nic");
  const r = [rel("connects", nic, a, group), rel("connects", nic, b, group)];
  const one = derive([node, a, b, nic], src([a, [cond("operational", "critical", "link-down")]]), r, shippedModel(), now);
  const partly = at(one.conditions, nic, "impact");
  check(partly?.status === "warning" && partly?.rootCause === a.id && partly?.derived === true, "two uplinks in one group, one down: a warning impact naming the failed member");
  check(partly?.reason === "redundancy-degraded" && /^one of two in uplinks down: port uplink-a/.test(partly?.message ?? ""), `…saying so (${partly?.message})`);
  check(one.rootCauses.length === 1 && one.rootCauses[0].id === a.id && one.rootCauses[0].impactedCount === 1, "…the member is the root, with the degraded dependant counted");
  const both = derive([node, a, b, nic], src([a, [cond("operational", "critical", "link-down")]], [b, [cond("operational", "critical", "link-down")]]), r, shippedModel(), now);
  check(at(both.conditions, nic, "impact")?.status === "critical", "both down: the rule's own impact");
  check(at(both.conditions, nic, "impact")?.reason === "link-down", "…the failure's reason, not the group's");

  // A bond: two cables, each with its own dependant, one group by name.
  const sw1 = obj("port", "sw-01/5");
  const sw2 = obj("port", "sw-02/5");
  const eno1 = obj("port", "srv-01/eno1");
  const eno2 = obj("port", "srv-01/eno2");
  const bond = { redundancyGroup: "tappaas1:lanbond" };
  const legs = [rel("connects", sw1, eno1, bond), rel("connects", sw2, eno2, bond)];
  const ports = [sw1, sw2, eno1, eno2];
  const leg = derive(ports, src([sw1, [cond("operational", "critical", "link-down")]]), legs, shippedModel(), now);
  check(at(leg.conditions, eno1, "impact")?.status === "warning" && at(leg.conditions, eno1, "impact")?.rootCause === sw1.id, "a bond, one leg down: its NIC degraded, naming the switch port");
  check(leg.rootCauses.length === 1 && leg.rootCauses[0].id === sw1.id, "…a partly failed group makes its dependant no root");
  check(at(leg.conditions, eno2, "impact") === undefined && at(leg.conditions, sw2, "impact") === undefined, "…the other leg untouched");
  const ends = derive(ports, src(
    [sw1, [cond("operational", "critical", "link-down", { since: "2026-10-30T08:00:00.000Z" })]],
    [eno1, [cond("operational", "critical", "link-down", { since: "2026-10-30T08:00:03.000Z" })]],
  ), legs, shippedModel(), now);
  check(ends.rootCauses.length === 1 && ends.rootCauses[0].id === sw1.id, "a bond's leg seen down from both ends: one root, the earlier");
  check(at(ends.conditions, eno1, "operational")?.derived === true && at(ends.conditions, eno1, "operational")?.rootCause === sw1.id, "…the NIC's own link-down is the same failure: derived, so no root of its own");
  check(at(ends.conditions, eno1, "impact")?.status === "warning", "…and the NIC is degraded, not down");
  const gone = derive(ports, src([sw1, [cond("operational", "critical", "link-down")]], [sw2, [cond("operational", "critical", "link-down")]]), legs, shippedModel(), now);
  check(at(gone.conditions, eno1, "impact")?.status === "critical" && at(gone.conditions, eno2, "impact")?.status === "critical", "a bond, both legs down: both NICs critical");
  const sw = obj("machine", "sw-01");
  const deep = derive([...ports, sw], src([sw, [cond("operational", "critical", "switch-down")]]), [...legs, rel("part-of", sw1, sw)], shippedModel([{ relation: "part-of", source: { type: "operational", status: "critical" }, impact: "critical" }]), now);
  check(at(deep.conditions, eno1, "impact")?.status === "warning" && at(deep.conditions, eno1, "impact")?.rootCause === sw.id, "a switch down behind one leg: the NIC degraded, the switch its root");
  check(/down: port sw-01\/5 \(machine sw-01\)/.test(at(deep.conditions, eno1, "impact")?.message ?? ""), `…the message names the member and the root (${at(deep.conditions, eno1, "impact")?.message})`);
  const s1 = obj("service", "dns:a");
  const s2 = obj("service", "dns:b");
  const dep = [rel("depends-on", vm1, s1, { redundancyGroup: "dns" }), rel("depends-on", vm1, s2, { redundancyGroup: "dns" })];
  const two = derive([vm1, s1, s2], src([s1, [cond("operational", "critical")]], [s2, [cond("operational", "critical")]]), dep, shippedModel(), now);
  check(at(two.conditions, vm1, "impact")?.status === "critical" && two.rootCauses.length === 2 && two.rootCauses.every((r) => r.impactedCount === 1), "two providers down: both are roots of the one symptom");
  const opt = rel("depends-on", vm1, svc, { required: false });
  const d = derive(all, src([svc, [cond("operational", "critical")]]), [opt], shippedModel(), now);
  check(at(d.conditions, vm1, "impact") === undefined, "a relation row saying required: false carries nothing");
  const bu = derive(all, src([vm1, [cond("operational", "critical")]]), [rel("backs-up", obj("datastore", "ds"), vm1)], shippedModel([{ relation: "backs-up", source: { type: "operational", status: "critical" }, impact: "critical" }]), now);
  check(at(bu.conditions, obj("datastore", "ds"), "impact") === undefined, "backs-up only informs");
}

// ── a cable sees it from both ends ──
{
  const a = obj("port", "sw:1");
  const b = obj("port", "srv:eno1");
  const d = derive([a, b], src(
    [a, [cond("operational", "critical", "link-down", { since: "2026-10-30T08:00:00.000Z" })]],
    [b, [cond("operational", "critical", "link-down", { since: "2026-10-30T08:00:05.000Z" })]],
  ), [rel("connects", a, b)], shippedModel(), now);
  check(d.rootCauses.length === 1 && d.rootCauses[0].id === a.id, "both ends of a cable down: the earlier is the root");
  check(at(d.conditions, b, "operational")?.derived === true && at(d.conditions, a, "operational")?.derived === false, "…the other derived");
}

// ── the lowest common ancestor ──
{
  const d = derive(all, src(
    [m1, [cond("operational", "warning", "lan-uplink")]],
    [vm1, [cond("operational", "critical", "guest-stopped")]],
    [vm3, [cond("operational", "critical", "guest-stopped")]],
  ), rels, shippedModel(), now);
  check(d.rootCauses.length === 1 && d.rootCauses[0].id === m1.id && d.rootCauses[0].impactedCount === 2, "two failing guests under a warning node: the node is the root");
  check(at(d.conditions, vm1, "operational")?.rootCause === m1.id, "…they name it");
  check(at(d.conditions, vm1, "operational")?.derived === false, "…and keep their own critical: validate still fails");
  const one = derive(all, src([m1, [cond("operational", "warning")]], [vm1, [cond("operational", "critical")]]), rels, shippedModel(), now);
  check(one.rootCauses.length === 2, "one failing guest under a warning node: both stand");
  const up = derive(all, src(
    [cluster, [cond("operational", "warning", "quorum-at-risk", { since: "2026-10-29T00:00:00.000Z" })]],
    [m1, [cond("operational", "warning", "lan-uplink")]],
    [vm1, [cond("operational", "critical")]], [vm3, [cond("operational", "critical")]],
  ), rels, shippedModel(), now);
  check(up.rootCauses.some((r) => r.id === m1.id) && !up.rootCauses.some((r) => r.id === vm1.id), "the lowest ancestor takes them, not the one above it");
  check(T0 < now, "fixture times hold");
}

// ── roll-ups ──
{
  const rack = obj("rack", "r1");
  const srv = obj("server", "srv-01");
  const env = obj("environment", "home");
  const r = [rel("placed-in", srv, rack), rel("allocated-to", srv, m1), rel("member-of", vm1, env), rel("member-of", vm3, env)];
  const d = derive([...all, rack, srv, env], src([vm1, [cond("capacity", "warning", "disk-full")]], [vm3, [cond("capacity", "ok", "ok")]], [m1, [cond("operational", "critical")]]), r, shippedModel(), now);
  check(at(d.conditions, env, "capacity")?.status === "warning" && at(d.conditions, env, "capacity")?.message === "1 of 2 warning", "an environment: the worst of its members, counted");
  check(at(d.conditions, rack, "operational")?.status === "critical", "a rack: through the box to the machine on it");
  const quiet = derive(all, src([cluster, [cond("operational", "warning", "quorum-at-risk")]], [m1, [cond("operational", "ok", "ok")]]), rels, shippedModel(), now);
  check(at(quiet.conditions, cluster, "operational")?.derived === false && at(quiet.conditions, cluster, "operational")?.reason === "quorum-at-risk", "a collection's own worse condition stands");
  const ack = derive(all, src([vm1, [cond("capacity", "critical", "disk-full", { acknowledged: { by: "a", note: "", until: null, sticky: false } })]], [vm3, [cond("capacity", "ok", "ok")]]), rels, shippedModel(), now);
  check(at(ack.conditions, site, "capacity")?.status === "ok", "an acknowledged condition is not counted");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
