// assess-model.ts — what `assess` and the readers of its result share (ADR-041
// D1): a condition as stored, the CMDB's objects and relations as it reads them,
// and how an object is found from a gate's subject.

import { CheckSubject } from "./types";
import { ConditionStatus, ConditionType } from "../../../lib/ts/src/health-rules";

export interface Acknowledged { by: string; note: string; until: string | null; sticky: boolean; at?: string; via?: string[] }
export interface Maintenance { until: string | null; note: string; by?: string }

export interface Condition {
  type: ConditionType;
  status: ConditionStatus;
  reason: string;
  message: string;
  since: string;
  lastChecked: string;
  source: string;
  derived: boolean;
  rootCause: string | null;
  acknowledged: Acknowledged | null;
  maintenance: Maintenance | null;
  flapping?: unknown; // emit's, carried over as they are
  flappingHeld?: unknown;
}

export interface CmdbItem {
  id: string;
  class: string;
  name: string;
  attributes: Record<string, unknown>;
}

export interface CmdbEnd { id: string; class: string; name: string }

export interface CmdbRel {
  type: string;
  from: CmdbEnd;
  to: CmdbEnd;
  attributes?: Record<string, unknown> | null;
}

export interface RootCause { id: string; type: string; impactedCount: number }

export const SOURCE = "health-manager";

// The order a colour is read in: unknown ranks between ok and warning (D1).
export const RANK: Record<ConditionStatus, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

export const failing = (c: { status: ConditionStatus }): boolean => c.status === "critical" || c.status === "warning";

export const conditionsOf = (o: CmdbItem): Condition[] => (Array.isArray(o.attributes.conditions) ? (o.attributes.conditions as Condition[]) : []);

const running = (w: { until: string | null } | null, now: number): boolean => w !== null && (!w.until || Date.parse(w.until) > now);

/** Silenced by an operator: an acknowledgement or a maintenance window that holds. */
export const silenced = (c: Condition, now: number): boolean => running(c.acknowledged, now) || running(c.maintenance, now);

/** What fails `validate` (D2): critical, neither derived, acknowledged nor in maintenance. */
export const counts = (c: Condition, now: number): boolean => c.status === "critical" && !c.derived && !silenced(c, now);

// A module is the node of its kind, or an app (ADR-040 D3).
const MODULE_CLASSES = ["vm", "lxc", "machine", "device", "app"];

/** Finds the object a gate's subject means. Only what the CMDB has: null when it does not. */
export class SiteIndex {
  readonly byId = new Map<string, CmdbItem>();
  private readonly byName = new Map<string, CmdbItem[]>();
  readonly site: CmdbItem | null;

  constructor(
    readonly objects: CmdbItem[],
    readonly relations: CmdbRel[],
  ) {
    for (const o of objects) {
      this.byId.set(o.id, o);
      this.byName.set(o.name, [...(this.byName.get(o.name) ?? []), o]);
    }
    this.site = objects.find((o) => o.class === "site") ?? null;
  }

  named(name: string, classes: string[]): CmdbItem | null {
    const hits = this.byName.get(name) ?? [];
    for (const c of classes) {
      const o = hits.find((x) => x.class === c);
      if (o) return o;
    }
    return null;
  }

  // The one object of `cls` by that name related to `other` by `type`.
  private on(cls: string, name: string, type: string, other: string): CmdbItem | null {
    const r = this.relations.find((x) => x.type === type && x.from.class === cls && x.from.name === name && x.to.id === other);
    return r ? this.byId.get(r.from.id) ?? null : null;
  }

  resolve(s: CheckSubject): CmdbItem | null {
    switch (s.kind) {
      case "module":
        return this.named(s.name, MODULE_CLASSES);
      case "node":
        return this.named(s.name, ["machine"]);
      case "disk":
        return this.named(s.name.split(":")[0], ["machine"]);
      case "switch":
        return this.named(s.name, ["device"]);
      case "peer":
        return this.named(s.name, ["backup-peer"]);
      case "site":
        return s.name === "quorum" ? this.objects.find((o) => o.class === "cluster") ?? this.site : this.site;
      case "pool": {
        const slash = s.name.indexOf("/");
        const node = this.named(s.name.slice(0, slash), ["machine"]);
        return node ? this.on("storage-pool", s.name.slice(slash + 1), "runs-on", node.id) : null;
      }
      case "port": {
        // <switch>:<port>: the switch is a device, its ports hang off its asset.
        const colon = s.name.lastIndexOf(":");
        const dev = this.named(s.name.slice(0, colon), ["device"]);
        if (!dev) return null;
        const asset = this.relations.find((r) => r.type === "allocated-to" && r.to.id === dev.id);
        const port = asset ? this.relations.find((r) => r.type === "part-of" && r.to.id === asset.from.id && r.from.name === s.name.slice(colon + 1)) : undefined;
        return (port && this.byId.get(port.from.id)) ?? dev;
      }
      default:
        return null;
    }
  }
}
