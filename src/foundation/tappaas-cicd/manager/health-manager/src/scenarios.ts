// scenarios.ts — contract scenarios: small fixtures shipped beside the health
// records, a handful of objects, a failure, and what must come out ("a node
// down: the node is the one root, its guests are impacted"). A rule set can
// pass every static check and still stop naming a dead node as a root; the
// scenarios are the check for that. A site may retire one it no longer holds to.

import { CmdbItem, CmdbRel, Condition, SOURCE } from "./assess-model";
import { derive } from "./derive";
import { RulesDoc } from "./rules";
import { ConditionStatus, ConditionType } from "../../../lib/ts/src/health-rules";

export interface Scenario {
  id: string; // <origin>.scenario.<name>
  description?: string;
  objects: { class: string; name: string; attributes?: Record<string, unknown> }[];
  relations: { type: string; from: string; to: string; attributes?: Record<string, unknown> }[]; // ends as "<class>/<name>"
  conditions: { object: string; type: ConditionType; status: ConditionStatus; reason?: string; since?: string }[];
  expect: {
    roots?: string[]; // the root causes, as "<class>/<name>", in order
    impact?: Record<string, ConditionStatus | "none">; // an object's impact status, or none
    derived?: string[]; // "<class>/<name>:<type>": explained, not its own
    covered?: string[]; // "<class>/<name>:<type>": its own, not a root while another stands
  };
}

export interface ScenarioFile { description?: string; scenarios: Scenario[] }

const T = "2026-01-01T00:00:00.000Z";

/** What is wrong with one scenario under these records; [] when it holds. */
export function runScenario(sc: Scenario, model: RulesDoc): string[] {
  const id = (cls: string, name: string): string => `${cls}/${name}`;
  const objects: CmdbItem[] = sc.objects.map((o) => ({ id: id(o.class, o.name), class: o.class, name: o.name, attributes: o.attributes ?? {} }));
  const byId = new Map(objects.map((o) => [o.id, o]));
  const wrong: string[] = [];
  const end = (ref: string): CmdbItem | undefined => {
    const o = byId.get(ref);
    if (!o) wrong.push(`names ${ref}, which is not among its objects`);
    return o;
  };
  const relations: CmdbRel[] = [];
  for (const r of sc.relations) {
    const f = end(r.from), t = end(r.to);
    if (f && t) relations.push({ type: r.type, from: { id: f.id, class: f.class, name: f.name }, to: { id: t.id, class: t.class, name: t.name }, attributes: r.attributes ?? {} });
  }
  const source = new Map<string, Condition[]>();
  for (const c of sc.conditions) {
    if (!end(c.object)) continue;
    const reason = c.reason ?? "broken";
    source.set(c.object, [...(source.get(c.object) ?? []), {
      type: c.type, status: c.status, reason, message: reason, since: c.since ?? T, lastChecked: T, source: SOURCE,
      derived: false, rootCause: null, acknowledged: null, maintenance: null,
    }]);
  }
  if (wrong.length) return wrong;
  const d = derive(objects, source, relations, model, T);
  const e = sc.expect;
  if (e.roots) {
    const got = d.rootCauses.map((r) => r.id);
    if (JSON.stringify(got) !== JSON.stringify(e.roots)) wrong.push(`roots: expected ${e.roots.join(", ") || "none"}, got ${got.join(", ") || "none"}`);
  }
  for (const [o, want] of Object.entries(e.impact ?? {})) {
    const got = d.conditions.get(o)?.find((c) => c.type === "impact")?.status ?? "none";
    if (got !== want) wrong.push(`impact on ${o}: expected ${want}, got ${got}`);
  }
  const condOf = (ref: string): Condition | undefined => {
    const at = ref.lastIndexOf(":");
    return d.conditions.get(ref.slice(0, at))?.find((c) => c.type === ref.slice(at + 1));
  };
  for (const ref of e.derived ?? []) if (condOf(ref)?.derived !== true) wrong.push(`${ref}: expected derived`);
  for (const ref of e.covered ?? []) {
    const c = condOf(ref);
    const at = ref.lastIndexOf(":");
    const isRoot = d.rootCauses.some((r) => r.id === ref.slice(0, at) && r.type === ref.slice(at + 1));
    if (!c || c.derived || isRoot || !c.rootCause) wrong.push(`${ref}: expected covered (its own, not a root)`);
  }
  return wrong;
}

/** Every scenario not retired, run: the ones that no longer hold, with why. */
export function runScenarios(scs: Scenario[], model: RulesDoc, retired: Set<string> = new Set()): { id: string; problems: string[] }[] {
  return scs.filter((s) => !retired.has(s.id)).map((s) => ({ id: s.id, problems: runScenario(s, model) })).filter((r) => r.problems.length);
}

/** The scenarios of a parsed file, or why it is not one. */
export function scenariosOf(doc: unknown): Scenario[] {
  const d = doc as ScenarioFile | null;
  if (!d || typeof d !== "object" || !Array.isArray(d.scenarios)) throw new Error("expected { scenarios: [...] }");
  return d.scenarios;
}
