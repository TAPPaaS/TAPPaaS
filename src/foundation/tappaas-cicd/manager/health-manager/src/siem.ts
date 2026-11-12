// siem.ts — security findings that are events (ADR-050 D12).
//
// An alert whose rule says `security` (ADR-039, labels type=security and
// level=info|warning|critical) is a hit, not a state: a brute force ends, a
// file changed once. The alert receiver folds every such hit into one entry
// per rule and CI (first, last, count) in its state file; this source turns
// each entry into a `security` finding that *holds* its condition:
//
//   info      no condition (the line stays in Loki)
//   warning   held for 24 h from the last hit, then over
//   critical  held until acknowledged: an ack of the CI's security condition
//             made after the last hit ends it; a new hit opens it again
//
// A classify record may re-rate a finding and set its `hold` ("12h", "7d",
// "until-ack"); without one the hold is the default for its status. The hold is
// decided here, by the source, because a record never makes a failure ok.

import { existsSync, readFileSync } from "fs";
import { CmdbItem, SiteIndex } from "./assess-model";
import { Finding } from "./assess-sources";
import { CheckSubject } from "./types";
import { durationMs } from "../../../lib/ts/src/health-records";
import { ConditionStatus } from "../../../lib/ts/src/health-rules";

export const SIEM_STATE = process.env.TAPPAAS_SIEM_STATE ?? "/var/lib/tappaas/siem-findings.json";
export const SIEM_OWNER = "siem";
export const DEFAULT_HOLD: Record<"warning" | "critical", string> = { warning: "24h", critical: "until-ack" };
// An entry older than this is no longer read, whatever its hold: the receiver
// prunes it too.
export const SIEM_MAX_AGE_MS = 90 * 86_400_000;

export type SiemLevel = "info" | "warning" | "critical";
export interface SiemEntry {
  alertname: string;
  host: string;
  module: string;
  ci?: string; // the CI id label the line carried, when it carried one
  level: SiemLevel;
  labels: Record<string, string>; // the last hit's own labels (what it captured)
  first: string;
  last: string;
  count: number;
}
export interface SiemItem extends SiemEntry { subject: CheckSubject | null }

const LEVELS: SiemLevel[] = ["info", "warning", "critical"];
const kebab = (s: string): string => s.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();

/** The receiver's state file, placed by `place` (alerts.ts's placeAlert). null
 *  when it cannot be read: the source has not looked. A missing file is no hit. */
export function readSiem(path: string, place: (host: string, module: string) => CheckSubject | null): SiemItem[] | null {
  if (!existsSync(path)) return [];
  let doc: { findings?: Record<string, Partial<SiemEntry>> };
  try {
    doc = JSON.parse(readFileSync(path, "utf8")) as typeof doc;
  } catch {
    return null;
  }
  const out: SiemItem[] = [];
  for (const e of Object.values(doc.findings ?? {})) {
    if (!e || typeof e.alertname !== "string" || !e.alertname || typeof e.last !== "string") continue;
    const level: SiemLevel = LEVELS.includes(e.level as SiemLevel) ? (e.level as SiemLevel) : "warning";
    const entry: SiemEntry = {
      alertname: e.alertname,
      host: String(e.host ?? ""),
      module: String(e.module ?? ""),
      ...(e.ci ? { ci: String(e.ci) } : {}),
      level,
      labels: (e.labels ?? {}) as Record<string, string>,
      first: String(e.first ?? e.last),
      last: e.last,
      count: Number(e.count ?? 1) || 1,
    };
    out.push({ ...entry, subject: place(entry.host, entry.module) });
  }
  return out;
}

/** When the operator last acknowledged the object's security condition, in ms;
 *  null without a live ack. */
export function securityAckAt(o: CmdbItem): number | null {
  const words = (o.attributes.acknowledgements ?? {}) as Record<string, { ack: unknown; at: string } | undefined>;
  const w = words.security;
  if (!w || !w.ack) return null;
  const t = Date.parse(w.at);
  return Number.isNaN(t) ? null : t;
}

/** Is a finding with this hold and this last hit still held? */
export function held(hold: string, lastMs: number, nowMs: number, ackAt: number | null): boolean {
  if (hold === "until-ack") return ackAt === null || ackAt < lastMs;
  const d = durationMs(hold);
  return Number.isFinite(d) && nowMs - lastMs <= d;
}

/** One finding per entry: held at its status, or ok once its hold is over.
 *  `rate` applies the classify records to a finding (classify.ts) and returns
 *  what it became, with the record's hold if it gave one. */
export function fromSiem(items: SiemItem[], idx: SiteIndex, nowMs: number, rate: (f: Finding) => Finding & { hold?: string; quieted?: string }): Finding[] {
  const out: Finding[] = [];
  for (const e of [...items].sort((a, b) => a.alertname.localeCompare(b.alertname) || a.host.localeCompare(b.host))) {
    if (e.level === "info") continue;
    const lastMs = Date.parse(e.last);
    if (Number.isNaN(lastMs) || nowMs - lastMs > SIEM_MAX_AGE_MS) continue;
    const o = (e.ci ? idx.byId.get(e.ci) : undefined) ?? (e.subject ? idx.resolve(e.subject) : null) ?? idx.site;
    if (!o) continue;
    const hits = e.count === 1 ? "1 hit" : `${e.count} hits`;
    const extra = Object.entries(e.labels).filter(([k]) => k !== "type" && k !== "level").map(([k, v]) => `${k} ${v}`).join(", ");
    const base: Finding = {
      object: o.id,
      type: "security",
      status: e.level as ConditionStatus,
      reason: `siem-${kebab(e.alertname)}`,
      message: `${e.alertname}${e.host ? ` on ${e.host}` : ""}: ${hits}, first ${e.first}, last ${e.last}${extra ? ` (${extra})` : ""}`,
      owner: SIEM_OWNER,
      labels: { ...e.labels, alertname: e.alertname, level: e.level, count: String(e.count), first: e.first, last: e.last },
    };
    const r = rate(base);
    const status = r.status === "critical" || r.status === "warning" ? r.status : null;
    const hold = r.hold ?? (status ? DEFAULT_HOLD[status] : DEFAULT_HOLD.warning);
    const still = held(hold, lastMs, nowMs, securityAckAt(o));
    out.push(still ? base : { ...base, status: "ok", reason: "ok", message: "" });
  }
  return out;
}
