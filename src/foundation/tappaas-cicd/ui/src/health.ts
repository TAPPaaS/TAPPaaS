// health.ts — the Health view's document (ADR-041 D5), built from what the CMDB
// holds: every object with its worst condition, the relations that carry
// impact, the groups a page collapses, the current root causes and the objects
// each one impacts. Pure: cmdb.ts reads, this computes, so the view and the
// pages that read the worst condition (Overview, Backup, Modules) agree.
//
// A condition is health-assess's (ADR-041 D1). Nothing here judges an object:
// this only picks the worst of what assess wrote and says what silences it.

import { createHash } from "crypto";
import { CmdbAttributePeriod, CmdbClassRow, CmdbObject, CmdbRelationRow, CmdbShow } from "./cmdb";

export type Status = "ok" | "warning" | "critical" | "unknown";

// `unknown` ranks between ok and warning (D1).
const RANK: Record<Status, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

export const CONDITION_TYPES = ["operational", "drift", "capacity", "security", "maintenance", "backup", "impact"];

// The relations that carry impact (D3, D5). part-of and provides do not, but
// they say which group an object collapses into.
export const IMPACT_RELATIONS = ["runs-on", "depends-on", "member-of", "connects", "allocated-to", "serves"];

export interface Acknowledged {
  by?: string;
  note?: string;
  until?: string | null;
  sticky?: boolean;
}

export interface Condition {
  type: string;
  status: Status;
  reason?: string | null;
  message?: string | null;
  since?: string | null;
  lastChecked?: string | null;
  source?: string | null;
  derived?: boolean;
  rootCause?: string | string[] | null;
  acknowledged?: Acknowledged | null;
  maintenance?: { until?: string | null; note?: string } | null;
  flapping?: boolean;
}

// What a page shows of a condition.
export interface Issue {
  type: string;
  status: Status;
  reason: string | null;
  message: string | null;
  since: string | null;
  derived: boolean;
  rootCause: string[];
  acknowledged: boolean;
  maintenance: boolean;
  flapping: boolean;
}

export interface HealthView {
  status: Status; // the colour
  type: string | null;
  reason: string | null;
  since: string | null;
  acknowledged: boolean; // the colour is only what an acknowledgement silenced: hatched
  maintenance: boolean; // only what a window silenced: dotted
  flapping: boolean;
}

export interface HealthNode extends HealthView {
  id: string;
  class: string;
  name: string;
  label: string;
  tier: number; // 0 at the bottom of the graph
  group: string | null;
  environment: string | null;
  module: string | null; // the deployed module it is, or provides for
  rootCause: string[]; // what explains it, the roots' ids
  isRoot: boolean;
  types: Record<string, Status>; // the worst of each condition type
  issues: Issue[]; // the conditions that are not ok
}

export interface HealthEdge {
  id: string;
  type: string;
  from: string;
  to: string;
}

export interface HealthGroup {
  id: string;
  label: string;
  kind: "environment" | "ports" | "addresses" | "host" | "class";
  members: number;
}

export interface HealthRoot {
  id: string;
  class: string;
  name: string;
  label: string;
  type: string | null;
  status: Status;
  reason: string | null;
  message: string | null;
  since: string | null;
  acknowledged: boolean;
  flapping: boolean;
  impactedCount: number;
  impacted: string[];
  environments: string[];
}

export type Counts = Record<Status | "acknowledged", number>;

export interface HealthGraph {
  generated: string;
  at: string | null; // the moment it shows; null: now
  topology: string; // changes when an object, a group or an edge does
  hasConditions: boolean; // false: this site has not run assess
  site: string | null;
  nodes: HealthNode[];
  edges: HealthEdge[];
  groups: HealthGroup[];
  roots: HealthRoot[];
  counts: Counts;
}

const asArray = (v: unknown): string[] => (typeof v === "string" && v ? [v] : Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && x !== "") : []);

export function conditionsOf(attributes: Record<string, unknown>): Condition[] {
  const v = attributes.conditions;
  return Array.isArray(v) ? (v as Condition[]).filter((c) => !!c && typeof c.type === "string" && typeof c.status === "string" && c.status in RANK) : [];
}

// An acknowledgement or a window holds until its `until`; none: until cleared.
export function holds(until: string | null | undefined, now: number): boolean {
  return !until || Date.parse(until) > now;
}

export function issueOf(c: Condition, rootsAcked: Set<string>, now: number): Issue {
  const rootCause = asArray(c.rootCause);
  const ownAck = !!c.acknowledged && holds(c.acknowledged.until, now);
  // An acknowledgement on a root covers its symptoms (D4); a symptom with a
  // root that is not acknowledged is heard.
  const byRoot = c.type === "impact" && rootCause.length > 0 && rootCause.every((r) => rootsAcked.has(r));
  return {
    type: c.type,
    status: c.status,
    reason: c.reason ?? null,
    message: c.message ?? null,
    since: c.since ?? null,
    derived: c.derived === true,
    rootCause,
    acknowledged: ownAck || byRoot,
    maintenance: !!c.maintenance && holds(c.maintenance.until, now),
    flapping: c.flapping === true,
  };
}

const silenced = (i: Issue): boolean => i.acknowledged || i.maintenance;

// Of two equally bad conditions the object's own comes first, then the impact
// that explains it; a derived one ("not running", of course) says the least.
const voice = (i: Issue): number => (i.type === "impact" ? 1 : i.derived ? 2 : 0);

// The colour: the worst condition still counting; only when nothing counts,
// the worst silenced one, hatched or dotted.
export function viewOf(issues: Issue[]): HealthView {
  const bad = issues.filter((i) => i.status !== "ok");
  const counting = bad.filter((i) => !silenced(i));
  const pool = counting.length ? counting : bad;
  const top = [...pool].sort((a, b) => RANK[b.status] - RANK[a.status] || voice(a) - voice(b))[0];
  if (!top) return { status: "ok", type: null, reason: null, since: null, acknowledged: false, maintenance: false, flapping: false };
  const quiet = !counting.length;
  return {
    status: top.status,
    type: top.type,
    reason: top.message ?? top.reason,
    since: top.since,
    acknowledged: quiet && top.acknowledged,
    maintenance: quiet && !top.acknowledged && top.maintenance,
    flapping: bad.some((i) => i.flapping),
  };
}

const NO_CONDITION: HealthView = { status: "unknown", type: null, reason: null, since: null, acknowledged: false, maintenance: false, flapping: false };

// Bottom to top (D5): the places and the hardware, what runs on it, what it
// serves, environments and the site.
const TIERS: Record<string, number> = {
  place: 0,
  resource: 1,
  machine: 2,
  device: 2,
  "storage-element": 3,
  vm: 4,
  lxc: 4,
  software: 5,
  "network-element": 6,
  identity: 6,
  cluster: 7,
  environment: 8,
  site: 9,
};

// A class's tier by its own name, else its nearest ancestor's (a class a
// module contributed); what the tree does not place sits with the software.
export function tierOf(cls: string, parent: Map<string, string | null>): number {
  let c: string | null | undefined = cls;
  for (let i = 0; c && i < 16; i++) {
    if (c in TIERS) return TIERS[c];
    c = parent.get(c);
  }
  return TIERS.software;
}

function isA(cls: string, of: string, parent: Map<string, string | null>): boolean {
  let c: string | null | undefined = cls;
  for (let i = 0; c && i < 16; i++) {
    if (c === of) return true;
    c = parent.get(c);
  }
  return false;
}

// The metamodel's tree as the console ships it, for a CMDB that does not say
// (GET /v1/classes failed): the classes the groups below ask about.
const SHIPPED_PARENTS: Record<string, string> = {
  app: "software", service: "software", controller: "software", manager: "software",
  zone: "network-element", ssid: "network-element", address: "network-element", "dns-name": "network-element", "proxy-route": "network-element", "vpn-peer": "network-element",
  "storage-pool": "storage-element", share: "storage-element", datastore: "storage-element", "backup-peer": "storage-element",
  organization: "identity", group: "identity", user: "identity", role: "identity",
  location: "place", room: "place", rack: "place",
  server: "asset", "network-device": "asset", appliance: "asset", "passive-device": "asset", "other-device": "asset", asset: "resource", port: "resource", pool: "resource",
};

// These collapse per class: nothing else draws them apart.
const CLASS_GROUPS = ["dns-name", "proxy-route", "vpn-peer", "share", "user", "group", "role", "organization", "place"];

// Which group an object collapses into; one member is no group.
function assignGroups(objects: CmdbObject[], rows: CmdbRelationRow[], parent: Map<string, string | null>): Map<string, HealthGroup> {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const name = (o: CmdbObject | undefined): string => o?.displayName || o?.name || "?";
  const out = new Map<string, { type: string; to: CmdbObject }[]>();
  for (const r of rows) {
    const to = byId.get(r.to.id);
    if (to) out.set(r.from.id, [...(out.get(r.from.id) ?? []), { type: r.type, to }]);
  }
  const via = (id: string, type: string, of?: string): CmdbObject | undefined => (out.get(id) ?? []).find((x) => x.type === type && (!of || isA(x.to.class, of, parent)))?.to;
  const envOf = (o: CmdbObject): string | null => {
    const e = via(o.id, "member-of", "environment");
    if (e) return e.name;
    return typeof o.attributes.environment === "string" && o.attributes.environment ? o.attributes.environment : null;
  };
  const guest = (c: string): boolean => isA(c, "vm", parent) || isA(c, "lxc", parent);
  const candidate = new Map<string, HealthGroup>();
  for (const o of objects) {
    let g: Omit<HealthGroup, "members"> | null = null;
    if (isA(o.class, "port", parent)) {
      const a = via(o.id, "part-of");
      if (a) g = { id: `ports:${a.id}`, label: `ports of ${name(a)}`, kind: "ports" };
    } else if (isA(o.class, "address", parent)) {
      const z = via(o.id, "member-of", "zone");
      if (z) g = { id: `addresses:${z.id}`, label: `addresses in ${name(z)}`, kind: "addresses" };
    } else if (guest(o.class)) {
      const e = envOf(o);
      if (e) g = { id: `environment:${e}`, label: `${e} guests`, kind: "environment" };
    } else if (isA(o.class, "software", parent)) {
      const host = via(o.id, "runs-on");
      const e = host && guest(host.class) ? envOf(host) : null;
      if (e) g = { id: `environment:${e}`, label: `${e} guests`, kind: "environment" };
      else if (host) g = { id: `host:${host.id}`, label: `software on ${name(host)}`, kind: "host" };
    } else {
      const c = CLASS_GROUPS.find((x) => isA(o.class, x, parent));
      if (c) g = { id: `class:${c}`, label: `${c}s`, kind: "class" };
    }
    if (!g) continue;
    candidate.set(o.id, { ...g, members: 0 });
  }
  const size = new Map<string, number>();
  for (const g of candidate.values()) size.set(g.id, (size.get(g.id) ?? 0) + 1);
  const groups = new Map<string, HealthGroup>();
  for (const [id, g] of candidate) if ((size.get(g.id) ?? 0) > 1) groups.set(id, { ...g, members: size.get(g.id) ?? 0 });
  return groups;
}

export function emptyCounts(): Counts {
  return { ok: 0, unknown: 0, warning: 0, critical: 0, acknowledged: 0 };
}

function countsOf(nodes: HealthNode[]): Counts {
  const c = emptyCounts();
  for (const n of nodes) {
    if (n.acknowledged || n.maintenance) c.acknowledged++;
    else c[n.status]++;
  }
  return c;
}

export interface BuildInput {
  objects: CmdbObject[];
  relations: CmdbRelationRow[];
  classes?: CmdbClassRow[];
  modules?: string[];
  now: number;
  at?: string | null;
}

export function buildHealth(i: BuildInput): HealthGraph {
  const parent = new Map<string, string | null>(Object.entries(SHIPPED_PARENTS));
  for (const c of i.classes ?? []) parent.set(c.name, c.parent);
  const objects = [...i.objects].sort((a, b) => a.id.localeCompare(b.id));
  const byId = new Map(objects.map((o) => [o.id, o]));
  const modules = new Set(i.modules ?? []);
  const site = objects.find((o) => isA(o.class, "site", parent)) ?? null;
  const groups = assignGroups(objects, i.relations, parent);

  // The acknowledged roots first: what a symptom's silence hangs on.
  const recorded = (Array.isArray(site?.attributes.rootCauses) ? site!.attributes.rootCauses : []) as { id?: unknown; type?: unknown; impactedCount?: unknown }[];
  const rootsAcked = new Set<string>();
  for (const r of recorded) {
    if (typeof r.id !== "string") continue;
    const own = conditionsOf(byId.get(r.id)?.attributes ?? {}).filter((c) => (typeof r.type === "string" ? c.type === r.type : c.status !== "ok"));
    if (own.length && own.every((c) => c.acknowledged && holds(c.acknowledged.until, i.now))) rootsAcked.add(r.id);
  }

  const envName = (id: string): string | null => {
    const o = byId.get(id);
    if (!o) return null;
    const g = groups.get(id);
    if (g?.kind === "environment") return g.id.slice("environment:".length);
    return typeof o.attributes.environment === "string" && o.attributes.environment ? o.attributes.environment : null;
  };

  let any = false;
  const nodes: HealthNode[] = objects.map((o) => {
    const conditions = conditionsOf(o.attributes);
    if (conditions.length) any = true;
    const issues = conditions.map((c) => issueOf(c, rootsAcked, i.now));
    const types: Record<string, Status> = {};
    for (const c of issues) if (!types[c.type] || RANK[c.status] > RANK[types[c.type]]) types[c.type] = c.status;
    const provider = typeof o.attributes.provider === "string" ? o.attributes.provider : null;
    const module = [provider, o.name].find((m) => m !== null && modules.has(m)) ?? null;
    return {
      id: o.id,
      class: o.class,
      name: o.name,
      label: o.displayName || o.name,
      tier: tierOf(o.class, parent),
      group: groups.get(o.id)?.id ?? null,
      environment: envName(o.id),
      module,
      rootCause: [...new Set(issues.flatMap((x) => x.rootCause))].filter((r) => r !== o.id),
      isRoot: false,
      types,
      issues: issues.filter((x) => x.status !== "ok"),
      ...(conditions.length ? viewOf(issues) : NO_CONDITION),
    };
  });

  const nodeOf = new Map(nodes.map((n) => [n.id, n]));
  const impactedBy = new Map<string, string[]>();
  for (const n of nodes) for (const r of n.rootCause) impactedBy.set(r, [...(impactedBy.get(r) ?? []), n.id]);
  // The site's record is the list; a root only a symptom names counts too.
  const ids = [...new Set([...recorded.map((r) => r.id).filter((x): x is string => typeof x === "string"), ...impactedBy.keys()])].filter((id) => nodeOf.has(id));
  const roots: HealthRoot[] = ids.map((id) => {
    const n = nodeOf.get(id)!;
    n.isRoot = true;
    const rec = recorded.find((r) => r.id === id);
    const type = typeof rec?.type === "string" ? rec.type : n.type;
    const c = n.issues.find((x) => x.type === type) ?? n.issues[0] ?? null;
    const impacted = impactedBy.get(id) ?? [];
    return {
      id,
      class: n.class,
      name: n.name,
      label: n.label,
      type,
      status: c?.status ?? n.status,
      reason: c?.reason ?? n.reason,
      message: c?.message ?? null,
      since: c?.since ?? n.since,
      acknowledged: rootsAcked.has(id),
      flapping: n.flapping,
      impactedCount: typeof rec?.impactedCount === "number" ? rec.impactedCount : impacted.length,
      impacted,
      environments: [...new Set(impacted.map((x) => nodeOf.get(x)?.environment).filter((e): e is string => !!e))].sort(),
    };
  });
  roots.sort((a, b) => b.impactedCount - a.impactedCount || a.label.localeCompare(b.label));

  const carrying = new Set(IMPACT_RELATIONS);
  const edges: HealthEdge[] = i.relations
    .filter((r) => carrying.has(r.type) && byId.has(r.from.id) && byId.has(r.to.id) && r.from.id !== r.to.id)
    .map((r) => ({ id: String(r.id), type: r.type, from: r.from.id, to: r.to.id }))
    .sort((a, b) => a.id.localeCompare(b.id, "en", { numeric: true }));

  const groupList = [...new Map([...groups.values()].map((g) => [g.id, g])).values()].sort((a, b) => a.id.localeCompare(b.id));
  const shape = JSON.stringify([nodes.map((n) => [n.id, n.class, n.group]), edges.map((e) => [e.type, e.from, e.to])]);
  return {
    generated: new Date(i.now).toISOString(),
    at: i.at ?? null,
    topology: createHash("sha256").update(shape).digest("hex").slice(0, 16),
    hasConditions: any,
    site: site?.id ?? null,
    nodes,
    edges,
    groups: groupList,
    roots,
    counts: countsOf(nodes),
  };
}

// ── what a change moved ───────────────────────────────────────────────

// Sent down the live stream: the colours that moved, or, when the topology did,
// only that (the page reads the graph again and lays it out once).
export interface HealthPatch {
  topology: string;
  relayout: boolean;
  generated: string;
  patches: HealthNode[];
  roots: HealthRoot[];
  counts: Counts;
  hasConditions: boolean;
}

export function diffHealth(before: HealthGraph | null, after: HealthGraph): HealthPatch | null {
  const relayout = before === null || before.topology !== after.topology;
  const old = new Map((before?.nodes ?? []).map((n) => [n.id, JSON.stringify(n)]));
  const patches = relayout ? [] : after.nodes.filter((n) => old.get(n.id) !== JSON.stringify(n));
  const sameRoots = before !== null && JSON.stringify(before.roots) === JSON.stringify(after.roots);
  if (!relayout && patches.length === 0 && sameRoots) return null;
  return { topology: after.topology, relayout, generated: after.generated, patches, roots: after.roots, counts: after.counts, hasConditions: after.hasConditions };
}

// ── the pages that read the worst condition ──────────────────────────

export interface ModuleHealth extends HealthView {
  objects: number;
  issues: (Issue & { object: string; label: string })[];
}

// The worst of a module's objects: its node or app, the services it provides.
export function moduleHealth(doc: HealthGraph | null): Map<string, ModuleHealth> {
  const out = new Map<string, ModuleHealth>();
  if (!doc?.hasConditions) return out;
  const by = new Map<string, HealthNode[]>();
  for (const n of doc.nodes) if (n.module) by.set(n.module, [...(by.get(n.module) ?? []), n]);
  for (const [m, nodes] of by) {
    const judged = nodes.filter((n) => Object.keys(n.types).length > 0);
    if (!judged.length) continue;
    const issues = judged.flatMap((n) => n.issues.map((x) => ({ ...x, object: n.id, label: n.label })));
    out.set(m, { ...viewOf(issues), objects: judged.length, issues });
  }
  return out;
}

export interface TypeHealth {
  status: Status;
  items: { id: string; label: string; class: string; status: Status; reason: string | null; since: string | null; silenced: boolean }[];
}

export interface HealthSummary {
  available: boolean; // the CMDB answered and holds conditions: otherwise a page keeps the health read
  generated: string | null;
  site: HealthView | null;
  counts: Counts;
  roots: HealthRoot[];
  byType: Record<string, TypeHealth>;
  attention: { id: string; label: string; class: string; module: string | null; type: string; status: Status; text: string; root: boolean }[];
}

const COUNTING_STATUS: Status[] = ["critical", "warning"];

export function healthSummary(doc: HealthGraph | null): HealthSummary {
  if (!doc?.hasConditions) return { available: false, generated: doc?.generated ?? null, site: null, counts: emptyCounts(), roots: [], byType: {}, attention: [] };
  const byType: Record<string, TypeHealth> = {};
  const attention: HealthSummary["attention"] = [];
  for (const n of doc.nodes) {
    for (const i of n.issues) {
      const t = (byType[i.type] ??= { status: "ok", items: [] });
      t.items.push({ id: n.id, label: n.label, class: n.class, status: i.status, reason: i.message ?? i.reason, since: i.since, silenced: silenced(i) });
      if (!silenced(i) && RANK[i.status] > RANK[t.status]) t.status = i.status;
      // A symptom is its root's business: one line, the root's (D4).
      if (!silenced(i) && !i.derived && i.type !== "impact" && COUNTING_STATUS.includes(i.status)) {
        attention.push({ id: n.id, label: n.label, class: n.class, module: n.module, type: i.type, status: i.status, text: i.message ?? i.reason ?? i.type, root: n.isRoot });
      }
    }
  }
  attention.sort((a, b) => Number(b.root) - Number(a.root) || RANK[b.status] - RANK[a.status] || a.label.localeCompare(b.label));
  const site = doc.nodes.find((n) => n.id === doc.site);
  return {
    available: true,
    generated: doc.generated,
    site: site ? { status: site.status, type: site.type, reason: site.reason, since: site.since, acknowledged: site.acknowledged, maintenance: site.maintenance, flapping: site.flapping } : null,
    counts: doc.counts,
    roots: doc.roots,
    byType,
    attention,
  };
}

// ── the CI panel ──────────────────────────────────────────────────────

export interface ConditionChange {
  at: string;
  type: string;
  from: Status | null;
  to: Status;
  reason: string | null;
  message: string | null;
  source: string;
}

// The transitions in the attribute's periods (D1): every change of a status
// opened a new period, so history is a walk through them.
export function conditionHistory(periods: CmdbAttributePeriod[], limit = 200): ConditionChange[] {
  const rows = periods.filter((p) => p.name === "conditions").sort((a, b) => Date.parse(a.from) - Date.parse(b.from));
  const last = new Map<string, Status>();
  const out: ConditionChange[] = [];
  for (const p of rows) {
    for (const c of conditionsOf({ conditions: p.value })) {
      const was = last.get(c.type) ?? null;
      if (was === c.status) continue;
      last.set(c.type, c.status);
      if (was === null && c.status === "ok") continue;
      out.push({ at: c.since ?? p.from, type: c.type, from: was, to: c.status, reason: c.reason ?? null, message: c.message ?? null, source: p.source });
    }
  }
  return out.sort((a, b) => Date.parse(b.at) - Date.parse(a.at)).slice(0, limit);
}

export interface HealthObject {
  id: string;
  class: string;
  ancestors: string[];
  name: string;
  label: string;
  module: string | null;
  view: HealthView;
  conditions: (Issue & { source: string | null; lastChecked: string | null; ack: Acknowledged | null; window: { until?: string | null; note?: string } | null })[];
  drift: unknown;
  relations: { id: string; type: string; direction: "in" | "out"; other: { id: string; class: string; name: string; status: Status | null } }[];
  history: ConditionChange[];
  changes: { id: number; kind: string; source: string; job: string | null; verb: string | null; actor: string | null; time: string }[];
  rootCauses: { id: string; class: string; label: string; reason: string | null }[];
  impacts: { id: string; class: string; label: string; status: Status }[];
}

export function healthObject(show: CmdbShow, periods: CmdbAttributePeriod[], changes: HealthObject["changes"], doc: HealthGraph | null, now: number): HealthObject {
  const nodeOf = new Map((doc?.nodes ?? []).map((n) => [n.id, n]));
  const n = nodeOf.get(show.id);
  const conditions = conditionsOf({ conditions: show.attributes.conditions?.value });
  const rootsAcked = new Set((doc?.roots ?? []).filter((r) => r.acknowledged).map((r) => r.id));
  const issues = conditions.map((c) => issueOf(c, rootsAcked, now));
  const root = (doc?.roots ?? []).find((r) => r.id === show.id);
  return {
    id: show.id,
    class: show.class,
    ancestors: show.ancestors ?? [],
    name: show.name,
    label: show.displayName || show.name,
    module: n?.module ?? null,
    view: conditions.length ? viewOf(issues) : NO_CONDITION,
    conditions: conditions.map((c, i) => ({ ...issues[i], source: c.source ?? null, lastChecked: c.lastChecked ?? null, ack: c.acknowledged ?? null, window: c.maintenance ?? null })),
    drift: show.drift ?? null,
    relations: show.relations.map((r) => ({ id: String(r.id), type: r.type, direction: r.direction, other: { ...r.other, status: nodeOf.get(r.other.id)?.status ?? null } })),
    history: conditionHistory(periods),
    changes: changes.slice(-50).reverse(),
    rootCauses: (n?.rootCause ?? []).map((id) => {
      const r = (doc?.roots ?? []).find((x) => x.id === id);
      return { id, class: r?.class ?? nodeOf.get(id)?.class ?? "?", label: r?.label ?? nodeOf.get(id)?.label ?? id, reason: r?.message ?? r?.reason ?? null };
    }),
    impacts: (root?.impacted ?? []).map((id) => {
      const x = nodeOf.get(id);
      return { id, class: x?.class ?? "?", label: x?.label ?? id, status: x?.status ?? "unknown" };
    }),
  };
}
