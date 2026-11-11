// rules.ts — the correlation rules as health-manager reads them (ADR-041 D3):
// `metamodel/health-rules.json`, served by cmdb-controller with what a reader
// needs of the metamodel. `rules list` shows them; `rules check` validates them,
// or a candidate file, by the check the controller applies at load.

import { readFileSync } from "fs";
import { cmdbRequest } from "../../../lib/ts/src/cmdb";
import { CycleRelation, HealthRule, checkHealthRules, dependencyCycles } from "../../../lib/ts/src/health-rules";

export interface RelationMeta {
  name: string;
  dependant: "from" | "to" | "both" | null;
  required: boolean;
}

export interface RulesDoc {
  rules: HealthRule[];
  relations: RelationMeta[];
  ancestors: Record<string, string[]>;
  fields?: string[]; // every attribute some class declares: what a `dependant` clause may name
}

export const readRules = (): RulesDoc => cmdbRequest("GET", "/v1/rules") as RulesDoc;

export function ruleLine(r: HealthRule): string {
  const ends = r.from || r.to ? ` (${r.from ?? "any"} → ${r.to ?? "any"})` : "";
  const dep = Object.entries(r.dependant ?? {}).map(([k, v]) => (v === true ? `${k} set` : `${k}=${String(v)}`));
  const when = dep.length ? ` to a dependant with ${dep.join(", ")}` : "";
  return `${r.source.type} ${r.source.status} crosses ${r.relation}${ends}${when} as ${r.impact} impact`;
}

/** What is wrong with a rules document, against the model the service gave. */
export function checkRules(doc: unknown, model: RulesDoc): string[] {
  return checkHealthRules(doc, {
    relations: model.relations.map((r) => r.name),
    dependants: model.relations.filter((r) => r.dependant).map((r) => r.name),
    classes: Object.keys(model.ancestors),
    fields: model.fields,
  });
}

/** The dependency cycles in the CMDB's relations, one line each: a failure in
 *  one would reach all of them and back. */
export function cycleProblems(relations: CycleRelation[], model: RulesDoc): string[] {
  const label = new Map<string, string>();
  for (const r of relations) for (const e of [r.from, r.to]) label.set(e.id, e.class && e.name ? `${e.class}/${e.name}` : e.id);
  return dependencyCycles(relations, model.relations).map((c) => `a dependency cycle over required relations: ${c.map((id) => label.get(id) ?? id).join(", ")}`);
}

/** `rules list|check [--file F] [--json]`. Returns the exit code. Without
 *  --file, check also reads the relations (when given) for dependency cycles. */
export function cmdRules(rest: string[], model: RulesDoc, print: (l: string) => void, relations?: () => CycleRelation[]): number {
  const [verb, ...args] = rest;
  const json = args.includes("--json");
  if (verb === "list") {
    if (json) print(JSON.stringify(model.rules, null, 2));
    else for (const r of model.rules) print(ruleLine(r));
    return 0;
  }
  if (verb !== "check") throw new Error("rules: expected 'list' or 'check'");
  const at = args.indexOf("--file");
  if (at >= 0 && !args[at + 1]) throw new Error("rules check: --file needs a path");
  const doc: unknown = at >= 0 ? JSON.parse(readFileSync(args[at + 1], "utf8")) : { rules: model.rules };
  const wrong = checkRules(doc, model);
  if (at < 0 && relations) wrong.push(...cycleProblems(relations(), model));
  if (json) print(JSON.stringify({ ok: wrong.length === 0, problems: wrong }, null, 2));
  else if (wrong.length) for (const w of wrong) print(w);
  else print(`${(doc as { rules: unknown[] }).rules.length} rule(s) hold${at < 0 && relations ? "; no dependency cycle" : ""}`);
  return wrong.length ? 1 : 0;
}
