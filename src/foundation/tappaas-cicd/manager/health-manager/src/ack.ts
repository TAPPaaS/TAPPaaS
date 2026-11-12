// ack.ts — acknowledgements (ADR-041 D4), and the maintenance verb.
//
// The ack and unack verbs write the operator's word, per condition type, into
// the object's `acknowledgements` attribute: nothing else writes it, and they
// never write `conditions`, so an ack made while assess runs is not lost.
// assess takes a word newer than the one a condition last took and keeps the
// ack's lifecycle (assess.ts stamp): it ends at its `until`, on a return to ok,
// and (not sticky) at the next status change, as Nagios's does. An impact is
// silenced while every root it names holds an ack of its own (assess, `via`).
// The verb's effect shows on the conditions at the next assess.
//
// A maintenance window is a file (windows.ts), the one the alert receiver reads
// too: `maintenance <ci>` writes one, assess puts the conditions of what it
// covers in maintenance, and emit tells when one opens and when it ends.

import { Ack, Condition, HealthCmdb, HealthObject, OperatorWord, conditionsOf, rootsOf } from "./emit-cmdb";
import { AckEvent, HealthEvent, Journal, MaintenanceEvent, eventLine } from "./events";
import { MAINTENANCE_DIR, Window, readWindows } from "./windows";
import { renameGuarded, unlinkGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";
import { mkdirSync } from "fs";
import { join } from "path";

const liveUntil = (until: string | null | undefined, now: Date): boolean => !until || Date.parse(until) > now.getTime();

export const silenced = (c: Condition | undefined, now: Date): boolean =>
  !!c && ((!!c.acknowledged && liveUntil(c.acknowledged.until, now)) || (!!c.maintenance && liveUntil(c.maintenance.until, now)) || !!c.quieted);

const clone = (objects: HealthObject[]): HealthObject[] =>
  objects.map((o) => ({ ...o, attributes: { ...o.attributes, ...(o.attributes.conditions ? { conditions: o.attributes.conditions.map((c) => ({ ...c })) } : {}) } }));

function ackEvent(event: "ack" | "unack", o: HealthObject, type: string, a: Ack, at: string, why: AckEvent["why"], symptoms: string[] = []): AckEvent {
  return { event, ci: o.id, class: o.class, name: o.name, type, by: a.by, note: a.note ?? "", sticky: a.sticky === true, until: a.until ?? null, why, symptoms, at };
}

function maintenanceEvent(phase: MaintenanceEvent["phase"], o: HealthObject, m: { until?: string | null; note?: string; by?: string }, at: string, why: MaintenanceEvent["why"]): MaintenanceEvent {
  return { event: "maintenance", phase, ci: o.id, class: o.class, name: o.name, by: m.by ?? "", note: m.note ?? "", until: m.until ?? null, why, at };
}

/** assess ends an ack, so emit sees it gone, not ending: what the object held
 *  at the cursor and holds no more is told here. One gone for no such reason
 *  was the operator's verb, which told its own. */
export function endedBeforeEmit(before: HealthObject[], objects: HealthObject[], now: Date): HealthEvent[] {
  const at = now.toISOString();
  const events: HealthEvent[] = [];
  const current = new Map(objects.map((o) => [o.id, o]));
  for (const o of before) {
    const cur = current.get(o.id);
    if (!cur) continue;
    for (const c of conditionsOf(o)) {
      const n = conditionsOf(cur).find((x) => x.type === c.type);
      const a = c.acknowledged;
      if (a && !a.via && !n?.acknowledged) {
        const why = !liveUntil(a.until, now) ? "expired" : !n || n.status === "ok" ? "recovered" : n.status !== c.status || n.since !== c.since ? "changed" : null;
        if (why) events.push(ackEvent("unack", cur, c.type, a, at, why));
      }
    }
  }
  return events;
}

export interface VerbContext {
  cmdb: HealthCmdb;
  journal: Journal;
  now: Date;
  actor: string;
}

// What an acknowledgement of this root also silences: the objects its impact reaches.
const symptomsOf = (objects: HealthObject[], root: string): string[] =>
  objects.filter((o) => o.id !== root && conditionsOf(o).some((c) => c.type === "impact" && c.status !== "ok" && rootsOf(c).includes(root))).map((o) => o.id);

function say(ctx: VerbContext, target: HealthObject, words: Record<string, OperatorWord>, verb: string, events: HealthEvent[]): void {
  ctx.cmdb.write(target, { acknowledgements: words }, { kind: "change", verb });
  ctx.journal(events.map(eventLine));
}

export interface AckRequest {
  ref: string;
  type?: string;
  note: string;
  until?: string;
  sticky: boolean;
}

/** Without a type: every condition of the object that is not ok. */
export function ack(ctx: VerbContext, q: AckRequest): HealthEvent[] {
  const target = ctx.cmdb.resolve(q.ref);
  const at = ctx.now.toISOString();
  const conds = conditionsOf(target).filter((c) => (q.type ? c.type === q.type : c.status !== "ok"));
  if (!conds.length) throw new Error(`${target.name} has no ${q.type ? `${q.type} condition` : "condition that is not ok"} to acknowledge`);
  const words = { ...(target.attributes.acknowledgements ?? {}) };
  const a: Ack = { by: ctx.actor, note: q.note, until: q.until ?? null, sticky: q.sticky, at };
  for (const c of conds) words[c.type] = { ack: a, at };
  const symptoms = symptomsOf(ctx.cmdb.objects(), target.id);
  const events: HealthEvent[] = conds.map((c) => ackEvent("ack", target, c.type, a, at, "operator", symptoms));
  say(ctx, target, words, "ack", events);
  return events;
}

export function unack(ctx: VerbContext, ref: string, type?: string): HealthEvent[] {
  const target = ctx.cmdb.resolve(ref);
  const at = ctx.now.toISOString();
  const conds = conditionsOf(target).filter((c) => c.acknowledged && !c.acknowledged.via && (!type || c.type === type));
  if (!conds.length) throw new Error(`${target.name} has no acknowledged ${type ? `${type} ` : ""}condition`);
  const words = { ...(target.attributes.acknowledgements ?? {}) };
  for (const c of conds) words[c.type] = { ack: null, at };
  const symptoms = symptomsOf(ctx.cmdb.objects(), target.id);
  const events: HealthEvent[] = conds.map((c) => ackEvent("unack", target, c.type, c.acknowledged!, at, "operator", symptoms));
  say(ctx, target, words, "unack", events);
  return events;
}

// The window a `maintenance <ci>` opens: one per CI, named after it.
const ciWindow = (o: HealthObject): string => `ci-${o.class}-${o.name}`.replace(/[^A-Za-z0-9_.-]/g, "_");

/** Opens (or moves) the CI's window. emit tells it opened; assess silences
 *  the conditions of the CI and what runs on it. */
export function maintenanceStart(ctx: VerbContext, ref: string, until: string, note: string, dir: string = MAINTENANCE_DIR()): HealthEvent[] {
  const target = ctx.cmdb.resolve(ref);
  const name = ciWindow(target);
  const w: Window & { by: string } = { name, scope: [target.name], until: Math.floor(Date.parse(until) / 1000), reason: note, opened: ctx.now.toISOString(), by: ctx.actor };
  mkdirSync(dir, { recursive: true });
  const f = join(dir, `${name}.json`);
  writeFileGuarded(`${join(dir, `.${name}`)}.tmp`, JSON.stringify(w) + "\n", "utf8");
  renameGuarded(`${join(dir, `.${name}`)}.tmp`, f);
  return [maintenanceEvent("start", target, { until, note, by: ctx.actor }, ctx.now.toISOString(), "operator")];
}

/** Closes the CI's window; emit tells it ended. */
export function maintenanceStop(ctx: VerbContext, ref: string, phase: "end" | "cancel", dir: string = MAINTENANCE_DIR()): HealthEvent[] {
  const target = ctx.cmdb.resolve(ref);
  const name = ciWindow(target);
  const w = readWindows(dir).find((x) => x.name === name);
  if (!w) throw new Error(`${target.name} is not in maintenance (no window ${name})`);
  unlinkGuarded(join(dir, `${name}.json`));
  return [maintenanceEvent(phase, target, { until: new Date(w.until * 1000).toISOString(), note: w.reason, by: ctx.actor }, ctx.now.toISOString(), "operator")];
}

export { clone as cloneObjects };
