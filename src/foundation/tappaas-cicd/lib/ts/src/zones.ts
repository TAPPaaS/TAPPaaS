// zones.ts — constants of the zone model that more than one manager needs, and
// the one parse of zones.json (network-manager's loadZones and the console).
//
// CONTROL_PLANE_ZONE started in network-manager/src/archetypes.ts with the
// comment "encoded here rather than inline so the two checks cannot disagree
// about who is exempt". That instinct was right and the number of consumers has
// since grown past two — environment-manager needs the same answer for its own
// exemption — so it lives in the shared lib rather than being transcribed a
// second time. network-manager re-exports it, so its existing importers are
// unaffected.

import { existsSync, readFileSync } from "fs";

// The management zone: TAPPaaS's control plane, tier 0.
//
// It is the standing exception to the zone-model invariants, because every one
// of them describes a boundary the control plane is defined to cross:
//
//   I1 (monotonic access-to) — mgmt reaches every zone for operational
//      visibility, which is by definition an upward edge from tier 0.
//   I2 (isolation floor)     — mgmt may list an isolated zone; nobody else may.
//   I5 (no zone-wide DMZ)    — mgmt keeps its full visibility list (ADR-021 D3b).
//   ADR-014 D1 service-zone  — an environment must bind a Service zone, because
//      a Client/IoT zone *consumes* one. The control plane is neither: the mgmt
//      environment's modules live in the mgmt zone, so it IS its own segment.
//
// There is exactly one control plane per site by construction, which is why the
// exemption is by NAME rather than by type: a second `type: Management` zone
// backing an environment would be a mistake, and naming the zone keeps that
// mistake reportable.
export const CONTROL_PLANE_ZONE = "mgmt";

// ── reading zones.json ────────────────────────────────────────────────
//
// One parse, shared: network-manager's loadZones() indexes the result into its
// typed ZonesDoc, and the console reads the file once here instead of running
// `network-manager list` and then one `show` per zone (#10 of the console
// review: N+1 processes for a 2 KB file). The selection rule is the one the
// jq-based tooling used — a key beginning "_" is a doc block, and an object is
// a zone when it has a `state` or a `vlantag`.

// Doc-block / comment keys ("_comment", "_README"): never zones.
export function isDocKey(k: string): boolean {
  return k.startsWith("_");
}

// The real zones of a parsed zones.json, in file order: [name, record].
export function zoneEntries(raw: Record<string, unknown>): Array<[string, Record<string, unknown>]> {
  const out: Array<[string, Record<string, unknown>]> = [];
  for (const [k, v] of Object.entries(raw)) {
    if (isDocKey(k)) continue;
    if (v === null || typeof v !== "object" || Array.isArray(v)) continue;
    const o = v as Record<string, unknown>;
    if (!("state" in o) && !("vlantag" in o)) continue;
    out.push([k, o]);
  }
  return out;
}

// zones.json parsed: the raw object (doc blocks included, so a writer can
// preserve them) and its zones. Throws, naming the file, when it is missing,
// not JSON or not an object.
export function readZonesFile(file: string): { raw: Record<string, unknown>; entries: Array<[string, Record<string, unknown>]> } {
  if (!existsSync(file)) throw new Error(`zones.json not found: ${file}`);
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    throw new Error(`zones.json is not valid JSON: ${file} (${(e as Error).message})`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`zones.json must be a JSON object: ${file}`);
  }
  const raw = parsed as Record<string, unknown>;
  return { raw, entries: zoneEntries(raw) };
}

// An environment's zone (#865): the one Service (or, for mgmt, Management) zone
// whose `environment` names it — the zone names the environment, nothing points
// the other way. null when none does, or more than one.
export function environmentZoneIn(entries: Array<[string, Record<string, unknown>]>, env: string): string | null {
  const own = entries.filter(([, z]) => z.environment === env && (z.type === "Service" || z.type === "Management"));
  return own.length === 1 ? own[0][0] : null;
}
