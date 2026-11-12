// rules.ts — the health records as health-manager reads them, and the verbs
// over them: `rules list` (one sentence per record) and `rules check` (the
// static check: schema, names, conflicts; and the dependency cycles in the
// CMDB's relations).
//
// The records and what a reader needs of the metamodel (relation types and
// their dependant ends, class ancestors, attributes) come from cmdb-controller.

import { readFileSync } from "fs";
import { cmdbRequest } from "../../../lib/ts/src/cmdb";
import { CycleRelation, dependencyCycles } from "../../../lib/ts/src/health-rules";
import { HealthRecord, KINDS, ModelInfo, Problem, checkSet, originOf, recordsOf } from "../../../lib/ts/src/health-records";
import { sentence } from "./rule-text";

export interface RelationMeta {
  name: string;
  dependant: "from" | "to" | "both" | null;
  required: boolean;
}

export interface RulesDoc {
  records: HealthRecord[];
  relations: RelationMeta[];
  ancestors: Record<string, string[]>;
  fields?: string[]; // every attribute some class declares
}

export const readRules = (): RulesDoc => cmdbRequest("GET", "/v1/rules") as RulesDoc;

export const modelInfo = (m: RulesDoc): ModelInfo => ({ relations: m.relations, ancestors: m.ancestors, fields: m.fields });

/** The dependency cycles in the CMDB's relations, one line each: a failure in
 *  one would reach all of them and back. */
export function cycleProblems(relations: CycleRelation[], model: RulesDoc): string[] {
  const label = new Map<string, string>();
  for (const r of relations) for (const e of [r.from, r.to]) label.set(e.id, e.class && e.name ? `${e.class}/${e.name}` : e.id);
  return dependencyCycles(relations, model.relations).map((c) => `a dependency cycle over required relations: ${c.map((id) => label.get(id) ?? id).join(", ")}`);
}

const flag = (args: string[], name: string): string | undefined => {
  const at = args.indexOf(name);
  if (at < 0) return undefined;
  if (!args[at + 1] || args[at + 1].startsWith("--")) throw new Error(`rules: ${name} needs a value`);
  return args[at + 1];
};

/** The records in the README's block: by kind, one line each with its id. */
export function markdownList(recs: HealthRecord[]): string[] {
  const out: string[] = [];
  for (const k of KINDS) {
    const of = recs.filter((r) => r.kind === k);
    if (!of.length) continue;
    out.push(`**${k}**`, "");
    for (const r of of) out.push(`- \`${r.id}\`${r.enabled === false ? " (off until a site turns it on)" : ""}: ${sentence(r)}.`);
    out.push("");
  }
  return out;
}

const problemLine = (p: Problem): string => `${p.level}: ${p.id}: ${p.message}`;

/** `rules list [--kind K] [--origin O] [--json|--markdown]` and
 *  `rules check [--file F] [--json]`. Returns the exit code. Without --file,
 *  check also reads the relations (when given) for dependency cycles. */
export function cmdRules(rest: string[], model: RulesDoc, print: (l: string) => void, relations?: () => CycleRelation[]): number {
  const [verb, ...args] = rest;
  const json = args.includes("--json");
  if (verb === "list") {
    const kind = flag(args, "--kind");
    const origin = flag(args, "--origin");
    const recs = model.records.filter((r) => (!kind || r.kind === kind) && (!origin || originOf(r.id) === origin));
    if (json) print(JSON.stringify(recs.map((r) => ({ ...r, origin: originOf(r.id), sentence: sentence(r) })), null, 2));
    else if (args.includes("--markdown")) for (const l of markdownList(recs)) print(l);
    else for (const r of recs) print(`${r.id}${r.enabled === false ? " [off]" : ""}: ${sentence(r)}`);
    return 0;
  }
  if (verb !== "check") throw new Error("rules: expected list or check");
  const file = flag(args, "--file");
  let recs = model.records;
  const problems: Problem[] = [];
  if (file) {
    const got = recordsOf(JSON.parse(readFileSync(file, "utf8")), file);
    problems.push(...got.problems);
    // A candidate file is checked with the rules in use, except those it replaces.
    const ids = new Set(got.records.map((r) => r?.id));
    recs = [...model.records.filter((r) => !ids.has(r.id)), ...got.records];
  }
  problems.push(...checkSet(recs, modelInfo(model)));
  const cycles = !file && relations ? cycleProblems(relations(), model) : [];
  const errors = problems.filter((p) => p.level === "error");
  if (json) print(JSON.stringify({ ok: errors.length === 0, problems: [...problems.map(problemLine), ...cycles] }, null, 2));
  else if (problems.length || cycles.length) for (const l of [...problems.map(problemLine), ...cycles]) print(l);
  if (!json && !errors.length) print(`${recs.length} record(s) hold${!file && relations ? cycles.length ? "" : "; no dependency cycle" : ""}`);
  return errors.length || cycles.length ? 1 : 0;
}
