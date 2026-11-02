// cmdbsweep.ts — the `cmdb` gate (ADR-040 D15): the site's health says what the
// last discovery sweep found, by the sweep's own thresholds. It reads the
// record and runs nothing: `cmdb sweep` is the check, nightly by its timer.
//
//   pass  the last sweep found nothing but expected changes
//   warn  drift, unmanaged things, or a difference from desired
//   fail  desired without actual, a source that failed, or no sweep in 48 h

import { CmdbRefused, CmdbUnavailable, cmdbRequest } from "../../../lib/ts/src/cmdb";
import { CheckResult, CheckRow } from "./types";

export const SWEEP_MAX_AGE_MS = 48 * 3600 * 1000;

export interface SweepDifference {
  kind: string;
  class: string;
  name: string;
  attribute: string | null;
  after?: unknown;
  expected: boolean;
  reason?: "new" | "words"; // expected: it belongs to what a verb just made, or only a relation's dependency words changed
}

export interface SweepRecord {
  time: string;
  counts: { expected: number; new?: number; words?: number; drift: number; desired: number; unmanaged: number; missing: number; unread: number; sourcesFailed: number };
  sources?: { source: string; ok: boolean }[];
  differences?: SweepDifference[];
}

export const WORD: Record<string, string> = { missing: "desired without actual", unmanaged: "actual without desired", desired: "differs from desired", unread: "could not be compared" };
const MAX_ROWS = 20;

/** The gate over a record. Pure: null is no record at all. */
export function checkCmdbSweep(rec: SweepRecord | null, now: number): CheckResult {
  const name = "cmdb";
  if (!rec) return { name, status: "fail", detail: "no sweep has run — cmdb sweep" };
  const age = now - Date.parse(rec.time);
  if (!(age <= SWEEP_MAX_AGE_MS)) {
    return { name, status: "fail", detail: `the last sweep is ${Math.round(age / 3600000)} h old (${rec.time}) — is cmdb-sweep.timer running?` };
  }
  const c = rec.counts;
  const rows: CheckRow[] = [];
  for (const s of (rec.sources ?? []).filter((x) => !x.ok)) rows.push({ status: "fail", text: `source ${s.source} failed` });
  for (const d of rec.differences ?? []) {
    if (d.expected) continue;
    const word = WORD[d.kind] ?? `drift: ${d.kind}`;
    rows.push({ status: d.kind === "missing" ? "fail" : "warn", text: `${`${d.class}/${d.name}`.padEnd(28)}${word}${d.attribute ? ` ${d.attribute}` : ""}` });
  }
  rows.sort((a, b) => (a.status === b.status ? 0 : a.status === "fail" ? -1 : 1));
  const summary = `${c.drift} drift, ${c.desired} from desired, ${c.unmanaged} unmanaged, ${c.missing} missing, ${c.sourcesFailed} source(s) failed`;
  const shown = rows.slice(0, MAX_ROWS);
  if (rows.length > shown.length) shown.push({ status: "warn", text: `… and ${rows.length - shown.length} more — cmdb sweep --last` });
  if (c.missing || c.sourcesFailed) return { name, status: "fail", detail: `${summary} (${rec.time})`, rows: shown };
  if (c.drift || c.desired || c.unmanaged || c.unread) return { name, status: "warn", detail: `${summary} (${rec.time})`, rows: shown };
  return { name, status: "pass", detail: `the site is what config/ says: ${c.expected} expected change(s)${c.new ? `, ${c.new} of them new` : ""}${c.words ? `, ${c.words} relation word(s)` : ""} (${rec.time})` };
}

/** The last record from the service. Null when none has run. */
export function readLastSweep(): SweepRecord | null {
  try {
    return cmdbRequest("GET", "/v1/sweep") as SweepRecord;
  } catch (e) {
    if (e instanceof CmdbRefused && e.status === 404) return null;
    throw e;
  }
}

export function checkCmdb(now: number, read: () => SweepRecord | null = readLastSweep): CheckResult {
  try {
    return checkCmdbSweep(read(), now);
  } catch (e) {
    if (e instanceof CmdbUnavailable) return { name: "cmdb", status: "warn", detail: `the CMDB does not answer: ${e.message}` };
    throw e;
  }
}
