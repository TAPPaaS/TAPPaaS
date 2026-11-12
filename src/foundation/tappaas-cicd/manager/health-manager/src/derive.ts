// engine.ts — the derivation (ADR-041 D3 as amended): from the conditions the
// sources set to impact, root causes, follows and roll-ups. One engine on every
// site; at each point where it decides something about a particular node, edge
// or condition it asks the health records (lib/ts health-records.ts):
//
//   spread    `propagate`: whether and as what a failure crosses an edge.
//             `combine`: how edges that back each other up count together.
//             The least fixpoint of "what reaches what": records only add, and
//             no match reads what was derived, so it ends and has one answer.
//   roots     `explain`: which arriving failure explains (derived) or covers
//             an object's own condition. A failure explains only up to the
//             status it left its provider with, never above its root's own
//             status: a critical is never the symptom of a warning.
//   follow    `follow`: whose colour an object nothing judges takes.
//   roll up   `rollup`: who a collection or a place is the sum of, read from a
//             snapshot taken before any roll-up.
//
// Two rules make groups sound. A group's verdict never explains its own failed
// members: a crossing a group gave carries the members that counted as down
// for it, and is no impact on, explanation of or cover for them. And a group
// whose verdict can reach its own members counts them from a run without such
// groups, so a member it took down is not counted as a cause of itself.
//
// Pure, and recomputed whole on every assess: the input is each object's
// source conditions, none derived, and the current relations.

import { CmdbItem, CmdbRel, Condition, DERIVED, RANK, RootCause, SOURCE, failing, silenced } from "./assess-model";
import { RulesDoc } from "./rules";
import { ConditionStatus } from "../../../lib/ts/src/health-rules";
import { Ancestors, Candidate, Combine, Explain, Follow, HealthRecord, MemberStep, OfKind, Picked, Propagate, Rollup, Status, Step, beats, flatten, matches, pick } from "../../../lib/ts/src/health-records";

interface Edge {
  rel: number; // the relation's index: both ends of a cable are one relation
  type: string;
  dep: string;
  prov: string;
  depEnd: "from" | "to";
  declared: boolean; // the end relations.json names, not one a record named
  from: CmdbRel["from"];
  to: CmdbRel["to"];
  required: boolean;
  attrs: Record<string, unknown>;
}
interface Seed { obj: string; cond: Condition }
type State = string; // `${obj}|${type}|${status}`
const S = (obj: string, type: string, status: string): State => `${obj}|${type}|${status}`;
const rank = (s: string): number => RANK[s as ConditionStatus];
const earlier = (a: Seed, b: Seed): number => Date.parse(a.cond.since) - Date.parse(b.cond.since) || a.obj.localeCompare(b.obj);

/** A group partly down: what reached the dependant, and how much of the group is down. */
export interface PartialGroup { member: string; group: string; down: number; of: number; reason: string }

interface Run {
  crossed: Map<State, Set<State>>; // every crossing, at the impact it gives
  explains: Map<State, Set<State>>; // what a crossing explains: the dependant at the level it left the provider with
  partial: Map<State, PartialGroup>; // a group's step that gave the dependant's state, with its wording
  down: Set<State>;
  via: Map<string, Set<string>>; // `${a}>${b}` a group gave: the members that counted as down for it
  keys: Map<string, string>; // `${a}>${b}` a group gave: the group
  by: Map<string, { rec: string; step?: number }>; // `${a}>${b}`: the record (and step) that made the crossing
}

/** What a run decided, for `rules explain` and the counts in `rules list`. */
export interface Trace {
  conflicts: Map<string, string[]>; // records that disagreed on one decision, by their ids joined
  fired: Map<string, number>; // how often each record won a decision
  runs: number;
}

export interface Derivation {
  conditions: Map<string, Condition[]>;
  rootCauses: RootCause[];
  trace: Trace;
  /** For tracing: how an impact got to an object, hop by hop, and which records decided. */
  why?: Why;
}

export interface Hop { from: string; to: string; type: string; status: string; rule: string; step?: number; group?: string }
export interface Why {
  path(rootObj: string, rootType: string, to: string): Hop[];
  explainedBy: Map<string, { root: string; rule: string; effect: "derived" | "covered" }>; // `${obj}|${type}`
}

export interface DeriveOpts {
  /** Keep what `rules explain` needs: the crossings and the records behind them. */
  trace?: boolean;
}

const WORDS = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
const count = (n: number): string => WORDS[n] ?? String(n);

export function derive(objects: CmdbItem[], source: Map<string, Condition[]>, relations: CmdbRel[], model: RulesDoc, now: string, opts: DeriveOpts = {}): Derivation {
  const anc: Ancestors = model.ancestors;
  const nowMs = Date.parse(now);
  const byId = new Map(objects.map((o) => [o.id, o]));
  const isA = (cls: string, a: string): boolean => (anc[cls] ?? [cls]).includes(a);
  const trace: Trace = { conflicts: new Map(), fired: new Map(), runs: 0 };
  const note = <R extends HealthRecord>(p: Picked<R>): Picked<R> => {
    if (p.winner) trace.fired.set(p.winner.id, (trace.fired.get(p.winner.id) ?? 0) + 1);
    if (p.conflict.length) trace.conflicts.set(p.conflict.map((c) => c.id).sort().join(" ~ "), p.conflict.map((c) => c.id));
    return p;
  };
  const active = (model.records ?? []).filter((r) => r.enabled !== false);
  const of = <K extends HealthRecord["kind"]>(k: K): Candidate<OfKind<K>>[] => active.filter((r): r is OfKind<K> => r.kind === k).map((rec) => ({ rec, flat: flatten(rec) }));
  const propagates = of("propagate"), combines = of("combine"), explainRecs = of("explain"), rollups = of("rollup"), follows = of("follow");
  const choose = <R extends HealthRecord>(cands: Candidate<R>[], ctx: (path: string) => unknown): Picked<R> => note(pick(cands.filter((c) => matches(c.flat, ctx, anc)), anc));

  // What a selector reads of an object: its class, name, id, attributes, and
  // the attributes module, zone and environment.
  const objField = (id: string, cls: string, p: string): unknown => {
    if (p === "class") return cls;
    if (p === "name") return byId.get(id)?.name;
    if (p === "id") return id;
    if (p === "module" || p === "zone" || p === "environment") return byId.get(id)?.attributes?.[p];
    if (p.startsWith("attr.")) return byId.get(id)?.attributes?.[p.slice(5)];
    return undefined;
  };
  const objCtx = (prefix: string, id: string, cls: string) => (path: string): unknown => (path.startsWith(`${prefix}.`) ? objField(id, cls, path.slice(prefix.length + 1)) : undefined);

  // ── the graph: the metamodel's dependant ends, and any end a propagate record names ──
  const meta = new Map(model.relations.map((r) => [r.name, r]));
  const named = new Map<string, Set<"from" | "to">>();
  for (const { rec } of propagates) {
    if (!rec.dependantEnd) continue;
    const rels = rec.when.relation === undefined ? [] : Array.isArray(rec.when.relation) ? rec.when.relation : [rec.when.relation];
    for (const r of rels) named.set(r, (named.get(r) ?? new Set()).add(rec.dependantEnd));
  }
  const edges: Edge[] = [];
  relations.forEach((r, rel) => {
    const m = meta.get(r.type);
    const a = r.attributes ?? {};
    const required = typeof a.required === "boolean" ? a.required : m?.dependant ? m.required : true;
    const mk = (depEnd: "from" | "to", declared: boolean): void =>
      void edges.push({ rel, type: r.type, depEnd, declared, from: r.from, to: r.to, required, attrs: a, dep: depEnd === "from" ? r.from.id : r.to.id, prov: depEnd === "from" ? r.to.id : r.from.id });
    const decl = new Set<"from" | "to">(m?.dependant === "both" ? ["from", "to"] : m?.dependant ? [m.dependant] : []);
    for (const d of decl) mk(d, true);
    for (const d of named.get(r.type) ?? []) if (!decl.has(d)) mk(d, false);
  });
  const byProv = new Map<string, Edge[]>();
  const byRel = new Map<number, Edge[]>();
  for (const e of edges) {
    if (!e.required) continue;
    byProv.set(e.prov, [...(byProv.get(e.prov) ?? []), e]);
    byRel.set(e.rel, [...(byRel.get(e.rel) ?? []), e]);
  }
  const edgeCtx = (e: Edge, type?: string, status?: string, reason?: string) => (path: string): unknown => {
    if (path === "relation") return e.type;
    if (path === "edge.end") return e.depEnd;
    if (path === "edge.declared") return e.declared;
    if (path === "condition.type") return type;
    if (path === "condition.status") return status;
    if (path === "condition.reason") return reason;
    if (path.startsWith("edge.attr.")) return e.attrs[path.slice(10)];
    const [sel] = path.split(".");
    const rest = path.slice(sel.length + 1);
    const provCls = e.depEnd === "from" ? e.to.class : e.from.class;
    const depCls = e.depEnd === "from" ? e.from.class : e.to.class;
    if (sel === "provider") return objField(e.prov, provCls, rest);
    if (sel === "dependant") return objField(e.dep, depCls, rest);
    if (sel === "from") return objField(e.from.id, e.from.class, rest);
    if (sel === "to") return objField(e.to.id, e.to.class, rest);
    return undefined;
  };
  // A seed's own reason, by its state: `condition.reason` matches only the
  // provider's own source condition.
  const reasonOf = new Map<State, string>();

  // Winners depend on inputs only (the edge, a type, a status, a reason): cached.
  const ruleCache = new Map<string, Propagate | null>();
  const edgeIndex = new Map(edges.map((e, i) => [e, i]));
  const ruleFor = (e: Edge, type: string, status: string, st: State): Propagate | null => {
    const reason = reasonOf.get(st);
    const key = `${edgeIndex.get(e)}|${type}|${status}|${reason ?? ""}`;
    if (ruleCache.has(key)) return ruleCache.get(key)!;
    const w = choose(propagates, edgeCtx(e, type, status, reason)).winner;
    ruleCache.set(key, w);
    return w;
  };
  // Groups: per combine record and key, the relations in it.
  const groupOf = new Map<Edge, { rec: Combine; key: string; name: string } | null>();
  const groups = new Map<string, Set<number>>();
  const label = (id: string): string => `${byId.get(id)?.class ?? "object"} ${byId.get(id)?.name ?? id}`;
  for (const e of edges) {
    if (!e.required) continue;
    const rec = choose(combines, edgeCtx(e)).winner;
    if (!rec) { groupOf.set(e, null); continue; }
    const byDep = rec.groupBy === "dependant";
    const value = byDep ? `${e.dep}|${e.type}` : String(e.attrs[(rec.groupBy as { edgeAttr: string }).edgeAttr]);
    const key = `${rec.id}|${value}`;
    groupOf.set(e, { rec, key, name: byDep ? `${e.type} of ${label(e.dep)}` : value });
    groups.set(key, (groups.get(key) ?? new Set()).add(e.rel));
  }
  const need = (st: Step, n: number): number => (st.upFewerThan !== undefined ? Math.max(1, n - st.upFewerThan + 1) : st.down === "all" ? n : st.down === "half" ? Math.ceil(n / 2) : Math.min(n, st.down ?? 1));

  // ── the spread ──
  const run = (seeds: Seed[], off: Set<string> = new Set(), clean: Set<State> | null = null, fed: Set<string> = new Set()): Run => {
    trace.runs++;
    const res: Run = { crossed: new Map(), explains: new Map(), partial: new Map(), down: new Set(seeds.map((s) => S(s.obj, s.cond.type, s.cond.status))), via: new Map(), keys: new Map(), by: new Map() };
    const { crossed, explains, down, via, keys } = res;
    const add = (m: Map<State, Set<State>>, a: State, b: State): boolean => {
      const s = m.get(a) ?? new Set();
      if (s.has(b)) return false;
      s.add(b);
      m.set(a, s);
      return true;
    };
    const groupDown = (e: Edge, key: string, type: string, status: string): { down: number; of: number; who: string[] } => {
      const members = [...groups.get(key)!];
      const who = new Set<string>([e.prov]);
      let n = 0;
      const counted = clean && fed.has(key) ? clean : down; // a group fed by its own verdict counts what failed without it
      for (const rel of members) {
        const provs = (byRel.get(rel) ?? []).filter((x) => x.prov !== e.dep && counted.has(S(x.prov, type, status))).map((x) => x.prov);
        if (rel === e.rel || provs.length) n++;
        for (const p of provs) who.add(p);
      }
      return { down: n, of: members.length, who: [...who].sort() };
    };
    const labels: { to: State; e: Edge; key: string; name: string; type: string; status: string; step: number; rec: Combine; member: string }[] = [];
    for (let grew = true; grew; ) {
      grew = false;
      for (const st of [...down]) {
        const [obj, type, status] = st.split("|");
        for (const e of byProv.get(obj) ?? []) {
          const rule = ruleFor(e, type, status, st);
          if (!rule || rule.as === "none") continue;
          const as = rule.as;
          const outType = as.type ?? type;
          const g = groupOf.get(e);
          const emits: { status: Status; step: number }[] = [];
          let who: string[] = [];
          if (!g) emits.push({ status: as.status, step: -1 });
          else if (off.has(g.key)) continue;
          else {
            const c = groupDown(e, g.key, type, status);
            who = c.who;
            g.rec.steps.forEach((s, i) => {
              if (c.down >= need(s, c.of)) emits.push({ status: s.as === "rule" ? as.status : s.as, step: i });
            });
          }
          for (const em of emits) {
            const to = S(e.dep, outType, em.status);
            if (add(crossed, st, to)) grew = true;
            const k = `${st}>${to}`;
            if (!res.by.has(k)) res.by.set(k, { rec: g ? g.rec.id : rule.id, ...(g && em.step >= 0 ? { step: em.step } : {}) });
            if (g) {
              for (const x of [to, S(e.dep, outType, status)]) {
                const kk = `${st}>${x}`;
                keys.set(kk, g.key);
                const had = via.get(kk) ?? new Set<string>();
                for (const w of who) if (!had.has(w)) { had.add(w); grew = true; }
                via.set(kk, had);
              }
            }
            // What a crossing explains: up to the level it left the provider with.
            if (add(explains, st, S(e.dep, outType, status))) grew = true;
            if (g && em.step >= 0 && !labels.some((l) => l.to === to && l.key === g.key && l.step === em.step)) labels.push({ to, e, key: g.key, name: g.name, type, status, step: em.step, rec: g.rec, member: obj });
            if (!down.has(to)) { down.add(to); grew = true; }
          }
        }
      }
    }
    // A step's wording stands only where it is the highest step that holds in
    // the end; the member it names is the earliest seed among those down.
    const ordered = [...seeds].sort(earlier);
    for (const l of labels) {
      const c = groupDown(l.e, l.key, l.type, l.status);
      const top = l.rec.steps.reduce((t, s, i) => (c.down >= need(s, c.of) ? i : t), -1);
      const reason = l.rec.steps[l.step].reason;
      const first = ordered.find((s) => c.who.includes(s.obj) && s.cond.type === l.type && s.cond.status === l.status)?.obj ?? c.who[0] ?? l.member;
      if (top === l.step && reason && !res.partial.has(l.to)) res.partial.set(l.to, { member: first, group: l.name, down: c.down, of: c.of, reason });
    }
    return res;
  };
  const reach = (from: State, m: Map<State, Set<State>>): Set<State> => {
    const seen = new Set<State>();
    for (const todo = [from]; todo.length; ) for (const n of m.get(todo.pop()!) ?? []) if (!seen.has(n)) { seen.add(n); todo.push(n); }
    return seen;
  };

  const out = new Map<string, Condition[]>();
  for (const [id, cs] of source) out.set(id, cs.map((c) => ({ ...c, derived: false, rootCause: null })));
  // A roll-up record that keeps an object's own condition of a type ("own")
  // makes that condition a sum of others: derived, never a root.
  const rollupFor = (o: { id: string; class: string }, type?: string): Rollup | null =>
    choose(rollups.filter((c) => (type !== undefined) || !("condition.type" in c.flat)), (k) => (k === "condition.type" ? type : objCtx("object", o.id, o.class)(k))).winner;
  for (const [obj, cs] of out) {
    const o = byId.get(obj);
    for (const c of cs) if (o && rollupFor(o, c.type)?.fn === "own") c.derived = true;
  }
  const seeds: Seed[] = [];
  for (const [obj, cs] of out) for (const cond of cs) if (failing(cond) && cond.type !== "impact" && !cond.derived) seeds.push({ obj, cond });
  for (const s of seeds) reasonOf.set(S(s.obj, s.cond.type, s.cond.status), s.cond.reason);
  const stateOf = (s: Seed): State => S(s.obj, s.cond.type, s.cond.status);

  let full = run(seeds);
  // Groups whose verdict comes back to their own members: counted from a run without them.
  const fed = new Set<string>();
  for (const [k, key] of full.keys) {
    const to = k.slice(k.indexOf(">") + 1);
    const provs = new Set([...groups.get(key)!].flatMap((rel) => (byRel.get(rel) ?? []).map((x) => x.prov)));
    if ([...reach(to, full.crossed)].some((st) => provs.has(st.split("|")[0]))) fed.add(key);
  }
  if (fed.size) full = run(seeds, new Set(), run(seeds, fed).down, fed);
  const members = new Set<string>();
  for (const w of full.via.values()) for (const o of w) members.add(o);
  const walk = (s: Seed, avoid: string | null): { hit: Set<State>; expl: Set<State> } => {
    const ok = (a: State, b: State): boolean => avoid === null || !full.via.get(`${a}>${b}`)?.has(avoid);
    const hit = new Set<State>();
    for (const todo = [stateOf(s)]; todo.length; ) {
      const a = todo.pop()!;
      for (const n of full.crossed.get(a) ?? []) if (!hit.has(n) && ok(a, n)) { hit.add(n); todo.push(n); }
    }
    const expl = new Set<State>();
    for (const st of [stateOf(s), ...hit]) for (const x of full.explains.get(st) ?? []) if (ok(st, x)) expl.add(x);
    return { hit, expl };
  };
  const walks = new Map<string, { hit: Set<State>; expl: Set<State> }>();
  const seedNo = new Map(seeds.map((s, i) => [s, i]));
  // What s reached, seen from object `at`: the plain reach unless `at` is a group's failed member.
  const reachOf = (s: Seed, at: string | null): { hit: Set<State>; expl: Set<State> } => {
    const avoid = at !== null && members.has(at) ? at : null;
    const k = `${seedNo.get(s)}|${avoid ?? ""}`;
    if (!walks.has(k)) walks.set(k, walk(s, avoid));
    return walks.get(k)!;
  };
  // explain: for the question q (derived or covered), the records of that
  // effect, and the `none` records that are an exception to one of them.
  const explainWinner = (q: "derived" | "covered", causeType: string, causeStatus: string, b: Seed): Explain | null => {
    const ctx = (k: string): unknown =>
      k === "cause.sameType" ? causeType === b.cond.type : k === "cause.type" ? causeType : k === "cause.status" ? causeStatus
      : k === "condition.type" ? b.cond.type : k === "condition.status" ? b.cond.status : k === "condition.reason" ? b.cond.reason
      : objCtx("object", b.obj, byId.get(b.obj)?.class ?? "")(k);
    const hit = explainRecs.filter((c) => matches(c.flat, ctx, anc));
    const qs = hit.filter((c) => c.rec.effect === q);
    const nones = hit.filter((n) => n.rec.effect === "none" && qs.some((c) => beats(n, c, anc)));
    return note(pick([...qs, ...nones], anc)).winner;
  };
  const explainedBy = new Map<string, { root: string; rule: string; effect: "derived" | "covered" }>();
  // Does a's failure explain b's condition as the same failure seen from below? Never above a's own status.
  const derivedBy = (a: Seed, b: Seed): Explain | null => {
    for (const st of reachOf(a, b.obj).expl) {
      const [obj, type, status] = st.split("|");
      if (obj !== b.obj) continue;
      if (Math.min(rank(status), rank(a.cond.status)) < rank(b.cond.status)) continue;
      const w = explainWinner("derived", type, status, b);
      if (w?.effect === "derived") return w;
    }
    return null;
  };
  const reachedBy = (a: Seed, b: Seed): boolean => derivedBy(a, b) !== null;
  const dominated = (s: Seed): boolean => seeds.some((o) => o !== s && reachedBy(o, s) && !(reachedBy(s, o) && earlier(s, o) < 0));
  const roots = seeds.filter((s) => !dominated(s)).sort(earlier);

  // Impact: what each root reached, per object as seen from that object; an
  // object reached by several roots names the one that gave its worst status.
  const impacted = new Map<string, { root: Seed; status: ConditionStatus; state: State; type: string }>();
  const impactCount = new Map<Seed, number>();
  for (const r of roots) {
    const objs = new Map<string, { status: ConditionStatus; state: State; type: string }>();
    const take = (st: State): void => {
      const [obj, type, s] = st.split("|");
      const had = objs.get(obj);
      if (obj !== r.obj && (!had || rank(s) > rank(had.status) || (s === had.status && full.partial.has(st)))) objs.set(obj, { status: s as ConditionStatus, state: st, type });
    };
    const plain = reachOf(r, null).hit;
    for (const st of plain) if (!members.has(st.split("|")[0])) take(st);
    for (const m of members) if ([...plain].some((st) => st.startsWith(`${m}|`))) for (const st of reachOf(r, m).hit) if (st.startsWith(`${m}|`)) take(st);
    impactCount.set(r, objs.size);
    for (const [obj, v] of objs) {
      const had = impacted.get(obj);
      if (!had) impacted.set(obj, { root: r, ...v });
      else if (rank(v.status) > rank(had.status)) Object.assign(had, { root: r, ...v });
    }
  }
  for (const s of seeds) {
    if (roots.includes(s)) continue;
    s.cond.derived = true;
    const by = roots.find((r) => reachedBy(r, s)) ?? roots[0];
    s.cond.rootCause = by.obj;
    if (opts.trace) explainedBy.set(`${s.obj}|${s.cond.type}`, { root: by.obj, rule: derivedBy(by, s)?.id ?? "", effect: "derived" });
  }
  for (const [obj, { root, status, state }] of impacted) {
    const part = full.partial.get(state);
    out.set(obj, [...(out.get(obj) ?? []), {
      type: "impact", status, reason: part ? part.reason : root.cond.reason,
      message: part
        ? `${count(part.down)} of ${count(part.of)} in ${part.group} down: ${label(part.member)}${part.member === root.obj ? "" : ` (${label(root.obj)})`}: ${root.cond.message}`
        : `${label(root.obj)}: ${root.cond.message}`,
      since: now, lastChecked: now, source: SOURCE, owner: DERIVED, derived: true, rootCause: root.obj,
      acknowledged: null, maintenance: null,
    }]);
  }
  // Covered: a root whose object another root's impact reached, where a record
  // says that impact covers it; never behind a root weaker than the impact or
  // than the condition covered.
  const coverRule = new Map<Seed, string>();
  const covered = (s: Seed): Seed | null => {
    const hit = impacted.get(s.obj);
    if (!hit || hit.root === s) return null;
    const w = explainWinner("covered", hit.type, hit.status, s);
    if (w?.effect !== "covered") return null;
    if (rank(hit.root.cond.status) < Math.max(rank(hit.status), rank(s.cond.status))) return null;
    coverRule.set(s, w.id);
    return hit.root;
  };
  for (const s of roots) {
    const by = covered(s);
    if (!by) continue;
    s.cond.rootCause = by.obj;
    if (opts.trace) explainedBy.set(`${s.obj}|${s.cond.type}`, { root: by.obj, rule: coverRule.get(s) ?? "", effect: "covered" });
  }
  const rootCauses = roots
    .filter((s) => !covered(s))
    .sort((a, b) => RANK[b.cond.status] - RANK[a.cond.status] || (impactCount.get(b) ?? 0) - (impactCount.get(a) ?? 0) || earlier(a, b))
    .map((s) => ({ id: s.obj, type: s.cond.type as string, impactedCount: impactCount.get(s) ?? 0 }));

  followUp(objects, out, relations, follows, anc, now, objCtx);
  rollUpAll(objects, out, relations, rollupFor, isA, now, nowMs);

  const d: Derivation = { conditions: out, rootCauses, trace };
  if (opts.trace) {
    d.why = {
      explainedBy,
      // The hops from a root's state to the object, breadth first over the crossings.
      path: (rootObj, rootType, to) => {
        const seed = seeds.find((s) => s.obj === rootObj && s.cond.type === rootType);
        if (!seed) return [];
        const start = stateOf(seed);
        const prev = new Map<State, State>();
        const seen = new Set([start]);
        let end: State | null = null;
        for (let front = [start]; front.length && !end; ) {
          const next: State[] = [];
          for (const a of front) {
            for (const b of full.crossed.get(a) ?? []) {
              if (seen.has(b)) continue;
              seen.add(b);
              prev.set(b, a);
              if (b.split("|")[0] === to) { end = b; break; }
              next.push(b);
            }
            if (end) break;
          }
          front = next;
        }
        if (!end) return [];
        const hops: Hop[] = [];
        for (let b: State = end; prev.has(b); b = prev.get(b)!) {
          const a = prev.get(b)!;
          const [, type, status] = b.split("|");
          const by = full.by.get(`${a}>${b}`);
          const key = full.keys.get(`${a}>${b}`);
          hops.unshift({ from: a.split("|")[0], to: b.split("|")[0], type, status, rule: by?.rec ?? "", ...(by?.step !== undefined ? { step: by.step } : {}), ...(key ? { group: key } : {}) });
        }
        return hops;
      },
    };
  }
  return d;
}

// An object with no condition of a followed type gets its parent's, up the
// chain: a free port its switch's. A parent judged only in other types is
// reported, so ok. Derived: never a failure or a root of its own.
function followUp(objects: CmdbItem[], out: Map<string, Condition[]>, relations: CmdbRel[], follows: Candidate<Follow>[], anc: Ancestors, now: string, objCtx: (prefix: string, id: string, cls: string) => (path: string) => unknown): void {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const parent = new Map<string, { up: string; types: string[] }>();
  // The winning follow record per object, then its relation.
  const winner = new Map<string, Follow | null>();
  for (const o of objects) winner.set(o.id, pick(follows.filter((c) => matches(c.flat, objCtx("object", o.id, o.class), anc)), anc).winner);
  for (const r of relations) {
    const f = winner.get(r.from.id);
    if (f && r.type === f.relation && byId.has(r.to.id)) parent.set(r.from.id, { up: r.to.id, types: f.types });
  }
  const settled = new Set<string>();
  const colour = (id: string): void => {
    if (settled.has(id)) return;
    settled.add(id);
    const p = parent.get(id);
    if (!p) return;
    for (const t of p.types) {
      if ((out.get(id) ?? []).some((c) => c.type === t)) continue;
      colour(p.up);
      const theirs = out.get(p.up) ?? [];
      if (!theirs.length) continue;
      const seen = theirs.filter((c) => c.type === t || c.type === "impact");
      const worst = seen.reduce((w, c) => (RANK[c.status] > RANK[w.status] ? c : w), seen[0] ?? theirs[0]);
      const status: ConditionStatus = seen.length ? worst.status : "ok";
      const src = byId.get(p.up)!;
      out.set(id, [...(out.get(id) ?? []), {
        type: t as Condition["type"], status, reason: "follows", message: `follows ${src.class} ${src.name}`,
        since: now, lastChecked: now, source: SOURCE, owner: DERIVED, derived: true, rootCause: failing({ status }) ? worst.rootCause ?? p.up : null,
        acknowledged: null, maintenance: null,
      }]);
    }
  };
  for (const o of objects) colour(o.id);
}

// Who a roll-up's members are: every object that is not itself a sum, or the
// steps over relations from the object (each later step from what the earlier gathered).
function membersOf(o: CmdbItem, steps: "all" | MemberStep[], objects: CmdbItem[], relations: CmdbRel[], isA: (cls: string, a: string) => boolean): string[] {
  if (steps === "all") return objects.filter((x) => !isA(x.class, "collection") && !isA(x.class, "place")).map((x) => x.id);
  let inside = new Set<string>();
  steps.forEach((s, i) => {
    const next = new Set<string>();
    for (let front = i === 0 ? [o.id] : [...inside]; front.length; ) {
      const fr = new Set(front);
      const got = relations
        .filter((r) => s.relations.includes(r.type) && fr.has(s.walk === "inbound" ? r.to.id : r.from.id))
        .map((r) => (s.walk === "inbound" ? r.from.id : r.to.id))
        .filter((id) => !next.has(id) && !(i > 0 && inside.has(id)));
      for (const id of got) next.add(id);
      front = s.transitive ? got : [];
    }
    inside = i === 0 ? next : new Set([...inside, ...next]);
  });
  return [...inside];
}

// Roll-ups, over a snapshot of what is settled: a place inside another counts
// with its own conditions, never with its sum. Never a root.
function rollUpAll(objects: CmdbItem[], out: Map<string, Condition[]>, relations: CmdbRel[], rollupFor: (o: CmdbItem, type?: string) => Rollup | null, isA: (cls: string, a: string) => boolean, now: string, nowMs: number): void {
  const settled = new Map(out);
  for (const o of objects) {
    const base = rollupFor(o);
    if (!base || !base.members) continue;
    const members = membersOf(o, base.members, objects, relations, isA).map((id) => settled.get(id) ?? []);
    const res = new Map((out.get(o.id) ?? []).map((c) => [c.type as string, c]));
    for (const type of new Set(members.flat().map((c) => c.type))) {
      const rec = rollupFor(o, type) ?? base;
      const mine = res.get(type);
      if (rec.fn === "own" && mine && mine.owner !== DERIVED) continue;
      const counted = members.flatMap((m) => m.filter((c) => c.type === type && !silenced(c, nowMs)));
      if (!counted.length) continue;
      let worst = counted.reduce<ConditionStatus>((w, c) => (RANK[c.status] > RANK[w] ? c.status : w), "ok");
      if (typeof rec.fn === "object") {
        const k = (v: number | "half" | "all"): number => (v === "all" ? counted.length : v === "half" ? Math.ceil(counted.length / 2) : v);
        const bad = counted.filter((c) => c.status === "critical").length;
        const warn = counted.filter((c) => failing(c)).length;
        worst = bad >= k(rec.fn.kOfN.critical) ? "critical" : warn >= k(rec.fn.kOfN.warning) ? "warning" : "ok";
      }
      if (mine && !mine.derived && RANK[mine.status] >= RANK[worst]) continue;
      const n = counted.filter((c) => c.status === worst).length;
      res.set(type, {
        type, status: worst, reason: worst === "ok" ? "ok" : "roll-up", message: `${n} of ${counted.length} members ${worst}`,
        since: now, lastChecked: now, source: SOURCE, owner: DERIVED, derived: true, rootCause: null,
        acknowledged: mine?.acknowledged ?? null, maintenance: mine?.maintenance ?? null,
      });
    }
    if (res.size) out.set(o.id, [...res.values()]);
  }
}
