// perf.ts — timed raises of a CI's performance level (ADR-046 D3, P2):
// `health-manager perf <ci> --level --until`, `perf stop`, `perf list`, and the
// expiry `emit` runs after every assess.
//
// A raise is an investigation: one CI, one level (basic, service or trace —
// trace only this way), until a time that is always given. It is kept in
// config/performance-raises.json (the raises in force and the last 90 days),
// recorded on the CI in the CMDB (its `investigation` attribute: set on a raise,
// unset when it ends, so each is a change and a marker on its charts), and
// applied by rewriting the guest's metrics pipeline
// (tappaas-metrics-target.sh guest <module> apply): a runtime file its Alloy
// re-reads, no rebuild. The level the CI falls back to is its cascade
// (site → environment → module), which the same script computes.
//
// The contract the console reads (`perf list --json`) is ui/README.md's
// "The contract P2 and P4 implement".

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { writeFileGuarded } from "../../../lib/ts/src/config-io";
import { HealthObject } from "./emit-cmdb";

export type RaiseLevel = "basic" | "service" | "trace";

export interface RaiseRow {
  ci: { id: string; class: string; name: string };
  module: string | null; // the instance whose pipeline it drives; null: nothing of its own to collect
  level: RaiseLevel;
  resolution: "normal" | "fine";
  from: string; // the cascaded level it raised from
  by: string;
  note: string | null;
  started: string;
  until: string;
  ended: string | null;
  endedHow: "expired" | "stopped" | null;
  endedBy: string | null;
  change: number | null;
}

export interface RaiseStore {
  investigations: RaiseRow[];
  history: RaiseRow[];
}

/** What the perf verbs need from outside: the CMDB, the pipeline, the clock. */
export interface PerfContext {
  configDir: string;
  now: Date;
  actor: string;
  resolve(ref: string): HealthObject;
  /** Record the CI's investigation (null: ended) as a change; the change's id, or null when not recorded. */
  record(ci: RaiseRow["ci"], investigation: Record<string, unknown> | null, verb: string): number | null;
  /** The CI's module's cascaded level ({from, ...}) or null when it has none. */
  cascade(module: string): { from: string; source: string } | null;
  /** Rewrite the module's pipeline; its output lines and success. */
  apply(module: string): { ok: boolean; lines: string[] };
  /** Delete the CI's series from both stores. */
  purge(ciId: string): { ok: boolean; lines: string[] };
  say(line: string): void;
  warn(line: string): void;
}

const FILE = "performance-raises.json";
const KEEP_MS = 90 * 86400000;
const LEVELS: RaiseLevel[] = ["basic", "service", "trace"];

export class PerfError extends Error {}

export function readRaises(configDir: string): RaiseStore {
  const p = join(configDir, FILE);
  if (!existsSync(p)) return { investigations: [], history: [] };
  try {
    const d = JSON.parse(readFileSync(p, "utf8")) as Partial<RaiseStore>;
    return { investigations: Array.isArray(d.investigations) ? d.investigations : [], history: Array.isArray(d.history) ? d.history : [] };
  } catch {
    return { investigations: [], history: [] };
  }
}

function writeRaises(configDir: string, s: RaiseStore, now: Date): void {
  const cut = now.getTime() - KEEP_MS;
  const history = s.history.filter((r) => Date.parse(r.ended ?? r.until) >= cut).sort((a, b) => (b.ended ?? b.until).localeCompare(a.ended ?? a.until));
  writeFileGuarded(join(configDir, FILE), JSON.stringify({ investigations: s.investigations, history }, null, 2) + "\n");
}

/** The instance whose pipeline a CI drives: a vm, lxc or machine named as a deployed instance. */
function moduleOf(configDir: string, ci: HealthObject): string | null {
  if (!["vm", "lxc", "machine"].includes(ci.class)) return null;
  return existsSync(join(configDir, `${ci.name}.json`)) ? ci.name : null;
}

const every = (r: string): string => (r === "fine" ? "every 15 seconds" : "every minute");
const iso = (d: Date): string => d.toISOString().replace(/\.\d{3}Z$/, "Z");

function applyRow(ctx: PerfContext, module: string | null, what: string): void {
  if (!module) {
    ctx.say(`${what}: it runs no collector of its own; its numbers come from its node or the services on it`);
    return;
  }
  const r = ctx.apply(module);
  if (!r.ok) ctx.warn(`${module}'s metrics pipeline was not rewritten: ${r.lines.slice(-1)[0] ?? "no answer"}`);
  else ctx.say(`the guest's pipeline is rewritten: ${r.lines.filter((l) => !/^(un)?changed$/.test(l)).slice(-1)[0] ?? module}`);
}

export interface RaiseRequest {
  ref: string;
  level: string;
  resolution?: string;
  until: string | undefined; // already an ISO time
  note?: string;
}

/** `perf <ci> --level … --until …`: start, or replace, the CI's raise. */
export function perfRaise(ctx: PerfContext, req: RaiseRequest): RaiseRow {
  if (!LEVELS.includes(req.level as RaiseLevel)) throw new PerfError(`--level must be basic, service or trace (got '${req.level}')`);
  if (!req.until) throw new PerfError("--until is required: a raise always ends by itself (an ISO time, or 30m, 2h, 7d)");
  if (Date.parse(req.until) <= ctx.now.getTime()) throw new PerfError(`--until ${req.until} has already passed`);
  if (req.resolution && req.resolution !== "fine") throw new PerfError(`--resolution takes fine (got '${req.resolution}')`);
  const o = ctx.resolve(req.ref);
  const ci = { id: o.id, class: o.class, name: o.name };
  const module = moduleOf(ctx.configDir, o);
  const store = readRaises(ctx.configDir);
  const prev = store.investigations.find((r) => r.ci.id === ci.id && r.ended === null);
  const from = prev?.from ?? (module ? ctx.cascade(module)?.from : null) ?? "basic";
  const row: RaiseRow = {
    ci,
    module,
    level: req.level as RaiseLevel,
    resolution: req.resolution === "fine" ? "fine" : "normal",
    from,
    by: ctx.actor,
    note: req.note ?? prev?.note ?? null,
    started: prev?.started ?? iso(ctx.now),
    until: iso(new Date(req.until)),
    ended: null,
    endedHow: null,
    endedBy: null,
    change: null,
  };
  store.investigations = store.investigations.filter((r) => r !== prev);
  store.investigations.push(row);
  // The store first: the pipeline's render reads the raise from it.
  writeRaises(ctx.configDir, store, ctx.now);
  ctx.say(`raised to ${row.level}, ${every(row.resolution)}, until ${row.until} (it was ${from})`);
  applyRow(ctx, module, ci.name);
  const inv: Record<string, unknown> = { level: row.level, resolution: row.resolution, from, by: row.by, started: row.started, until: row.until };
  if (row.note) inv.note = row.note;
  row.change = ctx.record(ci, inv, `perf ${ci.name} --level ${row.level}${row.resolution === "fine" ? " --resolution fine" : ""} --until ${row.until}`);
  writeRaises(ctx.configDir, store, ctx.now);
  if (row.change !== null) ctx.say("recorded as a change on the object");
  return row;
}

function end(ctx: PerfContext, store: RaiseStore, row: RaiseRow, how: "expired" | "stopped"): number | null {
  store.investigations = store.investigations.filter((r) => r !== row);
  const ended: RaiseRow = { ...row, ended: how === "expired" ? row.until : iso(ctx.now), endedHow: how, endedBy: how === "stopped" ? ctx.actor : null };
  store.history.push(ended);
  writeRaises(ctx.configDir, store, ctx.now);
  applyRow(ctx, row.module, row.ci.name);
  const change = ctx.record(row.ci, null, how === "stopped" ? `perf stop ${row.ci.name}` : `perf ${row.ci.name} expired`);
  if (change !== null) {
    ended.change = change;
    writeRaises(ctx.configDir, store, ctx.now);
  }
  return change;
}

/** `perf stop <ci> [--purge]`: end the CI's raise now. */
export function perfStop(ctx: PerfContext, ref: string, purge = false): void {
  const o = ctx.resolve(ref);
  const store = readRaises(ctx.configDir);
  const row = store.investigations.find((r) => r.ci.id === o.id && r.ended === null);
  if (!row && !purge) throw new PerfError(`${o.name} has no investigation in force`);
  if (row) {
    const change = end(ctx, store, row, "stopped");
    ctx.say(`investigation ended: back to ${row.from}`);
    if (change !== null) ctx.say("recorded as a change on the object");
  }
  if (purge) perfPurge(ctx, o.id, o.name);
}

/** `perf purge <ci>`: delete what the stores hold of the CI. */
export function perfPurge(ctx: PerfContext, id: string, name: string): void {
  const r = ctx.purge(id);
  if (!r.ok) throw new PerfError(`${name}'s series were not deleted: ${r.lines.slice(-1)[0] ?? "the store did not answer"}`);
  ctx.say(`${name}'s series are deleted from the metrics store and its trends`);
}

/** Every raise past its time ends (emit, after each assess). The rows ended. */
export function perfExpire(ctx: PerfContext): RaiseRow[] {
  const store = readRaises(ctx.configDir);
  const due = store.investigations.filter((r) => r.ended === null && Date.parse(r.until) <= ctx.now.getTime());
  for (const r of due) {
    end(ctx, store, r, "expired");
    ctx.say(`investigation of ${r.ci.name} expired: back to ${r.from}`);
  }
  return due;
}

/** `perf list --json`: the console's contract. A raise past its time reads as history (expired). */
export function perfList(configDir: string, now: Date): { now: string; investigations: Omit<RaiseRow, "module">[]; history: Omit<RaiseRow, "module">[] } {
  const s = readRaises(configDir);
  const strip = ({ module: _m, ...r }: RaiseRow): Omit<RaiseRow, "module"> => r;
  const live = s.investigations.filter((r) => r.ended === null && Date.parse(r.until) > now.getTime());
  const lapsed = s.investigations.filter((r) => !live.includes(r)).map((r) => ({ ...r, ended: r.ended ?? r.until, endedHow: r.endedHow ?? ("expired" as const) }));
  const cut = now.getTime() - KEEP_MS;
  const history = [...lapsed, ...s.history].filter((r) => Date.parse(r.ended ?? r.until) >= cut).sort((a, b) => (b.ended ?? b.until).localeCompare(a.ended ?? a.until));
  return { now: iso(now), investigations: live.sort((a, b) => b.started.localeCompare(a.started)).map(strip), history: history.map(strip) };
}

export function perfListLines(doc: ReturnType<typeof perfList>): string[] {
  const out: string[] = [];
  if (!doc.investigations.length) out.push("No investigation in force.");
  for (const r of doc.investigations) out.push(`${r.ci.class}/${r.ci.name}: ${r.level}${r.resolution === "fine" ? " (fine)" : ""} until ${r.until}, by ${r.by}, from ${r.from}${r.note ? ` — ${r.note}` : ""}`);
  if (doc.history.length) out.push("", "Ended in the last 90 days:");
  for (const r of doc.history) out.push(`${r.ci.class}/${r.ci.name}: ${r.level} ${r.started} – ${r.ended} (${r.endedHow}${r.endedBy ? ` by ${r.endedBy}` : ""})`);
  return out;
}
