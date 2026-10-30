// assess-fixture.ts — a small site in the CMDB's shape, and a stubbed AssessIO,
// for the assess, derive and validate tests. The rules are the shipped file.

import { readFileSync } from "fs";
import { join } from "path";
import { AssessIO } from "../../src/assess";
import { CmdbItem, CmdbRel, Condition } from "../../src/assess-model";
import { RulesDoc } from "../../src/rules";
import { CmdbReport } from "../../../../lib/ts/src/cmdb";
import { ConditionStatus, ConditionType, HealthRule } from "../../../../lib/ts/src/health-rules";

const CICD = process.env.HM_CICD_DIR ?? join(__dirname, "../../../../../../..");
const META = join(CICD, "controller/cmdb-controller/metamodel");

const CLASSES: Record<string, string[]> = {
  vm: ["vm", "node", "ci", "object"], lxc: ["lxc", "node", "ci", "object"], machine: ["machine", "node", "ci", "object"],
  device: ["device", "node", "ci", "object"], app: ["app", "software", "ci", "object"], service: ["service", "software", "ci", "object"],
  "storage-pool": ["storage-pool", "storage-element", "ci", "object"], datastore: ["datastore", "storage-element", "ci", "object"],
  "backup-peer": ["backup-peer", "storage-element", "ci", "object"], "vpn-peer": ["vpn-peer", "network-element", "ci", "object"],
  site: ["site", "collection", "ci", "object"], cluster: ["cluster", "collection", "ci", "object"], environment: ["environment", "collection", "ci", "object"],
  server: ["server", "asset", "resource", "object"], "network-device": ["network-device", "asset", "resource", "object"],
  appliance: ["appliance", "asset", "resource", "object"], "passive-device": ["passive-device", "asset", "resource", "object"],
  port: ["port", "resource", "object"], rack: ["rack", "place", "object"], room: ["room", "place", "object"],
};

export function shippedModel(extra: HealthRule[] = []): RulesDoc {
  const rel = JSON.parse(readFileSync(join(META, "relations.json"), "utf8")) as { relations: Record<string, { dependant?: "from" | "to" | "both"; required?: boolean }> };
  const rules = JSON.parse(readFileSync(join(META, "health-rules.json"), "utf8")) as { rules: HealthRule[] };
  return {
    rules: [...rules.rules, ...extra],
    relations: Object.entries(rel.relations).map(([name, r]) => ({ name, dependant: r.dependant ?? null, required: r.required === true })),
    ancestors: CLASSES,
  };
}

export const T0 = "2026-10-30T08:00:00.000Z";
export const NOW = new Date("2026-10-30T09:00:00.000Z");

export const obj = (cls: string, name: string, attributes: Record<string, unknown> = {}): CmdbItem => ({ id: `${cls}/${name}`, class: cls, name, attributes });

export function rel(type: string, from: CmdbItem, to: CmdbItem, attributes: Record<string, unknown> = {}): CmdbRel {
  return { type, from: { id: from.id, class: from.class, name: from.name }, to: { id: to.id, class: to.class, name: to.name }, attributes };
}

export function cond(type: ConditionType, status: ConditionStatus, reason = "broken", extra: Partial<Condition> = {}): Condition {
  return {
    type, status, reason, message: reason, since: T0, lastChecked: T0, source: "health-manager",
    derived: false, rootCause: null, acknowledged: null, maintenance: null, ...extra,
  };
}

export class StubIO implements AssessIO {
  written: CmdbReport[] = [];
  checks: AssessIO["gates"] = () => [];
  open: ReturnType<AssessIO["alerts"]>["open"] = [];
  recent: ReturnType<AssessIO["alerts"]>["recent"] = [];
  sweepRecord: ReturnType<AssessIO["sweep"]> = { time: NOW.toISOString(), counts: { expected: 0, drift: 0, desired: 0, unmanaged: 0, missing: 0, unread: 0, sourcesFailed: 0 } };
  scan: ReturnType<AssessIO["cve"]> = null;
  retired: CmdbItem[] = [];

  constructor(
    public items: CmdbItem[],
    public rels: CmdbRel[] = [],
    public model: RulesDoc = shippedModel(),
  ) {}

  objects(): CmdbItem[] { return this.items; }
  ended(): CmdbItem[] { return this.retired; }
  relations(): CmdbRel[] { return this.rels; }
  rules(): RulesDoc { return this.model; }
  sweep(): ReturnType<AssessIO["sweep"]> { return this.sweepRecord; }
  gates(): ReturnType<AssessIO["gates"]> { return this.checks(); }
  alerts(): ReturnType<AssessIO["alerts"]> { return { open: this.open, recent: this.recent }; }
  cve(): ReturnType<AssessIO["cve"]> { return this.scan; }
  write(r: CmdbReport): void {
    this.written.push(r);
    // As the store does: the next run reads what this one wrote.
    for (const o of r.objects ?? []) {
      const it = this.items.find((x) => x.id === o.id);
      if (it) Object.assign(it.attributes, o.attributes);
    }
  }
}
