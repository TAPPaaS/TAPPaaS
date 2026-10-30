// healthgraph.ts — the Health view's graph as data (ADR-041 D5): which cards a
// set of open groups leaves on the page, the lines between them with both ends
// on a card, the colour of a collapsed group, what a root's focus lights, what
// the filters keep, and a live patch applied. Plain data, no React: the unit
// tests run it over the fixture site. The page lays it out once per topology.

import { HealthEdge, HealthGraph, HealthGroup, HealthNode, HealthPatch, HealthStatus, HealthView } from "./types";

export const CARD_W = 210;
export const CARD_H = 62;
const GAP = 14;
const HEAD = 34;
const INNER_COLS = 3;

const RANK: Record<HealthStatus, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

export interface Card {
  id: string;
  kind: "node" | "group" | "open"; // an object, a collapsed group, an opened one
  node: HealthNode | null;
  group: HealthGroup | null;
  members: HealthNode[];
  tier: number;
  w: number;
  h: number;
  parent?: string;
  at?: { x: number; y: number };
}

export interface Line {
  id: string;
  source: string; // the upper card: what depends
  target: string;
  types: string[];
  ids: string[]; // the relations it stands for
  from: string[]; // the objects at each end
  to: string[];
}

// A group's colour: the worst member still counting; only when nothing counts,
// the worst silenced one. Grey only when no member is judged bad.
export function rollup(members: HealthView[]): HealthView {
  const bad = members.filter((m) => m.status !== "ok");
  const counting = bad.filter((m) => !m.acknowledged && !m.maintenance);
  const pool = counting.length ? counting : bad;
  const top = [...pool].sort((a, b) => RANK[b.status] - RANK[a.status])[0];
  if (!top) return { status: "ok", type: null, reason: null, since: null, acknowledged: false, maintenance: false, flapping: false };
  const quiet = !counting.length;
  return { ...top, acknowledged: quiet && top.acknowledged, maintenance: quiet && !top.acknowledged && top.maintenance, flapping: bad.some((m) => m.flapping) };
}

export function collapse(doc: HealthGraph, open: Set<string>): { cards: Card[]; lines: Line[] } {
  const members = new Map<string, HealthNode[]>();
  for (const n of doc.nodes) if (n.group) members.set(n.group, [...(members.get(n.group) ?? []), n]);
  const cards: Card[] = [];
  const cardOf = new Map<string, string>();
  for (const n of doc.nodes) {
    if (!n.group) {
      cards.push({ id: n.id, kind: "node", node: n, group: null, members: [], tier: n.tier, w: CARD_W, h: CARD_H });
      cardOf.set(n.id, n.id);
    }
  }
  for (const g of doc.groups) {
    const ms = [...(members.get(g.id) ?? [])].sort((a, b) => b.tier - a.tier || a.label.localeCompare(b.label));
    if (!ms.length) continue;
    const tier = Math.min(...ms.map((m) => m.tier));
    if (!open.has(g.id)) {
      cards.push({ id: g.id, kind: "group", node: null, group: g, members: ms, tier, w: CARD_W, h: CARD_H });
      for (const m of ms) cardOf.set(m.id, g.id);
      continue;
    }
    const cols = Math.min(INNER_COLS, ms.length);
    const rows = Math.ceil(ms.length / cols);
    cards.push({ id: g.id, kind: "open", node: null, group: g, members: ms, tier, w: cols * (CARD_W + GAP) + GAP, h: HEAD + rows * (CARD_H + GAP) + GAP });
    ms.forEach((m, i) => {
      cards.push({ id: m.id, kind: "node", node: m, group: null, members: [], tier: m.tier, w: CARD_W, h: CARD_H, parent: g.id, at: { x: GAP + (i % cols) * (CARD_W + GAP), y: HEAD + Math.floor(i / cols) * (CARD_H + GAP) } });
      cardOf.set(m.id, m.id);
    });
  }
  const tierOf = new Map(cards.map((c) => [c.id, c.tier]));
  const lines = new Map<string, Line>();
  const put = (e: HealthEdge): void => {
    const a = cardOf.get(e.from);
    const b = cardOf.get(e.to);
    if (!a || !b || a === b) return;
    // Dagre draws a source above its target: the higher tier on top, whichever
    // end the relation is read from (a zone serves the environment above it).
    const up = (tierOf.get(a) ?? 0) >= (tierOf.get(b) ?? 0);
    const [source, target] = up ? [a, b] : [b, a];
    const key = `${source}>${target}`;
    const l = lines.get(key) ?? { id: key, source, target, types: [], ids: [], from: [], to: [] };
    if (!l.types.includes(e.type)) l.types.push(e.type);
    l.ids.push(e.id);
    l.from.push(e.from);
    l.to.push(e.to);
    lines.set(key, l);
  };
  doc.edges.forEach(put);
  return { cards, lines: [...lines.values()] };
}

// What a root lights: itself and its symptoms; no root chosen: every root's.
// null when nothing is wrong: then nothing is dimmed.
export function hotSet(doc: HealthGraph, root: string | null): Set<string> | null {
  const roots = root ? doc.roots.filter((r) => r.id === root) : doc.roots.filter((r) => !r.acknowledged);
  if (!roots.length) return null;
  return new Set(roots.flatMap((r) => [r.id, ...r.impacted]));
}

export interface Filters {
  type: string; // "" is all
  class: string;
  environment: string;
}

export const NO_FILTERS: Filters = { type: "", class: "", environment: "" };

// A filter keeps the layout: what it leaves out is dimmed, so the graph stays
// where the eye left it.
export function kept(n: HealthNode, f: Filters): boolean {
  return (!f.type || (n.types[f.type] !== undefined && n.types[f.type] !== "ok")) && (!f.class || n.class === f.class) && (!f.environment || n.environment === f.environment);
}

// The colour under a condition-type filter: that type's, not the object's.
export function viewFor(n: HealthNode, f: Filters): HealthView {
  if (!f.type) return n;
  const issues = n.issues.filter((i) => i.type === f.type);
  if (!issues.length) return { status: n.types[f.type] ?? "ok", type: f.type, reason: null, since: null, acknowledged: false, maintenance: false, flapping: false };
  return rollup(issues.map((i) => ({ status: i.status, type: i.type, reason: i.message ?? i.reason, since: i.since, acknowledged: i.acknowledged, maintenance: i.maintenance, flapping: i.flapping })));
}

export function statusClass(v: HealthView): string {
  return `hc-${v.status}${v.acknowledged ? " hc-ack" : ""}${v.maintenance ? " hc-maint" : ""}`;
}

// The group that must be open for an object to be a card of its own.
export function groupsOf(doc: HealthGraph, ids: string[]): string[] {
  const nodes = new Map(doc.nodes.map((n) => [n.id, n]));
  return [...new Set(ids.map((id) => nodes.get(id)?.group).filter((g): g is string => !!g))];
}

// The cards to centre on: the first roots, else the site's. The list is worst
// first; a site with thirty roots fitted them all and showed a strip of dots.
const CENTRED_ROOTS = 6;

export function centreCards(doc: HealthGraph, cards: Card[], root: string | null): string[] {
  const shown = new Set(cards.map((c) => c.id));
  const nodes = new Map(doc.nodes.map((n) => [n.id, n]));
  const ids = root ? [root] : doc.roots.length ? doc.roots.slice(0, CENTRED_ROOTS).map((r) => r.id) : doc.site ? [doc.site] : [];
  const out = ids.map((id) => (shown.has(id) ? id : (nodes.get(id)?.group ?? null))).filter((x): x is string => !!x && shown.has(x));
  return [...new Set(out)];
}

// What to fit: the box around those cards, never tighter than a few cards, so
// one root keeps its neighbours in view.
export function boundsOf(nodes: { id: string; position: { x: number; y: number }; parentId?: string; data: { g: { w: number; h: number } } }[], ids: string[], minW = 760, minH = 420): { x: number; y: number; width: number; height: number } | null {
  const by = new Map(nodes.map((n) => [n.id, n]));
  const boxes = ids.flatMap((id) => {
    const n = by.get(id);
    if (!n) return [];
    const p = n.parentId ? by.get(n.parentId)?.position : null;
    return [{ x: n.position.x + (p?.x ?? 0), y: n.position.y + (p?.y ?? 0), w: n.data.g.w, h: n.data.g.h }];
  });
  if (!boxes.length) return null;
  const left = Math.min(...boxes.map((b) => b.x));
  const top = Math.min(...boxes.map((b) => b.y));
  const right = Math.max(...boxes.map((b) => b.x + b.w));
  const bottom = Math.max(...boxes.map((b) => b.y + b.h));
  const width = Math.max(right - left, minW);
  const height = Math.max(bottom - top, minH);
  return { x: (left + right - width) / 2, y: (top + bottom - height) / 2, width, height };
}

export function applyPatch(doc: HealthGraph, p: HealthPatch): HealthGraph {
  const by = new Map(p.patches.map((n) => [n.id, n]));
  return { ...doc, generated: p.generated, topology: p.topology, hasConditions: p.hasConditions, nodes: doc.nodes.map((n) => by.get(n.id) ?? n), roots: p.roots, counts: p.counts };
}

// The colours of a moment over the graph of now: the layout does not move.
export function replay(doc: HealthGraph, past: HealthGraph | null): HealthGraph {
  if (!past) return doc;
  const by = new Map(past.nodes.map((n) => [n.id, n]));
  return { ...doc, nodes: doc.nodes.map((n) => by.get(n.id) ?? { ...n, status: "unknown", acknowledged: false, maintenance: false, flapping: false, reason: "not in the CMDB then", type: null, types: {}, issues: [], rootCause: [], isRoot: false }), roots: past.roots.filter((r) => doc.nodes.some((n) => n.id === r.id)), counts: past.counts };
}
