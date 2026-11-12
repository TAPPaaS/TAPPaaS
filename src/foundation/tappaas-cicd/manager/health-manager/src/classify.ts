// classify.ts — what a source's finding becomes (the `classify` records):
// the condition type, status and reason, whether it is a sum of others
// (aggregate: derived, never a root), and whether it is heard (quiet).
//
// Only a failing finding is classified: a record never makes a failure ok or
// unknown, and never touches an ok. A re-rated finding keeps what its source
// said beside it (`raw`): its status and the record, and on the condition when
// the source's status last changed, which is what `finding.age` reads, so an
// age-based raise does not reset its own clock. A quieted finding is kept, with
// the status its source gave it, and silenced.

import { CmdbItem, Condition, failing } from "./assess-model";
import { Finding } from "./assess-sources";
import { Ancestors, Candidate, Classify, HealthRecord, flatten, matches, pick } from "../../../lib/ts/src/health-records";
import { ConditionType } from "../../../lib/ts/src/health-rules";

/** The source's own word on a re-rated condition. */
export interface Raw { status: Condition["status"]; since: string; rule: string }
/** The record that quieted a condition, and since when. */
export interface Quieted { rule: string; since: string; via?: string[] }

/** A finding after classify: what records made of it. */
export type Classified = Finding & { raw?: { status: Condition["status"]; rule: string }; quieted?: string; aggregate?: true };

/** How long the source has said this status: from the condition as stored. */
function ageOf(f: Finding, prior: Condition | undefined, nowMs: number): number {
  if (!prior || prior.type !== f.type) return 0;
  const raw = (prior as Condition & { raw?: Raw }).raw;
  const said = raw ? raw.status : prior.status;
  const since = raw ? raw.since : prior.since;
  return said === f.status && since ? Math.max(0, nowMs - Date.parse(since)) : 0;
}

/** Apply the classify records to each failing finding. `priorOf` gives an
 *  object's stored conditions (for age). Conflicts are reported in `conflicts`. */
export function classify(findings: Finding[], byId: Map<string, CmdbItem>, records: HealthRecord[], anc: Ancestors, priorOf: (id: string) => Condition[], nowMs: number, conflicts?: Set<string>): Classified[] {
  const cands: Candidate<Classify>[] = records.filter((r): r is Classify => r.kind === "classify" && r.enabled !== false).map((rec) => ({ rec, flat: flatten(rec) }));
  if (!cands.length) return findings;
  return findings.map((f) => {
    if (!failing(f)) return f;
    const o = byId.get(f.object);
    const prior = priorOf(f.object).find((c) => c.type === f.type || ((c as Condition & { raw?: Raw }).raw && c.owner === f.owner && c.reason === f.reason));
    const ctx = (k: string): unknown => {
      if (k === "finding.source") return f.owner;
      if (k === "finding.type") return f.type;
      if (k === "finding.status") return f.status;
      if (k === "finding.reason") return f.reason;
      if (k === "finding.age") return ageOf(f, prior, nowMs);
      if (k.startsWith("finding.labels.")) return f.labels?.[k.slice(15)];
      if (!o || !k.startsWith("object.")) return undefined;
      const p = k.slice(7);
      if (p === "class") return o.class;
      if (p === "name") return o.name;
      if (p === "id") return o.id;
      if (p === "module" || p === "zone" || p === "environment") return o.attributes[p];
      if (p.startsWith("attr.")) return o.attributes[p.slice(5)];
      return undefined;
    };
    const picked = pick(cands.filter((c) => matches(c.flat, ctx, anc)), anc);
    if (picked.conflict.length) conflicts?.add(picked.conflict.map((c) => c.id).sort().join(" ~ "));
    const w = picked.winner;
    if (!w) return f;
    const out: Classified = { ...f };
    if (w.set?.type) out.type = w.set.type as ConditionType;
    if (w.set?.reason) out.reason = w.set.reason;
    if (w.set?.status && w.set.status !== f.status) {
      out.status = w.set.status;
      out.raw = { status: f.status, rule: w.id };
    }
    if (w.quiet) out.quieted = w.id;
    if (w.aggregate) out.aggregate = true;
    return out;
  });
}
