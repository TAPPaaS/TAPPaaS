// rules-tools.ts — `rules explain` and `rules simulate`: the derivation run
// again on the current snapshot, with tracing on, or with extra failures, an
// extra rule file or a rule taken out. Nothing is written.
//
// The snapshot is what the CMDB holds now: the objects, the relations, and each
// object's source conditions (what derive computes is left out and computed
// again).

import { CmdbItem, CmdbRel, Condition, RANK, SOURCE, conditionsOf, failing, isDerivedKind } from "./assess-model";
import { Derivation, derive } from "./derive";
import { RulesDoc } from "./rules";
import { sentence } from "./rule-text";
import { ConditionStatus, ConditionType } from "../../../lib/ts/src/health-rules";
import { HealthRecord } from "../../../lib/ts/src/health-records";
import { Classified, classify } from "./classify";
import { NotifyRules, notifyOf, notifyRecord } from "./notices";

export interface Snapshot { objects: CmdbItem[]; relations: CmdbRel[] }

/** Each object's source conditions as stored: what a derivation starts from. */
export function snapshotSource(objects: CmdbItem[]): Map<string, Condition[]> {
  const out = new Map<string, Condition[]>();
  for (const o of objects) {
    const cs = conditionsOf(o).filter((c) => !isDerivedKind(c)).map((c) => ({ ...c }));
    if (cs.length) out.set(o.id, cs);
  }
  return out;
}

export const findObject = (objects: CmdbItem[], ref: string): CmdbItem | undefined =>
  objects.find((o) => o.id === ref) ?? objects.find((o) => o.name === ref) ?? objects.find((o) => `${o.class}/${o.name}` === ref);

const label = (o: CmdbItem | undefined, id: string): string => (o ? `${o.class} ${o.name}` : id);

export interface ExplainedCondition {
  type: string;
  status: string;
  reason: string;
  how: "root" | "derived" | "sum" | "covered" | "impact" | "follows" | "roll-up" | "ok";
  rootCause?: string;
  rule?: string;
  ruleText?: string;
  path?: { from: string; to: string; relation?: string; status: string; type: string; rule: string; lost: { id: string; by: string; why: string }[] }[];
  impacts?: number;
}

/** For one object: each condition and how it came about. */
export function explainObject(snap: Snapshot, model: RulesDoc, now: string, ref: string): { object: CmdbItem; conditions: ExplainedCondition[] } {
  const o = findObject(snap.objects, ref);
  if (!o) throw new Error(`rules explain: no object ${ref} in the CMDB`);
  const d = derive(snap.objects, snapshotSource(snap.objects), snap.relations, model, now, { trace: true });
  const byId = new Map(snap.objects.map((x) => [x.id, x]));
  const recs = new Map(model.records.map((r) => [r.id, r]));
  const relOf = (a: string, b: string): string | undefined => snap.relations.find((r) => (r.from.id === a && r.to.id === b) || (r.from.id === b && r.to.id === a))?.type;
  const out: ExplainedCondition[] = [];
  for (const c of d.conditions.get(o.id) ?? []) {
    const base = { type: c.type, status: c.status, reason: c.reason };
    const withRule = (rule?: string): Partial<ExplainedCondition> => (rule ? { rule, ...(recs.has(rule) ? { ruleText: sentence(recs.get(rule)!) } : {}) } : {});
    if (c.type === "impact") {
      const root = d.rootCauses.find((r) => r.id === c.rootCause);
      const rootType = root?.type ?? (d.conditions.get(c.rootCause ?? "") ?? []).find((x) => failing(x) && !x.derived)?.type ?? "operational";
      const hops = c.rootCause ? d.why!.path(c.rootCause, rootType, o.id) : [];
      out.push({ ...base, how: "impact", rootCause: c.rootCause ?? undefined, ...withRule(c.rule), path: hops.map((h) => ({ from: label(byId.get(h.from), h.from), to: label(byId.get(h.to), h.to), relation: relOf(h.from, h.to), status: h.status, type: h.type, rule: h.rule, lost: h.lost })) });
    } else if (c.reason === "follows") out.push({ ...base, how: "follows", rootCause: c.rootCause ?? undefined, ...withRule(c.rule) });
    else if (c.reason === "roll-up") out.push({ ...base, how: "roll-up", ...withRule(c.rule) });
    else if (!failing(c)) out.push({ ...base, how: "ok" });
    else if (c.aggregate) out.push({ ...base, how: "sum" });
    else if (c.derived) out.push({ ...base, how: "derived", rootCause: c.rootCause ?? undefined, ...withRule(c.rule ?? d.why!.explainedBy.get(`${o.id}|${c.type}`)?.rule) });
    else if (c.rootCause) out.push({ ...base, how: "covered", rootCause: c.rootCause, ...withRule(c.rule) });
    else out.push({ ...base, how: "root", impacts: d.rootCauses.find((r) => r.id === o.id && r.type === c.type)?.impactedCount ?? 0 });
  }
  return { object: o, conditions: out };
}

/** `rules explain` as lines. */
export function explainLines(x: ReturnType<typeof explainObject>, objects: CmdbItem[]): string[] {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const lines = [`${x.object.class} ${x.object.name}`];
  if (!x.conditions.length) lines.push("  no condition");
  for (const c of x.conditions) {
    const head = `  ${c.type} ${c.status}${c.reason && c.reason !== "ok" ? ` (${c.reason})` : ""}`;
    const root = c.rootCause ? label(byId.get(c.rootCause), c.rootCause) : "";
    const rule = c.rule ? ` — ${c.rule}${c.ruleText ? `: ${c.ruleText}` : ""}` : "";
    switch (c.how) {
      case "root": lines.push(`${head}: a root cause, impacting ${c.impacts}`); break;
      case "derived": lines.push(`${head}: the same failure as ${root}, derived${rule}`); break;
      case "sum": lines.push(`${head}: a sum of others (a classify rule says so), never a root`); break;
      case "covered": lines.push(`${head}: its own, not a root while ${root} stands${rule}`); break;
      case "follows": lines.push(`${head}: follows its parent${rule}`); break;
      case "roll-up": lines.push(`${head}: a sum of its members${rule}`); break;
      case "ok": lines.push(head); break;
      case "impact":
        lines.push(`${head}: from ${root}`);
        for (const h of c.path ?? []) {
          lines.push(`    ${h.from} → ${h.to}${h.relation ? ` over ${h.relation}` : ""}: ${h.type} ${h.status} — ${h.rule}`);
          for (const l of h.lost) lines.push(`      lost: ${l.id} (${l.why === "overridden" ? "overridden by" : "less specific than"} ${l.by})`);
        }
        break;
    }
  }
  return lines;
}

export interface Failure { object: string; type: ConditionType; status: ConditionStatus }

/** "<object>[:type[:status]]", operational critical by default. */
export function parseFailure(s: string): Failure {
  const parts = s.split(":");
  // A name may itself hold a colon (a service, a port): the last two parts are
  // a type and a status only when they are one.
  const statuses = ["warning", "critical"];
  let status: ConditionStatus = "critical";
  let type: ConditionType = "operational";
  if (parts.length > 1 && statuses.includes(parts[parts.length - 1])) status = parts.pop() as ConditionStatus;
  const TYPES = ["operational", "drift", "capacity", "performance", "security", "maintenance", "backup"];
  if (parts.length > 1 && TYPES.includes(parts[parts.length - 1])) type = parts.pop() as ConditionType;
  return { object: parts.join(":"), type, status };
}

export interface SimResult {
  roots: { id: string; label: string; type: string; impacted: number }[];
  colours: Record<string, ConditionStatus>; // per object, its worst status
  derivation: Derivation;
}

const worstOf = (cs: Condition[]): ConditionStatus => cs.reduce<ConditionStatus>((w, c) => (RANK[c.status] > RANK[w] ? c.status : w), "ok");

/** The derivation with extra failures and the records changed as given. */
export function simulate(snap: Snapshot, model: RulesDoc, now: string, fails: Failure[], change: { with?: HealthRecord[]; without?: string[] } = {}): SimResult {
  const source = snapshotSource(snap.objects);
  for (const f of fails) {
    const o = findObject(snap.objects, f.object);
    if (!o) throw new Error(`rules simulate: no object ${f.object} in the CMDB`);
    const cs = (source.get(o.id) ?? []).filter((c) => c.type !== f.type);
    cs.push({ type: f.type, status: f.status, reason: "simulated", message: "simulated", since: now, lastChecked: now, source: SOURCE, derived: false, rootCause: null, acknowledged: null, maintenance: null });
    source.set(o.id, cs);
  }
  const ids = new Set((change.with ?? []).map((r) => r.id));
  const records = [...model.records.filter((r) => !ids.has(r.id) && !(change.without ?? []).includes(r.id)), ...(change.with ?? [])];
  const d = derive(snap.objects, source, snap.relations, { ...model, records }, now);
  const byId = new Map(snap.objects.map((o) => [o.id, o]));
  const colours: Record<string, ConditionStatus> = {};
  for (const [id, cs] of d.conditions) colours[id] = worstOf(cs);
  return { roots: d.rootCauses.map((r) => ({ id: r.id, label: label(byId.get(r.id), r.id), type: r.type, impacted: r.impactedCount })), colours, derivation: d };
}

export interface SimDiff {
  rootsNew: SimResult["roots"];
  rootsGone: SimResult["roots"];
  colours: { id: string; label: string; from: ConditionStatus; to: ConditionStatus }[];
}

/** What changes from one result to another: roots that appear or go, objects whose colour changes. */
export function diffSim(before: SimResult, after: SimResult, objects: CmdbItem[]): SimDiff {
  const key = (r: SimResult["roots"][number]): string => `${r.id}|${r.type}`;
  const b = new Set(before.roots.map(key)), a = new Set(after.roots.map(key));
  const byId = new Map(objects.map((o) => [o.id, o]));
  const ids = new Set([...Object.keys(before.colours), ...Object.keys(after.colours)]);
  const colours = [...ids].sort().map((id) => ({ id, label: label(byId.get(id), id), from: before.colours[id] ?? "ok", to: after.colours[id] ?? "ok" })).filter((c) => c.from !== c.to);
  return { rootsNew: after.roots.filter((r) => !b.has(key(r))), rootsGone: before.roots.filter((r) => !a.has(key(r))), colours };
}

/** What the classify and notify records decide on the site as it is: per
 *  stored failing condition the record that quiets or re-rates it, and per root
 *  how it is told. A label a record reads is not stored with the condition: such
 *  a record is decided at the next assess. */
export function telling(snap: Snapshot, model: RulesDoc, now: string): { quiet: Map<string, string>; rated: Map<string, string>; told: Map<string, string> } {
  const byId = new Map(snap.objects.map((o) => [o.id, o]));
  const findings: Classified[] = [];
  for (const o of snap.objects) {
    for (const c of conditionsOf(o)) {
      if (isDerivedKind(c) || c.derived || !failing({ status: c.raw?.status ?? c.status })) continue;
      findings.push({ object: o.id, type: c.type, status: c.raw?.status ?? c.status, reason: c.reason, message: c.message, owner: c.owner ?? "" });
    }
  }
  const out = classify(findings, byId, model.records, model.ancestors, () => [], Date.parse(now));
  const quiet = new Map<string, string>(), rated = new Map<string, string>();
  for (const f of out) {
    const k = `${f.object}|${f.type}`;
    if (f.quieted) quiet.set(k, f.quieted);
    if (f.raw) rated.set(k, `${f.status} by ${f.raw.rule}`);
  }
  const d = derive(snap.objects, snapshotSource(snap.objects), snap.relations, model, now);
  const told = new Map<string, string>();
  const rules: NotifyRules = { records: model.records, ancestors: model.ancestors };
  for (const r of d.rootCauses) {
    const o = byId.get(r.id);
    const c = d.conditions.get(r.id)?.find((x) => x.type === r.type);
    if (o && c) told.set(`${r.id}|${r.type}`, notifyOf(o as never, c as never, rules));
  }
  return { quiet, rated, told };
}

/** The difference in what is quiet, re-rated and told, as lines. */
export function tellingLines(before: ReturnType<typeof telling>, after: ReturnType<typeof telling>, objects: CmdbItem[]): string[] {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const name = (k: string): string => { const [id, type] = k.split("|"); return `${label(byId.get(id), id)} ${type}`; };
  const out: string[] = [];
  for (const [k, r] of after.quiet) if (!before.quiet.has(k)) out.push(`would go quiet: ${name(k)} (${r})`);
  for (const [k] of before.quiet) if (!after.quiet.has(k)) out.push(`heard again: ${name(k)}`);
  for (const [k, r] of after.rated) if (before.rated.get(k) !== r) out.push(`rated ${r}: ${name(k)}`);
  for (const [k, w] of after.told) {
    const was = before.told.get(k);
    if (was && was !== w) out.push(`${name(k)}: told ${was === "at-once" ? "at once" : was === "digest" ? "in the digest" : "nowhere"} → ${w === "at-once" ? "at once" : w === "digest" ? "in the digest" : "nowhere"}`);
  }
  return out;
}

/** How many cases each classify and notify record decides on the site as it is:
 *  the stored failing findings it classifies, the roots it tells. */
export function decisions(snap: Snapshot, model: RulesDoc, now: string, roots: { id: string; type: string }[]): Map<string, number> {
  const out = new Map<string, number>();
  const bump = (id: string): void => void out.set(id, (out.get(id) ?? 0) + 1);
  const byId = new Map(snap.objects.map((o) => [o.id, o]));
  const findings: Classified[] = [];
  for (const o of snap.objects) {
    for (const c of conditionsOf(o)) {
      if (isDerivedKind(c) || c.derived || !failing({ status: c.raw?.status ?? c.status })) continue;
      findings.push({ object: o.id, type: c.type, status: c.raw?.status ?? c.status, reason: c.reason, message: c.message, owner: c.owner ?? "" });
    }
  }
  classify(findings, byId, model.records, model.ancestors, () => [], Date.parse(now), undefined, bump);
  const rules: NotifyRules = { records: model.records, ancestors: model.ancestors };
  for (const r of roots) {
    const o = byId.get(r.id);
    const c = conditionsOf(o ?? ({ attributes: {} } as CmdbItem)).find((x) => x.type === r.type);
    const w = o && c ? notifyRecord(o as never, c as never, rules) : null;
    if (w) bump(w.id);
  }
  return out;
}

export function simLines(r: SimResult): string[] {
  const out = [`${r.roots.length} root cause(s)`];
  for (const x of r.roots) out.push(`  ${x.label}: ${x.type}, impacting ${x.impacted}`);
  return out;
}

export function diffLines(d: SimDiff): string[] {
  const out: string[] = [];
  for (const r of d.rootsNew) out.push(`+ root ${r.label} (${r.type}, impacting ${r.impacted})`);
  for (const r of d.rootsGone) out.push(`- root ${r.label} (${r.type})`);
  for (const c of d.colours) out.push(`  ${c.label}: ${c.from} → ${c.to}`);
  if (!out.length) out.push("no difference");
  return out;
}
