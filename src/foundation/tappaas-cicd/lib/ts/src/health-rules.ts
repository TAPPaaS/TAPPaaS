// health-rules.ts — the correlation rules of ADR-041 D3, as data: their shape
// and the one check of them. cmdb-controller refuses a metamodel/health-rules.json
// that fails it at load; `health-manager rules check` runs the same check.

export const CONDITION_TYPES = ["operational", "drift", "capacity", "performance", "security", "maintenance", "backup", "impact"] as const;
export const CONDITION_STATUSES = ["ok", "warning", "critical", "unknown"] as const;
export type ConditionType = (typeof CONDITION_TYPES)[number];
export type ConditionStatus = (typeof CONDITION_STATUSES)[number];

export interface HealthRule {
  relation: string; // a relation type
  from?: string; // the class on its from end, subclasses too
  to?: string;
  source: { type: ConditionType; status: ConditionStatus };
  // Matches only a dependant whose attribute equals the value; `true` matches
  // any value that is set (not null, false, 0 or ""). A rule with it beats one
  // without for the same crossing.
  dependant?: Record<string, string | number | boolean>;
  impact: ConditionStatus; // the status of the impact on the dependant
  description?: string;
}

/** Does the dependant's attributes satisfy the rule's `dependant` clause? */
export function dependantMatches(rule: HealthRule, attributes: Record<string, unknown> | undefined): boolean {
  const a = attributes ?? {};
  return Object.entries(rule.dependant ?? {}).every(([k, v]) => (v === true ? Boolean(a[k]) : a[k] === v));
}

/** Where nothing judges an object, its `operational` colour is its parent's
 *  (derive.ts): the object on the `to` end of its relation of this type. */
export const FOLLOWS: { class: string; relation: string }[] = [
  { class: "port", relation: "part-of" },
  { class: "disk", relation: "part-of" },
  { class: "asset", relation: "allocated-to" },
];

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => v !== null && typeof v === "object" && !Array.isArray(v);

/** What is wrong with a rules document, as lines; [] when it holds. `dependants`
 *  names the relation types that have a dependant end: only those carry health.
 *  `fields`, where the reader has them, the attributes some class declares. */
export function checkHealthRules(doc: unknown, model: { relations: string[]; dependants: string[]; classes: string[]; fields?: string[] }): string[] {
  if (!isObj(doc) || !Array.isArray(doc.rules)) return ["expected { rules: [...] }"];
  const out: string[] = [];
  doc.rules.forEach((r: unknown, i: number) => {
    const at = `rules[${i}]`;
    if (!isObj(r)) return void out.push(`${at}: not an object`);
    if (typeof r.relation !== "string" || !model.relations.includes(r.relation)) out.push(`${at}: relation ${String(r.relation)} is not a relation type`);
    else if (!model.dependants.includes(r.relation)) out.push(`${at}: relation ${r.relation} has no dependant end, so it carries no health`);
    for (const end of ["from", "to"]) {
      if (r[end] !== undefined && !model.classes.includes(String(r[end]))) out.push(`${at}: ${end} ${String(r[end])} is not a class`);
    }
    const s = isObj(r.source) ? r.source : {};
    if (!CONDITION_TYPES.includes(s.type as ConditionType) || s.type === "impact") out.push(`${at}: source.type ${String(s.type)} is not a condition a check sets`);
    if (s.status !== "critical" && s.status !== "warning") out.push(`${at}: source.status ${String(s.status)} is not a failure (warning, critical)`);
    if (r.impact !== "critical" && r.impact !== "warning") out.push(`${at}: impact ${String(r.impact)} is not warning or critical`);
    if (r.dependant !== undefined) {
      if (!isObj(r.dependant) || !Object.keys(r.dependant).length) out.push(`${at}: dependant is an object of attribute: value`);
      else {
        for (const [k, v] of Object.entries(r.dependant)) {
          if (!["string", "number", "boolean"].includes(typeof v)) out.push(`${at}: dependant.${k} is a string, a number or true/false`);
          if (model.fields && !model.fields.includes(k)) out.push(`${at}: dependant.${k} is no class's attribute`);
        }
      }
    }
  });
  return out;
}

/** A relation as the cycle check reads it: its type, its ends and its words. */
export interface CycleRelation {
  type: string;
  from: { id: string; class?: string; name?: string };
  to: { id: string; class?: string; name?: string };
  attributes?: Record<string, unknown> | null;
}

/** The dependency cycles over required relations: each a set of objects that
 *  reach each other from provider to dependant. A relation with two dependant
 *  ends (a cable) is left out: it reaches back by itself. Each cycle once, its
 *  ids sorted; the cycles sorted by their first id. */
export function dependencyCycles(relations: CycleRelation[], meta: { name: string; dependant: string | null; required: boolean }[]): string[][] {
  const kinds = new Map(meta.map((m) => [m.name, m]));
  const next = new Map<string, Set<string>>();
  for (const r of relations) {
    const m = kinds.get(r.type);
    if (!m || (m.dependant !== "from" && m.dependant !== "to")) continue;
    const a = r.attributes ?? {};
    if (!(typeof a.required === "boolean" ? a.required : m.required)) continue;
    const [prov, dep] = m.dependant === "from" ? [r.to.id, r.from.id] : [r.from.id, r.to.id];
    next.set(prov, (next.get(prov) ?? new Set()).add(dep));
  }
  // Tarjan's strongly connected components, without recursion.
  const index = new Map<string, number>();
  const low = new Map<string, number>();
  const stack: string[] = [];
  const onStack = new Set<string>();
  const out: string[][] = [];
  let n = 0;
  for (const root of next.keys()) {
    if (index.has(root)) continue;
    const work: { v: string; it: Iterator<string> }[] = [];
    const open = (v: string): void => {
      index.set(v, n);
      low.set(v, n++);
      stack.push(v);
      onStack.add(v);
      work.push({ v, it: (next.get(v) ?? new Set<string>()).values() });
    };
    open(root);
    while (work.length) {
      const top = work[work.length - 1];
      const step = top.it.next();
      if (!step.done) {
        const w = step.value;
        if (!index.has(w)) open(w);
        else if (onStack.has(w)) low.set(top.v, Math.min(low.get(top.v)!, index.get(w)!));
        continue;
      }
      work.pop();
      if (work.length) low.set(work[work.length - 1].v, Math.min(low.get(work[work.length - 1].v)!, low.get(top.v)!));
      if (low.get(top.v) === index.get(top.v)) {
        const scc: string[] = [];
        for (let w = stack.pop()!; ; w = stack.pop()!) {
          onStack.delete(w);
          scc.push(w);
          if (w === top.v) break;
        }
        if (scc.length > 1 || next.get(top.v)?.has(top.v)) out.push(scc.sort());
      }
    }
  }
  return out.sort((x, y) => x[0].localeCompare(y[0]));
}
