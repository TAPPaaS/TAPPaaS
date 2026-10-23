// offsite.ts — an off-site copy is recorded, not asserted (ADR-012 §1.5, #609).
//
// An off-site copy is worth having because a fire or a theft at the building
// does not reach it — a PHYSICAL separation, which only data can show. The
// Site's own place is its primary location (site.json, ADR-036 D1), and every
// off-site target records where it is:
//
//   a satellite holding a copy     an instance of the satellite module
//                                  (config/<instance>.json, or a pre-ADR-010
//                                  §8.4 config/satellite-<name>.json) that
//                                  carries the backup role — the pull vault — or
//                                  is the Site's PBS Host (backup.json .node):
//                                  the location it names (`location`, ADR-036
//                                  D2); before migration 0021 it carried a
//                                  `physicalLocation`
//   config/remote-<name>.json      a peer that pulls OUR backups
//   config/pull-<name>.json        a peer WE pull — our copy is THEIR off-site
//                                  a peer names a location of the site
//                                  (`location`, ADR-036 D5); before migration
//                                  0019 it carried a `physicalLocation`
//
// (`receive-` peers push into us; where they are is their concern, not ours.)
//
// Separation is judged at the finest level BOTH sides record: a different
// country, city or building (a location's address) at any level both declare
// is separate. Equal at every level both declare is not shown to be separate —
// "same" when both record all three, or when a target names the primary
// location itself, "unproven" when one of them stops short. Nothing here is an
// error: a peer in the same city may still be a sound buddy. `validate`
// reports each as a warning.

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { Location, primaryLocation, siteLocation } from "../../../lib/ts/src/locations";
import { moduleSourceOf } from "../../../lib/ts/src/instance";

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
  /** the location it names, when it names one */
  location?: string;
  /** it names a location site.json does not have */
  missing?: boolean;
}

function readObj(f: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(readFileSync(f, "utf8")) as unknown;
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** A location as a Place: its address is the building level. */
export function locationPlace(l: Location | null): Place | null {
  if (!l || !l.country) return null;
  return asPlace({ country: l.country, city: l.city, building: l.address });
}

/** The Site's own place: its primary location. */
export function sitePlace(configDir: string): Place | null {
  return locationPlace(primaryLocation(configDir));
}

// Where a target is: the location it names, else (before migrations 0019 and
// 0021) its own physicalLocation.
function targetPlace(cfg: Record<string, unknown> | null, configDir: string, primary: string | null): { place: Place | null; location?: string; missing?: boolean; primary?: boolean } {
  const name = cfg?.location;
  if (typeof name === "string" && name !== "" && !name.includes("/")) {
    const l = siteLocation(name, configDir);
    return { place: locationPlace(l), location: name, missing: !l, primary: name === primary };
  }
  return { place: asPlace(cfg?.physicalLocation) };
}

const TARGET_PREFIXES: Array<[string, string]> = [
  ["remote-", "remote"],
  ["pull-", "pull"],
];

/** True when a config is an instance of the satellite module — by its
 *  recorded source, or the file name satellite-manager used before §8.4. */
function isSatellite(file: string, cfg: Record<string, unknown>): boolean {
  const src = moduleSourceOf(cfg);
  if (src && src.replace(/\/+$/, "").split("/").pop() === "satellite") return true;
  return /(^|\/)satellite-[^/]*\.json$/.test(file);
}

/** Every off-site target this site has, with how far it is shown to be away. A
 *  satellite counts only when it holds a copy: a relay (reverse-proxy,
 *  admin-vpn) carries no backups, so where it is says nothing about them. */
export function offsiteTargets(configDir: string): OffsiteTarget[] {
  if (!existsSync(configDir)) return [];
  const site = sitePlace(configDir);
  const primary = primaryLocation(configDir)?.name ?? null;
  const pbsHost = readObj(join(configDir, "backup.json"))?.node;
  // Naming the primary location is being at the Site, whatever it records.
  const judged = (t: ReturnType<typeof targetPlace>): Separation => (t.primary ? "same" : separation(site, t.place));
  // A locked-down satellite pulls through a `remote` peer of its own name
  // (ADR-010 §8.4.4): one copy, counted once — as the satellite.
  const satellites = new Set(
    readdirSync(configDir)
      .filter((f) => f.endsWith(".json") && !TARGET_PREFIXES.some(([p]) => f.startsWith(p)))
      .filter((f) => { const c = readObj(join(configDir, f)); return !!c && isSatellite(join(configDir, f), c); })
      .map((f) => f.slice(0, -".json".length)),
  );
  const out: OffsiteTarget[] = [];
  for (const f of readdirSync(configDir).sort()) {
    if (!f.endsWith(".json")) continue;
    const b = f.slice(0, -".json".length);
    const file = join(configDir, f);
    const hit = TARGET_PREFIXES.find(([p]) => b.startsWith(p));
    if (hit) {
      if (hit[1] === "remote" && satellites.has(b.slice(hit[0].length))) continue;
      const t = targetPlace(readObj(file), configDir, primary);
      out.push({ role: hit[1], name: b.slice(hit[0].length), file, place: t.place, separation: judged(t), ...(t.location ? { location: t.location } : {}), ...(t.missing ? { missing: true } : {}) });
      continue;
    }
    const cfg = readObj(file);
    if (!cfg || !isSatellite(file, cfg)) continue;
    const roles = Array.isArray(cfg.roles) ? cfg.roles : [];
    if (!roles.includes("backup") && pbsHost !== b) continue;
    const t = targetPlace(cfg, configDir, primary);
    out.push({ role: "satellite", name: b, file, place: t.place, separation: judged(t), ...(t.location ? { location: t.location } : {}), ...(t.missing ? { missing: true } : {}) });
  }
  return out;
}

/** One warning per target not shown to be off-site; [] when all are. */
export function offsiteWarnings(configDir: string): string[] {
  const site = sitePlace(configDir);
  const warnings: string[] = [];
  for (const t of offsiteTargets(configDir)) {
    const what = `${t.role} '${t.name}'`;
    const at = t.location ? `location '${t.location}'` : placeText(t.place);
    if (t.missing) {
      warnings.push(`${what} names location '${t.location}', which site.json does not have — nothing shows it is off-site: site-manager location add ${t.location} --country <CC> --kind remote`);
    } else if (t.separation === "unrecorded") {
      warnings.push(
        t.role === "satellite"
          ? `${what} names no location — nothing shows it is off-site: module-manager module modify ${t.name} --set location=<name> (one of site-manager location list; add one with site-manager location add <name> --country <CC> --kind remote)`
          : `${what} names no location — nothing shows it is off-site. Add "location": "<name>" (one of site-manager location list) to ${t.file}`,
      );
    } else if (t.separation === "same") {
      warnings.push(`${what} is at ${t.location ? `${at} (${placeText(t.place)})` : at} — the Site's own place; it is not an off-site copy`);
    } else if (t.separation === "unproven") {
      warnings.push(
        `${what} (${at}${t.location ? `: ${placeText(t.place)}` : ""}) is not shown to be away from the Site (${placeText(site)}): ` +
          `record the city, and if they share one the address, on both (site-manager location modify)`,
      );
    }
  }
  return warnings;
}

/** ADR-010 §8.4.3: a PBS on a managed satellite is the Site's ONLY copy, and home
 *  can reach — so delete from — it. It is protected only once something pulls it
 *  that home cannot reach: a locked-down satellite (the vault: `backup` role,
 *  `management: unmanaged`) or a `remote` peer (a buddy that pulls us). One
 *  warning until one exists; [] otherwise, and when the PBS is not on a satellite. */
export function pbsOnSatelliteWarnings(configDir: string): string[] {
  if (!existsSync(configDir)) return [];
  const node = readObj(join(configDir, "backup.json"))?.node;
  if (typeof node !== "string" || !node) return [];
  const host = readObj(join(configDir, `${node}.json`));
  if (!host || !isSatellite(join(configDir, `${node}.json`), host)) return [];
  for (const f of readdirSync(configDir)) {
    if (!f.endsWith(".json") || f === `${node}.json`) continue;
    if (f.startsWith("remote-")) return [];
    const c = readObj(join(configDir, f));
    if (c && isSatellite(join(configDir, f), c) && c.management === "unmanaged"
        && Array.isArray(c.roles) && c.roles.includes("backup")) return [];
  }
  return [
    `the Site's PBS runs on the satellite '${node}', which home can reach — and so delete from: ` +
      `there is no copy home cannot reach. Lock down a second satellite as the vault ` +
      `(module-manager module modify <instance> --lockdown) or add a buddy that pulls it (backup-manager peer add remote …)`,
  ];
}
