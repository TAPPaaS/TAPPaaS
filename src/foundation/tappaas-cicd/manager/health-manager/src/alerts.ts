// alerts.ts — the site's open and recent alerts, placed on what they are about
// (ADR-039 D8).
//
// A mail is not the only way to see an alert:
//   open    a `state` alert firing now — Grafana's alertmanager on the logging
//           VM holds them, labels and all (asked over SSH, as admin, from that
//           VM's localhost: the password never leaves it);
//   recent  an `event` alert of the last 24 h — an event "fires" only for its
//           window, so "open" would hide it within minutes; the mothership's
//           tappaas-alert-receiver records every alert it is posted
//           (/var/lib/tappaas/alerts.jsonl).
// Each is placed by its labels: `module` for a module's rule; `host` resolved
// to its instance through config/ (vmname), a node to its pvehost instance.
// The heartbeat is never an alert here.

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { ssh } from "../../../lib/ts/src/cluster";
import { readModuleJson } from "./config";
import { CheckResult, CheckRow, CheckSubject } from "./types";

export const ALERTS_LOG = process.env.TAPPAAS_ALERTS_LOG ?? "/var/lib/tappaas/alerts.jsonl";
const DAY_MS = 24 * 3600 * 1000;

export interface AlertItem {
  state: "open" | "recent";
  alertname: string;
  host: string;
  module: string;
  kind: string;
  labels: Record<string, string>;
  since: string;
  subject: CheckSubject | null;
}

// Labels Grafana, the rules and the receiver use for themselves.
const PLAIN = new Set(["alertname", "host", "kind", "module", "bundle", "lines", "grafana_folder"]);

function own(labels: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(labels)) if (!PLAIN.has(k) && !k.startsWith("__") && v) out[k] = v;
  return out;
}

// Where an alert belongs: the instance whose vmname (or, without one, its
// config name) is the alert's host — a node when that instance is a pvehost —
// else the rule's module.
export function placeAlert(host: string, module: string, configDir: string): CheckSubject | null {
  const short = host.split(".")[0];
  if (short && /^[A-Za-z0-9][A-Za-z0-9-]*$/.test(short) && existsSync(configDir)) {
    for (const f of readdirSync(configDir)) {
      if (!f.endsWith(".json")) continue;
      const inst = f.slice(0, -5);
      const raw = readModuleJson(join(configDir, f));
      if (!raw || String(raw.status ?? "").toLowerCase() === "archived") continue;
      const vm = typeof raw.vmname === "string" && raw.vmname ? raw.vmname : inst;
      if (vm !== short) continue;
      const src = String(raw.moduleSource ?? raw.location ?? "").replace(/\/+$/, "");
      if (!src) continue;
      return src.endsWith("/pvehost") ? { kind: "node", name: inst } : { kind: "module", name: inst };
    }
  }
  return module ? { kind: "module", name: module } : null;
}

// The open state alerts, from Grafana. null when it cannot be asked.
export function fetchGrafanaAlerts(configDir: string): Array<Record<string, unknown>> | null {
  const cfg = readModuleJson(join(configDir, "logging.json"));
  if (!cfg) return null;
  const host = `${typeof cfg.vmname === "string" ? cfg.vmname : "logging"}.${typeof cfg.zone0 === "string" ? cfg.zone0 : "mgmt"}.internal`;
  const r = ssh(
    "tappaas",
    host,
    "P=$(sudo cat /etc/secrets/grafana-admin-password) && curl -sf --max-time 15 -u \"admin:$P\" " +
      "'http://127.0.0.1:3000/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false'",
  );
  if (!r.ran || r.rc !== 0) return null;
  try {
    const v = JSON.parse(r.stdout) as unknown;
    return Array.isArray(v) ? (v as Array<Record<string, unknown>>) : null;
  } catch {
    return null;
  }
}

export function openAlerts(raw: Array<Record<string, unknown>>, configDir: string): AlertItem[] {
  const out: AlertItem[] = [];
  for (const a of raw) {
    const labels = (a.labels ?? {}) as Record<string, string>;
    if (labels.kind === "heartbeat" || labels.alertname === "Heartbeat") continue;
    if (labels.kind && labels.kind !== "state") continue; // an event is "recent", from the record
    out.push({
      state: "open",
      alertname: labels.alertname ?? "",
      host: labels.host ?? "",
      module: labels.module ?? "",
      kind: labels.kind ?? "",
      labels: own(labels),
      since: String(a.startsAt ?? ""),
      subject: placeAlert(labels.host ?? "", labels.module ?? "", configDir),
    });
  }
  return out;
}

// The receiver's record: event alerts that fired in the last day, newest first,
// one per alert and host.
export function recentEvents(path: string, configDir: string, nowMs: number): AlertItem[] {
  if (!existsSync(path)) return [];
  const seen = new Map<string, AlertItem>();
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let r: Record<string, unknown>;
    try {
      r = JSON.parse(line) as Record<string, unknown>;
    } catch {
      continue;
    }
    if (r.kind !== "event" || r.status !== "firing") continue;
    const t = Date.parse(String(r.time ?? ""));
    if (!Number.isFinite(t) || nowMs - t > DAY_MS) continue;
    const labels = (r.labels ?? {}) as Record<string, string>;
    const key = `${r.alertname}|${r.host}|${JSON.stringify(labels)}`;
    seen.set(key, {
      state: "recent",
      alertname: String(r.alertname ?? ""),
      host: String(r.host ?? ""),
      module: String(r.module ?? ""),
      kind: "event",
      labels,
      since: String(r.startsAt || r.time || ""),
      subject: placeAlert(String(r.host ?? ""), String(r.module ?? ""), configDir),
    });
  }
  return [...seen.values()].sort((a, b) => b.since.localeCompare(a.since));
}

export interface AlertFilter {
  module?: string;
  host?: string;
  node?: string;
}

export function filterAlerts(items: AlertItem[], f: AlertFilter): AlertItem[] {
  return items.filter((a) =>
    (!f.module || a.module === f.module || (a.subject?.kind === "module" && a.subject.name === f.module)) &&
    (!f.host || a.host === f.host || a.host.split(".")[0] === f.host) &&
    (!f.node || (a.subject?.kind === "node" && a.subject.name === f.node)));
}

export function alertLine(a: AlertItem): string {
  const where = a.host ? ` on ${a.host}` : "";
  const extra = Object.entries(a.labels).map(([k, v]) => `${k} ${v}`).join(", ");
  const of = a.module ? `  [${a.module}]` : "";
  return `${a.state.padEnd(7)}${a.alertname}${where}${extra ? ` (${extra})` : ""}  since ${a.since}${of}`;
}

// The gate: every open state alert, as a WARN — the mail already went; this
// keeps it in the health report until it clears. Never FAIL.
export function checkOpenAlerts(configDir: string, fetch: (d: string) => Array<Record<string, unknown>> | null = fetchGrafanaAlerts): CheckResult {
  if (!existsSync(join(configDir, "logging.json"))) {
    return { name: "open-alerts", status: "skip", detail: "logging is not deployed" };
  }
  const raw = fetch(configDir);
  if (raw === null) return { name: "open-alerts", status: "skip", detail: "Grafana's alerts could not be read" };
  const open = openAlerts(raw, configDir);
  if (open.length === 0) return { name: "open-alerts", status: "pass", detail: "no open alerts" };
  const rows: CheckRow[] = open.map((a) => ({ status: "warn", text: alertLine(a).trimStart(), ...(a.subject ? { subject: a.subject } : {}) }));
  return { name: "open-alerts", status: "warn", detail: `${open.length} open alert(s) — health-manager alerts`, rows };
}
