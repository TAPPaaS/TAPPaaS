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

// A pill and the cards it stands for. A neighbour by two relations belongs to
// the first of its pills; the other keeps its line to it.
export interface Hub {
  id: string;
  anchor: string;
  up: boolean;
  members: string[];
}

export function hubsOf(cards: Card[], lines: Line[]): Hub[] {
  const seen = new Set<string>();
  return cards.flatMap((c) => {
    if (!c.group || !c.via) return [];
    const up = c.group.side === "up";
    const ends = lines.filter((l) => (up ? l.target === c.id : l.source === c.id)).map((l) => (up ? l.source : l.target));
    const members = ends.filter((m) => !seen.has(m));
    for (const m of members) seen.add(m);
    return [{ id: c.id, anchor: c.via, up, members }];
  });
}

// A wide rank wraps into rows. dagre puts every card of a rank on one line, so
// an object with many neighbours lays out far wider than tall and the fit
// shrinks it to a strip. Each rank is cut into rows of at most k cards, k the
// one that lets the whole fit the canvas at the largest scale; a rank of k or
// fewer keeps dagre's places, a wrapped one is centred where it stood. A hub's
// members are a block of their own and wrap alone. Hubs on the same side of an
// anchor stand side by side, each centred on its members, the lot centred on
// the anchor; a lone hub keeps dagre's place. Returns the cards that move, none
// when no wrap does better and no hubs share a side.
export interface Placed { id: string; x: number; y: number; w: number; h: number }

export function wrapRanks(boxes: Placed[], view: { width: number; height: number }, gapX: number, gapY: number, maxZoom = 1.25, hubs: Hub[] = []): Map<string, { x: number; y: number }> {
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
  const rowsOf = (r: Placed[], k: number): Placed[][] => (r.length > k ? Array.from({ length: Math.ceil(r.length / k) }, (_, i) => r.slice(i * k, i * k + k)) : [r]);
  const heightOf = (r: Placed[]): number => Math.max(...r.map((b) => b.h));

  // What stands together: a hub's members on the rank next to it, and in each
  // rank whatever no hub claims. Clusters keep twice the cards' gap between them.
  const box = new Map(boxes.map((b) => [b.id, b]));
  const rankOf = new Map(ranks.flatMap((r, i) => r.map((b) => [b.id, i] as const)));
  const live = hubs.filter((h) => box.has(h.id) && box.has(h.anchor));
  const own = new Map(live.map((h) => [h.id, h.members.flatMap((m) => box.get(m) ?? []).filter((b) => rankOf.get(b.id) === rankOf.get(h.id)! + (h.up ? -1 : 1)).sort((a, b) => a.x - b.x)]));
  const sides = new Map<string, Hub[]>();
  for (const h of live) sides.set(`${h.anchor}|${h.up}`, [...(sides.get(`${h.anchor}|${h.up}`) ?? []), h]);
  const shared = (h: Hub): boolean => sides.get(`${h.anchor}|${h.up}`)!.length > 1;
  const held = new Set([...live.map((h) => h.id), ...[...own.values()].flat().map((b) => b.id)]);
  const blocks: { cards: Placed[]; tight: boolean }[][] = ranks.map((r) => (r.some((b) => !held.has(b.id)) ? [{ cards: r.filter((b) => !held.has(b.id)), tight: false }] : []));
  for (const h of live) {
    const cards = own.get(h.id)!;
    if (cards.length) blocks[rankOf.get(cards[0].id)!].push({ cards, tight: shared(h) });
  }
  const sep = gapX * 2;
  const widthOf = (b: { cards: Placed[]; tight: boolean }, k: number): number => (b.cards.length > k ? Math.max(...rowsOf(b.cards, k).map(packed)) : b.tight ? packed(b.cards) : span(b.cards));
  const rowCount = (i: number, k: number): number => Math.max(1, ...blocks[i].map((b) => rowsOf(b.cards, k).length));

  const widest = Math.max(1, ...blocks.flat().map((b) => b.cards.length));
  const size = (k: number): { w: number; h: number } => {
    let w = 0;
    let h = 0;
    ranks.forEach((r, i) => {
      const rows = rowCount(i, k);
      w = Math.max(w, blocks[i].reduce((s, b) => s + widthOf(b, k) + sep, -sep));
      h += rows * heightOf(r) + (rows - 1) * gapX;
    });
    return { w, h: h + gapY * (ranks.length - 1) };
  };
  const scale = (k: number): number => {
    const z = size(k);
    return Math.min(view.width / z.w, view.height / z.h, maxZoom);
  };
  let best = widest;
  for (let k = widest - 1; k >= 1; k--) if (scale(k) > scale(best) * 1.05) best = k;
  if (best === widest && !live.some(shared)) return moved;

  // Ranks top to bottom, each as tall as its rows; dagre's x where nothing wraps.
  const tops: number[] = [];
  let y = Math.min(...boxes.map((b) => b.y));
  ranks.forEach((r, i) => {
    tops.push(y);
    y += rowCount(i, best) * (heightOf(r) + gapX) - gapX + gapY;
  });
  const put = (b: Placed, x: number, row: number): void => {
    const i = rankOf.get(b.id)!;
    const rh = heightOf(ranks[i]);
    moved.set(b.id, { x, y: tops[i] + row * (rh + gapX) + (rh - b.h) / 2 });
  };
  // A block's rows; a short one sits on the rows nearest its hub.
  const lay = (cards: Placed[], at: number | null, dx: number, up: boolean): void => {
    if (!cards.length) return;
    const rows = rowsOf(cards, best);
    const skip = up ? rowCount(rankOf.get(cards[0].id)!, best) - rows.length : 0;
    const mid = at ?? Math.min(...cards.map((b) => b.x)) + span(cards) / 2 + dx;
    rows.forEach((row, i) => {
      let x = mid - packed(row) / 2;
      for (const b of row) {
        put(b, at === null && rows.length === 1 ? b.x + dx : x, skip + i);
        x += b.w + gapX;
      }
    });
  };
  for (const r of ranks) lay(r.filter((b) => !held.has(b.id)), null, 0, false);
  // Anchors in the order they were opened: what a hub hangs from has its place.
  for (const side of sides.values()) {
    const { anchor, up } = side[0];
    const a = box.get(anchor)!;
    const ax = moved.get(anchor)?.x ?? a.x;
    const dx = ax - a.x;
    const edge = (h: Hub): number => (up ? rowCount(rankOf.get(h.id)!, best) - 1 : 0);
    if (side.length === 1) {
      const hub = box.get(side[0].id)!;
      put(hub, hub.x + dx, edge(side[0]));
      lay(own.get(side[0].id)!, null, dx, up);
      continue;
    }
    const clusters = [...side].sort((p, q) => box.get(p.id)!.x - box.get(q.id)!.x).map((h) => {
      const cards = own.get(h.id)!;
      const hub = box.get(h.id)!;
      return { h, hub, cards, w: Math.max(hub.w, cards.length ? widthOf({ cards, tight: true }, best) : 0) };
    });
    let x = ax + a.w / 2 - (clusters.reduce((s, c) => s + c.w + sep, -sep)) / 2;
    for (const c of clusters) {
      const mid = x + c.w / 2;
      put(c.hub, mid - c.hub.w / 2, edge(c.h));
      lay(c.cards, mid, 0, up);
      x += c.w + sep;
    }
  }

  // Clusters of two anchors can meet on a row: pushed apart, the selected card
  // (the first anchor) stays, else the row keeps its middle.
  const rows = new Map<number, { id: string; b: Placed }[]>();
  for (const [id, m] of moved) {
    const b = box.get(id)!;
    const k = Math.round(m.y + b.h / 2);
    rows.set(k, [...(rows.get(k) ?? []), { id, b }]);
  }
  for (const row of rows.values()) {
    row.sort((p, q) => moved.get(p.id)!.x - moved.get(q.id)!.x);
    let end = -Infinity;
    const pushed = new Map<string, number>();
    for (const { id, b } of row) {
      const m = moved.get(id)!;
      pushed.set(id, m.x < end ? end + gapX - m.x : 0);
      end = m.x + pushed.get(id)! + b.w;
      if (pushed.get(id)) moved.set(id, { ...m, x: m.x + pushed.get(id)! });
    }
    const last = pushed.get(row[row.length - 1].id)!;
    const back = pushed.get(live[0]?.anchor) ?? last / 2;
    if (back) for (const { id } of row) moved.set(id, { ...moved.get(id)!, x: moved.get(id)!.x - back });
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
