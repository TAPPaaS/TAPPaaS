// cmdb-report.ts — what environment-manager reports to the CMDB (ADR-040 D3,
// D4): every environment, its domain and update window, the organization that
// owns it (owned-by) and the zones that serve it (serves, from zones.json: the
// zone names the environment, #865). The zone and the organization are
// network-manager's and identity-manager's CIs: here they are named only.

import { join } from "path";
import { CmdbObject, CmdbRelation, CmdbReport } from "../../../lib/ts/src/cmdb";
import { compact } from "../../../lib/ts/src/cmdb-source";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { loadEnvironments, loadRefSources } from "./config";

export const SOURCE = "environment-manager";

/** site.json's update schedule, as one line: "weekly Tuesday 02:00". Every
 *  environment updates in the site's window (ADR-017; ADR-007c keeps a window
 *  of its own out of v1). */
export function updateWindow(configDir: string): string | undefined {
  const s = readJsonObject(join(configDir, "site.json"))?.updateSchedule;
  let f: unknown, d: unknown, h: unknown;
  if (Array.isArray(s)) [f, d, h] = s;
  else if (s && typeof s === "object") ({ frequency: f, weekday: d, hour: h } = s as Record<string, unknown>);
  if (typeof f !== "string" || !f) return undefined;
  if (f === "none") return "none";
  const hour = typeof h === "number" || (typeof h === "string" && /^\d+$/.test(h)) ? `${String(h).padStart(2, "0")}:00` : undefined;
  const day = f !== "daily" && typeof d === "string" ? d : undefined;
  return [f, day, hour].filter(Boolean).join(" ");
}

/** The environments (all, or the named ones) as config/ has them. */
export function environmentObservation(configDir: string, only?: string[]): CmdbReport {
  const envs = loadEnvironments(configDir).environments;
  const refs = loadRefSources(configDir);
  const window = updateWindow(configDir);
  const objects: CmdbObject[] = [];
  const relations: CmdbRelation[] = [];
  for (const env of [...envs.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    if (only && !only.includes(env.name)) continue;
    const ref = `environment/${env.name}`;
    objects.push({
      ref,
      class: "environment",
      name: env.name,
      attributes: compact({
        displayName: env.displayName || undefined,
        domain: env.domains?.primary,
        updateWindow: window,
        organization: env.ownerOrg ? { class: "organization", name: env.ownerOrg } : undefined,
        desired: { file: `environments/${env.name}.json` },
        stage: "operational",
      }),
    });
    for (const [zone, link] of [...refs.zones].sort(([a], [b]) => a.localeCompare(b))) {
      if (link.environments.includes(env.name)) relations.push({ type: "serves", from: { class: "zone", name: zone }, to: { ref } });
    }
  }
  return { source: SOURCE, kind: "observation", objects, relations };
}
