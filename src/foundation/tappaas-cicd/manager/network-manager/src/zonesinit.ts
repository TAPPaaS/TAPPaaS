// zonesinit.ts — the install-time zones.json transform (ADR-007 "S6 N2").
//
// Turns the DISTRIBUTED zones.json template (keyed srv / home / guest / srv*…)
// into an INSTALL-SPECIFIC zones.json parameterised by the TAPPaaS system name
// <N>. It is a pure, offline document transform: read template → apply the
// operator-specified rules → return the new raw document. The caller (main.ts)
// persists it atomically via zones.ts's saveZones, which preserves the
// `_README` doc block and overall structure (doc-block keys are carried through
// untouched because we transform doc.raw in place and never index/drop "_*"
// keys here).
//
// Rules (operator-specified):
//   - rename  srv   → <N>            (default zone; keep config; state Active)
//   - rename  home  → <N>-private    (and in ITS access-to: srvHome → <N>)
//   - rename  guest → <N>-guest
//   - state Inactive on: srvHome, srvWork, srvCust, srvDev, work
//   - leave untouched: srvTest, iot*, dmz, netbird, test, mgmt (+ renamed)
//   - referential integrity (global): rewrite refs to a RENAMED key in
//     access-to / pinhole-allowed-from / any zone-name array|string field:
//       srv→<N>, home→<N>-private, guest→<N>-guest
//     (NOT a global srvHome→<N> — only the explicit one inside <N>-private.)
//   - idempotent: if <N> present and srv absent → no-op ("already initialised")
//
// Dependency-free TS (strict tsc, ambient env.d.ts), mirroring the rest of the
// component.

import { readFileSync } from "fs";

// Zones whose `state` is forced Inactive by the transform.
const INACTIVATE = ["srvHome", "srvWork", "srvCust", "srvDev", "work"];

// The doc-block / comment keys: never treated as zones, carried through as-is.
function isDocKey(k: string): boolean {
  return k.startsWith("_");
}

export interface ZonesInitResult {
  // The transformed raw document (ready to JSON-serialise / hand to saveZones).
  raw: Record<string, unknown>;
  // True when the input was already transformed and we made a safe no-op.
  alreadyInitialised: boolean;
}

// A sane zone-name slug: lowercase letters/digits/hyphen, must start with a
// letter, no empty / leading-trailing hyphen. (The renamed default zone becomes
// a zone-name key, so it must be a legal slug.)
const NAME_RE = /^[a-z][a-z0-9-]*$/;

export function validateName(name: string): void {
  if (name.length === 0) {
    throw new Error("zones-init: --name is required and must be non-empty");
  }
  if (name.endsWith("-")) {
    throw new Error(`zones-init: --name '${name}' must not end with a hyphen`);
  }
  if (!NAME_RE.test(name)) {
    throw new Error(
      `zones-init: --name '${name}' is not a valid zone-name slug ` +
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

// Apply the install-time transform. Pure: takes the raw template object,
// returns a new raw object (the input is not mutated). `force` re-applies from
// the template even if the input already looks transformed.
export function zonesInit(
  template: Record<string, unknown>,
  name: string,
  force: boolean,
): ZonesInitResult {
  validateName(name);

  // Idempotency / already-initialised check (only meaningful without --force):
  // a transformed doc has <N> present and `srv` absent.
  if (!force && name in template && !("srv" in template)) {
    return { raw: template, alreadyInitialised: true };
  }

  // Validate the template has the expected distributed keys before we touch it.
  for (const required of ["srv", "home", "guest"]) {
    if (!(required in template)) {
      throw new Error(
        `template missing expected key '${required}' — is this the distributed ` +
          `zones.json? (${force ? "--force given but " : ""}cannot transform)`,
      );
    }
  }

  const privateName = `${name}-private`;
  const guestName = `${name}-guest`;

  // The global rename map for referential integrity.
  const renames = new Map<string, string>([
    ["srv", name],
    ["home", privateName],
    ["guest", guestName],
  ]);

  // Build the output preserving key ORDER: walk the template's keys, emit each
  // (renamed where applicable) so the structure / doc-block placement is kept.
  const out: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(template)) {
    if (isDocKey(key)) {
      out[key] = val; // carry doc blocks (e.g. _README) through untouched
      continue;
    }

    let newKey = key;
    if (key === "srv") newKey = name;
    else if (key === "home") newKey = privateName;
    else if (key === "guest") newKey = guestName;

    // Deep-ish clone of the zone object (one level + arrays) so we never mutate
    // the input template.
    let zone: unknown = val;
    if (val !== null && typeof val === "object" && !Array.isArray(val)) {
      const src = val as Record<string, unknown>;
      const copy: Record<string, unknown> = {};
      for (const [f, v] of Object.entries(src)) {
        copy[f] = Array.isArray(v) ? [...v] : v;
      }
      zone = copy;
    }

    out[newKey] = zone;
  }

  // ── per-zone field edits (operate on the OUTPUT) ────────────────────

  // 1. The renamed default zone (<N>, was srv): ensure state Active.
  const defZone = out[name];
  if (defZone !== null && typeof defZone === "object" && !Array.isArray(defZone)) {
    (defZone as Record<string, unknown>).state = "Active";
  }

  // 2. <N>-private (was home): the EXPLICIT srvHome→<N> swap in its access-to.
  const privZone = out[privateName];
  if (privZone !== null && typeof privZone === "object" && !Array.isArray(privZone)) {
    const pz = privZone as Record<string, unknown>;
    if (Array.isArray(pz["access-to"])) {
      pz["access-to"] = (pz["access-to"] as unknown[]).map((el) =>
        el === "srvHome" ? name : el,
      );
    }
  }

  // 3. Force state Inactive on the listed zones (only if present).
  for (const z of INACTIVATE) {
    const zone = out[z];
    if (zone !== null && typeof zone === "object" && !Array.isArray(zone)) {
      (zone as Record<string, unknown>).state = "Inactive";
    }
  }

  // 4. GLOBAL referential integrity: rewrite refs to renamed keys everywhere.
  //    (srvHome is NOT in the rename map, so other srvHome refs are preserved
  //    pointing at the now-Inactive srvHome — exactly as specified.)
  for (const [key, val] of Object.entries(out)) {
    if (isDocKey(key)) continue;
    if (val !== null && typeof val === "object" && !Array.isArray(val)) {
      rewriteZoneRefs(val as Record<string, unknown>, renames);
    }
  }

  return { raw: out, alreadyInitialised: false };
}
