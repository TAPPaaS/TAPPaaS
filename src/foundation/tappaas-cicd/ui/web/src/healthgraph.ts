// healthgraph.ts — the Health view's ego graph as data (ADR-041 D5): the cards
// and lines of what is open around one object, an expansion and its fold, what
// the filters keep in the graph and the tree, and a live patch applied. Plain
// data, no React: the unit tests run it over the fixture site. The page lays it
// out once per shape.

import { EgoGroup, EgoNode, HealthEgo, HealthNode, HealthPatch, HealthPath, HealthStatus, HealthView, TreeNode, TreeRollup } from "./types";

export const CARD_W = 210;
export const CARD_H = 62;
export const PILL_W = 200;
export const PILL_H = 36;

// A group this big stands folded: its pill and what in it needs a look.
export const BIG_GROUP = 8;

const RANK: Record<HealthStatus, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

// The object in the middle and what has been expanded from it.
export interface Anchor {
  id: string;
  parent: string | null;
}

export interface EgoState {
  center: string;
  anchors: Anchor[];
  reads: Map<string, HealthEgo>;
  paths: HealthPath[];
  openGroups: Set<string>;
}

export interface Card {
  id: string;
  kind: "node" | "group";
  node: EgoNode | null;
  group: EgoGroup | null;
  members: EgoNode[]; // a group's, those not drawn elsewhere
  folded: number; // of those, how many the pill stands for
  via: string | null; // the anchor it was drawn from
  plus: boolean;
  minus: boolean;
  w: number;
  h: number;
}

export interface Line {
  id: string;
  source: string; // the upper card: what is needed
  target: string;
  label: string | null;
  strong: boolean; // a chain of the derivation
  dashed: boolean; // assess's word, no relation shows it
}

export function expand(anchors: Anchor[], id: string, parent: string): Anchor[] {
  return anchors.some((a) => a.id === id) ? anchors : [...anchors, { id, parent }];
}

// Folding takes what was expanded through it along.
export function fold(anchors: Anchor[], id: string): Anchor[] {
  const gone = new Set([id]);
  for (const a of anchors) if (a.parent !== null && gone.has(a.parent)) gone.add(a.id);
  return anchors.filter((a) => !gone.has(a.id));
}

const needsLook = (n: EgoNode): boolean => (n.status === "critical" || n.status === "warning") && !n.acknowledged && !n.maintenance;

export function egoCards(s: EgoState): { cards: Card[]; lines: Line[] } {
  const nodes = new Map<string, EgoNode>();
  const center = s.reads.get(s.center)?.center;
  for (const p of s.paths) for (const n of p.nodes) nodes.set(n.id, n);
  for (const a of s.anchors) {
    const r = s.reads.get(a.id);
    for (const n of r?.nodes ?? []) nodes.set(n.id, n);
    if (r) nodes.set(r.center.id, r.center);
  }
  if (center) nodes.set(center.id, center);

  const placed = new Set<string>(center ? [center.id] : []);
  const via = new Map<string, string>();
  const lines = new Map<string, Line>();
  const groups: Card[] = [];
  const line = (l: Line): void => {
    if (!lines.has(l.id)) lines.set(l.id, l);
  };
  const joined = (a: string, b: string): boolean => lines.has(`${a}>${b}`) || lines.has(`${b}>${a}`);
  for (const p of s.paths) {
    for (const e of p.edges) {
      placed.add(e.provider);
      placed.add(e.dependant);
      line({ id: `${e.provider}>${e.dependant}`, source: e.provider, target: e.dependant, label: e.virtual ? null : e.type, strong: true, dashed: e.virtual });
    }
    for (const n of p.nodes) placed.add(n.id);
  }
  for (const a of s.anchors) {
    if (!placed.has(a.id)) continue;
    for (const g of s.reads.get(a.id)?.groups.filter((x) => x.anchor === a.id) ?? []) {
      // A neighbour by two relations stands under both pills.
      const fresh = g.neighbours.filter((n) => !placed.has(n) || via.get(n) === a.id);
      const known = g.neighbours.filter((n) => !fresh.includes(n) && n !== a.parent && n !== a.id);
      const members = fresh.flatMap((n) => nodes.get(n) ?? []);
      const pill = `g:${g.key}`;
      const closed = members.length > BIG_GROUP && !s.openGroups.has(g.key);
      if (members.length) {
        const drawn = closed ? members.filter(needsLook) : members;
        groups.push({ id: pill, kind: "group", node: null, group: g, members, folded: members.length - drawn.length, via: a.id, plus: false, minus: false, w: PILL_W, h: PILL_H });
        const [top, bottom] = g.side === "up" ? [pill, a.id] : [a.id, pill];
        line({ id: `${top}>${bottom}`, source: top, target: bottom, label: null, strong: false, dashed: false });
        for (const m of drawn) {
          placed.add(m.id);
          via.set(m.id, a.id);
          const [t, b] = g.side === "up" ? [m.id, pill] : [pill, m.id];
          line({ id: `${t}>${b}`, source: t, target: b, label: null, strong: false, dashed: false });
        }
      }
      for (const n of known) {
        if (joined(a.id, n)) continue;
        const [t, b] = g.side === "up" ? [n, a.id] : [a.id, n];
        line({ id: `${t}>${b}`, source: t, target: b, label: g.type, strong: false, dashed: false });
      }
    }
  }
  const open = new Set(s.anchors.map((a) => a.id));
  const cards: Card[] = [...placed].flatMap((id) => {
    const n = nodes.get(id);
    if (!n) return [];
    return [{ id, kind: "node" as const, node: n, group: null, members: [], folded: 0, via: via.get(id) ?? (id === s.center ? null : s.center), plus: n.more && !open.has(id), minus: open.has(id) && id !== s.center, w: CARD_W, h: CARD_H }];
  });
  const ids = new Set([...cards, ...groups].map((c) => c.id));
  return { cards: [...cards, ...groups], lines: [...lines.values()].filter((l) => ids.has(l.source) && ids.has(l.target)) };
}

// What moves a card: the layout is computed once per value of this.
export function shapeOf(cards: Card[], lines: Line[]): string {
  return JSON.stringify([cards.map((c) => c.id).sort(), lines.map((l) => l.id).sort()]);
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

// In the tree: a row stays lit when anything under it is kept.
export function keptRollup(r: TreeRollup, f: Filters): boolean {
  return (!f.type || (r.types[f.type] !== undefined && r.types[f.type] !== "ok")) && (!f.class || r.classes.includes(f.class)) && (!f.environment || r.environments.includes(f.environment));
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

// What to fit: the box around every card, never tighter than a few cards, so
// one object alone is not blown up to fill the pane.
export function boundsOf(nodes: { position: { x: number; y: number }; data: { g: { w: number; h: number } } }[], minW = 560, minH = 320): { x: number; y: number; width: number; height: number } | null {
  if (!nodes.length) return null;
  const left = Math.min(...nodes.map((n) => n.position.x));
  const top = Math.min(...nodes.map((n) => n.position.y));
  const right = Math.max(...nodes.map((n) => n.position.x + n.data.g.w));
  const bottom = Math.max(...nodes.map((n) => n.position.y + n.data.g.h));
  const width = Math.max(right - left, minW);
  const height = Math.max(bottom - top, minH);
  return { x: (left + right - width) / 2, y: (top + bottom - height) / 2, width, height };
}

// A wide rank wraps into rows. dagre puts every card of a rank on one line, so
// an object with many neighbours lays out far wider than tall and the fit
// shrinks it to a strip. Each rank is cut into rows of at most k cards, k the
// one that lets the whole fit the canvas at the largest scale; a rank of k or
// fewer keeps dagre's places, a wrapped one is centred where it stood. Returns
// the cards that move, none when no wrap does better.
export interface Placed { id: string; x: number; y: number; w: number; h: number }

export function wrapRanks(boxes: Placed[], view: { width: number; height: number }, gapX: number, gapY: number, maxZoom = 1.25): Map<string, { x: number; y: number }> {
  const moved = new Map<string, { x: number; y: number }>();
  if (!boxes.length || view.width <= 0 || view.height <= 0) return moved;
  const byRank = new Map<number, Placed[]>();
  for (const b of boxes) {
    const k = Math.round(b.y + b.h / 2);
    byRank.set(k, [...(byRank.get(k) ?? []), b]);
  }
  const ranks = [...byRank.entries()].sort((a, b) => a[0] - b[0]).map(([, r]) => [...r].sort((a, b) => a.x - b.x));
  const span = (r: Placed[]): number => Math.max(...r.map((b) => b.x + b.w)) - Math.min(...r.map((b) => b.x));
  const packed = (r: Placed[]): number => r.reduce((s, b) => s + b.w, 0) + gapX * (r.length - 1);
  const rowsOf = (r: Placed[], k: number): Placed[][] => Array.from({ length: Math.ceil(r.length / k) }, (_, i) => r.slice(i * k, i * k + k));
  const heightOf = (r: Placed[]): number => Math.max(...r.map((b) => b.h));
  const widest = Math.max(...ranks.map((r) => r.length));
  const size = (k: number): { w: number; h: number } => {
    let w = 0;
    let h = 0;
    for (const r of ranks) {
      const rows = r.length > k ? rowsOf(r, k) : [r];
      w = Math.max(w, r.length > k ? Math.max(...rows.map(packed)) : span(r));
      h += rows.length * heightOf(r) + (rows.length - 1) * gapX;
    }
    return { w, h: h + gapY * (ranks.length - 1) };
  };
  const scale = (k: number): number => {
    const z = size(k);
    return Math.min(view.width / z.w, view.height / z.h, maxZoom);
  };
  let best = widest;
  for (let k = widest - 1; k >= 1; k--) if (scale(k) > scale(best) * 1.05) best = k;
  if (best === widest) return moved;
  // Ranks top to bottom, each as tall as its rows; dagre's x where nothing wraps.
  let y = Math.min(...boxes.map((b) => b.y));
  for (const r of ranks) {
    const rh = heightOf(r);
    if (r.length <= best) {
      for (const b of r) moved.set(b.id, { x: b.x, y: y + (rh - b.h) / 2 });
      y += rh + gapY;
      continue;
    }
    const mid = Math.min(...r.map((b) => b.x)) + span(r) / 2;
    for (const row of rowsOf(r, best)) {
      let x = mid - packed(row) / 2;
      for (const b of row) {
        moved.set(b.id, { x, y: y + (rh - b.h) / 2 });
        x += b.w + gapX;
      }
      y += rh + gapX;
    }
    y += gapY - gapX;
  }
  return moved;
}

// The stream's colours over what is shown; a card never moves for one.
function patched(n: EgoNode, by: Map<string, HealthNode>): EgoNode {
  const p = by.get(n.id);
  return p ? { ...p, more: n.more } : n;
}

export function patchEgo(reads: Map<string, HealthEgo>, p: HealthPatch): Map<string, HealthEgo> {
  const by = new Map(p.patches.map((n) => [n.id, n]));
  return new Map([...reads].map(([id, r]) => [id, { ...r, generated: p.generated, center: patched(r.center, by), nodes: r.nodes.map((n) => patched(n, by)) }]));
}

export function patchPaths(paths: HealthPath[], p: HealthPatch): HealthPath[] {
  const by = new Map(p.patches.map((n) => [n.id, n]));
  return paths.map((x) => ({ ...x, nodes: x.nodes.map((n) => patched(n, by)) }));
}

export function patchRows(rows: TreeNode[], rollups: Record<string, TreeRollup>): TreeNode[] {
  return rows.map((r) => (rollups[r.id] ? { ...r, ...rollups[r.id] } : r));
}
