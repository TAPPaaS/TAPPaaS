// zonesinit.ts — the install-time zones.json transform (ADR-007 "S6 N2",
// re-cut for ADR-014 D7).
//
// TWO OPERATIONS share one rename:
//
//   1. initProfile()        — apply a composable PROFILE bundle (`core`, `iot`)
//                             to the live document. Additive and idempotent: a
//                             profile only ever ADDS its zones (plus the
//                             access-to `grants` its zones need on zones from
//                             another profile), never removes or deactivates
//                             anything. Existing zones WIN, so a re-run can
//                             never rebuild a live file from template defaults
//                             (#427).
//   2. renameTemplateFile() — render the WHOLE template into this install's
//                             renamed namespace. This is the merge SOURCE
//                             (zones.rename.json): merge must see every zone the
//                             release ships, whichever profiles are installed,
//                             or a field fix would never be adopted.
//
// The rename map is `srv -> <N>` and nothing else (#425: home/guest are
// site-local client-role zones whose key drives the client DNS domain
// `<zone>.internal`; renaming one re-domains every device). It is applied to
// zone KEYS, to every zone-name reference, to a `serves` value, and to the
// `grants` keys — one map, one place.
//
// `serves: "srv"` in the template is a deliberate placeholder: after the rename
// it reads `serves: "<N>"`, the DEFAULT ENVIRONMENT, which shares its name with
// the default service zone by construction (site.defaultEnvironment drives both
// — ADR-007d/#426). That is how a shipped client/IoT zone comes out of `init`
// already bound to the environment, with no literal service-zone reference to
// go stale (#424).
//
// WHAT CHANGED FROM THE PRE-D7 VERSION: there is no longer a hardcoded
// INACTIVATE list (the five srv* zones it inactivated are no longer shipped —
// see `retire` for their removal from EXISTING installs), and the
// "already initialised" marker is no longer "the template still has srv"
// (profiles are naturally idempotent: a zone already present is simply kept).
//
// Dependency-free TS (strict tsc, ambient env.d.ts), mirroring the rest of the
// component.

import { readFileSync } from "fs";
import { isDocKey } from "./zones";

export interface ZonesInitResult {
  // The transformed raw document (ready to JSON-serialise / hand to saveZones).
  raw: Record<string, unknown>;
  // True when the input was already transformed and we made a safe no-op.
  alreadyInitialised: boolean;
  // Occupied zones present in the rendered document. Informational since D7:
  // the transform no longer inactivates anything, so there is nothing to guard.
  keptActive: string[];
}

// A sane zone-name slug: lowercase letters/digits/hyphen, must start with a
// letter, no empty / leading-trailing hyphen. (The renamed default zone becomes
// a zone-name key, so it must be a legal slug.)
const NAME_RE = /^[a-z][a-z0-9-]*$/;

export function validateName(name: string): void {
  if (name.length === 0) {
    throw new Error("init: --name is required and must be non-empty");
  }
  if (name.endsWith("-")) {
    throw new Error(`init: --name '${name}' must not end with a hyphen`);
  }
  if (!NAME_RE.test(name)) {
    throw new Error(
      `init: --name '${name}' is not a valid zone-name slug ` +
        "(lowercase letters/digits/hyphen, must start with a letter)",
    );
  }
}

// Parse a zones.json template into its raw object (doc blocks included). We do
// NOT use loadZones here: that drops "_*" doc keys from its indexed view, and
// the transform must operate over the FULL raw document.
export function parseTemplate(file: string): Record<string, unknown> {
  const txt = readFileSync(file, "utf8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(txt);
  } catch (e) {
    throw new Error(`template is not valid JSON: ${file} (${(e as Error).message})`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`template must be a JSON object: ${file}`);
  }
  return parsed as Record<string, unknown>;
}

// Rewrite a single zone-name reference per the rename map (used for both array
// entries and bare-string fields).
function rewriteRef(ref: string, renames: Map<string, string>): string {
  return renames.get(ref) ?? ref;
}

// Rewrite every zone-name reference inside one zone object: array fields
// (access-to, pinhole-allowed-from, plus any other string[] of zone names) and
// any bare-string field that holds a zone name (e.g. parent). Numbers/objects
// are left alone. This is the GLOBAL referential-integrity pass.
function rewriteZoneRefs(zone: Record<string, unknown>, renames: Map<string, string>): void {
  for (const [field, val] of Object.entries(zone)) {
    if (isDocKey(field)) continue; // never touch _comment etc.
    if (Array.isArray(val)) {
      // Only rewrite arrays of strings (zone-name lists). Mixed/other arrays
      // are mapped element-wise but non-strings pass through untouched.
      zone[field] = val.map((el) => (typeof el === "string" ? rewriteRef(el, renames) : el));
    } else if (typeof val === "string") {
      // `parent` / other single zone-name fields. Plain descriptive prose is
      // not a zone reference, but rewriteRef only changes EXACT renamed keys
      // (e.g. the whole string === "srv"), so descriptions are safe.
      zone[field] = rewriteRef(val, renames);
    }
  }
}

// The one rename map this install uses. Kept in a single function so init,
// merge and the profile engine cannot diverge on it.
export function renameMap(name: string): Map<string, string> {
  return new Map<string, string>([["srv", name]]);
}

// Deep-ish clone of one zone object (fields + array fields), so no transform
// ever mutates its input template/document.
function cloneZone(v: Record<string, unknown>): Record<string, unknown> {
  const copy: Record<string, unknown> = {};
  for (const [f, fv] of Object.entries(v)) copy[f] = Array.isArray(fv) ? [...fv] : fv;
  return copy;
}

// Render the WHOLE template into this install's renamed namespace. This is the
// merge SOURCE — every zone the release ships, regardless of installed profiles.
// The renamed default zone is forced Active (it is the zone modules land in).
export function zonesInit(
  template: Record<string, unknown>,
  name: string,
  force: boolean,
  // Retained for signature compatibility with the pre-D7 callers (merge passes
  // the occupancy set). There is no longer an INACTIVATE list for it to guard —
  // retiring a legacy zone is `network-manager retire`'s job, which applies the
  // same occupancy rule — so it is accepted and reported, never acted on.
  keepActive: ReadonlySet<string> = new Set<string>(),
): ZonesInitResult {
  validateName(name);

  // Idempotency (only meaningful without --force): already renamed ⇒ no-op.
  if (!force && name in template && !("srv" in template)) {
    return { raw: template, alreadyInitialised: true, keptActive: [] };
  }
  if (!("srv" in template)) {
    throw new Error(
      `template missing expected key 'srv' — is this the distributed zones.json? ` +
        `(${force ? "--force given but " : ""}cannot transform)`,
    );
  }

  const renames = renameMap(name);
  const out: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(template)) {
    if (isDocKey(key)) {
      out[key] = val; // carry doc blocks (e.g. _README) through untouched
      continue;
    }
    const newKey = renames.get(key) ?? key;
    out[newKey] = isZoneObject(val) ? cloneZone(val) : val;
  }

  // The renamed default zone is the one modules deploy into: force it Active.
  const defZone = out[name];
  if (isZoneObject(defZone)) defZone.state = "Active";

  // GLOBAL referential integrity: rewrite refs (and `serves`) to renamed keys.
  for (const [key, val] of Object.entries(out)) {
    if (isDocKey(key)) continue;
    if (isZoneObject(val)) rewriteZoneRefs(val, renames);
  }

  const keptActive = Array.from(keepActive).filter((z) => z in out).sort();
  return { raw: out, alreadyInitialised: false, keptActive };
}

// ── ADR-014 D7: composable profiles ──────────────────────────────────

export interface ProfileSpec {
  description: string;
  zones: string[];
  // zone -> access-to entries this profile contributes to it. Lets the `iot`
  // profile give the service and client zones reach to the devices — the one
  // edge the zone definitions alone cannot express, because the target zones
  // belong to another profile. Keys are renamed like any zone reference.
  grants?: Record<string, string[]>;
}

// Read the `_profiles` block from a template. Install-time metadata: it is read
// from the SHIPPED template and deliberately never copied into a live zones.json.
export function readProfiles(template: Record<string, unknown>): Map<string, ProfileSpec> {
  const out = new Map<string, ProfileSpec>();
  const block = template["_profiles"];
  if (!isZoneObject(block)) return out;
  for (const [key, val] of Object.entries(block)) {
    if (isDocKey(key) || !isZoneObject(val)) continue;
    const zones = Array.isArray(val["zones"])
      ? (val["zones"] as unknown[]).filter((z): z is string => typeof z === "string")
      : [];
    const grantsRaw = val["grants"];
    let grants: Record<string, string[]> | undefined;
    if (isZoneObject(grantsRaw)) {
      grants = {};
      for (const [z, refs] of Object.entries(grantsRaw)) {
        if (Array.isArray(refs)) {
          grants[z] = refs.filter((r): r is string => typeof r === "string");
        }
      }
    }
    out.set(key, {
      description: typeof val["description"] === "string" ? (val["description"] as string) : "",
      zones,
      ...(grants ? { grants } : {}),
    });
  }
  return out;
}

export function profileNames(template: Record<string, unknown>): string[] {
  return Array.from(readProfiles(template).keys());
}

export interface InitProfileResult {
  raw: Record<string, unknown>; // the full document to write
  profile: string;
  added: string[]; // zones this run contributed
  preserved: string[]; // pre-existing zones kept verbatim
  granted: string[]; // "zone.access-to += ref" edges this profile contributed
  renamedFromSrv: boolean; // an existing un-renamed `srv` was carried to <name>
}

// Apply one profile to the live document.
//
// ADDITIVE and IDEMPOTENT by construction:
//   - the existing document is carried forward first, with the srv -> <name>
//     rename applied to keys AND references, so a not-yet-renamed mainline
//     `srv` becomes `<name>` carrying its config rather than duplicating;
//   - the profile then contributes ONLY the zones that are not already present
//     (unless `force`, which re-stamps this profile's zones from the template);
//   - `grants` add access-to entries, never remove any;
//   - nothing is ever deleted or deactivated. Retiring a zone is `retire`'s job.
//
// Pure: neither input is mutated.
export function initProfile(
  template: Record<string, unknown>,
  existing: Record<string, unknown>,
  name: string,
  profile: string,
  force = false,
): InitProfileResult {
  validateName(name);

  const profiles = readProfiles(template);
  const spec = profiles.get(profile);
  if (!spec) {
    throw new Error(
      `unknown profile '${profile}' (known: ${Array.from(profiles.keys()).join(", ") || "none"})`,
    );
  }

  const renames = renameMap(name);
  const out: Record<string, unknown> = {};
  const preserved: string[] = [];
  const added: string[] = [];
  const granted: string[] = [];
  let renamedFromSrv = false;

  // 1. carry the existing document forward, renamed.
  for (const [key, val] of Object.entries(existing)) {
    if (isDocKey(key)) {
      // `_profiles` is install-time metadata: never carried into a live file.
      if (key !== "_profiles") out[key] = val;
      continue;
    }
    const newKey = renames.get(key) ?? key;
    if (newKey !== key) renamedFromSrv = true;
    if (isZoneObject(val)) {
      const copy = cloneZone(val);
      rewriteZoneRefs(copy, renames);
      out[newKey] = copy;
      preserved.push(newKey);
    } else {
      out[newKey] = val;
    }
  }

  // A profile naming a zone the template does not define is a BROKEN TEMPLATE,
  // not something to work around: skipping it silently would produce a
  // half-installed profile whose missing zone only surfaces later as a dangling
  // reference. (This replaces the pre-D7 "template must contain srv/home/guest"
  // check with one that actually tracks what the profiles need.)
  const missing = spec.zones.filter((z) => !isZoneObject(template[z]));
  if (missing.length > 0) {
    throw new Error(
      `template is missing ${missing.length} zone(s) named by profile '${profile}': ` +
        `${missing.join(", ")} — is this the distributed zones.json?`,
    );
  }

  // 2. contribute this profile's zones (existing wins unless --force).
  for (const key of spec.zones) {
    const src = template[key];
    if (!isZoneObject(src)) continue;
    const newKey = renames.get(key) ?? key;
    if (newKey in out && !force) continue;
    const copy = cloneZone(src);
    rewriteZoneRefs(copy, renames);
    // The renamed default zone is what modules deploy into: ship it Active.
    if (newKey === name) copy.state = "Active";
    const isNew = !(newKey in out);
    out[newKey] = copy;
    if (isNew) added.push(newKey);
  }

  // 3. grants: additive access-to edges onto zones from another profile.
  for (const [rawZone, refs] of Object.entries(spec.grants ?? {})) {
    const zoneKey = renames.get(rawZone) ?? rawZone;
    const target = out[zoneKey];
    if (!isZoneObject(target)) continue; // that profile is not installed — skip
    const cur = Array.isArray(target["access-to"]) ? (target["access-to"] as unknown[]).slice() : [];
    for (const ref of refs) {
      const refKey = renames.get(ref) ?? ref;
      // Only grant reach to a zone that actually exists after step 2 — never
      // author a dangling reference.
      if (!isZoneObject(out[refKey])) continue;
      if (cur.includes(refKey)) continue;
      cur.push(refKey);
      granted.push(`${zoneKey}.access-to += ${refKey}`);
    }
    target["access-to"] = cur;
  }

  // 4. carry any doc block the template has and the existing file lacks
  //    (again: never `_profiles`).
  for (const [key, val] of Object.entries(template)) {
    if (!isDocKey(key) || key === "_profiles" || key in out) continue;
    out[key] = val;
  }

  return { raw: out, profile, added, preserved, granted, renamedFromSrv };
}

// Is `v` a zone object (vs a "_*" doc block or a scalar/array)?
function isZoneObject(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// NOTE: `mergeInitWithExisting` (the #427 non-destructive re-run) is RETIRED —
// `initProfile` subsumes it: it carries the existing document forward with the
// rename applied, and contributes only zones that are not already present. The
// guarantee is unchanged and is still unit-asserted; it now lives in one code
// path instead of two.

// Convenience wrapper used by zones-merge: read the repo template from disk and
// render it into the renamed namespace. `force` is always true here — merge
// re-bases upstream every run, and the template (which still ships `srv`) is
// never "already initialised". This is the single shared entry point so init and
// merge cannot diverge on how the rename is computed.
export function renameTemplateFile(
  templateFile: string,
  name: string,
  keepActive: ReadonlySet<string> = new Set<string>(),
): ZonesInitResult {
  return zonesInit(parseTemplate(templateFile), name, true, keepActive);
}
