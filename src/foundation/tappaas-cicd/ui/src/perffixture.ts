// perffixture.ts — the metrics store with no logging VM (fixture mode, the
// unit tests). A fake `fetch` that answers Prometheus's query API for exactly
// the queries perf.ts builds from its catalogue, from a small description of
// each series (<fixtures>/perf/metrics.json): a base, a daily swing, noise and
// steps at given hours ago, all relative to the clock, so CONSOLE_NOW's
// capture always has 90 days behind it. Any other query answers empty, as
// Prometheus does for a series it does not hold.

import { readFileSync } from "fs";
import { Labels, MEASURED_SERIES, MetricsConfig, PromClient, SIGNALS, SITE_WIDE, promClient, selectorOf } from "./perf";

export interface FixtureSeries {
  signal: string; // a catalogue key: "vm.io_pressure"
  labels: Labels; // its selector: tappaas_ci_id (and pool for a pool)
  base: number;
  daily?: number; // the swing over a day, peaking mid-afternoon
  noise?: number;
  steps?: { hoursAgo: number; add: number }[]; // from then on, add
  min?: number;
  max?: number;
}

export interface FixtureMetrics {
  measuredSeries?: number;
  series: FixtureSeries[];
}

export function loadFixtureMetrics(file: string): FixtureMetrics {
  return JSON.parse(readFileSync(file, "utf8")) as FixtureMetrics;
}

// A number in [0, 1) from a string: the same noise for the same moment.
function hash01(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return ((h >>> 0) % 100000) / 100000;
}

export function valueAt(f: FixtureSeries, tMs: number, nowMs: number): number {
  const day = 86400_000;
  const phase = ((tMs % day) / day) * 2 * Math.PI;
  let v = f.base + (f.daily ?? 0) * Math.sin(phase - Math.PI / 2 - 0.6) + (f.noise ?? 0) * (hash01(`${f.signal}|${selectorOf(f.labels)}|${Math.floor(tMs / 300_000)}`) - 0.5) * 2;
  for (const s of f.steps ?? []) if (tMs >= nowMs - s.hoursAgo * 3600_000) v += s.add;
  return Math.min(f.max ?? Infinity, Math.max(f.min ?? 0, v));
}

interface Lookup {
  series: FixtureSeries[];
  key: string[]; // the labels a site-wide answer carries
}

// expr → the series it selects, for every query the console can build.
function lookups(m: FixtureMetrics): Map<string, Lookup> {
  const out = new Map<string, Lookup>();
  const add = (expr: string, s: FixtureSeries, key: string[]): void => {
    const l = out.get(expr) ?? { series: [], key };
    l.series.push(s);
    out.set(expr, l);
  };
  for (const f of m.series) {
    const sig = SIGNALS.find((s) => s.key === f.signal);
    if (!sig) throw new Error(`perf fixture: no signal ${f.signal}`);
    const sel = selectorOf(f.labels);
    add(sig.expr(sel), f, sig.by);
    add(sig.expr(SITE_WIDE), f, sig.by);
    if (sig.trend) {
      add(`trend:${sig.trend(sel)}`, f, sig.by);
      add(`trend:${sig.trend(SITE_WIDE)}`, f, sig.by);
    }
  }
  return out;
}

export function fixtureFetch(m: FixtureMetrics, now: () => number): typeof fetch {
  const table = lookups(m);
  const reply = (status: number, body: unknown): FetchResponse => {
    const text = typeof body === "string" ? body : JSON.stringify(body);
    return { ok: status < 400, status, text: async () => text, json: async () => JSON.parse(text) as unknown, body: null };
  };
  const answer = (result: unknown[], type: string): FetchResponse => reply(200, { status: "success", data: { resultType: type, result } });
  const fake = async (input: string): Promise<FetchResponse> => {
    const u = new URL(input);
    const q = u.searchParams.get("query") ?? "";
    const trends = u.pathname.startsWith("/trends/");
    const t = now();
    if (u.pathname.endsWith("/api/v1/query")) {
      if (q === MEASURED_SERIES) return answer([{ metric: {}, value: [t / 1000, String(m.measuredSeries ?? 0)] }], "vector");
      const l = table.get(q);
      return answer((l?.series ?? []).map((f) => ({ metric: Object.fromEntries(l!.key.map((k) => [k, f.labels[k] ?? ""])), value: [t / 1000, String(valueAt(f, t, t))] })), "vector");
    }
    if (u.pathname.endsWith("/api/v1/query_range")) {
      const l = table.get(trends ? `trend:${q}` : q);
      const start = Number(u.searchParams.get("start")) * 1000;
      const end = Number(u.searchParams.get("end")) * 1000;
      const step = parseInt(u.searchParams.get("step") ?? "300", 10) * 1000;
      const res = (l?.series ?? []).map((f) => {
        const values: [number, string][] = [];
        for (let x = start; x <= end; x += step) values.push([x / 1000, String(valueAt(f, x, t))]);
        return { metric: Object.fromEntries(l!.key.map((k) => [k, f.labels[k] ?? ""])), values };
      });
      return answer(res, "matrix");
    }
    return reply(404, "not found");
  };
  return fake as unknown as typeof fetch;
}

// The store over the fixture: the client is perf.ts's own, so a fixture run
// exercises the queries and the parsing the live console uses.
export function fixturePromClient(m: FixtureMetrics, now: () => number, passwordFile: string): PromClient {
  const cfg: MetricsConfig = { url: "https://logging.mgmt.internal:3121", user: "tappaas", passwordFile };
  return promClient(cfg, fixtureFetch(m, now));
}
