// rulestore.ts — the health records a site runs, and how a release reaches them.
//
// There is one installed set. Every record has an origin (core, a module, the
// site): who released it, and when it leaves. Origin is never a precedence.
//
//   config/health/rules/<origin>.json      what runs: the merge, the verbs and the console write it
//   config/health/base/<origin>.json       as released, last installed: the merge only
//   config/health/scenarios/<origin>.json  the contract scenarios as released
//   config/health/state.json               what the site did to each rule (edited, deleted, added),
//                                          rules held, scenarios retired, origins switched off, the last merge
//
// The merge runs per origin and per rule id over three versions: base (the
// last installed release), theirs (the new release) and ours (what is
// installed). It adds, changes and removes released rules; it never modifies
// or removes a rule the site edited, and never re-adds one the site deleted.
// A rule edited by hand in the file is found by comparing it with base.

import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { moduleOfLocation, moduleSourceOf } from "../../../lib/ts/src/instance";
import { Ancestors, HealthRecord, ModelInfo, Problem, anchorProblem, canonical, checkSet, conflicts, migrateRecordTypes, recordHash, recordsOf, ruleSetHash } from "../../../lib/ts/src/health-records";
import { currentType } from "../../../lib/ts/src/health-rules";
import { Scenario, runScenarios } from "./scenarios";
import { RulesDoc } from "./rules";
import { CmdbItem, CmdbRel, Condition, SOURCE } from "./assess-model";
import { derive } from "./derive";

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const same = (a: unknown, b: unknown): boolean => canonical(a) === canonical(b);

export interface Held { why: "reach" | "conflict" | "replaces"; detail: string; at: string; reach?: Reach }
export interface Reach { with: number; without: number; leaves: boolean }
export interface RuleState {
  local?: "edited" | "deleted" | "added";
  by?: string;
  at?: string;
  note?: string;
  editedFrom?: HealthRecord | null; // as released when the site edited it
  upstream?: "changed" | "removed";
  reviewed?: string; // the hash of the release the site last looked at for this rule
  held?: Held;
  reach?: Reach; // recorded at install for a module's rule
}
export interface ScenarioState { retired: { by: string; at: string; note: string }; hash: string; upstream?: "changed" }
export interface State {
  rules: Record<string, RuleState>;
  scenarios: Record<string, ScenarioState>;
  origins: Record<string, { disabled?: { by: string; at: string; note?: string } }>;
  lastMerge?: { at: string; ok: boolean; problems: string[]; changed: string[]; hash: string };
}

/** A release of one origin: what the merge calls theirs. */
export interface Release { origin: string; records: HealthRecord[]; scenarios: Scenario[]; foundation: boolean; file: string; problems: string[] }

export const healthDir = (configDir: string): string => join(configDir, "health");
const emptyState = (): State => ({ rules: {}, scenarios: {}, origins: {} });

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf8"));
}
function writeJson(path: string, v: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(v, null, 2) + "\n");
  renameSync(tmp, path);
}

export function who(): string {
  return process.env.SUDO_USER || process.env.USER || "unknown";
}

/** The installed set: per origin its records, its base, the scenarios, the state. */
export class RuleStore {
  rules = new Map<string, HealthRecord[]>();
  base = new Map<string, HealthRecord[]>();
  scenarios = new Map<string, Scenario[]>();
  state: State = emptyState();

  constructor(readonly dir: string) {}

  /** Is there an installed set at all (a merge has run here)? */
  get installed(): boolean {
    return existsSync(join(this.dir, "rules"));
  }

  static read(dir: string): RuleStore {
    const s = new RuleStore(dir);
    const files = (sub: string): string[] => (existsSync(join(dir, sub)) ? readdirSync(join(dir, sub)).filter((f) => f.endsWith(".json")).sort() : []);
    for (const f of files("rules")) s.rules.set(f.slice(0, -5), recordsOf(readJson(join(dir, "rules", f)), f).records);
    for (const f of files("base")) s.base.set(f.slice(0, -5), recordsOf(readJson(join(dir, "base", f)), f).records);
    for (const f of files("scenarios")) {
      const doc = readJson(join(dir, "scenarios", f));
      s.scenarios.set(f.slice(0, -5), isObj(doc) && Array.isArray(doc.scenarios) ? (doc.scenarios as Scenario[]) : []);
    }
    if (existsSync(join(dir, "state.json"))) {
      const st = readJson(join(dir, "state.json"));
      if (isObj(st)) s.state = { ...emptyState(), ...(st as Partial<State>) } as State;
    }
    s.migrateTypes();
    return s;
  }

  /** The records, bases, edits and scenarios written before the condition
   *  types split, as they read now (health-rules.ts LEGACY_TYPES): base and
   *  ours the same way, so the three-way merge still sees what the site edited
   *  and keeps it. The ids of what changed; written by the next write. */
  migratedTypes: string[] = [];
  migrateTypes(): string[] {
    const changed = new Set<string>();
    const recs = (m: Map<string, HealthRecord[]>): void => {
      for (const [o, rs] of m) m.set(o, rs.map((r) => { const n = migrateRecordTypes(r); if (n !== r) changed.add(r.id); return n; }));
    };
    // A rule the site reviewed stays reviewed: the hash it noted is of base as written then.
    const rehash = new Map<string, string>();
    for (const rs of this.base.values()) for (const r of rs) { const n = migrateRecordTypes(r); if (n !== r) rehash.set(recordHash(r), recordHash(n)); }
    for (const st of Object.values(this.state.rules)) if (st.reviewed && rehash.has(st.reviewed)) st.reviewed = rehash.get(st.reviewed);
    recs(this.rules);
    recs(this.base);
    for (const [id, st] of Object.entries(this.state.rules)) {
      if (!st.editedFrom) continue;
      const n = migrateRecordTypes(st.editedFrom);
      if (n !== st.editedFrom) { st.editedFrom = n; changed.add(id); }
    }
    for (const scs of this.scenarios.values()) {
      for (const sc of scs) {
        const conds = (sc as unknown as { conditions?: { type: string; reason?: string }[] }).conditions ?? [];
        for (const c of conds) {
          const t = currentType(c.type, c.reason);
          if (t && t !== c.type) { c.type = t; changed.add(sc.id); }
        }
      }
    }
    this.migratedTypes = [...changed].sort();
    return this.migratedTypes;
  }

  write(): void {
    for (const [o, recs] of this.rules) writeJson(join(this.dir, "rules", `${o}.json`), { records: recs });
    for (const [o, recs] of this.base) writeJson(join(this.dir, "base", `${o}.json`), { records: recs });
    for (const [o, scs] of this.scenarios) writeJson(join(this.dir, "scenarios", `${o}.json`), { scenarios: scs });
    writeJson(join(this.dir, "state.json"), this.state);
  }

  /** Every installed record, as in the files. */
  all(): HealthRecord[] {
    return [...this.rules.values()].flat();
  }

  find(id: string): { origin: string; rec: HealthRecord } | null {
    for (const [origin, recs] of this.rules) {
      const rec = recs.find((r) => r.id === id);
      if (rec) return { origin, rec };
    }
    return null;
  }

  baseOf(id: string): HealthRecord | null {
    for (const recs of this.base.values()) {
      const r = recs.find((x) => x.id === id);
      if (r) return r;
    }
    return null;
  }

  /** What runs: every installed record, a held one and those of an origin the
   *  site switched off turned off. */
  active(): HealthRecord[] {
    const off = new Set(Object.entries(this.state.origins).filter(([, v]) => v.disabled).map(([k]) => k));
    return [...this.rules.entries()].flatMap(([origin, recs]) => recs.map((r) => (off.has(origin) || this.state.rules[r.id]?.held ? { ...r, enabled: false } : r)));
  }

  allScenarios(): Scenario[] {
    return [...this.scenarios.values()].flat();
  }

  retired(): Set<string> {
    return new Set(Object.keys(this.state.scenarios).filter((k) => this.state.scenarios[k].retired));
  }

  /** The per-rule state a rule in the file has, worked out against base: a hand
   *  edit is an edit like any other, author unknown. */
  localOf(id: string): RuleState["local"] | undefined {
    const st = this.state.rules[id];
    if (st?.local) return st.local;
    const ours = this.find(id)?.rec;
    const base = this.baseOf(id);
    if (ours && base && !same(ours, base)) return "edited";
    if (ours && !base) return "added";
    return undefined;
  }

  /** Is the rule pending: edited here, changed or removed upstream, not yet reviewed? */
  pending(id: string): boolean {
    const st = this.state.rules[id];
    if (!st?.upstream) return false;
    const b = this.baseOf(id);
    return !b || st.reviewed !== recordHash(b);
  }

  /** Put a record in its origin's file, replacing one of the same id, or add it. */
  put(origin: string, rec: HealthRecord): void {
    const recs = this.rules.get(origin) ?? [];
    const at = recs.findIndex((r) => r.id === rec.id);
    if (at >= 0) recs[at] = rec;
    else recs.push(rec);
    this.rules.set(origin, recs);
  }

  drop(id: string): void {
    for (const [o, recs] of this.rules) this.rules.set(o, recs.filter((r) => r.id !== id));
  }
}

// ── the releases ──────────────────────────────────────────────────────

interface Instance { name: string; moduleSource: string; status: string }

function instances(configDir: string): Instance[] {
  if (!existsSync(configDir)) return [];
  const out: Instance[] = [];
  for (const f of readdirSync(configDir).filter((x) => x.endsWith(".json")).sort()) {
    let raw: unknown;
    try {
      raw = readJson(join(configDir, f));
    } catch {
      continue;
    }
    if (!isObj(raw)) continue;
    const src = moduleSourceOf(raw);
    if (!src) continue;
    out.push({ name: f.slice(0, -5), moduleSource: src, status: typeof raw.status === "string" ? raw.status : "" });
  }
  return out;
}

/** The released core records: the directory beside the metamodel, in the
 *  tappaas-cicd source the site runs (TAPPAAS_HEALTH_CORE_DIR overrides). */
export function coreReleaseDir(configDir: string): string | null {
  if (process.env.TAPPAAS_HEALTH_CORE_DIR) return process.env.TAPPAAS_HEALTH_CORE_DIR;
  const cicd = instances(configDir).find((i) => moduleOfLocation(i.moduleSource) === "tappaas-cicd");
  return cicd ? join(cicd.moduleSource, "controller/cmdb-controller/metamodel/health") : null;
}

/** The release root: the repository the site verified, above src/foundation/tappaas-cicd. */
function releaseRoot(configDir: string): string | null {
  const core = coreReleaseDir(configDir);
  if (!core) return null;
  const m = /^(.*)\/src\/foundation\/tappaas-cicd\/controller\/cmdb-controller\/metamodel\/health\/?$/.exec(core);
  return m ? m[1] : null;
}

/** Read a release directory of core records and scenarios. */
export function readCoreRelease(dir: string): Release {
  const rel: Release = { origin: "core", records: [], scenarios: [], foundation: true, file: dir, problems: [] };
  if (!existsSync(dir)) return { ...rel, problems: [`no core records at ${dir}`] };
  for (const f of readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
    try {
      const got = recordsOf(readJson(join(dir, f)), f);
      rel.records.push(...got.records);
      rel.problems.push(...got.problems.map((p) => `${f}: ${p.message}`));
    } catch (e) {
      rel.problems.push(`${f}: ${(e as Error).message}`);
    }
  }
  const sdir = join(dir, "scenarios");
  if (existsSync(sdir)) {
    for (const f of readdirSync(sdir).filter((x) => x.endsWith(".json")).sort()) {
      try {
        const doc = readJson(join(sdir, f));
        if (isObj(doc) && Array.isArray(doc.scenarios)) rel.scenarios.push(...(doc.scenarios as Scenario[]));
        else rel.problems.push(`scenarios/${f}: expected { scenarios: [...] }`);
      } catch (e) {
        rel.problems.push(`scenarios/${f}: ${(e as Error).message}`);
      }
    }
  }
  return rel;
}

/** Every release the site has: core, and each installed module's
 *  <module>-health.json beside its source JSON. A module is foundation when its
 *  source is under src/foundation/ of the release the site verified. */
export function releases(configDir: string): Map<string, Release> {
  const out = new Map<string, Release>();
  const core = coreReleaseDir(configDir);
  if (core) out.set("core", readCoreRelease(core));
  const root = releaseRoot(configDir);
  for (const i of instances(configDir)) {
    if (i.status === "archived") continue;
    const module = moduleOfLocation(i.moduleSource);
    if (module === "tappaas-cicd" || out.has(module)) continue;
    const file = join(i.moduleSource, `${module}-health.json`);
    const foundation = !!root && i.moduleSource.replace(/\/+$/, "").startsWith(`${root}/src/foundation/`);
    const rel: Release = { origin: module, records: [], scenarios: [], foundation, file, problems: [] };
    if (existsSync(file)) {
      try {
        const doc = readJson(file);
        const got = recordsOf(doc, file);
        rel.records = got.records;
        rel.problems = got.problems.map((p) => p.message);
        if (isObj(doc) && Array.isArray(doc.scenarios)) rel.scenarios = doc.scenarios as Scenario[];
      } catch (e) {
        rel.problems.push((e as Error).message);
      }
    }
    out.set(module, rel);
  }
  return out;
}

/** The classes each module's components report, from the control-plane registry. */
export function reportedClasses(configDir: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let reg: unknown;
  try {
    reg = readJson(join(configDir, "control-plane.json"));
  } catch {
    return out;
  }
  const comps = isObj(reg) && Array.isArray(reg.components) ? (reg.components as unknown[]) : [];
  for (const c of comps) {
    if (!isObj(c) || !Array.isArray(c.reports)) continue;
    const m = typeof c.reportsFor === "string" ? c.reportsFor : typeof c.module === "string" ? c.module : "tappaas-cicd";
    out.set(m, [...(out.get(m) ?? []), ...(c.reports as unknown[]).filter((x): x is string => typeof x === "string")]);
  }
  return out;
}

/** The records a site runs: the installed set once a merge has run, else the
 *  core records of the release (before the first merge); null when neither reads. */
export function siteRecords(configDir: string): { records: HealthRecord[]; scenarios: Scenario[]; lastMerge?: State["lastMerge"]; problem?: string } {
  const store = RuleStore.read(healthDir(configDir));
  if (store.installed) return { records: store.active(), scenarios: store.allScenarios(), ...(store.state.lastMerge ? { lastMerge: store.state.lastMerge } : {}) };
  const dir = coreReleaseDir(configDir);
  const core = dir ? readCoreRelease(dir) : null;
  if (!core || core.problems.length) return { records: [], scenarios: [], problem: `none installed in ${healthDir(configDir)}, and the release's core records ${dir ? `at ${dir} do not read (${core?.problems.join("; ")})` : "were not found (no tappaas-cicd instance in config/)"}` };
  return { records: core.records, scenarios: core.scenarios };
}

// ── reach ─────────────────────────────────────────────────────────────

/** The most objects one failure a propagate record matches can impact, with
 *  and without it, on the site as it is; whether that reaches past the module. */
export function reachOf(rec: HealthRecord, others: HealthRecord[], model: RulesDoc, snap: { objects: CmdbItem[]; relations: CmdbRel[] }, now: string, origin: string): Reach {
  const none: Reach = { with: 0, without: 0, leaves: false };
  if (rec.kind !== "propagate" || rec.as === "none") return none;
  const w = rec.when;
  const anc = model.ancestors;
  const sel = w.provider ?? w.from ?? w.to;
  const classes = sel?.class === undefined ? null : Array.isArray(sel.class) ? sel.class : [sel.class];
  const provs = snap.objects.filter((o) => (!classes || classes.some((c) => (anc[o.class] ?? [o.class]).includes(c))) && (sel?.module === undefined || o.attributes.module === sel.module)).slice(0, 200);
  const cType = w.condition?.type;
  const cStatus = w.condition?.status;
  const type = (Array.isArray(cType) ? cType[0] : typeof cType === "string" ? cType : "operational") as Condition["type"];
  const status = (Array.isArray(cStatus) ? cStatus[0] : typeof cStatus === "string" ? cStatus : "critical") as Condition["status"];
  const byId = new Map(snap.objects.map((o) => [o.id, o]));
  let best = none;
  for (const p of provs) {
    const src = new Map<string, Condition[]>([[p.id, [{ type, status, reason: "reach", message: "reach", since: now, lastChecked: now, source: SOURCE, derived: false, rootCause: null, acknowledged: null, maintenance: null }]]]);
    const hit = (recs: HealthRecord[]): string[] => {
      const d = derive(snap.objects, new Map([...src].map(([k, v]) => [k, v.map((c) => ({ ...c }))])), snap.relations, { ...model, records: recs }, now);
      return [...d.conditions].filter(([id, cs]) => id !== p.id && cs.some((c) => c.type === "impact")).map(([id]) => id);
    };
    const withIt = hit([...others, rec]);
    if (withIt.length <= best.with) continue;
    const without = hit(others).length;
    best = { with: withIt.length, without, leaves: withIt.some((id) => byId.get(id)?.attributes.module !== origin) };
  }
  return best;
}

// ── the merge ─────────────────────────────────────────────────────────

export interface MergeChange { id: string; origin: string; what: "added" | "updated" | "removed" | "kept" | "upstream-changed" | "upstream-removed" | "in-step" | "stays-deleted" | "tombstone-dropped" | "held" | "renamed" }
/** ok: every release held. activate: the merged set holds and may be written;
 *  when not, the rules that ran before keep running. */
export interface MergeResult { ok: boolean; activate: boolean; changes: MergeChange[]; problems: Problem[]; before: string; after: string }

export interface MergeOpts {
  origins?: string[]; // only these; default: every origin with a release or an installed base
  now: string;
  model: ModelInfo & { records?: HealthRecord[] } & Partial<RulesDoc>;
  reports?: Map<string, string[]>; // classes each module reports (anchoring)
  snapshot?: { objects: CmdbItem[]; relations: CmdbRel[] }; // the site, for reach
  reachHold?: number; // objects: an app module's rule that reaches more is held
}

/** Merge each origin's release into the store, in place. The caller writes the store when ok. */
export function mergeReleases(store: RuleStore, rels: Map<string, Release>, opts: MergeOpts): MergeResult {
  const before = ruleSetHash(store.active());
  const res: MergeResult = { ok: true, activate: true, changes: [], problems: [], before, after: before };
  const origins = opts.origins ?? [...new Set([...rels.keys(), ...store.base.keys()])].filter((o) => o !== "site");
  const anc: Ancestors = opts.model.ancestors;
  const fresh = new Set<string>(); // ids this merge added or changed from a release
  for (const origin of origins) {
    const rel = rels.get(origin) ?? { origin, records: [], scenarios: [], foundation: false, file: "", problems: [] };
    // A module that ships no rules, and never did here: nothing to install.
    if (!rel.records.length && !rel.scenarios.length && !rel.problems.length && !store.base.has(origin) && !store.rules.has(origin) && !Object.keys(store.state.rules).some((id) => id.startsWith(`${origin}.`))) continue;
    // A release that does not parse or validate changes nothing.
    const relProblems = [...rel.problems];
    if (!relProblems.length) {
      for (const p of checkSet(rel.records, opts.model)) if (p.level === "error") relProblems.push(`${p.id}: ${p.message}`);
      if (origin !== "core") {
        for (const r of rel.records) {
          if (!r.id.startsWith(`${origin}.`)) relProblems.push(`${r.id}: a ${origin} record's id starts with ${origin}.`);
          const a = anchorProblem(r, origin, opts.reports?.get(origin) ?? [], anc);
          if (a) relProblems.push(`${r.id}: ${a}`);
        }
      } else for (const r of rel.records) if (!r.id.startsWith("core.")) relProblems.push(`${r.id}: a core record's id starts with core.`);
    }
    if (relProblems.length) {
      res.ok = false;
      for (const m of relProblems) res.problems.push({ level: "error", id: origin, message: `the released rules do not hold, nothing changed: ${m}` });
      continue;
    }
    const base = new Map((store.base.get(origin) ?? []).map((r) => [r.id, r]));
    const theirs = new Map(rel.records.map((r) => [r.id, r]));
    const ours = new Map((store.rules.get(origin) ?? []).map((r) => [r.id, r]));
    const ids = [...new Set([...base.keys(), ...theirs.keys(), ...ours.keys(), ...Object.keys(store.state.rules).filter((id) => id.startsWith(`${origin}.`) || (origin === "core" && id.startsWith("core.")))])];
    const order = [...rel.records.map((r) => r.id), ...[...ours.keys()].filter((id) => !theirs.has(id))];
    const next = new Map<string, HealthRecord>();
    const note = (id: string, what: MergeChange["what"]): void => void res.changes.push({ id, origin, what });
    for (const id of ids) {
      const b = base.get(id), t = theirs.get(id), o = ours.get(id);
      const st = store.state.rules[id] ?? {};
      if (st.local === "deleted" || (!o && b)) {
        // Deleted here (a tombstone, or gone from the file by hand).
        if (!t) {
          if (store.state.rules[id]) { delete store.state.rules[id]; note(id, "tombstone-dropped"); }
          continue;
        }
        store.state.rules[id] = { ...st, local: "deleted", by: st.by ?? "unknown", at: st.at ?? opts.now, ...(b && !same(b, t) ? { upstream: "changed" as const } : {}) };
        note(id, "stays-deleted");
        continue;
      }
      if (!o) {
        if (t) { next.set(id, t); fresh.add(id); note(id, "added"); }
        continue;
      }
      if (!b) {
        // Installed, never released before: the site's own (or a release this base never saw).
        if (t && same(o, t)) { delete store.state.rules[id]; next.set(id, o); note(id, "in-step"); }
        else if (t) { store.state.rules[id] = { ...st, local: st.local ?? "added", upstream: "changed" }; next.set(id, o); note(id, "upstream-changed"); }
        else next.set(id, o);
        continue;
      }
      const edited = !same(o, b);
      if (!edited) {
        if (!t) { note(id, "removed"); delete store.state.rules[id]; continue; }
        if (!same(t, b)) { next.set(id, t); fresh.add(id); note(id, "updated"); }
        else next.set(id, o);
        if (store.state.rules[id] && !store.state.rules[id].held && !store.state.rules[id].reach) delete store.state.rules[id];
        continue;
      }
      const local: RuleState = { ...st, local: "edited", by: st.by ?? "unknown", at: st.at ?? opts.now, editedFrom: st.editedFrom ?? b };
      if (!t) { store.state.rules[id] = { ...local, upstream: "removed" }; next.set(id, o); note(id, "upstream-removed"); continue; }
      if (same(o, t)) { delete store.state.rules[id]; next.set(id, o); note(id, "in-step"); continue; }
      if (same(t, b)) { store.state.rules[id] = local; next.set(id, o); note(id, "kept"); continue; }
      store.state.rules[id] = { ...local, upstream: "changed" };
      next.set(id, o);
      note(id, "upstream-changed");
    }
    // Renames: a released rule that replaces one edited here comes in held.
    for (const t of rel.records) {
      for (const old of t.replaces ?? []) {
        if (store.localOf(old) === "edited" || store.state.rules[old]?.local === "edited") {
          store.state.rules[t.id] = { ...(store.state.rules[t.id] ?? {}), held: { why: "replaces", detail: `replaces ${old}, which this site edited: keep one of the two`, at: opts.now } };
          note(t.id, "renamed");
        }
      }
    }
    store.rules.set(origin, order.filter((id) => next.has(id)).map((id) => next.get(id)!));
    store.base.set(origin, rel.records);
    store.scenarios.set(origin, rel.scenarios);
    for (const sc of rel.scenarios) {
      const s = store.state.scenarios[sc.id];
      if (s?.retired && s.hash !== recordHash(sc as unknown as HealthRecord)) s.upstream = "changed";
    }
  }

  // Checked before it is active: a newly released rule that conflicts with a
  // local one is held; the rest runs.
  for (;;) {
    const act = store.active();
    const pairs = conflicts(act, anc);
    let held = false;
    for (const [a, b] of pairs) {
      const [nu, loc] = fresh.has(a.id) && !fresh.has(b.id) ? [a, b] : fresh.has(b.id) && !fresh.has(a.id) ? [b, a] : [null, null];
      if (!nu || !loc) continue;
      store.state.rules[nu.id] = { ...(store.state.rules[nu.id] ?? {}), held: { why: "conflict", detail: `conflicts with ${loc.id}`, at: opts.now } };
      res.changes.push({ id: nu.id, origin: store.find(nu.id)?.origin ?? "", what: "held" });
      held = true;
    }
    if (!held) break;
  }
  // Reach, for each new or changed module rule: recorded; an app module's held over the threshold.
  if (opts.snapshot) {
    const rulesDoc = { relations: (opts.model.relations as RulesDoc["relations"]) ?? [], ancestors: anc, fields: opts.model.fields, records: [] } as RulesDoc;
    for (const id of fresh) {
      const f = store.find(id);
      if (!f || f.origin === "core" || f.origin === "site") continue;
      const others = store.active().filter((r) => r.id !== id && r.enabled !== false);
      const reach = reachOf(f.rec, others, rulesDoc, opts.snapshot, opts.now, f.origin);
      const st = (store.state.rules[id] = { ...(store.state.rules[id] ?? {}), reach });
      const foundation = rels.get(f.origin)?.foundation ?? false;
      if (!foundation && opts.reachHold !== undefined && reach.with > opts.reachHold && reach.with > reach.without && !st.held) {
        st.held = { why: "reach", detail: `one failure it matches can impact ${reach.with} objects (${reach.without} without it); this site holds an app module's rule over ${opts.reachHold}`, at: opts.now, reach };
        res.changes.push({ id, origin: f.origin, what: "held" });
      }
    }
  }
  const after = store.active();
  for (const p of checkSet(after, opts.model)) if (p.level === "error") { res.ok = false; res.activate = false; res.problems.push(p); }
  if (opts.model.relations) {
    const doc = { relations: opts.model.relations as RulesDoc["relations"], ancestors: anc, fields: opts.model.fields, records: after } as RulesDoc;
    for (const f of runScenarios(store.allScenarios(), doc, store.retired())) res.problems.push({ level: "warning", id: f.id, message: `the scenario no longer holds: ${f.problems.join("; ")}` });
  }
  res.after = ruleSetHash(after);
  store.state.lastMerge = { at: opts.now, ok: res.ok, problems: res.problems.map((p) => `${p.level}: ${p.id}: ${p.message}`), changed: [...new Set(res.changes.filter((c) => !["kept", "stays-deleted"].includes(c.what)).map((c) => c.id))], hash: res.after };
  return res;
}
