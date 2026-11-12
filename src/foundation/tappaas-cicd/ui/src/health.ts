// health.ts — the Health view's document (ADR-041 D5), built from what the CMDB
// holds: every object with its worst condition, the relations between them, the
// current root causes and the objects each one impacts; the tree over the
// relations the metamodel calls containment, with the roll-up of every subtree;
// the ego graph around one object and the chains of the derivation. Pure:
// cmdb.ts reads, this computes, so the view and the pages that read the worst
// condition (Overview, Backup, Modules) agree.
//
// A condition is health-assess's (ADR-041 D1). Nothing here judges an object:
// this only picks the worst of what assess wrote and says what silences it.

import { createHash } from "crypto";
import { CmdbAttributePeriod, CmdbClassRow, CmdbObject, CmdbRelationRow, CmdbShow } from "./cmdb";
import { migrateConditions, migrateStoredObjects } from "../../lib/ts/src/health-migrate";
import { CONDITION_TYPES as TYPES } from "../../lib/ts/src/health-rules";

export type Status = "ok" | "warning" | "critical" | "unknown";

// `unknown` ranks between ok and warning (D1).
const RANK: Record<Status, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

// The types health speaks in. A condition stored under a type from before the
// split (maintenance, security) reads as its new one (health-migrate.ts).
export const CONDITION_TYPES: string[] = [...TYPES];

// What the Health view needs of a relation type: the metamodel's words, so the
// console hardcodes neither containment nor dependency (/v1/rules).
export interface RelationType {
  name: string;
  dependant: "from" | "to" | "both" | null; // the end hurt when the other fails
  tree: "from" | "to" | "both" | null; // the end nested under the other; both: a leaf either way
}

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
  quieted?: { rule: string; since?: string; via?: string[] } | null; // quiet by a health rule: kept, told nowhere
  raw?: { status: Status; since?: string; rule: string } | null; // re-rated by a health rule: what its source said
  rule?: string | null; // the health rule that decided a derived condition
  owner?: string | null; // the source that raised it
  hits?: Hits | null; // the events behind it: the SIEM's hits, a flapping condition's transitions
  heldUntil?: string | null; // when its hold ends, or "ack": until acknowledged
  heldBy?: string | null; // the health rule that set the hold
}

export interface Hits { count: number; first: string; last: string; alerts?: string[]; query?: string }

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
  quiet?: string; // the health rule that quieted it (or its only root)
  hits?: Hits;
  heldUntil?: string;
  heldBy?: string;
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
  environment: string | null;
  module: string | null; // the deployed module it is, or provides for
  rootCause: string[]; // what explains it, the roots' ids
  isRoot: boolean;
  types: Record<string, Status>; // the worst of each condition type
  issues: Issue[]; // the conditions that are not ok
  acks?: Record<string, AckWord>; // the operator's last acknowledgement per type, kept after the condition ended
}

// An acknowledgement as the operator gave it (the object's acknowledgements attribute).
export interface AckWord { by: string; note: string; at: string; until: string | null }

function acksOf(attributes: Record<string, unknown>): Record<string, AckWord> | undefined {
  const words = attributes.acknowledgements;
  if (!words || typeof words !== "object") return undefined;
  const out: Record<string, AckWord> = {};
  for (const [type, w] of Object.entries(words as Record<string, { ack?: { by?: string; note?: string; until?: string | null; at?: string } | null; at?: string }>)) {
    if (!w?.ack) continue;
    out[type] = { by: w.ack.by ?? "", note: w.ack.note ?? "", at: w.ack.at ?? w.at ?? "", until: w.ack.until ?? null };
  }
  return Object.keys(out).length ? out : undefined;
}

export interface HealthEdge {
  id: string;
  type: string;
  from: string;
  to: string;
}

// A root's condition of one type it is a root in: the fields its row shows.
export interface RootCondition {
  type: string;
  status: Status;
  reason: string | null;
  message: string | null;
  since: string | null;
  acknowledged: boolean;
  maintenance: boolean;
  hits?: Hits;
  heldUntil?: string;
  heldBy?: string;
}

export interface HealthRoot {
  id: string;
  class: string;
  name: string;
  label: string;
  type: string | null; // the worst of the types it is a root in
  types: string[]; // every type it is a root in
  conditions: RootCondition[]; // one per type in `types`, worst first
  environment: string | null; // its own
  maintenance: boolean;
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

// `acknowledged`: the silenced conditions (acknowledged or in maintenance); the rest count objects.
export type Counts = Record<Status | "acknowledged", number>;

export interface HealthGraph {
  generated: string;
  at: string | null; // the moment it shows; null: now
  topology: string; // changes when an object or an edge does
  hasConditions: boolean; // false: this site has not run assess
  site: string | null;
  nodes: HealthNode[];
  edges: HealthEdge[];
  relationTypes: RelationType[];
  tree: TreeIndex;
  roots: HealthRoot[];
  counts: Counts;
}

// A subtree in one line: the worst status, how many objects need a look (an
// unknown is grey, not a finding to count; a silenced one neither), and what a
// filter asks of it.
export interface TreeRollup {
  status: Status;
  notOk: number;
  unknown: number;
  acknowledged: boolean;
  maintenance: boolean;
  flapping: boolean;
  types: Record<string, Status>;
  classes: string[];
  environments: string[];
}

export interface TreeChild {
  id: string;
  leaf: boolean; // listed, not opened: the other end of a cable
}

export interface TreeIndex {
  facets: { id: string; label: string; roots: string[] }[];
  children: Map<string, TreeChild[]>;
  rollups: Map<string, TreeRollup>;
}

const asArray = (v: unknown): string[] => (typeof v === "string" && v ? [v] : Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && x !== "") : []);

export function conditionsOf(attributes: Record<string, unknown>): Condition[] {
  const v = attributes.conditions;
  return Array.isArray(v) ? migrateConditions((v as Condition[]).filter((c) => !!c && typeof c.type === "string" && typeof c.status === "string" && c.status in RANK)) : [];
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
    ...(c.quieted?.rule ? { quiet: c.quieted.rule } : {}),
    ...(c.hits && typeof c.hits.count === "number" ? { hits: c.hits } : {}),
    ...(c.heldUntil ? { heldUntil: c.heldUntil } : {}),
    ...(c.heldBy ? { heldBy: c.heldBy } : {}),
  };
}

const silenced = (i: Issue): boolean => i.acknowledged || i.maintenance || !!i.quiet;

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

function isA(cls: string, of: string, parent: Map<string, string | null>): boolean {
  let c: string | null | undefined = cls;
  for (let i = 0; c && i < 16; i++) {
    if (c === of) return true;
    c = parent.get(c);
  }
  return false;
}

// The metamodel's tree as the console ships it, for a CMDB that does not say
// (GET /v1/classes failed): the classes the facets and the environments ask about.
const SHIPPED_PARENTS: Record<string, string> = {
  vm: "node", lxc: "node", machine: "node", device: "node",
  site: "collection", cluster: "collection", environment: "collection",
  app: "software", service: "software", controller: "software", manager: "software",
  zone: "network-element", ssid: "network-element", address: "network-element", "dns-name": "network-element", "proxy-route": "network-element", "vpn-peer": "network-element",
  "storage-pool": "storage-element", share: "storage-element", datastore: "storage-element", "backup-peer": "storage-element",
  organization: "identity", group: "identity", user: "identity", role: "identity",
  location: "place", room: "place", rack: "place",
  server: "asset", "network-device": "asset", appliance: "asset", "passive-device": "asset", "other-device": "asset", asset: "resource", port: "resource", disk: "resource", pool: "resource",
};

export function emptyCounts(): Counts {
  return { ok: 0, unknown: 0, warning: 0, critical: 0, acknowledged: 0 };
}

// The objects by colour, and apart from them what is silenced, condition by
// condition: an acknowledged critical beside an open warning is one warning
// object and one silenced condition. An object whose every failure is silenced
// is in no colour's count.
export function countsOf(nodes: HealthNode[]): Counts {
  const c = emptyCounts();
  for (const n of nodes) {
    if (!n.acknowledged && !n.maintenance) c[n.status]++;
    c.acknowledged += n.issues.filter((i) => i.status !== "ok" && silenced(i)).length;
  }
  return c;
}

// The Health page's filters: a condition type, a class, an environment; "" is all.
export interface HealthFilter { type?: string; class?: string; environment?: string }

const filtering = (f: HealthFilter): boolean => !!(f.type || f.class || f.environment);

/** Is a root cause in the list under the filters: a root in that type, of that
 *  class, in that environment (its own, or one of what it impacts)? */
export function rootMatches(r: HealthRoot, f: HealthFilter): boolean {
  return (!f.type || r.types.includes(f.type)) && (!f.class || r.class === f.class) && (!f.environment || r.environment === f.environment || r.environments.includes(f.environment));
}

/** The header under the filters: the objects by colour as the filters see them
 *  (under a type, that type's colour), what they silence, and "8 of 34 root causes". */
export function filteredCounts(doc: HealthGraph, f: HealthFilter): { counts: Counts; roots: number; rootsAll: number; filtered: boolean } {
  const c = emptyCounts();
  for (const n of doc.nodes) {
    if ((f.class && n.class !== f.class) || (f.environment && n.environment !== f.environment)) continue;
    if (!f.type) {
      if (!n.acknowledged && !n.maintenance) c[n.status]++;
      c.acknowledged += n.issues.filter((i) => i.status !== "ok" && silenced(i)).length;
      continue;
    }
    const st = n.types[f.type];
    if (st === undefined) continue;
    const mine = n.issues.filter((i) => i.type === f.type);
    const v = mine.length ? viewOf(mine) : null;
    if (!v) c[st]++;
    else if (!v.acknowledged && !v.maintenance) c[v.status]++;
    c.acknowledged += mine.filter((i) => i.status !== "ok" && silenced(i)).length;
  }
  return { counts: c, roots: doc.roots.filter((r) => rootMatches(r, f)).length, rootsAll: doc.roots.length, filtered: filtering(f) };
}

export interface BuildInput {
  objects: CmdbObject[];
  relations: CmdbRelationRow[];
  classes?: CmdbClassRow[];
  relationTypes?: RelationType[];
  modules?: string[];
  now: number;
  at?: string | null;
}

// An object's environment: the one it is a member of, its own word for it, or
// that of the guest it runs on.
function environmentsOf(objects: CmdbObject[], rows: CmdbRelationRow[], parent: Map<string, string | null>): Map<string, string> {
  const out = new Map<string, string>();
  for (const o of objects) if (typeof o.attributes.environment === "string" && o.attributes.environment) out.set(o.id, o.attributes.environment);
  for (const r of rows) if (r.type === "member-of" && isA(r.to.class, "environment", parent)) out.set(r.from.id, r.to.name);
  for (const r of rows) {
    const host = out.get(r.to.id);
    if (r.type === "runs-on" && host && isA(r.from.class, "software", parent) && !out.has(r.from.id)) out.set(r.from.id, host);
  }
  return out;
}

export function buildHealth(i: BuildInput): HealthGraph {
  const parent = new Map<string, string | null>(Object.entries(SHIPPED_PARENTS));
  for (const c of i.classes ?? []) parent.set(c.name, c.parent);
  const objects = migrateStoredObjects([...i.objects]).sort((a, b) => a.id.localeCompare(b.id));
  const byId = new Map(objects.map((o) => [o.id, o]));
  const modules = new Set(i.modules ?? []);
  const site = objects.find((o) => isA(o.class, "site", parent)) ?? null;
  const environments = environmentsOf(objects, i.relations, parent);

  // The acknowledged roots first: what a symptom's silence hangs on.
  const recorded = (Array.isArray(site?.attributes.rootCauses) ? site!.attributes.rootCauses : []) as { id?: unknown; type?: unknown; impactedCount?: unknown }[];
  const rootsAcked = new Set<string>();
  for (const r of recorded) {
    if (typeof r.id !== "string") continue;
    const own = conditionsOf(byId.get(r.id)?.attributes ?? {}).filter((c) => (typeof r.type === "string" ? c.type === r.type : c.status !== "ok"));
    if (own.length && own.every((c) => c.acknowledged && holds(c.acknowledged.until, i.now))) rootsAcked.add(r.id);
  }

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
      environment: environments.get(o.id) ?? null,
      module,
      rootCause: [...new Set(issues.flatMap((x) => x.rootCause))].filter((r) => r !== o.id),
      isRoot: false,
      types,
      issues: issues.filter((x) => x.status !== "ok"),
      ...(acksOf(o.attributes) ? { acks: acksOf(o.attributes) } : {}),
      ...(conditions.length ? viewOf(issues) : NO_CONDITION),
    };
  });

  const nodeOf = new Map(nodes.map((n) => [n.id, n]));
  const impactedBy = new Map<string, string[]>();
  for (const n of nodes) for (const r of n.rootCause) impactedBy.set(r, [...(impactedBy.get(r) ?? []), n.id]);
  // The site's record is the list: health-manager decides the roots under the
  // rules the site runs, and the console computes none of its own.
  const ids = [...new Set(recorded.map((r) => r.id).filter((x): x is string => typeof x === "string"))].filter((id) => nodeOf.has(id));
  const roots: HealthRoot[] = ids.map((id) => {
    const n = nodeOf.get(id)!;
    n.isRoot = true;
    const recs = recorded.filter((r) => r.id === id);
    const rec = recs.find((r) => typeof r.impactedCount === "number") ?? recs[0];
    // Every type the object is a root in; worst first. An entry without a type
    // is its failing conditions.
    const named = [...new Set(recs.map((r) => r.type).filter((t): t is string => typeof t === "string"))];
    const own = n.issues.filter((x) => (named.length ? named.includes(x.type) : x.type !== "impact" && !x.derived));
    const conds: RootCondition[] = own
      .sort((a, b) => RANK[b.status] - RANK[a.status] || Number(a.acknowledged) - Number(b.acknowledged) || a.type.localeCompare(b.type))
      .map((x) => ({ type: x.type, status: x.status, reason: x.reason, message: x.message, since: x.since, acknowledged: x.acknowledged, maintenance: x.maintenance, ...(x.hits ? { hits: x.hits } : {}), ...(x.heldUntil ? { heldUntil: x.heldUntil } : {}), ...(x.heldBy ? { heldBy: x.heldBy } : {}) }));
    const types = named.length ? [...new Set([...conds.map((x) => x.type), ...named])] : conds.map((x) => x.type);
    const type = conds[0]?.type ?? named[0] ?? n.type;
    const c = n.issues.find((x) => x.type === type) ?? n.issues[0] ?? null;
    const impacted = impactedBy.get(id) ?? [];
    return {
      id,
      class: n.class,
      name: n.name,
      label: n.label,
      type,
      types,
      conditions: conds,
      environment: n.environment,
      maintenance: conds.length > 0 && conds.every((x) => x.maintenance),
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
  roots.sort((a, b) => b.impactedCount - a.impactedCount || RANK[b.status] - RANK[a.status] || a.label.localeCompare(b.label));

  const edges: HealthEdge[] = i.relations
    .filter((r) => byId.has(r.from.id) && byId.has(r.to.id) && r.from.id !== r.to.id)
    .map((r) => ({ id: String(r.id), type: r.type, from: r.from.id, to: r.to.id }))
    .sort((a, b) => a.id.localeCompare(b.id, "en", { numeric: true }));

  const shape = JSON.stringify([nodes.map((n) => [n.id, n.class]), edges.map((e) => [e.type, e.from, e.to])]);
  const relationTypes = i.relationTypes ?? [];
  return {
    generated: new Date(i.now).toISOString(),
    at: i.at ?? null,
    topology: createHash("sha256").update(shape).digest("hex").slice(0, 16),
    hasConditions: any,
    site: site?.id ?? null,
    nodes,
    edges,
    relationTypes,
    tree: buildTree(nodes, edges, relationTypes, parent),
    roots,
    counts: countsOf(nodes),
  };
}

// ── the tree ──────────────────────────────────────────────────────────

// The top level (D5). Which relation nests what is the metamodel's; a facet only
// says where to start: the objects of these classes that nothing of them holds.
const FACETS = [
  { id: "physical", label: "Physical", classes: ["place", "site", "asset", "node"] },
  { id: "environments", label: "Environments", classes: ["environment", "zone"] },
  { id: "identity", label: "Identity", classes: ["identity"] },
];

// What no facet reaches is still found: a fourth row, only when there is any.
const ELSEWHERE = { id: "elsewhere", label: "Elsewhere" };

export const TREE_FACETS = [...FACETS.map((f) => f.id), ELSEWHERE.id];

const ROLLED_UP = new Set(["roll-up", "rollup"]);

// A collection's or a place's own derived condition repeats its members: the
// count is of the objects at fault, not of the boxes around them.
const needsLook = (n: HealthNode): boolean =>
  n.issues.some((i) => COUNTING_STATUS.includes(i.status) && !silenced(i) && !(i.derived && ROLLED_UP.has(i.reason ?? "")));

export function rollupOf(nodes: HealthNode[]): TreeRollup {
  const counting = nodes.filter((n) => n.status !== "ok" && !n.acknowledged && !n.maintenance);
  const pool = counting.length ? counting : nodes.filter((n) => n.status !== "ok");
  const top = pool.reduce<HealthNode | null>((a, n) => (!a || RANK[n.status] > RANK[a.status] ? n : a), null);
  const types: Record<string, Status> = {};
  for (const n of nodes) for (const [t, st] of Object.entries(n.types)) if (!types[t] || RANK[st] > RANK[types[t]]) types[t] = st;
  const quiet = !counting.length;
  return {
    status: top?.status ?? "ok",
    notOk: nodes.filter(needsLook).length,
    unknown: nodes.filter((n) => n.status === "unknown" && !n.acknowledged && !n.maintenance).length,
    acknowledged: quiet && !!top?.acknowledged,
    maintenance: quiet && !top?.acknowledged && !!top?.maintenance,
    flapping: nodes.some((n) => n.flapping),
    types,
    classes: [...new Set(nodes.map((n) => n.class))].sort(),
    environments: [...new Set(nodes.map((n) => n.environment).filter((e): e is string => !!e))].sort(),
  };
}

// Everything under the starts, themselves too. A leaf is seen and not opened.
function walk(starts: string[], children: Map<string, TreeChild[]>): Set<string> {
  const seen = new Set(starts);
  const opened = new Set(starts);
  const stack = [...starts];
  while (stack.length) {
    for (const c of children.get(stack.pop() as string) ?? []) {
      seen.add(c.id);
      if (c.leaf || opened.has(c.id)) continue;
      opened.add(c.id);
      stack.push(c.id);
    }
  }
  return seen;
}

function buildTree(nodes: HealthNode[], edges: HealthEdge[], types: RelationType[], parent: Map<string, string | null>): TreeIndex {
  const nodeOf = new Map(nodes.map((n) => [n.id, n]));
  const tree = new Map(types.filter((t) => t.tree).map((t) => [t.name, t.tree]));
  const children = new Map<string, TreeChild[]>();
  const holders = new Map<string, string[]>();
  const nest = (holder: string, child: string, leaf: boolean): void => {
    const list = children.get(holder) ?? [];
    const had = list.find((c) => c.id === child);
    if (had) had.leaf = had.leaf && leaf;
    else list.push({ id: child, leaf });
    children.set(holder, list);
    if (!leaf) holders.set(child, [...(holders.get(child) ?? []), holder]);
  };
  for (const e of edges) {
    const t = tree.get(e.type);
    if (t === "from") nest(e.to, e.from, false);
    else if (t === "to") nest(e.from, e.to, false);
    else if (t === "both") {
      nest(e.from, e.to, true);
      nest(e.to, e.from, true);
    }
  }
  const label = (id: string): string => nodeOf.get(id)?.label ?? id;
  const byLabel = (a: string, b: string): number => label(a).localeCompare(label(b), "en", { numeric: true }) || a.localeCompare(b);
  for (const list of children.values()) list.sort((a, b) => byLabel(a.id, b.id));

  const facets: TreeIndex["facets"] = FACETS.map((f) => {
    const mine = (id: string): boolean => f.classes.some((c) => isA(nodeOf.get(id)?.class ?? "", c, parent));
    return { id: f.id, label: f.label, roots: nodes.map((n) => n.id).filter((id) => mine(id) && !(holders.get(id) ?? []).some(mine)).sort(byLabel) };
  });
  const placed = walk(facets.flatMap((f) => f.roots), children);
  const left = nodes.map((n) => n.id).filter((id) => !placed.has(id));
  const pending = new Set(left);
  const roots = left.filter((id) => !(holders.get(id) ?? []).some((h) => pending.has(h)));
  // A loop of objects holding each other has no top: its first stands for it.
  for (const id of left) if (!walk(roots, children).has(id)) roots.push(id);
  if (roots.length) facets.push({ id: ELSEWHERE.id, label: ELSEWHERE.label, roots: roots.sort(byLabel) });

  const of = (ids: Iterable<string>): HealthNode[] => [...ids].flatMap((id) => nodeOf.get(id) ?? []);
  const rollups = new Map<string, TreeRollup>();
  for (const n of nodes) rollups.set(n.id, rollupOf(of(walk([n.id], children))));
  for (const f of facets) rollups.set(f.id, rollupOf(of(walk(f.roots, children))));
  return { facets, children, rollups };
}

export interface TreeNode extends TreeRollup {
  id: string;
  class: string;
  name: string;
  label: string;
  isRoot: boolean;
  children: number; // how many to open: one level is read at a time
}

export interface HealthTree {
  generated: string;
  hasConditions: boolean;
  site: string | null;
  counts: Counts;
  roots: HealthRoot[];
  facets: TreeNode[];
}

export interface TreeMatch extends TreeNode {
  where: string; // the way down to it, as a line
}

const EMPTY_ROLLUP: TreeRollup = { status: "unknown", notOk: 0, unknown: 0, acknowledged: false, maintenance: false, flapping: false, types: {}, classes: [], environments: [] };

function facetNode(doc: HealthGraph, f: TreeIndex["facets"][number]): TreeNode {
  return { ...(doc.tree.rollups.get(f.id) ?? EMPTY_ROLLUP), id: f.id, class: "facet", name: f.id, label: f.label, isRoot: false, children: f.roots.length };
}

function treeNode(doc: HealthGraph, c: TreeChild, under: string | null): TreeNode | null {
  const n = doc.nodes.find((x) => x.id === c.id);
  if (!n) return null;
  const list = (doc.tree.children.get(c.id) ?? []).filter((x) => x.id !== under);
  return { ...(doc.tree.rollups.get(c.id) ?? EMPTY_ROLLUP), id: n.id, class: n.class, name: n.name, label: n.label, isRoot: n.isRoot, children: c.leaf ? 0 : list.length };
}

export function healthTree(doc: HealthGraph): HealthTree {
  return { generated: doc.generated, hasConditions: doc.hasConditions, site: doc.site, counts: doc.counts, roots: doc.roots, facets: doc.tree.facets.map((f) => facetNode(doc, f)) };
}

// One level: a facet's tops or an object's children. null: no such row.
export function treeChildren(doc: HealthGraph, id: string): TreeNode[] | null {
  const f = doc.tree.facets.find((x) => x.id === id);
  if (f) return f.roots.flatMap((r) => treeNode(doc, { id: r, leaf: false }, null) ?? []);
  if (TREE_FACETS.includes(id)) return [];
  if (!doc.nodes.some((n) => n.id === id)) return null;
  return (doc.tree.children.get(id) ?? []).flatMap((c) => treeNode(doc, c, id) ?? []);
}

// The first way down to an object, its facet first: what Show in tree opens.
export function treePath(doc: HealthGraph, id: string): string[] | null {
  const came = new Map<string, string>();
  for (const f of doc.tree.facets) {
    const queue = [...f.roots];
    for (const r of f.roots) if (!came.has(r)) came.set(r, f.id);
    while (queue.length) {
      const at = queue.shift() as string;
      if (at === id) {
        const path = [id];
        for (let p = came.get(id); p !== undefined; p = came.get(p)) path.unshift(p);
        return path;
      }
      for (const c of doc.tree.children.get(at) ?? []) {
        if (came.has(c.id)) continue;
        came.set(c.id, at);
        if (!c.leaf) queue.push(c.id);
        else if (c.id === id) queue.unshift(c.id);
      }
    }
  }
  return null;
}

// The tree is read a level at a time, so a search is the server's: by name or
// class, the worst first.
export function treeSearch(doc: HealthGraph, q: string, limit = 50): TreeMatch[] {
  const term = q.trim().toLowerCase();
  if (!term) return [];
  const label = new Map<string, string>([...doc.nodes.map((n): [string, string] => [n.id, n.label]), ...doc.tree.facets.map((f): [string, string] => [f.id, f.label])]);
  return doc.nodes
    .filter((n) => [n.label, n.name, n.class].some((x) => x.toLowerCase().includes(term)))
    .sort((a, b) => RANK[b.status] - RANK[a.status] || a.label.localeCompare(b.label, "en", { numeric: true }))
    .slice(0, limit)
    .flatMap((n) => {
      const t = treeNode(doc, { id: n.id, leaf: false }, null);
      return t ? [{ ...t, where: (treePath(doc, n.id) ?? []).slice(0, -1).map((id) => label.get(id) ?? id).join(" › ") }] : [];
    });
}

// ── the ego graph ─────────────────────────────────────────────────────

export interface EgoNode extends HealthNode {
  more: boolean; // it has neighbours beyond what is shown with it
}

// One relation type seen from one object: which way it is read, and on which
// side of the object it is drawn: what it needs above, what needs it below.
export interface EgoGroup {
  key: string;
  anchor: string;
  type: string;
  direction: "out" | "in";
  side: "up" | "down";
  label: string;
  neighbours: string[];
}

export interface HealthEgo {
  generated: string;
  at: string | null;
  id: string;
  center: EgoNode;
  nodes: EgoNode[]; // the neighbours
  groups: EgoGroup[];
  edges: HealthEdge[];
}

export interface PathEdge {
  id: string;
  type: string; // "derived" on a virtual one
  provider: string; // what the failure comes from
  dependant: string;
  virtual: boolean; // assess says so, no relation shows why: a relation may be missing
}

export interface HealthPath {
  generated: string;
  at: string | null;
  id: string;
  to: "root" | "impact";
  nodes: EgoNode[];
  edges: PathEdge[];
}

type Adjacent = { edge: HealthEdge; other: string; direction: "out" | "in" };

function adjacency(doc: HealthGraph): Map<string, Adjacent[]> {
  const out = new Map<string, Adjacent[]>();
  const add = (id: string, a: Adjacent): void => {
    out.set(id, [...(out.get(id) ?? []), a]);
  };
  for (const e of doc.edges) {
    add(e.from, { edge: e, other: e.to, direction: "out" });
    add(e.to, { edge: e, other: e.from, direction: "in" });
  }
  return out;
}

function sideOf(t: RelationType | undefined, direction: "out" | "in"): "up" | "down" {
  // The far end of a relation read forwards is `to`.
  const far = direction === "out" ? "to" : "from";
  const near = direction === "out" ? "from" : "to";
  if (t?.dependant === "both" || t?.tree === "both") return "down";
  if (t?.dependant) return t.dependant === near ? "up" : "down";
  if (t?.tree) return t.tree === near ? "up" : "down";
  return far === "to" ? "down" : "up";
}

function groupLabel(type: string, t: RelationType | undefined, direction: "out" | "in"): string {
  if (t?.tree === (direction === "out" ? "to" : "from")) return `contains · ${type}`;
  return direction === "out" ? type : `${type} ←`;
}

// The object and everything `depth` hops from it, grouped by relation type.
export function healthEgo(doc: HealthGraph, id: string, depth = 1): HealthEgo | null {
  const nodeOf = new Map(doc.nodes.map((n) => [n.id, n]));
  const center = nodeOf.get(id);
  if (!center) return null;
  const adj = adjacency(doc);
  const types = new Map(doc.relationTypes.map((t) => [t.name, t]));
  const shown = new Set([id]);
  const groups = new Map<string, EgoGroup>();
  const edges = new Map<string, HealthEdge>();
  let frontier = [id];
  for (let hop = 0; hop < depth && frontier.length; hop++) {
    const next: string[] = [];
    for (const anchor of frontier) {
      for (const a of adj.get(anchor) ?? []) {
        if (a.other === anchor) continue;
        const t = types.get(a.edge.type);
        const key = `${anchor}|${a.edge.type}|${a.direction}`;
        const g = groups.get(key) ?? { key, anchor, type: a.edge.type, direction: a.direction, side: sideOf(t, a.direction), label: groupLabel(a.edge.type, t, a.direction), neighbours: [] };
        if (!g.neighbours.includes(a.other)) g.neighbours.push(a.other);
        groups.set(key, g);
        edges.set(a.edge.id, a.edge);
        if (!shown.has(a.other)) {
          shown.add(a.other);
          next.push(a.other);
        }
      }
    }
    frontier = next;
  }
  const label = (x: string): string => nodeOf.get(x)?.label ?? x;
  const ego = (n: HealthNode): EgoNode => ({ ...n, more: (adj.get(n.id) ?? []).some((a) => !shown.has(a.other)) });
  const list = [...groups.values()].sort((a, b) => a.label.localeCompare(b.label));
  for (const g of list) g.neighbours.sort((a, b) => label(a).localeCompare(label(b), "en", { numeric: true }));
  return {
    generated: doc.generated,
    at: doc.at,
    id,
    center: ego(center),
    nodes: [...shown].filter((x) => x !== id).flatMap((x) => { const n = nodeOf.get(x); return n ? [ego(n)] : []; }),
    groups: list,
    edges: [...edges.values()],
  };
}

// Who fails with whom: per object, what it needs and what needs it, by the
// metamodel's dependant ends.
function dependencies(doc: HealthGraph): { needs: Map<string, HealthEdge[]>; neededBy: Map<string, HealthEdge[]> } {
  const dep = new Map(doc.relationTypes.map((t) => [t.name, t.dependant]));
  const needs = new Map<string, HealthEdge[]>();
  const neededBy = new Map<string, HealthEdge[]>();
  const link = (dependant: string, provider: string, e: HealthEdge): void => {
    needs.set(dependant, [...(needs.get(dependant) ?? []), { ...e, from: dependant, to: provider }]);
    neededBy.set(provider, [...(neededBy.get(provider) ?? []), { ...e, from: dependant, to: provider }]);
  };
  for (const e of doc.edges) {
    const d = dep.get(e.type);
    if (d === "from" || d === "both") link(e.from, e.to, e);
    if (d === "to" || d === "both") link(e.to, e.from, e);
  }
  return { needs, neededBy };
}

// The way from `start` to any of the ends, stepping only on what `step` allows;
// the relations of each way, none when there is none.
function ways(start: string, ends: Set<string>, step: (id: string) => boolean, next: (id: string) => { edge: HealthEdge; to: string }[]): Map<string, { edge: HealthEdge; from: string }[]> {
  const came = new Map<string, { edge: HealthEdge; from: string } | null>([[start, null]]);
  const queue = [start];
  const out = new Map<string, { edge: HealthEdge; from: string }[]>();
  while (queue.length) {
    const at = queue.shift() as string;
    for (const n of next(at)) {
      if (came.has(n.to) || !(step(n.to) || ends.has(n.to))) continue;
      came.set(n.to, { edge: n.edge, from: at });
      queue.push(n.to);
    }
  }
  for (const end of ends) {
    if (!came.has(end) || end === start) continue;
    const way: { edge: HealthEdge; from: string }[] = [];
    for (let c = came.get(end); c; c = came.get(c.from)) way.push(c);
    out.set(end, way);
  }
  return out;
}

// `root`: from the object up to what explains it. `impact`: from it down to
// what fails because of it. Along the relations where they show the way; where
// they do not, assess's word stands as a virtual line.
export function healthPath(doc: HealthGraph, id: string, to: "root" | "impact"): HealthPath | null {
  const nodeOf = new Map(doc.nodes.map((n) => [n.id, n]));
  const self = nodeOf.get(id);
  if (!self) return null;
  const { needs, neededBy } = dependencies(doc);
  const failing = (x: string): boolean => {
    const s = nodeOf.get(x)?.status;
    return s === "critical" || s === "warning";
  };
  const edges = new Map<string, PathEdge>();
  const shown = new Set([id]);
  const real = (e: HealthEdge): void => {
    edges.set(`${e.id}|${e.from}`, { id: e.id, type: e.type, provider: e.to, dependant: e.from, virtual: false });
    shown.add(e.from);
    shown.add(e.to);
  };
  const virtual = (provider: string, dependant: string): void => {
    edges.set(`v|${provider}|${dependant}`, { id: `v|${provider}|${dependant}`, type: "derived", provider, dependant, virtual: true });
    shown.add(provider);
    shown.add(dependant);
  };
  if (to === "root") {
    const ends = new Set(self.rootCause.filter((r) => nodeOf.has(r)));
    const found = ways(id, ends, failing, (x) => (needs.get(x) ?? []).map((e) => ({ edge: e, to: e.to })));
    for (const end of ends) {
      const way = found.get(end);
      if (way) way.forEach((w) => real(w.edge));
      else virtual(end, id);
    }
  } else {
    const roots = new Set(self.isRoot ? [id] : self.rootCause);
    const hurt = doc.nodes.filter((n) => n.id !== id && n.rootCause.some((r) => roots.has(r))).map((n) => n.id);
    const ends = new Set(hurt);
    const found = ways(id, ends, (x) => ends.has(x), (x) => (neededBy.get(x) ?? []).map((e) => ({ edge: e, to: e.from })));
    for (const end of ends) {
      const way = found.get(end);
      if (way) way.forEach((w) => real(w.edge));
      else if (self.isRoot) virtual(id, end);
    }
  }
  const adj = adjacency(doc);
  const ego = (n: HealthNode): EgoNode => ({ ...n, more: (adj.get(n.id) ?? []).some((a) => !shown.has(a.other)) });
  return {
    generated: doc.generated,
    at: doc.at,
    id,
    to,
    nodes: [...shown].flatMap((x) => { const n = nodeOf.get(x); return n ? [ego(n)] : []; }),
    edges: [...edges.values()],
  };
}

// ── what a change moved ───────────────────────────────────────────────

// Sent down the live stream: the colours and the roll-ups that moved, or, when
// the topology did, only that (the page reads again and lays out once).
export interface HealthPatch {
  topology: string;
  relayout: boolean;
  generated: string;
  patches: HealthNode[];
  rollups: Record<string, TreeRollup>;
  roots: HealthRoot[];
  counts: Counts;
  hasConditions: boolean;
}

export function diffHealth(before: HealthGraph | null, after: HealthGraph): HealthPatch | null {
  const relayout = before === null || before.topology !== after.topology;
  const old = new Map((before?.nodes ?? []).map((n) => [n.id, JSON.stringify(n)]));
  const patches = relayout ? [] : after.nodes.filter((n) => old.get(n.id) !== JSON.stringify(n));
  const rollups: Record<string, TreeRollup> = {};
  if (!relayout) for (const [id, r] of after.tree.rollups) if (JSON.stringify(before?.tree.rollups.get(id)) !== JSON.stringify(r)) rollups[id] = r;
  const sameRoots = before !== null && JSON.stringify(before.roots) === JSON.stringify(after.roots);
  if (!relayout && patches.length === 0 && sameRoots && Object.keys(rollups).length === 0) return null;
  return { topology: after.topology, relayout, generated: after.generated, patches, rollups, roots: after.roots, counts: after.counts, hasConditions: after.hasConditions };
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
  isRoot: boolean;
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
    conditions: conditions.map((c, i) => ({ ...issues[i], source: c.source ?? null, lastChecked: c.lastChecked ?? null, ack: c.acknowledged ?? null, window: c.maintenance ?? null, ...(c.quieted ? { quieted: c.quieted } : {}), ...(c.raw ? { raw: c.raw } : {}), ...(c.rule ? { rule: c.rule } : {}) })),
    drift: show.drift ?? null,
    relations: show.relations.map((r) => ({ id: String(r.id), type: r.type, direction: r.direction, other: { ...r.other, status: nodeOf.get(r.other.id)?.status ?? null } })),
    history: conditionHistory(periods),
    changes: changes.slice(-50).reverse(),
    isRoot: !!root,
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
