// locations.ts — the site's locations, owned by site-manager (ADR-036 D1, D5).
//
// A location is a place with an address: the site's own building, a
// provider's data centre, a backup buddy's site. site.json keeps them in
// `locations{}` by name, and `primaryLocation` names the one the site is at —
// its timezone is the site's. Everything else that is somewhere names a
// location (a backup peer's `location` today; rooms and devices later) and
// reads the address from here, so every manager answers "where is it" the
// same way, through siteLocation() and primaryLocation().
//
// site-manager's location verbs and backup-manager's `peer add` both edit
// through addLocation / modifyLocation / deleteLocation, so the rules (a
// valid name, a country, the primary and a named location are never deleted)
// are written once.
//
// A site.json from before migration 0019 has only `location` (country, city,
// building, timezone, locale, keyboard). readLocations() reads it as the one
// location the migration will make of it, so a reader works in the window
// between the pull and the migration, and on a restored older config.

import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { defaultConfigDir, readJsonObject } from "./config-io";

type Obj = Record<string, unknown>;

export type LocationKind = "site" | "remote";

export interface Location {
  name: string;
  displayName?: string;
  kind?: LocationKind;
  country: string;
  city?: string;
  address?: string;
  timezone?: string;
  latitude?: number;
  longitude?: number;
}

/** The fields of a location a verb may set (the name is its key). */
export type LocationFields = Partial<Omit<Location, "name">>;

export const LOCATION_NAME = /^[a-z][a-z0-9-]{0,62}$/;
export const LOCATION_KINDS: LocationKind[] = ["site", "remote"];

const obj = (v: unknown): Obj | null => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const str = (v: unknown): string | undefined => (typeof v === "string" && v.trim() !== "" ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

// The letters a place name is written with that ASCII has no single letter
// for. Migration 0019 carries the same table in jq: both must name a place the
// same way.
const TRANSLIT: Record<string, string> = {
  æ: "ae", ø: "oe", å: "aa", ä: "ae", ö: "oe", ü: "ue", ß: "ss",
  á: "a", à: "a", â: "a", ã: "a", é: "e", è: "e", ê: "e", ë: "e", í: "i", ì: "i", î: "i", ï: "i",
  ó: "o", ò: "o", ô: "o", õ: "o", ú: "u", ù: "u", û: "u", ý: "y", ç: "c", ñ: "n", ł: "l", š: "s", ž: "z", č: "c",
};

/** The name a place gets from its text (a building, a city): lower-case
 *  ASCII, words joined by '-', starting with a letter. "" when nothing is left. */
export function locationName(text: unknown): string {
  if (typeof text !== "string") return "";
  let s = text.toLowerCase().replace(/[^\x00-\x7f]/g, (c) => TRANSLIT[c] ?? "-");
  s = s.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  if (s === "") return "";
  if (!/^[a-z]/.test(s)) s = `loc-${s}`;
  return s.slice(0, 63).replace(/-+$/, "");
}

/** A name not yet taken: base, then base-2, base-3, … */
export function freeName(taken: Record<string, unknown>, base: string): string {
  if (!(base in taken)) return base;
  for (let i = 2; ; i++) {
    const n = `${base.slice(0, 60)}-${i}`;
    if (!(n in taken)) return n;
  }
}

function toLocation(name: string, raw: Obj): Location {
  const l: Location = { name, country: str(raw.country) ?? "" };
  for (const k of ["displayName", "city", "address", "timezone"] as const) {
    const v = str(raw[k]);
    if (v !== undefined) l[k] = v;
  }
  if (raw.kind === "site" || raw.kind === "remote") l.kind = raw.kind;
  const lat = num(raw.latitude);
  const lon = num(raw.longitude);
  if (lat !== undefined) l.latitude = lat;
  if (lon !== undefined) l.longitude = lon;
  return l;
}

/** The name migration 0019 gives the retired `location`: its building, else
 *  its city, else the site's code, else "site". */
export function legacyPrimaryName(site: Obj): string {
  const loc = obj(site.location) ?? {};
  return locationName(loc.building) || locationName(loc.city) || locationName(site.name) || "site";
}

export interface SiteLocations {
  locations: Record<string, Location>;
  primary: string | null;
  // read from the retired `location` (migration 0019 has not run)
  legacy: boolean;
}

/** The locations of a parsed site.json, and the primary one's name. */
export function readLocations(site: Obj | null): SiteLocations {
  const s = site ?? {};
  const map = obj(s.locations);
  if (map) {
    const locations: Record<string, Location> = {};
    for (const [n, raw] of Object.entries(map)) {
      const o = obj(raw);
      if (o) locations[n] = toLocation(n, o);
    }
    return { locations, primary: str(s.primaryLocation) ?? null, legacy: false };
  }
  const old = obj(s.location);
  if (old) {
    const name = legacyPrimaryName(s);
    const l = toLocation(name, { ...old, address: old.building, displayName: old.building ?? old.city });
    return { locations: { [name]: l }, primary: name, legacy: true };
  }
  return { locations: {}, primary: null, legacy: false };
}

/** site.json's locale and keyboard: site-wide, at the top level (or under the
 *  retired `location`). */
export function siteLocale(site: Obj | null): { locale?: string; keyboard?: string } {
  const old = obj(site?.location) ?? {};
  const out: { locale?: string; keyboard?: string } = {};
  const locale = str(site?.locale) ?? str(old.locale);
  const keyboard = str(site?.keyboard) ?? str(old.keyboard);
  if (locale) out.locale = locale;
  if (keyboard) out.keyboard = keyboard;
  return out;
}

function readSite(configDir: string): Obj | null {
  try {
    return readJsonObject(join(configDir, "site.json"));
  } catch {
    return null;
  }
}

/** The named location, or the primary one when no name is given; null when
 *  site.json has no such location. */
export function siteLocation(name?: string, configDir: string = defaultConfigDir()): Location | null {
  const { locations, primary } = readLocations(readSite(configDir));
  const n = name ?? primary;
  return n ? locations[n] ?? null : null;
}

/** The location the site is at. */
export function primaryLocation(configDir: string = defaultConfigDir()): Location | null {
  return siteLocation(undefined, configDir);
}

/** A location's address as one line: address, city, COUNTRY. */
export function placeText(l: { address?: string; city?: string; country?: string } | null): string {
  if (!l) return "-";
  return [l.address, l.city, l.country ? l.country.toUpperCase() : undefined].filter(Boolean).join(", ") || "-";
}

const norm = (v: unknown): string => (typeof v === "string" ? v.trim().toLowerCase() : "");

/** The location at the same place — the same country, city and address, case
 *  and spaces ignored, an absent one equal only to an absent one. */
export function findLocation(locations: Record<string, Location>, place: { country?: string; city?: string; address?: string }): string | null {
  for (const [n, l] of Object.entries(locations)) {
    if (norm(l.country) === norm(place.country) && norm(l.city) === norm(place.city) && norm(l.address) === norm(place.address)) return n;
  }
  return null;
}

// ── what names a location ──────────────────────────────────────────────

/** Every record that names a location, as [what, location]: a config whose
 *  top-level `location` is a name (a backup peer; a machine or device later —
 *  a string with a '/' is the module directory field migration 0006 renamed,
 *  never a place), and a room or recorded device of racks.json/positions.json. */
export function locationReferences(configDir: string): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  if (!existsSync(configDir)) return out;
  for (const f of readdirSync(configDir).sort()) {
    if (!f.endsWith(".json") || f === "site.json") continue;
    let raw: Obj | null;
    try {
      raw = readJsonObject(join(configDir, f));
    } catch {
      continue;
    }
    if (!raw) continue;
    if (typeof raw.location === "string" && raw.location !== "" && !raw.location.includes("/")) out.push([f, raw.location]);
    if (f === "racks.json" || f === "positions.json") {
      for (const part of ["rooms", "devices"]) {
        for (const [n, v] of Object.entries(obj(raw[part]) ?? {})) {
          const l = obj(v)?.location;
          if (typeof l === "string" && l !== "") out.push([`${f} ${part === "rooms" ? "room" : "device"} ${n}`, l]);
        }
      }
    }
  }
  return out;
}

/** What names this location. */
export function locationNamers(configDir: string, name: string): string[] {
  return locationReferences(configDir).filter(([, l]) => l === name).map(([w]) => w);
}

/** What is wrong with site.json's locations: [] when nothing. */
export function locationErrors(site: Obj, configDir: string): string[] {
  const errs: string[] = [];
  if ("location" in site) errs.push("site.json still carries location, which is retired: migration 0019 moves it into locations (it runs with the next update)");
  const { locations, primary } = readLocations({ ...site, location: undefined });
  if (Object.keys(locations).length === 0 && !("location" in site)) {
    errs.push("site.json records no locations: add the site's own with site-manager location add <name> --country <CC> --timezone <tz> --primary");
  }
  for (const [n, l] of Object.entries(locations)) {
    if (!LOCATION_NAME.test(n)) errs.push(`location '${n}': a name is lower-case letters, digits and '-', starting with a letter`);
    if (!/^[A-Za-z]{2}$/.test(l.country)) errs.push(`location '${n}' records no country (an ISO 3166-1 alpha-2 code)`);
  }
  if (!primary) {
    if (Object.keys(locations).length > 0) errs.push("site.json names no primaryLocation: site-manager site modify --primaryLocation <name>");
  } else if (!locations[primary]) {
    errs.push(`primaryLocation '${primary}' is not one of the site's locations`);
  } else if (!locations[primary].timezone) {
    errs.push(`the primary location '${primary}' records no timezone, the site's: site-manager location modify ${primary} --timezone <tz>`);
  }
  for (const [what, l] of locationReferences(configDir)) {
    if (!locations[l]) errs.push(`${what} names location '${l}', which site.json does not have`);
  }
  return errs;
}

// ── the edits ──────────────────────────────────────────────────────────

/** The checks every set of fields passes; throws with the reason. */
function checkFields(f: LocationFields): void {
  if (f.country !== undefined && !/^[A-Za-z]{2}$/.test(f.country)) throw new Error(`--country takes an ISO 3166-1 alpha-2 code (e.g. DK), not '${f.country}'`);
  if (f.kind !== undefined && !LOCATION_KINDS.includes(f.kind)) throw new Error(`--kind is one of ${LOCATION_KINDS.join(", ")}`);
  if (f.latitude !== undefined && (!Number.isFinite(f.latitude) || f.latitude < -90 || f.latitude > 90)) throw new Error("--latitude must be between -90 and 90");
  if (f.longitude !== undefined && (!Number.isFinite(f.longitude) || f.longitude < -180 || f.longitude > 180)) throw new Error("--longitude must be between -180 and 180");
}

function locationsOf(doc: Obj): Obj {
  if (!obj(doc.locations) && obj(doc.location)) {
    throw new Error("site.json still has the retired location: migration 0019 moves it into locations first (it runs with the next update)");
  }
  if (!obj(doc.locations)) doc.locations = {};
  return doc.locations as Obj;
}

function written(f: LocationFields): Obj {
  const out: Obj = {};
  for (const k of ["displayName", "kind", "country", "city", "address", "timezone", "latitude", "longitude"] as const) {
    const v = f[k];
    if (v === undefined || v === "") continue;
    out[k] = k === "country" ? String(v).toUpperCase() : v;
  }
  return out;
}

/** Add a location to a site.json document (in place). `primary` also makes it
 *  the primary one, as does being the first. */
export function addLocation(doc: Obj, name: string, f: LocationFields, primary = false): Obj {
  if (!LOCATION_NAME.test(name)) throw new Error(`'${name}' is not a location name: lower-case letters, digits and '-', starting with a letter`);
  const map = locationsOf(doc);
  if (name in map) throw new Error(`location '${name}' already exists: site-manager location modify ${name}`);
  if (!f.country) throw new Error("a location needs --country (an ISO 3166-1 alpha-2 code)");
  checkFields(f);
  // The first of the site's own places is its primary one unless another is named.
  const becomesPrimary = primary || (!str(doc.primaryLocation) && f.kind !== "remote");
  if (becomesPrimary && !f.timezone) throw new Error(`the primary location needs --timezone: it is the site's`);
  map[name] = written(f);
  if (becomesPrimary) doc.primaryLocation = name;
  return doc;
}

/** Change a location's fields (in place): `set` the fields given, `unset`
 *  the optional ones named. The country cannot be unset, nor the primary
 *  location's timezone. */
export const LOCATION_OPTIONAL = ["displayName", "kind", "city", "address", "timezone", "latitude", "longitude"] as const;
export function modifyLocation(doc: Obj, name: string, set: LocationFields, unset: string[] = []): Obj {
  const map = locationsOf(doc);
  const cur = obj(map[name]);
  if (!cur) throw new Error(`location '${name}' does not exist (site-manager location list)`);
  for (const u of unset) {
    if (u === "country") throw new Error("a location keeps its country: give another one instead");
    if (!(LOCATION_OPTIONAL as readonly string[]).includes(u)) throw new Error(`a location has no field '${u}' (${LOCATION_OPTIONAL.join(", ")})`);
  }
  checkFields(set);
  const next: Obj = { ...cur, ...written(set) };
  for (const u of unset) delete next[u];
  if (doc.primaryLocation === name && !str(next.timezone)) throw new Error(`'${name}' is the primary location: its timezone is the site's and stays`);
  map[name] = next;
  return doc;
}

/** Remove a location (in place). Refused for the primary one and for one that
 *  anything names. */
export function deleteLocation(doc: Obj, name: string, configDir: string): Obj {
  const map = locationsOf(doc);
  if (!(name in map)) throw new Error(`location '${name}' does not exist (site-manager location list)`);
  if (doc.primaryLocation === name) throw new Error(`'${name}' is the primary location: make another one primary first (site-manager site modify --primaryLocation <name>)`);
  const by = locationNamers(configDir, name);
  if (by.length) throw new Error(`location '${name}' is named by ${by.join(", ")}: point them at another location first`);
  delete map[name];
  return doc;
}

/** The location at a place, made when the site has none: how `peer add
 *  --country --city` names its peer's place. Returns its name and whether it
 *  was made. */
export function ensureLocation(doc: Obj, place: { country: string; city?: string; address?: string }, fallback: string, kind: LocationKind = "remote"): { name: string; created: boolean } {
  const map = locationsOf(doc);
  const { locations } = readLocations(doc);
  const hit = findLocation(locations, place);
  if (hit) return { name: hit, created: false };
  const base = locationName(place.address) || locationName(place.city) || locationName(fallback) || "remote";
  const name = freeName(map, base);
  const displayName = place.address ?? place.city;
  addLocation(doc, name, { ...(displayName ? { displayName } : {}), kind, country: place.country, city: place.city, address: place.address });
  return { name, created: true };
}
