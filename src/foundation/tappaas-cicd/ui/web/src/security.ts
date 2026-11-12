// security.ts — the Security page's shaping: the CVE risk read (/api/security)
// as rows, a level's colour and words, and the 7-day sparkline. Pure, so the
// unit tests run it without a DOM.

// The status colours a level is drawn in (ui.tsx's Level, the part used here).
type UiLevel = "pass" | "warn" | "fail" | "skip";

export type RiskLevel = "ok" | "low" | "medium" | "high" | "critical";
export type CveState = "decided" | "risk" | "open" | "carried";
export type CveMark = "unread" | "rule" | "confirmed" | "deferred" | "review" | "accepted";

export interface SecurityCve {
  id: string;
  state: CveState;
  severity: string;
  rating: string | null;
  pkg: string;
  version: string;
  analysis: string | null;
  carriedFrom: string | null;
  mark?: CveMark;
  level?: string;
  component?: string | null;
  reason?: string | null;
  flags?: string[];
  old?: string | null;
  note?: string | null;
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
  operator: Record<string, QueueCard[]>;
  maintainer: Record<string, QueueCard[]> | null;
}

export interface SecurityRow {
  key: string;
  name: string;
  level: RiskLevel;
  score: number;
  setBy: string | null;
  spark: (number | null)[];
}

export interface SecurityUnit extends SecurityRow {
  kind: "module" | "node" | "firewall";
  counts: Record<CveState, number>;
  marks?: Record<CveMark, number>;
  baselineOnly?: boolean;
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
  days: string[];
  site: SecurityRow;
  environments: SecurityEnvironment[];
  outside: SecurityZone[];
  failed: string[];
  levels?: { level: RiskLevel; from: number; to: number | null }[];
  queues?: SecurityQueues | null;
}

// The queues, in the order the page shows them, with their headings.
export const OPERATOR_QUEUES: { key: string; title: string; empty: string }[] = [
  { key: "update", title: "Update", empty: "No update is waiting that clears a CVE." },
  { key: "coming", title: "Coming", empty: "Nothing announced for the next release." },
  { key: "decision", title: "Your decision", empty: "Nothing needs your decision: this site runs as the records assume." },
  { key: "tappaas", title: "With TAPPaaS", empty: "Nothing waits on a TAPPaaS decision." },
  { key: "upstream", title: "With upstream", empty: "Nothing decided is waiting on an upstream fix." },
];
export const MAINTAINER_QUEUES: { key: string; title: string; empty: string }[] = [
  { key: "move", title: "Move a pin", empty: "No pin move clears anything today." },
  { key: "decide", title: "Decide", empty: "Every critical and high CVE has a decision." },
  { key: "review", title: "Review", empty: "Nothing to review." },
  { key: "deferred", title: "Deferred", empty: "Nothing is put off." },
];

// A queue card's level as a status colour: the worst CVE it holds.
export function cardTone(c: QueueCard): UiLevel {
  return c.worst === "critical" ? "fail" : c.worst === "high" || c.worst === "medium" ? "warn" : "pass";
}

// The score's ranges in one line: "critical 30 and above · high 16–29 · … · ok 0".
export function levelsText(levels: SecurityView["levels"]): string {
  return (levels ?? [])
    .map((l) => `${l.level} ${l.to === null ? `${l.from} and above` : l.from === l.to ? `${l.from}` : `${l.from}–${l.to}`}`)
    .join(" · ");
}

// The status colour of a level, as health has it: ok and low are fine, medium
// and high need attention, critical is broken.
export function riskTone(l: RiskLevel | "unknown"): UiLevel {
  return l === "critical" ? "fail" : l === "high" || l === "medium" ? "warn" : l === "unknown" ? "skip" : "pass";
}

// The level and score as one phrase: "high, 20".
export const riskText = (r: { level: RiskLevel; score: number }): string => (r.level === "ok" ? "ok" : `${r.level}, ${r.score}`);

export const unitLabel = (u: SecurityUnit): string => (u.kind === "node" ? `node ${u.name}` : u.kind === "firewall" ? `${u.name} (firewall)` : u.name);

const markOf = (c: SecurityCve): CveMark =>
  c.mark ?? (c.state === "decided" || c.state === "risk" ? "confirmed" : c.state === "carried" ? "review" : "unread");

// What a CVE counts as: its upstream level, and the effective one when a
// decision changed it ("critical → high").
export function cveCategory(c: SecurityCve): string {
  const up = c.severity.toLowerCase();
  const lv = c.level ?? (c.state === "decided" ? "none" : c.state === "risk" && c.rating ? c.rating : up);
  return lv === up ? up : `${up} → ${lv}`;
}

export const MARK_WORD: Record<CveMark, string> = { unread: "unread", rule: "by rule", confirmed: "confirmed", deferred: "deferred", review: "to review", accepted: "accepted" };

// The badge a mark is drawn with: hollow (warn) for what needs someone, solid
// for what is settled, struck (skip) for an acceptance.
export function markTone(c: SecurityCve): UiLevel | "info" {
  const m = markOf(c);
  return m === "confirmed" ? "info" : m === "accepted" ? "skip" : m === "rule" ? "pass" : "warn";
}
export const markWord = (c: SecurityCve): string => MARK_WORD[markOf(c)];

const FLAG_WORD: Record<string, string> = {
  kev: "known exploited", epss: "likely to be exploited", "review-due": "review due", "needs-use": "needs its use statement",
  assumption: "does not hold here", version: "new major version", "upstream-changed": "upstream changed its score", expired: "review date passed",
  "rule-expired": "the rule's result was not read in 14 days",
};

// The note under a CVE: why it has the level it has, or what it waits for.
export function cveNote(c: SecurityCve): string | null {
  const m = markOf(c);
  const flags = (c.flags ?? []).map((f) => FLAG_WORD[f] ?? f);
  const lead = flags.length ? `${flags.join(", ")}. ` : "";
  if (m === "review") return `${lead}${c.old ? `Was ${c.old}.` : c.carriedFrom ? `Analysed for ${c.carriedFrom}${c.analysis ? `: ${c.analysis}` : ""}.` : ""}${c.analysis && c.old ? ` ${c.analysis}` : ""}`.trim() || null;
  if (m === "unread") return `${lead}Not decided yet.`;
  if (m === "deferred") return `${lead}Put off: ${c.note ?? ""}`.trim();
  if (m === "accepted") return `${lead}Accepted on this site: ${c.note ?? ""}`.trim();
  if (m === "rule") return `${lead}Lowered by a rule nobody has read yet${c.analysis ? `: ${c.analysis}` : ""}.`;
  return `${lead}${c.analysis ?? ""}`.trim() || null;
}

// The marks as words, only what needs someone: "3 unread, 1 to review".
export function countsText(c: Record<CveState, number>, marks?: Record<CveMark, number>): string {
  if (marks) {
    const order: CveMark[] = ["unread", "rule", "review", "deferred", "accepted", "confirmed"];
    const parts = order.filter((k) => (marks[k] ?? 0) > 0).map((k) => `${marks[k]} ${MARK_WORD[k]}`);
    return parts.length ? parts.join(", ") : "none";
  }
  const parts = (["open", "risk", "carried", "decided"] as CveState[]).filter((k) => c[k] > 0).map((k) => `${c[k]} ${k}`);
  return parts.length ? parts.join(", ") : "none";
}

// The sparkline as an SVG polyline over a w×h box: one point a day, a gap
// where no scan wrote. The scale starts at 0 and reaches the highest value
// (at least 1), so a flat line at zero sits on the floor.
export function sparkPoints(vs: (number | null)[], w: number, h: number): string[] {
  const max = Math.max(1, ...vs.map((v) => v ?? 0));
  const step = vs.length > 1 ? w / (vs.length - 1) : 0;
  const runs: string[] = [];
  let cur: string[] = [];
  vs.forEach((v, i) => {
    if (v === null) {
      if (cur.length) runs.push(cur.join(" "));
      cur = [];
      return;
    }
    const y = h - 1 - (v / max) * (h - 2);
    cur.push(`${(i * step).toFixed(1)},${y.toFixed(1)}`);
  });
  if (cur.length) runs.push(cur.join(" "));
  return runs;
}

export function sparkTitle(days: string[], vs: (number | null)[]): string {
  return days.map((d, i) => `${d.slice(5)}: ${vs[i] ?? "no scan"}`).join("\n");
}

// Every unit, worst first: for the Overview and the attention filter.
export function allUnits(v: SecurityView): SecurityUnit[] {
  const seen = new Map<string, SecurityUnit>();
  for (const z of [...v.environments.flatMap((e) => e.zones), ...v.outside]) for (const u of z.units) seen.set(u.key, u);
  return [...seen.values()].sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
}

// The Overview tile: the site's level, and how many modules are at high or above.
export function securityTile(v: SecurityView | null | undefined): { value: string; sub: string; level: UiLevel } | null {
  if (!v) return null;
  const units = allUnits(v);
  const high = units.filter((u) => u.level === "high" || u.level === "critical").length;
  const by = v.site.setBy ? ` · set by ${v.site.setBy}` : "";
  return {
    value: `CVE risk ${riskText(v.site)}`,
    sub: `${high} of ${units.length} modules high or critical${by}${v.failed.length ? ` · ${v.failed.length} not scanned` : ""}`,
    level: riskTone(v.site.level),
  };
}
