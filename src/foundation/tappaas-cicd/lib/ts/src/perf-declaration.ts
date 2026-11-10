// perf-declaration.ts — a module's performance declaration (ADR-046 D5): the
// exporters its guest exposes, whether it emits traces, and the thresholds of
// its signals, under `performance` in the module JSON beside the instance's
// own `performance.level` / `performance.resolution`. Foundation modules only
// for now (O8): a module whose source is not official may not declare one.
// Pure: the module JSON in, findings out. module-manager's `validate` and the
// install-time lint (validate-module-tier-source.sh, the same rules in jq) use it.

import { PERF_SIGNALS } from "./perf-signals";

export interface PerfExporter {
  name: string;
  port: number;
  path?: string;
  level?: "basic" | "service";
  keep: string[];
}

export interface PerfThreshold {
  signal: string;
  warning?: number;
  critical?: number;
  for?: string;
}

export interface PerfDeclaration {
  exporters?: PerfExporter[];
  traces?: { otlp: boolean; level?: "trace"; note?: string };
  thresholds?: PerfThreshold[];
}

// The instance's own keys, owned by module-manager (P2), not the declaration's.
const INSTANCE_KEYS = ["level", "resolution"];
const DECLARATION_KEYS = ["exporters", "traces", "thresholds"];

const NAME = /^[a-z][a-z0-9-]{0,40}$/;
const GLOB = /^[A-Za-z_:*][A-Za-z0-9_:*]{0,120}$/;
const PATH = /^\/[A-Za-z0-9/_.-]{0,100}$/;
const SIGNAL = /^[a-z][a-z0-9_]{0,60}$/;
const DURATION = /^[0-9]+(s|m|h)$/;

export function declares(perf: unknown): boolean {
  return !!perf && typeof perf === "object" && DECLARATION_KEYS.some((k) => k in (perf as object));
}

// Findings for one module JSON: errors refuse the install, warnings do not.
// Software known not to emit OpenTelemetry spans, by the module that ships it
// (ADR-046 P6): a declaration of traces.otlp there promises spans that never
// come. Taken out when the software gains an OTLP exporter.
export const NO_OTLP: Record<string, string> = {
  identity: "authentik ships no OpenTelemetry exporter (Sentry only)",
};

export function perfDeclarationFindings(module: { name?: string | null; source?: string | null; performance?: unknown }): { errors: string[]; warnings: string[] } {
  const errors: string[] = [];
  const warnings: string[] = [];
  const p = module.performance;
  if (p === undefined || p === null) return { errors, warnings };
  if (typeof p !== "object" || Array.isArray(p)) return { errors: ["performance must be an object"], warnings };
  const perf = p as Record<string, unknown>;
  for (const k of Object.keys(perf)) {
    if (!INSTANCE_KEYS.includes(k) && !DECLARATION_KEYS.includes(k)) errors.push(`performance.${k} is not a performance key (exporters, traces, thresholds; level and resolution are the instance's)`);
  }
  if (!declares(perf)) return { errors, warnings };
  const source = module.source ?? "official";
  if (source !== "official") {
    errors.push(`a ${source} module may not declare performance exporters, traces or thresholds yet: only foundation modules do, until the format has settled`);
    return { errors, warnings };
  }

  if (perf.exporters !== undefined) {
    if (!Array.isArray(perf.exporters)) errors.push("performance.exporters must be a list");
    else {
      const names = new Set<string>();
      const ports = new Set<number>();
      perf.exporters.forEach((e: unknown, i: number) => {
        const at = `performance.exporters[${i}]`;
        if (!e || typeof e !== "object") return void errors.push(`${at} must be an object`);
        const x = e as Record<string, unknown>;
        if (typeof x.name !== "string" || !NAME.test(x.name)) errors.push(`${at}.name must be a short lower-case name`);
        else if (names.has(x.name)) errors.push(`${at}.name ${x.name} is declared twice`);
        else names.add(x.name);
        if (typeof x.port !== "number" || !Number.isInteger(x.port) || x.port < 1 || x.port > 65535) errors.push(`${at}.port must be a port number`);
        else if (ports.has(x.port)) errors.push(`${at}.port ${x.port} is declared twice`);
        else ports.add(x.port);
        if (x.path !== undefined && (typeof x.path !== "string" || !PATH.test(x.path))) errors.push(`${at}.path must be a URL path such as /metrics`);
        if (x.level !== undefined && x.level !== "basic" && x.level !== "service") errors.push(`${at}.level must be basic or service`);
        if (!Array.isArray(x.keep) || x.keep.length === 0) errors.push(`${at}.keep must list the metric names to keep (a module never ships all of an exporter)`);
        else for (const g of x.keep) if (typeof g !== "string" || !GLOB.test(g)) errors.push(`${at}.keep: '${String(g)}' is not a metric name or a name with *`);
        else if (g === "*" || /^\*+$/.test(g)) errors.push(`${at}.keep: '*' keeps everything; name the metrics`);
        for (const k of Object.keys(x)) if (!["name", "port", "path", "level", "keep"].includes(k)) errors.push(`${at}.${k} is not an exporter key`);
      });
    }
  }
  if (perf.traces !== undefined) {
    const t = perf.traces as Record<string, unknown> | null;
    if (!t || typeof t !== "object" || typeof t.otlp !== "boolean") errors.push("performance.traces must be {\"otlp\": true|false}");
    else if (t.level !== undefined && t.level !== "trace") errors.push("performance.traces.level is trace: traces are collected only while an object is traced");
    else {
      for (const k of Object.keys(t)) if (!["otlp", "level", "note"].includes(k)) errors.push(`performance.traces.${k} is not a traces key (otlp, level, note)`);
      if (t.note !== undefined && typeof t.note !== "string") errors.push("performance.traces.note is text");
      const why = module.name ? NO_OTLP[module.name] : undefined;
      if (t.otlp === true && why) warnings.push(`performance.traces.otlp is true, but ${why}: no spans will arrive — set it false until it does`);
    }
  }
  if (perf.thresholds !== undefined) {
    if (!Array.isArray(perf.thresholds)) errors.push("performance.thresholds must be a list");
    else
      perf.thresholds.forEach((th: unknown, i: number) => {
        const at = `performance.thresholds[${i}]`;
        const x = (th && typeof th === "object" ? th : {}) as Record<string, unknown>;
        if (typeof x.signal !== "string" || !SIGNAL.test(x.signal)) errors.push(`${at}.signal must name a signal such as http_p95_seconds`);
        else if (!PERF_SIGNALS.some((s) => s.name === x.signal)) errors.push(`${at}.signal ${x.signal} is not a signal TAPPaaS measures (${PERF_SIGNALS.map((s) => s.name).join(", ")})`);
        const w = x.warning;
        const c = x.critical;
        if (w === undefined && c === undefined) errors.push(`${at} needs a warning or a critical value`);
        if ((w !== undefined && typeof w !== "number") || (c !== undefined && typeof c !== "number")) errors.push(`${at}: warning and critical are numbers`);
        else if (typeof w === "number" && typeof c === "number" && w >= c) warnings.push(`${at}: warning ${w} is not below critical ${c}`);
        if (x.for !== undefined && (typeof x.for !== "string" || !DURATION.test(x.for))) errors.push(`${at}.for must be a duration such as 15m`);
      });
  }
  return { errors, warnings };
}
