// assess-performance.ts — the `performance` condition and the trend-based
// `capacity` (ADR-046 D6), from the metrics store, for assess.
//
// performance  each signal's static thresholds (O6): D6's per-class defaults
//              (perf-signals.ts) and what a foundation module declares
//              (performance.thresholds, on its guest and its routes). A level is
//              entered only once the signal has held at or over it for the
//              whole window (`for`: min_over_time over the window), and left
//              only once it has stayed under it for the window (max_over_time):
//              a spike is no event, and neither is one quiet minute.
//              A CI that had a performance condition and has no numbers now is
//              `unknown`, never critical; one never measured gets none.
// capacity     "full in N days" for pools (Proxmox's storage numbers), backup
//              datastores (PBS's) and node memory, from the slope of the last 7
//              days: within the site's horizon (performance.capacityHorizonDays,
//              default 14) a warning, beside the usage thresholds' own.
//
// Pure over a MetricsReader; a store that does not answer gives no findings,
// and assess then leaves what this source set standing (not looked).

import { CmdbItem, Condition, RANK, SiteIndex, conditionsOf } from "./assess-model";
import { Finding } from "./assess-sources";
import { MetricsReader, Sample } from "./metrics-read";
import { ConditionStatus } from "../../../lib/ts/src/health-rules";
import { PERF_SIGNALS, PerfSignal, durationSeconds, signalExpr, signalNamed, signalValue } from "../../../lib/ts/src/perf-signals";

export const PERF_OWNER = "performance";
export const SITE_WIDE = 'tappaas_ci_id!=""';
export const DEFAULT_HORIZON_DAYS = 14;
const TREND_WINDOW = "7d";

// Proxmox's storage numbers and PBS's datastore numbers name the storage by a
// label; the pool or datastore CI of that name (on that node) is its object.
export const STORAGE_LABEL = "storage";
export const DATASTORE_LABEL = "id";

export interface Threshold {
  signal: PerfSignal;
  warning: number;
  critical: number;
  forS: number;
  declared: string | null; // the module that declared it; null: the default
}

export interface Declared {
  module: string;
  thresholds: { signal: string; warning?: number; critical?: number; for?: string }[];
}

const levelOf = (v: number, t: Threshold): ConditionStatus => (v >= t.critical ? "critical" : v >= t.warning ? "warning" : "ok");

/** The thresholds for one CI: the class's defaults, a declaration of its module over them. */
export function thresholdsFor(cls: string, module: string | null, declared: Declared[]): Threshold[] {
  const out = new Map<string, Threshold>();
  for (const s of PERF_SIGNALS) {
    if (!s.classes.includes(cls) || !s.defaults) continue;
    out.set(s.name, { signal: s, warning: s.defaults.warning, critical: s.defaults.critical, forS: durationSeconds(s.defaults.for) ?? 900, declared: null });
  }
  for (const d of declared.filter((x) => x.module === module)) {
    for (const t of d.thresholds) {
      const s = signalNamed(t.signal);
      if (!s || !s.classes.includes(cls)) continue;
      const base = out.get(s.name);
      const warning = t.warning ?? base?.warning ?? Infinity;
      const critical = t.critical ?? base?.critical ?? Infinity;
      out.set(s.name, { signal: s, warning, critical, forS: durationSeconds(t.for ?? "") ?? base?.forS ?? 900, declared: d.module });
    }
  }
  return [...out.values()];
}

// The CI a series is about: a pool by its node and name, a route by its own
// id, everything else by its id.
export function ciIndex(idx: SiteIndex): (s: PerfSignal, m: Record<string, string>) => CmdbItem | undefined {
  const runsOn = new Map<string, string>();
  for (const r of idx.relations) if (r.type === "runs-on") runsOn.set(r.from.id, r.to.id);
  const pools = new Map<string, CmdbItem>();
  for (const o of idx.objects) if (o.class === "storage-pool" && runsOn.get(o.id)) pools.set(`${runsOn.get(o.id)}|${o.name}`, o);
  return (s, m) => (s.classes.includes("storage-pool") ? pools.get(`${m.tappaas_ci_id}|${m.pool}`) : idx.byId.get(m.tappaas_ci_id ?? ""));
}

// The module a CI belongs to: its `module` attribute, as its reporter set it.
const moduleOf = (o: CmdbItem): string | null => (typeof o.attributes.module === "string" && o.attributes.module ? o.attributes.module : null);

const query = (r: MetricsReader, expr: string, trends = false): Sample[] | null => r.instant(expr, trends);
const windowed = (fn: "min_over_time" | "max_over_time", s: PerfSignal, forS: number): string => `${fn}((${signalExpr(s, SITE_WIDE)})[${forS}s:1m])`;

/** The performance findings: one per CI and signal judged, worst kept by assess. */
export function fromPerformance(idx: SiteIndex, reader: MetricsReader, declared: Declared[]): { findings: Finding[]; looked: boolean } {
  const findings: Finding[] = [];
  const objectOf = ciIndex(idx);
  // Each signal once per window, site-wide: a declared window is a query of its own.
  const windows = new Map<string, Set<number>>();
  const perCi = new Map<string, Threshold[]>();
  for (const o of idx.objects) {
    const ts = thresholdsFor(o.class, moduleOf(o), declared);
    if (!ts.length) continue;
    perCi.set(o.id, ts);
    for (const t of ts) windows.set(t.signal.name, new Set([...(windows.get(t.signal.name) ?? []), t.forS]));
  }
  const answers = new Map<string, { min: Map<string, number>; max: Map<string, number> }>();
  for (const [name, fors] of windows) {
    const s = signalNamed(name)!;
    for (const f of fors) {
      const lo = query(reader, windowed("min_over_time", s, f));
      const hi = query(reader, windowed("max_over_time", s, f));
      if (lo === null || hi === null) return { findings: [], looked: false }; // the store did not answer: nothing judged
      const min = new Map<string, number>();
      const max = new Map<string, number>();
      for (const x of lo) { const o = objectOf(s, x.metric); if (o) min.set(o.id, Math.max(min.get(o.id) ?? -Infinity, x.value)); }
      for (const x of hi) { const o = objectOf(s, x.metric); if (o) max.set(o.id, Math.max(max.get(o.id) ?? -Infinity, x.value)); }
      answers.set(`${name}|${f}`, { min, max });
    }
  }
  for (const [id, ts] of perCi) {
    const o = idx.byId.get(id)!;
    const prior = conditionsOf(o).find((c: Condition) => c.type === "performance");
    let seen = false;
    for (const t of ts) {
      const a = answers.get(`${t.signal.name}|${t.forS}`);
      const lo = a?.min.get(id);
      const hi = a?.max.get(id);
      if (lo === undefined || hi === undefined) continue;
      seen = true;
      // Entered once held for the window; left once under it for the window.
      const was = prior && prior.reason === reasonOf(t.signal) ? prior.status : "ok";
      const w: ConditionStatus = was === "unknown" ? "ok" : was;
      const held = levelOf(lo, t); // at or over it the whole window
      const ceiling = levelOf(hi, t); // never over it in the window: it cannot stay there
      const stays = RANK[w] <= RANK[ceiling] ? w : ceiling;
      const status: ConditionStatus = RANK[held] >= RANK[stays] ? held : stays;
      const mins = Math.round(t.forS / 60);
      const line = status === "ok"
        ? `${o.name}: ${t.signal.label} ${signalValue(t.signal, hi)} at most in ${mins} min`
        : `${o.name}: ${t.signal.label} ${signalValue(t.signal, lo)}, over ${signalValue(t.signal, status === "critical" ? t.critical : t.warning)} for ${mins} min${t.declared ? ` (${t.declared}'s threshold)` : ""}`;
      findings.push({ object: id, type: "performance", status, reason: status === "ok" ? "ok" : reasonOf(t.signal), message: line, owner: PERF_OWNER });
    }
    // Measured before, no numbers now: unknown, never critical.
    if (!seen && prior) findings.push({ object: id, type: "performance", status: "unknown", reason: "perf-no-numbers", message: `${o.name}: no numbers in the metrics store`, owner: PERF_OWNER });
  }
  return { findings, looked: true };
}

export const reasonOf = (s: PerfSignal): string => `perf-${s.name.replace(/_/g, "-")}`;

/** The projections: "full in N days" within the horizon is a capacity warning. */
export function fromTrends(idx: SiteIndex, reader: MetricsReader, horizonDays: number): { findings: Finding[]; looked: boolean } {
  const findings: Finding[] = [];
  const runsOn = new Map<string, string>();
  for (const r of idx.relations) if (r.type === "runs-on") runsOn.set(r.from.id, r.to.id);
  const days = (free: string, used: string, trends: boolean): Sample[] | null =>
    query(reader, `(${free}) / (deriv((${used})[${TREND_WINDOW}:1h]) > 0) / 86400`, trends);
  const pools = days(
    `max by (tappaas_ci_id, ${STORAGE_LABEL}) (trend5m:proxmox_storage_total:avg{${SITE_WIDE}}) - max by (tappaas_ci_id, ${STORAGE_LABEL}) (trend5m:proxmox_storage_used:avg{${SITE_WIDE}})`,
    `max by (tappaas_ci_id, ${STORAGE_LABEL}) (trend5m:proxmox_storage_used:avg{${SITE_WIDE}})`, true);
  const stores = days(`max by (tappaas_ci_id, ${DATASTORE_LABEL}) (pbs_datastore_avail{${SITE_WIDE}})`, `max by (tappaas_ci_id, ${DATASTORE_LABEL}) (pbs_datastore_used{${SITE_WIDE}})`, false);
  const memory = days(
    `max by (tappaas_ci_id) (trend5m:proxmox_node_memory_memtotal:avg{${SITE_WIDE}}) - max by (tappaas_ci_id) (trend5m:proxmox_node_memory_memused:avg{${SITE_WIDE}})`,
    `max by (tappaas_ci_id) (trend5m:proxmox_node_memory_memused:avg{${SITE_WIDE}})`, true);
  if (pools === null && stores === null && memory === null) return { findings, looked: false };
  const say = (o: CmdbItem, what: string, d: number): void => {
    const within = d <= horizonDays;
    findings.push({ object: o.id, type: "capacity", status: within ? "warning" : "ok", reason: within ? "capacity-trend" : "ok", message: `${o.name}: ${what} full in ${Math.max(0, Math.round(d))} day(s) at the last 7 days' rate`, owner: PERF_OWNER });
  };
  for (const x of pools ?? []) {
    const o = idx.objects.find((p) => p.class === "storage-pool" && p.name === x.metric[STORAGE_LABEL] && runsOn.get(p.id) === x.metric.tappaas_ci_id);
    if (o) say(o, "the pool is", x.value);
  }
  for (const x of stores ?? []) {
    const o = idx.objects.find((p) => p.class === "datastore" && p.name === x.metric[DATASTORE_LABEL]);
    if (o) say(o, "the datastore is", x.value);
  }
  for (const x of memory ?? []) {
    const o = idx.byId.get(x.metric.tappaas_ci_id ?? "");
    if (o && o.class === "machine") say(o, "its memory is", x.value);
  }
  return { findings, looked: true };
}

export function horizonOf(siteJson: Record<string, unknown> | null): number {
  const p = (siteJson?.performance ?? {}) as { capacityHorizonDays?: unknown };
  return typeof p.capacityHorizonDays === "number" && p.capacityHorizonDays > 0 ? p.capacityHorizonDays : DEFAULT_HORIZON_DAYS;
}
