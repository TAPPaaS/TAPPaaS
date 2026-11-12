// rule-text.ts — a health record as one sentence, for `rules list`, the
// README's block of standard rules and the console. Plain words from the
// record's own fields; the record stays the truth.

import { CauseSel, CondSel, FindingSel, HealthRecord, ObjSel, Pred, When } from "../../../lib/ts/src/health-records";

const pv = (p: Pred): string => {
  if (Array.isArray(p)) return p.map((x) => String(x)).join(" or ");
  if (typeof p === "object" && p !== null) {
    if ("exists" in p) return "set";
    if ("glob" in p) return `like ${p.glob}`;
    if ("over" in p) return `older than ${p.over}`;
    return JSON.stringify(p);
  }
  return String(p);
};

const a = (w: string): string => (/^[aeiou]/.test(w) ? `an ${w}` : `a ${w}`);

function obj(o: ObjSel | undefined, fallback: string): string {
  if (!o) return fallback;
  const cls = o.class === undefined ? fallback : a(Array.isArray(o.class) ? o.class.join(" or ") : o.class);
  const bits: string[] = [];
  if (o.name !== undefined) bits.push(`named ${pv(o.name)}`);
  if (o.id !== undefined) bits.push(`with id ${pv(o.id)}`);
  if (o.module !== undefined) bits.push(`of module ${pv(o.module)}`);
  if (o.zone !== undefined) bits.push(`in zone ${pv(o.zone)}`);
  if (o.environment !== undefined) bits.push(`in environment ${pv(o.environment)}`);
  for (const [k, p] of Object.entries(o.attr ?? {})) bits.push(typeof p === "object" && p !== null && "exists" in p ? `with ${k}` : `with ${k} ${pv(p)}`);
  return [cls, ...bits].join(" ");
}

function cond(c: CondSel | undefined, noun = "failure"): string {
  if (!c) return `a ${noun}`;
  const st = c.status !== undefined ? `${pv(c.status)} ` : "";
  const ty = c.type !== undefined ? `${pv(c.type)} ` : "";
  const why = c.reason !== undefined ? ` (${pv(c.reason)})` : "";
  return `a ${st}${ty}${noun}${why}`.replace(/^a ([aeiou])/, "an $1");
}

function finding(f: FindingSel | undefined): string {
  if (!f) return "a finding";
  const bits = [f.source !== undefined ? `from ${pv(f.source)}` : "", ...Object.entries(f.labels ?? {}).map(([k, p]) => `${k} ${pv(p)}`), f.age ? `standing ${pv(f.age)}` : ""].filter(Boolean);
  return `${cond({ type: f.type, status: f.status, reason: f.reason }, "finding")}${bits.length ? ` ${bits.join(", ")}` : ""}`;
}

function cause(c: CauseSel | undefined): string {
  if (!c) return "a failure";
  const st = c.status !== undefined ? `${pv(c.status)} ` : "";
  const ty = c.sameType ? "" : c.type !== undefined ? `${pv(c.type)} ` : "";
  return `a ${st}${ty}failure${c.sameType ? " of the same type" : ""}`.replace(/^a ([aeiou])/, "an $1");
}

const rel = (w: When): string => (w.relation === undefined ? "" : Array.isArray(w.relation) ? w.relation.join(" or ") : w.relation);
const edge = (w: When): string => Object.entries(w.edge?.attr ?? {}).map(([k, p]) => (typeof p === "object" && p !== null && "exists" in p ? ` with ${k}` : ` with ${k} ${pv(p)}`)).join("");

/** One sentence for a record. */
export function sentence(r: HealthRecord): string {
  const w = r.when ?? {};
  switch (r.kind) {
    case "classify": {
      const to = [r.set?.type, r.set?.status, r.set?.reason ? `(${r.set.reason})` : ""].filter(Boolean).join(" ");
      const does = [to ? `is ${to}` : "", r.aggregate ? "is a sum of others, never a root" : "", r.quiet ? "is kept and quiet" : ""].filter(Boolean).join(", ");
      return `${finding(w.finding)}${w.object ? ` on ${obj(w.object, "an object")}` : ""} ${does}`;
    }
    case "propagate": {
      const where = w.from || w.to ? ` (${obj(w.from, "any")} → ${obj(w.to, "any")})` : "";
      const end = r.dependantEnd ? `, hurting its ${r.dependantEnd} end` : "";
      const path = `${rel(w)}${edge(w)}${where}${end} to ${obj(w.dependant, "its dependant")}`;
      const head = `${cond(w.condition)}${w.provider ? ` on ${obj(w.provider, "")}` : ""}`;
      return r.as === "none" ? `${head} does not cross ${path}` : `${head} crosses ${path} as a ${r.as.status}${r.as.type ? ` ${r.as.type}` : ""} impact`;
    }
    case "combine": {
      const steps = r.steps.map((s) => `${s.down !== undefined ? `${s.down} down` : `fewer than ${s.upFewerThan} up`}: ${s.as === "rule" ? "the rule's impact" : `a ${s.as}`}${s.reason ? ` (${s.reason})` : ""}`).join("; ");
      const by = r.groupBy === "dependant" ? "per dependant" : `by ${r.groupBy.edgeAttr}`;
      return `${rel(w) ? `${rel(w)} relations` : "relations"}${edge(w)}${w.dependant ? ` into ${obj(w.dependant, "")}` : ""} count together ${by}: ${steps}`;
    }
    case "explain": {
      const eff = r.effect === "derived" ? "explains it: derived" : r.effect === "covered" ? "covers it: not a root while that stands" : "neither explains nor covers it";
      return `${cause(w.cause)} reaching ${obj(w.object, "an object")} with ${cond(w.condition, "condition")} of its own ${eff}`;
    }
    case "follow":
      return `${obj(w.object, "an object")} nothing judges takes the ${r.types.join(", ")} colour of what it is ${r.relation}`;
    case "rollup": {
      const who = r.members === undefined ? "" : r.members === "all" ? " of everything that is not a sum" : ` of what is ${r.members.map((s) => `${s.relations.join(" or ")} ${s.walk === "inbound" ? "it" : "from it"}${s.transitive ? ", all the way" : ""}`).join(", then ")}`;
      const fn = r.fn === "own" ? "is its own, not a sum of its members" : r.fn === "worst" ? `is the worst${who}` : `is critical at ${r.fn.kOfN.critical} critical, a warning at ${r.fn.kOfN.warning} failing${who}`;
      return `${obj(w.object, "an object")}${w.condition?.type !== undefined ? `'s ${pv(w.condition.type)}` : ""} ${fn}`;
    }
    case "notify":
      return `a root cause with ${cond(w.condition, "condition")}${w.object ? ` on ${obj(w.object, "")}` : ""} is told ${r.notify === "at-once" ? "at once" : r.notify === "digest" ? "in the daily digest" : "nowhere"}`;
  }
}
