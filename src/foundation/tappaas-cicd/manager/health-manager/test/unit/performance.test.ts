// performance.test.ts — ADR-046 D6 in assess: the `performance` condition from
// the metrics store (static thresholds held for their window, declared ones
// over the defaults, a missing metric unknown, a store that does not answer
// leaving what stood), the trend capacity, the shipped correlation rules (a
// slow pool degrades what is stored on it), the digest-only mail, and the
// signal table the alert renderer carries equal to perf-signals.ts.

import { spawnSync } from "child_process";
import { readFileSync } from "fs";
import { join } from "path";
import { AssessResult, assess } from "../../src/assess";
import { Declared, fromPerformance, fromTrends, horizonOf, reasonOf, thresholdsFor } from "../../src/assess-performance";
import { CmdbItem, Condition, SiteIndex } from "../../src/assess-model";
import { MetricsReader, Sample, curlReader, parseVector } from "../../src/metrics-read";
import { checkHealthRules } from "../../../../lib/ts/src/health-rules";
import { PERF_SIGNALS, signalNamed } from "../../../../lib/ts/src/perf-signals";
import { NOW, StubIO, cond, obj, rel, shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const got = (r: AssessResult, o: CmdbItem, type: string): Condition | undefined => r.objects.find((x) => x.id === o.id)?.conditions.find((c) => c.type === type);

// A fake store: per query fragment, the samples it answers; null for "down".
class FakeStore implements MetricsReader {
  down = false;
  asked: string[] = [];
  constructor(public answers: { has: string; samples: Sample[] }[] = []) {}
  instant(expr: string, trends = false): Sample[] | null {
    this.asked.push(`${trends ? "trends:" : ""}${expr}`);
    if (this.down) return null;
    return this.answers.filter((a) => expr.includes(a.has)).flatMap((a) => a.samples);
  }
}
const s = (labels: Record<string, string>, value: number): Sample => ({ metric: labels, value });

const site = obj("site", "home");
const m1 = obj("machine", "tappaas3");
const pool = obj("storage-pool", "tankc1", { zfsState: "ONLINE" });
const kk = obj("vm", "karakeep");
const nm = obj("vm", "nomad");
const id = obj("vm", "identity");
const route = obj("proxy-route", "identity.hrossen.dk", { description: "TAPPaaS: identity", host: "identity.hrossen.dk" });
const base = (): { items: CmdbItem[]; rels: ReturnType<typeof rel>[] } => ({
  items: [site, m1, pool, kk, nm, id, route].map((o) => ({ ...o, attributes: { ...o.attributes } })),
  rels: [rel("runs-on", pool, m1), rel("runs-on", kk, m1), rel("runs-on", nm, m1), rel("runs-on", id, m1), rel("stored-on", kk, pool), rel("stored-on", nm, pool)],
});
const writeWait = (min: number, max: number): { has: string; samples: Sample[] }[] => [
  { has: "min_over_time((max by (tappaas_ci_id, pool) (tappaas_zpool_write_wait", samples: [s({ tappaas_ci_id: m1.id, pool: "tankc1" }, min)] },
  { has: "max_over_time((max by (tappaas_ci_id, pool) (tappaas_zpool_write_wait", samples: [s({ tappaas_ci_id: m1.id, pool: "tankc1" }, max)] },
];

// ── thresholds ──
{
  const d = thresholdsFor("storage-pool", null, []);
  check(d.length === 1 && d[0].signal.name === "pool_write_latency_seconds" && d[0].warning === 0.025 && d[0].forS === 900, "a pool's default: write latency, 25 ms, 15 minutes");
  const declared: Declared[] = [{ module: "identity", thresholds: [{ signal: "http_p95_seconds", warning: 0.5, for: "5m" }, { signal: "io_pressure_percent", critical: 30 }, { signal: "made_up", warning: 1 }] }];
  const r = thresholdsFor("proxy-route", "identity", declared);
  const p95 = r.find((t) => t.signal.name === "http_p95_seconds")!;
  check(p95.warning === 0.5 && p95.critical === 5 && p95.forS === 300 && p95.declared === "identity", "a declared threshold over the default, the rest kept");
  check(thresholdsFor("proxy-route", "other", declared).find((t) => t.signal.name === "http_p95_seconds")!.warning === 1.5, "another module's declaration does not apply");
  check(thresholdsFor("vm", "identity", declared).find((t) => t.signal.name === "io_pressure_percent")!.critical === 30, "on its guest too");
  check(!r.some((t) => t.signal.name === "made_up"), "an unknown signal is left out");
  check(thresholdsFor("disk", null, []).length === 0, "a class without signals: nothing judged");
}

// ── held for the window: entered and left ──
{
  const idx = (items: CmdbItem[], rels: ReturnType<typeof rel>[]) => new SiteIndex(items, rels);
  const b = base();
  let f = fromPerformance(idx(b.items, b.rels), new FakeStore(writeWait(0.038, 0.06)), [], new Set());
  const onPool = f.findings.filter((x) => x.object === pool.id);
  check(f.looked && onPool.length === 1 && onPool[0].status === "warning" && onPool[0].reason === "perf-pool-write-latency-seconds", "over 25 ms the whole window: a warning");
  check(/tankc1: write latency 38 ms, over 25 ms for 15 min/.test(onPool[0].message), `the message says it (${onPool[0].message})`);
  f = fromPerformance(idx(b.items, b.rels), new FakeStore(writeWait(0.01, 0.2)), [], new Set());
  check(f.findings.find((x) => x.object === pool.id)!.status === "ok", "a spike, not held: still ok");
  const was = base();
  was.items.find((o) => o.id === pool.id)!.attributes.conditions = [cond("performance", "warning", "perf-pool-write-latency-seconds")];
  f = fromPerformance(idx(was.items, was.rels), new FakeStore(writeWait(0.01, 0.03)), [], new Set());
  check(f.findings.find((x) => x.object === pool.id)!.status === "warning", "once a warning, one quiet minute does not end it");
  f = fromPerformance(idx(was.items, was.rels), new FakeStore(writeWait(0.005, 0.02)), [], new Set());
  check(f.findings.find((x) => x.object === pool.id)!.status === "ok", "under it the whole window: over");
  f = fromPerformance(idx(was.items, was.rels), new FakeStore(writeWait(0.12, 0.3)), [], new Set());
  check(f.findings.find((x) => x.object === pool.id)!.status === "critical", "held over 100 ms: critical");
  // A metric gone: unknown, never critical.
  f = fromPerformance(idx(was.items, was.rels), new FakeStore([]), [], new Set());
  const gone = f.findings.find((x) => x.object === pool.id)!;
  check(gone.status === "unknown" && gone.reason === "perf-no-numbers", "measured before, no numbers now: unknown");
  check(!fromPerformance(idx(b.items, b.rels), new FakeStore([]), [], new Set()).findings.some((x) => x.object === pool.id), "never measured: no condition");
  const down = new FakeStore(writeWait(0.5, 0.5));
  down.down = true;
  const fd = fromPerformance(idx(b.items, b.rels), down, [], new Set());
  check(!fd.looked && fd.findings.length === 0, "the store down: nothing judged, nothing looked");
  // A route, by its module's declared threshold.
  const st = new FakeStore([
    { has: "min_over_time((histogram_quantile", samples: [s({ tappaas_ci_id: route.id }, 0.8)] },
    { has: "max_over_time((histogram_quantile", samples: [s({ tappaas_ci_id: route.id }, 0.9)] },
  ]);
  f = fromPerformance(idx(b.items, b.rels), st, [{ module: "identity", thresholds: [{ signal: "http_p95_seconds", warning: 0.5, for: "5m" }] }], new Set(["identity"]));
  const r = f.findings.find((x) => x.object === route.id)!;
  check(r.status === "warning" && /\(identity's threshold\)/.test(r.message), `a route over its module's declared p95 (${r.message})`);
  check(st.asked.some((q) => q.includes("[300s:1m]")), "its declared window in the query");
}

// ── through assess: a slow pool degrades what is stored on it ──
{
  const b = base();
  const io = new StubIO(b.items, b.rels);
  const store = new FakeStore(writeWait(0.04, 0.05));
  io.metrics = () => store;
  const r = assess(io, {}, NOW, []);
  const p = got(r, pool, "performance")!;
  check(p.status === "warning" && !p.derived, "the pool: a performance warning of its own");
  check(got(r, kk, "impact")?.status === "warning" && got(r, kk, "impact")?.rootCause === pool.id, "its guests: a warning impact naming the pool (stored-on)");
  check(r.rootCauses.some((x) => x.id === pool.id && x.type === "performance"), "the pool is a performance root cause");
  check(r.transitions.some((t) => t.id === pool.id && t.type === "performance" && t.to === "warning"), "a transition to tell");
  // The store down next time: the warning stands (not looked).
  store.down = true;
  const r2 = assess(io, {}, new Date(NOW.getTime() + 300_000), []);
  check(got(r2, pool, "performance")?.status === "warning", "the store down: the warning stands");
  // Recovered.
  store.down = false;
  store.answers = writeWait(0.004, 0.01);
  const r3 = assess(io, {}, new Date(NOW.getTime() + 600_000), []);
  check(got(r3, pool, "performance")?.status === "ok" && got(r3, kk, "impact")?.status === "ok", "under it again: the pool and the impact are over");
}

// ── a node under pressure degrades its guests (runs-on) ──
{
  const b = base();
  const io = new StubIO(b.items, b.rels);
  io.metrics = () => new FakeStore([
    { has: 'min_over_time((max by (tappaas_ci_id) (tappaas_node_psi_some_avg60{tappaas_ci_id!="", resource="memory"', samples: [s({ tappaas_ci_id: m1.id }, 30)] },
    { has: 'max_over_time((max by (tappaas_ci_id) (tappaas_node_psi_some_avg60{tappaas_ci_id!="", resource="memory"', samples: [s({ tappaas_ci_id: m1.id }, 40)] },
  ]);
  const r = assess(io, {}, NOW, []);
  check(got(r, m1, "performance")?.status === "critical", "the node: critical memory pressure");
  check(got(r, id, "impact")?.status === "warning", "its guests: a warning impact, not critical (runs-on)");
}

// ── trend capacity ──
{
  const b = base();
  const ds = obj("datastore", "tappaas_backup");
  const idx = new SiteIndex([...b.items, ds], b.rels);
  const st = new FakeStore([
    { has: "trend5m:proxmox_storage_total", samples: [s({ tappaas_ci_id: m1.id, storage: "tankc1" }, 9.4)] },
    { has: "pbs_datastore_avail", samples: [s({ tappaas_ci_id: "x", id: "tappaas_backup" }, 40)] },
    { has: "trend5m:proxmox_node_memory_memtotal", samples: [s({ tappaas_ci_id: m1.id }, 3)] },
  ]);
  const t = fromTrends(idx, st, 14);
  const on = (o: CmdbItem) => t.findings.find((x) => x.object === o.id);
  check(on(pool)?.status === "warning" && on(pool)?.reason === "capacity-trend" && /full in 9 day/.test(on(pool)!.message), `a pool full in 9 days, within 14: a warning (${on(pool)?.message})`);
  check(on(ds)?.status === "ok", "a datastore full in 40 days: ok");
  check(on(m1)?.status === "warning" && /its memory is full in 3 day/.test(on(m1)!.message), "a node's memory full in 3 days: a warning");
  check(st.asked.some((q) => q.startsWith("trends:") && q.includes("deriv(")), "pools and memory from the trends instance, by their slope");
  check(fromTrends(idx, st, 5).findings.find((x) => x.object === pool.id)?.status === "ok", "a shorter horizon: ok");
  const dn = new FakeStore();
  dn.down = true;
  check(!fromTrends(idx, dn, 14).looked, "the store down: not looked");
  check(horizonOf({ performance: { capacityHorizonDays: 30 } }) === 30 && horizonOf(null) === 14 && horizonOf({ performance: { capacityHorizonDays: -1 } }) === 14, "the horizon: the site's, else 14");
}

// ── the shipped rules hold, and carry performance ──
{
  const m = shippedModel();
  const relNames = m.relations.map((r) => r.name);
  const deps = m.relations.filter((r) => r.dependant).map((r) => r.name);
  check(checkHealthRules({ rules: m.rules }, { relations: relNames, dependants: deps, classes: Object.keys(m.ancestors) }).length === 0, "rules check passes with the performance rules");
  const perf = m.rules.filter((r) => r.source.type === "performance");
  check(perf.some((r) => r.relation === "stored-on" && r.to === "storage-pool" && r.source.status === "warning" && r.impact === "warning"), "a slow pool crosses stored-on as a warning");
  check(perf.some((r) => r.relation === "runs-on" && r.to === "machine" && r.source.status === "warning" && r.impact === "warning"), "a pressured node crosses runs-on as a warning");
  check(perf.every((r) => r.impact === "warning"), "performance never impacts as critical");
}

// ── the store's answer, and the credential never in argv ──
{
  check(parseVector('{"status":"success","data":{"resultType":"vector","result":[{"metric":{"a":"b"},"value":[1,"2.5"]}]}}')?.[0].value === 2.5, "a vector parsed");
  check(parseVector('{"status":"error"}') === null && parseVector("not json") === null, "an error or garbage: null");
  let seen: { args: string[]; input: string } = { args: [], input: "" };
  const r = curlReader({ url: "https://logging.mgmt.internal:3121", user: "tappaas", passwordFile: join(__dirname, "performance.test.js") }, (args, input) => { seen = { args, input }; return { rc: 0, stdout: '{"status":"success","data":{"result":[]}}' }; });
  r.instant("up", true);
  check(seen.args.at(-1) === "https://logging.mgmt.internal:3121/trends/api/v1/query", "the trends instance under /trends/");
  check(!seen.args.join(" ").includes("tappaas:") && seen.input.startsWith('user = "tappaas:'), "the credential on stdin, never in argv");
  check(reasonOf(signalNamed("http_5xx_ratio")!) === "perf-http-5xx-ratio", "a reason names its signal");
}

// ── the renderer's table equals perf-signals.ts ──
{
  const py = join(__dirname, "../../../../../../../scripts/tappaas-alert-rules.py");
  const out = spawnSync("python3", ["-I", "-c", "import importlib.util,json,sys; s=importlib.util.spec_from_file_location('ar', sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(json.dumps({k: v[1] for k, v in m.SIGNALS.items()}))", py], { encoding: "utf8" });
  if (out.status !== 0) check(false, `the renderer's table could not be read: ${out.stderr}`);
  else {
    const table = JSON.parse(String(out.stdout)) as Record<string, string>;
    check(Object.keys(table).sort().join() === PERF_SIGNALS.map((x) => x.name).sort().join(), "the same signal names");
    check(PERF_SIGNALS.every((x) => table[x.name] === x.expr), "the same expressions");
  }
}

// ── mailed in the digest only: the shipped rules' matches over event lines ──
{
  const rules = (JSON.parse(readFileSync(join(__dirname, "../../../../../../../tappaas-cicd-alerts.json"), "utf8")) as { rules: { name: string; match: string }[] }).rules;
  const m = (name: string): RegExp => new RegExp(rules.find((r) => r.name === name)!.match);
  const line = (type: string, from: string, to: string, kind: string, root: boolean, extra: Record<string, unknown> = {}): string =>
    JSON.stringify({ event: "transition", id: "x", ci: "c", class: "storage-pool", name: "tankc1", type, from, to, reason: "r", message: "m", kind, rootCause: null, correlated: [], since: "t", at: "t", flapping: false, root, symptoms: 2, impacted: "2 vm", silenced: false, ...extra });
  const perfCrit = line("performance", "ok", "critical", "causal", true, { digestOnly: true });
  const opCrit = line("operational", "ok", "critical", "causal", true);
  check(m("health-root-cause").test(opCrit) && !m("health-root-cause").test(perfCrit), "a critical performance root is not mailed at once");
  check(m("health-daily-digest").test(perfCrit), "…it is in the daily digest");
  check(m("health-daily-digest").test(line("performance", "ok", "warning", "causal", true, { digestOnly: true })), "a warning performance root: the digest too");
  check(!m("health-root-recovered").test(line("performance", "critical", "ok", "recovery", true, { digestOnly: true })) && m("health-root-recovered").test(line("operational", "critical", "ok", "recovery", true)), "its recovery is not mailed either");
  check(!m("health-daily-digest").test(line("performance", "ok", "warning", "symptom", false, { digestOnly: true })) && !m("health-root-cause").test(line("impact", "ok", "critical", "symptom", false)), "a symptom is never mailed");
}

console.log(`\nperformance: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
