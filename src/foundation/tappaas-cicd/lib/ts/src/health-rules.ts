// health-rules.ts — the condition types and statuses health speaks in, and the
// dependency-cycle check over the CMDB's relations. The rules themselves are
// health records (health-records.ts).

export const CONDITION_TYPES = ["operational", "drift", "capacity", "performance", "security", "maintenance", "backup", "impact"] as const;
export const CONDITION_STATUSES = ["ok", "warning", "critical", "unknown"] as const;
export type ConditionType = (typeof CONDITION_TYPES)[number];
export type ConditionStatus = (typeof CONDITION_STATUSES)[number];

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
