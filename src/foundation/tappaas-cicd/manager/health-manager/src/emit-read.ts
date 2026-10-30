// emit-read.ts — the read side of ADR-041 D2: show, list, roots and history,
// from the conditions in the CMDB. Each builds a document (what --json prints)
// and its table apart, so a test can read either.

import { silenced } from "./ack";
import { Condition, HealthObject, Period, RootEntry, Status, conditionsOf, rootsOf } from "./emit-cmdb";
import { transitions } from "./emit";

const RANK: Record<Status, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

const flags = (c: Condition, now: Date): string =>
  [c.acknowledged ? (c.acknowledged.via ? "ack(root)" : "ack") : "", c.maintenance && silenced(c, now) ? "maintenance" : "", c.flapping ? "flapping" : "", c.derived ? "derived" : ""]
    .filter(Boolean)
    .join(",");

function table(rows: string[][]): string[] {
  const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => r[i].length)));
  return rows.map((r) => r.map((v, i) => v.padEnd(widths[i])).join("  ").trimEnd());
}

export interface ShowDoc {
  id: string;
  class: string;
  name: string;
  conditions: Condition[];
  rootCauses: string[]; // what it is a symptom of
  impacts: { id: string; class: string; name: string }[]; // when it is a root
  isRoot: boolean;
}

const named = (o: HealthObject): { id: string; class: string; name: string } => ({ id: o.id, class: o.class, name: o.name });

export const impactedBy = (objects: HealthObject[], id: string): HealthObject[] =>
  objects.filter((o) => o.id !== id && conditionsOf(o).some((c) => c.type === "impact" && c.status !== "ok" && rootsOf(c).includes(id)));

export function showDoc(o: HealthObject, objects: HealthObject[], roots: RootEntry[]): ShowDoc {
  const conditions = conditionsOf(o);
  return {
    ...named(o),
    conditions,
    rootCauses: [...new Set(conditions.flatMap(rootsOf))],
    impacts: impactedBy(objects, o.id).map(named),
    isRoot: roots.some((r) => r.id === o.id),
  };
}

export function showLines(d: ShowDoc, objects: HealthObject[], now: Date): string[] {
  const label = (id: string): string => {
    const o = objects.find((x) => x.id === id);
    return o ? `${o.class}/${o.name}` : id;
  };
  const out = [`${d.class}/${d.name}  ${d.id}`];
  if (!d.conditions.length) out.push("no conditions yet");
  else {
    out.push(...table([["TYPE", "STATUS", "SINCE", "REASON", "FLAGS"], ...d.conditions.map((c) => [c.type, c.status, c.since ?? "", c.reason ?? "", flags(c, now)])]));
  }
  for (const c of d.conditions) {
    if (c.message) out.push(`  ${c.type}: ${c.message}`);
    const a = c.acknowledged;
    if (a) out.push(`  ${c.type}: acknowledged by ${a.by}${a.note ? `: ${a.note}` : ""}${a.until ? `, until ${a.until}` : ""}${a.sticky ? ", sticky" : ""}${a.via ? `, with ${a.via.map(label).join(", ")}` : ""}`);
    if (c.maintenance) out.push(`  ${c.type}: in maintenance until ${c.maintenance.until}${c.maintenance.note ? `: ${c.maintenance.note}` : ""}`);
  }
  if (d.rootCauses.length) out.push(`root cause: ${d.rootCauses.map(label).join(", ")}`);
  if (d.isRoot) out.push(`a root cause; impacts ${d.impacts.length}: ${d.impacts.map((i) => `${i.class}/${i.name}`).join(", ") || "nothing else"}`);
  return out;
}

export interface ListFilter {
  type?: string;
  status?: string;
  rootCauses?: boolean;
}

export interface ListRow extends Condition {
  id: string;
  class: string;
  name: string;
}

/** A row per condition, worst first. Without --status, what is not ok. */
export function listRows(objects: HealthObject[], roots: RootEntry[], f: ListFilter): ListRow[] {
  const rows: ListRow[] = [];
  for (const o of objects) {
    if (f.rootCauses && !roots.some((r) => r.id === o.id)) continue;
    for (const c of conditionsOf(o)) {
      if (f.type && c.type !== f.type) continue;
      if (f.status ? c.status !== f.status : c.status === "ok") continue;
      if (f.rootCauses && !roots.some((r) => r.id === o.id && (!r.type || r.type === c.type))) continue;
      rows.push({ ...c, id: o.id, class: o.class, name: o.name });
    }
  }
  return rows.sort((a, b) => RANK[b.status] - RANK[a.status] || a.class.localeCompare(b.class) || a.name.localeCompare(b.name) || a.type.localeCompare(b.type));
}

export function listLines(rows: ListRow[], now: Date): string[] {
  if (!rows.length) return ["nothing to list"];
  return table([["OBJECT", "TYPE", "STATUS", "SINCE", "REASON", "FLAGS"], ...rows.map((r) => [`${r.class}/${r.name}`, r.type, r.status, r.since ?? "", r.reason ?? "", flags(r, now)])]);
}

export interface RootDoc {
  id: string;
  class: string;
  name: string;
  type: string;
  impactedCount: number;
  impacted: { id: string; class: string; name: string }[];
}

export function rootDocs(objects: HealthObject[], roots: RootEntry[]): RootDoc[] {
  return roots
    .map((r) => {
      const o = objects.find((x) => x.id === r.id);
      const impacted = impactedBy(objects, r.id).map(named);
      return { id: r.id, class: o?.class ?? "", name: o?.name ?? r.id, type: r.type ?? "", impactedCount: r.impactedCount ?? impacted.length, impacted };
    })
    .sort((a, b) => b.impactedCount - a.impactedCount);
}

export function rootLines(docs: RootDoc[]): string[] {
  if (!docs.length) return ["no root causes"];
  const out: string[] = [];
  for (const d of docs) {
    out.push(`${d.class}/${d.name}  ${d.type}  impacts ${d.impactedCount}`);
    for (const i of d.impacted) out.push(`  ${i.class}/${i.name}`);
  }
  return out;
}

export interface HistoryRow {
  at: string;
  type: string;
  from: Status;
  to: Status;
  reason: string;
  message: string;
}

export function historyRows(periods: Period[], since?: string): HistoryRow[] {
  const from = since ? Date.parse(since) : -Infinity;
  return transitions(periods)
    .filter((t) => Date.parse(t.at) > from)
    .map((t) => ({ at: t.at, type: t.type, from: t.from, to: t.to, reason: t.after?.reason ?? "cleared", message: (t.after ?? t.before)?.message ?? "" }));
}

export function historyLines(rows: HistoryRow[]): string[] {
  if (!rows.length) return ["no transitions"];
  return table([["AT", "TYPE", "FROM", "TO", "REASON"], ...rows.map((r) => [r.at, r.type, r.from, r.to, r.reason])]);
}
