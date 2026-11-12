// assess.ts — `health-manager assess`, the calculating half (ADR-041 D2) and the
// only writer of `conditions`: gather what the sources say, settle it against
// what was stored, derive (derive.ts), and write everything in one report.
//
// One condition per type per object. Over the sources, the worst wins; a failure
// is taken back only by the source that raised it, once it has looked again: a
// gate that skipped, or a guest it could not reach, leaves the failure standing
// with its old lastChecked. A condition whose status and reason hold keeps its
// since and message, and only lastChecked moves, which the store rewrites in
// place. An acknowledgement is carried over: a plain one ends when the status
// changes, a sticky one at ok. So is what emit keeps on a condition (flapping,
// flappingHeld). Maintenance is the open window's that covers the object.

import { AlertItem } from "./alerts";
import { Acknowledged, CmdbItem, CmdbRel, Condition, DERIVED, RootCause, RANK, SOURCE, SiteIndex, conditionsOf, failing, isDerivedKind } from "./assess-model";
import { OBSERVATION_REASONS, fromObservations } from "./assess-observations";
import { Finding, GATES, fromAlerts, fromCve, fromGates, fromSweep, fromThresholds } from "./assess-sources";
import { SWEEP_MAX_AGE_MS, SweepRecord } from "./cmdbsweep";
import { derive } from "./derive";
import { RulesDoc } from "./rules";
import { STALE_DAYS, ScanStatus } from "./security";
import { SiteSecurity, siteSecurity } from "./site-score";
import { CheckResult } from "./types";
import { CmdbReport } from "../../../lib/ts/src/cmdb";
import { CONDITION_TYPES, ConditionStatus } from "../../../lib/ts/src/health-rules";
import { conflicts, recordHash, ruleSetHash } from "../../../lib/ts/src/health-records";
import { levelChanged } from "./events";
import { Declared, PERF_OWNER, fromPerformance, fromTrends } from "./assess-performance";
import { MetricsReader } from "./metrics-read";
import { Covered, Window, asMaintenance, coveredBy, named, windowOf, isOpen } from "./windows";

/** Everything assess reads and writes; tests stub it. */
export interface AssessIO {
  objects(): CmdbItem[];
  ended(): CmdbItem[]; // the CIs retired: what an address or a route may still point at
  relations(): CmdbRel[];
  rules(): RulesDoc;
  sweep(): SweepRecord | null;
  gates(): CheckResult[]; // only asked on a full run
  alerts(): { open: AlertItem[] | null; recent: AlertItem[] }; // open null: Grafana did not answer
  cve(): ScanStatus | null;
  security?(scan: ScanStatus): SiteSecurity; // the scan's risk scores, placed by config/ (without: no zones)
  // The metrics store (ADR-046 D6): null when logging or its credential is not here.
  metrics?(): MetricsReader | null;
  perfDeclared?(): Declared[]; // the foundation modules' declared thresholds
  modules?(): Set<string>; // the instances, to tell a CI's module
  horizonDays?(): number; // capacity: "full within" this many days is a warning
  windows?(): Window[]; // the maintenance windows (windows.ts): what they cover is in maintenance
  write(report: CmdbReport): void;
}

export interface AssessOpts {
  only?: string; // an object's id or name: the sources speak only for it, and no gate runs
  dryRun?: boolean;
  timed?: Timer; // told each phase's duration (--timing)
}

/** Told how long a phase took, in ms: a CMDB read, a source, a gate, the writing. */
export type Timer = (phase: string, ms: number) => void;

/** Runs `f` as the phase `name`, telling `timed` how long it took. */
export function lap<T>(timed: Timer | undefined, name: string, f: () => T): T {
  if (!timed) return f();
  const t0 = Date.now();
  try {
    return f();
  } finally {
    timed(name, Date.now() - t0);
  }
}

export interface Transition { id: string; class: string; name: string; type: string; from: ConditionStatus | null; to: ConditionStatus; reason: string }

export interface AssessResult {
  time: string;
  objects: { id: string; class: string; name: string; conditions: Condition[] }[];
  rootCauses: RootCause[];
  transitions: Transition[];
  report: CmdbReport | null; // null: nothing to write
}

// The source that raised a reason, for a condition stored before the owner
// was: the one that can take it back. A pool's usage is a threshold's too, and
// that one runs every time.
function ownerOf(reason: string): string {
  if (reason.startsWith("alert-")) return "alerts";
  if (reason.startsWith("sweep-")) return "sweep";
  if (reason.startsWith("cve-")) return "cve";
  if (["pool-usage", "pool-state", "datastore-usage", "link-down", "vpn-handshake-stale", "certificate-expiry"].includes(reason)) return "thresholds";
  if (reason.startsWith("perf-") || reason === "capacity-trend") return PERF_OWNER;
  if (OBSERVATION_REASONS.includes(reason)) return "observations";
  return Object.entries(GATES).find(([, g]) => g.reason === reason)?.[0] ?? reason;
}
const owner = (c: Condition): string => c.owner ?? ownerOf(c.reason);

// How long a judgement holds without its owner looking again. Past it an ok,
// or a failure (after a day at least), is unknown: nobody knows any more.
export const HOUR = 3600 * 1000;
const UNCHECKED_AFTER: Record<string, number> = { sweep: SWEEP_MAX_AGE_MS + HOUR, cve: (STALE_DAYS + 1) * 24 * HOUR };
export const maxAge = (own: string, failingToo: boolean): number => Math.max(UNCHECKED_AFTER[own] ?? HOUR, failingToo ? 24 * HOUR : 0);
// An unknown nobody has looked at for a week is no judgement at all: dropped.
const FORGET_UNKNOWN_MS = 7 * 24 * HOUR;

// An input not observed for this long is stale: a judgement over it is unknown.
// Two nightly discoveries: what the 5-minute refresh reports is never this old.
export const STALE_INPUT_MS = 48 * HOUR;

/** When a source last reported the object; null when none ever did. */
export function observedAt(o: CmdbItem): number | null {
  const ts = [...Object.values(o.seen ?? {}), ...(o.lastSeen ? [o.lastSeen] : [])].map((t) => Date.parse(t)).filter((t) => !Number.isNaN(t));
  return ts.length ? Math.max(...ts) : null;
}

/** A judgement over an object whose observations are stale is unknown. */
export function staleToUnknown(fs: Finding[], idx: SiteIndex, nowMs: number): Finding[] {
  return fs.map((f) => {
    const o = idx.byId.get(f.object);
    const at = o ? observedAt(o) : null;
    if (at === null || nowMs - at <= STALE_INPUT_MS || f.status === "unknown") return f;
    const was = f.status === "ok" ? "" : `; it was ${f.status}: ${f.message}`;
    return { ...f, status: "unknown", reason: "not-observed", message: `not observed since ${new Date(at).toISOString()}${was}` };
  });
}

function worstOf(fs: Finding[]): Finding {
  // unknown is no judgement: below ok here, between ok and warning on the object.
  const rank = (f: Finding): number => (f.status === "unknown" ? -1 : RANK[f.status]);
  const top = fs.reduce((w, f) => (rank(f) > rank(w) ? f : w));
  if (top.status === "ok") return top;
  const same = [...new Set(fs.filter((f) => f.status === top.status && f.reason === top.reason).map((f) => f.message).filter(Boolean))];
  return { ...top, message: same.join("; ") };
}

const blank = (f: Finding, now: string): Condition => ({
  type: f.type, status: f.status, reason: f.reason, message: f.message,
  since: now, lastChecked: now, source: SOURCE, owner: f.owner, derived: false, rootCause: null, acknowledged: null, maintenance: null,
});

/** What each object's source conditions are now: `fresh` over what was stored. */
export function settle(priorOf: (id: string) => Condition[], ids: Iterable<string>, findings: Finding[], looked: (owner: string, id: string) => boolean, now: string): Map<string, Condition[]> {
  const nowMs = Date.parse(now);
  const by = new Map<string, Map<string, Finding[]>>();
  for (const f of findings) {
    if (!by.has(f.object)) by.set(f.object, new Map());
    const m = by.get(f.object)!;
    m.set(f.type, [...(m.get(f.type) ?? []), f]);
  }
  const out = new Map<string, Condition[]>();
  for (const id of new Set([...ids, ...by.keys()])) {
    const cs: Condition[] = [];
    const fresh = by.get(id) ?? new Map<string, Finding[]>();
    // What derive computes is computed again, whole: none of it is carried.
    // Nor is an ok that only an explained symptom ever had.
    const prior = priorOf(id).filter((c) => !isDerivedKind(c) && !(c.derived && c.status === "ok"));
    for (const p of prior) {
      const fs = fresh.get(p.type);
      const own = owner(p);
      const again = looked(own, id);
      if (fs) {
        const f = worstOf(fs);
        cs.push(!again && failing(p) && RANK[f.status] < RANK[p.status] ? { ...p } : { ...blank(f, now), since: p.since });
      } else if (again) {
        // Its owner looked and has nothing to say: a failure is over, and an ok
        // or unknown nobody gives any more is no judgement.
        if (failing(p)) cs.push({ ...p, owner: own, status: "ok", reason: "ok", message: "", lastChecked: now });
      } else if (!p.owner && p.status === "ok") {
        // An ok stored before conditions carried their owner, that no source
        // gives now: "ok" names nobody who could confirm it, so it is no
        // judgement (absent reads as ok, and nothing is told).
      } else {
        const age = nowMs - Date.parse(p.lastChecked);
        if (p.status !== "unknown" && age > maxAge(own, failing(p))) {
          cs.push({ ...p, owner: own, status: "unknown", reason: "not-checked", message: `not checked since ${p.lastChecked}${p.message ? `; it was ${p.status}: ${p.message}` : ""}` });
        } else if (!(p.status === "unknown" && age > FORGET_UNKNOWN_MS)) cs.push({ ...p });
      }
      fresh.delete(p.type);
    }
    for (const fs of fresh.values()) cs.push(blank(worstOf(fs), now));
    if (cs.length) out.set(id, cs);
  }
  return out;
}

// What the operator and emit keep, each in an attribute of its own (one writer
// each, so nothing they write is lost to a run of this one):
//   acknowledgements  the ack and unack verbs: per type, the operator's last
//                     word ({ ack | null, at }). A word newer than the one this
//                     condition last took (operatorAt) is taken: an ack set, or
//                     cleared. From then on the ack's own lifecycle holds: it
//                     ends at its until, on a change of status (not sticky), or
//                     at ok (sticky).
//   flapping          emit's: per type, what it holds while the condition flaps.
// Both are projected onto the condition here, so every reader reads one shape.
export interface OperatorWord { ack: Acknowledged | null; at: string }
export const acksOf = (o: CmdbItem): Record<string, OperatorWord> => (o.attributes.acknowledgements as Record<string, OperatorWord> | undefined) ?? {};
export const flapsOf = (o: CmdbItem): Record<string, { held: ConditionStatus }> => (o.attributes.flapping as Record<string, { held: ConditionStatus }> | undefined) ?? {};

// Since, across no change of status; the maintenance of the open window that
// covers the object (windows.ts), never carried over.
function stamp(c: Condition, p: Condition | undefined, now: string, nowMs: number, cov: Covered | undefined, word: OperatorWord | undefined, flap: { held: ConditionStatus } | undefined): Condition {
  const window: Window | undefined = coveredBy(c, cov);
  const mnt = window ? asMaintenance(window) : null;
  const held = !!p && p.status === c.status && p.reason === c.reason;
  const until = (w: { until: string | null } | null): boolean => w !== null && (!w.until || Date.parse(w.until) > nowMs);
  const fresh = !!word && word.at > (p?.operatorAt ?? "");
  let ack = fresh ? word!.ack : p?.acknowledged?.via ? null : p?.acknowledged ?? null;
  // The lifecycle: a word just taken holds as given; one carried ends as Nagios's does.
  if (!until(ack) || (ack && !fresh && p && !held && (!ack.sticky || c.status === "ok")) || (ack && c.status === "ok" && !fresh)) ack = null;
  const operatorAt = fresh ? word!.at : p?.operatorAt;
  return {
    ...c,
    since: p ? (held ? p.since : now) : c.since,
    // A derived message (a roll-up's count) is recomputed every run.
    message: held && c.owner !== DERIVED ? p!.message : c.message,
    acknowledged: ack,
    maintenance: mnt,
    ...(operatorAt ? { operatorAt } : {}),
    ...(flap ? { flapping: true, flappingHeld: flap.held } : {}),
  };
}

// An impact is silenced while every root it names holds an ack of its own on
// the condition that makes it a root; it carries that ack with `via`.
function viaAcks(next: Map<string, Condition[]>, roots: RootCause[]): void {
  const rootAck = (id: string): Acknowledged | null => {
    const entries = roots.filter((r) => r.id === id);
    const own = (next.get(id) ?? []).find((c) => c.acknowledged && !c.acknowledged.via && entries.some((r) => r.type === c.type));
    return entries.length && own ? own.acknowledged : null;
  };
  for (const cs of next.values()) {
    for (const c of cs) {
      if (c.type !== "impact" || c.status === "ok" || (c.acknowledged && !c.acknowledged.via)) continue;
      const rs = c.rootCause ? [c.rootCause] : [];
      const acks = rs.map(rootAck);
      c.acknowledged = rs.length && acks.every(Boolean) ? { ...acks[0]!, sticky: true, via: rs } : null;
    }
  }
}

const typeOrder = (c: Condition): number => CONDITION_TYPES.indexOf(c.type);

// The parts history keeps: everything but lastChecked.
const lasting = (cs: Condition[]): string => JSON.stringify(cs.map(({ lastChecked: _, ...rest }) => rest));

export function assess(io: AssessIO, opts: AssessOpts, now: Date, gatesOverride?: CheckResult[]): AssessResult {
  const time = now.toISOString();
  const nowMs = now.getTime();
  const t = <T>(name: string, f: () => T): T => lap(opts.timed, name, f);
  const objects = t("cmdb objects", () => io.objects()).filter((o) => o.attributes.placeholder !== true);
  const relations = t("cmdb relations", () => io.relations());
  const idx = new SiteIndex(objects, relations);
  const only = opts.only ? idx.byId.get(opts.only) ?? objects.find((o) => o.name === opts.only) ?? null : null;
  if (opts.only && !only) throw new Error(`assess: no object ${opts.only} in the CMDB`);

  const checks = only ? [] : gatesOverride ?? t("gates", () => io.gates());
  const g = fromGates(checks, idx);
  const findings: Finding[] = [...g.findings];
  const ran = new Set(g.ran);
  const a = t("alerts", () => io.alerts());
  findings.push(...fromAlerts([...(a.open ?? []), ...a.recent], idx));
  if (a.open !== null) ran.add("alerts");
  const rec = t("sweep", () => io.sweep());
  findings.push(...fromSweep(rec, nowMs, idx));
  ran.add("sweep");
  findings.push(...t("thresholds", () => staleToUnknown(fromThresholds(idx, nowMs), idx, nowMs)));
  ran.add("thresholds");
  const ended = t("cmdb ended", () => io.ended());
  findings.push(...t("observations", () => staleToUnknown(fromObservations(idx, ended, nowMs), idx, nowMs)));
  ran.add("observations");
  const reader = io.metrics ? t("metrics", () => io.metrics!()) : null;
  if (reader) {
    const p = t("performance", () => fromPerformance(idx, reader, io.perfDeclared?.() ?? [], io.modules?.() ?? new Set()));
    const tr = t("trends", () => fromTrends(idx, reader, io.horizonDays?.() ?? 14));
    findings.push(...p.findings, ...tr.findings);
    // Both or neither: one owner takes back what either set.
    if (p.looked && tr.looked) ran.add(PERF_OWNER);
  }
  const scan = t("cve", () => io.cve());
  const sec = scan ? t("cve score", () => (io.security ? io.security(scan) : siteSecurity(scan, { placement: {}, zones: {} }))) : null;
  findings.push(...fromCve(scan, sec, nowMs, idx));
  if (scan) ran.add("cve");

  // The rules: two active records that can decide one case differently are a
  // conflict the check should have refused; the engine takes the more severe
  // outcome, and the site is told.
  const model = t("rules", () => io.rules());
  if (idx.site) {
    for (const [a, b] of conflicts(model.records, model.ancestors)) {
      findings.push({ object: idx.site.id, type: "drift", status: "warning", reason: "rules-conflict", message: `health records ${a.id} and ${b.id} decide one case differently — health-manager rules check`, owner: "rules" });
    }
    ran.add("rules");
  }

  const priorOf = (id: string): Condition[] => (idx.byId.get(id) ? conditionsOf(idx.byId.get(id)!) : []);
  const looked = (owner: string, id: string): boolean => {
    if (only && id !== only.id) return false;
    if (!ran.has(owner)) return false;
    // The site is where a gate puts what it could not place (fromGates), so a
    // gate that ran has looked at the site: a fallback it no longer makes is over.
    const judged = g.unjudged.get(owner);
    return !judged || judged.has(id) || id === idx.site?.id;
  };
  const scoped = only ? findings.filter((f) => f.object === only.id) : findings;
  const source = t("settle", () => settle(priorOf, objects.map((o) => o.id), scoped, looked, time));

  // An open window covers what its object would impact under the rules: one
  // simulated spread per object a window names.
  const open = (io.windows?.() ?? []).filter((w) => isOpen(w, nowMs));
  const cover = [...new Set(open.filter((w) => w.scope !== "site").flatMap((w) => [...named(w, objects)]))];
  const d = t("derive", () => derive(objects, source, relations, model, time, { cover }));
  const windows = windowOf(open, objects, nowMs, (id) => d.covers?.get(id) ?? new Map());
  const result: AssessResult = { time, objects: [], rootCauses: d.rootCauses, transitions: [], report: null };
  const reported: NonNullable<CmdbReport["objects"]> = [];
  const nextOf = new Map<string, Condition[]>();
  for (const o of objects) {
    const prior = priorOf(o.id);
    const byType = new Map(prior.map((c) => [c.type as string, c]));
    const made = d.conditions.get(o.id) ?? [];
    const words = acksOf(o);
    const flaps = flapsOf(o);
    const st = (c: Condition, p: Condition | undefined): Condition => stamp(c, p, time, nowMs, windows.get(o.id), words[c.type], flaps[c.type]);
    const next = made.map((c) => st(c, byType.get(c.type)));
    // What was a failing impact or roll-up and no longer is: over, not gone.
    // One that was ok already is simply not computed any more.
    for (const p of prior) {
      if (next.some((c) => c.type === p.type) || !p.derived || !failing(p)) continue;
      next.push(st({ ...p, status: "ok", reason: "ok", message: "", rootCause: null, lastChecked: time }, p));
    }
    next.sort((x, y) => typeOrder(x) - typeOrder(y));
    if (next.length) nextOf.set(o.id, next);
  }
  viaAcks(nextOf, d.rootCauses);
  for (const o of objects) {
    const next = nextOf.get(o.id);
    if (!next) continue;
    const prior = priorOf(o.id);
    const byType = new Map(prior.map((c) => [c.type as string, c]));
    result.objects.push({ id: o.id, class: o.class, name: o.name, conditions: next });
    for (const c of next) {
      const p = byType.get(c.type);
      if (!p || p.status !== c.status || levelChanged(c.type, p, c)) result.transitions.push({ id: o.id, class: o.class, name: o.name, type: c.type, from: p?.status ?? null, to: c.status, reason: c.reason });
    }
    if (only && lasting(prior) === lasting(next)) continue;
    const attributes: Record<string, unknown> = { conditions: next };
    if (o.id === idx.site?.id) Object.assign(attributes, siteAttributes(o, d.rootCauses, checks, only !== null, time, rulesOf(model.records, o)));
    reported.push({ id: o.id, class: o.class, name: o.name, attributes });
  }
  // The site may have no conditions at all, and still carries the run.
  if (idx.site && !reported.some((r) => r.id === idx.site!.id)) {
    const s = idx.site;
    reported.push({ id: s.id, class: s.class, name: s.name, attributes: siteAttributes(s, d.rootCauses, checks, only !== null, time, rulesOf(model.records, s)) });
  }
  if (reported.length) result.report = { source: SOURCE, kind: "observation", assessment: true, time, objects: reported };
  if (result.report && !opts.dryRun) t("cmdb write", () => io.write(result.report!));
  return result;
}

/** The rule set a run used: its hash, each active record's own hash, and,
 *  where the set differs from the last run's, the records that changed. */
export interface RulesStamp { hash: string; records: Record<string, string>; changed?: string[] }

function rulesOf(records: RulesDoc["records"], site: CmdbItem): RulesStamp {
  const active = records.filter((r) => r.enabled !== false);
  const stamp: RulesStamp = { hash: ruleSetHash(records), records: Object.fromEntries(active.map((r) => [r.id, recordHash(r)])) };
  const prior = ((site.attributes.assessment ?? {}) as { rules?: RulesStamp }).rules;
  if (prior?.hash && prior.hash !== stamp.hash) {
    const ids = new Set([...Object.keys(prior.records ?? {}), ...Object.keys(stamp.records)]);
    stamp.changed = [...ids].filter((id) => prior.records?.[id] !== stamp.records[id]).sort();
  }
  return stamp;
}

function siteAttributes(site: CmdbItem, rootCauses: RootCause[], checks: CheckResult[], only: boolean, time: string, rules: RulesStamp): Record<string, unknown> {
  const had = (site.attributes.assessment ?? {}) as { gates?: unknown };
  // --only runs no gate: the table of the last full run stands.
  const gates = only ? had.gates ?? [] : checks.map(({ name, status, detail, rows, findings }) => ({ name, status, detail, rows, findings }));
  return { rootCauses, assessment: { time, gates, rules } };
}
