// sectionview.ts — how a section's values read (the backend gives the raw
// value and its format). Pure, so the unit tests read the same text.

import { bytes } from "./physical/storage";
import { SectionFormat, SectionGauge } from "./types";

export function valueText(v: unknown, format?: SectionFormat): string {
  if (v === null || v === undefined || v === "") return "—";
  if (typeof v === "number" && format === "bytes") return bytes(v);
  if (typeof v === "number" && format === "mib") return bytes(v * 1024 * 1024);
  if (typeof v === "number" && format === "percent") return `${v.toFixed(0)}%`;
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (typeof v === "string" || typeof v === "number") return String(v);
  return JSON.stringify(v);
}

export function gaugePct(g: SectionGauge): number {
  return g.max > 0 ? Math.min(100, (g.value / g.max) * 100) : 0;
}

// Its own level, or by how full it is: the storage-pools gate's 80 and 90.
export function gaugeLevel(g: SectionGauge): "pass" | "warn" | "fail" | "skip" {
  if (g.level) return g.level;
  const pct = gaugePct(g);
  return pct >= 90 ? "fail" : pct >= 80 ? "warn" : "pass";
}
