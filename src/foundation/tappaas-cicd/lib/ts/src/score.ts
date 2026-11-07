// score.ts — the one CVE risk score (ADR-045 D3): a module, a zone, an
// environment, the site and a release candidate are scored here and nowhere
// else. health-manager's `score` verb, the release preview (through that verb)
// and the release record all call it.
//
// A counted CVE is in one of three states (decided ones count nothing):
//   risk     analysed, exploitable here — counted at its TAPPaaS rating
//   open     critical/high nobody has analysed — counted at its CVE severity
//   carried  analysed for another version of the package — counted as open
// Points: risk 25/10/3/1 (critical/high/medium/low), open and carried 20/8
// (critical/high; an unanalysed medium or low counts nothing).
//
// A module's score: only the highest category with any item counts; within it
// the items are taken highest first, each counting half the one before. So a
// category never reaches twice its top value (critical < 50, high < 20,
// medium < 6, low < 2). The level comes from the score: ok 0, low < 7,
// medium < 16, high < 30, critical ≥ 30.
//
// A zone is the highest module score among the modules deployed in it, times
// the multiplier of its tier; an environment is the highest of its zones; the
// site the highest of its environments and of the zones in no environment. A
// release has no zones: its score is its highest module score.
//
// The weights, the bands and the multipliers are judgement calls, kept in the
// tables below so changing one is one edit; the release record stores them.

export type CveState = "decided" | "risk" | "open" | "carried";
export type Category = "critical" | "high" | "medium" | "low";
export type Level = "ok" | "low" | "medium" | "high" | "critical";

export const CATEGORIES: Category[] = ["critical", "high", "medium", "low"];
export const LEVELS: Level[] = ["ok", "low", "medium", "high", "critical"];

// Points per counted CVE (ADR-045 D3).
export const WEIGHTS: { risk: Record<Category, number>; open: Partial<Record<Category, number>> } = {
  risk: { critical: 25, high: 10, medium: 3, low: 1 },
  open: { critical: 20, high: 8 },
};

// The lower bound of each level above ok: a score at or above it has that level.
export const BANDS: { level: Level; from: number }[] = [
  { level: "critical", from: 30 },
  { level: "high", from: 16 },
  { level: "medium", from: 7 },
  { level: "low", from: 0 }, // above 0
];

// Zone multiplier by tier: the lower the tier, the more a compromise there reaches.
export const TIER_MULTIPLIERS: Record<number, number> = { 0: 2, 1: 1, 2: 0.75, 3: 0.5, 4: 0.25, 5: 0.1, 6: 0.1 };

// A term smaller than this is not added: the halving series would otherwise,
// after ~50 items, round a sum that must stay below twice its top value up to
// exactly that value (60 open highs would be 16.0 — high — instead of medium).
const NEGLIGIBLE = 1e-6;

export interface ScoredItem {
  id: string;
  state: CveState;
  severity?: string; // the CVE's own severity: Critical | High | Medium | Low (any case)
  rating?: string; // a risk item's TAPPaaS rating: critical | high | medium | low
  pkg?: string;
}

export interface ModuleScore {
  score: number; // rounded for display: two decimals, never across a level band
  raw: number;
  level: Level;
  category: Category | null; // the category that counts
  counted: number; // items in that category
  counts: Record<CveState, number>;
}

export interface Aggregate {
  score: number;
  raw: number;
  level: Level;
  setBy: { module: string | null; zone?: string | null };
  multiplier?: number;
}

function lc(s: string | undefined): string {
  return (s ?? "").trim().toLowerCase();
}

// The category and points of one item; null when it counts nothing (decided, or
// an unanalysed medium/low). A risk item without a TAPPaaS rating counts at its
// CVE severity, with the risk weights: analysed, and nobody said it is less.
export function itemPoints(i: ScoredItem): { category: Category; points: number } | null {
  if (i.state === "decided") return null;
  if (i.state === "risk") {
    const r = lc(i.rating);
    const c = (CATEGORIES as string[]).includes(r) ? (r as Category) : (lc(i.severity) as Category);
    if (!(CATEGORIES as string[]).includes(c)) return null;
    return { category: c, points: WEIGHTS.risk[c] };
  }
  const c = lc(i.severity) as Category;
  const p = WEIGHTS.open[c];
  return p === undefined ? null : { category: c, points: p };
}

export function levelOf(score: number): Level {
  if (!(score > 0)) return "ok";
  for (const b of BANDS) if (score >= b.from) return b.level;
  return "low";
}

// Two decimals for people, but never rounded across a band: 15.9999 is shown
// 15.99 (medium), not 16.00 (high).
export function displayScore(raw: number): number {
  const r = Math.round(raw * 100) / 100;
  return levelOf(r) === levelOf(raw) ? r : Math.floor(raw * 100) / 100;
}

// The halving sum of a list of points, highest first.
export function halvingSum(points: number[]): number {
  let sum = 0;
  let f = 1;
  for (const p of [...points].sort((a, b) => b - a)) {
    const term = p * f;
    if (term < NEGLIGIBLE) break;
    sum += term;
    f /= 2;
  }
  return sum;
}

export function moduleScore(items: ScoredItem[]): ModuleScore {
  const counts: Record<CveState, number> = { decided: 0, risk: 0, open: 0, carried: 0 };
  const by: Record<Category, number[]> = { critical: [], high: [], medium: [], low: [] };
  const seen = new Set<string>();
  for (const i of items) {
    // One CVE is one item, whatever packages it hits: the first entry counts.
    const key = `${i.id}`;
    if (i.id && seen.has(key)) continue;
    if (i.id) seen.add(key);
    if (i.state in counts) counts[i.state]++;
    const p = itemPoints(i);
    if (p) by[p.category].push(p.points);
  }
  const category = CATEGORIES.find((c) => by[c].length > 0) ?? null;
  const raw = category ? halvingSum(by[category]) : 0;
  return { score: displayScore(raw), raw, level: levelOf(raw), category, counted: category ? by[category].length : 0, counts };
}

// A tier that is no number (the overlays, work, wan) counts ×1; a tier above 6
// counts as the lowest tier's.
export function tierMultiplier(tier: unknown): number {
  if (typeof tier !== "number" || !Number.isFinite(tier) || tier < 0) return 1;
  const t = Math.floor(tier);
  return TIER_MULTIPLIERS[t] ?? (t > 6 ? TIER_MULTIPLIERS[6] : 1);
}

function agg(raw: number, setBy: Aggregate["setBy"], multiplier?: number): Aggregate {
  const a: Aggregate = { score: displayScore(raw), raw, level: levelOf(raw), setBy };
  if (multiplier !== undefined) a.multiplier = multiplier;
  return a;
}

// The highest of a set of (name, raw score); ties go to the first name in order.
function highest(xs: { module: string | null; zone?: string | null; raw: number }[]): { module: string | null; zone?: string | null; raw: number } {
  let best: { module: string | null; zone?: string | null; raw: number } = { module: null, raw: 0 };
  for (const x of [...xs].sort((a, b) => (a.zone ?? "").localeCompare(b.zone ?? "") || (a.module ?? "").localeCompare(b.module ?? ""))) {
    if (x.raw > best.raw) best = x;
  }
  return best;
}

export function zoneScore(tier: unknown, modules: { module: string; raw: number }[]): Aggregate {
  const m = tierMultiplier(tier);
  const top = highest(modules);
  return agg(top.raw * m, { module: top.module }, m);
}

export interface ZoneInfo {
  tier?: unknown;
  environment?: unknown; // a name, a list of names (a shared service zone), or none
}

export interface SiteInput {
  modules: Record<string, ScoredItem[]>; // module (or platform target) → its counted CVEs
  placement: Record<string, string[]>; // module → the zones it is deployed in
  zones: Record<string, ZoneInfo>;
}

export interface SiteScores {
  site: Aggregate;
  environments: Record<string, Aggregate & { zones: string[] }>;
  zones: Record<string, Aggregate & { environments: string[] }>;
  modules: Record<string, ModuleScore>;
  outside: string[]; // the zones in no environment, which roll up to the site directly
}

export function zoneEnvironments(z: ZoneInfo | undefined): string[] {
  const e = z?.environment;
  if (typeof e === "string" && e) return [e];
  if (Array.isArray(e)) return e.filter((x): x is string => typeof x === "string" && !!x);
  return [];
}

export function siteScores(input: SiteInput): SiteScores {
  const modules: Record<string, ModuleScore> = {};
  for (const [m, items] of Object.entries(input.modules)) modules[m] = moduleScore(items);
  // Every zone something is placed in counts, even one zones.json does not know (×1).
  const zoneNames = new Set(Object.keys(input.zones));
  for (const zs of Object.values(input.placement)) for (const z of zs) zoneNames.add(z);
  const zones: SiteScores["zones"] = {};
  for (const z of [...zoneNames].sort()) {
    const ms = Object.entries(input.placement)
      .filter(([m, zs]) => zs.includes(z) && modules[m])
      .map(([m]) => ({ module: m, raw: modules[m].raw }));
    zones[z] = { ...zoneScore(input.zones[z]?.tier, ms), environments: zoneEnvironments(input.zones[z]) };
  }
  const environments: SiteScores["environments"] = {};
  for (const [z, a] of Object.entries(zones)) {
    for (const e of a.environments) (environments[e] ??= { ...agg(0, { module: null, zone: null }), zones: [] }).zones.push(z);
  }
  for (const [e, a] of Object.entries(environments)) {
    const top = highest(a.zones.map((z) => ({ module: zones[z].setBy.module, zone: z, raw: zones[z].raw })));
    environments[e] = { ...agg(top.raw, { module: top.module, zone: top.zone ?? null }), zones: a.zones.sort() };
  }
  const outside = Object.keys(zones).filter((z) => zones[z].environments.length === 0).sort();
  const top = highest([
    ...Object.values(environments).map((a) => ({ module: a.setBy.module, zone: a.setBy.zone ?? null, raw: a.raw })),
    ...outside.map((z) => ({ module: zones[z].setBy.module, zone: z, raw: zones[z].raw })),
  ]);
  return { site: agg(top.raw, { module: top.module, zone: top.zone ?? null }), environments, zones, modules, outside };
}

// A release candidate: each module scored, no zone multiplier; its level is its
// highest module's.
export function releaseScores(mods: Record<string, ScoredItem[]>): { release: Aggregate; modules: Record<string, ModuleScore> } {
  const modules: Record<string, ModuleScore> = {};
  for (const [m, items] of Object.entries(mods)) modules[m] = moduleScore(items);
  const top = highest(Object.entries(modules).map(([m, s]) => ({ module: m, raw: s.raw })));
  return { release: agg(top.raw, { module: top.module }), modules };
}

// The values a score was computed with, stored with a release record.
export function scoreModel(): { weights: typeof WEIGHTS; bands: typeof BANDS; tierMultipliers: typeof TIER_MULTIPLIERS; halving: number } {
  return { weights: WEIGHTS, bands: BANDS, tierMultipliers: TIER_MULTIPLIERS, halving: 0.5 };
}
