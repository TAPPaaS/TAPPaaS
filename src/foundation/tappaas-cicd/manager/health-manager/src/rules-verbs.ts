// rules-verbs.ts — the verbs that change what a site runs: add, edit, enable,
// disable, delete, restore, diff, take, keep, accept, scenario, merge, show.
//
// Each is a preview first and an apply second, as the console's jobs are:
// without --apply it prints what would change (the records, the check, the
// contract scenarios, and on the site as it is now the roots that appear or go
// and the objects whose colour changes) and writes nothing. Every write goes
// through the check; a set under which a contract scenario no longer holds
// needs --force, which the rule's state records. An apply that changes the
// active set recalculates health at once.

import { readFileSync } from "fs";
import { HealthRecord, Problem, canonical, checkSet, flatten, originOf, recordHash, recordsOf, ruleSetHash } from "../../../lib/ts/src/health-records";
import { RulesDoc, modelInfo } from "./rules";
import { RuleStore, healthDir, mergeReleases, releases, reportedClasses, who } from "./rulestore";
import { Snapshot, diffLines, diffSim, simulate, telling, tellingLines } from "./rules-tools";
import { runScenarios } from "./scenarios";
import { sentence } from "./rule-text";

export interface RulesEnv {
  configDir: string;
  meta: Pick<RulesDoc, "relations" | "ancestors" | "fields">; // the metamodel, from the controller
  snapshot?: () => Snapshot;
  now: () => string;
  recalc?: () => void; // assess, then emit: health under the new rules at once
  reachHold?: number; // site.json health.rules.reachHold: objects, or under 1 a share of the CIs; default a quarter
}

const same = (a: unknown, b: unknown): boolean => canonical(a) === canonical(b);
const flag = (args: string[], name: string): string | undefined => {
  const at = args.indexOf(name);
  if (at < 0) return undefined;
  if (!args[at + 1] || args[at + 1].startsWith("--")) throw new Error(`rules: ${name} needs a value`);
  return args[at + 1];
};
const all = (args: string[], name: string): string[] => args.flatMap((a, i) => (args[i - 1] === name ? [a] : []));
const VALUED = new Set(["--note", "--set", "--unset", "--file", "--field", "--origin", "--kind", "--state", "--fail", "--with", "--without"]);
const positional = (args: string[]): string[] => args.filter((a, i) => !a.startsWith("--") && !VALUED.has(args[i - 1]));

/** Set a dotted path in an object; null unsets. */
function setPath(o: Record<string, unknown>, path: string, v: unknown): void {
  const parts = path.split(".");
  let at: Record<string, unknown> = o;
  for (const p of parts.slice(0, -1)) {
    if (typeof at[p] !== "object" || at[p] === null || Array.isArray(at[p])) at[p] = {};
    at = at[p] as Record<string, unknown>;
  }
  const last = parts[parts.length - 1];
  if (v === null) delete at[last];
  else at[last] = v;
}
function getPath(o: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((x, p) => (typeof x === "object" && x !== null ? (x as Record<string, unknown>)[p] : undefined), o);
}
const parseValue = (s: string): unknown => {
  try {
    return JSON.parse(s);
  } catch {
    return s;
  }
};

/** A rule's local state after it changed: an edit against base, or the site's own. */
function marked(store: RuleStore, id: string, now: string, note?: string): void {
  const rec = store.find(id)?.rec;
  const base = store.baseOf(id);
  const st = store.state.rules[id] ?? {};
  if (!rec) return;
  if (originOf(id) === "site" || !base) {
    store.state.rules[id] = { ...st, local: "added", by: who(), at: now, ...(note ? { note } : {}) };
    return;
  }
  if (same(rec, base)) {
    const { local: _l, by: _b, at: _a, note: _n, editedFrom: _e, upstream: _u, reviewed: _r, ...rest } = st;
    if (Object.keys(rest).length) store.state.rules[id] = rest;
    else delete store.state.rules[id];
    return;
  }
  store.state.rules[id] = { ...st, local: "edited", by: who(), at: now, editedFrom: st.editedFrom ?? base, ...(note ? { note } : {}) };
}

/** Every field of a record as path → value, for the three-way view. */
function fields(r: HealthRecord | null | undefined): Map<string, string> {
  const out = new Map<string, string>();
  if (!r) return out;
  const { when: _w, ...top } = r as unknown as Record<string, unknown>;
  for (const [k, v] of Object.entries(top)) out.set(k, canonical(v));
  for (const [k, v] of Object.entries(flatten(r))) if (k !== "edge.declared" && k !== "edge.end") out.set(`when.${k}`, canonical(v));
  return out;
}

export function threeWay(store: RuleStore, id: string): { field: string; released: string | null; here: string | null; now: string | null; mark: "here" | "upstream" | "both" | "" }[] {
  const was = store.state.rules[id]?.editedFrom ?? store.baseOf(id);
  const ours = store.find(id)?.rec ?? null;
  const theirs = store.baseOf(id);
  const a = fields(was), b = fields(ours), c = fields(theirs);
  const keys = [...new Set([...a.keys(), ...b.keys(), ...c.keys()])].sort();
  return keys.map((k) => {
    const r = a.get(k) ?? null, h = b.get(k) ?? null, n = c.get(k) ?? null;
    const here = r !== h, up = r !== n;
    return { field: k, released: r, here: h, now: n, mark: here && up ? (h === n ? "" : "both") : here ? "here" : up ? "upstream" : "" };
  });
}

export function stateLine(store: RuleStore, id: string): string {
  const st = store.state.rules[id];
  const bits: string[] = [];
  const local = store.localOf(id);
  if (local) bits.push(local);
  if (st?.held) bits.push(`held: ${st.held.detail}`);
  if (store.pending(id)) bits.push(st?.upstream === "removed" ? "pending: removed upstream" : "pending: changed upstream");
  if (st?.reach) bits.push(`reach ${st.reach.with}${st.reach.leaves ? ", beyond its module" : ""}`);
  const origin = originOf(id);
  if (store.state.origins[origin]?.disabled) bits.push(`origin ${origin} off`);
  return bits.join("; ");
}

/** The verbs that write. Returns the exit code, or null when the verb is not one of them. */
export function cmdRulesWrite(rest: string[], env: RulesEnv, print: (l: string) => void): number | null {
  const [verb, ...args] = rest;
  const apply = args.includes("--apply");
  const force = args.includes("--force");
  const json = args.includes("--json");
  const note = flag(args, "--note");
  const dir = healthDir(env.configDir);
  const now = env.now();
  const model = (records: HealthRecord[]): RulesDoc => ({ ...env.meta, records } as RulesDoc);
  const read = (): RuleStore => {
    const s = RuleStore.read(dir);
    if (!s.installed) throw new Error("rules: no rules are installed on this site yet — health-manager rules merge --apply installs them");
    return s;
  };
  const one = (): string => {
    const id = positional(args)[0];
    if (!id) throw new Error(`rules ${verb}: name a rule`);
    return id;
  };

  // A change: made on a fresh copy, checked, previewed, written on --apply.
  const change = (summary: string, mutate: (s: RuleStore) => void): number => {
    const before = read();
    const work = read();
    mutate(work);
    const was = before.active(), is = work.active();
    const problems: Problem[] = checkSet(is, modelInfo(model(is))).filter((p) => p.level === "error");
    const failing = problems.length ? [] : runScenarios(work.allScenarios(), { ...model(is), scenarios: [] }, work.retired());
    const ids = new Set([...was.map((r) => r.id), ...is.map((r) => r.id)]);
    const lines: string[] = [summary];
    for (const id of [...ids].sort()) {
      const a = was.find((r) => r.id === id), b = is.find((r) => r.id === id);
      if (same(a, b)) continue;
      lines.push(!a ? `+ ${id}: ${sentence(b!)}` : !b ? `- ${id}` : `~ ${id}: ${sentence(b)}${b.enabled === false ? " [off]" : ""}`);
    }
    if (same(was, is) && same(before.state, work.state)) lines.push("nothing changes");
    for (const p of problems) lines.push(`refused: ${p.id}: ${p.message}`);
    for (const f of failing) lines.push(`scenario ${f.id} no longer holds: ${f.problems.join("; ")}${force ? " (forced)" : " — --force writes it anyway"}`);
    if (env.snapshot && !same(was, is)) {
      const snap = env.snapshot();
      const d = diffSim(simulate(snap, model(was), now, []), simulate(snap, model(is), now, []), snap.objects);
      const t = tellingLines(telling(snap, model(was), now), telling(snap, model(is), now), snap.objects);
      lines.push("on the site as it is now:", ...[...diffLines(d).filter((l) => l !== "no difference" || !t.length), ...t].map((l) => `  ${l}`));
    }
    if (problems.length || (failing.length && !force)) {
      for (const l of lines) print(l);
      return 1;
    }
    if (!apply) {
      for (const l of lines) print(l);
      print("nothing written: --apply writes it");
      return 0;
    }
    // Forced over failing scenarios: said once, on the rules this write changed.
    if (failing.length) {
      const over = `written with --force over ${failing.map((f) => `scenario ${f.id}`).join(", ")}`;
      for (const id of ids) {
        const a = was.find((r) => r.id === id), b = is.find((r) => r.id === id);
        const st = work.state.rules[id];
        if (same(a, b) || !st?.local) continue;
        work.state.rules[id] = { ...st, note: `${st.note ? `${st.note}; ` : ""}${over}` };
      }
    }
    work.write();
    for (const l of lines) print(l);
    if (ruleSetHash(was) !== ruleSetHash(is)) env.recalc?.();
    return 0;
  };

  switch (verb) {
    case "show": {
      const s = read();
      const id = one();
      const f = s.find(id);
      const base = s.baseOf(id);
      if (!f && !base) throw new Error(`rules show: no rule ${id}`);
      const by = s.all().filter((r) => (r.overrides ?? []).includes(id)).map((r) => r.id);
      let decides: number | undefined;
      if (env.snapshot && f) {
        const snap = env.snapshot();
        decides = simulate(snap, model(s.active()), now, []).derivation.trace.fired.get(id) ?? 0;
      }
      const out = { id, origin: originOf(id), state: stateLine(s, id) || "as released", sentence: sentence(f?.rec ?? base!), record: f?.rec ?? null, released: base, overrides: f?.rec.overrides ?? [], overriddenBy: by, decidesNow: decides, local: s.state.rules[id] ?? null };
      if (json) print(JSON.stringify(out, null, 2));
      else {
        print(`${id} (${out.origin}): ${f ? sentence(f.rec) : "deleted here"}`);
        print(`  state: ${out.state}`);
        if (decides !== undefined) print(`  decides ${decides} case(s) on the site now`);
        if (out.overrides.length) print(`  overrides: ${out.overrides.join(", ")}`);
        if (by.length) print(`  overridden by: ${by.join(", ")}`);
        print(JSON.stringify(f?.rec ?? base, null, 2));
      }
      return 0;
    }
    case "add": {
      const file = positional(args)[0];
      if (!file) throw new Error("rules add: name a file of site records");
      const got = recordsOf(JSON.parse(readFileSync(file, "utf8")), file);
      if (got.problems.length) throw new Error(`rules add: ${got.problems.map((p) => p.message).join("; ")}`);
      for (const r of got.records) if (originOf(r.id) !== "site") throw new Error(`rules add: ${r.id}: a site's own rule's id starts with site.`);
      return change(`add ${got.records.map((r) => r.id).join(", ")}`, (s) => {
        for (const r of got.records) {
          s.put("site", r);
          marked(s, r.id, now, note);
        }
      });
    }
    case "edit": {
      const id = one();
      const sets = all(args, "--set");
      const unsets = all(args, "--unset");
      const file = flag(args, "--file");
      if (!sets.length && !unsets.length && !file) throw new Error("rules edit: --set path=value, --unset path or --file F");
      return change(`edit ${id}`, (s) => {
        const f = s.find(id);
        if (!f) throw new Error(`rules edit: no rule ${id} installed`);
        let rec = JSON.parse(JSON.stringify(f.rec)) as Record<string, unknown>;
        if (file) {
          const doc = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
          rec = (Array.isArray(doc.records) ? (doc.records as Record<string, unknown>[]).find((r) => r.id === id) : doc) ?? rec;
          if (rec.id !== id) throw new Error(`rules edit: the file's record is ${String(rec.id)}, not ${id}`);
        }
        for (const kv of sets) {
          const eq = kv.indexOf("=");
          if (eq < 1) throw new Error(`rules edit: --set ${kv} is path=value`);
          if (kv.slice(0, eq) === "id" || kv.slice(0, eq) === "kind") throw new Error("rules edit: a rule's id and kind stay");
          setPath(rec, kv.slice(0, eq), parseValue(kv.slice(eq + 1)));
        }
        for (const p of unsets) setPath(rec, p, null);
        s.put(f.origin, rec as unknown as HealthRecord);
        marked(s, id, now, note);
      });
    }
    case "enable":
    case "disable": {
      const origin = flag(args, "--origin");
      if (origin) {
        return change(`${verb} every rule of ${origin}`, (s) => {
          if (verb === "disable") s.state.origins[origin] = { ...(s.state.origins[origin] ?? {}), disabled: { by: who(), at: now, ...(note ? { note } : {}) } };
          else delete s.state.origins[origin];
        });
      }
      const id = one();
      return change(`${verb} ${id}`, (s) => {
        const f = s.find(id);
        if (!f) throw new Error(`rules ${verb}: no rule ${id} installed`);
        const rec = { ...f.rec } as HealthRecord;
        if (verb === "enable") delete rec.enabled;
        else rec.enabled = false;
        if (verb === "enable" && s.baseOf(id)?.enabled === false) rec.enabled = true;
        s.put(f.origin, rec);
        marked(s, id, now, note);
      });
    }
    case "delete": {
      const id = one();
      return change(`delete ${id}`, (s) => {
        if (!s.find(id)) throw new Error(`rules delete: no rule ${id} installed`);
        s.drop(id);
        if (originOf(id) === "site" || !s.baseOf(id)) delete s.state.rules[id];
        else s.state.rules[id] = { ...(s.state.rules[id] ?? {}), local: "deleted", by: who(), at: now, ...(note ? { note } : {}) };
      });
    }
    case "restore": {
      const id = one();
      return change(`restore ${id} as released`, (s) => {
        const base = s.baseOf(id);
        if (!base) throw new Error(`rules restore: ${id} is not released`);
        s.put(originOf(id) === "core" ? "core" : originOf(id), base);
        delete s.state.rules[id];
      });
    }
    case "diff": {
      const s = read();
      const id = one();
      const rows = threeWay(s, id);
      if (json) print(JSON.stringify(rows, null, 2));
      else {
        print(`${id}: as released when edited | as it is here | as released now`);
        for (const r of rows) if (r.mark) print(`  ${r.field}: ${r.released ?? "—"} | ${r.here ?? "—"} | ${r.now ?? "—"}  (changed ${r.mark === "both" ? "in both" : r.mark})`);
        if (!rows.some((r) => r.mark)) print("  no difference");
      }
      return 0;
    }
    case "take": {
      const id = one();
      const field = flag(args, "--field");
      return change(field ? `take ${field} of ${id} as released now` : `take ${id} as released now`, (s) => {
        const base = s.baseOf(id);
        const f = s.find(id);
        if (!base) throw new Error(`rules take: ${id} is not released`);
        if (!field || !f) {
          s.put(f?.origin ?? originOf(id), base);
          delete s.state.rules[id];
          return;
        }
        const rec = JSON.parse(JSON.stringify(f.rec)) as Record<string, unknown>;
        setPath(rec, field, getPath(base, field) ?? null);
        s.put(f.origin, rec as unknown as HealthRecord);
        marked(s, id, now, note);
      });
    }
    case "keep": {
      const id = one();
      return change(`keep ${id} as edited`, (s) => {
        const base = s.baseOf(id);
        const st = s.state.rules[id];
        if (!st) throw new Error(`rules keep: ${id} has nothing pending`);
        const { upstream: _u, ...rest } = st;
        s.state.rules[id] = { ...rest, ...(base ? { reviewed: recordHash(base) } : {}) };
      });
    }
    case "accept": {
      const id = one();
      return change(`accept ${id}`, (s) => {
        const st = s.state.rules[id];
        if (!st?.held) throw new Error(`rules accept: ${id} is not held`);
        const { held: _h, ...rest } = st;
        if (Object.keys(rest).length) s.state.rules[id] = rest;
        else delete s.state.rules[id];
      });
    }
    case "scenario": {
      const [sub] = positional(args);
      const s = read();
      if (sub === "list" || !sub) {
        const rows = s.allScenarios().map((sc) => ({ id: sc.id, description: sc.description ?? "", ...(s.state.scenarios[sc.id] ?? {}) }));
        if (json) print(JSON.stringify(rows, null, 2));
        else for (const r of rows) print(`${r.id}${"retired" in r && r.retired ? ` [retired by ${r.retired.by}: ${r.retired.note}]${"upstream" in r && r.upstream ? " (changed upstream)" : ""}` : ""}: ${r.description}`);
        return 0;
      }
      const id = positional(args)[1];
      if (!id) throw new Error(`rules scenario ${sub}: name a scenario`);
      const sc = s.allScenarios().find((x) => x.id === id);
      if (!sc) throw new Error(`rules scenario ${sub}: no scenario ${id}`);
      if (sub === "retire") {
        if (!note) throw new Error("rules scenario retire: --note says why this site no longer holds to it");
        return change(`retire scenario ${id}`, (w) => void (w.state.scenarios[id] = { retired: { by: who(), at: now, note }, hash: recordHash(sc as unknown as HealthRecord) }));
      }
      if (sub === "restore") return change(`restore scenario ${id}`, (w) => void delete w.state.scenarios[id]);
      throw new Error("rules scenario: list, retire or restore");
    }
    case "merge": {
      const origins = all(args, "--origin");
      const store = RuleStore.read(dir);
      const snap = env.snapshot?.();
      const cis = snap ? snap.objects.filter((o) => (env.meta.ancestors[o.class] ?? []).includes("ci")).length : 0;
      const rels = releases(env.configDir);
      const res = mergeReleases(store, rels, {
        ...(origins.length ? { origins } : {}),
        now,
        model: { ...env.meta, relations: env.meta.relations },
        reports: reportedClasses(env.configDir),
        ...(snap ? { snapshot: snap, reachHold: env.reachHold === undefined ? Math.max(1, Math.floor(cis / 4)) : env.reachHold < 1 ? Math.max(1, Math.floor(cis * env.reachHold)) : env.reachHold } : {}),
      });
      const shown = res.changes.filter((c) => c.what !== "kept");
      if (json) print(JSON.stringify(res, null, 2));
      else {
        for (const c of shown) print(`${c.what}: ${c.id}`);
        for (const p of res.problems) print(`${p.level}: ${p.id}: ${p.message}`);
        if (!shown.length && !res.problems.length) print("nothing to merge");
      }
      if (!apply) {
        if (!json) print("nothing written: --apply writes it");
        return res.ok ? 0 : 1;
      }
      if (res.activate) store.write();
      else {
        // The rules that ran keep running; the site is told.
        const kept = RuleStore.read(dir);
        kept.state.lastMerge = store.state.lastMerge;
        if (kept.installed) kept.write();
      }
      if (res.activate && res.before !== res.after) env.recalc?.();
      return res.ok ? 0 : 1;
    }
    default:
      return null;
  }
}
