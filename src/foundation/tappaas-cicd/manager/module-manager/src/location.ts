// location.ts — where a machine is (ADR-036 D2).
//
// A machine module names the location it is at with `location`: the name of
// one of the site's locations (site.json locations{}, site-manager). Absent, it
// is at the primary location. `add` and `adopt` take `--location <name>`, or
// `--country [--city] [--building]`, which find the location at that place or
// add one of kind remote — the way `backup-manager peer add` names a peer's
// place. `modify --set location=<name>` and `validate` check the name exists.
//
// `location` once held the module's source directory (now moduleSource,
// migration 0006): a value with a '/' is that old field, never a place.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { readJsonObject, writeJsonAtomic } from "../../../lib/ts/src/config-io";
import { ensureLocation, readLocations } from "../../../lib/ts/src/locations";

/** A `location` value that is a location's name (not the old directory field). */
export function isLocationName(v: unknown): v is string {
  return typeof v === "string" && v !== "" && !v.includes("/");
}

function siteDoc(configDir: string): Record<string, unknown> | null {
  try {
    return readJsonObject(join(configDir, "site.json"));
  } catch {
    return null;
  }
}

/** Why `name` cannot be a machine's location, or null when it can. */
export function locationRefusal(configDir: string, name: string): string | null {
  if (!isLocationName(name)) return `'${name}' is not a location name (site-manager location list)`;
  const { locations } = readLocations(siteDoc(configDir));
  if (!locations[name]) {
    const known = Object.keys(locations);
    return `the site has no location '${name}'${known.length ? ` (it has: ${known.join(", ")})` : ""} — add it with site-manager location add ${name} --country <CC> --kind remote`;
  }
  return null;
}

/** What validate says about one module's place: errors and warnings. */
export function locationFindings(configDir: string, raw: Record<string, unknown>): { errors: string[]; warnings: string[] } {
  const errors: string[] = [];
  const warnings: string[] = [];
  const machine = raw.kind === "machine";
  if (isLocationName(raw.location)) {
    if (!machine) warnings.push(`'location: ${raw.location}' — only a machine names a location; a guest is where its node is`);
    const { locations } = readLocations(siteDoc(configDir));
    if (!locations[raw.location]) errors.push(`location '${raw.location}' is not one of the site's locations (site-manager location list)`);
  }
  if (raw.physicalLocation !== undefined) {
    warnings.push(
      isLocationName(raw.location)
        ? "carries both location and the retired physicalLocation — migration 0021 refuses it until one goes: module-manager module modify <instance> --unset physicalLocation"
        : "physicalLocation is retired: migration 0021 makes it a location of the site and this machine's location (it runs with the next update)",
    );
  }
  return { errors, warnings };
}

/** The kind the module's release JSON declares ("" when it cannot be read). */
export function releaseKind(moduleJson: string): string {
  if (!moduleJson || !existsSync(moduleJson)) return "";
  try {
    const k = (JSON.parse(readFileSync(moduleJson, "utf8")) as { kind?: unknown }).kind;
    return typeof k === "string" ? k : "";
  } catch {
    return "";
  }
}

export interface PlaceFlags {
  location?: string;
  country?: string;
  city?: string;
  building?: string;
}

/** Take --location, --country, --city and --building out of a flag list
 *  (`--flag value` pairs); the rest is returned untouched. */
export function takePlaceFlags(args: string[]): { place: PlaceFlags; rest: string[] } {
  const place: PlaceFlags = {};
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const k = args[i].replace(/^--/, "");
    if (args[i].startsWith("--") && (k === "location" || k === "country" || k === "city" || k === "building")) {
      const v = args[i + 1];
      if (v === undefined || v.startsWith("--")) throw new Error(`${args[i]} requires a value`);
      place[k] = v;
      i++;
      continue;
    }
    rest.push(args[i]);
  }
  return { place, rest };
}

/** The location name the place flags give, adding a location of kind remote
 *  to site.json when --country names a place the site has none at. Returns
 *  null when no place flag was given. Throws with the reason. */
export function resolvePlace(configDir: string, place: PlaceFlags, fallback: string, write = true): { name: string; created: boolean } | null {
  if (place.location !== undefined) {
    if (place.country || place.city || place.building) throw new Error("--location names a location; --country/--city/--building describe one — give one or the other");
    const why = locationRefusal(configDir, place.location);
    if (why) throw new Error(why);
    return { name: place.location, created: false };
  }
  if (!place.country) {
    if (place.city || place.building) throw new Error("--city and --building need --country (the place is recorded from the country down)");
    return null;
  }
  if (!/^[A-Za-z]{2}$/.test(place.country)) throw new Error(`--country takes an ISO 3166-1 alpha-2 code (e.g. FI), not '${place.country}'`);
  const file = join(configDir, "site.json");
  const doc = siteDoc(configDir);
  if (!doc) throw new Error(`--country needs the site's site.json (${file}) to record the location in`);
  const r = ensureLocation(doc, { country: place.country.toUpperCase(), city: place.city, address: place.building }, fallback);
  if (r.created && write) writeJsonAtomic(file, doc);
  return r;
}
