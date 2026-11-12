// windows.test.ts — what a maintenance window covers: each object it names,
// whole, and on what that object would impact if it failed, what the failure
// would explain or cover there, under the health records in use. One case per
// row of the table in the design: wider along real dependencies, narrower
// where the outage would not account for a condition.

import { CmdbItem, CmdbRel, Condition } from "../../src/assess-model";
import { derive } from "../../src/derive";
import { Window, coveredBy, windowOf } from "../../src/windows";
import { cond, obj, rel, shippedModel } from "./assess-fixture";
import { readFileSync } from "fs";
import { join } from "path";
import { HealthRecord } from "../../../../lib/ts/src/health-records";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const now = "2026-10-30T09:00:00.000Z";
const nowMs = Date.parse(now);
const win = (names: string[] | "site"): Window => ({ name: "w", scope: names, until: nowMs / 1000 + 3600, reason: "update" });

/** Every condition after derive, with the window it is in (or none). */
function covered(objects: CmdbItem[], source: [CmdbItem, Condition[]][], relations: CmdbRel[], w: Window, model = shippedModel()): (o: CmdbItem, type: string) => boolean | undefined {
  const names = w.scope === "site" ? [] : objects.filter((o) => (w.scope as string[]).includes(o.name)).map((o) => o.id);
  const d = derive(objects, new Map(source.map(([o, cs]) => [o.id, cs])), relations, model, now, { cover: names });
  const cov = windowOf([w], objects, nowMs, (id) => d.covers?.get(id) ?? new Map());
  return (o, type) => {
    const c = d.conditions.get(o.id)?.find((x) => x.type === type);
    return c ? coveredBy(c, cov.get(o.id)) !== undefined : undefined;
  };
}

const node = obj("machine", "tappaas1");
const guest = obj("vm", "identity");
const svc = obj("service", "identity:identity");
const nc = obj("vm", "nextcloud");
const pool = obj("storage-pool", "tank");
const far = obj("vm", "elsewhere");
const node2 = obj("machine", "tappaas2");

// A guest, its services, on a node in a window: covered, every condition.
{
  const is = covered([node, guest, svc], [[guest, [cond("capacity", "critical", "disk-full"), cond("operational", "critical", "guest-stopped")]], [svc, [cond("operational", "warning", "alert-x")]]],
    [rel("runs-on", guest, node), rel("runs-on", svc, guest)], win(["tappaas1"]));
  check(is(guest, "operational") === true && is(guest, "capacity") === true && is(svc, "operational") === true, "a node in a window: its guest and services, every condition (a critical covers)");
}

// What depends on a service of a guest in a window: covered now.
{
  const is = covered([node, guest, svc, nc], [[nc, [cond("operational", "warning", "alert-login-failed")]]],
    [rel("runs-on", guest, node), rel("runs-on", svc, guest), rel("depends-on", nc, svc)], win(["identity"]));
  check(is(nc, "operational") === true, "nextcloud while identity is in a window: its login alerts are silent");
}

// What is stored on a pool whose node is in a window, wherever it runs.
{
  const is = covered([node, node2, pool, far], [[far, [cond("operational", "critical", "guest-stopped")]]],
    [rel("runs-on", pool, node), rel("runs-on", far, node2), rel("stored-on", far, pool)], win(["tappaas1"]));
  check(is(far, "operational") === true, "a guest on another node, stored on the window node's pool: covered");
}

// An HA guest on a node in a window: only what a degraded node explains.
{
  const ha = obj("vm", "firewall", { haNode: "tappaas2" });
  const is = covered([node, ha], [[ha, [cond("operational", "critical", "guest-stopped"), cond("capacity", "critical", "disk-full")]]], [rel("runs-on", ha, node)], win(["tappaas1"]));
  check(is(ha, "operational") === true, "an HA guest on the window's node: its operational condition is silent");
  check(is(ha, "capacity") === false, "…a full disk on it is heard: a moving guest does not explain it");
}

// A NIC behind one leg of a bond: one of two down is silent; both down is heard.
{
  const sw1 = obj("port", "sw-01/5"), sw2 = obj("port", "sw-02/5"), eno1 = obj("port", "srv/eno1"), eno2 = obj("port", "srv/eno2");
  const bond = { redundancyGroup: "tappaas1:lanbond" };
  const legs = [rel("connects", sw1, eno1, bond), rel("connects", sw2, eno2, bond)];
  const one = covered([sw1, sw2, eno1, eno2], [[sw1, [cond("operational", "critical", "link-down")]], [eno1, [cond("operational", "critical", "link-down", { since: "2026-10-30T08:00:03.000Z" })]]], legs, win(["sw-01/5"]));
  check(one(eno1, "impact") === true && one(eno1, "operational") === true, "a bond's leg in a window: the NIC's one of two down is silent");
  const both = covered([sw1, sw2, eno1, eno2], [[sw1, [cond("operational", "critical", "link-down")]], [sw2, [cond("operational", "critical", "link-down")]]], legs, win(["sw-01/5"]));
  check(both(eno1, "impact") === false, "…the other leg down too is not what the window simulated: heard");
}

// A relation row marked required: false carries nothing, so covers nothing.
{
  const opt = obj("vm", "optional");
  const is = covered([node, opt], [[opt, [cond("operational", "critical", "guest-stopped")]]], [rel("runs-on", opt, node, { required: false })], win(["tappaas1"]));
  check(is(opt, "operational") === false, "a guest whose runs-on says required: false: not covered");
}

// A rule changes it with everything else: soften a crossing, the window stops covering.
{
  const soft = shippedModel([{ id: "site.propagate.nc-free", kind: "propagate", when: { relation: "depends-on", dependant: { name: "nextcloud" }, condition: { type: "operational", status: "critical" } }, as: "none" }]);
  const is = covered([node, guest, svc, nc], [[nc, [cond("operational", "warning", "alert-login-failed")]]],
    [rel("runs-on", guest, node), rel("runs-on", svc, guest), rel("depends-on", nc, svc)], win(["identity"]), soft);
  check(is(nc, "operational") === false, "a site record that softens the crossing: the window no longer covers the far side");
}

// The nodes of a zone, the zone in a window: covered, by the network module's record.
{
  const zone = obj("zone", "srv");
  const web = obj("vm", "web");
  const net = JSON.parse(readFileSync(join(process.env.HM_CICD_DIR ?? join(__dirname, "../../../../../../.."), "../network/network-health.json"), "utf8")) as { records: HealthRecord[] };
  const src: [CmdbItem, Condition[]][] = [[web, [cond("operational", "critical", "unreachable")]]];
  const without = covered([zone, web], src, [rel("member-of", web, zone)], win(["srv"]));
  check(without(web, "operational") === false, "a zone in a window, with core alone: its nodes are not covered (a zone down is the network module's to say)");
  const withNet = covered([zone, web], src, [rel("member-of", web, zone)], win(["srv"]), shippedModel(net.records));
  check(withNet(web, "operational") === true, "…with the network module's zone record: the nodes in it are covered");
}

// A site window covers everything; a named object is covered whole.
{
  const is = covered([node, guest, far], [[far, [cond("capacity", "warning", "x")]], [node, [cond("drift", "warning", "y")]]], [rel("runs-on", guest, node)], win("site"));
  check(is(far, "capacity") === true && is(node, "drift") === true, "a site window covers every condition of every object");
  const named = covered([node], [[node, [cond("drift", "warning", "y"), cond("vulnerability", "warning", "z")]]], [], win(["tappaas1"]));
  check(named(node, "drift") === true && named(node, "vulnerability") === true, "the object a window names: every condition");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
