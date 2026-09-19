// offsite.ts — an off-site copy is recorded, not asserted (ADR-012 §1.5, #609).
//
// An off-site copy is worth having because a fire or a theft at the building
// does not reach it — a PHYSICAL separation, which only data can show. Every
// off-site target therefore records a `physicalLocation` shaped like the Site's
// own `site.json` `location` (ISO country, optional city and building):
//
//   a satellite holding a copy     an instance of the satellite module
//                                  (config/<instance>.json, or a pre-ADR-010
//                                  §8.4 config/satellite-<name>.json) that
//                                  carries the backup role — the pull vault — or
//                                  is the Site's PBS Host (backup.json .node)
//   config/remote-<name>.json      a peer that pulls OUR backups
//   config/pull-<name>.json        a peer WE pull — our copy is THEIR off-site
//
// (`receive-` peers push into us; where they are is their concern, not ours.)
//
// Separation is judged at the finest level BOTH sides record: a different
// country, city or building at any level both declare is separate. Equal at
// every level both declare is not shown to be separate — "same" when both
// record all three, "unproven" when one of them stops short. Nothing here is
// an error: an existing site's peers predate the field, and a peer in the same
// city may still be a sound buddy. `validate` reports each as a warning.

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";

export interface Place {
  country?: string;
  city?: string;
  building?: string;
}

export type Separation = "separate" | "same" | "unproven" | "unrecorded";

const LEVELS = ["country", "city", "building"] as const;

function norm(v: unknown): string {
  return typeof v === "string" ? v.trim().toLowerCase() : "";
}

/** A Place from a config value, or null when it records no country. */
export function asPlace(v: unknown): Place | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  if (!norm(o.country)) return null;
  const p: Place = { country: String(o.country) };
  if (norm(o.city)) p.city = String(o.city);
  if (norm(o.building)) p.building = String(o.building);
  return p;
}

export function separation(site: Place | null, target: Place | null): Separation {
  if (!target) return "unrecorded";
  if (!site) return "unproven"; // nothing to compare against
  for (const l of LEVELS) {
    const a = norm(site[l]);
    const b = norm(target[l]);
    if (!a || !b) return "unproven";
    if (a !== b) return "separate";
  }
  return "same";
}

export function placeText(p: Place | null): string {
  if (!p) return "-";
  return [p.building, p.city, p.country?.toUpperCase()].filter(Boolean).join(", ");
}

export interface OffsiteTarget {
  /** "satellite" | "remote" | "pull" */
  role: string;
  name: string;
  file: string;
  place: Place | null;
  separation: Separation;
}

function readObj(f: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(readFileSync(f, "utf8")) as unknown;
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** The Site's own place: site.json `location`. */
export function sitePlace(configDir: string): Place | null {
  return asPlace(readObj(join(configDir, "site.json"))?.location);
}

const TARGET_PREFIXES: Array<[string, string]> = [
  ["remote-", "remote"],
  ["pull-", "pull"],
];

/** True when a config is an instance of the satellite module — by its
 *  recorded source, or the file name satellite-manager used before §8.4. */
function isSatellite(file: string, cfg: Record<string, unknown>): boolean {
  const src = cfg.moduleSource ?? cfg.location;
  if (typeof src === "string" && src.replace(/\/+$/, "").split("/").pop() === "satellite") return true;
  return /(^|\/)satellite-[^/]*\.json$/.test(file);
}

/** Every off-site target this site has, with how far it is shown to be away. A
 *  satellite counts only when it holds a copy: a relay (reverse-proxy,
 *  admin-vpn) carries no backups, so where it is says nothing about them. */
export function offsiteTargets(configDir: string): OffsiteTarget[] {
  if (!existsSync(configDir)) return [];
  const site = sitePlace(configDir);
  const pbsHost = readObj(join(configDir, "backup.json"))?.node;
  const out: OffsiteTarget[] = [];
  for (const f of readdirSync(configDir).sort()) {
    if (!f.endsWith(".json")) continue;
    const b = f.slice(0, -".json".length);
    const file = join(configDir, f);
    const hit = TARGET_PREFIXES.find(([p]) => b.startsWith(p));
    if (hit) {
      const place = asPlace(readObj(file)?.physicalLocation);
      out.push({ role: hit[1], name: b.slice(hit[0].length), file, place, separation: separation(site, place) });
      continue;
    }
    const cfg = readObj(file);
    if (!cfg || !isSatellite(file, cfg)) continue;
    const roles = Array.isArray(cfg.roles) ? cfg.roles : [];
    if (!roles.includes("backup") && pbsHost !== b) continue;
    const place = asPlace(cfg.physicalLocation);
    out.push({ role: "satellite", name: b, file, place, separation: separation(site, place) });
  }
  return out;
}

/** One warning per target not shown to be off-site; [] when all are. */
export function offsiteWarnings(configDir: string): string[] {
  const site = sitePlace(configDir);
  const warnings: string[] = [];
  for (const t of offsiteTargets(configDir)) {
    const what = `${t.role} '${t.name}'`;
    if (t.separation === "unrecorded") {
      warnings.push(
        `${what} records no physicalLocation — nothing shows it is off-site. ` +
          `Add "physicalLocation": {"country": "XX", "city": "…"} to ${t.file}`,
      );
    } else if (t.separation === "same") {
      warnings.push(`${what} is at ${placeText(t.place)} — the Site's own place; it is not an off-site copy`);
    } else if (t.separation === "unproven") {
      warnings.push(
        `${what} (${placeText(t.place)}) is not shown to be away from the Site (${placeText(site)}): ` +
          `record the city, and if they share one the building, on both`,
      );
    }
  }
  return warnings;
}
