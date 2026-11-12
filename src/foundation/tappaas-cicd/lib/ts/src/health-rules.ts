// health-rules.ts — the condition types and statuses health speaks in, and the
// dependency-cycle check over the CMDB's relations. The rules themselves are
// health records (health-records.ts).

export const CONDITION_TYPES = ["operational", "drift", "capacity", "performance", "backup", "upkeep", "vulnerability", "threat", "impact"] as const;
export const CONDITION_STATUSES = ["ok", "warning", "critical", "unknown"] as const;
export type ConditionType = (typeof CONDITION_TYPES)[number];
export type ConditionStatus = (typeof CONDITION_STATUSES)[number];

// ── the types before the split ──────────────────────────────────────
// `maintenance` became `upkeep` (a maintenance window is not a condition type),
// and `security` split into `vulnerability` (the supply chain: CVEs, the scan,
// signatures, control-plane trust, the NixOS baseline) and `threat` (what
// happens on a running system: the SIEM's hits, a system not built from the
// repository, an alert that says something is exposed). Certificate expiry
// moved to upkeep, an unescrowed backup key to backup. A stored condition, an
// ack and a site's rule edit written before are read through these.
export const LEGACY_TYPES = ["security", "maintenance"] as const;
export const isConditionType = (t: unknown): t is ConditionType => typeof t === "string" && (CONDITION_TYPES as readonly string[]).includes(t);

const THREAT_REASON = /^(siem-|alert-)|^system-not-built$/;
const THREAT_SOURCES = new Set(["siem", "alerts", "guest-system"]);
const VULN_SOURCES = new Set(["cve", "signature-status", "control-plane-trust"]);

/** What a type, as written before the split, is now, given the condition's
 *  reason and its source (owner). A current type is returned as it is; an
 *  unknown one is null. */
export function currentType(type: string, reason?: string | null, source?: string | null): ConditionType | null {
  if (isConditionType(type)) return type;
  if (type === "maintenance") return reason === "backup-key-not-escrowed" ? "backup" : "upkeep";
  if (type !== "security") return null;
  if (reason === "certificate-expiry") return "upkeep";
  if ((reason && THREAT_REASON.test(reason)) || (source && THREAT_SOURCES.has(source))) return "threat";
  return "vulnerability";
}

/** The types a match on a type written before the split now reads: a reason or
 *  source that decides it gives one; otherwise every type it split into, so a
 *  site's rule keeps matching what it matched. */
export function currentTypesOf(type: string, hint: { reasons?: string[]; source?: string[] } = {}): ConditionType[] {
  if (isConditionType(type)) return [type];
  const reasons = hint.reasons?.length ? hint.reasons : null;
  const sources = hint.source?.length ? hint.source : null;
  if (reasons) return [...new Set(reasons.map((r) => currentType(type, r)!))];
  if (sources && sources.every((s) => THREAT_SOURCES.has(s) || VULN_SOURCES.has(s))) return [...new Set(sources.map((s) => currentType(type, null, s)!))];
  if (type === "maintenance") return ["upkeep"];
  if (type === "security") return ["vulnerability", "threat"];
  return [];
}

/** A relation as the cycle check reads it: its type, its ends and its words. */
export interface CycleRelation {
  type: string;
  from: { id: string; class?: string; name?: string };
  to: { id: string; class?: string; name?: string };
  attributes?: Record<string, unknown> | null;
}

/** The dependency cycles over required relations: each a set of objects that
 *  reach each other from provider to dependant. A relation with two dependant
 *  ends (a cable) is left out: it reaches back by itself. Each cycle once, its
 *  ids sorted; the cycles sorted by their first id. */
export function dependencyCycles(relations: CycleRelation[], meta: { name: string; dependant: string | null; required: boolean }[]): string[][] {
  const kinds = new Map(meta.map((m) => [m.name, m]));
  const next = new Map<string, Set<string>>();
  for (const r of relations) {
    const m = kinds.get(r.type);
    if (!m || (m.dependant !== "from" && m.dependant !== "to")) continue;
    const a = r.attributes ?? {};
    if (!(typeof a.required === "boolean" ? a.required : m.required)) continue;
    const [prov, dep] = m.dependant === "from" ? [r.to.id, r.from.id] : [r.from.id, r.to.id];
    next.set(prov, (next.get(prov) ?? new Set()).add(dep));
  }
  // Tarjan's strongly connected components, without recursion.
  const index = new Map<string, number>();
  const low = new Map<string, number>();
  const stack: string[] = [];
  const onStack = new Set<string>();
  const out: string[][] = [];
  let n = 0;
  for (const root of next.keys()) {
    if (index.has(root)) continue;
    const work: { v: string; it: Iterator<string> }[] = [];
    const open = (v: string): void => {
      index.set(v, n);
      low.set(v, n++);
      stack.push(v);
      onStack.add(v);
      work.push({ v, it: (next.get(v) ?? new Set<string>()).values() });
    };
    open(root);
    while (work.length) {
      const top = work[work.length - 1];
      const step = top.it.next();
      if (!step.done) {
        const w = step.value;
        if (!index.has(w)) open(w);
        else if (onStack.has(w)) low.set(top.v, Math.min(low.get(top.v)!, index.get(w)!));
        continue;
      }
      work.pop();
      if (work.length) low.set(work[work.length - 1].v, Math.min(low.get(work[work.length - 1].v)!, low.get(top.v)!));
      if (low.get(top.v) === index.get(top.v)) {
        const scc: string[] = [];
        for (let w = stack.pop()!; ; w = stack.pop()!) {
          onStack.delete(w);
          scc.push(w);
          if (w === top.v) break;
        }
        if (scc.length > 1 || next.get(top.v)?.has(top.v)) out.push(scc.sort());
      }
    }
  }
  return out.sort((x, y) => x[0].localeCompare(y[0]));
}
