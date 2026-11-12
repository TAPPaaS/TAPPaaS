// site-decisions.ts — what a site adds to the central CVE decisions.
//
//   assumptions   a component record says what a site must look like for it to
//                 hold (`assumes`). They are checked here, against this site's
//                 config, at every scan: a record whose assumptions fail is not
//                 applied, and the CVE says why. Nothing to acknowledge.
//   acceptances   config/security-acceptances.json: the operator accepts a CVE
//                 of one unit until a date, with a note. It takes the CVE out of
//                 the unit's level (and the zone, environment and site above),
//                 keyed by component, CVE and unit — no version, so it survives
//                 version moves. It ends at its date, when the CVE becomes known
//                 exploited, when upstream rates it higher, or when a central
//                 decision covers it; ended ones are kept under `ended`.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { Acceptance, ComponentRecord, DAY, SiteView, categoryOf, levelRankOf } from "../../../lib/ts/src/cve-decisions";
import { CONTROL_PLANE_ZONE, readZonesFile } from "../../../lib/ts/src/zones";
import { renameGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";
import { readModuleJson } from "./config";
import { AcceptanceRow, CveItem, ScanStatus } from "./security";

export const ACCEPTANCES_FILE = "security-acceptances.json";
export const MAX_ACCEPT_DAYS = 366;

export type SiteDecider = (unit: string, component: string, record: ComponentRecord | undefined, id: string) => SiteView;

export interface Ended extends Acceptance {
  ended: string; // ISO date
  why: string; // expired | known-exploited | severity-rose | superseded | gone
}

export interface AcceptancesFile {
  schema: 1;
  acceptances: Acceptance[];
  ended: Ended[];
}

export function readAcceptances(configDir: string): AcceptancesFile {
  const f = join(configDir, ACCEPTANCES_FILE);
  if (!existsSync(f)) return { schema: 1, acceptances: [], ended: [] };
  try {
    const d = JSON.parse(readFileSync(f, "utf8")) as Partial<AcceptancesFile>;
    return { schema: 1, acceptances: Array.isArray(d.acceptances) ? d.acceptances : [], ended: Array.isArray(d.ended) ? d.ended : [] };
  } catch {
    return { schema: 1, acceptances: [], ended: [] };
  }
}

export function writeAcceptances(configDir: string, doc: AcceptancesFile): void {
  const f = join(configDir, ACCEPTANCES_FILE);
  writeFileGuarded(`${f}.tmp`, JSON.stringify(doc, null, 1) + "\n");
  renameGuarded(`${f}.tmp`, f);
}

// ── assumptions ────────────────────────────────────────────────────────
export interface Exposure {
  public: boolean; // reachable from the internet: a proxy route open to it, or a zone of tier 4 and above
  sso: boolean; // logs in through identity
  tier: number | null;
  zone: string;
  config: Record<string, unknown>;
}

export function exposureOf(configDir: string, unit: string, zoneTiers: Record<string, number | null>): Exposure {
  if (unit.startsWith("node:")) return { public: false, sso: false, tier: zoneTiers[CONTROL_PLANE_ZONE] ?? 0, zone: CONTROL_PLANE_ZONE, config: {} };
  const cfg = readModuleJson(join(configDir, `${unit}.json`)) ?? {};
  const zone = typeof cfg.zone0 === "string" ? cfg.zone0 : "";
  const tier = zone ? zoneTiers[zone] ?? null : null;
  const conf = (cfg.config ?? {}) as Record<string, Record<string, unknown> | undefined>;
  const zones = conf["network:proxy"]?.proxyAllowedZones;
  const internet = Array.isArray(zones) && zones.includes("internet");
  return { public: internet || (tier !== null && tier >= 4), sso: !!conf["identity:identity"], tier, zone, config: conf as Record<string, unknown> };
}

// The assumptions of a record that do not hold for this unit, each with the
// sentence the console shows. An assumption that cannot be evaluated fails.
export function failedAssumptions(assumes: Record<string, string> | undefined, unit: string, x: Exposure): { key: string; text: string }[] {
  const out: { key: string; text: string }[] = [];
  for (const [k, v] of Object.entries(assumes ?? {})) {
    if (k === "maxExposure") {
      if (v === "internal" && x.public) out.push({ key: k, text: `assumes internal only; ${unit} is reachable from the internet here` });
      else if (v === "authenticated" && x.public && !x.sso) out.push({ key: k, text: `assumes users log in first; ${unit} is public here without identity` });
      else if (v !== "internal" && v !== "authenticated") out.push({ key: k, text: `assumes maxExposure ${v}, which this site cannot check` });
    } else if (k === "zoneTier") {
      const m = /^(<=|>=|<|>|=)?\s*(\d+)$/.exec(v.trim());
      if (!m || x.tier === null) {
        out.push({ key: k, text: `assumes zone tier ${v}; ${unit}'s zone ${x.zone || "(none)"} has no tier here` });
        continue;
      }
      const n = Number(m[2]);
      const ok = m[1] === "<=" ? x.tier <= n : m[1] === ">=" ? x.tier >= n : m[1] === "<" ? x.tier < n : m[1] === ">" ? x.tier > n : x.tier === n;
      if (!ok) out.push({ key: k, text: `assumes zone tier ${v}; ${unit} is in ${x.zone}, tier ${x.tier}` });
    } else if (k === "serviceOff") {
      const svc = x.config[v] as { enabled?: unknown } | undefined;
      if (svc !== undefined && svc?.enabled !== false) out.push({ key: k, text: `assumes ${v} is off; it is configured on ${unit} here` });
    } else {
      out.push({ key: k, text: `assumes ${k} ${v}, which this site cannot check` });
    }
  }
  return out;
}

// ── the decider the scan uses ──────────────────────────────────────────
export function siteDecisions(configDir: string): SiteDecider {
  const tiers: Record<string, number | null> = {};
  try {
    for (const [name, z] of readZonesFile(join(configDir, "zones.json")).entries) tiers[name] = typeof z.tier === "number" ? z.tier : null;
  } catch {
    // no zones.json: no tiers; a zoneTier assumption then fails, as it cannot be checked
  }
  const exposure = new Map<string, Exposure>();
  const acc = readAcceptances(configDir).acceptances;
  return (unit, component, record, id) => {
    const view: SiteView = {};
    if (record?.assumes && Object.keys(record.assumes).length) {
      if (!exposure.has(unit)) exposure.set(unit, exposureOf(configDir, unit, tiers));
      const failed = failedAssumptions(record.assumes, unit, exposure.get(unit)!);
      if (failed.length) view.failedAssumptions = failed;
    }
    const a = acc.find((x) => x.unit === unit && x.cve === id && x.component === component);
    if (a) view.acceptance = a;
    return view;
  };
}

// The score unit a target counts in: a node by "node:<name>", an image by the
// module it runs in, anything else by its own id (the module instance).
export function unitName(targetId: string): string {
  if (targetId.startsWith("node:")) return targetId;
  if (targetId.startsWith("image:")) return targetId.slice(6).split("/")[0];
  return targetId;
}

// ── after a scan: acceptances that ended ───────────────────────────────
// An active acceptance whose CVE the scan no longer shows as accepted has
// ended: moved to `ended` with why, and returned for the digest. One whose CVE
// is no longer found at all ends as gone.
export function settleAcceptances(configDir: string, s: ScanStatus, now: number): Ended[] {
  const doc = readAcceptances(configDir);
  if (!doc.acceptances.length) return [];
  const items = new Map<string, CveItem>();
  const ids = new Set<string>();
  for (const t of s.targets) {
    for (const i of t.items ?? []) {
      const unit = unitName(t.id);
      const k = `${unit} ${i.id} ${i.component}`;
      const had = items.get(k);
      if (!had || i.mark === "accepted") items.set(k, i);
      ids.add(`${unit} ${i.id}`);
    }
  }
  const rows = new Map<string, AcceptanceRow>();
  for (const t of s.targets) for (const r of t.acceptances ?? []) {
    const k = `${unitName(t.id)} ${r.id} ${r.component}`;
    const had = rows.get(k);
    if (!had || (had.accepted && !r.accepted)) rows.set(k, r);
  }
  const keep: Acceptance[] = [];
  const ended: Ended[] = [];
  const day = new Date(now).toISOString().slice(0, 10);
  for (const a of doc.acceptances) {
    const k = `${a.unit} ${a.cve} ${a.component}`;
    const r = rows.get(k);
    const i = items.get(k);
    let why = "";
    if (Date.parse(a.until) <= now) why = "expired";
    else if (r) why = r.accepted ? "" : r.ended ?? "";
    else if (!i && !ids.has(`${a.unit} ${a.cve}`)) why = "gone";
    else if (!i) why = ""; // the CVE is on the unit under another row: decided at the next scan
    else if (i.mark !== "accepted") {
      const was = categoryOf(a.severity);
      const now = categoryOf(i.severity);
      why = i.kev || (i.flags ?? []).includes("kev") ? "known-exploited"
        : was && now && levelRankOf(now) > levelRankOf(was) ? "severity-rose"
        : i.mark === "confirmed" ? "superseded"
        : ""; // not applied yet (accepted while the scan ran): it stays
    }
    if (why) ended.push({ ...a, ended: day, why });
    else keep.push(a);
  }
  if (ended.length) writeAcceptances(configDir, { schema: 1, acceptances: keep, ended: [...doc.ended, ...ended].slice(-500) });
  return ended;
}

// ── the accept verb ────────────────────────────────────────────────────
export interface AcceptRequest {
  unit: string;
  cves: string[]; // empty with a component: every CVE of it the last scan counts on the unit
  component?: string;
  note: string;
  until: string;
  by: string;
}

// The acceptances a request makes, from the last scan, or why it cannot.
export function acceptancesFor(req: AcceptRequest, s: ScanStatus, now: number): { add: Acceptance[]; problems: string[] } {
  const problems: string[] = [];
  if (!req.note.trim()) problems.push("an acceptance needs a note: why this site accepts it");
  const until = Date.parse(req.until);
  if (!Number.isFinite(until)) problems.push("an acceptance needs --until <YYYY-MM-DD>");
  else if (until > now + MAX_ACCEPT_DAYS * DAY) problems.push(`--until is at most a year ahead`);
  else if (until <= now) problems.push("--until is in the past");
  const unitItems: CveItem[] = [];
  for (const t of s.targets) {
    if (unitName(t.id) === req.unit) unitItems.push(...(t.items ?? []));
  }
  if (!unitItems.length) problems.push(`the last scan has no CVE on ${req.unit}`);
  const picked = req.cves.length
    ? req.cves.map((c) => unitItems.find((i) => i.id === c.toUpperCase() || i.id === c) ?? null)
    : unitItems.filter((i) => i.component === req.component && i.counted);
  req.cves.forEach((c, n) => { if (!picked[n]) problems.push(`${c} is not among ${req.unit}'s CVEs in the last scan`); });
  const add: Acceptance[] = [];
  const seen = new Set<string>();
  for (const i of picked) {
    if (!i || seen.has(i.id)) continue;
    seen.add(i.id);
    if (req.component && i.component !== req.component) { problems.push(`${i.id} is ${i.component}'s, not ${req.component}'s`); continue; }
    if (i.kev) { problems.push(`${i.id} is known exploited: it cannot be accepted`); continue; }
    add.push({ component: i.component ?? "", cve: i.id, unit: req.unit, note: req.note.trim(), by: req.by,
      at: new Date(now).toISOString().slice(0, 10), until: req.until.slice(0, 10), severity: i.severity });
  }
  if (!add.length && !problems.length) problems.push("nothing to accept");
  return { add, problems };
}
