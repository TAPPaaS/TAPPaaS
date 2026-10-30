// ack.ts — acknowledgements and maintenance windows (ADR-041 D4). Both are
// members of a condition, so they are written with `conditions`.
//
// reconcileAcks holds the rules, for the verbs and for each emit alike:
//   - an ack ends at its `until`, on a return to ok, and (not sticky) at the next
//     status change, as Nagios's does; a maintenance window ends at its `until`;
//   - an impact condition is silenced while EVERY root it names has a holding
//     ack on the condition that makes it a root. It carries that as an ack with
//     `via`, so the console and validate read it like any other, and loses it as
//     soon as a root is unacknowledged or another root appears;
//   - a condition that appears inside a window joins the window.

import { Ack, Condition, HealthCmdb, HealthObject, RootEntry, conditionsOf, rootsOf, rootsOfSite } from "./emit-cmdb";
import { AckEvent, HealthEvent, Journal, MaintenanceEvent, eventLine } from "./events";

const liveUntil = (until: string | null | undefined, now: Date): boolean => !until || Date.parse(until) > now.getTime();

export const silenced = (c: Condition | undefined, now: Date): boolean =>
  !!c && ((!!c.acknowledged && liveUntil(c.acknowledged.until, now)) || (!!c.maintenance && liveUntil(c.maintenance.until, now)));

const clone = (objects: HealthObject[]): HealthObject[] =>
  objects.map((o) => ({ ...o, attributes: { ...o.attributes, ...(o.attributes.conditions ? { conditions: o.attributes.conditions.map((c) => ({ ...c })) } : {}) } }));

function ackEvent(event: "ack" | "unack", o: HealthObject, type: string, a: Ack, at: string, why: AckEvent["why"], symptoms: string[] = []): AckEvent {
  return { event, ci: o.id, class: o.class, name: o.name, type, by: a.by, note: a.note ?? "", sticky: a.sticky === true, until: a.until ?? null, why, symptoms, at };
}

function maintenanceEvent(phase: MaintenanceEvent["phase"], o: HealthObject, m: { until?: string | null; note?: string; by?: string }, at: string, why: MaintenanceEvent["why"]): MaintenanceEvent {
  return { event: "maintenance", phase, ci: o.id, class: o.class, name: o.name, by: m.by ?? "", note: m.note ?? "", until: m.until ?? null, why, at };
}

export interface Reconciled {
  dirty: Set<string>; // the ids of the objects whose conditions changed
  events: HealthEvent[];
}

/** Bring the objects' acks and windows up to date, in place (see the header). */
export function reconcileAcks(objects: HealthObject[], roots: RootEntry[], now: Date): Reconciled {
  const at = now.toISOString();
  const dirty = new Set<string>();
  const events: HealthEvent[] = [];
  for (const o of objects) {
    const conds = conditionsOf(o);
    const window = conds.map((c) => c.maintenance).find((m) => m && liveUntil(m.until, now));
    let ended = false; // one event per object, however many conditions the window held
    for (const c of conds) {
      const a = c.acknowledged;
      if (a && !a.via) {
        const why = !liveUntil(a.until, now) ? "expired"
          : c.status === "ok" ? "recovered"
          : !a.sticky && a.at && c.since && Date.parse(c.since) > Date.parse(a.at) ? "changed"
          : null;
        if (why) {
          events.push(ackEvent("unack", o, c.type, a, at, why));
          c.acknowledged = null;
          dirty.add(o.id);
        }
      }
      if (c.maintenance && !liveUntil(c.maintenance.until, now)) {
        if (!window && !ended) events.push(maintenanceEvent("end", o, c.maintenance, at, "expired"));
        ended = true;
        c.maintenance = null;
        dirty.add(o.id);
      } else if (window && !c.maintenance) {
        c.maintenance = { ...window };
        dirty.add(o.id);
      }
    }
  }
  // After the expiries: a root's ack that just ended silences nothing.
  const byId = new Map(objects.map((o) => [o.id, o]));
  const rootAck = (id: string): Ack | undefined => {
    const entries = roots.filter((r) => r.id === id);
    if (!entries.length) return undefined;
    const held = conditionsOf(byId.get(id) ?? ({ attributes: {} } as HealthObject)).filter((c) => c.acknowledged && !c.acknowledged.via && entries.some((r) => !r.type || r.type === c.type));
    return held[0]?.acknowledged ?? undefined;
  };
  for (const o of objects) {
    for (const c of conditionsOf(o)) {
      if (c.type !== "impact" || c.status === "ok") {
        if (c.acknowledged?.via) {
          c.acknowledged = null;
          dirty.add(o.id);
        }
        continue;
      }
      const rs = rootsOf(c);
      const acks = rs.map(rootAck);
      const all = rs.length > 0 && acks.every(Boolean);
      if (c.acknowledged && !c.acknowledged.via) continue; // its own
      if (all && !c.acknowledged) {
        // Sticky, so assess leaves it: it lasts as long as the root's, decided here.
        c.acknowledged = { by: acks[0]!.by, note: acks[0]!.note, until: acks[0]!.until ?? null, sticky: true, at, via: rs };
        dirty.add(o.id);
      } else if (c.acknowledged && (!all || c.acknowledged.via!.join() !== rs.join())) {
        c.acknowledged = all ? { ...c.acknowledged, via: rs } : null;
        dirty.add(o.id);
      }
    }
  }
  return { dirty, events };
}

/** assess drops an ack or a window that has ended, so emit sees it gone, not
 *  ending: what the object held at the cursor and holds no more is told here.
 *  One gone for no such reason was the operator's verb, which told its own. */
export function endedBeforeEmit(before: HealthObject[], objects: HealthObject[], now: Date): HealthEvent[] {
  const at = now.toISOString();
  const events: HealthEvent[] = [];
  const current = new Map(objects.map((o) => [o.id, o]));
  for (const o of before) {
    const cur = current.get(o.id);
    if (!cur) continue;
    let ended = false;
    for (const c of conditionsOf(o)) {
      const n = conditionsOf(cur).find((x) => x.type === c.type);
      const a = c.acknowledged;
      if (a && !a.via && !n?.acknowledged) {
        const why = !liveUntil(a.until, now) ? "expired" : !n || n.status === "ok" ? "recovered" : n.status !== c.status || n.since !== c.since ? "changed" : null;
        if (why) events.push(ackEvent("unack", cur, c.type, a, at, why));
      }
      const m = c.maintenance;
      if (m && !n?.maintenance && !liveUntil(m.until, now) && !ended) {
        ended = true;
        events.push(maintenanceEvent("end", cur, m, at, "expired"));
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

function working(ctx: VerbContext, ref: string): { objects: HealthObject[]; target: HealthObject; roots: RootEntry[] } {
  const id = ctx.cmdb.resolve(ref).id;
  const objects = clone(ctx.cmdb.objects());
  const target = objects.find((o) => o.id === id);
  if (!target) throw new Error(`${ref} is not a live object`);
  return { objects, target, roots: rootsOfSite(objects) };
}

function commit(ctx: VerbContext, objects: HealthObject[], dirty: Set<string>, verb: string, events: HealthEvent[]): void {
  for (const o of objects) if (dirty.has(o.id)) ctx.cmdb.write(o, conditionsOf(o), { kind: "change", verb });
  ctx.journal(events.map(eventLine));
}

const via = (objects: HealthObject[], root: string): string[] =>
  objects.filter((o) => conditionsOf(o).some((c) => c.acknowledged?.via?.includes(root))).map((o) => o.id);

export interface AckRequest {
  ref: string;
  type?: string;
  note: string;
  until?: string;
  sticky: boolean;
}

/** Without a type: every condition of the object that is not ok. */
export function ack(ctx: VerbContext, q: AckRequest): HealthEvent[] {
  const { objects, target, roots } = working(ctx, q.ref);
  const at = ctx.now.toISOString();
  const conds = conditionsOf(target).filter((c) => (q.type ? c.type === q.type : c.status !== "ok"));
  if (!conds.length) throw new Error(`${target.name} has no ${q.type ? `${q.type} condition` : "condition that is not ok"} to acknowledge`);
  for (const c of conds) c.acknowledged = { by: ctx.actor, note: q.note, until: q.until ?? null, sticky: q.sticky, at };
  const r = reconcileAcks(objects, roots, ctx.now);
  r.dirty.add(target.id);
  const symptoms = via(objects, target.id);
  const events: HealthEvent[] = [...r.events, ...conds.map((c) => ackEvent("ack", target, c.type, c.acknowledged!, at, "operator", symptoms))];
  commit(ctx, objects, r.dirty, "ack", events);
  return events;
}

export function unack(ctx: VerbContext, ref: string, type?: string): HealthEvent[] {
  const { objects, target, roots } = working(ctx, ref);
  const at = ctx.now.toISOString();
  const conds = conditionsOf(target).filter((c) => c.acknowledged && (!type || c.type === type));
  if (!conds.length) throw new Error(`${target.name} has no acknowledged ${type ? `${type} ` : ""}condition`);
  const symptoms = via(objects, target.id);
  const events: HealthEvent[] = conds.map((c) => ackEvent("unack", target, c.type, c.acknowledged!, at, "operator", symptoms));
  for (const c of conds) c.acknowledged = null;
  const r = reconcileAcks(objects, roots, ctx.now);
  r.dirty.add(target.id);
  commit(ctx, objects, r.dirty, "unack", [...r.events, ...events]);
  return events;
}

export function maintenanceStart(ctx: VerbContext, ref: string, until: string, note: string): HealthEvent[] {
  const { objects, target, roots } = working(ctx, ref);
  const conds = conditionsOf(target);
  if (!conds.length) throw new Error(`${target.name} has no conditions yet: run health-manager assess first`);
  const m = { until, note, by: ctx.actor };
  for (const c of conds) c.maintenance = { ...m };
  const r = reconcileAcks(objects, roots, ctx.now);
  r.dirty.add(target.id);
  const events: HealthEvent[] = [...r.events, maintenanceEvent("start", target, m, ctx.now.toISOString(), "operator")];
  commit(ctx, objects, r.dirty, "maintenance", events);
  return events;
}

export function maintenanceStop(ctx: VerbContext, ref: string, phase: "end" | "cancel"): HealthEvent[] {
  const { objects, target, roots } = working(ctx, ref);
  const conds = conditionsOf(target).filter((c) => c.maintenance);
  if (!conds.length) throw new Error(`${target.name} is not in maintenance`);
  const m = conds[0].maintenance!;
  for (const c of conds) c.maintenance = null;
  const r = reconcileAcks(objects, roots, ctx.now);
  r.dirty.add(target.id);
  const events: HealthEvent[] = [...r.events, maintenanceEvent(phase, target, m, ctx.now.toISOString(), "operator")];
  commit(ctx, objects, r.dirty, "maintenance", events);
  return events;
}

export { clone as cloneObjects };
