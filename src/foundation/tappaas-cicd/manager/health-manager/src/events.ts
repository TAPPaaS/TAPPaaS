// events.ts — the health events (ADR-041 D4): the shape of each, and the
// journal line that carries it.
//
// One JSON object per line, identifier tappaas-health, so Loki holds them and
// ADR-039's rules match them. Keys keep the order they are built in: the rule
// file's `match` reads `"kind":"causal"` before `"silenced":false`.

import { spawnGuarded } from "../../../lib/ts/src/exec";
import { Status } from "./emit-cmdb";

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

export interface RootCauseEvent {
  event: "rootcause";
  ci: string;
  class: string;
  name: string;
  type: string;
  symptoms: string[];
  impacted: string; // the symptoms by class, "3 vm, 2 service"
  cleared: boolean;
  at: string;
}

export type HealthEvent = TransitionEvent | AckEvent | MaintenanceEvent | RootCauseEvent;

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
