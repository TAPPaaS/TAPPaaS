// assess-validate.ts — `validate` as a read (ADR-041 D2): the table of the last
// assess, each gate as it stood, with the conditions on top. A row whose
// condition is derived, acknowledged or in maintenance no longer fails, and says
// why; what only a source beyond the gates found gets a line of its own. The
// verdict is the conditions': exit 1 on any that counts.

import { CmdbItem, Condition, SiteIndex, conditionsOf, counts, failing, silenced } from "./assess-model";
import { GATES } from "./assess-sources";
import { CheckResult, CheckRow, CheckStatus, HealthReport } from "./types";

export interface Assessed { time: string; gates: CheckResult[] }

export const assessmentOf = (objects: CmdbItem[]): Assessed | null => {
  const a = objects.find((o) => o.class === "site")?.attributes.assessment as Assessed | undefined;
  return a && typeof a.time === "string" && Array.isArray(a.gates) ? a : null;
};

const why = (c: Condition, nowMs: number, idx: SiteIndex): string => {
  if (c.derived) return `follows from ${idx.byId.get(c.rootCause ?? "")?.name ?? "another object"}`;
  return c.acknowledged && silenced({ ...c, maintenance: null }, nowMs) ? `acknowledged by ${c.acknowledged.by}` : "in maintenance";
};

const rank: Record<CheckStatus, number> = { skip: 0, pass: 0, warn: 1, fail: 2 };

/** The report `validate` prints, from what the CMDB holds. */
export function readValidate(idx: SiteIndex, assessed: Assessed, nowMs: number): HealthReport {
  const cond = (o: CmdbItem | null | undefined, type: string): Condition | undefined => (o ? conditionsOf(o).find((c) => c.type === type) : undefined);

  const overlay = (gate: string, rows: CheckRow[] | undefined): CheckRow[] | undefined =>
    rows?.map((r): CheckRow => {
      const g = GATES[gate];
      if (r.status !== "fail" || !g) return r;
      const c = cond((r.subject ? idx.resolve(r.subject) : null) ?? idx.site, g.type);
      if (!c || !failing(c) || (!c.derived && !silenced(c, nowMs))) return r;
      return { ...r, status: "warn", text: `${r.text} (${why(c, nowMs, idx)})` };
    });

  const checks: CheckResult[] = assessed.gates.map((g) => {
    const rows = overlay(g.name, g.rows);
    const findings = overlay(g.name, g.findings);
    const all = [...(rows ?? []), ...(findings ?? [])];
    const fell = g.status === "fail" && all.length > 0 && !all.some((r) => r.status === "fail");
    return { ...g, status: fell ? "warn" : g.status, ...(rows ? { rows } : {}), ...(findings ? { findings } : {}) };
  });

  // What no gate prints: thresholds over the CMDB, and alerts of the last day.
  const extra: CheckRow[] = [];
  let counted = 0;
  for (const o of idx.objects) {
    for (const c of conditionsOf(o)) {
      if (counts(c, nowMs)) counted++;
      if (!failing(c) || c.type === "impact" || c.derived) continue;
      if (Object.values(GATES).some((g) => g.reason === c.reason) || /^(sweep|cve)-/.test(c.reason)) continue;
      const status: CheckStatus = counts(c, nowMs) ? "fail" : "warn";
      extra.push({ status, text: `${o.class}/${o.name}: ${c.message || c.reason}${silenced(c, nowMs) ? ` (${why(c, nowMs, idx)})` : ""}` });
    }
  }
  const worst = extra.reduce<CheckStatus>((w, r) => (rank[r.status] > rank[w] ? r.status : w), "pass");
  checks.push({
    name: "conditions",
    status: worst,
    detail: extra.length ? `${extra.length} beyond the gates — health-manager list` : "nothing beyond the gates",
    ...(extra.length ? { rows: extra } : {}),
  });

  // The verdict is the conditions': a gate whose failure counts for nothing is no failure.
  const settled = counted === 0 ? checks.map((c) => (c.status === "fail" ? { ...c, status: "warn" as CheckStatus } : c)) : checks;
  return { checks: settled, failed: Math.max(settled.filter((c) => c.status === "fail").length, counted > 0 ? 1 : 0) };
}
