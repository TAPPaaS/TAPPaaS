// overview.ts — the Overview page as data: the four area tiles (Site,
// Environment, Modules, Identity), each summed up from the reads its own page
// makes, with the worst condition of the area's classes; and the Alerts, the
// ten open events that matter most. Plain data: the unit tests run it over
// hrossen's records.

import { envCards, EnvLike, ModuleLike, ZoneLike } from "./envcards";
import { Gate, HealthStatus, HealthSummary, JobSummary, ModuleSummary, OpsEvent, Operations, SiteRead, StorageInventory } from "./types";
import { CONDITION_TYPES } from "./healthwords";

const RANK: Record<HealthStatus, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };
const worst = (list: HealthStatus[]): HealthStatus => list.reduce<HealthStatus>((a, s) => (RANK[s] > RANK[a] ? s : a), "ok");

// ── the worst per area ────────────────────────────────────────────────

export type Area = "site" | "environment" | "modules" | "identity";

// The CMDB classes each tile answers for (the metamodel's: ci.json, place.json,
// resource.json). A condition sits on a concrete class, so every subclass is named.
export const AREA_CLASSES: Record<Area, string[]> = {
  site: [
    "site", "cluster", "machine", "device",
    "place", "location", "room", "rack",
    "asset", "server", "network-device", "appliance", "passive-device", "other-device", "port", "disk", "pool",
    "storage-element", "storage-pool", "share", "datastore", "backup-peer",
  ],
  environment: ["environment", "zone"],
  modules: ["vm", "lxc", "app", "service", "controller", "manager"],
  identity: ["identity", "organization", "group", "user", "role"],
};

/** The worst open condition on an object of the area's classes; null when the CMDB holds no conditions. */
export function areaStatus(s: HealthSummary | null | undefined, area: Area): HealthStatus | null {
  if (!s?.available) return null;
  const classes = new Set(AREA_CLASSES[area]);
  const items = Object.values(s.byType).flatMap((t) => t.items).filter((i) => classes.has(i.class) && !i.silenced);
  return worst(items.map((i) => i.status));
}

/** A tile's colour from a gate's or a badge's word. */
export const fromLevel = (l: string | null | undefined): HealthStatus =>
  l === "fail" || l === "critical" ? "critical" : l === "warn" || l === "warning" ? "warning" : l === "pass" || l === "ok" ? "ok" : "unknown";

// ── Site ──────────────────────────────────────────────────────────────

export interface SiteTile {
  name: string | null;
  locations: { name: string; label: string; primary: boolean }[];
  nodes: { name: string; location: string | null; status: HealthStatus; text: string | null }[];
  quorum: { status: HealthStatus; text: string } | null;
  storage: { used: number; total: number; pools: number } | null;
  status: HealthStatus;
}

interface Loc {
  displayName?: string;
}

export function siteTile(site: SiteRead | null | undefined, storage: StorageInventory | null | undefined, gates: Gate[] | null | undefined, summary: HealthSummary | null | undefined): SiteTile {
  const s = (site?.site ?? {}) as SiteRead["site"] & { locations?: Record<string, Loc>; primaryLocation?: string };
  const locations = Object.entries(s.locations ?? {})
    .map(([name, l]) => ({ name, label: l.displayName ?? name, primary: name === s.primaryLocation }))
    .sort((a, b) => Number(b.primary) - Number(a.primary) || a.name.localeCompare(b.name));
  const conditions = summary?.available ? Object.values(summary.byType).flatMap((t) => t.items).filter((i) => !i.silenced && (i.class === "machine" || i.class === "server")) : null;
  const nodes = (site?.nodes ?? []).map((n) => {
    const st = storage?.nodes.find((x) => x.name === n.name) ?? null;
    let status: HealthStatus;
    let text: string | null = null;
    if (conditions) {
      const mine = conditions.filter((i) => i.label === n.name);
      status = worst(mine.map((i) => i.status));
      text = mine.sort((a, b) => RANK[b.status] - RANK[a.status])[0]?.reason ?? null;
    } else if (st) {
      status = fromLevel(st.state);
      text = st.reasons[0] ?? null;
    } else status = "unknown";
    if (st && !st.reachable) {
      status = worst([status, "warning"]);
      text = text ?? "not reachable";
    }
    return { name: n.name, location: n.location ?? null, status, text };
  });
  const q = gates?.find((g) => g.name === "quorum") ?? null;
  const quorum = q ? { status: q.status === "skip" ? ("unknown" as HealthStatus) : fromLevel(q.status), text: q.detail } : null;
  let storageSum: SiteTile["storage"] = null;
  for (const n of storage?.nodes ?? []) {
    for (const p of n.pools) {
      if (!p.usable) continue;
      storageSum ??= { used: 0, total: 0, pools: 0 };
      storageSum.used += p.usable.used;
      storageSum.total += p.usable.total;
      storageSum.pools++;
    }
  }
  const own = areaStatus(summary, "site");
  const status = own ?? worst([...(quorum ? [quorum.status] : []), ...(storage?.nodes ?? []).map((n) => fromLevel(n.state))]);
  return { name: s.displayName ?? s.name ?? null, locations, nodes, quorum, storage: storageSum, status: site ? status : "unknown" };
}

// ── Environment ───────────────────────────────────────────────────────

export interface EnvRow {
  name: string;
  label: string;
  zone: string | null;
  isDefault: boolean;
  modules: number;
  maturity: { word: string; count: number }[]; // its modules' maturity, the most first
  status: HealthStatus; // the worst health badge of its modules
}
export interface EnvironmentTile {
  envs: EnvRow[];
  status: HealthStatus;
}

type Mod = ModuleLike & Pick<ModuleSummary, "badges">;

export function environmentTile(envs: EnvLike[] | null | undefined, zones: ZoneLike[] | null | undefined, modules: Mod[] | null | undefined, defaultEnv: string | null, summary: HealthSummary | null | undefined): EnvironmentTile {
  const cards = envCards(envs ?? [], zones ?? [], modules ?? [], defaultEnv);
  const rows = cards.map((c) => {
    const mods = c.boxes.flatMap((b) => b.modules);
    const by = new Map<string, number>();
    for (const m of mods) {
      const w = m.badges.maturity ?? "unknown";
      by.set(w, (by.get(w) ?? 0) + 1);
    }
    return {
      name: c.env.name,
      label: c.env.displayName ?? c.env.name,
      zone: c.zone,
      isDefault: c.isDefault,
      modules: c.modules,
      maturity: [...by.entries()].map(([word, count]) => ({ word, count })).sort((a, b) => b.count - a.count || a.word.localeCompare(b.word)),
      status: worst(mods.map((m) => fromLevel(m.badges.health))),
    };
  });
  // The default environment first, then by name.
  rows.sort((a, b) => Number(b.isDefault) - Number(a.isDefault) || a.name.localeCompare(b.name));
  const own = areaStatus(summary, "environment");
  return { envs: rows, status: envs ? own ?? worst(rows.map((r) => r.status)) : "unknown" };
}

// ── Modules ───────────────────────────────────────────────────────────

export interface ModulesTile {
  total: number;
  running: number;
  stopped: number;
  updating: number;
  archived: number;
  noGuest: number; // config-only modules: nothing of their own to run
  sweepActive: boolean;
  lastUpdates: { what: string; at: string | null; ok: boolean; sweep: boolean }[];
  attention: { name: string; level: "fail" | "warn" }[];
  status: HealthStatus;
}

// The verbs that change a module's software: a job of one of them, running, is an update in progress.
const UPDATE_VERBS = new Set(["update", "install", "upgrade", "rollback"]);
// The module a job names: its object (the verb's first positional).
const jobModule = (j: JobSummary): string | null => (j.object && j.object !== j.verb ? j.object : null);

export function modulesTile(
  modules: ModuleSummary[] | null | undefined,
  jobs: JobSummary[] | null | undefined,
  sweepActive: boolean,
  lastSweep: SiteRead["lastSweep"] | null | undefined,
  summary: HealthSummary | null | undefined,
  lastN = 3,
): ModulesTile {
  const list = modules ?? [];
  const mm = (jobs ?? []).filter((j) => j.bin === "module-manager" && UPDATE_VERBS.has(j.verb.split(" ")[0]) && j.kind === "apply");
  const busy = new Set(mm.filter((j) => j.state === "running" || j.state === "queued").map(jobModule).filter((m): m is string => !!m));
  const archived = (m: ModuleSummary): boolean => (m.status ?? "").toLowerCase() === "archived";
  const t: ModulesTile = { total: list.length, running: 0, stopped: 0, updating: 0, archived: 0, noGuest: 0, sweepActive, lastUpdates: [], attention: [], status: "unknown" };
  for (const m of list) {
    if (archived(m)) t.archived++;
    else if (busy.has(m.name)) t.updating++;
    else if (m.badges.run === "running") t.running++;
    else if (m.badges.run === "stopped") t.stopped++;
    else t.noGuest++;
  }
  const done = mm
    .filter((j) => j.state === "done" && j.ended)
    .map((j) => ({ what: jobModule(j) ?? j.verb, at: j.ended, ok: j.exit === 0, sweep: false }));
  const sweep = lastSweep?.end_time ? [{ what: "sweep", at: lastSweep.end_time.replace(" ", "T"), ok: !!lastSweep.ok, sweep: true }] : [];
  t.lastUpdates = [...done, ...sweep].sort((a, b) => Date.parse(b.at ?? "") - Date.parse(a.at ?? "")).slice(0, lastN);
  t.attention = list
    .filter((m) => m.badges.health === "fail" || m.badges.health === "warn")
    .map((m) => ({ name: m.name, level: m.badges.health as "fail" | "warn" }))
    .sort((a, b) => Number(b.level === "fail") - Number(a.level === "fail") || a.name.localeCompare(b.name));
  const own = areaStatus(summary, "modules");
  t.status = modules ? own ?? worst(list.map((m) => fromLevel(m.badges.health))) : "unknown";
  return t;
}

// ── Identity ──────────────────────────────────────────────────────────

export interface IdentityTile {
  counts: { users: number; groups: number; roles: number; orgs: number } | null;
  provider: { module: string; installed: boolean; run: string; health: HealthStatus } | null;
  status: HealthStatus;
}

/** The identity provider is the `identity` module (Authentik). */
export const IDENTITY_MODULE = "identity";

export function identityTile(identity: Record<string, string[]> | null | undefined, modules: ModuleSummary[] | null | undefined, summary: HealthSummary | null | undefined): IdentityTile {
  const n = (k: string): number => identity?.[k]?.length ?? 0;
  const counts = identity ? { users: n("user"), groups: n("group"), roles: n("role"), orgs: n("org") } : null;
  const m = modules?.find((x) => x.name === IDENTITY_MODULE) ?? null;
  const health: HealthStatus = m ? (m.condition && !m.condition.acknowledged && !m.condition.maintenance ? m.condition.status : fromLevel(m.badges.health)) : "unknown";
  const provider = modules ? { module: IDENTITY_MODULE, installed: !!m, run: m?.badges.run ?? "none", health } : null;
  const own = areaStatus(summary, "identity");
  const parts: HealthStatus[] = [...(own !== null ? [own] : []), ...(provider ? [provider.installed ? health : "critical"] : [])];
  if (provider?.installed && provider.run === "stopped") parts.push("critical");
  return { counts, provider, status: identity || modules ? worst(parts) : "unknown" };
}

// ── the health strip: one card per condition type ─────────────────────

export interface TypeCard {
  type: string;
  status: HealthStatus; // the worst open one; ok when none
  critical: number; // objects, open (not silenced)
  warning: number;
  silenced: number;
  names: string[]; // the first few open, worst first
}

/** One card per condition type, in the filter's order, from the conditions the
 *  CMDB holds: what is open, what is silenced, the first names. */
export function typeCards(s: HealthSummary | null | undefined): TypeCard[] {
  if (!s?.available) return [];
  return CONDITION_TYPES.map((type) => {
    const items = s.byType[type]?.items ?? [];
    const open = items.filter((i) => !i.silenced && (i.status === "critical" || i.status === "warning")).sort((a, b) => RANK[b.status] - RANK[a.status] || a.label.localeCompare(b.label));
    return {
      type,
      status: worst(open.map((i) => i.status)),
      critical: open.filter((i) => i.status === "critical").length,
      warning: open.filter((i) => i.status === "warning").length,
      silenced: items.filter((i) => i.silenced && i.status !== "ok").length,
      names: [...new Set(open.map((i) => i.label))].slice(0, 3),
    };
  });
}

/** A card's line: "2 critical · 1 warning", or "ok". */
export function typeValue(c: TypeCard): string {
  const parts = [c.critical ? `${c.critical} critical` : "", c.warning ? `${c.warning} warning` : ""].filter(Boolean);
  return parts.length ? parts.join(" · ") : "ok";
}

// ── Alerts ────────────────────────────────────────────────────────────

export interface Alerts {
  rows: OpsEvent[];
  total: number;
  more: number; // past the first `max`: the Health page's root list has them
}

const sinceMs = (s: string | null): number => (s ? Date.parse(s) || 0 : 0);

/** The open events, critical first, then warning, the newest first within each; the first `max`. */
export function topAlerts(ops: Operations | null | undefined, max = 10): Alerts {
  const all = (ops?.groups ?? []).flatMap((g) => g.events);
  const sorted = [...all].sort((a, b) => RANK[b.status] - RANK[a.status] || sinceMs(b.since) - sinceMs(a.since) || a.label.localeCompare(b.label) || a.id.localeCompare(b.id));
  const rows = sorted.slice(0, max);
  return { rows, total: all.length, more: all.length - rows.length };
}

/** Bytes as the tile shows them: 1.2 TB. */
// Memory is counted in powers of 1024, as the machines and their vendors do:
// "64 GiB" installed, not the 68.7 GB that bytes() would say of storage.
export function binaryBytes(n: number): string {
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

export function bytes(n: number): string {
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let i = 0;
  let v = n;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}
