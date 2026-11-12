// openevents.ts — the open events by root cause, critical first, each with what
// it impacts (the Overview's alerts, GET health/events); what changed on an
// object in the last day (the Health page's root list and panel); and the
// discovery sweep the Assets page can start. Pure but for SweepRunner:
// reads.ts reads, this shapes.
//
// An open event is an object with a failing condition of its own: critical or
// warning, not derived, not acknowledged, not in a maintenance window. An
// `impact` condition is the symptom of another object's failure, so it is never
// an event of its own: it is that root's impact.
//
// Impact comes from the health document, not from GET /v1/objects/<id>/impact:
// every dependant that a root hurts names it in its derived condition's
// `rootCause`, which buildHealth has already collected per root (roots[].impacted),
// so it costs nothing, and it follows the relation types' `dependant` end where
// /impact walks every relation both ways.
//
// Recent changes come from GET /v1/objects/<id>/history: its `changes` (the
// change rows naming the object) and, by change id, the attributes and
// relations each one opened. The change stream (/v1/stream) says only which
// objects a change touched and nothing before the console started.

import { CmdbAttributePeriod, CmdbHistory } from "./cmdb";
import { HealthGraph, HealthNode, Issue, Status } from "./health";

export type EventStatus = "critical" | "warning";

const RANK: Record<Status, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

export interface OpsCondition {
  type: string;
  status: EventStatus;
  reason: string | null;
  message: string | null;
  since: string | null;
  flapping: boolean;
}

export interface OpsEvent {
  id: string;
  class: string;
  name: string;
  label: string;
  environment: string | null;
  module: string | null;
  // The worst of its own failing conditions; `conditions` holds them all, worst first.
  type: string;
  status: EventStatus;
  reason: string | null;
  message: string | null;
  since: string | null;
  flapping: boolean;
  conditions: OpsCondition[];
  isRoot: boolean; // other objects fail because of it
  rootCause: string[]; // the roots that explain it, when it has any
}

export interface OpsImpacted {
  id: string;
  class: string;
  label: string;
  status: Status;
}

export interface OpsGroup {
  root: string; // the event the group is headed by
  status: EventStatus; // the worst in the group
  since: string | null; // the earliest
  events: OpsEvent[]; // the root first
  impact: { count: number; objects: OpsImpacted[] };
}

export interface OpsChange {
  id: number;
  time: string;
  kind: string;
  source: string;
  verb: string | null;
  job: string | null;
  actor: string | null;
  drift: boolean;
  what: string[]; // the attributes it set, the relations it made or ended
}

export interface Operations {
  generated: string | null;
  hasConditions: boolean;
  counts: { critical: number; warning: number; groups: number; silenced: number };
  groups: OpsGroup[];
  windowHours: number;
  changes: Record<string, OpsChange[]>; // by object id
  changesError: Record<string, string>; // the objects whose history did not answer
  changesSkipped: string[]; // past the cap: not read
}

const failing = (i: Issue): boolean => i.status === "critical" || i.status === "warning";
const silenced = (i: Issue): boolean => i.acknowledged || i.maintenance;
const own = (i: Issue): boolean => failing(i) && !i.derived && i.type !== "impact";
const earliest = (a: string | null, b: string | null): string | null => (!a ? b : !b ? a : Date.parse(a) <= Date.parse(b) ? a : b);
const sinceMs = (s: string | null): number => (s ? Date.parse(s) : Number.POSITIVE_INFINITY);

function eventOf(n: HealthNode, roots: Set<string>): OpsEvent | null {
  const mine = n.issues.filter((i) => own(i) && !silenced(i)).sort((a, b) => RANK[b.status] - RANK[a.status] || sinceMs(a.since) - sinceMs(b.since) || a.type.localeCompare(b.type));
  const top = mine[0];
  if (!top) return null;
  return {
    id: n.id,
    class: n.class,
    name: n.name,
    label: n.label,
    environment: n.environment,
    module: n.module,
    type: top.type,
    status: top.status as EventStatus,
    reason: top.reason,
    message: top.message,
    since: top.since,
    flapping: mine.some((i) => i.flapping),
    conditions: mine.map((i) => ({ type: i.type, status: i.status as EventStatus, reason: i.reason, message: i.message, since: i.since, flapping: i.flapping })),
    isRoot: roots.has(n.id) || n.isRoot,
    rootCause: n.rootCause.filter((r) => r !== n.id),
  };
}

/** Every open event: an object with a failing condition of its own that nothing silences. */
export function openEvents(doc: HealthGraph): OpsEvent[] {
  const roots = new Set(doc.roots.map((r) => r.id));
  return doc.nodes.map((n) => eventOf(n, roots)).filter((e): e is OpsEvent => e !== null);
}

/** How many own failing conditions an acknowledgement or a window holds back. */
export function silencedCount(doc: HealthGraph): number {
  return doc.nodes.reduce((sum, n) => sum + n.issues.filter((i) => own(i) && silenced(i)).length, 0);
}

/**
 * The events by root cause: an event explained by another open event (its
 * rootCause, followed to the top) goes under that one; any other heads a group
 * of its own. Critical groups first, then the one that impacts most, then the
 * oldest; in a group the head first, then critical before warning, then by name.
 */
export function groupEvents(doc: HealthGraph, events: OpsEvent[]): OpsGroup[] {
  const byId = new Map(events.map((e) => [e.id, e]));
  const nodeOf = new Map(doc.nodes.map((n) => [n.id, n]));
  const rootOf = new Map(doc.roots.map((r) => [r.id, r]));
  const weight = (id: string): number => rootOf.get(id)?.impactedCount ?? 0;

  // The open root an event hangs under: the heaviest of its causes that is an
  // event itself, and that one's in turn; a cycle stops where it closes.
  const headOf = (e: OpsEvent): string => {
    const seen = new Set<string>([e.id]);
    let at = e;
    for (;;) {
      const next = at.rootCause
        .map((r) => byId.get(r))
        .filter((x): x is OpsEvent => !!x && !seen.has(x.id))
        .sort((a, b) => RANK[b.status] - RANK[a.status] || weight(b.id) - weight(a.id) || a.id.localeCompare(b.id))[0];
      if (!next) return at.id;
      seen.add(next.id);
      at = next;
    }
  };

  const groups = new Map<string, OpsEvent[]>();
  for (const e of events) {
    const h = headOf(e);
    groups.set(h, [...(groups.get(h) ?? []), e]);
  }

  const out: OpsGroup[] = [...groups.entries()].map(([root, list]) => {
    const evs = [...list].sort(
      (a, b) => Number(b.id === root) - Number(a.id === root) || RANK[b.status] - RANK[a.status] || a.label.localeCompare(b.label) || a.id.localeCompare(b.id),
    );
    const impacted = (rootOf.get(root)?.impacted ?? []).filter((id) => id !== root);
    const objects = impacted
      .map((id) => nodeOf.get(id))
      .filter((n): n is HealthNode => !!n)
      .map((n) => ({ id: n.id, class: n.class, label: n.label, status: n.status }))
      .sort((a, b) => RANK[b.status] - RANK[a.status] || a.class.localeCompare(b.class) || a.label.localeCompare(b.label));
    return {
      root,
      status: evs.some((e) => e.status === "critical") ? "critical" : "warning",
      since: evs.reduce<string | null>((s, e) => earliest(s, e.since), null),
      events: evs,
      impact: { count: Math.max(rootOf.get(root)?.impactedCount ?? 0, objects.length), objects },
    };
  });
  return out.sort(
    (a, b) => RANK[b.status] - RANK[a.status] || b.impact.count - a.impact.count || sinceMs(a.since) - sinceMs(b.since) || a.root.localeCompare(b.root),
  );
}

// What changes by itself and says nothing about an incident: an observation
// that set only these is left out ("what changed" is the operator's question,
// not the assessment's heartbeat).
const NOISE = new Set(["conditions", "lastSeen", "used", "leaseUntil"]);

interface HistoryRelation {
  type: string;
  direction: "in" | "out";
  other: { id: string; class: string; name: string };
  change?: number | null;
  from: string;
  to: string | null;
}

/**
 * The changes to one object within the window, newest first: each with what it
 * set (attributes by change id) and the relations it made or ended. A change
 * that is an observation and set nothing but volatile health is left out; a
 * change (a verb's run) or a sweep's record always stays.
 */
export function recentChanges(h: CmdbHistory, fromMs: number, untilMs = Number.POSITIVE_INFINITY): OpsChange[] {
  const periods = (h.attributes ?? []) as (CmdbAttributePeriod & { change?: number | null })[];
  const rels = ((h as CmdbHistory & { relations?: HistoryRelation[] }).relations ?? []) as HistoryRelation[];
  const out: OpsChange[] = [];
  for (const c of h.changes ?? []) {
    const t = Date.parse(c.time);
    if (!(t >= fromMs && t <= untilMs)) continue;
    const attrs = [...new Set(periods.filter((p) => p.change === c.id || (p.change == null && Date.parse(p.from) === t)).map((p) => p.name))].sort();
    const made = rels.filter((r) => r.change === c.id || (r.change == null && Date.parse(r.from) === t));
    const ended = rels.filter((r) => r.to !== null && Date.parse(r.to) === t && !made.includes(r));
    const relWord = (r: HistoryRelation, sign: string): string => `${sign}${r.type} ${r.direction === "out" ? "→" : "←"} ${r.other.class}/${r.other.name}`;
    const what = [...attrs, ...made.map((r) => relWord(r, "+")), ...ended.map((r) => relWord(r, "−"))];
    const quiet = c.kind === "observation" && c.verb !== "sweep" && !c.drift && (what.length === 0 || attrs.every((a) => NOISE.has(a))) && made.length === 0 && ended.length === 0;
    if (quiet) continue;
    out.push({ id: c.id, time: c.time, kind: c.kind, source: c.source, verb: c.verb, job: c.job, actor: c.actor, drift: (c as { drift?: boolean }).drift === true, what: what.filter((w) => !NOISE.has(w)) });
  }
  return out.sort((a, b) => Date.parse(b.time) - Date.parse(a.time) || b.id - a.id);
}

/** What changed on each root cause within the window: the Health page's line. */
export interface RootChanges {
  windowHours: number;
  changes: Record<string, OpsChange[]>; // by object id, newest first
  changesError: Record<string, string>;
  changesSkipped: string[];
}

export function rootChanges(histories: Map<string, CmdbHistory | Error>, skipped: string[], now: number): RootChanges {
  const changes: Record<string, OpsChange[]> = {};
  const changesError: Record<string, string> = {};
  const from = now - WINDOW_HOURS * 3600_000;
  for (const [id, h] of histories) {
    if (h instanceof Error) changesError[id] = h.message;
    else changes[id] = recentChanges(h, from, now);
  }
  return { windowHours: WINDOW_HOURS, changes, changesError, changesSkipped: skipped };
}

/** The objects whose history the page reads: every event's, in the page's order, at most `max`. */
export function changeTargets(groups: OpsGroup[], max: number): { read: string[]; skipped: string[] } {
  const all = groups.flatMap((g) => g.events.map((e) => e.id));
  return { read: all.slice(0, max), skipped: all.slice(max) };
}

export const WINDOW_HOURS = 24;

/** The document: the groups, and each event's changes from the histories read. */
export function operationsDoc(doc: HealthGraph | null, histories: Map<string, CmdbHistory | Error>, skipped: string[], now: number): Operations {
  const events = doc ? openEvents(doc) : [];
  const groups = doc ? groupEvents(doc, events) : [];
  const changes: Record<string, OpsChange[]> = {};
  const changesError: Record<string, string> = {};
  const from = now - WINDOW_HOURS * 3600_000;
  for (const [id, h] of histories) {
    if (h instanceof Error) changesError[id] = h.message;
    else changes[id] = recentChanges(h, from, now);
  }
  return {
    generated: doc?.generated ?? null,
    hasConditions: doc?.hasConditions ?? false,
    counts: {
      critical: events.filter((e) => e.status === "critical").length,
      warning: events.filter((e) => e.status === "warning").length,
      groups: groups.length,
      silenced: doc ? silencedCount(doc) : 0,
    },
    groups,
    windowHours: WINDOW_HOURS,
    changes,
    changesError,
    changesSkipped: skipped,
  };
}

// ── the discovery sweep (D15) ─────────────────────────────────────────

type Obj = Record<string, unknown>;

export interface SweepDifference {
  kind: string;
  class: string;
  name: string;
  id: string | null;
  source: string;
  attribute: string | null;
  before: unknown;
  after: unknown;
  expected: boolean;
}

export interface SweepRecord {
  id: number | null;
  time: string | null;
  since: string | null; // the sweep before; null: the baseline
  status: string;
  counts: Record<string, number>;
  sources: { source: string; ok: boolean; fallback: boolean; error: string | null; seconds: number | null }[];
  findings: SweepDifference[]; // what is not expected first, at most FINDINGS
  findingsTotal: number;
  expectedTotal: number;
}

export const FINDINGS = 200;

/** A sweep record (POST or GET /v1/sweep) as the page shows it: the findings before what a change explains. */
export function sweepRecord(d: Obj): SweepRecord {
  const diffs = (Array.isArray(d.differences) ? d.differences : []) as Obj[];
  const all: SweepDifference[] = diffs.map((x) => ({
    kind: String(x.kind ?? ""),
    class: String(x.class ?? ""),
    name: String(x.name ?? ""),
    id: typeof x.id === "string" ? x.id : null,
    source: String(x.source ?? ""),
    attribute: typeof x.attribute === "string" ? x.attribute : null,
    before: x.before ?? null,
    after: x.after ?? null,
    expected: x.expected === true,
  }));
  const findings = all.filter((x) => !x.expected);
  const counts = (d.counts && typeof d.counts === "object" ? d.counts : {}) as Record<string, unknown>;
  return {
    id: typeof d.id === "number" ? d.id : typeof d.id === "string" && d.id !== "" ? Number(d.id) : null,
    time: typeof d.time === "string" ? d.time : d.time instanceof Date ? d.time.toISOString() : null,
    since: typeof d.since === "string" ? d.since : null,
    status: typeof d.status === "string" ? d.status : "unknown",
    counts: Object.fromEntries(Object.entries(counts).filter(([, v]) => typeof v === "number")) as Record<string, number>,
    sources: ((Array.isArray(d.sources) ? d.sources : []) as Obj[]).map((s) => ({
      source: String(s.source ?? ""),
      ok: s.ok === true,
      fallback: s.fallback === true,
      error: typeof s.error === "string" ? s.error : null,
      seconds: typeof s.seconds === "number" ? s.seconds : null,
    })),
    findings: findings.slice(0, FINDINGS),
    findingsTotal: findings.length,
    expectedTotal: all.length - findings.length,
  };
}

export interface SweepApi {
  sweep(): Promise<Obj>; // POST /v1/sweep: runs it, answers its record (409 while one runs)
  lastSweep(): Promise<Obj | null>; // GET /v1/sweep; null: none has run
}

export interface SweepState {
  last: SweepRecord | null;
  lastError: string | null; // the last record could not be read
  running: { started: string; by: string | null } | null; // started from this console
  failed: { at: string; error: string } | null; // the last one this console started, when it failed
}

/**
 * The console's side of a sweep: POST /v1/sweep answers only when the sweep
 * has finished (hours on a big site), so it runs behind the request; the page
 * reads GET while it does. One at a time from here; the controller refuses a
 * second (409) whoever started the first, which `start` passes on when it
 * comes within `refuseMs`.
 */
export class SweepRunner {
  private running: SweepState["running"] = null;
  private failed: SweepState["failed"] = null;

  constructor(
    private readonly api: SweepApi,
    private readonly log: (line: string) => void = () => undefined,
    private readonly now: () => number = Date.now,
    private readonly refuseMs = 1500,
  ) {}

  get busy(): boolean {
    return this.running !== null;
  }

  async start(by: string | null): Promise<{ status: 202 | 409 | 502; running?: SweepState["running"]; error?: string }> {
    if (this.running) return { status: 409, error: `a sweep started here at ${this.running.started} is still running` };
    const running = { started: new Date(this.now()).toISOString(), by };
    this.running = running;
    this.failed = null;
    let early: { status: 409 | 502; error: string } | null = null;
    const run = this.api.sweep().then(
      (rec) => {
        this.log(`discovery sweep: ${String(rec.status ?? "done")}${by ? ` (started by ${by})` : ""}`);
      },
      (e: Error & { status?: number | null }) => {
        const refused = e.status === 409;
        early = { status: refused ? 409 : 502, error: e.message };
        if (!refused) this.failed = { at: new Date(this.now()).toISOString(), error: e.message };
        this.log(`discovery sweep: ${e.message}`);
      },
    ).then(() => {
      if (this.running === running) this.running = null;
    });
    // A refusal or a CMDB that does not answer comes at once; a sweep that runs does not.
    await Promise.race([run, new Promise<void>((r) => setTimeout(() => r(), this.refuseMs))]);
    const e = early as { status: 409 | 502; error: string } | null;
    if (e) return { status: e.status, error: e.error };
    return { status: 202, running };
  }

  async state(): Promise<SweepState> {
    let last: SweepRecord | null = null;
    let lastError: string | null = null;
    try {
      const d = await this.api.lastSweep();
      last = d ? sweepRecord(d) : null;
    } catch (e) {
      lastError = (e as Error).message;
    }
    return { last, lastError, running: this.running, failed: this.failed };
  }
}
