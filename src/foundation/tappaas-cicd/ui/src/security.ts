// security.ts — /api/security: the site's CVE risk as the Security page shows it.
//
// The read is `health-manager report security --json`: the last scan, with the
// risk scores under `score` (health-manager's site-score.ts computes them; the
// console never does the maths). This keeps what the page shows and drops the
// rest: the site, its environments, zones and modules with level, score, what
// sets it, the state counts and seven days of scores, and each module's counted
// CVEs. Whether a fix exists is never passed on: no fix field leaves here.

import { levelRanges } from "../../lib/ts/src/score";

export type Level = "ok" | "low" | "medium" | "high" | "critical";
export type CveState = "decided" | "risk" | "open" | "carried";
export type CveMark = "unread" | "rule" | "confirmed" | "deferred" | "review" | "accepted";
const MARKS: CveMark[] = ["unread", "rule", "confirmed", "deferred", "review", "accepted"];

interface Agg {
  score: number;
  level: Level;
  setBy: { module: string | null; zone?: string | null };
  multiplier?: number;
}

interface RawUnit extends Agg {
  name: string;
  kind: "module" | "node" | "firewall";
  zones: string[];
  category: string | null;
  counted: number;
  counts: Record<CveState, number>;
  marks?: Partial<Record<CveMark, number>>;
  baselineOnly?: boolean;
  failed: string[];
  items: Record<string, unknown>[];
}

interface RawScore {
  generated: string;
  inventory?: string;
  site: Agg;
  environments: Record<string, Agg & { zones: string[] }>;
  zones: Record<string, Agg & { environments: string[]; tier: number | null }>;
  outside: string[];
  units: Record<string, RawUnit>;
  history?: { date: string; site: number; environments: Record<string, number>; zones: Record<string, number>; units: Record<string, number> }[];
}

export interface SecurityCve {
  id: string;
  state: CveState;
  severity: string;
  rating: string | null;
  pkg: string;
  version: string;
  analysis: string | null;
  carriedFrom: string | null;
  // The decision: what counts is `level`, how far anyone got with it is `mark`.
  mark: CveMark;
  level: string; // effective: critical … low, or none
  component: string | null; // <module>/<eco>:<source>
  reason: string | null;
  flags: string[]; // the ones a person acts on: kev, epss, review-due, needs-use, assumption, version, upstream-changed, expired, rule-expired
  old: string | null; // review: what was decided before ("none: not reachable")
  note: string | null; // deferred or accepted: the note
}

export interface QueueCard {
  title: string;
  text: string;
  worst: string;
  units: string[];
  count: number;
  baseline: boolean;
  action: string | null;
}

export interface SecurityQueues {
  operator: Record<string, QueueCard[]>; // update, coming, decision, tappaas, upstream
  maintainer: Record<string, QueueCard[]> | null; // move, decide, review, deferred — where the train runs
}

export interface SecurityRow {
  key: string;
  name: string;
  level: Level;
  score: number;
  setBy: string | null; // the module (and zone) that sets it, or what counts on a module
  spark: (number | null)[];
}

export interface SecurityUnit extends SecurityRow {
  kind: "module" | "node" | "firewall";
  counts: Record<CveState, number>;
  marks: Record<CveMark, number>;
  baselineOnly: boolean;
  failed: boolean;
  cves: SecurityCve[];
}

export interface SecurityZone extends SecurityRow {
  multiplier: number;
  tier: number | null;
  units: SecurityUnit[];
}

export interface SecurityEnvironment extends SecurityRow {
  zones: SecurityZone[];
}

export interface SecurityView {
  generated: string;
  inventory: string | null;
  days: string[]; // the sparkline's dates, oldest first
  site: SecurityRow;
  environments: SecurityEnvironment[];
  outside: SecurityZone[]; // zones in no environment: directly under the site
  failed: string[]; // units whose scan failed, not counted
  levels: { level: Level; from: number; to: number | null }[]; // each level's range of the score, highest first
  queues: SecurityQueues | null;
}

const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
const LEVELS: Level[] = ["ok", "low", "medium", "high", "critical"];
const levelOf = (v: unknown): Level => (LEVELS.includes(v as Level) ? (v as Level) : "ok");

export function lastDays(today: string, n = 7): string[] {
  const t = Date.parse(`${today}T00:00:00Z`);
  return Array.from({ length: n }, (_, i) => new Date(t - (n - 1 - i) * 86_400_000).toISOString().slice(0, 10));
}

// What counts most first: by effective level, then what needs someone (review,
// unread, by rule) before what is settled, then the id.
const MARK_ORDER: Record<CveMark, number> = { review: 0, unread: 1, rule: 2, deferred: 3, confirmed: 4, accepted: 5 };
const CAT_ORDER = ["critical", "high", "medium", "low", "none"];
const catRank = (c: SecurityCve): number => {
  const k = CAT_ORDER.indexOf(c.level);
  return k < 0 ? CAT_ORDER.length : k;
};
function byWeight(a: SecurityCve, b: SecurityCve): number {
  return catRank(a) - catRank(b) || MARK_ORDER[a.mark] - MARK_ORDER[b.mark] || a.id.localeCompare(b.id);
}
const SHOWN_FLAGS = ["kev", "epss", "review-due", "needs-use", "assumption", "version", "upstream-changed", "expired", "rule-expired"];
const markOf = (i: Record<string, unknown>): CveMark => {
  if (MARKS.includes(i.mark as CveMark)) return i.mark as CveMark;
  return i.state === "decided" || i.state === "risk" ? "confirmed" : i.state === "carried" ? "review" : "unread";
};
const levelOfItem = (i: Record<string, unknown>): string => {
  if (typeof i.level === "string" && i.level) return i.level;
  if (i.state === "decided") return "none";
  return String(i.state === "risk" && i.rating ? i.rating : i.severity ?? "").toLowerCase();
};
function card(c: Record<string, unknown>): QueueCard {
  return { title: String(c.title ?? ""), text: String(c.text ?? ""), worst: String(c.worst ?? ""), units: Array.isArray(c.units) ? c.units.map(String) : [],
    count: Array.isArray(c.cves) ? c.cves.length : 0, baseline: c.baseline === true, action: str(c.action) };
}
function cards(q: unknown): Record<string, QueueCard[]> {
  const out: Record<string, QueueCard[]> = {};
  for (const [k, v] of Object.entries((q ?? {}) as Record<string, unknown>)) out[k] = Array.isArray(v) ? v.map((c) => card(c as Record<string, unknown>)) : [];
  return out;
}

export function securityView(raw: Record<string, unknown> | null): SecurityView | null {
  const s = raw?.score as RawScore | undefined;
  if (!s || !s.site || !s.units) return null;
  const days = lastDays(s.generated.slice(0, 10));
  const hist = s.history ?? [];
  const spark = (pick: (h: NonNullable<RawScore["history"]>[number]) => number | undefined): (number | null)[] =>
    days.map((d) => {
      const h = hist.find((x) => x.date === d);
      const v = h ? pick(h) : undefined;
      return typeof v === "number" ? v : null;
    });
  const nameOf = (k: string | null): string | null => (k ? s.units[k]?.name ?? k : null);
  const by = (a: Agg, withZone: boolean): string | null =>
    a.setBy.module ? `${nameOf(a.setBy.module)}${withZone && a.setBy.zone ? ` in ${a.setBy.zone}` : ""}` : null;
  const unit = (key: string, u: RawUnit): SecurityUnit => ({
    key,
    name: u.name,
    kind: u.kind,
    level: levelOf(u.level),
    score: u.score,
    setBy: u.category ? `${u.counted} ${u.category}${u.baselineOnly ? ", NixOS baseline" : ""}` : null,
    spark: spark((h) => h.units[key]),
    counts: { open: u.counts?.open ?? 0, risk: u.counts?.risk ?? 0, carried: u.counts?.carried ?? 0, decided: u.counts?.decided ?? 0 },
    // A scan from before marks: counted from the items, one per CVE.
    marks: u.marks ? (Object.fromEntries(MARKS.map((m) => [m, u.marks?.[m] ?? 0])) as Record<CveMark, number>)
      : (Object.fromEntries(MARKS.map((m) => [m, new Set((u.items ?? []).filter((i) => markOf(i) === m).map((i) => String(i.id))).size])) as Record<CveMark, number>),
    baselineOnly: u.baselineOnly === true,
    failed: (u.failed ?? []).length > 0,
    // Field by field: whatever else the scan knows (a fixed version) stays behind.
    cves: (u.items ?? []).map((i) => ({
      id: String(i.id ?? ""),
      state: (["decided", "risk", "open", "carried"].includes(String(i.state)) ? i.state : "open") as CveState,
      severity: String(i.severity ?? ""),
      rating: str(i.rating),
      pkg: String(i.pkg ?? ""),
      version: String(i.version ?? ""),
      analysis: str(i.analysis),
      carriedFrom: str(i.carriedFrom),
      mark: markOf(i),
      level: levelOfItem(i),
      component: str(i.component),
      reason: str(i.reason),
      flags: Array.isArray(i.flags) ? i.flags.map(String).filter((f) => SHOWN_FLAGS.includes(f)) : [],
      old: i.old && typeof i.old === "object" ? `${String((i.old as Record<string, unknown>).level ?? "")}${(i.old as Record<string, unknown>).why ? `: ${String((i.old as Record<string, unknown>).why)}` : ""}` : null,
      note: str(i.note),
    })).sort(byWeight),
  });
  const zone = (z: string): SecurityZone => {
    const a = s.zones[z];
    const units = Object.entries(s.units)
      .filter(([, u]) => (u.zones ?? []).includes(z))
      .map(([k, u]) => unit(k, u))
      .sort((x, y) => y.score - x.score || x.name.localeCompare(y.name));
    return { key: z, name: z, level: levelOf(a?.level), score: a?.score ?? 0, setBy: a ? by(a, false) : null, multiplier: a?.multiplier ?? 1, tier: a?.tier ?? null, spark: spark((h) => h.zones[z]), units };
  };
  // A zone nothing runs in and nothing scores says nothing: left out.
  const shown = (z: SecurityZone): boolean => z.units.length > 0 || z.score > 0;
  const environments = Object.entries(s.environments)
    .map(([e, a]) => ({ key: e, name: e, level: levelOf(a.level), score: a.score, setBy: by(a, true), spark: spark((h) => h.environments[e]), zones: a.zones.map(zone).filter(shown) }))
    .sort((x, y) => y.score - x.score || x.name.localeCompare(y.name));
  return {
    generated: s.generated,
    inventory: s.inventory ?? null,
    days,
    site: { key: "site", name: "site", level: levelOf(s.site.level), score: s.site.score, setBy: by(s.site, true), spark: spark((h) => h.site) },
    environments,
    outside: s.outside.map(zone).filter(shown).sort((x, y) => y.score - x.score || x.name.localeCompare(y.name)),
    failed: Object.values(s.units).filter((u) => (u.failed ?? []).length > 0).map((u) => u.name).sort(),
    levels: levelRanges(),
    queues: raw?.queues ? {
      operator: cards((raw.queues as Record<string, unknown>).operator),
      maintainer: (raw.queues as Record<string, unknown>).maintainer ? cards((raw.queues as Record<string, unknown>).maintainer) : null,
    } : null,
  };
}

// A module's level and score, for its badge; null when the scan has no unit of
// that name.
export function moduleLevel(raw: Record<string, unknown> | null, module: string): { level: Level; score: number } | null {
  const u = (raw?.score as RawScore | undefined)?.units?.[module];
  return u ? { level: levelOf(u.level), score: u.score } : null;
}
