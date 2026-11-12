// baseline-ci.ts — the NixOS baseline as a CI of its own.
//
// Every NixOS module is built from the same baseline packages, and a CVE level
// only those packages set is one cause, not one per module. The baseline is a
// `nixos-baseline` CI, reported by health-manager's `report` (which the CMDB
// sweep runs) from the component records' templates/* components; the cve
// source puts the baseline's own finding on it (assess-sources.ts fromCve).

import { CmdbBatch } from "../../../lib/ts/src/cmdb-reporter";
import { ComponentRecord } from "../../../lib/ts/src/cve-decisions";

export const BASELINE_CLASS = "nixos-baseline";
export const BASELINE_NAME = "nixos-baseline";
export const BASELINE_PREFIX = "templates/";

/** The baseline's component keys, sorted: the records under templates/. */
export function baselineComponents(records: Record<string, ComponentRecord>): string[] {
  return Object.keys(records).filter((k) => k.startsWith(BASELINE_PREFIX)).sort();
}

/** The report that keeps the CI: one object, or nothing when no record is the baseline's. */
export function buildBaselineReport(records: Record<string, ComponentRecord>, source = "health-manager"): CmdbBatch {
  const b = new CmdbBatch(source);
  const components = baselineComponents(records);
  if (components.length) b.put(BASELINE_CLASS, BASELINE_NAME, { components });
  return b;
}
