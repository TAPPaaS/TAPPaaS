// windows.ts — maintenance windows: one model for the alert receiver and for
// the conditions.
//
// A window is a file in /var/lib/tappaas/maintenance (TAPPAAS_MAINTENANCE_DIR),
// written by tappaas-maintenance.sh: the update opens one before it restarts a
// guest or a node's cluster stack, and `health-manager maintenance` opens one
// for a CI. The receiver holds back a silent host's alert while a window covers
// it; assess puts every condition of what a window covers in maintenance, so a
// planned restart mails no critical root cause either. Nothing else stores a
// window: the conditions' `maintenance` is assess's projection of these files.
//
// What a window covers: the whole site (scope "site"), or each object it names
// (by name, or a machine by its hostname), every condition of it, and on
// everything that object would impact if it failed, what that failure would
// explain or cover there: the health records' own spread of a simulated
// critical outage (derive.ts, `cover`). What the planned outage accounts for is
// silent; what it does not account for is still heard.

import { readdirSync, readFileSync } from "fs";
import { join } from "path";
import { CmdbItem } from "./assess-model";

export const MAINTENANCE_DIR = (): string => process.env.TAPPAAS_MAINTENANCE_DIR ?? "/var/lib/tappaas/maintenance";

export interface Window {
  name: string;
  scope: "site" | string[];
  until: number; // epoch seconds
  reason: string;
  opened?: string;
}

/** The windows in the directory, open or not; none when it is missing. */
export function readWindows(dir: string = MAINTENANCE_DIR()): Window[] {
  let files: string[];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".json") && !f.startsWith("."));
  } catch {
    return [];
  }
  const out: Window[] = [];
  for (const f of files.sort()) {
    try {
      const w = JSON.parse(readFileSync(join(dir, f), "utf8")) as Record<string, unknown>;
      const scope = w.scope === "site" ? "site" : Array.isArray(w.scope) ? w.scope.map(String) : null;
      const until = Number(w.until);
      if (!scope || !Number.isFinite(until)) continue;
      out.push({ name: String(w.name ?? f.slice(0, -5)), scope, until, reason: String(w.reason ?? "maintenance"), ...(typeof w.opened === "string" ? { opened: w.opened } : {}) });
    } catch {
      // a file being written, or not a window: not one
    }
  }
  return out;
}

export const isOpen = (w: Window, nowMs: number): boolean => w.until * 1000 > nowMs;

const short = (h: string): string => h.split(".")[0];

/** The objects a window names, by id: every object for scope "site". */
export function named(w: Window, objects: CmdbItem[]): Set<string> {
  if (w.scope === "site") return new Set(objects.map((o) => o.id));
  const names = new Set(w.scope.map(short));
  return new Set(
    objects
      .filter((o) => names.has(o.name) || (typeof o.attributes.hostname === "string" && names.has(short(o.attributes.hostname))))
      .map((o) => o.id),
  );
}

/** What a window covers on one object: every condition, or these types. */
export interface Covered { window: Window; types: Set<string> | "all" }

/** Per object, what the open windows cover. `reachOf(id)` is what a failure of
 *  a named object would explain or cover elsewhere (per object, the condition
 *  types); a named object is covered whole. Where several windows cover one
 *  object, a whole cover beats a partial one, then the window that ends last;
 *  partial types from several windows add up. */
export function windowOf(windows: Window[], objects: CmdbItem[], nowMs: number, reachOf: (id: string) => Map<string, Set<string>> = () => new Map()): Map<string, Covered> {
  const out = new Map<string, Covered>();
  const put = (id: string, w: Window, types: Set<string> | "all"): void => {
    const had = out.get(id);
    if (!had) return void out.set(id, { window: w, types: types === "all" ? "all" : new Set(types) });
    if (types === "all") {
      if (had.types !== "all" || had.window.until < w.until) out.set(id, { window: w, types: "all" });
      return;
    }
    if (had.types === "all") return;
    for (const t of types) had.types.add(t);
    if (had.window.until < w.until) had.window = w;
  };
  for (const w of windows.filter((x) => isOpen(x, nowMs))) {
    const ids = named(w, objects);
    for (const id of ids) put(id, w, "all");
    if (w.scope === "site") continue;
    for (const id of ids) for (const [obj, types] of reachOf(id)) if (!ids.has(obj) && types.size) put(obj, w, types);
  }
  return out;
}

/** Is this condition in the window that covers its object? */
export const coveredBy = (c: { type: string }, cov: Covered | undefined): Window | undefined => (cov && (cov.types === "all" || cov.types.has(c.type)) ? cov.window : undefined);

/** The condition's `maintenance` a window gives. */
export const asMaintenance = (w: Window): { until: string; note: string; by: string } => ({ until: new Date(w.until * 1000).toISOString(), note: w.reason, by: `window ${w.name}` });
