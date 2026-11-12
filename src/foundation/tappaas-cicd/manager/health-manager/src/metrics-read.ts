// metrics-read.ts — health-manager's reads of the metrics store (ADR-046 D6):
// the logging VM's Prometheus at :3121 (and its 90-day trends under /trends/),
// with the mothership's admin credential — the endpoint and credential the
// console's performance reads use. Synchronous (curl), like assess's other
// sources; every failure is null, never an exception: a store that does not
// answer means "not looked", and the conditions it set stand.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { spawnGuarded } from "../../../lib/ts/src/exec";

export interface Sample {
  metric: Record<string, string>;
  value: number;
}

export interface MetricsReader {
  /** An instant query; null when the store did not answer or refused it. */
  instant(expr: string, trends?: boolean): Sample[] | null;
}

export interface MetricsEndpoint {
  url: string;
  user: string;
  passwordFile: string;
}

export function metricsEndpoint(configDir: string, env: Record<string, string | undefined> = process.env): MetricsEndpoint | null {
  const home = env.HOME ?? "/home/tappaas";
  const passwordFile = env.HEALTH_METRICS_PASSWORD_FILE ?? env.LOG_SHIPPING_ADMIN_FILE ?? join(home, ".loki-admin-password");
  if (!existsSync(join(configDir, "logging.json")) || !existsSync(passwordFile)) return null;
  return { url: env.HEALTH_METRICS_URL ?? "https://logging.mgmt.internal:3121", user: "tappaas", passwordFile };
}

/** The store's answer as samples; null when it is not a success. */
export function parseVector(text: string): Sample[] | null {
  try {
    const doc = JSON.parse(text) as { status?: string; data?: { result?: { metric?: Record<string, string>; value?: [number, string] }[] } };
    if (doc.status !== "success" || !Array.isArray(doc.data?.result)) return null;
    return doc.data!.result!.map((r) => ({ metric: r.metric ?? {}, value: Number(r.value?.[1]) })).filter((s) => Number.isFinite(s.value));
  } catch {
    return null;
  }
}

export function curlReader(ep: MetricsEndpoint, run: (args: string[], input: string) => { rc: number; stdout: string } = curlRun): MetricsReader {
  return {
    instant(expr, trends = false) {
      let pw: string;
      try {
        pw = readFileSync(ep.passwordFile, "utf8").trim();
      } catch {
        return null;
      }
      const base = trends ? `${ep.url.replace(/\/+$/, "")}/trends` : ep.url.replace(/\/+$/, "");
      // The credential on stdin (curl -K -), never in argv where ps shows it.
      const r = run(["-sf", "--max-time", "20", "-K", "-", "--data-urlencode", `query=${expr}`, `${base}/api/v1/query`], `user = "${ep.user}:${pw.replace(/["\\]/g, "\\$&")}"\n`);
      return r.rc === 0 ? parseVector(r.stdout) : null;
    },
  };
}

function curlRun(args: string[], input: string): { rc: number; stdout: string } {
  const r = spawnGuarded("curl", args, { encoding: "utf8", input, timeout: 30_000 });
  return { rc: r.status ?? 1, stdout: String(r.stdout ?? "") };
}
