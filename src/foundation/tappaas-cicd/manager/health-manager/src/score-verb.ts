// score-verb.ts — `health-manager score` (ADR-045 D3): the one risk score, for
// whoever needs a number without computing it themselves.
//
//   score --details <file> [--json]
//       a release preview's details (tappaas-train preview): each module's
//       release score and level over the CVEs "if released now" ships, and the
//       release's own (its highest module). No zone multiplier: a release knows
//       no site's zones. The preview calls this instead of scoring in Python.
//   score --items <file> [--json]
//       {modules: {<m>: [{id, state, severity, rating}]}, placement?, zones?}: with
//       placement and zones, the site's scores (module, zone, environment, site);
//       without, a release's.

import { readFileSync } from "fs";
import {
  Aggregate, CveState, ModuleScore, ScoredItem, SiteInput, releaseScores, scoreModel, siteScores,
} from "../../../lib/ts/src/score";

interface DetailCve {
  id: string;
  severity?: string;
  status?: string; // open | risk | ack | carried | baseline
  state?: string; // the state under an ack (pin-preview, ADR-045): open | risk | carried
  risk?: string; // a risk item's TAPPaaS rating
}
interface Details {
  modules?: Record<string, { cves?: { new?: DetailCve[]; same?: DetailCve[] } }>;
}

const STATES = new Set<CveState>(["decided", "risk", "open", "carried"]);

// A preview CVE as a scored item. An ack accepts an item for the gate; it does
// not change its risk, so an acked item counts in the state it has under the ack.
// `baseline`: the shared baseline's CVE, counted in the baseline's own row.
export function itemOfDetail(c: DetailCve): ScoredItem | null {
  if (c.status === "baseline") return null;
  let s = (c.state ?? c.status ?? "open") as CveState | "ack";
  if (s === "ack") s = "open";
  if (!STATES.has(s as CveState)) s = "open";
  return { id: c.id, state: s as CveState, severity: c.severity, rating: c.risk };
}

export function itemsOfDetails(d: Details): Record<string, ScoredItem[]> {
  const out: Record<string, ScoredItem[]> = {};
  for (const [m, v] of Object.entries(d.modules ?? {})) {
    out[m] = [...(v.cves?.new ?? []), ...(v.cves?.same ?? [])].map(itemOfDetail).filter((x): x is ScoredItem => x !== null);
  }
  return out;
}

function moduleJson(s: ModuleScore): Record<string, unknown> {
  return { score: s.score, level: s.level, category: s.category, counted: s.counted, counts: s.counts };
}
function aggJson(a: Aggregate): Record<string, unknown> {
  return { score: a.score, level: a.level, setBy: a.setBy, ...(a.multiplier !== undefined ? { multiplier: a.multiplier } : {}) };
}

export function scoreDocument(input: { modules: Record<string, ScoredItem[]>; placement?: SiteInput["placement"]; zones?: SiteInput["zones"] }): Record<string, unknown> {
  if (input.placement && input.zones) {
    const s = siteScores({ modules: input.modules, placement: input.placement, zones: input.zones });
    const map = <T, R>(o: Record<string, T>, f: (x: T) => R): Record<string, R> => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, f(v)]));
    return {
      site: aggJson(s.site),
      environments: map(s.environments, (a) => ({ ...aggJson(a), zones: a.zones })),
      zones: map(s.zones, (a) => ({ ...aggJson(a), environments: a.environments })),
      outside: s.outside,
      modules: map(s.modules, moduleJson),
      model: scoreModel(),
    };
  }
  const r = releaseScores(input.modules);
  return {
    release: aggJson(r.release),
    modules: Object.fromEntries(Object.entries(r.modules).map(([m, s]) => [m, moduleJson(s)])),
    model: scoreModel(),
  };
}

export function renderScores(doc: Record<string, unknown>): string[] {
  const mods = (doc.modules ?? {}) as Record<string, { score: number; level: string; category: string | null; counted: number }>;
  const lines: string[] = [];
  const top = (doc.release ?? doc.site) as { score: number; level: string; setBy: { module: string | null; zone?: string | null } };
  lines.push(`${doc.release ? "release" : "site"}: ${top.score} ${top.level}` +
    (top.setBy.module ? ` — set by ${top.setBy.module}${top.setBy.zone ? ` in ${top.setBy.zone}` : ""}` : ""));
  if (doc.environments) {
    for (const [e, a] of Object.entries(doc.environments as Record<string, { score: number; level: string; setBy: { module: string | null; zone?: string | null } }>)) {
      lines.push(`  environment ${e}: ${a.score} ${a.level}${a.setBy.module ? ` (${a.setBy.module} in ${a.setBy.zone})` : ""}`);
    }
    for (const [z, a] of Object.entries(doc.zones as Record<string, { score: number; level: string; multiplier: number; setBy: { module: string | null } }>)) {
      lines.push(`  zone ${z} ×${a.multiplier}: ${a.score} ${a.level}${a.setBy.module ? ` (${a.setBy.module})` : ""}`);
    }
  }
  const rows = Object.entries(mods).sort((a, b) => b[1].score - a[1].score || a[0].localeCompare(b[0]));
  for (const [m, s] of rows) {
    lines.push(`  ${m.padEnd(22)} ${String(s.score).padStart(6)}  ${s.level.padEnd(8)} ${s.category ? `${s.counted} ${s.category}` : ""}`.trimEnd());
  }
  return lines;
}

export function cmdScore(rest: string[], out: (s: string) => void): number {
  let details = "";
  let items = "";
  let json = false;
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--details") details = rest[++i] ?? "";
    else if (a === "--items") items = rest[++i] ?? "";
    else if (a === "--json") json = true;
    else throw new Error(`score: unexpected argument ${a}`);
  }
  if (!!details === !!items) throw new Error("score: give one of --details <file> or --items <file>");
  const file = details || items;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    throw new Error(`score: ${file} is not readable JSON (${(e as Error).message})`);
  }
  const input = details
    ? { modules: itemsOfDetails(parsed as Details) }
    : (parsed as { modules: Record<string, ScoredItem[]>; placement?: SiteInput["placement"]; zones?: SiteInput["zones"] });
  if (!input || typeof input.modules !== "object" || input.modules === null) throw new Error(`score: ${file} has no "modules"`);
  const doc = scoreDocument(input);
  if (json) out(JSON.stringify(doc, null, 1));
  else for (const l of renderScores(doc)) out(l);
  return 0;
}
