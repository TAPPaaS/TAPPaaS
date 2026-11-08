// emit.ts — one health event per condition transition (ADR-041 D2, D4).
//
// emit never computes health. It reads the conditions assess wrote, finds what
// changed since the last run in the periods of the `conditions` attribute, and
// tells it: a journal line per event (events.ts). The controller's change
// stream carries only its own change records and takes nothing from a client,
// so the console hears of a transition as the change report assess wrote.
//
// The cursor, config/.health-emit-cursor: the CMDB change id read up to, the
// time, and the root causes last told. A change id, not a time: a report's time
// is when its run began, and it may commit after a later run has read. The first
// run has nothing to compare: it records where it stands and tells only the
// current root causes.
//
// Flapping is Nagios's rule, over what the CMDB holds. Nagios samples the last
// 21 results; the history holds changes, not each unchanged check, so a "result"
// here is one of the last 20 assess intervals, changed or not, the oldest
// weighted 0.8 and the newest 1.15. Above 30 % it starts, below 25 % it ends. So
// a condition that stops changing stops flapping by itself, which is why every
// flapping condition is read on every run.

import { closeSync, existsSync, openSync, readFileSync, statSync } from "fs";
import { join } from "path";
import { cloneObjects, endedBeforeEmit, reconcileAcks, silenced } from "./ack";
import { Condition, HealthCmdb, HealthObject, Period, RootEntry, Status, conditionsOf, rootsOf, rootsOfSite, worse } from "./emit-cmdb";
import { EventKind, HealthEvent, Journal, RootCauseEvent, TransitionEvent, eventLine, levelChanged, levelRose } from "./events";
import { renameGuarded, simulating, unlinkGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";

export const CURSOR_FILE = ".health-emit-cursor";
const LOCK_FILE = ".health-emit.lock";
const LOCK_STALE_MS = 5 * 60 * 1000;
const BUCKETS = 20;
const WEIGHT_OLDEST = 0.8;
const WEIGHT_NEWEST = 1.15;
const FLAP_START = 30;
const FLAP_END = 25;
// A condition whose `since` is this close before the cursor is read again: the
// change id decides what is new, this only picks which objects to ask about.
const OVERLAP_MS = 15 * 60 * 1000;
export const DEFAULT_INTERVAL_MIN = 5;

export interface RootSeen {
  ci: string;
  class: string;
  name: string;
  type: string;
  symptoms: string[];
  impacted?: string; // the symptoms by class: "3 vm, 2 service"
}

export interface Cursor {
  time: string;
  change: number | null;
  roots: Record<string, RootSeen>; // by <ci>:<type>
}

export function readCursor(configDir: string): Cursor | null {
  try {
    const c = JSON.parse(readFileSync(join(configDir, CURSOR_FILE), "utf8")) as Cursor;
    return typeof c.time === "string" && !Number.isNaN(Date.parse(c.time)) ? { time: c.time, change: c.change ?? null, roots: c.roots ?? {} } : null;
  } catch {
    return null;
  }
}

export function writeCursor(configDir: string, c: Cursor): void {
  const f = join(configDir, CURSOR_FILE);
  writeFileGuarded(`${f}.tmp`, JSON.stringify(c) + "\n", "utf8");
  renameGuarded(`${f}.tmp`, f);
}

/** site.json's health.assessInterval, in minutes. */
export function assessInterval(configDir: string): number {
  try {
    const v = (JSON.parse(readFileSync(join(configDir, "site.json"), "utf8")) as { health?: { assessInterval?: unknown } }).health?.assessInterval;
    return Number.isInteger(v) && (v as number) >= 1 && (v as number) <= 60 ? (v as number) : DEFAULT_INTERVAL_MIN;
  } catch {
    return DEFAULT_INTERVAL_MIN;
  }
}

/** One status change of one condition, from two neighbouring periods. */
export interface Transition {
  type: string;
  from: Status;
  to: Status;
  at: string; // the period's start
  change: number;
  after?: Condition;
  before?: Condition;
}

const asConditions = (v: unknown): Condition[] => (Array.isArray(v) ? (v as Condition[]) : []);

/** Every status change in the periods. A condition first seen comes from
 *  unknown (absent is unknown, as in Kubernetes), and first seen ok is no news;
 *  one that goes away has returned to ok. */
export function transitions(periods: Period[]): Transition[] {
  const out: Transition[] = [];
  const sorted = [...periods].sort((a, b) => Date.parse(a.from) - Date.parse(b.from));
  let prev: Condition[] = [];
  for (const p of sorted) {
    const cur = asConditions(p.value);
    for (const type of new Set([...prev, ...cur].map((c) => c.type))) {
      const before = prev.find((c) => c.type === type);
      const after = cur.find((c) => c.type === type);
      const from = before?.status ?? "unknown";
      const to = after?.status ?? "ok";
      if ((from === to && !levelChanged(type, before, after)) || (!before && to === "ok")) continue;
      out.push({ type, from, to, at: p.from, change: Number(p.change), after, before });
    }
    prev = cur;
  }
  return out;
}

/** The percentage of change over the last 20 intervals, newest weighted higher. */
export function flapPercent(changes: number[], nowMs: number, intervalMs: number): number {
  let total = 0;
  let hit = 0;
  for (let i = 0; i < BUCKETS; i++) {
    const w = WEIGHT_OLDEST + (i * (WEIGHT_NEWEST - WEIGHT_OLDEST)) / (BUCKETS - 1);
    const end = nowMs - (BUCKETS - 1 - i) * intervalMs;
    total += w;
    if (changes.some((t) => t > end - intervalMs && t <= end)) hit += w;
  }
  return (hit / total) * 100;
}

export const flappingNow = (was: boolean, pct: number): boolean => (was ? pct >= FLAP_END : pct > FLAP_START);

function kindOf(to: Status, c: Condition | undefined, isRoot: boolean): EventKind {
  if (to === "ok") return "recovery";
  if (c?.type === "impact" || c?.derived) return "symptom";
  return isRoot ? "causal" : "symptom";
}

export interface EmitInput {
  now: Date;
  intervalMin: number;
  since?: string; // --since: everything after this, whatever the cursor says
}

export interface EmitResult {
  events: HealthEvent[];
  cursor: Cursor;
}

const rootKey = (id: string, type: string | undefined): string => `${id}:${type ?? ""}`;

/** A root's consequence, the objects it impacts by class, most first: "3 vm,
 *  2 service"; "nothing" when it impacts none. */
export function byClass(ids: string[], objects: HealthObject[]): string {
  const n = new Map<string, number>();
  for (const id of ids) {
    const cls = objects.find((o) => o.id === id)?.class || "object";
    n.set(cls, (n.get(cls) ?? 0) + 1);
  }
  return [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([cls, k]) => `${k} ${cls}`).join(", ") || "nothing";
}

function rootSet(objects: HealthObject[], roots: RootEntry[]): Record<string, RootSeen> {
  const out: Record<string, RootSeen> = {};
  for (const r of roots) {
    const o = objects.find((x) => x.id === r.id);
    const symptoms = objects
      .filter((x) => x.id !== r.id && conditionsOf(x).some((c) => c.type === "impact" && c.status !== "ok" && rootsOf(c).includes(r.id)))
      .map((x) => x.id)
      .sort();
    out[rootKey(r.id, r.type)] = { ci: r.id, class: o?.class ?? "", name: o?.name ?? "", type: r.type ?? "", symptoms, impacted: byClass(symptoms, objects) };
  }
  return out;
}

function rootEvents(was: Record<string, RootSeen>, now: Record<string, RootSeen>, at: string): RootCauseEvent[] {
  const out: RootCauseEvent[] = [];
  for (const [k, r] of Object.entries(now)) {
    if (was[k]?.symptoms.join() !== r.symptoms.join()) out.push({ event: "rootcause", ...r, impacted: r.impacted ?? "nothing", cleared: false, at });
  }
  for (const [k, r] of Object.entries(was)) {
    if (!now[k]) out.push({ event: "rootcause", ...r, symptoms: [], impacted: "nothing", cleared: true, at });
  }
  return out;
}

/** The objects worth a history read: only history tells what happened. */
function candidates(objects: HealthObject[], before: HealthObject[], cursorMs: number): HealthObject[] {
  const was = new Map(before.map((o) => [o.id, conditionsOf(o)]));
  const sig = (cs: Condition[]): string => cs.map((c) => `${c.type}=${c.status}`).sort().join();
  return objects.filter((o) => {
    const cs = conditionsOf(o);
    if (cs.some((c) => c.flapping)) return true;
    if (cs.some((c) => c.since && Date.parse(c.since) >= cursorMs - OVERLAP_MS)) return true;
    return sig(cs) !== sig(was.get(o.id) ?? []);
  });
}

/** Group the run's events by root: each lists the ids of the others in its group. */
function correlate(events: TransitionEvent[]): void {
  const groups = new Map<string, TransitionEvent[]>();
  const add = (k: string, e: TransitionEvent): void => void groups.set(k, [...(groups.get(k) ?? []), e]);
  for (const e of events) {
    if (e.root) add(e.ci, e);
    if (e.rootCause) add(e.rootCause, e);
  }
  for (const group of groups.values()) {
    for (const e of group) for (const o of group) if (o !== e && !e.correlated.includes(o.id)) e.correlated.push(o.id);
  }
}

export function emit(cmdb: HealthCmdb, cursor: Cursor | null, input: EmitInput): EmitResult & { writes: Set<string>; objects: HealthObject[] } {
  const at = input.now.toISOString();
  const intervalMs = input.intervalMin * 60 * 1000;
  const objects = cloneObjects(cmdb.objects());
  const roots = rootsOfSite(objects);
  const seen = cursor?.roots ?? {};
  const now = rootSet(objects, roots);
  const from = input.since ?? cursor?.time;
  const before = from ? cmdb.objects(from) : [];
  const gone = endedBeforeEmit(before, objects, input.now);
  const r = reconcileAcks(objects, roots, input.now);
  const dirty = new Set(r.dirty);
  const told: TransitionEvent[] = [];
  let change = cursor?.change ?? null;

  if (from) {
    const fromMs = Date.parse(from);
    const isNew = (t: Transition): boolean =>
      input.since !== undefined || cursor?.change === null || cursor === null ? Date.parse(t.at) > fromMs : t.change > cursor.change!;
    for (const o of candidates(objects, before, fromMs)) {
      const periods = cmdb.periods(o.id);
      for (const p of periods) change = Math.max(change ?? 0, Number(p.change));
      const all = transitions(periods);
      const conds = conditionsOf(o);
      for (const type of new Set([...all.map((t) => t.type), ...conds.filter((c) => c.flapping).map((c) => c.type)])) {
        const ofType = all.filter((t) => t.type === type);
        const fresh = ofType.filter(isNew);
        const c = conds.find((x) => x.type === type);
        const isRoot = roots.some((e) => e.id === o.id && (!e.type || e.type === type));
        const wasRoot = !!seen[rootKey(o.id, type)] || !!seen[rootKey(o.id, "")];
        const event = (t: { from: Status; to: Status; at: string; since?: string; after?: Condition; before?: Condition }, flap: Partial<TransitionEvent>): TransitionEvent => {
          const cond = t.after ?? t.before;
          const rs = rootsOf(t.after).length ? rootsOf(t.after) : rootsOf(t.before);
          return {
            event: "transition",
            id: `${o.id}:${type}:${Date.parse(t.at)}`,
            ci: o.id,
            class: o.class,
            name: o.name,
            type,
            from: t.from,
            to: t.to,
            reason: t.after?.reason ?? (t.after ? "" : "cleared"),
            message: cond?.message ?? "",
            kind: kindOf(t.to, cond, isRoot),
            rootCause: rs[0] ?? null,
            correlated: [],
            since: t.since ?? t.after?.since ?? t.at,
            at,
            flapping: false,
            ...flap,
            root: isRoot || (t.to === "ok" && wasRoot),
            symptoms: roots.find((e) => e.id === o.id)?.impactedCount ?? now[rootKey(o.id, type)]?.symptoms.length ?? 0,
            impacted: (now[rootKey(o.id, type)] ?? now[rootKey(o.id, "")])?.impacted ?? "nothing",
            silenced: silenced(c, input.now),
            ...(t.after && levelRose(o.class, type, t.before, t.after) ? { levelUp: true as const } : {}),
          };
        };
        const windowMs = BUCKETS * intervalMs;
        const recent = ofType.filter((t) => Date.parse(t.at) > input.now.getTime() - windowMs);
        const was = c?.flapping === true;
        const flapping = c ? flappingNow(was, flapPercent(recent.map((t) => Date.parse(t.at)), input.now.getTime(), intervalMs)) : false;
        if (c && !was && flapping && fresh.length) {
          const held = recent.reduce<Status>((w, t) => worse(worse(w, t.from), t.to), "ok");
          c.flapping = true;
          c.flappingHeld = held;
          dirty.add(o.id);
          told.push(event({ from: fresh[0].from, to: held, at, after: c }, { event: "flapping", phase: "start", flapping: true }));
        } else if (c && was && !flapping) {
          const held = c.flappingHeld ?? c.status;
          c.flapping = false;
          delete c.flappingHeld;
          dirty.add(o.id);
          told.push(event({ from: held, to: c.status, at, after: c }, { event: "flapping", phase: "end" }));
        } else if (!was) {
          for (const t of fresh) told.push(event(t, {}));
        }
      }
    }
    correlate(told);
  }

  const events: HealthEvent[] = [...gone, ...r.events, ...told, ...rootEvents(seen, now, at)];
  return { events, cursor: { time: at, change, roots: now }, writes: dirty, objects };
}

/** One run: under a lock, as the timer and the alert receiver may overlap. false
 *  when another run holds it; that run or the next one tells what this would. */
export function withEmitLock(configDir: string, fn: () => void): boolean {
  if (simulating()) {
    fn();
    return true;
  }
  const f = join(configDir, LOCK_FILE);
  try {
    if (existsSync(f) && Date.now() - statSync(f).mtimeMs > LOCK_STALE_MS) unlinkGuarded(f);
    closeSync(openSync(f, "wx"));
  } catch {
    return false;
  }
  try {
    fn();
  } finally {
    try {
      unlinkGuarded(f);
    } catch {
      // gone already: nothing holds it
    }
  }
  return true;
}

/** Write what the run changed, tell it, and only then move the cursor: a crash
 *  between the two tells an event twice rather than never. */
export function runEmit(cmdb: HealthCmdb, journal: Journal, configDir: string, input: Omit<EmitInput, "intervalMin">): HealthEvent[] {
  const r = emit(cmdb, readCursor(configDir), { ...input, intervalMin: assessInterval(configDir) });
  for (const o of r.objects) if (r.writes.has(o.id)) cmdb.write(o, conditionsOf(o), { kind: "observation" });
  journal(r.events.map(eventLine));
  writeCursor(configDir, r.cursor);
  return r.events;
}
