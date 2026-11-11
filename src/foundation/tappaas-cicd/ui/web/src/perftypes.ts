// perftypes.ts — what the console's performance reads answer (ADR-046 D7),
// shared by the server (src/perf.ts) and the web app. Plain types and a few
// pure helpers, no DOM.

export type PerfLevel = "off" | "basic" | "service" | "trace";
export type PerfResolution = "normal" | "fine";
export type PerfRange = "24h" | "7d" | "30d" | "90d";
export type PerfStatus = "ok" | "warning" | "critical" | "unknown";

export const LEVELS: PerfLevel[] = ["off", "basic", "service", "trace"];
// What may be set as standing configuration: trace is only ever a timed raise.
export const STANDING_LEVELS: PerfLevel[] = ["off", "basic", "service"];
export const RANGES: PerfRange[] = ["24h", "7d", "30d", "90d"];

export const levelRank = (l: PerfLevel): number => LEVELS.indexOf(l);

// The store's state as the console sees it: off (the site collects nothing),
// on, or unreachable (on, but the store did not answer).
export type StoreState = "off" | "on" | "unreachable";

// A change on the CI that can move its numbers, drawn on its charts (D4.2).
export interface PerfAnnotation {
  at: string;
  label: string; // "update identity", "modify nomad", "level trace until 12:00"
  actor: string | null;
  source: string;
}

export interface PerfPoint {
  t: number; // ms since the epoch
  v: number;
}

export interface PerfSeries {
  key: string; // "vm.io_pressure"
  label: string; // "I/O pressure"
  unit: string; // "%", "ms", "MB/s", "req/s"
  lens: "use" | "red";
  warning: number | null; // the static threshold (D6), in the unit
  critical: number | null;
  points: PerfPoint[];
  now: number | null; // the last value
  status: PerfStatus; // its line, or its performance condition's when that names it
  judged?: boolean; // the signal its performance condition names: always charted
}

// One row of the Overview's lists.
export interface PerfTop {
  ci: { id: string; class: string; name: string; label: string };
  signal: string;
  label: string;
  unit: string;
  value: number;
  warning: number | null;
  critical: number | null;
  status: PerfStatus;
  spark: PerfPoint[]; // 24 h
  lastChange: PerfAnnotation | null;
}

export interface PerfRoot {
  id: string;
  class: string;
  label: string;
  status: PerfStatus;
  message: string | null;
  since: string | null;
  impacted: { id: string; label: string; class: string }[];
}

export interface PerfCost {
  series: number;
  diskMBPerDay: number;
  diskGB: number; // over the retention
  memoryMB: number;
}

export interface PerfOverview {
  site: string;
  level: PerfLevel; // the site's level
  levelFrom: "site" | "size"; // set in the site's record, or its size's default
  size: "small" | "medium" | "large";
  store: StoreState;
  storeError: string | null;
  roots: PerfRoot[];
  saturated: PerfTop[]; // USE: the most saturated resources
  services: PerfTop[]; // RED: the slowest and most failing published services
  basicCost: PerfCost | null; // what switching on basic would cost, when the site is off
  logging: { memoryMB: number | null; diskGB: number | null; installed: boolean };
  investigations: number; // timed raises in force
}

// A CI's numbers over a range (the CI panel and Browse).
export interface PerfCi {
  ci: { id: string; class: string; name: string; label: string };
  range: PerfRange;
  store: StoreState;
  storeError: string | null;
  level: PerfEffective;
  series: PerfSeries[];
  annotations: PerfAnnotation[];
  links: { grafana: string | null; traces: string | null; rootCause: { id: string; label: string } | null };
  note: string | null; // why there are no series, in the operator's words
}

// Where a CI's level comes from, and until when a raise holds.
export interface PerfEffective {
  level: PerfLevel;
  resolution: PerfResolution;
  from: "site" | "size" | "environment" | "module" | "investigation";
  until: string | null; // a timed raise's end
  by: string | null;
  cascaded: PerfLevel; // what it falls back to when a raise ends
}

export interface PerfLevelRow {
  scope: "site" | "environment" | "module";
  name: string;
  environment: string | null; // a module's
  ciId: string | null; // a module's main CI, for its panel
  level: PerfLevel;
  set: boolean; // set here, not inherited
  from: string; // "set here", "the site", "environment rossen", "the site's size (medium)"
  resolution: PerfResolution;
  resolutionSet: boolean;
  cost: PerfCost;
}

export interface PerfLevels {
  site: string;
  size: "small" | "medium" | "large";
  retentionDays: number;
  retentionSet: boolean;
  rows: PerfLevelRow[];
  total: PerfCost; // with the trends instance and, while anything traces, Tempo
  measuredSeries: number | null; // what the store holds now
  logging: { memoryMB: number | null; diskGB: number | null; installed: boolean };
  verbs: { environmentLevel: boolean }; // environment-manager accepts performance.level
}

// health-manager perf list --json, one row (the contract in ui/README.md).
export interface PerfInvestigation {
  ci: { id: string; class: string; name: string };
  level: PerfLevel;
  resolution: PerfResolution;
  from: PerfLevel; // the cascaded level it raised from
  by: string;
  note: string | null;
  started: string;
  until: string;
  ended: string | null;
  endedHow: "expired" | "stopped" | null;
  endedBy: string | null;
}

export interface PerfInvestigations {
  now: string;
  active: PerfInvestigation[];
  history: PerfInvestigation[];
  available: boolean; // health-manager has the perf verbs
  error: string | null;
}

// A value as the operator reads it: 3 significant digits at most, the unit after.
export function fmtValue(v: number | null, unit: string): string {
  if (v === null || !Number.isFinite(v)) return "—";
  const a = Math.abs(v);
  const s = a >= 100 ? v.toFixed(0) : a >= 10 ? v.toFixed(1) : a >= 1 ? v.toFixed(2) : v.toFixed(a === 0 ? 0 : 3);
  const t = s.includes(".") ? s.replace(/0+$/, "").replace(/\.$/, "") : s;
  return unit === "%" ? `${t} %` : `${t} ${unit}`;
}

export function fmtSize(mb: number): string {
  if (mb >= 1024 * 10) return `${Math.round(mb / 1024)} GB`;
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`;
  return `${Math.round(mb)} MB`;
}

export function fmtSeries(n: number): string {
  return n >= 10000 ? `${Math.round(n / 1000)}k` : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(Math.round(n));
}

export const statusOf = (v: number | null, warning: number | null, critical: number | null): PerfStatus =>
  v === null || !Number.isFinite(v) ? "unknown" : critical !== null && v >= critical ? "critical" : warning !== null && v >= warning ? "warning" : "ok";

/** The charts a short list shows (the CI panel's `max`): the signal its
 *  performance condition names first, then what is over its line, then the
 *  catalogue's order; only series with numbers. Without a max, all of them. */
export function chartsShown(series: PerfSeries[], max?: number): PerfSeries[] {
  const rank: Record<PerfStatus, number> = { critical: 0, warning: 1, ok: 2, unknown: 3 };
  const withNumbers = series.map((s, i) => ({ s, i })).filter((x) => x.s.points.length);
  if (!max) return withNumbers.map((x) => x.s);
  return withNumbers
    .sort((a, b) => Number(!!b.s.judged) - Number(!!a.s.judged) || rank[a.s.status] - rank[b.s.status] || a.i - b.i)
    .slice(0, max)
    .map((x) => x.s);
}
