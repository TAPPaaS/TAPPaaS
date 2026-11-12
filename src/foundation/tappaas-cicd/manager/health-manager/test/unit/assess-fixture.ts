// assess-fixture.ts — a small site in the CMDB's shape, and a stubbed AssessIO,
// for the assess, derive and validate tests. The rules are the shipped file.

import { readFileSync, readdirSync } from "fs";
import { join } from "path";
import { AssessIO } from "../../src/assess";
import { CmdbItem, CmdbRel, Condition } from "../../src/assess-model";
import { RulesDoc } from "../../src/rules";
import { CmdbReport } from "../../../../lib/ts/src/cmdb";
import { ConditionStatus, ConditionType } from "../../../../lib/ts/src/health-rules";
import { HealthRecord, Propagate } from "../../../../lib/ts/src/health-records";
import { HealthRule } from "./oracle/derive-p0";

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
  zone: ["zone", "network-element", "ci", "object"],
  port: ["port", "resource", "object"], disk: ["disk", "resource", "object"], rack: ["rack", "place", "object"], room: ["room", "place", "object"],
};

/** The core records as released: metamodel/health/*.json. */
export function coreRecords(): HealthRecord[] {
  const dir = join(META, "health");
  return readdirSync(dir).filter((f) => f.endsWith(".json")).sort().flatMap((f) => (JSON.parse(readFileSync(join(dir, f), "utf8")) as { records: HealthRecord[] }).records);
}

export function shippedRelations(): RulesDoc["relations"] {
  const rel = JSON.parse(readFileSync(join(META, "relations.json"), "utf8")) as { relations: Record<string, { dependant?: "from" | "to" | "both"; required?: boolean }> };
  return Object.entries(rel.relations).map(([name, r]) => ({ name, dependant: r.dependant ?? null, required: r.required === true }));
}

// Every class of the metamodel files with its ancestors, as the controller serves them.
function metamodelAncestors(): Record<string, string[]> {
  const parent = new Map<string, string | null>();
  for (const f of readdirSync(META).filter((x) => x.endsWith(".json"))) {
    const doc = JSON.parse(readFileSync(join(META, f), "utf8")) as { classes?: Record<string, { parent?: string }> };
    for (const [name, c] of Object.entries(doc.classes ?? {})) parent.set(name, c.parent ?? null);
  }
  const out: Record<string, string[]> = {};
  for (const name of parent.keys()) {
    const chain: string[] = [];
    for (let c: string | null | undefined = name; c && !chain.includes(c); c = parent.get(c)) chain.push(c);
    out[name] = chain;
  }
  return out;
}
const ALL_CLASSES: Record<string, string[]> = { ...metamodelAncestors(), ...CLASSES };
export const ANCESTORS = ALL_CLASSES;

let legacyN = 0;
/** A rule in the old health-rules.json shape, as the propagate record it is: the
 *  tests written before records add rules this way. */
export function fromLegacy(r: HealthRule, relations: RulesDoc["relations"] = shippedRelations()): Propagate {
  const meta = relations.find((x) => x.name === r.relation);
  const when: Propagate["when"] = { relation: r.relation, condition: { type: r.source.type, status: r.source.status } };
  if (meta?.dependant === "both") {
    if (r.from) when.from = { class: r.from };
    if (r.to) when.to = { class: r.to };
  } else {
    const [depCls, provCls] = meta?.dependant === "to" ? [r.to, r.from] : [r.from, r.to];
    if (depCls) when.dependant = { class: depCls };
    if (provCls) when.provider = { class: provCls };
  }
  if (r.dependant) when.dependant = { ...(when.dependant ?? {}), attr: Object.fromEntries(Object.entries(r.dependant).map(([k, v]) => [k, v === true ? { exists: true } : v])) };
  return { id: `test.propagate.r${++legacyN}`, kind: "propagate", when, as: { status: r.impact as "warning" | "critical" } };
}

/** The shipped records, the metamodel's relations and the classes; `extra`
 *  records, or rules in the old shape, added. */
export function shippedModel(extra: (HealthRule | HealthRecord)[] = []): RulesDoc {
  const relations = shippedRelations();
  return {
    records: [...coreRecords(), ...extra.map((x) => ("kind" in x ? x : fromLegacy(x, relations)))],
    relations,
    ancestors: ALL_CLASSES,
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
  security?: AssessIO["security"];
  metrics?: AssessIO["metrics"];
  windows?: AssessIO["windows"];
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
