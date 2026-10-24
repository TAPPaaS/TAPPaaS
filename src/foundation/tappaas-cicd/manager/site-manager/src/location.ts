// location.ts — `site-manager location list|show|add|modify|delete` (ADR-036 D1).
//
// The site's places, in site.json `locations{}`. The edits are lib/ts
// locations.ts's, which backup-manager's `peer add` uses too; this file is the
// verbs around them: reading the flags, the --check preview, the output. The
// preview and the apply say the change in the same one line ("would modify
// location 'hareskov': …" / "modified location 'hareskov': …"); a refusal is
// one "[refused] …" line; --check --json prints the whole resulting site.json.

import { GN, CL, DieError, die, info, refused } from "../../../lib/ts/src/cli";
import {
  Location, LocationFields, LocationKind, addLocation, deleteLocation, locationNamers, modifyLocation,
  placeText, readLocations,
} from "../../../lib/ts/src/locations";
import { loadRaw, writeSite } from "./config";

export interface LocationOpts {
  configDir: string;
  json: boolean;
  flags: Map<string, string>;
  boolFlags: Set<string>;
  rest: string[];
}

const TEXT_FLAGS: Array<[string, keyof LocationFields]> = [
  ["--displayName", "displayName"], ["--country", "country"], ["--city", "city"], ["--address", "address"], ["--timezone", "timezone"],
];

// The fields given, and (modify) the ones given as '' or by --unset.
function fieldsOf(o: LocationOpts, no: (m: string) => never): { set: LocationFields; unset: string[] } {
  const set: LocationFields = {};
  const unset = (o.flags.get("--unset") ?? "").split(",").map((x) => x.trim()).filter(Boolean);
  for (const [flag, key] of TEXT_FLAGS) {
    const v = o.flags.get(flag);
    if (v === undefined) continue;
    if (v === "") unset.push(key);
    else (set as Record<string, unknown>)[key] = v;
  }
  const kind = o.flags.get("--kind");
  if (kind === "") unset.push("kind");
  else if (kind !== undefined) set.kind = kind as LocationKind;
  for (const [flag, key] of [["--latitude", "latitude"], ["--longitude", "longitude"]] as const) {
    const v = o.flags.get(flag);
    if (v === undefined) continue;
    if (v === "") {
      unset.push(key);
      continue;
    }
    const n = Number(v);
    if (!Number.isFinite(n)) no(`${flag} must be a number, in decimal degrees`);
    set[key] = n;
  }
  return { set, unset };
}

function row(l: Location, primary: string | null, configDir: string): Record<string, unknown> {
  const { name, ...fields } = l;
  return { name, ...fields, primary: name === primary, namedBy: locationNamers(configDir, name) };
}

function line(l: Location, primary: string | null): string {
  const label = l.displayName && l.displayName !== l.name ? ` "${l.displayName}"` : "";
  const kind = l.kind === "remote" ? "remote" : "site";
  return `${(l.name + (l.name === primary ? " *" : "")).padEnd(22)} ${kind.padEnd(7)} ${placeText(l)}${l.timezone ? ` · ${l.timezone}` : ""}${label}`;
}

export function cmdLocation(o: LocationOpts, siteFile: string): void {
  const sub = o.rest[0];
  const name = o.rest[1];
  const raw = loadRaw(siteFile);
  if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
  const { locations, primary } = readLocations(raw);

  if (sub === "list") {
    const all = Object.values(locations).sort((a, b) => Number(b.name === primary) - Number(a.name === primary) || a.name.localeCompare(b.name));
    if (o.json) {
      info(JSON.stringify(all.map((l) => row(l, primary, o.configDir)), null, 2));
      return;
    }
    if (!all.length) {
      info("no locations (location add <name> --country <CC> --timezone <tz>)");
      return;
    }
    for (const l of all) info(line(l, primary));
    info("(* the primary location: the site's own, and its timezone)");
    return;
  }
  if (!name) die(`location ${sub ?? ""}: expected list | show <name> | add <name> | modify <name> | delete <name>`);

  if (sub === "show") {
    const l = locations[name] ?? die(`location '${name}' does not exist (site-manager location list)`);
    const r = row(l, primary, o.configDir);
    if (o.json) {
      info(JSON.stringify(r, null, 2));
      return;
    }
    const lbl = (k: string): string => `${GN}${(k + ":").padEnd(13)}${CL}`;
    info(`${lbl("Location")}${l.name}${l.displayName && l.displayName !== l.name ? ` (${l.displayName})` : ""}${l.name === primary ? "  — the primary location" : ""}`);
    info(`${lbl("Kind")}${l.kind ?? "site"}`);
    info(`${lbl("Place")}${placeText(l)}`);
    if (l.timezone) info(`${lbl("Timezone")}${l.timezone}`);
    if (l.latitude !== undefined || l.longitude !== undefined) info(`${lbl("Position")}${l.latitude ?? "?"}, ${l.longitude ?? "?"}`);
    const by = r.namedBy as string[];
    info(`${lbl("Named by")}${by.length ? by.join(", ") : "nothing"}`);
    return;
  }

  const check = o.boolFlags.has("--check");
  const no = check ? refused : die;
  const doc = JSON.parse(JSON.stringify(raw)) as Record<string, unknown>;
  const said = locationChange(sub, name, () => {
    if (sub === "add") {
      const { set } = fieldsOf(o, no);
      addLocation(doc, name, set, o.boolFlags.has("--primary"));
      return { set, primary: doc.primaryLocation === name && primary !== name };
    }
    if (sub === "modify") {
      const { set, unset } = fieldsOf(o, no);
      if (Object.keys(set).length === 0 && unset.length === 0) no("location modify: give at least one field (see --help)");
      modifyLocation(doc, name, set, unset);
      return { set, unset };
    }
    if (sub === "delete") {
      deleteLocation(doc, name, o.configDir);
      return {};
    }
    return die(`location ${sub}: unknown subcommand (expected list | show | add | modify | delete)`);
  }, no);
  if (check) {
    info(o.json ? JSON.stringify(doc, null, 2) : `[check] ${said.check}`);
    return;
  }
  writeSite(siteFile, doc);
  info(`${GN}✓${CL} ${said.done} — run 'validate' to confirm`);
}

// What a location verb does, in one line for the dry run and one for the
// apply. edit makes the change on a copy of site.json; its refusal (a
// thrown Error) is "location <sub>: <why>".
export function locationChange(
  sub: string,
  name: string,
  edit: () => { set?: LocationFields; unset?: string[]; primary?: boolean },
  no: (m: string) => never,
): { check: string; done: string } {
  let r: ReturnType<typeof edit>;
  try {
    r = edit();
  } catch (e) {
    if (e instanceof DieError) throw e;
    return no(`location ${sub}: ${(e as Error).message}`);
  }
  const fields = [...Object.entries(r.set ?? {}).map(([k, v]) => `${k}=${String(v)}`), ...(r.unset ?? []).map((u) => `${u} unset`)].join(", ");
  const what =
    sub === "add" ? `location '${name}' (${placeText({ ...(r.set ?? {}), country: r.set?.country ?? "" })})${r.primary ? " as the primary location" : ""}`
    : sub === "modify" ? `location '${name}': ${fields}; site.json otherwise unchanged`
    : `location '${name}'`;
  const past: Record<string, string> = { add: "added", modify: "modified", delete: "deleted" };
  return { check: `would ${sub} ${what}`, done: `${past[sub] ?? sub} ${what}` };
}
