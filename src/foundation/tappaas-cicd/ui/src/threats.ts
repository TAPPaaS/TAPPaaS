// threats.ts — the Security page's Threats tab (ADR-050 P4): read-only, from
// the threat conditions health-manager wrote on the CIs. The open findings,
// critical first, then the latest hit; each with its hits, the hold left, the
// CVE state of the same object beside it (a hit on something with an open CVE
// stands out); and the acknowledgements of the last 30 days with their reason.
// Pure: the health document in, the view out.

import { AckWord, HealthGraph, Hits, Status } from "./health";

const RANK: Record<Status, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };
const ACK_DAYS = 30;
const ACKS_SHOWN = 20;

export interface ThreatRow {
  id: string;
  class: string;
  name: string;
  label: string;
  module: string | null;
  environment: string | null;
  status: Status;
  reason: string | null;
  message: string | null;
  since: string | null;
  hits?: Hits;
  heldUntil?: string;
  heldBy?: string;
  acknowledged: boolean;
  maintenance: boolean;
  // The same object's vulnerability: its CVE level, and whether one is open.
  cve: { status: Status; reason: string | null; message: string | null; open: boolean } | null;
}

export interface ThreatAck extends AckWord {
  id: string;
  class: string;
  label: string;
}

export interface ThreatsView {
  generated: string | null;
  hasConditions: boolean;
  counts: { critical: number; warning: number; silenced: number };
  open: ThreatRow[]; // not silenced
  silenced: ThreatRow[]; // acknowledged, in a window, or quiet
  acks: ThreatAck[]; // the last 30 days, newest first
}

const lastHit = (r: ThreatRow): number => Date.parse(r.hits?.last ?? r.since ?? "") || 0;

export function threatsView(doc: HealthGraph | null, now: number): ThreatsView {
  const rows: ThreatRow[] = [];
  const acks: ThreatAck[] = [];
  for (const n of doc?.nodes ?? []) {
    const vuln = n.issues.find((i) => i.type === "vulnerability");
    const cve = n.types.vulnerability !== undefined
      ? { status: vuln?.status ?? n.types.vulnerability, reason: vuln?.reason ?? null, message: vuln?.message ?? null, open: (vuln?.status ?? n.types.vulnerability) === "warning" || (vuln?.status ?? n.types.vulnerability) === "critical" }
      : null;
    for (const i of n.issues) {
      if (i.type !== "threat" || (i.status !== "warning" && i.status !== "critical")) continue;
      rows.push({
        id: n.id, class: n.class, name: n.name, label: n.label, module: n.module, environment: n.environment,
        status: i.status, reason: i.reason, message: i.message, since: i.since,
        ...(i.hits ? { hits: i.hits } : {}), ...(i.heldUntil ? { heldUntil: i.heldUntil } : {}), ...(i.heldBy ? { heldBy: i.heldBy } : {}),
        acknowledged: i.acknowledged, maintenance: i.maintenance, cve,
      });
    }
    const a = n.acks?.threat;
    if (a && now - (Date.parse(a.at) || 0) <= ACK_DAYS * 86_400_000) acks.push({ ...a, id: n.id, class: n.class, label: n.label });
  }
  rows.sort((a, b) => RANK[b.status] - RANK[a.status] || Number(b.cve?.open ?? false) - Number(a.cve?.open ?? false) || lastHit(b) - lastHit(a) || a.label.localeCompare(b.label));
  acks.sort((a, b) => (Date.parse(b.at) || 0) - (Date.parse(a.at) || 0));
  const silenced = (r: ThreatRow): boolean => r.acknowledged || (r.maintenance && r.status !== "critical");
  const open = rows.filter((r) => !silenced(r));
  return {
    generated: doc?.generated ?? null,
    hasConditions: doc?.hasConditions ?? false,
    counts: { critical: open.filter((r) => r.status === "critical").length, warning: open.filter((r) => r.status === "warning").length, silenced: rows.length - open.length },
    open,
    silenced: rows.filter(silenced),
    acks: acks.slice(0, ACKS_SHOWN),
  };
}
