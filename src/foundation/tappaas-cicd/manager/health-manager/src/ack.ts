// ack.ts — acknowledgements (ADR-041 D4), and the maintenance verb.
//
// reconcileAcks holds the rules, for the verbs and for each emit alike:
//   - an ack ends at its `until`, on a return to ok, and (not sticky) at the next
//     status change, as Nagios's does;
//   - an impact condition is silenced while EVERY root it names has a holding
//     ack on the condition that makes it a root. It carries that as an ack with
//     `via`, so the console and validate read it like any other, and loses it as
//     soon as a root is unacknowledged or another root appears.
//
// A maintenance window is a file (windows.ts), the one the alert receiver reads
// too: `maintenance <ci>` writes one, assess puts the conditions of what it
// covers in maintenance, and emit tells when one opens and when it ends.

import { Ack, Condition, HealthCmdb, HealthObject, RootEntry, conditionsOf, rootsOf, rootsOfSite } from "./emit-cmdb";
import { AckEvent, HealthEvent, Journal, MaintenanceEvent, eventLine } from "./events";
import { MAINTENANCE_DIR, Window, readWindows } from "./windows";
import { renameGuarded, unlinkGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";
import { mkdirSync } from "fs";
import { join } from "path";

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
    for (const c of conditionsOf(o)) {
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

/** assess drops an ack that has ended, so emit sees it gone, not ending: what
 *  the object held at the cursor and holds no more is told here. One gone for
 *  no such reason was the operator's verb, which told its own. */
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
