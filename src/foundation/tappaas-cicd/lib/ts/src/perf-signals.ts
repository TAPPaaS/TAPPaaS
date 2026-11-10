// perf-signals.ts — the signals a threshold may name (ADR-046 D5, D6): each a
// fixed PromQL over the store's series, in base units (seconds, ratios 0–1,
// pressure in percent), keyed by the CI it is about, with the class it applies
// to and its default threshold (D6's per-class defaults, static, O6). A module
// declares a threshold on one of these names (`performance.thresholds`), an
// ADR-039 rule with `source: metrics` names one, health-manager's `assess`
// judges them. scripts/tappaas-alert-rules.py carries the same table for the
// rule renderer; a test holds the two equal.

export interface PerfSignal {
  name: string;
  label: string; // in the operator's words
  unit: "s" | "ratio" | "percent";
  classes: string[]; // the CI classes it is about
  by: string[]; // the labels a site-wide answer is keyed by
  expr: string; // __SEL__ is the label selector
  defaults: { warning: number; critical: number; for: string } | null; // null: only when declared
}

export const SIGNAL_SELECTOR = "__SEL__";

export const PERF_SIGNALS: PerfSignal[] = [
  { name: "pool_write_latency_seconds", label: "write latency", unit: "s", classes: ["storage-pool"], by: ["tappaas_ci_id", "pool"],
    expr: "max by (tappaas_ci_id, pool) (tappaas_zpool_write_wait_seconds{__SEL__})", defaults: { warning: 0.025, critical: 0.1, for: "15m" } },
  { name: "pool_read_latency_seconds", label: "read latency", unit: "s", classes: ["storage-pool"], by: ["tappaas_ci_id", "pool"],
    expr: "max by (tappaas_ci_id, pool) (tappaas_zpool_read_wait_seconds{__SEL__})", defaults: null },
  // A guest waiting for CPU its node gives others: Proxmox's CPU pressure of the guest, the steal it sees.
  { name: "cpu_pressure_percent", label: "CPU pressure (steal)", unit: "percent", classes: ["vm", "lxc"], by: ["tappaas_ci_id"],
    expr: "max by (tappaas_ci_id) (proxmox_vm_pressurecpusome{__SEL__})", defaults: { warning: 20, critical: 50, for: "15m" } },
  { name: "memory_pressure_percent", label: "memory pressure", unit: "percent", classes: ["vm", "lxc"], by: ["tappaas_ci_id"],
    expr: "max by (tappaas_ci_id) (proxmox_vm_pressurememorysome{__SEL__})", defaults: { warning: 10, critical: 25, for: "15m" } },
  { name: "io_pressure_percent", label: "I/O pressure", unit: "percent", classes: ["vm", "lxc"], by: ["tappaas_ci_id"],
    expr: "max by (tappaas_ci_id) (proxmox_vm_pressureiosome{__SEL__})", defaults: { warning: 20, critical: 40, for: "15m" } },
  { name: "node_memory_pressure_percent", label: "memory pressure", unit: "percent", classes: ["machine"], by: ["tappaas_ci_id"],
    expr: 'max by (tappaas_ci_id) (tappaas_node_psi_some_avg60{__SEL__, resource="memory"})', defaults: { warning: 10, critical: 25, for: "15m" } },
  { name: "node_io_pressure_percent", label: "I/O pressure", unit: "percent", classes: ["machine"], by: ["tappaas_ci_id"],
    expr: 'max by (tappaas_ci_id) (tappaas_node_psi_some_avg60{__SEL__, resource="io"})', defaults: { warning: 20, critical: 40, for: "15m" } },
  { name: "http_p95_seconds", label: "response time (p95)", unit: "s", classes: ["proxy-route"], by: ["tappaas_ci_id"],
    expr: "histogram_quantile(0.95, sum by (tappaas_ci_id, le) (rate(caddy_http_request_duration_seconds_bucket{__SEL__}[5m])))", defaults: { warning: 1.5, critical: 5, for: "15m" } },
  { name: "http_5xx_ratio", label: "server errors (5xx)", unit: "ratio", classes: ["proxy-route"], by: ["tappaas_ci_id"],
    expr: 'sum by (tappaas_ci_id) (rate(caddy_http_request_duration_seconds_count{__SEL__, code="5xx"}[5m])) / sum by (tappaas_ci_id) (rate(caddy_http_request_duration_seconds_count{__SEL__}[5m]))', defaults: { warning: 0.01, critical: 0.05, for: "15m" } },
  { name: "probe_seconds", label: "response time from inside", unit: "s", classes: ["proxy-route"], by: ["tappaas_ci_id"],
    expr: "max by (tappaas_ci_id) (probe_duration_seconds{__SEL__})", defaults: null },
];

export const signalNamed = (name: string): PerfSignal | undefined => PERF_SIGNALS.find((s) => s.name === name);

export function signalExpr(s: PerfSignal, selector: string): string {
  return s.expr.split(SIGNAL_SELECTOR).join(selector);
}

/** "15m" → seconds; null when it is not a duration. */
export function durationSeconds(d: string): number | null {
  const m = /^([0-9]+)(s|m|h)$/.exec(d);
  return m ? Number(m[1]) * (m[2] === "h" ? 3600 : m[2] === "m" ? 60 : 1) : null;
}

/** A value as the operator reads it, in the signal's unit. */
export function signalValue(s: PerfSignal, v: number): string {
  if (s.unit === "s") return v < 1 ? `${Math.round(v * 1000)} ms` : `${v.toFixed(1)} s`;
  if (s.unit === "ratio") return `${(v * 100).toFixed(v < 0.1 ? 1 : 0)} %`;
  return `${v.toFixed(v < 10 ? 1 : 0)} %`;
}
