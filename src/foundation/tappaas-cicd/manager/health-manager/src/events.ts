// events.ts — the health events (ADR-041 D4): the shape of each, and the
// journal line that carries it.
//
// One JSON object per line, identifier tappaas-health, so Loki holds them and
// ADR-039's rules match them. Keys keep the order they are built in: the rule
// file's `match` reads `"kind":"causal"` before `"silenced":false`.

import { spawnGuarded } from "../../../lib/ts/src/exec";
import { Status } from "./emit-cmdb";
import type { NoticeEvent } from "./notices";

export const IDENTIFIER = "tappaas-health";

export type EventKind = "causal" | "symptom" | "recovery";

/** A condition's status changed; or, with phase, a flapping start or end. */
export interface TransitionEvent {
  event: "transition" | "flapping";
  id: string;
  ci: string;
  class: string;
  name: string;
  type: string;
  from: Status;
  to: Status;
  reason: string;
  message: string;
  kind: EventKind;
  rootCause: string | null;
  correlated: string[];
  since: string;
  at: string;
  flapping: boolean;
  phase?: "start" | "end";
  root: boolean; // the object is a root cause: a recovery alone cannot say so
  symptoms: number; // on a root: what it impacts
  impacted: string; // on a root: what it impacts by class, "3 vm, 2 service"; else "nothing"
  silenced: boolean; // acknowledged or in maintenance: recorded, never mailed
  cause?: "rules"; // the health rules changed: not a health change, not counted toward flapping
  rules?: string[]; // the rules that changed, with cause "rules"
  levelUp?: true; // a module's CVE risk level rose to high or critical (cve-level-up mails it)
  digestOnly?: true; // a performance condition: told in the daily digest, never mailed on its own
}

// The CVE risk level a vulnerability condition's reason names (ADR-045 D4): 0 for
// any other reason (ok, low, or another source's), 2–4 for medium to critical.
export const CVE_LEVEL_RANK: Record<string, number> = { "cve-medium": 2, "cve-high": 3, "cve-critical": 4 };
export const cveLevelRank = (reason: string | undefined): number => CVE_LEVEL_RANK[reason ?? ""] ?? 0;

/** A vulnerability condition whose level changed while its status did not
 *  (medium to high: both warning) is a transition all the same. */
export function levelChanged(type: string, before: { reason?: string } | undefined, after: { reason?: string } | undefined): boolean {
  if (type !== "vulnerability" || !before || !after || before.reason === after.reason) return false;
  return cveLevelRank(before.reason) > 0 || cveLevelRank(after.reason) > 0;
}

// The objects whose level is their own score's, not a module's: they never
// raise cve-level-up (the module that set it did).
const NOT_A_MODULE = new Set(["zone", "environment", "site"]);

/** Did a module's (or a node's) level rise to high or critical? */
export function levelRose(cls: string, type: string, before: { reason?: string } | undefined, after: { reason?: string } | undefined): boolean {
  if (type !== "vulnerability" || NOT_A_MODULE.has(cls)) return false;
  const to = cveLevelRank(after?.reason);
  return to >= 3 && to > cveLevelRank(before?.reason);
}

export interface AckEvent {
  event: "ack" | "unack";
  ci: string;
  class: string;
  name: string;
  type: string;
  by: string;
  note: string;
  sticky: boolean;
  until: string | null;
  why?: "operator" | "expired" | "recovered" | "changed";
  symptoms: string[];
  at: string;
}

export interface MaintenanceEvent {
  event: "maintenance";
  phase: "start" | "end" | "cancel";
  ci: string;
  class: string;
  name: string;
  by: string;
  note: string;
  until: string | null;
  why?: "operator" | "expired";
  at: string;
}

export type HealthEvent = TransitionEvent | AckEvent | MaintenanceEvent | NoticeEvent;

export type Journal = (lines: string[]) => void;

export const eventLine = (e: HealthEvent): string => JSON.stringify(e);

/** The journal, as cmdb-sweep writes it. Without one the lines go to stderr. */
export const systemJournal: Journal = (lines) => {
  if (!lines.length) return;
  const r = spawnGuarded("systemd-cat", ["-t", IDENTIFIER], { input: lines.join("\n") + "\n", encoding: "utf8" });
  if (r.error || r.status !== 0) {
    process.stderr.write(`[Warning] no journal (${r.error?.message ?? `exit ${String(r.status)}`}); the events follow\n${lines.join("\n")}\n`);
  }
};
