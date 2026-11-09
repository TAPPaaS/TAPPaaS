// security.ts — the Security page's shaping: the CVE risk read (/api/security)
// as rows, a level's colour and words, and the 7-day sparkline. Pure, so the
// unit tests run it without a DOM.

// The status colours a level is drawn in (ui.tsx's Level, the part used here).
type UiLevel = "pass" | "warn" | "fail" | "skip";

export type RiskLevel = "ok" | "low" | "medium" | "high" | "critical";
export type CveState = "decided" | "risk" | "open" | "carried";

export interface SecurityCve {
  id: string;
  state: CveState;
  severity: string;
  rating: string | null;
  pkg: string;
  version: string;
  analysis: string | null;
  carriedFrom: string | null;
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

// What a CVE counts as: an analysed one at its rating, an open or carried one
// at its CVE severity.
export function cveCategory(c: SecurityCve): string {
  if (c.state === "risk") return c.rating ? `${c.rating}, rated here` : c.severity.toLowerCase();
  return c.severity.toLowerCase();
}

export const STATE_WORD: Record<CveState, string> = { open: "open", risk: "risk", carried: "carried", decided: "decided" };

// The note under a CVE: its analysis, or why it has none.
export function cveNote(c: SecurityCve): string | null {
  if (c.state === "carried") return `Analysed for ${c.carriedFrom ?? "another version"}${c.analysis ? `: ${c.analysis}` : ""}. Confirm it for ${c.version}.`;
  if (c.state === "open") return "Not analysed yet.";
  return c.analysis;
}

// The counts as words, only what is there: "1 open, 2 risk".
export function countsText(c: Record<CveState, number>): string {
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
