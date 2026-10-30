// emit-cmdb.ts — what the emitting half of health-manager reads and writes in
// the CMDB (ADR-041 D2): objects with their conditions, the periods of the
// `conditions` attribute, and a write of one object's conditions. An interface,
// so the logic runs against a stub in the tests.
//
// `conditions` is one attribute: every write replaces the array. assess carries
// `acknowledged`, `maintenance`, `flapping` and `flappingHeld` over when it
// rewrites one, and drops an ack or window that has ended; here they are read,
// changed and written back whole.

import { cmdbQuery, cmdbReport, cmdbRequest, cmdbShow, objectPath } from "../../../lib/ts/src/cmdb";
import { changeJob } from "../../../lib/ts/src/job";

const SOURCE = "health-manager";

export type Status = "ok" | "warning" | "critical" | "unknown";
const RANK: Record<Status, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

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

export interface HealthObject {
  id: string;
  class: string;
  name: string;
  attributes: { conditions?: Condition[]; rootCauses?: RootEntry[] };
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
  write(o: HealthObject, conditions: Condition[], meta: WriteMeta): void;
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

  // An assessment: the object by id, no sighting, so a write here neither holds
  // off a CI's expiry nor revives an unseen one (ADR-041 D2).
  write(o: HealthObject, conditions: Condition[], meta: WriteMeta): void {
    cmdbReport({
      source: SOURCE,
      kind: meta.kind,
      assessment: true,
      ...(meta.kind === "change" ? { verb: meta.verb, ...changeJob() } : {}),
      objects: [{ id: o.id, class: o.class, name: o.name, attributes: { conditions } }],
    });
  }
}
