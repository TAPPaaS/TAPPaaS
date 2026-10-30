// rules.ts — the correlation rules as health-manager reads them (ADR-041 D3):
// `metamodel/health-rules.json`, served by cmdb-controller with what a reader
// needs of the metamodel. `rules list` shows them; `rules check` validates them,
// or a candidate file, by the check the controller applies at load.

import { readFileSync } from "fs";
import { cmdbRequest } from "../../../lib/ts/src/cmdb";
import { HealthRule, checkHealthRules } from "../../../lib/ts/src/health-rules";

export interface RelationMeta {
  name: string;
  dependant: "from" | "to" | "both" | null;
  required: boolean;
}

export interface RulesDoc {
  rules: HealthRule[];
  relations: RelationMeta[];
  ancestors: Record<string, string[]>;
}

export const readRules = (): RulesDoc => cmdbRequest("GET", "/v1/rules") as RulesDoc;

export function ruleLine(r: HealthRule): string {
  const ends = r.from || r.to ? ` (${r.from ?? "any"} → ${r.to ?? "any"})` : "";
  return `${r.source.type} ${r.source.status} crosses ${r.relation}${ends} as ${r.impact} impact`;
}

/** What is wrong with a rules document, against the model the service gave. */
export function checkRules(doc: unknown, model: RulesDoc): string[] {
  return checkHealthRules(doc, {
    relations: model.relations.map((r) => r.name),
    dependants: model.relations.filter((r) => r.dependant).map((r) => r.name),
    classes: Object.keys(model.ancestors),
  });
}

/** `rules list|check [--file F] [--json]`. Returns the exit code. */
export function cmdRules(rest: string[], model: RulesDoc, print: (l: string) => void): number {
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
  if (json) print(JSON.stringify({ ok: wrong.length === 0, problems: wrong }, null, 2));
  else if (wrong.length) for (const w of wrong) print(w);
  else print(`${(doc as { rules: unknown[] }).rules.length} rule(s) hold`);
  return wrong.length ? 1 : 0;
}
