// retire.ts — the one-time removal of zones a release stopped shipping
// (ADR-014 D7 / decision F3).
//
// WHY THIS EXISTS: deleting a zone from the template does NOT remove it from an
// existing install. The 3-way merge's zone-level rule is "in current, absent in
// source → KEEP + warn" (zonesmerge.ts), which is correct — it is what stops a
// release from silently deleting an operator's zone — but it means the D7
// template cleanup would leave `srvHome`…`srvTest`, `iot` and the four `test*`
// zones as permanent orphans on every existing system, still carrying the stale
// references #424 is about.
//
// THE GUARD (F3): a zone is retired only when it is BOTH
//   - not Active/Mandatory/Manual (i.e. it provisions nothing today), AND
//   - not named by any installed module's `zone`/`zone0`.
// Anything else is kept and reported. Retiring a zone with tenants would orphan
// a running service; retiring a live zone would tear down its interface.
//
// THE SET IS AN EXPLICIT LIST, never "everything Inactive". `work` is Inactive
// and unoccupied on many installs and is NOT retired: it is a legitimate
// trusted-client zone that is merely switched off, and `enable work` must keep
// working. `srv` is never retired either — it is the rename source.
//
// Dry-run by default. Like enable/disable this does not reconcile: the operator
// applies with `network-manager reconcile --apply` when ready. Every retired
// zone is Inactive by definition, so no plane resource exists to tear down —
// the reconcile merely converges the (now smaller) desired state.

import { ZonesDoc } from "./types";
import { getZone, listZoneNames, removeZone, saveZones } from "./zones";
import { occupiedZones } from "./zonescheck";

// Zones the D7 template no longer ships. Explicit, ordered, and deliberately
// NOT derived from "absent in the template" — an operator's own zone is also
// absent from the template and must never be swept up by this.
export const RETIRED_ZONES: readonly string[] = [
  // the five near-duplicate service zones D7 collapses into the single `srv`
  "srvHome",
  "srvWork",
  "srvCust",
  "srvDev",
  "srvTest",
  // the flat generic IoT zone (operator decision R1); its `srv` twin STAYS,
  // because `srv` is the rename source for the default service zone
  "iot",
  // test-only zones that never belonged in a shipped template
  "test",
  "testAllowA",
  "testAllowB",
  "testPinhole",
];

export type RetireVerdict = "retired" | "kept-active" | "kept-occupied" | "absent";

export interface RetireItem {
  zone: string;
  verdict: RetireVerdict;
  detail: string;
  // References to this zone that were (or would be) stripped from other zones.
  strippedFrom: string[];
}

export interface RetireResult {
  items: RetireItem[];
  retired: string[];
  kept: string[];
  changed: boolean;
}

function isLiveState(state: unknown): boolean {
  return state === "Active" || state === "Mandatory" || state === "Manual";
}

// Strip every reference to `zone` from every other zone's access-to /
// pinhole-allowed-from. Returns the zone names that actually changed.
function stripRefs(doc: ZonesDoc, zone: string): string[] {
  const touched: string[] = [];
  for (const name of listZoneNames(doc)) {
    if (name === zone) continue;
    const raw = doc.raw[name];
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) continue;
    const r = raw as Record<string, unknown>;
    let hit = false;
    for (const field of ["access-to", "pinhole-allowed-from"]) {
      if (!Array.isArray(r[field])) continue;
      const cur = r[field] as unknown[];
      const next = cur.filter((x) => x !== zone);
      if (next.length !== cur.length) {
        r[field] = next;
        const z = doc.zones.get(name);
        if (z) (z as Record<string, unknown>)[field] = next;
        hit = true;
      }
    }
    if (hit) touched.push(name);
  }
  return touched;
}

// Plan (and, when apply=true, perform) the retirement. Pure with respect to the
// filesystem: the caller persists.
export function retireZones(doc: ZonesDoc, configDir: string, apply: boolean): RetireResult {
  const occupied = occupiedZones(configDir);
  const items: RetireItem[] = [];
  const retired: string[] = [];
  const kept: string[] = [];

  for (const name of RETIRED_ZONES) {
    const z = getZone(doc, name);
    if (!z) {
      items.push({ zone: name, verdict: "absent", detail: "not present", strippedFrom: [] });
      continue;
    }
    if (isLiveState(z.state)) {
      items.push({
        zone: name,
        verdict: "kept-active",
        detail:
          `state='${String(z.state)}' — a live zone is never retired automatically. ` +
          `Disable it first (\`network-manager disable ${name}\`), converge, then re-run.`,
        strippedFrom: [],
      });
      kept.push(name);
      continue;
    }
    if (occupied.has(name)) {
      items.push({
        zone: name,
        verdict: "kept-occupied",
        detail:
          `still named by an installed module's zone/zone0 — retiring it would orphan a ` +
          `deployed service. Move or remove the module first.`,
        strippedFrom: [],
      });
      kept.push(name);
      continue;
    }

    // Eligible. Compute (and on apply, perform) the removal + reference strip.
    if (apply) {
      const touched = stripRefs(doc, name);
      removeZone(doc, name);
      items.push({
        zone: name,
        verdict: "retired",
        detail: `state='${String(z.state)}', no module tenants`,
        strippedFrom: touched,
      });
    } else {
      const touched = listZoneNames(doc).filter((other) => {
        if (other === name) return false;
        const z2 = getZone(doc, other);
        return (
          (Array.isArray(z2?.["access-to"]) && (z2!["access-to"] as string[]).includes(name)) ||
          (Array.isArray(z2?.["pinhole-allowed-from"]) &&
            (z2!["pinhole-allowed-from"] as string[]).includes(name))
        );
      });
      items.push({
        zone: name,
        verdict: "retired",
        detail: `state='${String(z.state)}', no module tenants`,
        strippedFrom: touched,
      });
    }
    retired.push(name);
  }

  return { items, retired, kept, changed: apply && retired.length > 0 };
}

// Persist after an applied retirement.
export function saveRetired(zonesFile: string, doc: ZonesDoc): void {
  saveZones(zonesFile, doc);
}
