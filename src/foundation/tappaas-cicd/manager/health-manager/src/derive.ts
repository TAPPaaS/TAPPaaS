// derive.ts — ADR-041 D3: from the conditions the sources set to impact, root
// causes and roll-ups. Pure, and recomputed whole on every assess: the input is
// each object's source conditions, none derived, and the current relations.
//
// A failure travels from a provider to its dependant, over a relation whose rule
// matches the failure (health-rules.json). What decides "expected or derived":
//
//   impact     an object a failure reached gets `impact`, naming the root.
//   derived    its own condition of the travelling type, failing no worse than
//              what reached it, is the same failure seen from below: `derived`,
//              and it does not count. A worse one is its own.
//   root       a failing, non-derived condition on an object nothing reached,
//              and no ancestor explains (below).
//   ancestor   a failing ancestor no rule crosses from (a warning) is the root of
//              two or more failing dependants, lowest first, then earliest. Those
//              keep their own failure: a critical is not silenced by a warning.
//   follows    an object nothing judges takes its parent's colour (FOLLOWS):
//              `derived`, so never a failure or a root of its own.
//   group      relations of one `redundancyGroup` (its name, site-wide) are
//              crossed at the rule's impact only once all of them are down;
//              while some are, the dependant of a failed one gets a `warning`
//              impact naming the failed member ("one of two in … down").
//   softer     a crossing softer than its source (a group partly down, a rule
//              that degrades) still explains the dependant's own condition of
//              that type: the guest stopped because its node did.
//
// A cable has no direction, so two ports that each see the link down reach each
// other: the one whose transition came first is the root.

import { CmdbItem, CmdbRel, Condition, RANK, RootCause, SOURCE, failing, silenced } from "./assess-model";
import { RulesDoc } from "./rules";
import { ConditionStatus, FOLLOWS, HealthRule, dependantMatches } from "../../../lib/ts/src/health-rules";

interface Edge {
  rel: number; // the relation's index: both ends of a cable are one relation
  type: string;
  dep: string; // the dependant
  prov: string; // the provider
  fromClass: string;
  toClass: string;
  required: boolean;
  group: string | null;
}

interface Seed { obj: string; cond: Condition }
type State = string; // `${obj}|${type}|${status}`
const stateOf = (obj: string, type: string, status: string): State => `${obj}|${type}|${status}`;

export interface Derivation {
  conditions: Map<string, Condition[]>;
  rootCauses: RootCause[];
}

function edgesOf(relations: CmdbRel[], model: RulesDoc): Edge[] {
  const meta = new Map(model.relations.map((r) => [r.name, r]));
  const out: Edge[] = [];
  relations.forEach((r, rel) => {
    const m = meta.get(r.type);
    if (!m?.dependant) return;
    const a = r.attributes ?? {};
    const common = {
      rel,
      type: r.type,
      fromClass: r.from.class,
      toClass: r.to.class,
      required: typeof a.required === "boolean" ? a.required : m.required,
      group: typeof a.redundancyGroup === "string" ? a.redundancyGroup : null,
    };
    if (m.dependant !== "to") out.push({ ...common, dep: r.from.id, prov: r.to.id });
    if (m.dependant !== "from") out.push({ ...common, dep: r.to.id, prov: r.from.id });
  });
  return out;
}

// The rule for a failure crossing e: one that reads the dependant, and matches
// it, before one that does not.
function ruleFor(e: Edge, type: string, status: string, model: RulesDoc, attrsOf: (id: string) => Record<string, unknown> | undefined): HealthRule | undefined {
  const isA = (cls: string, anc?: string): boolean => !anc || (model.ancestors[cls] ?? [cls]).includes(anc);
  const fits = model.rules.filter((r) => r.relation === e.type && r.source.type === type && r.source.status === status && isA(e.fromClass, r.from) && isA(e.toClass, r.to));
  return fits.find((r) => r.dependant && dependantMatches(r, attrsOf(e.dep))) ?? fits.find((r) => !r.dependant);
}

// A redundancy group partly down: what reached the dependant, and how much of
// the group is down.
export interface PartialGroup { member: string; group: string; down: number; of: number }

interface Spread {
  crossed: Map<State, Set<State>>; // every crossing, at the impact it gives
  softer: Map<State, Set<State>>; // a softer crossing, at its source's status
  partial: Map<State, PartialGroup>; // the dependant's state a partly down group gave
}

// Every (object, type, status) a failure reaches, and the crossings that got it
// there. A fixpoint, because a redundancy group is crossed only once all its
// members are down, and those may be reached in any order; a group still
// partly down once nothing else grows gives its `warning`, which may travel on.
function spread(seeds: Seed[], edges: Edge[], model: RulesDoc, attrsOf: (id: string) => Record<string, unknown> | undefined): Spread {
  const crossed = new Map<State, Set<State>>();
  const softer = new Map<State, Set<State>>();
  const partial = new Map<State, PartialGroup>();
  const down = new Set<State>(seeds.map((s) => stateOf(s.obj, s.cond.type, s.cond.status)));
  const byProv = new Map<string, Edge[]>();
  const byRel = new Map<number, Edge[]>();
  const groups = new Map<string, Set<number>>();
  for (const e of edges) {
    if (!e.required) continue;
    byProv.set(e.prov, [...(byProv.get(e.prov) ?? []), e]);
    byRel.set(e.rel, [...(byRel.get(e.rel) ?? []), e]);
    if (e.group) groups.set(e.group, (groups.get(e.group) ?? new Set()).add(e.rel));
  }
  const add = (m: Map<State, Set<State>>, from: State, to: State): void => void m.set(from, (m.get(from) ?? new Set()).add(to));
  // How much of e's group is down: a member is down when a provider of it is,
  // other than e's dependant (what it reaches through e is no cause of e).
  const groupDown = (e: Edge, type: string, status: string): { down: number; of: number } => {
    const members = [...groups.get(e.group!)!];
    const isDown = (rel: number): boolean => rel === e.rel || (byRel.get(rel) ?? []).some((x) => x.prov !== e.dep && down.has(stateOf(x.prov, type, status)));
    return { down: members.filter(isDown).length, of: members.length };
  };
  const pass = (partly: boolean): boolean => {
    let grew = false;
    for (const st of [...down]) {
      const [obj, type, status] = st.split("|");
      for (const e of byProv.get(obj) ?? []) {
        const rule = ruleFor(e, type, status, model, attrsOf);
        if (!rule) continue;
        let impact = rule.impact;
        let part: PartialGroup | null = null;
        if (e.group) {
          const g = groupDown(e, type, status);
          if (g.down < g.of) {
            if (!partly) continue;
            impact = "warning";
            part = { member: obj, group: e.group, ...g };
          } else if (partly) continue;
        }
        const to = stateOf(e.dep, type, impact);
        if (crossed.get(st)?.has(to) && (!part || partial.has(to))) continue;
        add(crossed, st, to);
        if (part && !partial.has(to)) partial.set(to, part);
        if (RANK[impact] < RANK[status as ConditionStatus]) add(softer, st, stateOf(e.dep, type, status));
        if (!down.has(to)) down.add(to);
        grew = true;
      }
    }
    return grew;
  };
  for (;;) {
    while (pass(false));
    if (!pass(true)) break;
  }
  return { crossed, softer, partial };
}

function reach(from: State, crossed: Map<State, Set<State>>): Set<State> {
  const seen = new Set<State>();
  const todo = [from];
  while (todo.length) {
    for (const n of crossed.get(todo.pop()!) ?? []) {
      if (seen.has(n)) continue;
      seen.add(n);
      todo.push(n);
    }
  }
  return seen;
}

const WORDS = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
const count = (n: number): string => WORDS[n] ?? String(n);

const earlier = (a: Seed, b: Seed): number => Date.parse(a.cond.since) - Date.parse(b.cond.since) || a.obj.localeCompare(b.obj);

// The objects under each of `ids` along required relations, whatever rules say.
function dependantsOf(id: string, edges: Edge[]): Set<string> {
  const seen = new Set<string>();
  const todo = [id];
  while (todo.length) {
    const p = todo.pop()!;
    for (const e of edges) {
      if (e.required && e.prov === p && !seen.has(e.dep) && e.dep !== id) {
        seen.add(e.dep);
        todo.push(e.dep);
      }
    }
  }
  return seen;
}

const isA = (o: CmdbItem, anc: string, model: RulesDoc): boolean => (model.ancestors[o.class] ?? [o.class]).includes(anc);

// Who a collection or a place is the sum of.
function membersOf(o: CmdbItem, objects: CmdbItem[], relations: CmdbRel[], model: RulesDoc): string[] {
  if (o.class === "site") return objects.filter((x) => !isA(x, "collection", model) && !isA(x, "place", model)).map((x) => x.id);
  const inbound = (ids: string[], types: string[]): string[] => relations.filter((r) => types.includes(r.type) && ids.includes(r.to.id)).map((r) => r.from.id);
  if (isA(o, "collection", model)) return [...new Set(inbound([o.id], ["member-of", "serves"]))];
  const inside = new Set<string>();
  for (let front = [o.id]; front.length; ) {
    front = inbound(front, ["placed-in", "at"]).filter((id) => !inside.has(id));
    for (const id of front) inside.add(id);
  }
  for (const r of relations) if (r.type === "allocated-to" && inside.has(r.from.id)) inside.add(r.to.id);
  return [...inside];
}

function rollUp(own: Condition[], members: Condition[][], now: string, nowMs: number): Condition[] {
  const out = new Map(own.map((c) => [c.type as string, c]));
  const types = new Set(members.flat().map((c) => c.type));
  for (const type of types) {
    const counted = members.flatMap((m) => m.filter((c) => c.type === type && !silenced(c, nowMs)));
    if (!counted.length) continue;
    const worst = counted.reduce<ConditionStatus>((w, c) => (RANK[c.status] > RANK[w] ? c.status : w), "ok");
    const had = out.get(type);
    if (had && !had.derived && RANK[had.status] >= RANK[worst]) continue;
    const n = counted.filter((c) => c.status === worst).length;
    out.set(type, {
      type, status: worst, reason: worst === "ok" ? "ok" : "roll-up",
      message: `${n} of ${counted.length} members ${worst}`,
      since: now, lastChecked: now, source: SOURCE, derived: true, rootCause: null,
      acknowledged: had?.acknowledged ?? null, maintenance: had?.maintenance ?? null,
    });
  }
  return [...out.values()];
}

// An object with no `operational` of its own gets its parent's, up the chain: a
// free port its switch's. A parent judged only in other types is reported, so ok.
function follow(objects: CmdbItem[], out: Map<string, Condition[]>, relations: CmdbRel[], model: RulesDoc, now: string): void {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const parent = new Map<string, string>();
  for (const f of FOLLOWS) {
    for (const r of relations) {
      const o = byId.get(r.from.id);
      if (r.type === f.relation && o && isA(o, f.class, model) && byId.has(r.to.id)) parent.set(o.id, r.to.id);
    }
  }
  const settled = new Set<string>();
  const colour = (id: string): void => {
    if (settled.has(id)) return;
    settled.add(id);
    const up = parent.get(id);
    const own = (out.get(id) ?? []).some((c) => c.type === "operational");
    if (!up || own) return;
    colour(up);
    const theirs = out.get(up) ?? [];
    if (!theirs.length) return;
    const seen = theirs.filter((c) => c.type === "operational" || c.type === "impact");
    const worst = seen.reduce((w, c) => (RANK[c.status] > RANK[w.status] ? c : w), seen[0] ?? theirs[0]);
    const status: ConditionStatus = seen.length ? worst.status : "ok";
    const src = byId.get(up)!;
    out.set(id, [...(out.get(id) ?? []), {
      type: "operational", status, reason: "follows", message: `follows ${src.class} ${src.name}`,
      since: now, lastChecked: now, source: SOURCE, derived: true, rootCause: failing({ status }) ? worst.rootCause ?? up : null,
      acknowledged: null, maintenance: null,
    }]);
  };
  for (const o of objects) colour(o.id);
}

export function derive(objects: CmdbItem[], source: Map<string, Condition[]>, relations: CmdbRel[], model: RulesDoc, now: string): Derivation {
  const nowMs = Date.parse(now);
  const byId = new Map(objects.map((o) => [o.id, o]));
  const edges = edgesOf(relations, model);
  const out = new Map<string, Condition[]>();
  for (const [id, cs] of source) out.set(id, cs.map((c) => ({ ...c, derived: false, rootCause: null })));

  const seeds: Seed[] = [];
  for (const [obj, cs] of out) for (const cond of cs) if (failing(cond) && cond.type !== "impact") seeds.push({ obj, cond });
  const { crossed, softer, partial } = spread(seeds, edges, model, (id) => byId.get(id)?.attributes);
  const reached = new Map(seeds.map((s) => [s, reach(stateOf(s.obj, s.cond.type, s.cond.status), crossed)]));

  // The same failure seen from below: reached in its own type, no less severe;
  // or reached softer than its source, at the source's severity.
  const reachedBy = (a: Seed, b: Seed): boolean => {
    const from = [stateOf(a.obj, a.cond.type, a.cond.status), ...reached.get(a)!];
    return [...reached.get(a)!, ...from.flatMap((st) => [...(softer.get(st) ?? [])])].some((st) => {
      const [obj, type, status] = st.split("|");
      return obj === b.obj && type === b.cond.type && RANK[status as ConditionStatus] >= RANK[b.cond.status];
    });
  };
  const dominated = (s: Seed): boolean => seeds.some((o) => o !== s && reachedBy(o, s) && !(reachedBy(s, o) && earlier(s, o) < 0));
  const roots = seeds.filter((s) => !dominated(s)).sort(earlier);

  // Impact: every object a root reached, naming the earliest root.
  const impacted = new Map<string, { root: Seed; status: ConditionStatus; state: State }>();
  const impactCount = new Map<Seed, number>();
  for (const r of roots) {
    const objs = new Map<string, { status: ConditionStatus; state: State }>();
    for (const st of reached.get(r)!) {
      const [obj, , s] = st.split("|");
      const status = s as ConditionStatus;
      const had = objs.get(obj);
      if (obj !== r.obj && (!had || RANK[status] > RANK[had.status] || (status === had.status && partial.has(st)))) objs.set(obj, { status, state: st });
    }
    impactCount.set(r, objs.size);
    for (const [obj, { status, state }] of objs) {
      const had = impacted.get(obj);
      if (!had) impacted.set(obj, { root: r, status, state });
      else if (RANK[status] > RANK[had.status]) Object.assign(had, { status, state });
    }
  }
  for (const s of seeds) {
    if (roots.includes(s)) continue;
    s.cond.derived = true;
    s.cond.rootCause = (roots.find((r) => reachedBy(r, s)) ?? roots[0]).obj;
  }
  const label = (id: string): string => `${byId.get(id)?.class ?? "object"} ${byId.get(id)?.name ?? id}`;
  for (const [obj, { root, status, state }] of impacted) {
    const part = partial.get(state);
    out.set(obj, [...(out.get(obj) ?? []), {
      type: "impact", status, reason: part ? "redundancy-degraded" : root.cond.reason,
      message: part
        ? `${count(part.down)} of ${count(part.of)} in ${part.group} down: ${label(part.member)}${part.member === root.obj ? "" : ` (${label(root.obj)})`}: ${root.cond.message}`
        : `${label(root.obj)}: ${root.cond.message}`,
      since: now, lastChecked: now, source: SOURCE, derived: true, rootCause: root.obj,
      acknowledged: null, maintenance: null,
    }]);
  }

  // Root causes: what is left, unless a common ancestor explains it.
  const open = roots.filter((s) => !impacted.has(s.obj));
  const taken = new Set<Seed>();
  const under = new Map<Seed, number>();
  const types = new Set(model.rules.map((r) => r.source.type as string));
  const candidates = open
    .filter((s) => types.has(s.cond.type))
    .map((s) => {
      const below = dependantsOf(s.obj, edges);
      return { s, covers: open.filter((x) => x !== s && x.cond.type === s.cond.type && below.has(x.obj)) };
    })
    .filter((c) => c.covers.length >= 2)
    .sort((a, b) => a.covers.length - b.covers.length || earlier(a.s, b.s));
  for (const { s, covers } of candidates) {
    const fresh = covers.filter((x) => !taken.has(x));
    if (fresh.length < 2) continue;
    for (const x of fresh) {
      taken.add(x);
      x.cond.rootCause = s.obj;
    }
    under.set(s, fresh.length);
  }
  const rootCauses = open
    .filter((s) => !taken.has(s))
    .sort((a, b) => (impactCount.get(b) ?? 0) + (under.get(b) ?? 0) - (impactCount.get(a) ?? 0) - (under.get(a) ?? 0) || earlier(a, b))
    .map((s) => ({ id: s.obj, type: s.cond.type as string, impactedCount: (impactCount.get(s) ?? 0) + (under.get(s) ?? 0) }));

  follow(objects, out, relations, model, now);

  // Roll-ups, over what is settled above; never a root.
  const rolled = objects.filter((o) => isA(o, "collection", model) || isA(o, "place", model));
  for (const o of rolled) {
    const members = membersOf(o, objects, relations, model).map((id) => out.get(id) ?? []);
    const cs = rollUp(out.get(o.id) ?? [], members, now, nowMs);
    if (cs.length) out.set(o.id, cs);
  }
  return { conditions: out, rootCauses };
}
