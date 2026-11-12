// perfroots.ts — the root causes the Performance view lists (ADR-046 D7):
// each from its `performance` condition and that condition's own root, never
// the object's worst condition. The health document names a root by its worst
// condition (coturn's security score, say, while its performance is what
// breached); the performance overview has the performance condition's line.
// Pure, no DOM.

import type { PerfRoot } from "./perftypes";
import type { HealthRoot } from "./types";

/** The performance roots, in the overview's order, as the tree's root list
 *  shows them: the line, status, time and impact of the performance condition;
 *  the health root only for what the performance read does not carry (the
 *  environments, acknowledged, flapping). */
export function performanceRoots(perf: PerfRoot[], health: HealthRoot[]): HealthRoot[] {
  const byId = new Map(health.map((h) => [h.id, h]));
  return perf.map((p) => {
    const h = byId.get(p.id);
    return {
      id: p.id,
      class: p.class,
      name: h?.name ?? p.label,
      label: p.label,
      type: "performance",
      status: p.status,
      reason: null,
      message: p.message,
      since: p.since,
      acknowledged: h?.type === "performance" ? h.acknowledged : false,
      flapping: h?.type === "performance" ? h.flapping : false,
      impactedCount: p.impacted.length,
      impacted: p.impacted.map((i) => i.id),
      environments: h?.environments ?? [],
    };
  });
}
