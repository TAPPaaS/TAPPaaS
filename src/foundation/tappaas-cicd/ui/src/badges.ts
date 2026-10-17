// badges.ts — the Modules list: each deployed module with the badges the spike's
// mockups put on it (run state, health, backup, CVE, maturity) and the health
// findings that name it, so its page and the Attention list agree.

import { BackupRow, Gate, GateFinding, HealthDoc, ModuleRow } from "./model";

export type Level = "fail" | "warn" | "pass" | "unknown";

export interface ModuleFinding {
  gate: string;
  status: string;
  text: string;
}

export interface ModuleSummary extends ModuleRow {
  badges: {
    run: "running" | "stopped" | "none";
    health: Level;
    backup: "covered" | "disabled" | "not-in-job" | "not-opted" | "unknown";
    cve: "act" | "ok" | "unknown";
    maturity: string | null;
  };
  findings: ModuleFinding[];
}

const rank: Record<string, number> = { fail: 2, warn: 1, pass: 0 };

// The findings of every gate that name this module.
export function findingsFor(health: HealthDoc | null, module: string): ModuleFinding[] {
  const out: ModuleFinding[] = [];
  for (const g of health?.gates ?? []) {
    for (const f of g.findings) {
      if (f.subject?.kind === "module" && f.subject.name === module) out.push({ gate: g.name, status: f.status, text: f.text });
    }
  }
  return out;
}

export function backupBadge(row: BackupRow | undefined): ModuleSummary["badges"]["backup"] {
  if (!row) return "unknown";
  if (row.enabled === false) return "disabled";
  if (row.optedIn === false) return "not-opted";
  if (row.inPbsJob === false) return "not-in-job";
  return "covered";
}

export function moduleSummaries(modules: ModuleRow[], health: HealthDoc | null, backup: BackupRow[] | null): ModuleSummary[] {
  const byModule = new Map((backup ?? []).map((b) => [b.module, b]));
  return modules.map((m) => {
    const findings = findingsFor(health, m.name);
    const gates = findings.filter((f) => f.gate !== "cve-status");
    let worst = -1;
    for (const f of gates) worst = Math.max(worst, rank[f.status] ?? -1);
    const health_: Level = health === null ? "unknown" : worst === 2 ? "fail" : worst === 1 ? "warn" : "pass";
    const cve = health === null || !health.gates.some((g) => g.name === "cve-status" && g.status !== "skip")
      ? "unknown"
      : findings.some((f) => f.gate === "cve-status" && f.status !== "pass") ? "act" : "ok";
    return {
      ...m,
      badges: {
        run: m.running === "running" ? "running" : m.running === "-" || m.vmid === null ? "none" : "stopped",
        health: health_,
        backup: backup === null ? "unknown" : backupBadge(byModule.get(m.name)),
        cve,
        maturity: m.status,
      },
      findings,
    };
  });
}

// Attention (the Overview's inbox): every FAIL and WARN finding, worst first, each
// with the object it is about; a failing or warning gate with no per-object
// finding is one row of its own.
export interface AttentionRow {
  gate: string;
  level: "fail" | "warn";
  text: string;
  subject: { kind: string; name: string } | null;
}

export function attention(health: HealthDoc | null): AttentionRow[] {
  const rows: AttentionRow[] = [];
  for (const g of health?.gates ?? []) {
    if (g.status !== "fail" && g.status !== "warn") continue;
    const bad = g.findings.filter((f: GateFinding) => f.status === "fail" || f.status === "warn");
    if (bad.length === 0) rows.push({ gate: g.name, level: g.status as "fail" | "warn", text: g.detail, subject: null });
    for (const f of bad) rows.push({ gate: g.name, level: f.status as "fail" | "warn", text: f.text.replace(/\s+/g, " ").trim(), subject: f.subject });
  }
  return rows.sort((a, b) => (rank[b.level] ?? 0) - (rank[a.level] ?? 0));
}

// The Overview strip: one card per thing an operator checks in the morning.
export function gateByName(health: HealthDoc | null, name: string): Gate | null {
  return health?.gates.find((g) => g.name === name) ?? null;
}
