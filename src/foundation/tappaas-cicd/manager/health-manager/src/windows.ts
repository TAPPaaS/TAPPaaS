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
// (by name, or a machine by its hostname) and everything that runs on it, down
// the chain: a node's guests, a guest's services and applications.

import { readdirSync, readFileSync } from "fs";
import { join } from "path";
import { CmdbItem, CmdbRel } from "./assess-model";

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

/** The objects a window covers, by id. */
export function covered(w: Window, objects: CmdbItem[], relations: CmdbRel[]): Set<string> {
  if (w.scope === "site") return new Set(objects.map((o) => o.id));
  const names = new Set(w.scope.map(short));
  const out = new Set(
    objects
      .filter((o) => names.has(o.name) || (typeof o.attributes.hostname === "string" && names.has(short(o.attributes.hostname))))
      .map((o) => o.id),
  );
  const on = new Map<string, string[]>();
  for (const r of relations) if (r.type === "runs-on") on.set(r.to.id, [...(on.get(r.to.id) ?? []), r.from.id]);
  for (let front = [...out]; front.length; ) {
    front = front.flatMap((id) => on.get(id) ?? []).filter((id) => !out.has(id));
    for (const id of front) out.add(id);
  }
  return out;
}

/** Per object, the open window that covers it and ends last. */
export function windowOf(windows: Window[], objects: CmdbItem[], relations: CmdbRel[], nowMs: number): Map<string, Window> {
  const out = new Map<string, Window>();
  for (const w of windows.filter((x) => isOpen(x, nowMs))) {
    for (const id of covered(w, objects, relations)) {
      const had = out.get(id);
      if (!had || had.until < w.until) out.set(id, w);
    }
  }
  return out;
}

/** The condition's `maintenance` a window gives. */
export const asMaintenance = (w: Window): { until: string; note: string; by: string } => ({ until: new Date(w.until * 1000).toISOString(), note: w.reason, by: `window ${w.name}` });
