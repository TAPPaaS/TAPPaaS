// columns.ts — a graph laid out in columns, left to right (the zones by trust):
// each column as wide as its widest card; its cards ordered so the lines cross
// as little as they can (the barycenter of their neighbours, swept left to
// right and back), then spread evenly over the height of the tallest column;
// each line leaves a card's side and enters the other's, a few pixels apart
// from the other lines on the same side. Plain data, no React: the unit tests
// run it over fixtures.

export interface ColNode {
  id: string;
  w: number;
  h: number;
  col?: number;
  order?: number; // the starting row within its column (ascending), then the id
  head?: boolean; // the column's title: pinned to the top, outside the spread
  after?: string; // kept directly below this node of the same column
}

export interface ColEdge {
  source: string;
  target: string;
}

export type Side = "left" | "right";
export interface Route {
  sx: number;
  sy: number;
  ss: Side;
  tx: number;
  ty: number;
  ts: Side;
}

type Pos = Map<string, { x: number; y: number }>;

const colOf = (n: ColNode): number => n.col ?? 0;

// The starting order: by order, then the id.
function initialOrder(members: ColNode[]): ColNode[] {
  return [...members].sort((a, b) => (a.order ?? 0) - (b.order ?? 0) || a.id.localeCompare(b.id));
}

// Move each node that names `after` to just below its anchor (in the same
// column), keeping the rest of the order; one whose anchor is not there stays.
function keepAfter(list: ColNode[]): ColNode[] {
  const ids = new Set(list.map((n) => n.id));
  const out = list.filter((n) => !n.after || !ids.has(n.after));
  let pending = list.filter((n) => !out.includes(n));
  while (pending.length > 0) {
    const left = pending.filter((n) => {
      const i = out.findIndex((m) => m.id === n.after);
      if (i < 0) return true;
      out.splice(i + 1, 0, n);
      return false;
    });
    if (left.length === pending.length) return [...out, ...left]; // anchors that name each other
    pending = left;
  }
  return out;
}

// The order of each column's cards (heads excluded), from the starting order,
// improved by `sweeps` barycenter passes: left to right, right to left, and so
// on. A card's barycenter is the mean of its neighbours' relative rows (0..1)
// in the columns already swept, the nearer columns counting more; a card with
// no neighbour there keeps its place.
export function orderColumns(nodes: ColNode[], edges: ColEdge[], sweeps = 3): Map<number, ColNode[]> {
  const body = nodes.filter((n) => !n.head);
  const cols = [...new Set(body.map(colOf))].sort((a, b) => a - b);
  const order = new Map<number, ColNode[]>(cols.map((c) => [c, keepAfter(initialOrder(body.filter((n) => colOf(n) === c)))]));
  const byId = new Map(body.map((n) => [n.id, n]));
  const nbrs = new Map<string, string[]>(body.map((n) => [n.id, []]));
  for (const e of edges) {
    if (!byId.has(e.source) || !byId.has(e.target) || e.source === e.target) continue;
    nbrs.get(e.source)!.push(e.target);
    nbrs.get(e.target)!.push(e.source);
  }
  const rel = (id: string): number => {
    const list = order.get(colOf(byId.get(id)!))!;
    return (list.findIndex((n) => n.id === id) + 0.5) / list.length;
  };
  for (let s = 0; s < sweeps; s++) {
    const forward = s % 2 === 0;
    const seq = forward ? cols : [...cols].reverse();
    for (const c of seq) {
      const list = order.get(c)!;
      const bary = new Map<string, number>();
      list.forEach((n, i) => {
        let sum = 0;
        let weight = 0;
        for (const m of nbrs.get(n.id)!) {
          const mc = colOf(byId.get(m)!);
          if (forward ? mc >= c : mc <= c) continue;
          const w = 1 / Math.abs(mc - c);
          sum += w * rel(m);
          weight += w;
        }
        bary.set(n.id, weight > 0 ? sum / weight : (i + 0.5) / list.length);
      });
      const cur = new Map(list.map((n, i) => [n.id, i]));
      const sorted = [...list].sort((a, b) => bary.get(a.id)! - bary.get(b.id)! || cur.get(a.id)! - cur.get(b.id)!);
      order.set(c, keepAfter(sorted));
    }
  }
  return order;
}

// Positions: the heads in a row on top, then each column's cards in their
// order, spread over the height of the tallest column (that one with `gapY`
// between its cards): every card gets an equal share of the column's free
// height, half of it above and half below. A card kept below another stays
// `gapY` under it: the two take one share. A column with a single card (or
// pair) has nothing to spread: it moves to the mean height of its neighbours,
// so the lines that pass its column do not all run behind it.
export function columnPositions(nodes: ColNode[], edges: ColEdge[], gapX: number, gapY: number): Pos {
  const cols = [...new Set(nodes.map(colOf))].sort((a, b) => a - b);
  const order = orderColumns(nodes, edges);
  const pos: Pos = new Map();
  const headH = Math.max(0, ...nodes.filter((n) => n.head).map((n) => n.h));
  const top = 10 + (headH > 0 ? headH + gapY : 0);
  const blocks = new Map<number, ColNode[][]>();
  for (const [c, list] of order) {
    const bs: ColNode[][] = [];
    list.forEach((n, i) => (i > 0 && n.after === list[i - 1].id ? bs[bs.length - 1].push(n) : bs.push([n])));
    blocks.set(c, bs);
  }
  const blockH = (b: ColNode[]): number => b.reduce((s, n) => s + n.h, 0) + gapY * (b.length - 1);
  const height = Math.max(0, ...[...blocks.values()].map((bs) => bs.reduce((s, b) => s + blockH(b) + gapY, 0)));
  let x = 10;
  for (const c of cols) {
    const all = nodes.filter((n) => colOf(n) === c);
    const colW = Math.max(0, ...all.map((n) => n.w));
    for (const n of all.filter((m) => m.head)) pos.set(n.id, { x: x + (colW - n.w) / 2, y: 10 });
    const bs = blocks.get(c) ?? [];
    const share = bs.length ? (height - bs.reduce((s, b) => s + blockH(b), 0)) / bs.length : 0;
    let y = top + share / 2;
    for (const b of bs) {
      for (const n of b) {
        pos.set(n.id, { x: x + (colW - n.w) / 2, y });
        y += n.h + gapY;
      }
      y += share - gapY;
    }
    x += colW + gapX;
  }
  // The lone blocks, against the spread positions of their neighbours.
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const spreadY = (id: string): number => pos.get(id)!.y + byId.get(id)!.h / 2;
  const moved: [ColNode[], number][] = [];
  for (const bs of blocks.values()) {
    if (bs.length !== 1) continue;
    const ids = new Set(bs[0].map((n) => n.id));
    const nbrs = edges.flatMap((e) => (ids.has(e.source) && !ids.has(e.target) ? [e.target] : ids.has(e.target) && !ids.has(e.source) ? [e.source] : [])).filter((id) => byId.has(id) && !byId.get(id)!.head);
    if (nbrs.length === 0) continue;
    const want = nbrs.reduce((s, id) => s + spreadY(id), 0) / nbrs.length;
    moved.push([bs[0], Math.min(Math.max(want - bs[0][0].h / 2, top), top + height - gapY - blockH(bs[0]))]);
  }
  for (const [b, y0] of moved) {
    let y = y0;
    for (const n of b) {
      pos.set(n.id, { x: pos.get(n.id)!.x, y });
      y += n.h + gapY;
    }
  }
  return pos;
}

// Where each line starts and ends. Forward (to a column on the right): from
// the source's right side into the target's left. Backward: from the left into
// the right. Within a column: right side to right side. The lines on one side
// of a card are spread `step` pixels apart around its middle, in the order of
// the cards at their other ends, so parallel lines do not overlap.
export function routeEdges(nodes: ColNode[], pos: Pos, edges: ColEdge[], step = 7): Route[] {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  type End = { edge: number; node: string; side: Side; other: number };
  const ends: End[] = [];
  const sides = edges.map((e) => {
    const sc = colOf(byId.get(e.source)!);
    const tc = colOf(byId.get(e.target)!);
    const ss: Side = tc >= sc ? "right" : "left";
    const ts: Side = tc > sc ? "left" : "right";
    return { ss, ts };
  });
  const midY = (id: string): number => pos.get(id)!.y + byId.get(id)!.h / 2;
  edges.forEach((e, i) => {
    ends.push({ edge: i, node: e.source, side: sides[i].ss, other: midY(e.target) });
    ends.push({ edge: i, node: e.target, side: sides[i].ts, other: midY(e.source) });
  });
  const offset = new Map<string, number>(); // `${edge}:${node}` → dy
  const groups = new Map<string, End[]>();
  for (const end of ends) {
    const k = `${end.node}|${end.side}`;
    groups.set(k, [...(groups.get(k) ?? []), end]);
  }
  for (const list of groups.values()) {
    const h = byId.get(list[0].node)!.h;
    const room = Math.min(step, (h - 12) / Math.max(1, list.length - 1));
    list.sort((a, b) => a.other - b.other || a.edge - b.edge);
    list.forEach((end, k) => offset.set(`${end.edge}:${end.node}|${end.side}`, (k - (list.length - 1) / 2) * room));
  }
  return edges.map((e, i) => {
    const s = byId.get(e.source)!;
    const t = byId.get(e.target)!;
    const sp = pos.get(e.source)!;
    const tp = pos.get(e.target)!;
    const { ss, ts } = sides[i];
    return {
      sx: ss === "right" ? sp.x + s.w : sp.x,
      sy: sp.y + s.h / 2 + (offset.get(`${i}:${e.source}|${ss}`) ?? 0),
      ss,
      tx: ts === "left" ? tp.x : tp.x + t.w,
      ty: tp.y + t.h / 2 + (offset.get(`${i}:${e.target}|${ts}`) ?? 0),
      ts,
    };
  });
}
