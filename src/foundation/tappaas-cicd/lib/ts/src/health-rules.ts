// health-rules.ts — the correlation rules of ADR-041 D3, as data: their shape
// and the one check of them. cmdb-controller refuses a metamodel/health-rules.json
// that fails it at load; `health-manager rules check` runs the same check.

export const CONDITION_TYPES = ["operational", "drift", "capacity", "security", "maintenance", "backup", "impact"] as const;
export const CONDITION_STATUSES = ["ok", "warning", "critical", "unknown"] as const;
export type ConditionType = (typeof CONDITION_TYPES)[number];
export type ConditionStatus = (typeof CONDITION_STATUSES)[number];

export interface HealthRule {
  relation: string; // a relation type
  from?: string; // the class on its from end, subclasses too
  to?: string;
  source: { type: ConditionType; status: ConditionStatus };
  impact: ConditionStatus; // the status of the impact on the dependant
  description?: string;
}

/** Where nothing judges an object, its `operational` colour is its parent's
 *  (derive.ts): the object on the `to` end of its relation of this type. */
export const FOLLOWS: { class: string; relation: string }[] = [
  { class: "port", relation: "part-of" },
  { class: "asset", relation: "allocated-to" },
];

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => v !== null && typeof v === "object" && !Array.isArray(v);

/** What is wrong with a rules document, as lines; [] when it holds. `dependants`
 *  names the relation types that have a dependant end: only those carry health. */
export function checkHealthRules(doc: unknown, model: { relations: string[]; dependants: string[]; classes: string[] }): string[] {
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
  });
  return out;
}
