// perf.test.ts — the performance reads (src/perf.ts, ADR-046 D7): the
// selectors and the catalogue's queries, the levels cascade, the cost, the
// investigations contract, the change markers, and the reads over the
// fixtures' synthetic store — the medium site at basic and the off variant.

import { mkdirSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { ExecResult } from "../../../lib/ts/src/exec";
import { CmdbHistory } from "../../src/cmdb";
import { capturedCmdb, repoAbove } from "../../src/fixtures";
import { HealthGraph, buildHealth } from "../../src/health";
import {
  MEASURED_SERIES, Perf, PerfDeps, RANGE, SIGNALS, SITE_WIDE, annotationsOf, costOf, environmentScope, moduleScope, parseInvestigations,
  judgedBy, perfCis, selectorOf, siteLevel, totalCost,
} from "../../src/perf";
import { fixtureFetch, fixturePromClient, loadFixtureMetrics, valueAt } from "../../src/perffixture";
import { hasVerb, sizeMB } from "../../src/perfwire";
import { grafanaTraces } from "../../src/jumps";
import { chartsShown, fmtValue, statusOf } from "../../web/src/perftypes";
import { performanceRoots } from "../../web/src/perfroots";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const NOW = Date.parse("2026-11-01T08:54:11Z");
const tmp = (): string => mkdtempSync(join(tmpdir(), "console-perf-"));
function copyTree(from: string, to: string): void {
  mkdirSync(to, { recursive: true });
  for (const f of readdirSync(from)) {
    if (statSync(join(from, f)).isDirectory()) copyTree(join(from, f), join(to, f));
    else writeFileSync(join(to, f), readFileSync(join(from, f)));
  }
}

function units(): void {
  check(selectorOf({ tappaas_ci_id: "a", pool: "tankc1" }) === 'pool="tankc1",tappaas_ci_id="a"', "a selector is in label order");
  check(selectorOf({ x: 'a"b\\c' }) === 'x="abc"', "a selector drops quotes and backslashes");
  for (const s of SIGNALS) {
    check(s.expr('tappaas_ci_id="X"').includes('tappaas_ci_id="X"') && s.expr(SITE_WIDE).includes(SITE_WIDE), `${s.key}: the selector is in its query`);
    check(s.by.every((l) => s.expr(SITE_WIDE).includes(l)), `${s.key}: a site-wide answer is keyed by ${s.by.join(", ")}`);
    if (s.trend) check(/trend5m:/.test(s.trend(SITE_WIDE)), `${s.key}: its trend reads the 5-minute rules`);
  }
  check(RANGE["24h"].trends === false && RANGE["90d"].trends === true, "24 h from the store, 90 days from the trends");

  // The cascade (D3).
  const dir = tmp();
  writeFileSync(join(dir, "site.json"), JSON.stringify({ name: "s" }));
  let s = siteLevel(dir);
  check(s.size === "medium" && s.level === "basic" && !s.levelSet && s.retentionDays === 15, "no level, medium: basic and 15 days, by its size");
  writeFileSync(join(dir, "site.json"), JSON.stringify({ name: "s", size: "small" }));
  s = siteLevel(dir);
  check(s.level === "off" && s.retentionDays === 7, "small: off and 7 days");
  writeFileSync(join(dir, "site.json"), JSON.stringify({ name: "s", size: "large", performance: { level: "trace", retentionDays: 40, resolution: "fine" } }));
  s = siteLevel(dir);
  check(s.level === "service" && s.levelSet && s.retentionDays === 40 && s.resolution === "fine", "trace is never standing: read as service; the retention and resolution as set");
  writeFileSync(join(dir, "site.json"), JSON.stringify({ name: "s", performance: { level: "basic" } }));
  s = siteLevel(dir);
  mkdirSync(join(dir, "environments"));
  writeFileSync(join(dir, "environments", "test.json"), JSON.stringify({ name: "test", performance: { level: "off" } }));
  const env = environmentScope(dir, "test", s);
  check(env.level === "off" && env.set && env.fromText === "set here", "an environment's own level");
  const plain = environmentScope(dir, "rossen", s);
  check(plain.level === "basic" && !plain.set && plain.fromText === "the site", "an environment without one follows the site");
  writeFileSync(join(dir, "nextcloud.json"), JSON.stringify({ performance: { level: "service" } }));
  check(moduleScope(dir, "nextcloud", plain, "rossen").level === "service", "a module's own level wins");
  const inherited = moduleScope(dir, "deconz", env, "test");
  check(inherited.level === "off" && !inherited.set && inherited.fromText === "environment test", "a module without one follows its environment, and says so");

  // The cost, against P1's measurement (3 nodes, 22 guests, PBS: ~1.9k series at basic).
  const p1 = costOf([...Array(3).fill("machine"), ...Array(22).fill("vm"), "datastore"], "basic", "normal", 15);
  check(p1.series > 1700 && p1.series < 2100, `P1's site at basic: ${p1.series} series, about 1.9k`);
  const fine = costOf(["vm"], "basic", "fine", 15);
  check(Math.abs(fine.diskMBPerDay / costOf(["vm"], "basic", "normal", 15).diskMBPerDay - 4) < 0.01, "fine: four times the samples");
  check(costOf(["vm"], "off", "normal", 15).series === 0, "off costs nothing");
  check(totalCost([p1], true).memoryMB - totalCost([p1], false).memoryMB === 300, "anything at trace adds Tempo");
  check(totalCost([], false).memoryMB === 0, "nothing collected, nothing paid");

  // The investigations contract.
  const inv = parseInvestigations({
    investigations: [
      { ci: { id: "a", class: "vm", name: "identity" }, level: "trace", resolution: "fine", from: "basic", by: "lars", started: "2026-11-01T07:40:00Z", until: "2026-11-01T10:40:00Z", ended: null },
      { ci: { id: "b", class: "vm", name: "old" }, level: "service", from: "basic", by: "lars", started: "2026-10-01T07:40:00Z", until: "2026-10-01T09:40:00Z", ended: null },
      { ci: { id: "c" }, level: "trace", until: "2026-11-02T00:00:00Z" },
      { ci: { id: "d", class: "vm", name: "x" }, level: "loud", by: "lars", started: "2026-11-01T07:40:00Z", until: "2026-11-02T00:00:00Z" },
    ],
    history: [{ ci: { id: "e", class: "vm", name: "y" }, level: "basic", from: "off", by: "lars", started: "2026-10-30T07:40:00Z", until: "2026-10-31T07:40:00Z", ended: "2026-10-30T09:00:00Z", endedHow: "stopped", endedBy: "lars" }],
  }, NOW);
  check(inv.active.length === 1 && inv.active[0].ci.name === "identity" && inv.active[0].resolution === "fine", "one in force");
  check(inv.history.length === 2 && inv.history[0].ci.name === "y" && inv.history[1].endedHow === "expired" && inv.history[1].ended === "2026-10-01T09:40:00Z", "one past its end is history, as ran out; newest first");
  check(parseInvestigations(null, NOW).active.length === 0, "no document: nothing");

  // Change markers (D4.2).
  const h: CmdbHistory = { id: "a", attributes: [], changes: [
    { id: 1, kind: "observation", source: "health-manager", job: null, verb: null, actor: null, time: "2026-11-01T01:00:00Z", drift: false },
    { id: 2, kind: "change", source: "cmdb-controller", job: null, verb: "sweep", actor: null, time: "2026-11-01T02:00:00Z", drift: false },
    { id: 3, kind: "change", source: "module-manager", job: "j", verb: "update identity", actor: "lars", time: "2026-11-01T03:00:00Z", drift: false },
    { id: 4, kind: "change", source: "module-manager", job: "j", verb: "update identity", actor: "lars", time: "2026-10-20T03:00:00Z", drift: false },
  ] };
  const marks = annotationsOf(h, NOW - RANGE["24h"].ms, NOW);
  check(marks.length === 1 && marks[0].label === "update identity" && marks[0].actor === "lars", "a marker: a write, not an observation or the sweep, within the range");

  check(statusOf(30, 25, 100) === "warning" && statusOf(120, 25, 100) === "critical" && statusOf(null, 1, 2) === "unknown", "a value against its lines");
  check(fmtValue(40.69, "ms") === "40.7 ms" && fmtValue(0.4, "%") === "0.4 %" && fmtValue(1257.6, "ms") === "1258 ms", "a value as the operator reads it");
  check(sizeMB("32G") === 32768 && sizeMB("2048") === 2048 && sizeMB(null) === null, "sizes in MB");
  check(!hasVerb(null, "health-manager", ["perf"]), "no manifests: no perf verb");
}

async function store(): Promise<void> {
  const m = loadFixtureMetrics(join(FIX, "perf", "metrics.json"));
  const pw = join(tmp(), "pw");
  writeFileSync(pw, "x\n");
  const prom = fixturePromClient(m, () => NOW, pw);
  const sig = SIGNALS.find((x) => x.key === "pool.write_wait")!;
  const all = await prom.instant(sig.expr(SITE_WIDE));
  check(all.length >= 4 && all.every((r) => r.metric.pool && r.metric.tappaas_ci_id), "a site-wide query: every pool, keyed by node and pool");
  const one = m.series.find((x) => x.signal === "pool.write_wait" && x.labels.pool === "tankc1")!;
  const r = await prom.range(sig.expr(selectorOf(one.labels)), NOW - RANGE["7d"].ms, NOW, RANGE["7d"].stepS, false);
  check(r.length === 1 && r[0].values.length === 337, "a CI's week: one series, a point every 30 minutes");
  const v = r[0].values.map(([, x]) => Number(x));
  check(Math.min(...v.slice(-60)) > Math.max(...v.slice(0, 60)) - 5, "tankc1 is slower since its step");
  check(valueAt(one, NOW, NOW) === valueAt(one, NOW, NOW), "the same moment, the same number");
  check((await prom.range(sig.trend!(selectorOf(one.labels)), NOW - RANGE["90d"].ms, NOW, RANGE["90d"].stepS, true)).length === 1, "the 90-day trend answers from /trends/");
  check((await prom.instant("up")).length === 0, "a query the console never builds: empty, as Prometheus");
  check(Number((await prom.instant(MEASURED_SERIES))[0].values[0][1]) === m.measuredSeries, "the series the store holds");
  const bad = fixtureFetch(m, () => NOW);
  check((await bad("https://x/nothing")).status === 404, "another path: 404");
}

const ok = (stdout: string): ExecResult => ({ rc: 0, stdout, stderr: "", ran: true });

async function reads(): Promise<void> {
  const site = capturedCmdb(FIX, repoAbove(FIX) ?? join(FIX, "..", "..", "..", "..", "..", ".."));
  const modules = (JSON.parse(readFileSync(join(FIX, "modules.json"), "utf8")) as { modules: { name: string; environment: string }[] }).modules;
  const g: HealthGraph = buildHealth({ objects: site.objects, relations: site.relations, classes: site.classes, relationTypes: site.relationTypes, modules: modules.map((x) => x.name), now: NOW });
  const routes = new Map(site.objects.filter((o) => o.class === "proxy-route").map((o) => [o.id, String(o.attributes.description ?? "")]));
  const history = (id: string): Promise<CmdbHistory | null> => {
    try {
      return Promise.resolve(JSON.parse(readFileSync(join(FIX, "cmdb", "history", `${id}.json`), "utf8")) as CmdbHistory);
    } catch {
      return Promise.resolve(null);
    }
  };
  const m = loadFixtureMetrics(join(FIX, "perf", "metrics.json"));
  const pw = join(tmp(), "pw");
  writeFileSync(pw, "x\n");
  const deps = (configDir: string, perfList: string | null): PerfDeps => ({
    configDir,
    run: async (bin, args) => (bin === "health-manager" && args.join(" ") === "perf list --json" && perfList !== null ? ok(perfList) : { rc: 1, stdout: "", stderr: "no", ran: true }),
    graph: async () => g,
    history,
    descriptions: async () => routes,
    modules: async () => modules,
    environments: async () => ["mgmt", "rossen", "test"],
    logging: async () => ({ memoryMB: 2048, diskGB: 32, installed: true }),
    hasVerb: () => perfList !== null,
    envLevelSettable: () => false,
    prom: fixturePromClient(m, () => NOW, pw),
    grafana: (cls, l) => `grafana:${cls}:${JSON.stringify(l)}`,
    traces: (ciId) => `traces:${ciId}`,
    now: () => NOW,
  });

  const cis = perfCis(g, routes);
  const tankc1 = cis.find((c) => c.name === "tankc1")!;
  check(tankc1.labels.pool === "tankc1" && tankc1.labels.tappaas_ci_id === "2df905fc-99ad-4ce9-8f70-e3989f9a308a", "a pool is selected by its node and its name");
  check(cis.find((c) => c.name === "cloud.hrossen.dk")?.module === "nextcloud", "a route's module, from its description");

  // The medium site at basic, nextcloud at service, identity traced.
  const perf = new Perf(deps(join(FIX, "config"), readFileSync(join(FIX, "reads", "health-manager-perf-list-json.out"), "utf8")));
  const o = await perf.loadOverview();
  check(o.level === "basic" && o.levelFrom === "site" && o.store === "on", "the overview: basic, set in the site's record, the store answering");
  check(o.roots.length === 2 && o.roots[0].label === "tankc1" && o.roots[0].impacted.map((x) => x.label).sort().join(",") === "Karakeep,Project N.O.M.A.D.", "the performance root causes, the one that slows most first, and what it slows");
  // Bug (hrossen 2026-11-11): Browse named coturn's root by its worst condition, its security score.
  const COTURN = "33394b2f-6716-4deb-aefd-76295bd61baa";
  // The health document as the console reads it: the CMDB's query leaves ended objects out.
  const healthRoots = buildHealth({ objects: site.objects.filter((x) => !(x as unknown as { ended?: unknown }).ended), relations: site.relations, classes: site.classes, relationTypes: site.relationTypes, modules: modules.map((x) => x.name), now: NOW }).roots;
  const healthRoot = healthRoots.find((r) => r.id === COTURN);
  check(healthRoot?.type === "security" && healthRoot.message === "score 14, medium: 3 high", "the fixture: coturn's health root names its security condition (the bug's input)");
  const browse = performanceRoots(o.roots, healthRoots);
  const cot = browse.find((r) => r.id === COTURN);
  check(browse.length === 2 && cot?.type === "performance" && cot.message === "coturn: CPU pressure (steal) 0.4 %, over 0.0 % for 2 min (coturn's threshold)" && cot.since === "2026-11-01T08:40:00.000Z", "Browse lists coturn by its performance condition: its line and since");
  check(browse[0].id === o.roots[0].id && browse.find((r) => r.label === "tankc1")?.impactedCount === 2, "in the overview's order, with what the performance root slows");
  check(o.saturated[0]?.ci.label === "tankc1" && o.saturated[0].status === "warning" && o.saturated[0].spark.length === 289, "the most saturated: tankc1's write latency, with its 24 hours");
  check(new Set(o.saturated.map((x) => x.ci.id)).size === o.saturated.length && o.saturated.length <= 8, "one row per object, eight at most");
  check(!o.saturated.some((x) => x.ci.label === "deconz-test"), "the test environment is off: nothing of it");
  check(o.services.map((x) => x.ci.label).sort().join(",") === "cloud.hrossen.dk,identity.hrossen.dk", "the services measured: nextcloud's and identity's routes");
  check(o.saturated.some((x) => x.lastChange?.label === "update litellm"), "a row's last change, from the CMDB");
  check(o.investigations === 1 && o.basicCost === null, "one investigation; no offer while it collects");

  const l = await perf.loadLevels();
  const row = (name: string) => l.rows.find((x) => x.name === name && x.scope === "module")!;
  check(l.rows[0].scope === "site" && l.rows[0].level === "basic" && l.rows[0].set, "the site's row first");
  check(row("nextcloud").level === "service" && row("nextcloud").set && row("nextcloud").cost.series > row("immich").cost.series, "nextcloud at service, set here, costs more");
  check(row("deconz-test").level === "off" && row("deconz-test").from === "environment test", "deconz-test follows its environment");
  check(l.measuredSeries === 2140 && l.retentionDays === 15 && l.total.memoryMB > 300, "measured, retention, and Tempo counted while identity traces");

  const id = "7fa7910d-f316-43b7-8660-7ec3e5a27831";
  const c = await perf.loadCi(id, "24h");
  check(c.level.level === "trace" && c.level.from === "investigation" && c.level.cascaded === "basic" && c.level.until === "2026-11-01T10:40:12Z", "identity: trace until its end, then basic");
  check(c.series.length === 6 && c.series.every((x) => x.points.length === 289), "a guest's six signals over 24 hours");
  check(c.series.some((x) => x.key === "vm.cpu_pressure" && x.label === "CPU pressure (steal)"), "CPU pressure (steal) is among a guest's signals");
  // Bug (hrossen 2026-11-11): coturn breached CPU pressure (its declared 0 %), and the panel's three charts left it out.
  const ct = await perf.loadCi(COTURN, "24h");
  const cp = ct.series.find((x) => x.key === "vm.cpu_pressure");
  check(cp?.judged === true && cp.status === "warning" && statusOf(cp.now, cp.warning, cp.critical) === "ok", "coturn's CPU pressure: under the default line, warning by its performance condition, and marked as the judged signal");
  const three = chartsShown(ct.series, 3);
  check(three[0]?.key === "vm.cpu_pressure" && three.length === 3, "the panel's three charts lead with the breached signal");
  check(chartsShown(ct.series).map((x) => x.key).join(",") === ct.series.filter((x) => x.points.length).map((x) => x.key).join(","), "without a max: every signal with numbers, in the catalogue's order");
  check(judgedBy({ judged: "pool_write_latency_seconds" }, { reason: "perf-pool-write-latency-seconds" }) && !judgedBy({ judged: "io_pressure_percent" }, { reason: "perf-cpu-pressure-percent" }) && !judgedBy({}, { reason: "perf-x" }), "a condition names its signal by its reason");
  check(c.annotations.some((a) => a.label.startsWith("perf identity --level trace")), "the raise itself is a marker");
  check(c.links.grafana === `grafana:vm:{"tappaas_ci_id":"${id}"}`, "the Grafana link: the class's dashboard at the CI");
  check(c.links.traces === `traces:${id}`, "identity at trace: its traces link (P6)");
  const k = await perf.loadCi("5f045500-92a5-4342-8cf3-0a4183e7e8e2", "7d");
  check(k.links.rootCause?.label === "tankc1", "karakeep: its root cause linked");
  check(k.links.traces === null, "karakeep is not at trace: no traces link");
  const d90 = await perf.loadCi(id, "90d");
  check(d90.series.find((x) => x.key === "vm.cpu")!.points.length === 361, "the 90-day trend");
  const route = await perf.loadCi("f2d2826e-5c9f-4d41-9234-9b8fb8af8811", "90d");
  check(route.series.every((x) => !x.points.length) && /trends/.test(route.note ?? ""), "a route has no trend yet, and says so");
  const disk = await perf.loadCi(site.objects.find((x) => x.class === "disk")!.id, "24h");
  check(disk.series.length === 0 && /Nothing is measured/.test(disk.note ?? ""), "a class without signals says so");

  const inv = await perf.loadInvestigations();
  check(inv.available && inv.active.length === 1 && inv.history.length === 2, "the investigations, from health-manager perf list");

  // The off site: small, no level, no investigation.
  const off = tmp();
  copyTree(join(FIX, "config"), off);
  copyTree(join(FIX, "variants", "off", "config"), off);
  writeFileSync(join(off, "environments", "test.json"), JSON.stringify({ name: "test" }));
  const p2 = new Perf(deps(off, readFileSync(join(FIX, "variants", "off", "reads", "health-manager-perf-list-json.out"), "utf8")));
  const o2 = await p2.loadOverview();
  check(o2.level === "off" && o2.levelFrom === "size" && o2.store === "off", "the off site: off, by its size, nothing asked of the store");
  check(o2.basicCost !== null && o2.basicCost.series > 1000 && o2.saturated.length === 0, `and what basic would cost: ${o2.basicCost?.series} series`);
  const c2 = await p2.loadCi(id, "24h");
  check(c2.series.length === 0 && /level is off/.test(c2.note ?? ""), "a CI on the off site: no numbers, and why");
  const noVerb = new Perf(deps(off, null));
  const i3 = await noVerb.loadInvestigations();
  check(!i3.available && i3.active.length === 0, "no perf verb: not available, nothing in force");
  const noStore = new Perf({ ...deps(join(FIX, "config"), null), prom: null });
  check((await noStore.loadOverview()).store === "unreachable", "collecting but no store here: unreachable");
}

// The traces jump (P6): Grafana's Explore on Tempo, a TraceQL search by the CI.
function tracesJump(): void {
  const ctx = { topology: null, modules: [{ name: "logging", environment: "mgmt" }], environments: [{ name: "mgmt", domains: { primary: "hrossen.dk" } }], mgmtDomain: "mgmt.internal", pbsStore: "" };
  const u = grafanaTraces(ctx as never, "7fa7910d-f316-43b7-8660-7ec3e5a27831");
  const panes = u ? JSON.parse(decodeURIComponent(u.split("panes=")[1])) : null;
  check(!!u && u.startsWith("https://logging.hrossen.dk/explore?") && panes?.t?.datasource === "tempo", `the traces link opens Explore on Tempo (${u})`);
  check(panes?.t?.queries?.[0]?.query === '{ resource.tappaas.ci.id = "7fa7910d-f316-43b7-8660-7ec3e5a27831" }', "searching the CI's spans by its id");
  check(grafanaTraces(ctx as never, "not-an-id") === null, "no link for something that is not a CI id");
}

void (async () => {
  units();
  tracesJump();
  await store();
  await reads();
  done("perf");
})();
