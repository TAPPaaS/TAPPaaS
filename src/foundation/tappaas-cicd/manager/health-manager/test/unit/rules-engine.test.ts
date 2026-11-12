// rules-engine.test.ts — what the record-driven engine can do beyond today's
// records: a quorum (combine over member-of, crossed against its declared end),
// a raising rule and a raising cycle, a type change against a cross-type
// explain, an exception (`as: none`), k of n, a roll-up that never replaces an
// impact the spread gave, the record behind each derived condition, and a
// conflict that is evaluated anyway.

import { CmdbItem, Condition } from "../../src/assess-model";
import { derive } from "../../src/derive";
import { cond, obj, rel, shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const now = "2026-10-30T09:00:00.000Z";
const src = (...e: [CmdbItem, Condition[]][]): Map<string, Condition[]> => new Map(e.map(([o, c]) => [o.id, c.map((x) => ({ ...x }))]));
const at = (d: ReturnType<typeof derive>, o: CmdbItem, t: string): Condition | undefined => d.conditions.get(o.id)?.find((c) => c.type === t);
const down = (since = "2026-10-30T02:00:00.000Z"): Condition[] => [cond("operational", "critical", "node-down", { since })];
const roots = (d: ReturnType<typeof derive>): string[] => d.rootCauses.map((r) => r.id);

// ── a 3-node quorum ──
{
  const cl = obj("cluster", "c1");
  const ms = [0, 1, 2].map((i) => obj("machine", `m${i}`));
  const gs = [0, 1, 2].map((i) => obj("vm", `g${i}`));
  const objs = [cl, ...ms, ...gs];
  const rels = [...ms.map((m) => rel("member-of", m, cl)), ...gs.map((g, i) => rel("runs-on", g, ms[i]))];
  const model = shippedModel([
    { id: "cluster.propagate.node-to-cluster", kind: "propagate", dependantEnd: "to", description: "A node that is down counts against its cluster's quorum.",
      when: { relation: "member-of", provider: { class: "machine" }, dependant: { class: "cluster" }, condition: { type: "operational", status: "critical" } }, as: { status: "critical" } },
    { id: "cluster.combine.quorum", kind: "combine", when: { relation: "member-of", dependant: { class: "cluster" } }, groupBy: "dependant",
      steps: [{ down: 1, as: "warning", reason: "quorum-reduced" }, { down: "half", as: "rule", reason: "quorum-lost" }] },
  ]);
  const one = derive(objs, src([ms[0], down()]), rels, model, now);
  check(at(one, cl, "impact")?.status === "warning" && at(one, cl, "impact")?.reason === "quorum-reduced" && /^one of three in member-of of cluster c1 down: machine m0/.test(at(one, cl, "impact")?.message ?? ""), `quorum, one of three down: the cluster a warning (${at(one, cl, "impact")?.message})`);
  check(roots(one).join() === ms[0].id && at(one, gs[0], "impact")?.status === "critical", "…the node is the root, its guest critical");
  check(at(one, ms[1], "impact") === undefined && at(one, gs[1], "impact") === undefined, "…the other nodes and their guests untouched");
  const two = derive(objs, src([ms[0], down()], [ms[1], down("2026-10-30T02:05:00.000Z")]), rels, model, now);
  check(at(two, cl, "impact")?.status === "critical" && at(two, cl, "impact")?.reason === "quorum-lost", `two of three: the cluster critical, quorum lost (${at(two, cl, "impact")?.reason})`);
  check(roots(two).includes(ms[0].id) && roots(two).includes(ms[1].id) && roots(two).length === 2, `…both dead nodes are roots, neither the other's symptom (${roots(two).join(", ")})`);
  check(at(two, ms[2], "impact")?.status === "critical" && at(two, gs[2], "impact")?.status === "critical", "…the third node and its guest critical");
  check(at(two, ms[2], "impact")?.rootCause === ms[0].id, "…naming the first to fail");
  const three = derive(objs, src([ms[0], down()], [ms[1], down()], [ms[2], down()]), rels, model, now);
  check(roots(three).length === 3, `all three down: three roots (${roots(three).join(", ")})`);
  const site = obj("site", "home");
  const withRoll = derive([...objs, site], src([ms[0], down()], [ms[1], down("2026-10-30T02:05:00.000Z")]), rels, model, now);
  check(at(withRoll, cl, "impact")?.reason === "quorum-lost", "a roll-up never replaces the impact the spread gave: the cluster keeps quorum lost");
  check(at(withRoll, cl, "impact")?.rule === "cluster.combine.quorum", `…and names the record that decided it (${at(withRoll, cl, "impact")?.rule})`);
}

// ── a raising rule, and a raising cycle ──
{
  const g = obj("vm", "g");
  const n = obj("machine", "n2");
  const svc = obj("service", "g:svc");
  const app = obj("vm", "app");
  const rels = [rel("runs-on", g, n), rel("runs-on", svc, g), rel("depends-on", app, svc)];
  const model = shippedModel([{ id: "site.propagate.raise", kind: "propagate", when: { relation: "runs-on", provider: { class: "machine" }, condition: { type: "operational", status: "warning" } }, as: { status: "critical" } }]);
  const d = derive([g, n, svc, app], src([n, [cond("operational", "warning", "fan")]], [g, [cond("operational", "critical", "guest-stopped")]], [app, [cond("capacity", "critical", "disk-full")]]), rels, model, now);
  check(at(d, g, "impact")?.status === "critical" && at(d, g, "impact")?.rootCause === n.id, "a raise: the node's warning reaches its guest as critical");
  check(at(d, g, "operational")?.derived === false && roots(d).includes(g.id), "…the guest that stopped on its own stays a root: a critical is never the symptom of a warning");
  check(roots(d).includes(app.id) && roots(d).includes(n.id), "…so does the app's full disk, and the node itself");
  const a = obj("vm", "a"), b = obj("vm", "b"), sa = obj("service", "a:s"), sb = obj("service", "b:s");
  const cyc = [rel("runs-on", sa, a), rel("runs-on", sb, b), rel("depends-on", a, sb), rel("depends-on", b, sa)];
  const amp = shippedModel([{ id: "site.propagate.amp", kind: "propagate", when: { relation: ["runs-on", "depends-on"], condition: { type: "operational", status: "warning" } }, as: { status: "critical" } }]);
  const c = derive([a, b, sa, sb], src([a, [cond("operational", "warning", "w")]]), cyc, amp, now);
  check([b, sa, sb].every((o) => at(c, o, "impact")?.status === "critical") && roots(c).join() === a.id, "a raising cycle ends, critical all the way round, one root");
}

// ── a type change, against a cross-type explain ──
{
  const pool = obj("storage-pool", "tank"), db = obj("vm", "db"), node = obj("machine", "n");
  const rels = [rel("stored-on", db, pool), rel("runs-on", db, node), rel("runs-on", pool, node)];
  const s = (): Map<string, Condition[]> => src([pool, [cond("performance", "critical", "pool-latency")]], [db, [cond("operational", "warning", "alert-db-timeouts")]]);
  const plain = derive([pool, db, node], s(), rels, shippedModel(), now);
  check(roots(plain).includes(db.id), "shipped: a slow pool does not explain a database's timeout alert");
  const ex = derive([pool, db, node], s(), rels, shippedModel([{ id: "site.explain.slow-pool-alerts", kind: "explain", when: { cause: { type: "performance" }, condition: { type: "operational", reason: { glob: "alert-*" } }, object: { name: "db" } }, effect: "derived" }]), now);
  check(!roots(ex).includes(db.id) && at(ex, db, "operational")?.derived === true && at(ex, db, "operational")?.rule === "site.explain.slow-pool-alerts", "a cross-type explain makes it the pool's, naming the record");
  const tc = derive([pool, db, node], s(), rels, shippedModel([{ id: "site.propagate.slow-pool-op", kind: "propagate", when: { relation: "stored-on", provider: { class: "storage-pool" }, dependant: { name: "db" }, condition: { type: "performance", status: "critical" } }, as: { type: "operational", status: "warning" } }]), now);
  check(JSON.stringify(roots(tc)) === JSON.stringify(roots(ex)) && at(tc, db, "operational")?.derived === true, "a type-changing propagate gives the same roots");
}

// ── an exception, k of n, a conflict evaluated anyway ──
{
  const node = obj("machine", "n"), g7 = obj("vm", "g7", { haNode: "n2" }), g8 = obj("vm", "g8", { haNode: "n2" });
  const rels = [rel("runs-on", g7, node), rel("runs-on", g8, node)];
  const none = derive([node, g7, g8], src([node, down()]), rels, shippedModel([{ id: "site.propagate.g7-none", kind: "propagate", when: { relation: "runs-on", dependant: { name: "g7", attr: { haNode: { exists: true } } }, condition: { type: "operational", status: "critical" } }, as: "none" }]), now);
  check(at(none, g7, "impact") === undefined && at(none, g8, "impact")?.status === "warning", "as none: the failure does not cross where the exception says, elsewhere it does");
  const cl = obj("cluster", "c"), ms = [0, 1, 2, 3].map((i) => obj("machine", `k${i}`));
  const krels = ms.map((m) => rel("member-of", m, cl));
  const kofn = shippedModel([{ id: "site.rollup.cluster-2of4", kind: "rollup", when: { object: { class: "cluster" } }, members: [{ relations: ["member-of"], walk: "inbound" }], fn: { kOfN: { warning: 1, critical: "half" } } }]);
  const k1 = derive([cl, ...ms], src([ms[0], down()]), krels, kofn, now);
  const k2 = derive([cl, ...ms], src([ms[0], down()], [ms[1], down()]), krels, kofn, now);
  check(at(k1, cl, "operational")?.status === "warning" && at(k2, cl, "operational")?.status === "critical", `k of n: one of four a warning, half critical (${at(k1, cl, "operational")?.status}, ${at(k2, cl, "operational")?.status})`);
  const dmz = obj("vm", "web", { haNode: "n2", zone: "dmz" });
  const clash = shippedModel([{ id: "site.propagate.dmz", kind: "propagate", when: { relation: "runs-on", dependant: { zone: "dmz" }, condition: { type: "operational", status: "critical" } }, as: { status: "critical" } }]);
  const cd = derive([node, dmz], src([node, down()]), [rel("runs-on", dmz, node)], clash, now);
  check(at(cd, dmz, "impact")?.status === "critical" && [...cd.trace.conflicts.keys()].some((k) => k.includes("site.propagate.dmz") && k.includes("core.propagate.runs-on.down-ha")), "a conflict that runs: the more severe outcome, and it is reported");
}

// ── the record behind each derived condition ──
{
  const m = obj("machine", "n"), g = obj("vm", "g"), port = obj("port", "p"), srv = obj("server", "s");
  const rels = [rel("runs-on", g, m), rel("part-of", port, srv), rel("allocated-to", srv, m)];
  const d = derive([m, g, port, srv, obj("site", "home")], src([m, down()], [g, [cond("operational", "critical", "guest-stopped", { since: "2026-10-30T02:01:00.000Z" })]]), rels, shippedModel(), now);
  check(at(d, g, "impact")?.rule === "core.propagate.runs-on.down", "an impact names its propagate record");
  check(at(d, g, "operational")?.rule === "core.explain.same-failure", "a derived condition its explain record");
  check(at(d, srv, "operational")?.rule === "core.follow.asset" && at(d, port, "operational")?.rule === "core.follow.port", "a followed colour its follow record");
  check(at(d, obj("site", "home"), "impact")?.rule === "core.rollup.site", "a roll-up its rollup record");
  const tr = derive([m, g], src([m, down()]), [rel("runs-on", g, m)], shippedModel(), now, { trace: true });
  const hops = tr.why!.path(m.id, "operational", g.id);
  check(hops.length === 1 && hops[0].rule === "core.propagate.runs-on.down" && hops[0].lost.length === 0, "traced: the path from the root, hop by hop, with its record");
  const ha = obj("vm", "h", { haNode: "x" });
  const trh = derive([m, ha], src([m, down()]), [rel("runs-on", ha, m)], shippedModel(), now, { trace: true });
  const hh = trh.why!.path(m.id, "operational", ha.id);
  check(hh[0]?.rule === "core.propagate.runs-on.down-ha" && hh[0].lost.some((l) => l.id === "core.propagate.runs-on.down" && l.why === "less-specific"), "…and the records that matched and lost, and why");
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
