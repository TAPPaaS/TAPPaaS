// health-records.ts — declarative health rules: the record, the one match
// language, which record wins, and the static check of a set.
//
// A record is { id, kind, description?, when, enabled?, overrides?, replaces?,
// …outcome }. `when` is built from selectors (an object, an edge, a condition,
// a finding, a cause); each field holds a predicate: a literal (equality), a
// list (one of), {exists: true} (set to something), {glob: "a*"} (one `*` at
// either end), {over: "24h"} (an age). A class field matches the class or any
// subclass. There is no negation: an exception is a more specific record.
//
// For one decision several records may match. A record named in another
// matching record's `overrides` is out; so is one another matching record is
// strictly more specific than (everything it matches, the other matches too,
// and not the reverse). What is left agrees, or it is a conflict: the check
// refuses the set, and should one ever be evaluated the more severe outcome is
// taken, so the result is still deterministic.

import { createHash } from "crypto";
import { CONDITION_TYPES } from "./health-rules";

export type Val = string | number | boolean;
export type Pred = Val | Val[] | { exists: true } | { glob: string } | { over: string } | { gte?: number; lte?: number };

export interface ObjSel {
  class?: string | string[];
  name?: Pred;
  id?: Pred;
  attr?: Record<string, Pred>;
  module?: Pred;
  zone?: Pred;
  environment?: Pred;
}
export interface CondSel { type?: Pred; status?: Pred; reason?: Pred }
export interface FindingSel { source?: Pred; type?: Pred; status?: Pred; reason?: Pred; labels?: Record<string, Pred>; age?: { over: string } }
export interface CauseSel { type?: Pred; sameType?: boolean; status?: Pred }

export interface When {
  relation?: string | string[];
  edge?: { attr?: Record<string, Pred> };
  object?: ObjSel;
  provider?: ObjSel;
  dependant?: ObjSel;
  from?: ObjSel;
  to?: ObjSel;
  condition?: CondSel;
  finding?: FindingSel;
  cause?: CauseSel;
}

export const KINDS = ["classify", "propagate", "combine", "explain", "follow", "rollup", "notify"] as const;
export type Kind = (typeof KINDS)[number];
export type Status = "warning" | "critical";

interface Envelope {
  id: string;
  description?: string;
  when: When;
  enabled?: boolean;
  overrides?: string[];
  replaces?: string[];
}
export interface Classify extends Envelope { kind: "classify"; set?: { type?: string; status?: Status; reason?: string }; aggregate?: boolean; quiet?: boolean }
export interface Propagate extends Envelope { kind: "propagate"; as: "none" | { status: Status; type?: string }; dependantEnd?: "from" | "to" }
export interface Step { down?: number | "half" | "all"; upFewerThan?: number; as: "rule" | Status; reason?: string }
export interface Combine extends Envelope { kind: "combine"; groupBy: "dependant" | { edgeAttr: string }; steps: Step[] }
export interface Explain extends Envelope { kind: "explain"; effect: "derived" | "covered" | "none" }
export interface Follow extends Envelope { kind: "follow"; relation: string; types: string[] }
export interface MemberStep { relations: string[]; walk: "inbound" | "outbound"; transitive?: boolean }
export type KofN = { warning: number | "half" | "all"; critical: number | "half" | "all" };
export interface Rollup extends Envelope { kind: "rollup"; members?: "all" | MemberStep[]; fn: "worst" | "own" | { kOfN: KofN } }
export interface Notify extends Envelope { kind: "notify"; notify: "at-once" | "digest" | "none" }
export type HealthRecord = Classify | Propagate | Combine | Explain | Follow | Rollup | Notify;
export type OfKind<K extends Kind> = Extract<HealthRecord, { kind: K }>;

/** Who released a record: the first part of its id (core, a module, site). */
export const originOf = (id: string): string => id.split(".")[0];

// ── the flat form the matcher reads ───────────────────────────────────

/** A class predicate, internal: the value is a class name, matched with its ancestors. */
type IsA = { isA: string[] };
type FlatPred = Pred | IsA;
export type Flat = Record<string, FlatPred>;
export type Ancestors = Record<string, string[]>;

const OBJ_SELECTORS = ["object", "provider", "dependant", "from", "to"] as const;
const OBJ_FIELDS = ["name", "id", "module", "zone", "environment"] as const;

/** `when` as path → predicate: "dependant.class", "dependant.attr.haNode",
 *  "condition.status", "finding.labels.alertname", "relation", …. A propagate
 *  record also matches on the end it hurts: the declared one, or `dependantEnd`. */
export function flatten(r: HealthRecord): Flat {
  const w = r.when ?? {};
  const out: Flat = {};
  if (w.relation !== undefined) out.relation = w.relation;
  for (const [k, p] of Object.entries(w.edge?.attr ?? {})) out[`edge.attr.${k}`] = p;
  for (const sel of OBJ_SELECTORS) {
    const o = w[sel];
    if (!o) continue;
    if (o.class !== undefined) out[`${sel}.class`] = { isA: Array.isArray(o.class) ? o.class : [o.class] };
    for (const f of OBJ_FIELDS) if (o[f] !== undefined) out[`${sel}.${f}`] = o[f] as Pred;
    for (const [k, p] of Object.entries(o.attr ?? {})) out[`${sel}.attr.${k}`] = p;
  }
  for (const [k, p] of Object.entries(w.condition ?? {})) out[`condition.${k}`] = p as Pred;
  const f = w.finding ?? {};
  for (const k of ["source", "type", "status", "reason", "age"] as const) if (f[k] !== undefined) out[`finding.${k}`] = f[k] as Pred;
  for (const [k, p] of Object.entries(f.labels ?? {})) out[`finding.labels.${k}`] = p;
  for (const [k, p] of Object.entries(w.cause ?? {})) out[`cause.${k}`] = p as Pred;
  if (r.kind === "propagate") {
    if (r.dependantEnd) out["edge.end"] = r.dependantEnd;
    else out["edge.declared"] = true;
  }
  return out;
}

// ── predicates ────────────────────────────────────────────────────────

const isObj = (p: unknown): p is Record<string, unknown> => typeof p === "object" && p !== null && !Array.isArray(p);
const has = <K extends string>(p: FlatPred, k: K): p is FlatPred & Record<K, unknown> => isObj(p) && k in p;
const literals = (p: FlatPred): Val[] | null => (Array.isArray(p) ? p : isObj(p) ? null : [p]);
const globRe = (g: string): RegExp => new RegExp("^" + g.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$");
const isAOf = (cls: string, anc: Ancestors): string[] => anc[cls] ?? [cls];

/** "90s", "15m", "24h", "7d" as milliseconds; NaN when it is none of those. */
export function durationMs(s: string): number {
  const m = /^(\d+(?:\.\d+)?)(s|m|h|d)$/.exec(String(s).trim());
  if (!m) return NaN;
  return Number(m[1]) * { s: 1e3, m: 60e3, h: 3600e3, d: 86400e3 }[m[2] as "s" | "m" | "h" | "d"];
}

/** Does a concrete value satisfy the predicate? A class value is matched with its ancestors; an age is in ms. */
export function holds(p: FlatPred, v: unknown, anc: Ancestors): boolean {
  if (has(p, "isA")) return typeof v === "string" && (p as IsA).isA.some((c) => isAOf(v, anc).includes(c));
  if (has(p, "exists")) return v !== undefined && v !== null && v !== false && v !== 0 && v !== "";
  if (has(p, "glob")) return typeof v === "string" && globRe(String(p.glob)).test(v);
  if (has(p, "over")) return typeof v === "number" && v > durationMs(String(p.over));
  if (has(p, "gte") || has(p, "lte")) {
    const q = p as { gte?: number; lte?: number };
    return typeof v === "number" && (q.gte === undefined || v >= q.gte) && (q.lte === undefined || v <= q.lte);
  }
  return literals(p)!.some((x) => x === v);
}

export function matches(when: Flat, ctx: (path: string) => unknown, anc: Ancestors): boolean {
  for (const [k, p] of Object.entries(when)) if (!holds(p, ctx(k), anc)) return false;
  return true;
}

// Is a at least as tight as b: every value a accepts, b accepts?
function tighter(a: FlatPred, b: FlatPred, anc: Ancestors): boolean {
  if (has(b, "isA")) {
    const xs = has(a, "isA") ? (a as IsA).isA : (literals(a) as string[] | null);
    return xs !== null && xs.every((x) => (b as IsA).isA.some((y) => isAOf(String(x), anc).includes(y)));
  }
  if (has(b, "exists")) {
    if (has(a, "exists")) return true;
    if (has(a, "glob")) return String(a.glob).replace(/\*/g, "") !== "";
    const la = literals(a);
    return la !== null ? la.every((v) => holds(b, v, anc)) : has(a, "isA") || has(a, "over");
  }
  if (has(b, "glob")) {
    if (has(a, "glob")) {
      const ga = String(a.glob), gb = String(b.glob);
      return globRe(gb).test(ga.replace(/\*/g, "")) && (gb.startsWith("*") ? ga.startsWith("*") || !gb.endsWith("*") : true) && (gb.endsWith("*") ? ga.endsWith("*") || !gb.startsWith("*") : true) && ga.length >= gb.length;
    }
    const la = literals(a);
    return la !== null && la.every((v) => typeof v === "string" && globRe(String(b.glob)).test(v));
  }
  if (has(b, "over")) return has(a, "over") && durationMs(String(a.over)) >= durationMs(String(b.over));
  if (has(b, "gte") || has(b, "lte")) {
    const q = b as { gte?: number; lte?: number };
    if (has(a, "gte") || has(a, "lte")) {
      const r = a as { gte?: number; lte?: number };
      return (q.gte === undefined || (r.gte !== undefined && r.gte >= q.gte)) && (q.lte === undefined || (r.lte !== undefined && r.lte <= q.lte));
    }
    const la = literals(a);
    return la !== null && la.every((v) => holds(b, v, anc));
  }
  const la = literals(a), lb = literals(b)!;
  return la !== null && la.every((v) => lb.includes(v));
}

// Can one value satisfy both?
function meet(a: FlatPred, b: FlatPred, anc: Ancestors): boolean {
  const ca = has(a, "isA") ? (a as IsA).isA : null, cb = has(b, "isA") ? (b as IsA).isA : null;
  if (ca && cb) return ca.some((x) => cb.some((y) => isAOf(x, anc).includes(y) || isAOf(y, anc).includes(x)));
  if (ca || cb) {
    const cs = (ca ?? cb)!;
    const vs = literals(ca ? b : a) as string[] | null;
    return vs === null || vs.some((v) => cs.some((c) => isAOf(String(v), anc).includes(c)));
  }
  const la = literals(a), lb = literals(b);
  if (la && lb) return la.some((v) => lb.includes(v));
  if (la) return la.some((v) => holds(b, v, anc));
  if (lb) return lb.some((v) => holds(a, v, anc));
  if (has(a, "glob") && has(b, "glob")) {
    const ga = String(a.glob), gb = String(b.glob);
    const pre = (g: string): string => (g.startsWith("*") ? "" : g.split("*")[0]);
    const suf = (g: string): string => (g.endsWith("*") ? "" : g.split("*").pop()!);
    const pa = pre(ga), pb = pre(gb), sa = suf(ga), sb = suf(gb);
    return (pa.startsWith(pb) || pb.startsWith(pa)) && (sa.endsWith(sb) || sb.endsWith(sa));
  }
  return true; // exists, over or an interval against another: they can
}

/** a ⊆ b: everything a matches, b matches. */
export const subsumedBy = (a: Flat, b: Flat, anc: Ancestors): boolean => Object.entries(b).every(([k, pb]) => k in a && tighter(a[k], pb, anc));
export const strictlyMoreSpecific = (a: Flat, b: Flat, anc: Ancestors): boolean => subsumedBy(a, b, anc) && !subsumedBy(b, a, anc);
export const overlap = (a: Flat, b: Flat, anc: Ancestors): boolean => Object.entries(a).every(([k, pa]) => !(k in b) || meet(pa, b[k], anc));

// ── outcomes ──────────────────────────────────────────────────────────

const RANKS: Record<string, number> = { none: 0, digest: 1, "at-once": 2, warning: 2, critical: 3 };

/** A record's outcome, as one comparable string: two records agree when equal. */
export function outcome(r: HealthRecord): string {
  switch (r.kind) {
    case "classify": return JSON.stringify([r.set ?? null, r.aggregate === true, r.quiet === true]);
    case "propagate": return JSON.stringify(r.as);
    case "combine": return JSON.stringify([r.groupBy, r.steps]);
    case "explain": return r.effect;
    case "follow": return JSON.stringify([r.relation, [...r.types].sort()]);
    case "rollup": return JSON.stringify([r.members ?? null, r.fn]);
    case "notify": return r.notify;
  }
}

/** How severe an outcome is, for a conflict that is evaluated: the more severe wins. */
export function severity(r: HealthRecord): number {
  switch (r.kind) {
    case "classify": return r.quiet ? -1 : RANKS[r.set?.status ?? ""] ?? 0;
    case "propagate": return r.as === "none" ? 0 : RANKS[r.as.status];
    case "explain": return { derived: 2, covered: 1, none: 0 }[r.effect];
    case "notify": return RANKS[r.notify];
    default: return 0;
  }
}

export interface Candidate<R extends HealthRecord = HealthRecord> { rec: R; flat: Flat }
export interface Picked<R extends HealthRecord = HealthRecord> { winner: R | null; conflict: R[]; beaten: { rec: R; by: R; why: "overridden" | "less-specific" }[] }

/** Among the records that match one decision: the winner, any conflict, and who lost to whom. */
export function pick<R extends HealthRecord>(cands: Candidate<R>[], anc: Ancestors): Picked<R> {
  if (cands.length <= 1) return { winner: cands[0]?.rec ?? null, conflict: [], beaten: [] };
  const beaten: Picked<R>["beaten"] = [];
  const left = cands.filter((c) => {
    for (const d of cands) {
      if (d === c) continue;
      if ((d.rec.overrides ?? []).includes(c.rec.id)) return void beaten.push({ rec: c.rec, by: d.rec, why: "overridden" }), false;
      if (!(c.rec.overrides ?? []).includes(d.rec.id) && strictlyMoreSpecific(d.flat, c.flat, anc)) return void beaten.push({ rec: c.rec, by: d.rec, why: "less-specific" }), false;
    }
    return true;
  });
  left.sort((a, b) => severity(b.rec) - severity(a.rec) || a.rec.id.localeCompare(b.rec.id));
  const distinct = new Set(left.map((c) => outcome(c.rec)));
  return { winner: left[0]?.rec ?? null, conflict: distinct.size > 1 ? left.map((c) => c.rec) : [], beaten };
}

/** Does `a` beat `b` where both match: an override, or strictly more specific? */
export const beats = (a: Candidate, b: Candidate, anc: Ancestors): boolean =>
  (a.rec.overrides ?? []).includes(b.rec.id) || (!(b.rec.overrides ?? []).includes(a.rec.id) && strictlyMoreSpecific(a.flat, b.flat, anc));

/** Pairs of one kind that can match the same decision, neither beating the
 *  other, with different outcomes. An `explain` record that says `derived` and
 *  one that says `covered` answer different questions; a `none` takes part in
 *  a question only against what it beats. */
export function conflicts(recs: HealthRecord[], anc: Ancestors): [HealthRecord, HealthRecord][] {
  const cs = recs.filter((r) => r.enabled !== false).map((rec) => ({ rec, flat: flatten(rec) }));
  const out: [HealthRecord, HealthRecord][] = [];
  for (let i = 0; i < cs.length; i++) {
    for (let j = i + 1; j < cs.length; j++) {
      const a = cs[i], b = cs[j];
      if (a.rec.kind !== b.rec.kind || outcome(a.rec) === outcome(b.rec) || !overlap(a.flat, b.flat, anc)) continue;
      if (beats(a, b, anc) || beats(b, a, anc)) continue;
      if (a.rec.kind === "explain" && b.rec.kind === "explain") {
        const ea = a.rec.effect, eb = b.rec.effect;
        if (ea !== "none" && eb !== "none") continue;
        // A none against a q-record conflicts only when it is an exception to
        // some other q-record that both can meet.
        const [n, q] = ea === "none" ? [a, b] : [b, a];
        const qe = (q.rec as Explain).effect;
        if (!cs.some((o) => o !== q && o.rec.kind === "explain" && (o.rec as Explain).effect === qe && beats(n, o, anc) && overlap(o.flat, q.flat, anc))) continue;
      }
      out.push([a.rec, b.rec]);
    }
  }
  return out;
}

// ── the static check ──────────────────────────────────────────────────

export interface Problem { level: "error" | "warning" | "note"; id: string; message: string }

/** What a check knows of the metamodel. */
export interface ModelInfo {
  relations: { name: string; dependant: "from" | "to" | "both" | null }[];
  ancestors: Ancestors; // every class, with its ancestors
  fields?: string[]; // every attribute some class declares
}

const SELECTORS: Record<Kind, (keyof When)[]> = {
  classify: ["finding", "object"],
  propagate: ["relation", "provider", "dependant", "from", "to", "edge", "condition"],
  combine: ["relation", "provider", "dependant", "edge"],
  explain: ["cause", "condition", "object"],
  follow: ["object"],
  rollup: ["object", "condition"],
  notify: ["object", "condition"],
};
const NUMERIC = (p: unknown): boolean => isObj(p) && ("gte" in p || "lte" in p);

/** The schema of one record and the names it uses; [] when it holds. Numeric
 *  predicates are refused until a release ships the first record needing one. */
export function checkRecord(r: unknown, model: ModelInfo | null): Problem[] {
  const out: Problem[] = [];
  const id = isObj(r) && typeof r.id === "string" ? r.id : "?";
  const err = (message: string): void => void out.push({ level: "error", id, message });
  if (!isObj(r)) return [{ level: "error", id, message: "not an object" }];
  if (typeof r.id !== "string" || !/^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9_-]*)+$/.test(r.id)) err("id is <origin>.<name>…: lower-case words joined by dots");
  if (!KINDS.includes(r.kind as Kind)) return [...out, { level: "error", id, message: `kind ${String(r.kind)} is not one of ${KINDS.join(", ")}` }];
  const kind = r.kind as Kind;
  if (r.description !== undefined && typeof r.description !== "string") err("description is text");
  if (r.enabled !== undefined && typeof r.enabled !== "boolean") err("enabled is true or false");
  for (const k of ["overrides", "replaces"]) if (r[k] !== undefined && (!Array.isArray(r[k]) || !(r[k] as unknown[]).every((x) => typeof x === "string"))) err(`${k} is a list of record ids`);
  if (!isObj(r.when)) err("when is an object");
  const w = (isObj(r.when) ? r.when : {}) as Record<string, unknown>;
  for (const k of Object.keys(w)) if (!SELECTORS[kind].includes(k as keyof When)) err(`when.${k}: a ${kind} record has ${SELECTORS[kind].join(", ")}`);
  const classes = model ? new Set(Object.keys(model.ancestors)) : null;
  const relNames = model ? new Set(model.relations.map((x) => x.name)) : null;
  const pred = (at: string, p: unknown): void => {
    if (NUMERIC(p)) return err(`${at}: numeric comparison is not available yet`);
    const lit = (v: unknown): boolean => ["string", "number", "boolean"].includes(typeof v);
    if (lit(p) || (Array.isArray(p) && p.length > 0 && p.every(lit))) return;
    if (isObj(p) && Object.keys(p).length === 1) {
      if (p.exists === true) return;
      if (typeof p.glob === "string") {
        const g = p.glob;
        const stars = g.split("*").length - 1;
        if (stars === 0 || stars > 2 || (stars === 1 && !g.startsWith("*") && !g.endsWith("*")) || (stars === 2 && !(g.startsWith("*") && g.endsWith("*")))) return err(`${at}: a glob has * at either end only`);
        return;
      }
      if (typeof p.over === "string" && Number.isFinite(durationMs(p.over))) return;
    }
    err(`${at}: not a predicate (a value, a list, {exists: true}, {glob: …}${at.endsWith(".age") ? ", {over: \"24h\"}" : ""})`);
  };
  const objSel = (at: string, o: unknown): void => {
    if (!isObj(o)) return err(`${at} is an object selector`);
    for (const [k, v] of Object.entries(o)) {
      if (k === "class") {
        const cs = Array.isArray(v) ? v : [v];
        if (!cs.length || !cs.every((c) => typeof c === "string")) err(`${at}.class is a class or a list of classes`);
        else if (classes) for (const c of cs as string[]) if (!classes.has(c)) err(`${at}.class ${c} is not a class`);
      } else if (k === "attr") {
        if (!isObj(v)) { err(`${at}.attr is {attribute: predicate}`); continue; }
        for (const [a, p] of Object.entries(v)) {
          pred(`${at}.attr.${a}`, p);
          if (model?.fields && !model.fields.includes(a)) err(`${at}.attr.${a} is no class's attribute`);
        }
      } else if ((OBJ_FIELDS as readonly string[]).includes(k)) pred(`${at}.${k}`, v);
      else err(`${at}.${k}: an object selector has class, name, id, attr, module, zone, environment`);
    }
  };
  for (const s of OBJ_SELECTORS) if (w[s] !== undefined) objSel(`when.${s}`, w[s]);
  if (w.relation !== undefined) {
    const rs = Array.isArray(w.relation) ? w.relation : [w.relation];
    if (!rs.length || !rs.every((x) => typeof x === "string")) err("when.relation is a relation type or a list");
    else if (relNames) for (const x of rs as string[]) if (!relNames.has(x)) err(`when.relation ${x} is not a relation type`);
  }
  if (w.edge !== undefined) {
    const e = w.edge;
    if (!isObj(e) || Object.keys(e).some((k) => k !== "attr") || !isObj(e.attr)) err("when.edge is {attr: {name: predicate}}");
    else for (const [a, p] of Object.entries(e.attr)) pred(`when.edge.attr.${a}`, p);
  }
  const condFields = (at: string, c: unknown, allowed: string[]): void => {
    if (!isObj(c)) return err(`${at} is an object`);
    for (const [k, v] of Object.entries(c)) {
      if (!allowed.includes(k)) { err(`${at}.${k}: ${at} has ${allowed.join(", ")}`); continue; }
      if (k === "labels") {
        if (!isObj(v)) err(`${at}.labels is {label: predicate}`);
        else for (const [l, p] of Object.entries(v)) pred(`${at}.labels.${l}`, p);
      } else if (k === "sameType") {
        if (v !== true) err(`${at}.sameType is true`);
      } else pred(`${at}.${k}`, v);
      if (k === "type") for (const t of (Array.isArray(v) ? v : [v]) as unknown[]) if (typeof t === "string" && !(CONDITION_TYPES as readonly string[]).includes(t)) err(`${at}.type ${t} is not a condition type`);
      if (k === "status") for (const t of (Array.isArray(v) ? v : [v]) as unknown[]) if (typeof t === "string" && !["ok", "warning", "critical", "unknown"].includes(t)) err(`${at}.status ${t} is not a status`);
      if (k === "age" && !(isObj(v) && typeof v.over === "string")) err(`${at}.age is {over: "24h"}`);
    }
  };
  if (w.condition !== undefined) condFields("when.condition", w.condition, kind === "rollup" ? ["type"] : ["type", "status", "reason"]);
  if (w.finding !== undefined) condFields("when.finding", w.finding, ["source", "type", "status", "reason", "labels", "age"]);
  if (w.cause !== undefined) condFields("when.cause", w.cause, ["type", "sameType", "status"]);

  const status = (v: unknown): boolean => v === "warning" || v === "critical";
  const names = (o: Record<string, unknown> | undefined): boolean => !!o && (o.reason !== undefined || o.labels !== undefined);
  const namesObject = (o: unknown): boolean => isObj(o) && (o.name !== undefined || o.id !== undefined);
  switch (kind) {
    case "classify": {
      const set = r.set;
      if (set !== undefined) {
        if (!isObj(set) || !Object.keys(set).length) err("set is {type?, status?, reason?}");
        else {
          if (set.type !== undefined && (!(CONDITION_TYPES as readonly string[]).includes(String(set.type)) || set.type === "impact")) err(`set.type ${String(set.type)} is not a condition a source sets`);
          if (set.status !== undefined && !status(set.status)) err("set.status is warning or critical: a rule never makes a failure ok");
          if (set.reason !== undefined && (typeof set.reason !== "string" || !set.reason)) err("set.reason is a word");
          for (const k of Object.keys(set)) if (!["type", "status", "reason"].includes(k)) err(`set.${k}: set has type, status, reason`);
        }
      }
      if (r.aggregate !== undefined && r.aggregate !== true) err("aggregate is true");
      if (r.quiet !== undefined && r.quiet !== true) err("quiet is true");
      if (set === undefined && r.aggregate === undefined && r.quiet === undefined) err("a classify record sets, aggregates or quiets");
      if (r.quiet === true && !names(w.finding as Record<string, unknown>) && !namesObject(w.object)) err("a quiet record names a reason, a label or an object");
      break;
    }
    case "propagate": {
      const as = r.as;
      if (as !== "none" && !(isObj(as) && status(as.status) && (as.type === undefined || ((CONDITION_TYPES as readonly string[]).includes(String(as.type)) && as.type !== "impact")) && Object.keys(as).every((k) => k === "status" || k === "type"))) err('as is "none" or {status: warning|critical, type?}');
      if (r.dependantEnd !== undefined && r.dependantEnd !== "from" && r.dependantEnd !== "to") err("dependantEnd is from or to");
      if (r.dependantEnd === undefined && model && w.relation !== undefined) {
        for (const x of (Array.isArray(w.relation) ? w.relation : [w.relation]) as string[]) {
          const m = model.relations.find((y) => y.name === x);
          if (m && !m.dependant) err(`relation ${x} has no dependant end: name the one this record hurts (dependantEnd)`);
        }
      }
      if (w.relation === undefined) err("a propagate record names its relation");
      break;
    }
    case "combine": {
      const g = r.groupBy;
      if (g !== "dependant" && !(isObj(g) && typeof g.edgeAttr === "string" && Object.keys(g).length === 1)) err('groupBy is "dependant" or {edgeAttr: name}');
      if (!Array.isArray(r.steps) || !r.steps.length) err("steps is a list");
      else {
        let prev = -1;
        const order = (s: Record<string, unknown>): number => (s.as === "critical" ? 3 : s.as === "rule" ? 2.5 : 2);
        const at = (s: Record<string, unknown>): number => (s.down === "all" ? 1e9 : s.down === "half" ? 0.5e9 : typeof s.down === "number" ? s.down : typeof s.upFewerThan === "number" ? 1e9 - s.upFewerThan : 0);
        const sorted = (r.steps as unknown[]).filter(isObj).sort((a, b) => at(a) - at(b));
        (r.steps as unknown[]).forEach((s, i) => {
          if (!isObj(s)) return err(`steps[${i}] is an object`);
          const d = s.down, u = s.upFewerThan;
          if ((d === undefined) === (u === undefined)) err(`steps[${i}] has down or upFewerThan`);
          if (d !== undefined && !(d === "all" || d === "half" || (typeof d === "number" && Number.isInteger(d) && d >= 1))) err(`steps[${i}].down is a count from 1, "half" or "all"`);
          if (u !== undefined && !(typeof u === "number" && Number.isInteger(u) && u >= 1)) err(`steps[${i}].upFewerThan is a count from 1`);
          if (!["rule", "warning", "critical"].includes(String(s.as))) err(`steps[${i}].as is rule, warning or critical`);
          if (s.reason !== undefined && typeof s.reason !== "string") err(`steps[${i}].reason is a word`);
        });
        for (const s of sorted) {
          if (order(s) < prev) err("steps get softer as more members fail");
          prev = Math.max(prev, order(s));
        }
      }
      break;
    }
    case "explain":
      if (!["derived", "covered", "none"].includes(String(r.effect))) err("effect is derived, covered or none");
      break;
    case "follow":
      if (typeof r.relation !== "string") err("relation is a relation type");
      else if (relNames && !relNames.has(r.relation)) err(`relation ${r.relation} is not a relation type`);
      if (!Array.isArray(r.types) || !r.types.length || !r.types.every((t) => (CONDITION_TYPES as readonly string[]).includes(String(t)))) err("types is a list of condition types");
      break;
    case "rollup": {
      const m = r.members;
      if (m !== undefined && m !== "all") {
        if (!Array.isArray(m) || !m.length) err('members is "all" or a list of steps');
        else m.forEach((s, i) => {
          if (!isObj(s) || !Array.isArray(s.relations) || !s.relations.length || !["inbound", "outbound"].includes(String(s.walk))) err(`members[${i}] is {relations: [...], walk: inbound|outbound, transitive?}`);
          else if (relNames) for (const x of s.relations as string[]) if (!relNames.has(x)) err(`members[${i}]: ${x} is not a relation type`);
        });
      }
      const fn = r.fn;
      const k = (v: unknown): boolean => v === "half" || v === "all" || (typeof v === "number" && Number.isInteger(v) && v >= 1);
      if (fn !== "worst" && fn !== "own" && !(isObj(fn) && isObj(fn.kOfN) && k(fn.kOfN.warning) && k(fn.kOfN.critical))) err('fn is "worst", "own" or {kOfN: {warning: n, critical: n|"half"|"all"}}');
      if (fn !== "own" && m === undefined) err("a roll-up names its members");
      break;
    }
    case "notify":
      if (!["at-once", "digest", "none"].includes(String(r.notify))) err("notify is at-once, digest or none");
      if (r.notify === "none" && !names(w.condition as Record<string, unknown>) && !namesObject(w.object)) err("a notify none record names a reason or an object");
      break;
  }
  return out;
}

// ── a rule file and a rule set ────────────────────────────────────────

/** A released or installed rule file: { description?, records: [...] }. */
export interface RuleFile { description?: string; records: HealthRecord[] }

/** The records of a parsed file, or the problem with its shape. */
export function recordsOf(doc: unknown, file: string): { records: HealthRecord[]; problems: Problem[] } {
  if (!isObj(doc) || !Array.isArray(doc.records)) return { records: [], problems: [{ level: "error", id: file, message: "expected { records: [...] }" }] };
  return { records: doc.records as HealthRecord[], problems: [] };
}

/** The static check of a whole set: each record's schema, ids once, overrides
 *  that name something, and every conflict. `origin` restricts a module's
 *  records to its own end (anchoring) where given. */
export function checkSet(recs: HealthRecord[], model: ModelInfo | null): Problem[] {
  const out: Problem[] = [];
  const ids = new Map<string, number>();
  for (const r of recs) {
    out.push(...checkRecord(r, model));
    if (isObj(r) && typeof r.id === "string") ids.set(r.id, (ids.get(r.id) ?? 0) + 1);
  }
  for (const [id, n] of ids) if (n > 1) out.push({ level: "error", id, message: `id ${id} is used ${n} times` });
  if (out.some((p) => p.level === "error")) return out;
  for (const r of recs) for (const o of r.overrides ?? []) if (!ids.has(o)) out.push({ level: "warning", id: r.id, message: `overrides ${o}, which is not in the set` });
  for (const [a, b] of conflicts(recs, model?.ancestors ?? {})) out.push({ level: "error", id: a.id, message: `conflicts with ${b.id}: both can match one decision, neither is more specific or overrides the other, and they decide differently` });
  return out;
}

// ── canonical form and the hash ───────────────────────────────────────

/** JSON with object keys sorted, recursively: the form a hash and a diff read. */
export function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (isObj(v)) return `{${Object.keys(v).sort().filter((k) => v[k] !== undefined).map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}

/** SHA-256 over the active records in canonical form, sorted by id. */
export function ruleSetHash(recs: HealthRecord[]): string {
  const active = recs.filter((r) => r.enabled !== false).sort((a, b) => a.id.localeCompare(b.id));
  return createHash("sha256").update(canonical(active)).digest("hex");
}
