// site-score.ts — the running site's risk scores (ADR-045 D3, D4): the last
// scan's CVEs, per module and platform target, then per zone, environment and
// the site. The maths is lib/ts/src/score.ts; this only says what is scored
// and where it sits.
//
//   unit        what gets a score: a module instance (its VM or container and
//               the images running in it, together), a node, the firewall
//   placement   a module sits in its zone0; a node and the firewall in the
//               management zone (the firewall sits in every zone, and counts
//               there); a module with no zone in "no zone" (×1, no environment)
//   history     one entry per day in config/sbom/score-history.json, written
//               by the scan and the rescan: the console's 7-day sparkline
//
// Health (assess-sources.ts fromCve), the console (/api/security, through
// `report security --json`) and `report security` all read siteSecurity().

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { Aggregate, CveState, Level, ModuleScore, ScoredItem, ZoneInfo, siteScores, tierMultiplier } from "../../../lib/ts/src/score";
import { Mark } from "../../../lib/ts/src/cve-decisions";
import { CONTROL_PLANE_ZONE, readZonesFile } from "../../../lib/ts/src/zones";
import { renameGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";
import { readModuleJson } from "./config";
import { CveItem, ScanStatus, TargetStatus, sbomDir, targetSubject } from "./security";
import { CheckSubject } from "./types";

export const HISTORY_FILE = "score-history.json";
export const HISTORY_DAYS = 30;
export const NO_ZONE = "no zone";

export type UnitKind = "module" | "node" | "firewall";

export interface UnitScore extends ModuleScore {
  name: string;
  kind: UnitKind;
  subject: CheckSubject;
  zones: string[];
  targets: string[]; // the scan targets it is made of
  failed: string[]; // those whose scan failed: not counted, and said so
  items: CveItem[];
}

export interface SiteSecurity {
  generated: string; // the scan it is computed from
  inventory?: string; // a rescan: when its inventory was taken
  site: Aggregate;
  environments: Record<string, Aggregate & { zones: string[] }>;
  zones: Record<string, Aggregate & { environments: string[]; tier: number | null }>;
  outside: string[];
  units: Record<string, UnitScore>;
  history: HistoryEntry[];
}

export interface HistoryEntry {
  date: string; // YYYY-MM-DD (UTC)
  at: string;
  site: number;
  environments: Record<string, number>;
  zones: Record<string, number>;
  units: Record<string, number>;
}

// A target's unit: "node:<name>" for a node, else the module instance the
// target is (or runs inside).
export function unitOf(t: TargetStatus): { key: string; name: string; kind: UnitKind; subject: CheckSubject } {
  const subject = targetSubject(t);
  if (subject.kind === "node") return { key: `node:${subject.name}`, name: subject.name, kind: "node", subject };
  return { key: subject.name, name: subject.name, kind: t.layer === "opnsense" ? "firewall" : "module", subject };
}

export function scoreUnits(s: ScanStatus): Record<string, { name: string; kind: UnitKind; subject: CheckSubject; targets: string[]; failed: string[]; items: CveItem[] }> {
  const out: ReturnType<typeof scoreUnits> = {};
  for (const t of s.targets) {
    const u = unitOf(t);
    const e = (out[u.key] ??= { name: u.name, kind: u.kind, subject: u.subject, targets: [], failed: [], items: [] });
    if (u.kind === "firewall") e.kind = "firewall";
    e.targets.push(t.id);
    if (t.coverage !== "ok" || t.verdict === "failed") e.failed.push(t.id);
    e.items.push(...(t.items ?? []));
  }
  return out;
}

// Where each unit sits, and the zones' tiers and environments, from config/.
export function sitePlacement(configDir: string, units: ReturnType<typeof scoreUnits>): { placement: Record<string, string[]>; zones: Record<string, ZoneInfo> } {
  const zones: Record<string, ZoneInfo> = {};
  try {
    for (const [name, z] of readZonesFile(join(configDir, "zones.json")).entries) zones[name] = { tier: z.tier, environment: z.environment };
  } catch {
    // no zones.json: every zone counts ×1 and in no environment
  }
  const placement: Record<string, string[]> = {};
  for (const [key, u] of Object.entries(units)) {
    if (u.kind !== "module") {
      placement[key] = [CONTROL_PLANE_ZONE];
      continue;
    }
    const cfg = readModuleJson(join(configDir, `${u.name}.json`));
    const z = typeof cfg?.zone0 === "string" && cfg.zone0 ? cfg.zone0 : "";
    placement[key] = [z || NO_ZONE];
  }
  return { placement, zones };
}

const scored = (items: CveItem[]): ScoredItem[] => items.map((i) => ({
  id: i.id, state: i.state as CveState, severity: i.severity, rating: i.rating, pkg: i.pkg,
  ...(i.level ? { level: i.level } : {}), ...(i.mark ? { mark: i.mark } : {}), ...(i.counted !== undefined ? { counted: i.counted } : {}),
}));

export function siteSecurity(s: ScanStatus, place: { placement: Record<string, string[]>; zones: Record<string, ZoneInfo> }, history: HistoryEntry[] = []): SiteSecurity {
  const units = scoreUnits(s);
  const sc = siteScores({ modules: Object.fromEntries(Object.entries(units).map(([k, u]) => [k, scored(u.items)])), placement: place.placement, zones: place.zones });
  const out: SiteSecurity = {
    generated: s.generated,
    ...(s.inventory ? { inventory: s.inventory } : {}),
    site: sc.site,
    environments: sc.environments,
    zones: Object.fromEntries(Object.entries(sc.zones).map(([z, a]) => {
      const tier = place.zones[z]?.tier;
      return [z, { ...a, tier: typeof tier === "number" ? tier : null }];
    })),
    outside: sc.outside,
    units: {},
    history,
  };
  for (const [k, u] of Object.entries(units)) out.units[k] = { ...sc.modules[k], ...u, zones: place.placement[k] ?? [] };
  return out;
}

// ── history ────────────────────────────────────────────────────────────
export function readHistory(configDir: string): HistoryEntry[] {
  const f = join(sbomDir(configDir), HISTORY_FILE);
  if (!existsSync(f)) return [];
  try {
    const v = JSON.parse(readFileSync(f, "utf8")) as unknown;
    return Array.isArray(v) ? (v as HistoryEntry[]).filter((e) => e && typeof e.date === "string") : [];
  } catch {
    return [];
  }
}

// Today's entry replaces an earlier one of the same day; the oldest go after
// HISTORY_DAYS.
export function withToday(history: HistoryEntry[], sec: SiteSecurity, at: string): HistoryEntry[] {
  const e: HistoryEntry = {
    date: at.slice(0, 10),
    at,
    site: sec.site.score,
    environments: Object.fromEntries(Object.entries(sec.environments).map(([k, a]) => [k, a.score])),
    zones: Object.fromEntries(Object.entries(sec.zones).map(([k, a]) => [k, a.score])),
    units: Object.fromEntries(Object.entries(sec.units).map(([k, u]) => [k, u.score])),
  };
  return [...history.filter((h) => h.date !== e.date), e].sort((a, b) => a.date.localeCompare(b.date)).slice(-HISTORY_DAYS);
}

export function writeHistory(configDir: string, history: HistoryEntry[]): void {
  const f = join(sbomDir(configDir), HISTORY_FILE);
  writeFileGuarded(`${f}.tmp`, JSON.stringify(history) + "\n");
  renameGuarded(`${f}.tmp`, f);
}

// The site's security from config/: what every reader calls.
export function loadSiteSecurity(configDir: string, s: ScanStatus): SiteSecurity {
  return siteSecurity(s, sitePlacement(configDir, scoreUnits(s)), readHistory(configDir));
}

// After a scan or a rescan: today's scores into the history.
export function recordHistory(configDir: string, s: ScanStatus): SiteSecurity {
  const sec = loadSiteSecurity(configDir, s);
  sec.history = withToday(sec.history, sec, s.generated);
  writeHistory(configDir, sec.history);
  return sec;
}

// The last `days` days of one series, oldest first; null where no scan wrote.
export function sparkline(history: HistoryEntry[], pick: (h: HistoryEntry) => number | undefined, today: string, days = 7): (number | null)[] {
  const t = Date.parse(`${today}T00:00:00Z`);
  const out: (number | null)[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(t - i * 86_400_000).toISOString().slice(0, 10);
    const h = history.find((x) => x.date === d);
    const v = h ? pick(h) : undefined;
    out.push(v === undefined ? null : v);
  }
  return out;
}

// One CVE as the report lists it: its levels, its mark, and why.
export function itemLines(i: CveItem, indent: string): string[] {
  const pad = (x: string, n: number): string => x.padEnd(n);
  const up = i.severity.toLowerCase();
  const lv = i.level ?? (i.state === "decided" ? "none" : i.rating ?? up);
  const levels = lv === up ? up : `${up} → ${lv}`;
  const mark = i.mark ?? (i.state === "decided" || i.state === "risk" ? "confirmed" : i.state === "carried" ? "review" : "unread");
  const extra = (i.flags ?? []).filter((f) => ["kev", "epss", "expired", "review-due", "needs-use", "assumption", "version", "upstream-changed", "grace", "rule-expired"].includes(f));
  const out = [`${indent}${pad(mark === "rule" ? "by rule" : mark, 10)}${pad(levels, 20)}${pad(i.id, 20)}${i.pkg} ${i.version}${extra.length ? `  [${extra.join(", ")}]` : ""}`];
  const why = i.mark === "review" && i.old?.why ? `was ${i.old.level}: ${i.old.why}` : i.note ?? i.analysis;
  if (why) out.push(`${indent}  ${why.replace(/\s+/g, " ").slice(0, 110)}`);
  return out;
}

// ── the table (`report security`) ─────────────────────────────────────
const LEVEL_RANK: Record<Level, number> = { ok: 0, low: 1, medium: 2, high: 3, critical: 4 };
export const levelRank = (l: Level): number => LEVEL_RANK[l] ?? 0;

const SPARK = "▁▂▃▄▅▆▇█";
export function sparkText(vs: (number | null)[]): string {
  const max = Math.max(1, ...vs.map((v) => v ?? 0));
  return vs.map((v) => (v === null ? "·" : SPARK[Math.min(7, Math.round((v / max) * 7))])).join("");
}

const setByText = (a: { setBy: { module: string | null; zone?: string | null } }, units: Record<string, UnitScore>): string =>
  a.setBy.module ? `${units[a.setBy.module]?.name ?? a.setBy.module}${a.setBy.zone ? ` in ${a.setBy.zone}` : ""}` : "";

// Unread, by rule, confirmed, to review, accepted — deferred joins unread.
const countsText = (m: Record<Mark, number>): string => `${m.unread + m.deferred}/${m.rule}/${m.confirmed}/${m.review}/${m.accepted}`;

export function renderSecurity(sec: SiteSecurity, now: number, opts: { items?: boolean } = {}): string[] {
  const today = new Date(now).toISOString().slice(0, 10);
  const pad = (x: string | number, n: number): string => String(x).padEnd(n);
  const num = (x: number): string => String(x).padStart(6);
  const out: string[] = [];
  const age = Math.floor((now - Date.parse(sec.generated)) / 3_600_000);
  out.push(`Security of ${sec.generated} (${age < 48 ? `${age} h` : `${Math.floor(age / 24)} days`} ago)` +
    (sec.inventory ? `, the inventory of ${sec.inventory} matched again` : ""));
  out.push("");
  const head = `${pad("", 34)}${pad("LEVEL", 9)}${"SCORE".padStart(6)}  ${pad("SET BY", 24)}${pad("U/R/C/V/A", 14)}7 DAYS`;
  out.push(head);
  const row = (label: string, a: Aggregate, by: string, counts: string, spark: (number | null)[]): string =>
    `${pad(label, 34)}${pad(a.level, 9)}${num(a.score)}  ${pad(by, 24)}${pad(counts, 14)}${sparkText(spark)}`;
  out.push(row("site", sec.site, setByText(sec.site, sec.units), "", sparkline(sec.history, (h) => h.site, today)));
  const zoneRow = (z: string, indent: string): void => {
    const a = sec.zones[z];
    out.push(row(`${indent}zone ${z} ×${a.multiplier ?? tierMultiplier(a.tier)}`, a, setByText(a, sec.units), "", sparkline(sec.history, (h) => h.zones[z], today)));
    const us = Object.entries(sec.units).filter(([, u]) => u.zones.includes(z)).sort((x, y) => y[1].raw - x[1].raw || x[1].name.localeCompare(y[1].name));
    for (const [k, u] of us) {
      const label = `${indent}  ${u.kind === "module" ? "" : `${u.kind} `}${u.name}`;
      out.push(row(label, u as unknown as Aggregate, u.category ? `${u.counted} ${u.category}` : u.failed.length ? "scan failed" : "", countsText(u.marks), sparkline(sec.history, (h) => h.units[k], today)));
      if (opts.items) {
        for (const i of u.items) out.push(...itemLines(i, `${indent}      `));
      }
    }
  };
  for (const [e, a] of Object.entries(sec.environments).sort((x, y) => x[0].localeCompare(y[0]))) {
    out.push(row(`  environment ${e}`, a, setByText(a, sec.units), "", sparkline(sec.history, (h) => h.environments[e], today)));
    for (const z of a.zones) zoneRow(z, "    ");
  }
  for (const z of sec.outside) zoneRow(z, "  ");
  out.push("", "U/R/C/V/A: unread, by rule, confirmed, to review, accepted CVEs. Each counts at its effective level;",
    "a module's score counts its highest level only.");
  const failed = Object.values(sec.units).filter((u) => u.failed.length > 0);
  if (failed.length) out.push(`Not counted, the scan failed: ${failed.map((u) => u.name).join(", ")} (health-manager report security --scan).`);
  return out;
}
