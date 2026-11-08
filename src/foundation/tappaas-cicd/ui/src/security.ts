// security.ts — /api/security: the site's CVE risk as the Security page shows it.
//
// The read is `health-manager report security --json`: the last scan, with the
// risk scores under `score` (health-manager's site-score.ts computes them; the
// console never does the maths). This keeps what the page shows and drops the
// rest: the site, its environments, zones and modules with level, score, what
// sets it, the state counts and seven days of scores, and each module's counted
// CVEs. Whether a fix exists is never passed on: no fix field leaves here.

export type Level = "ok" | "low" | "medium" | "high" | "critical";
export type CveState = "decided" | "risk" | "open" | "carried";

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
}

const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
const LEVELS: Level[] = ["ok", "low", "medium", "high", "critical"];
const levelOf = (v: unknown): Level => (LEVELS.includes(v as Level) ? (v as Level) : "ok");

export function lastDays(today: string, n = 7): string[] {
  const t = Date.parse(`${today}T00:00:00Z`);
  return Array.from({ length: n }, (_, i) => new Date(t - (n - 1 - i) * 86_400_000).toISOString().slice(0, 10));
}

// What counts most first: open, then risk, carried, decided; within a state the
// highest category (a risk CVE at its rating), then the id.
const STATE_ORDER: Record<CveState, number> = { open: 0, risk: 1, carried: 2, decided: 3 };
const CAT_ORDER = ["critical", "high", "medium", "low"];
const catRank = (c: SecurityCve): number => {
  const k = CAT_ORDER.indexOf((c.state === "risk" && c.rating ? c.rating : c.severity).toLowerCase());
  return k < 0 ? CAT_ORDER.length : k;
};
function byWeight(a: SecurityCve, b: SecurityCve): number {
  return STATE_ORDER[a.state] - STATE_ORDER[b.state] || catRank(a) - catRank(b) || a.id.localeCompare(b.id);
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
    setBy: u.category ? `${u.counted} ${u.category}` : null,
    spark: spark((h) => h.units[key]),
    counts: { open: u.counts?.open ?? 0, risk: u.counts?.risk ?? 0, carried: u.counts?.carried ?? 0, decided: u.counts?.decided ?? 0 },
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
  };
}

// A module's level and score, for its badge; null when the scan has no unit of
// that name.
export function moduleLevel(raw: Record<string, unknown> | null, module: string): { level: Level; score: number } | null {
  const u = (raw?.score as RawScore | undefined)?.units?.[module];
  return u ? { level: levelOf(u.level), score: u.score } : null;
}
