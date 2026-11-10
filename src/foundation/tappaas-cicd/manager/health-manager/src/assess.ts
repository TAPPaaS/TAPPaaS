// assess.ts — `health-manager assess`, the calculating half (ADR-041 D2) and the
// only writer of `conditions`: gather what the sources say, settle it against
// what was stored, derive (derive.ts), and write everything in one report.
//
// One condition per type per object. Over the sources, the worst wins; a failure
// is taken back only by the source that raised it, once it has looked again: a
// gate that skipped, or a guest it could not reach, leaves the failure standing
// with its old lastChecked. A condition whose status and reason hold keeps its
// since and message, and only lastChecked moves, which the store rewrites in
// place. What the operator set — acknowledged, maintenance — is carried over: a
// plain acknowledgement ends when the status changes, a sticky one at ok. So is
// what emit keeps on a condition (flapping, flappingHeld).

import { AlertItem } from "./alerts";
import { CmdbItem, CmdbRel, Condition, RootCause, RANK, SOURCE, SiteIndex, conditionsOf, failing } from "./assess-model";
import { OBSERVATION_REASONS, fromObservations } from "./assess-observations";
import { Finding, GATES, fromAlerts, fromCve, fromGates, fromSweep, fromThresholds } from "./assess-sources";
import { SweepRecord } from "./cmdbsweep";
import { derive } from "./derive";
import { RulesDoc } from "./rules";
import { ScanStatus } from "./security";
import { SiteSecurity, siteSecurity } from "./site-score";
import { CheckResult } from "./types";
import { CmdbReport } from "../../../lib/ts/src/cmdb";
import { CONDITION_TYPES, ConditionStatus } from "../../../lib/ts/src/health-rules";
import { levelChanged } from "./events";
import { Declared, PERF_OWNER, fromPerformance, fromTrends } from "./assess-performance";
import { MetricsReader } from "./metrics-read";

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

// The source that raised a reason: the one that can take it back. A pool's usage
// is a threshold's too, and that one runs every time.
function ownerOf(reason: string): string {
  if (reason.startsWith("alert-")) return "alerts";
  if (reason.startsWith("sweep-")) return "sweep";
  if (reason.startsWith("cve-")) return "cve";
  if (["pool-usage", "pool-state", "datastore-usage", "link-down", "vpn-handshake-stale", "certificate-expiry"].includes(reason)) return "thresholds";
  if (reason.startsWith("perf-") || reason === "capacity-trend") return PERF_OWNER;
  if (OBSERVATION_REASONS.includes(reason)) return "observations";
  return Object.entries(GATES).find(([, g]) => g.reason === reason)?.[0] ?? reason;
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
  since: now, lastChecked: now, source: SOURCE, derived: false, rootCause: null, acknowledged: null, maintenance: null,
});

/** What each object's source conditions are now: `fresh` over what was stored. */
export function settle(priorOf: (id: string) => Condition[], ids: Iterable<string>, findings: Finding[], looked: (owner: string, id: string) => boolean, now: string): Map<string, Condition[]> {
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
    const prior = priorOf(id).filter((c) => c.type !== "impact" && c.reason !== "roll-up" && c.reason !== "follows");
    for (const p of prior) {
      const fs = fresh.get(p.type);
      const again = !failing(p) || looked(ownerOf(p.reason), id);
      if (fs) {
        const f = worstOf(fs);
        cs.push(!again && RANK[f.status] < RANK[p.status] ? { ...p } : { ...blank(f, now), since: p.since });
      } else if (failing(p) && again) cs.push({ ...p, status: "ok", reason: "ok", message: "", lastChecked: now });
      else cs.push({ ...p });
      fresh.delete(p.type);
    }
    for (const fs of fresh.values()) cs.push(blank(worstOf(fs), now));
    if (cs.length) out.set(id, cs);
  }
  return out;
}

// What the operator set, across a change of status; since, across none.
function stamp(c: Condition, p: Condition | undefined, now: string, nowMs: number): Condition {
  if (!p) return c;
  const held = p.status === c.status && p.reason === c.reason;
  const until = (w: { until: string | null } | null): boolean => w !== null && (!w.until || Date.parse(w.until) > nowMs);
  let ack = c.acknowledged ?? p.acknowledged ?? null;
  if (!until(ack) || (ack && !held && (!ack.sticky || c.status === "ok"))) ack = null;
  const mnt = until(c.maintenance ?? p.maintenance ?? null) ? c.maintenance ?? p.maintenance ?? null : null;
  return {
    ...c,
    since: held ? p.since : now,
    message: held ? p.message : c.message,
    acknowledged: ack,
    maintenance: mnt,
    ...(p.flapping !== undefined ? { flapping: p.flapping } : {}),
    ...(p.flappingHeld !== undefined ? { flappingHeld: p.flappingHeld } : {}),
  };
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
  findings.push(...t("thresholds", () => fromThresholds(idx, nowMs)));
  ran.add("thresholds");
  const ended = t("cmdb ended", () => io.ended());
  findings.push(...t("observations", () => fromObservations(idx, ended, nowMs)));
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

  const model = t("rules", () => io.rules());
  const d = t("derive", () => derive(objects, source, relations, model, time));

  const result: AssessResult = { time, objects: [], rootCauses: d.rootCauses, transitions: [], report: null };
  const reported: NonNullable<CmdbReport["objects"]> = [];
  for (const o of objects) {
    const prior = priorOf(o.id);
    const byType = new Map(prior.map((c) => [c.type as string, c]));
    const made = d.conditions.get(o.id) ?? [];
    const next = made.map((c) => stamp(c, byType.get(c.type), time, nowMs));
    // What was impact or a roll-up and no longer is: over, not gone.
    for (const p of prior) {
      if (next.some((c) => c.type === p.type) || !p.derived) continue;
      next.push(stamp({ ...p, status: "ok", reason: "ok", message: "", rootCause: null, lastChecked: time }, p, time, nowMs));
    }
    next.sort((x, y) => typeOrder(x) - typeOrder(y));
    if (!next.length) continue;
    result.objects.push({ id: o.id, class: o.class, name: o.name, conditions: next });
    for (const c of next) {
      const p = byType.get(c.type);
      if (!p || p.status !== c.status || levelChanged(c.type, p, c)) result.transitions.push({ id: o.id, class: o.class, name: o.name, type: c.type, from: p?.status ?? null, to: c.status, reason: c.reason });
    }
    if (only && lasting(prior) === lasting(next)) continue;
    const attributes: Record<string, unknown> = { conditions: next };
    if (o.id === idx.site?.id) Object.assign(attributes, siteAttributes(o, d.rootCauses, checks, only !== null, time));
    reported.push({ id: o.id, class: o.class, name: o.name, attributes });
  }
  // The site may have no conditions at all, and still carries the run.
  if (idx.site && !reported.some((r) => r.id === idx.site!.id)) {
    const s = idx.site;
    reported.push({ id: s.id, class: s.class, name: s.name, attributes: siteAttributes(s, d.rootCauses, checks, only !== null, time) });
  }
  if (reported.length) result.report = { source: SOURCE, kind: "observation", assessment: true, time, objects: reported };
  if (result.report && !opts.dryRun) t("cmdb write", () => io.write(result.report!));
  return result;
}

function siteAttributes(site: CmdbItem, rootCauses: RootCause[], checks: CheckResult[], only: boolean, time: string): Record<string, unknown> {
  const had = (site.attributes.assessment ?? {}) as { gates?: unknown };
  // --only runs no gate: the table of the last full run stands.
  const gates = only ? had.gates ?? [] : checks.map(({ name, status, detail, rows, findings }) => ({ name, status, detail, rows, findings }));
  return { rootCauses, assessment: { time, gates } };
}
