// emit-cmdb.ts — what the emitting half of health-manager reads and writes in
// the CMDB (ADR-041 D2): objects with their conditions, the periods of the
// `conditions` attribute, and a write of one object's conditions. An interface,
// so the logic runs against a stub in the tests.
//
// `conditions` has one writer, assess. What the operator says (acknowledgements)
// and what emit holds while a condition flaps (flapping) are attributes of their
// own, each with one writer; assess projects both onto the conditions.

import { cmdbPeriods, cmdbQuery, cmdbReport, cmdbRequest, cmdbShow, objectPath } from "../../../lib/ts/src/cmdb";
import type { InvestigationPeriod } from "./perf";
import { changeJob } from "../../../lib/ts/src/job";
import { RANK } from "./assess-model";
import type { ConditionStatus } from "../../../lib/ts/src/health-rules";

const SOURCE = "health-manager";

// One status and one rank for every reader (assess-model.ts holds them).
export type Status = ConditionStatus;
export { RANK };

export const worse = (a: Status, b: Status): Status => (RANK[b] > RANK[a] ? b : a);

export interface Ack {
  by: string;
  note?: string;
  until?: string | null;
  sticky?: boolean;
  at?: string; // when it was set: a non-sticky ack ends at the next status change
  via?: string[]; // on a symptom: the roots whose acknowledgement silences it
}

export interface Maintenance {
  until: string;
  note?: string;
  by?: string;
}

export interface Condition {
  type: string;
  status: Status;
  reason?: string;
  message?: string;
  since?: string;
  lastChecked?: string;
  source?: string;
  derived?: boolean;
  rootCause?: string | string[] | null;
  acknowledged?: Ack | null;
  maintenance?: Maintenance | null;
  flapping?: boolean;
  flappingHeld?: Status; // the status told while it flaps
}

export interface RootEntry {
  id: string;
  type?: string;
  impactedCount?: number;
}

// The operator's last word per condition type (the ack verbs), and what emit
// holds while a condition flaps: attributes of their own, one writer each.
export interface OperatorWord { ack: Ack | null; at: string }
export type Flaps = Record<string, { held: Status }>;

export interface HealthObject {
  id: string;
  class: string;
  name: string;
  attributes: { conditions?: Condition[]; rootCauses?: RootEntry[]; acknowledgements?: Record<string, OperatorWord>; flapping?: Flaps };
}

/** One period of the `conditions` attribute, from the CMDB's history. */
export interface Period {
  name: string;
  value: unknown;
  change: number | string;
  from: string;
  to: string | null;
}

export interface WriteMeta {
  kind: "observation" | "change";
  verb?: string;
}

export interface HealthCmdb {
  objects(at?: string): HealthObject[];
  objectsOfClass(cls: string): HealthObject[]; // subclasses too
  resolve(ref: string): HealthObject;
  periods(id: string): Period[];
  /** Every period of the `investigation` attribute since a time; null when the CMDB has no such read. */
  investigations?(since: string): InvestigationPeriod[] | null;
  /** Writes the named attributes of one object (never `conditions`: assess alone writes those). */
  write(o: HealthObject, attributes: Partial<Pick<HealthObject["attributes"], "acknowledgements" | "flapping">>, meta: WriteMeta): void;
}

export const conditionsOf = (o: HealthObject): Condition[] => (Array.isArray(o.attributes.conditions) ? o.attributes.conditions : []);

export const rootsOfSite = (objects: HealthObject[]): RootEntry[] => {
  const r = objects.find((o) => o.class === "site")?.attributes.rootCauses;
  return Array.isArray(r) ? r : [];
};

export const rootsOf = (c: Condition | undefined): string[] => {
  const r = c?.rootCause;
  return Array.isArray(r) ? r : r ? [r] : [];
};

/** `<class>/<name>` or a plain id or name. */
export function splitRef(ref: string): { ref: string; class?: string } {
  const slash = ref.indexOf("/");
  return slash > 0 ? { ref: ref.slice(slash + 1), class: ref.slice(0, slash) } : { ref };
}

export class LiveHealthCmdb implements HealthCmdb {
  objects(at?: string): HealthObject[] {
    return cmdbQuery({ class: "object", limit: 100000, ...(at ? { at } : {}) }) as unknown as HealthObject[];
  }

  objectsOfClass(cls: string): HealthObject[] {
    return cmdbQuery({ class: cls, limit: 100000 }) as unknown as HealthObject[];
  }

  resolve(ref: string): HealthObject {
    const r = splitRef(ref);
    const s = cmdbShow(r.ref, r.class ? { class: r.class } : {});
    const attrs = (s.attributes ?? {}) as Record<string, { value: unknown }>;
    return {
      id: String(s.id),
      class: String(s.class),
      name: String(s.name),
      attributes: Object.fromEntries(Object.entries(attrs).map(([k, v]) => [k, v.value])) as HealthObject["attributes"],
    };
  }

  periods(id: string): Period[] {
    const h = cmdbRequest("GET", objectPath(id, "history", {})) as { attributes: Period[] };
    return h.attributes.filter((a) => a.name === "conditions");
  }

  // A controller without the periods route (404) has no record to read back.
  investigations(since: string): InvestigationPeriod[] | null {
    try {
      return cmdbPeriods("investigation", since) as InvestigationPeriod[];
    } catch {
      return null;
    }
  }

  // An assessment: the object by id, no sighting, so a write here neither holds
  // off a CI's expiry nor revives an unseen one (ADR-041 D2).
  write(o: HealthObject, attributes: Partial<Pick<HealthObject["attributes"], "acknowledgements" | "flapping">>, meta: WriteMeta): void {
    cmdbReport({
      source: SOURCE,
      kind: meta.kind,
      assessment: true,
      ...(meta.kind === "change" ? { verb: meta.verb, ...changeJob() } : {}),
      objects: [{ id: o.id, class: o.class, name: o.name, attributes }],
    });
  }
}
