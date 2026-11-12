// perf.ts — the console's performance reads (ADR-046 D7): the Overview, a CI's
// numbers over a range, the levels cascade and the investigations. The metrics
// store (logging:metrics, Prometheus on the logging VM, tcp/3121 with the
// mothership's admin credential) is asked from here only, never from the
// browser, and only with the queries this file builds from its signal
// catalogue: no PromQL comes in from a request. The levels come from the
// records (site.json, config/environments/<env>.json, config/<module>.json:
// `performance.level` / `performance.resolution`, D3); the timed raises from
// `health-manager perf list --json`; the change markers from the CMDB's
// change history of the CI (D4.2). The contracts for the verbs and the field
// P2 and P4 build are in ui/README.md, "Performance".

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { Cached, CachedMap, Entry } from "./cache";
import { CmdbHistory } from "./cmdb";
import { HealthGraph, HealthNode } from "./health";
import { Runner } from "./run";
import {
  PerfAnnotation, PerfCi, PerfCost, PerfEffective, PerfInvestigation, PerfInvestigations, PerfLevel, PerfLevelRow, PerfLevels,
  PerfOverview, PerfPoint, PerfRange, PerfResolution, PerfRoot, PerfSeries, PerfStatus, PerfTop, RANGES, levelRank, statusOf,
} from "../web/src/perftypes";

// ── the signal catalogue (D2) ─────────────────────────────────────────

// A label selector, rendered in a fixed order so a query is one string for one
// CI (the fixture store looks queries up by it).
export type Labels = Record<string, string>;
export const SITE_WIDE = 'tappaas_ci_id!=""';
const RANK_STATUS: Record<PerfStatus, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

/** The signal a performance condition names: its reason is perf-<health-manager signal>, dashes for underscores. */
export function judgedBy(s: Pick<Signal, "judged">, issue: { reason: string | null } | undefined): boolean {
  return !!s.judged && !!issue?.reason && issue.reason === `perf-${s.judged.replace(/_/g, "-")}`;
}

export function selectorOf(l: Labels): string {
  return Object.keys(l).sort().map((k) => `${k}="${l[k].replace(/["\\]/g, "")}"`).join(",");
}

export interface Signal {
  key: string;
  classes: string[];
  label: string;
  unit: string;
  lens: "use" | "red";
  level: PerfLevel; // the lowest level that collects it
  by: string[]; // the labels a site-wide answer is keyed by
  expr: (sel: string) => string;
  trend: ((sel: string) => string) | null; // on the 90-day instance; null: no trend rule for it
  warning: number | null;
  critical: number | null;
  saturation: boolean; // ranks in the Overview's USE list
  judged?: string; // the health-manager signal (perf-signals.ts) its performance condition names
}

const BY_CI = ["tappaas_ci_id"];
const BY_POOL = ["tappaas_ci_id", "pool"];
const gauge = (m: string, f: string, by = "tappaas_ci_id", extra = "", scale = ""): Pick<Signal, "expr" | "trend"> => ({
  expr: (s) => `${f} by (${by}) (${m}{${s}${extra}})${scale}`,
  trend: (s) => `${f} by (${by}) (trend5m:${m}:avg{${s}${extra}})${scale}`,
});

export const SIGNALS: Signal[] = [
  { key: "node.cpu", classes: ["machine"], label: "CPU used", unit: "%", lens: "use", level: "basic", by: BY_CI, ...gauge("proxmox_node_cpustat_cpu", "avg", "tappaas_ci_id", "", " * 100"), warning: 85, critical: 95, saturation: true },
  { key: "node.memory", classes: ["machine"], label: "Memory used", unit: "%", lens: "use", level: "basic", by: BY_CI,
    expr: (s) => `sum by (tappaas_ci_id) (proxmox_node_memory_memused{${s}}) / sum by (tappaas_ci_id) (proxmox_node_memory_memtotal{${s}}) * 100`,
    trend: (s) => `sum by (tappaas_ci_id) (trend5m:proxmox_node_memory_memused:avg{${s}}) / sum by (tappaas_ci_id) (trend5m:proxmox_node_memory_memtotal:avg{${s}}) * 100`,
    warning: 90, critical: 97, saturation: true },
  { key: "node.mem_pressure", classes: ["machine"], label: "Memory pressure", unit: "%", lens: "use", level: "basic", by: BY_CI, ...gauge("tappaas_node_psi_some_avg60", "max", "tappaas_ci_id", ',resource="memory"'), warning: 10, critical: 25, saturation: true, judged: "node_memory_pressure_percent" },
  { key: "node.io_pressure", classes: ["machine"], label: "I/O pressure", unit: "%", lens: "use", level: "basic", by: BY_CI, ...gauge("tappaas_node_psi_some_avg60", "max", "tappaas_ci_id", ',resource="io"'), warning: 20, critical: 40, saturation: true, judged: "node_io_pressure_percent" },
  { key: "vm.cpu", classes: ["vm", "lxc"], label: "CPU used, of its cores", unit: "%", lens: "use", level: "basic", by: BY_CI, ...gauge("proxmox_vm_cpu", "avg", "tappaas_ci_id", "", " * 100"), warning: 90, critical: 98, saturation: true },
  { key: "vm.cpu_pressure", classes: ["vm", "lxc"], label: "CPU pressure (steal)", unit: "%", lens: "use", level: "basic", by: BY_CI, ...gauge("proxmox_vm_pressurecpusome", "max"), warning: 20, critical: 50, saturation: true, judged: "cpu_pressure_percent" },
  { key: "vm.memory", classes: ["vm", "lxc"], label: "Memory working set", unit: "%", lens: "use", level: "basic", by: BY_CI,
    expr: (s) => `sum by (tappaas_ci_id) (tappaas_guest_memory_used_bytes{${s}}) / sum by (tappaas_ci_id) (proxmox_vm_maxmem{${s}}) * 100`,
    trend: (s) => `sum by (tappaas_ci_id) (trend5m:tappaas_guest_memory_used_bytes:avg{${s}}) / sum by (tappaas_ci_id) (trend5m:proxmox_vm_maxmem:avg{${s}}) * 100`,
    warning: 90, critical: 97, saturation: true },
  { key: "vm.mem_pressure", classes: ["vm", "lxc"], label: "Memory pressure", unit: "%", lens: "use", level: "basic", by: BY_CI, ...gauge("proxmox_vm_pressurememorysome", "max"), warning: 10, critical: 25, saturation: true, judged: "memory_pressure_percent" },
  { key: "vm.io_pressure", classes: ["vm", "lxc"], label: "I/O pressure", unit: "%", lens: "use", level: "basic", by: BY_CI, ...gauge("proxmox_vm_pressureiosome", "max"), warning: 20, critical: 40, saturation: true, judged: "io_pressure_percent" },
  { key: "vm.disk_write", classes: ["vm", "lxc"], label: "Disk writes", unit: "MB/s", lens: "use", level: "basic", by: BY_CI,
    expr: (s) => `sum by (tappaas_ci_id) (rate(proxmox_vm_diskwrite_total{${s}}[5m])) / 1e6`,
    trend: (s) => `sum by (tappaas_ci_id) (trend5m:proxmox_vm_diskwrite_total:rate{${s}}) / 1e6`,
    warning: null, critical: null, saturation: false },
  // A pool's numbers come from its node's sampler: the node's identity and the pool's name.
  { key: "pool.write_wait", classes: ["storage-pool"], label: "Write latency", unit: "ms", lens: "use", level: "basic", by: BY_POOL, ...gauge("tappaas_zpool_write_wait_seconds", "max", "tappaas_ci_id, pool", "", " * 1000"), warning: 25, critical: 100, saturation: true, judged: "pool_write_latency_seconds" },
  { key: "pool.read_wait", classes: ["storage-pool"], label: "Read latency", unit: "ms", lens: "use", level: "basic", by: BY_POOL, ...gauge("tappaas_zpool_read_wait_seconds", "max", "tappaas_ci_id, pool", "", " * 1000"), warning: 25, critical: 100, saturation: true, judged: "pool_read_latency_seconds" },
  // A published service, the user's view: Caddy's per-host numbers, stamped with the route's CI (P3).
  { key: "svc.p95", classes: ["proxy-route"], label: "Response time (p95)", unit: "ms", lens: "red", level: "service", by: BY_CI,
    expr: (s) => `histogram_quantile(0.95, sum by (tappaas_ci_id, le) (rate(caddy_http_request_duration_seconds_bucket{${s}}[5m]))) * 1000`,
    trend: null, warning: 1500, critical: 5000, saturation: true, judged: "http_p95_seconds" },
  { key: "svc.errors", classes: ["proxy-route"], label: "Errors (5xx)", unit: "%", lens: "red", level: "service", by: BY_CI,
    expr: (s) => `sum by (tappaas_ci_id) (rate(caddy_http_request_duration_seconds_count{${s},code=~"5.."}[5m])) / sum by (tappaas_ci_id) (rate(caddy_http_request_duration_seconds_count{${s}}[5m])) * 100`,
    trend: null, warning: 1, critical: 5, saturation: true, judged: "http_5xx_ratio" },
  // The same service probed from inside the site, once a minute (black-box, P3).
  { key: "svc.probe", classes: ["proxy-route"], label: "Response time (probe)", unit: "ms", lens: "red", level: "service", by: BY_CI,
    expr: (s) => `max by (tappaas_ci_id) (probe_duration_seconds{${s}}) * 1000`, trend: null, warning: 2000, critical: 8000, saturation: false, judged: "probe_seconds" },
  { key: "svc.up", classes: ["proxy-route"], label: "Probe down", unit: "%", lens: "red", level: "service", by: BY_CI,
    expr: (s) => `(1 - avg by (tappaas_ci_id) (avg_over_time(probe_success{${s}}[15m]))) * 100`, trend: null, warning: 5, critical: 50, saturation: true },
  { key: "svc.rate", classes: ["proxy-route"], label: "Requests", unit: "req/s", lens: "red", level: "service", by: BY_CI,
    expr: (s) => `sum by (tappaas_ci_id) (rate(caddy_http_request_duration_seconds_count{${s}}[5m]))`,
    trend: null, warning: null, critical: null, saturation: false },
];

export const MEASURED_SERIES = 'count({__name__=~".+"})';

export const signalsFor = (cls: string): Signal[] => SIGNALS.filter((s) => s.classes.includes(cls));
export const PERF_CLASSES = [...new Set(SIGNALS.flatMap((s) => s.classes))];

// ── the store ─────────────────────────────────────────────────────────

export interface PromResult {
  metric: Labels;
  values: [number, string][]; // seconds, value; one pair for an instant query
}

export interface PromClient {
  instant(expr: string): Promise<PromResult[]>;
  range(expr: string, startMs: number, endMs: number, stepS: number, trends: boolean): Promise<PromResult[]>;
}

export interface MetricsConfig {
  url: string; // https://logging.mgmt.internal:3121; /trends/ is the 90-day instance
  user: string;
  passwordFile: string;
}

// The store, when logging is installed here and the admin credential is
// readable: the same credential as Loki's (lib/metrics-shipping.sh
// metrics_curl_admin), over TLS from the site's CA.
export function metricsConfig(configDir: string, home: string, env: Record<string, string | undefined> = process.env): MetricsConfig | null {
  const passwordFile = env.CONSOLE_METRICS_PASSWORD_FILE ?? env.CONSOLE_LOKI_PASSWORD_FILE ?? join(home, ".loki-admin-password");
  if (!existsSync(join(configDir, "logging.json")) || !existsSync(passwordFile)) return null;
  return { url: env.CONSOLE_METRICS_URL ?? "https://logging.mgmt.internal:3121", user: "tappaas", passwordFile };
}

interface PromAnswer {
  status?: string;
  error?: string;
  data?: { resultType?: string; result?: { metric?: Labels; value?: [number, string]; values?: [number, string][] }[] };
}

// Prometheus's HTTP API over fetch (live), or over the fixture store's fake
// fetch: the same queries, the same parsing.
export function promClient(cfg: MetricsConfig, f: typeof fetch = fetch): PromClient {
  const ask = async (base: string, path: string, params: Record<string, string>): Promise<PromResult[]> => {
    let pw: string;
    try {
      pw = readFileSync(cfg.passwordFile, "utf8").trim();
    } catch {
      throw new Error(`the metrics store's credential (${cfg.passwordFile}) cannot be read`);
    }
    const q = Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
    const auth = Buffer.from(`${cfg.user}:${pw}`).toString("base64");
    const r = await f(`${base.replace(/\/+$/, "")}${path}?${q}`, { headers: { Authorization: `Basic ${auth}` }, signal: AbortSignal.timeout(20_000) });
    if (!r.ok) throw new Error(`the metrics store answered HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
    const doc = (await r.json()) as PromAnswer;
    if (doc.status !== "success") throw new Error(`the metrics store refused the query: ${doc.error ?? "no reason"}`);
    return (doc.data?.result ?? []).map((x) => ({ metric: x.metric ?? {}, values: x.values ?? (x.value ? [x.value] : []) }));
  };
  return {
    instant: (expr) => ask(cfg.url, "/api/v1/query", { query: expr }),
    range: (expr, startMs, endMs, stepS, trends) =>
      ask(trends ? `${cfg.url.replace(/\/+$/, "")}/trends` : cfg.url, "/api/v1/query_range", { query: expr, start: String(startMs / 1000), end: String(endMs / 1000), step: `${stepS}s` }),
  };
}

// ── ranges ────────────────────────────────────────────────────────────

// 24 h and 7 d from the store, 30 d and 90 d from the 5-minute trends.
export const RANGE: Record<PerfRange, { ms: number; stepS: number; trends: boolean }> = {
  "24h": { ms: 24 * 3600_000, stepS: 300, trends: false },
  "7d": { ms: 7 * 86400_000, stepS: 1800, trends: false },
  "30d": { ms: 30 * 86400_000, stepS: 7200, trends: true },
  "90d": { ms: 90 * 86400_000, stepS: 21600, trends: true },
};

export const isRange = (s: string | null): s is PerfRange => s !== null && (RANGES as string[]).includes(s);

const points = (r: PromResult | undefined): PerfPoint[] =>
  (r?.values ?? []).map(([t, v]) => ({ t: Math.round(t * 1000), v: Number(v) })).filter((p) => Number.isFinite(p.v));

// ── the levels (D3) ───────────────────────────────────────────────────

type Size = "small" | "medium" | "large";
const RETENTION: Record<Size, number> = { small: 7, medium: 15, large: 30 };
const SIZE_LEVEL: Record<Size, PerfLevel> = { small: "off", medium: "basic", large: "basic" };

interface PerfField {
  level?: unknown;
  resolution?: unknown;
  retentionDays?: unknown;
}

function readJson(f: string): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(f, "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

const perfOf = (doc: Record<string, unknown> | null): PerfField => (doc?.performance && typeof doc.performance === "object" ? (doc.performance as PerfField) : {});
const standing = (v: unknown): PerfLevel | null => (v === "off" || v === "basic" || v === "service" ? v : v === "trace" ? "service" : null); // trace is never standing: read as service
const resolutionOf = (v: unknown): PerfResolution | null => (v === "fine" ? "fine" : v === "normal" ? "normal" : null);

export interface SiteLevel {
  name: string;
  size: Size;
  level: PerfLevel;
  levelSet: boolean;
  resolution: PerfResolution;
  resolutionSet: boolean;
  retentionDays: number;
  retentionSet: boolean;
}

export function siteLevel(configDir: string): SiteLevel {
  const doc = readJson(join(configDir, "site.json"));
  const size: Size = doc?.size === "small" || doc?.size === "large" ? doc.size : "medium";
  const p = perfOf(doc);
  const level = standing(p.level);
  const res = resolutionOf(p.resolution);
  const ret = typeof p.retentionDays === "number" && p.retentionDays > 0 ? p.retentionDays : null;
  return {
    name: typeof doc?.name === "string" ? doc.name : "site",
    size,
    level: level ?? SIZE_LEVEL[size],
    levelSet: level !== null,
    resolution: res ?? "normal",
    resolutionSet: res !== null,
    retentionDays: ret ?? RETENTION[size],
    retentionSet: ret !== null,
  };
}

export interface Scope {
  level: PerfLevel;
  set: boolean;
  from: PerfEffective["from"];
  fromText: string;
  resolution: PerfResolution;
  resolutionSet: boolean;
}

export function environmentScope(configDir: string, env: string, site: SiteLevel): Scope {
  const p = perfOf(readJson(join(configDir, "environments", `${env}.json`)));
  const level = standing(p.level);
  const res = resolutionOf(p.resolution);
  const inherited: Scope = site.levelSet
    ? { level: site.level, set: false, from: "site", fromText: "the site", resolution: site.resolution, resolutionSet: false }
    : { level: site.level, set: false, from: "size", fromText: `the site's size (${site.size})`, resolution: site.resolution, resolutionSet: false };
  return {
    ...inherited,
    ...(level ? { level, set: true, from: "environment" as const, fromText: "set here" } : {}),
    ...(res ? { resolution: res, resolutionSet: true } : {}),
  };
}

export function moduleScope(configDir: string, module: string, env: Scope, envName: string | null): Scope {
  const p = perfOf(readJson(join(configDir, `${module}.json`)));
  const level = standing(p.level);
  const res = resolutionOf(p.resolution);
  const inherited: Scope = env.set ? { ...env, set: false, fromText: `environment ${envName}`, resolutionSet: false } : { ...env, set: false, resolutionSet: false };
  return {
    ...inherited,
    ...(level ? { level, set: true, from: "module" as const, fromText: "set here" } : {}),
    ...(res ? { resolution: res, resolutionSet: true } : {}),
  };
}

// ── the cost (D3's table, ADR-044's sizes) ────────────────────────────

// Series per CI by class and level, from P1's measurement on a 3-node,
// 22-guest site at basic (~1.9k series: a node ~250, a guest ~45, PBS ~100)
// and D3's table for service (the module's exporters, a route's histogram).
const SERIES: Record<string, Partial<Record<PerfLevel, number>>> = {
  machine: { basic: 250, service: 250, trace: 250 },
  vm: { basic: 45, service: 400, trace: 400 },
  lxc: { basic: 45, service: 400, trace: 400 },
  "proxy-route": { service: 60, trace: 60 },
  datastore: { basic: 100, service: 100, trace: 100 },
};
const INTERVAL_S: Record<PerfLevel, number> = { off: 60, basic: 60, service: 30, trace: 30 };
const BYTES_PER_SAMPLE = 1.5;
const KB_PER_SERIES = 30; // Prometheus's head
const PROMETHEUS_MB = 60;
const TRENDS_MB = 90;
const TEMPO_MB = 300;
const TREND_SHARE = 0.25; // the trend rules keep about a quarter of basic's series, 5-minute
const TREND_DAYS = 90;

export function costOf(classes: string[], level: PerfLevel, resolution: PerfResolution, retentionDays: number): PerfCost {
  if (level === "off") return ZERO;
  const series = classes.reduce((n, c) => n + (SERIES[c]?.[level] ?? 0), 0);
  const interval = resolution === "fine" ? 15 : INTERVAL_S[level];
  const diskMBPerDay = (series * (86400 / interval) * BYTES_PER_SAMPLE) / 1e6;
  return { series, diskMBPerDay, diskGB: (diskMBPerDay * retentionDays) / 1024, memoryMB: (series * KB_PER_SERIES) / 1024 };
}

export const ZERO: PerfCost = { series: 0, diskMBPerDay: 0, diskGB: 0, memoryMB: 0 };
export function subCost(a: PerfCost, b: PerfCost): PerfCost {
  return { series: a.series - b.series, diskMBPerDay: a.diskMBPerDay - b.diskMBPerDay, diskGB: a.diskGB - b.diskGB, memoryMB: a.memoryMB - b.memoryMB };
}
export function addCost(a: PerfCost, b: PerfCost): PerfCost {
  return { series: a.series + b.series, diskMBPerDay: a.diskMBPerDay + b.diskMBPerDay, diskGB: a.diskGB + b.diskGB, memoryMB: a.memoryMB + b.memoryMB };
}

// The whole: the CIs' cost, the store's own base, the trends instance, and Tempo while anything traces.
export function totalCost(parts: PerfCost[], tracing: boolean): PerfCost {
  const sum = parts.reduce(addCost, ZERO);
  if (sum.series === 0 && !tracing) return sum;
  const trendSeries = sum.series * TREND_SHARE;
  const trendGB = (trendSeries * 288 * BYTES_PER_SAMPLE * TREND_DAYS) / 1e6 / 1024;
  return { ...sum, diskGB: sum.diskGB + trendGB, memoryMB: sum.memoryMB + PROMETHEUS_MB + TRENDS_MB + (tracing ? TEMPO_MB : 0) };
}

// ── the CIs ───────────────────────────────────────────────────────────

export interface PerfCiRef {
  id: string;
  class: string;
  name: string;
  label: string;
  module: string | null;
  environment: string | null;
  labels: Labels; // how its series are selected
}

// A route's module, from the description network:proxy writes ("TAPPaaS: nextcloud").
const routeModule = (n: HealthNode, desc: Map<string, string>): string | null => /^TAPPaaS: ([a-z0-9-]+)/.exec(desc.get(n.id) ?? "")?.[1] ?? null;

// The CIs the catalogue has signals for, with their selectors: a pool by the
// node it runs on and its name, everything else by its own id.
export function perfCis(g: HealthGraph, descriptions: Map<string, string> = new Map()): PerfCiRef[] {
  const runsOn = new Map<string, string>();
  for (const e of g.edges) if (e.type === "runs-on") runsOn.set(e.from, e.to);
  const out: PerfCiRef[] = [];
  for (const n of g.nodes) {
    if (!PERF_CLASSES.includes(n.class)) continue;
    let labels: Labels = { tappaas_ci_id: n.id };
    if (n.class === "storage-pool") {
      const host = runsOn.get(n.id);
      if (!host) continue;
      labels = { pool: n.name, tappaas_ci_id: host };
    }
    const module = n.class === "proxy-route" ? routeModule(n, descriptions) ?? n.module : n.module;
    out.push({ id: n.id, class: n.class, name: n.name, label: n.label, module, environment: n.environment, labels });
  }
  return out;
}

const keyOf = (l: Labels, by: string[]): string => by.map((k) => l[k] ?? "").join("|");

// ── change markers (D4.2) ─────────────────────────────────────────────

// The CMDB changes on a CI that can move its numbers: a manager's or an
// operator's write (an update, a modify, a migration, a level change), not
// the sweep's observations.
export function annotationsOf(h: CmdbHistory | null, fromMs: number, toMs: number): PerfAnnotation[] {
  return (h?.changes ?? [])
    .filter((c) => c.kind === "change" && c.verb && c.verb !== "sweep")
    .map((c) => ({ at: c.time, label: c.verb as string, actor: c.actor, source: c.source }))
    .filter((a) => {
      const t = Date.parse(a.at);
      return t >= fromMs && t <= toMs;
    })
    .sort((a, b) => a.at.localeCompare(b.at));
}

// ── investigations ────────────────────────────────────────────────────

const ISO = /^\d{4}-\d\d-\d\dT/;

// health-manager perf list --json, checked against the contract; a row that
// does not fit it is dropped, not guessed at.
export function parseInvestigations(doc: unknown, now: number): { active: PerfInvestigation[]; history: PerfInvestigation[] } {
  const d = (doc && typeof doc === "object" ? doc : {}) as { investigations?: unknown[]; history?: unknown[] };
  const row = (x: unknown): PerfInvestigation | null => {
    const r = (x && typeof x === "object" ? x : {}) as Record<string, unknown>;
    const ci = (r.ci && typeof r.ci === "object" ? r.ci : {}) as Record<string, unknown>;
    if (typeof ci.id !== "string" || typeof ci.name !== "string" || typeof r.until !== "string" || !ISO.test(r.until) || typeof r.started !== "string") return null;
    const level = r.level === "basic" || r.level === "service" || r.level === "trace" ? r.level : null;
    if (!level) return null;
    return {
      ci: { id: ci.id, class: typeof ci.class === "string" ? ci.class : "ci", name: ci.name },
      level,
      resolution: r.resolution === "fine" ? "fine" : "normal",
      from: standing(r.from) ?? "off",
      by: typeof r.by === "string" ? r.by : "?",
      note: typeof r.note === "string" ? r.note : null,
      started: r.started,
      until: r.until,
      ended: typeof r.ended === "string" ? r.ended : null,
      endedHow: r.endedHow === "expired" || r.endedHow === "stopped" ? r.endedHow : null,
      endedBy: typeof r.endedBy === "string" ? r.endedBy : null,
    };
  };
  const all = [...(d.investigations ?? []), ...(d.history ?? [])].map(row).filter((x): x is PerfInvestigation => x !== null);
  // One whose end has passed is history, whatever the verb last wrote.
  const active = all.filter((x) => !x.ended && Date.parse(x.until) > now).sort((a, b) => a.until.localeCompare(b.until));
  const history = all
    .filter((x) => !active.includes(x))
    .map((x) => (x.ended ? x : { ...x, ended: x.until, endedHow: "expired" as const }))
    .sort((a, b) => (b.ended ?? "").localeCompare(a.ended ?? ""));
  return { active, history };
}

// ── the reads ─────────────────────────────────────────────────────────

export interface PerfDeps {
  configDir: string;
  run: Runner;
  graph: () => Promise<HealthGraph | null>;
  history: (id: string) => Promise<CmdbHistory | null>;
  descriptions: () => Promise<Map<string, string>>; // proxy-route id → description
  modules: () => Promise<{ name: string; environment?: string | null }[]>;
  environments: () => Promise<string[]>;
  logging: () => Promise<{ memoryMB: number | null; diskGB: number | null; installed: boolean }>;
  hasVerb: (words: string[]) => boolean; // health-manager's manifest has it
  envLevelSettable: () => boolean; // environment-manager's fields know performance.level
  prom: PromClient | null;
  grafana: (cls: string, labels: Labels) => string | null; // the class's shipped dashboard at the CI
  traces?: (id: string) => string | null; // Tempo's explore view, once logging:traces exists (P6)
  now: () => number;
}

const TOP = 8;

export class Perf {
  readonly overview: Cached<PerfOverview>;
  readonly levels: Cached<PerfLevels>;
  readonly investigations: Cached<PerfInvestigations>;
  readonly series: CachedMap<PerfCi>;

  constructor(private readonly d: PerfDeps) {
    this.overview = new Cached("perf-overview", 60_000, () => this.loadOverview(), d.now);
    this.levels = new Cached("perf-levels", 60_000, () => this.loadLevels(), d.now);
    this.investigations = new Cached("perf-investigations", 30_000, () => this.loadInvestigations(), d.now);
    // key: "<id>|<range>"
    this.series = new CachedMap("perf-series", 60_000, (k) => {
      const [id, range] = k.split("|");
      return this.loadCi(id, range as PerfRange);
    }, d.now);
  }

  refresh(): void {
    void this.overview.refresh();
    void this.levels.refresh();
    void this.investigations.refresh();
  }

  // Every CI's effective level: the cascade, then a timed raise over it.
  private async effective(): Promise<{ site: SiteLevel; byModule: Map<string, Scope>; byEnv: Map<string, Scope>; active: PerfInvestigation[] }> {
    const site = siteLevel(this.d.configDir);
    const [mods, envs, inv] = await Promise.all([this.d.modules(), this.d.environments(), this.investigations.get()]);
    const byEnv = new Map(envs.map((e) => [e, environmentScope(this.d.configDir, e, site)]));
    const byModule = new Map<string, Scope>();
    for (const m of mods) {
      const env = m.environment ? byEnv.get(m.environment) ?? environmentScope(this.d.configDir, m.environment, site) : environmentScope(this.d.configDir, "-", site);
      byModule.set(m.name, moduleScope(this.d.configDir, m.name, env, m.environment ?? null));
    }
    return { site, byModule, byEnv, active: inv.value?.active ?? [] };
  }

  private levelOf(ci: { id: string; module: string | null; environment: string | null }, e: Awaited<ReturnType<Perf["effective"]>>): PerfEffective {
    const scope = (ci.module && e.byModule.get(ci.module)) || (ci.environment && e.byEnv.get(ci.environment)) || environmentScope(this.d.configDir, "-", e.site);
    const raise = e.active.find((x) => x.ci.id === ci.id);
    const base: PerfEffective = { level: scope.level, resolution: scope.resolution, from: scope.from, until: null, by: null, cascaded: scope.level };
    if (!raise) return base;
    return { level: levelRank(raise.level) > levelRank(scope.level) ? raise.level : scope.level, resolution: raise.resolution === "fine" ? "fine" : scope.resolution, from: "investigation", until: raise.until, by: raise.by, cascaded: scope.level };
  }

  private anyCollecting(e: Awaited<ReturnType<Perf["effective"]>>): boolean {
    return e.site.level !== "off" || e.active.length > 0 || [...e.byModule.values(), ...e.byEnv.values()].some((s) => s.level !== "off");
  }

  async loadInvestigations(): Promise<PerfInvestigations> {
    const now = this.d.now();
    const base = { now: new Date(now).toISOString(), active: [], history: [] };
    if (!this.d.hasVerb(["perf", "list"])) return { ...base, available: false, error: null };
    const r = await this.d.run("health-manager", ["perf", "list", "--json"], 30_000);
    if (!r.ran || r.rc !== 0) return { ...base, available: true, error: (r.stderr || r.stdout).trim().split("\n").pop() || `health-manager perf list exited ${r.rc}` };
    try {
      return { now: base.now, ...parseInvestigations(JSON.parse(r.stdout), now), available: true, error: null };
    } catch {
      return { ...base, available: true, error: "health-manager perf list --json gave no JSON" };
    }
  }

  async loadLevels(): Promise<PerfLevels> {
    const e = await this.effective();
    const [g, mods, logging, desc, measured] = await Promise.all([this.d.graph(), this.d.modules(), this.d.logging(), this.d.descriptions(), this.measured(e)]);
    const cis = g ? perfCis(g, desc) : [];
    // What a module costs: every CI of it that has a series count, a route by its description.
    const classesOf = (m: string): string[] => [
      ...(g?.nodes ?? []).filter((n) => n.module === m && n.class !== "proxy-route" && SERIES[n.class]).map((n) => n.class),
      ...cis.filter((c) => c.module === m && c.class === "proxy-route").map((c) => c.class),
    ];
    const ret = e.site.retentionDays;
    const rows: PerfLevelRow[] = [];
    const siteScope = environmentScope(this.d.configDir, "-", e.site);
    rows.push({ scope: "site", name: e.site.name, environment: null, ciId: g?.site ?? null, level: e.site.level, set: e.site.levelSet, from: e.site.levelSet ? "set here" : `the site's size (${e.site.size})`, resolution: e.site.resolution, resolutionSet: e.site.resolutionSet, cost: ZERO });
    for (const [name, s] of [...e.byEnv].sort(([a], [b]) => a.localeCompare(b))) {
      const own = mods.filter((m) => m.environment === name);
      const cost = own.reduce((c, m) => addCost(c, costOf(classesOf(m.name), e.byModule.get(m.name)?.level ?? s.level, e.byModule.get(m.name)?.resolution ?? s.resolution, ret)), ZERO);
      rows.push({ scope: "environment", name, environment: null, ciId: g?.nodes.find((n) => n.class === "environment" && n.name === name)?.id ?? null, level: s.level, set: s.set, from: s.fromText, resolution: s.resolution, resolutionSet: s.resolutionSet, cost });
    }
    for (const m of [...mods].sort((a, b) => a.name.localeCompare(b.name))) {
      const s = e.byModule.get(m.name) ?? siteScope;
      const main = cis.find((c) => c.module === m.name && (c.class === "vm" || c.class === "lxc" || c.class === "machine")) ?? null;
      rows.push({ scope: "module", name: m.name, environment: m.environment ?? null, ciId: main?.id ?? null, level: s.level, set: s.set, from: s.fromText, resolution: s.resolution, resolutionSet: s.resolutionSet, cost: costOf(classesOf(m.name), s.level, s.resolution, ret) });
    }
    // A raise counts at its level for as long as it holds.
    const raised = e.active.map((x) => {
      const c = cis.find((y) => y.id === x.ci.id);
      const cascaded = c ? this.levelOf(c, { ...e, active: [] }).level : "off";
      return levelRank(x.level) > levelRank(cascaded) ? subCost(costOf([x.ci.class], x.level, x.resolution, ret), costOf([x.ci.class], cascaded, "normal", ret)) : ZERO;
    });
    const total = totalCost([...rows.filter((r) => r.scope === "module").map((r) => r.cost), ...raised], e.active.some((x) => x.level === "trace"));
    return { site: e.site.name, size: e.site.size, retentionDays: ret, retentionSet: e.site.retentionSet, rows, total, measuredSeries: measured, logging, verbs: { environmentLevel: this.d.envLevelSettable() } };
  }

  private async measured(e: Awaited<ReturnType<Perf["effective"]>>): Promise<number | null> {
    if (!this.d.prom || !this.anyCollecting(e)) return null;
    try {
      const r = await this.d.prom.instant(MEASURED_SERIES);
      const v = Number(r[0]?.values[0]?.[1]);
      return Number.isFinite(v) ? v : null;
    } catch {
      return null;
    }
  }

  // The `performance` root causes the CMDB carries (D6), with what they explain.
  static roots(g: HealthGraph | null): PerfRoot[] {
    if (!g) return [];
    const perf = (n: HealthNode) => n.issues.filter((i) => i.type === "performance");
    const out: PerfRoot[] = [];
    for (const n of g.nodes) {
      const own = perf(n).find((i) => !i.derived && i.rootCause.filter((r) => r !== n.id).length === 0);
      if (!own) continue;
      // What it slows: the impact derive gave them (and their own performance condition, derived from it).
      const impacted = g.nodes.filter((x) => x.id !== n.id && x.issues.some((i) => (i.type === "impact" || i.type === "performance") && i.rootCause.includes(n.id))).map((x) => ({ id: x.id, label: x.label, class: x.class }));
      out.push({ id: n.id, class: n.class, label: n.label, status: own.status, message: own.message ?? own.reason, since: own.since, impacted });
    }
    return out.sort((a, b) => b.impacted.length - a.impacted.length || a.label.localeCompare(b.label));
  }

  async loadOverview(): Promise<PerfOverview> {
    const e = await this.effective();
    const [g, logging, inv, desc] = await Promise.all([this.d.graph(), this.d.logging(), this.investigations.get(), this.d.descriptions()]);
    const cis = g ? perfCis(g, desc) : [];
    const base: PerfOverview = {
      site: e.site.name, level: e.site.level, levelFrom: e.site.levelSet ? "site" : "size", size: e.site.size,
      store: "off", storeError: null, roots: Perf.roots(g), saturated: [], services: [], basicCost: null, logging,
      investigations: inv.value?.active.length ?? 0,
    };
    if (!this.anyCollecting(e)) {
      const classes = cis.filter((c) => c.class !== "storage-pool" && c.class !== "proxy-route").map((c) => c.class);
      return { ...base, basicCost: totalCost([costOf(classes, "basic", "normal", RETENTION[e.site.size])], false) };
    }
    if (!this.d.prom) return { ...base, store: "unreachable", storeError: "The logging module or its admin credential is not on this machine, so the metrics store cannot be read." };
    const prom = this.d.prom;
    const now = this.d.now();
    try {
      const rows: PerfTop[] = [];
      const byKey = new Map<string, PerfCiRef>();
      for (const c of cis) byKey.set(c.labels.pool ? `${c.labels.tappaas_ci_id}|${c.labels.pool}` : c.id, c);
      await Promise.all(SIGNALS.filter((s) => s.saturation).map(async (s) => {
        for (const r of await prom.instant(s.expr(SITE_WIDE))) {
          const c = byKey.get(keyOf(r.metric, s.by));
          const v = Number(r.values[0]?.[1]);
          if (!c || !s.classes.includes(c.class) || !Number.isFinite(v)) continue;
          rows.push({ ci: { id: c.id, class: c.class, name: c.name, label: c.label }, signal: s.key, label: s.label, unit: s.unit, value: v, warning: s.warning, critical: s.critical, status: statusOf(v, s.warning, s.critical), spark: [], lastChange: null });
        }
      }));
      // How close to its line: the value over its warning threshold.
      const score = (r: PerfTop): number => (r.warning ? r.value / r.warning : 0);
      const pick = (lens: "use" | "red"): PerfTop[] => {
        const own = rows.filter((r) => SIGNALS.find((s) => s.key === r.signal)?.lens === lens).sort((a, b) => score(b) - score(a));
        const seen = new Set<string>();
        return own.filter((r) => (seen.has(r.ci.id) ? false : (seen.add(r.ci.id), true))).slice(0, TOP);
      };
      const saturated = pick("use");
      const services = pick("red");
      const day = RANGE["24h"];
      await Promise.all([...saturated, ...services].map(async (row) => {
        const s = SIGNALS.find((x) => x.key === row.signal)!;
        const c = cis.find((x) => x.id === row.ci.id)!;
        const [r, h] = await Promise.all([prom.range(s.expr(selectorOf(c.labels)), now - day.ms, now, day.stepS, false), this.d.history(c.id).catch(() => null)]);
        row.spark = points(r[0]);
        row.lastChange = annotationsOf(h, now - day.ms, now).pop() ?? null;
      }));
      return { ...base, store: "on", saturated, services };
    } catch (err) {
      return { ...base, store: "unreachable", storeError: (err as Error).message };
    }
  }

  async loadCi(id: string, range: PerfRange): Promise<PerfCi> {
    const [g, desc, e] = await Promise.all([this.d.graph(), this.d.descriptions(), this.effective()]);
    const node = g?.nodes.find((n) => n.id === id) ?? null;
    if (!node) throw new Error(`no object ${id}`);
    const ref = (g ? perfCis(g, desc) : []).find((c) => c.id === id) ?? null;
    const level = this.levelOf(ref ?? { id, module: node.module, environment: node.environment }, e);
    const perfIssue = node.issues.find((i) => i.type === "performance" && i.rootCause.length) ?? node.issues.find((i) => i.type === "impact");
    const rootId = perfIssue?.rootCause.find((r) => r !== id) ?? null;
    const rootNode = rootId ? g?.nodes.find((n) => n.id === rootId) ?? null : null;
    const now = this.d.now();
    const spec = RANGE[range];
    const out: PerfCi = {
      ci: { id, class: node.class, name: node.name, label: node.label },
      range, store: "off", storeError: null, level, series: [], annotations: [],
      links: { grafana: null, traces: null, rootCause: rootNode ? { id: rootNode.id, label: rootNode.label } : null },
      note: null,
    };
    const h = await this.d.history(id).catch(() => null);
    out.annotations = annotationsOf(h, now - spec.ms, now);
    const signals = signalsFor(node.class);
    // Its own performance condition over its line: that signal is charted, at that status.
    const breach = node.issues.find((i) => i.type === "performance" && (i.status === "warning" || i.status === "critical"));
    if (!ref || !signals.length) return { ...out, note: `Nothing is measured for a ${node.class}: performance covers nodes, guests, storage pools and published services.` };
    out.links.grafana = this.d.grafana(node.class, ref.labels);
    if (level.level === "trace") out.links.traces = this.d.traces?.(id) ?? null;
    if (level.level === "off" && !this.anyCollecting(e)) return { ...out, note: "This site collects no numbers: its level is off." };
    if (!this.d.prom) return { ...out, store: "unreachable", storeError: "The logging module or its admin credential is not on this machine, so the metrics store cannot be read." };
    try {
      out.series = await Promise.all(signals.map(async (s): Promise<PerfSeries> => {
        const q = spec.trends ? s.trend : s.expr;
        const r = q ? await this.d.prom!.range(q(selectorOf(ref.labels)), now - spec.ms, now, spec.stepS, spec.trends) : [];
        const pts = points(r[0]);
        const last = pts.length ? pts[pts.length - 1].v : null;
        const measured = statusOf(last, s.warning, s.critical) as PerfStatus;
        const judged = judgedBy(s, breach);
        return { key: s.key, label: s.label, unit: s.unit, lens: s.lens, warning: s.warning, critical: s.critical, points: pts, now: last, status: judged && RANK_STATUS[breach!.status as PerfStatus] > RANK_STATUS[measured] ? (breach!.status as PerfStatus) : measured, ...(judged ? { judged: true } : {}) };
      }));
      out.store = "on";
      if (out.series.every((s) => !s.points.length)) {
        const need = signals.every((s) => s.level === "service") ? "service" : "basic";
        out.note = spec.trends && signals.every((s) => !s.trend)
          ? `The ${range} view reads the 5-minute trends, which keep no ${node.class} numbers yet.`
          : levelRank(level.level) < levelRank(need) ? `Its level is ${level.level}; these numbers are collected from ${need} up.` : "The store holds no numbers for it in this range.";
      }
      return out;
    } catch (err) {
      return { ...out, store: "unreachable", storeError: (err as Error).message };
    }
  }

  ci(id: string, range: PerfRange): Promise<Entry<PerfCi>> {
    return this.series.of(`${id}|${range}`).get();
  }
}
