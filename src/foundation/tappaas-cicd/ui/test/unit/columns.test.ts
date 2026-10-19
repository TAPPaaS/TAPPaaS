// columns.test.ts — the column layout (web/src/columns.ts): the barycenter
// order of each column, the spread over the tallest column's height, and
// where each line leaves and enters, over hrossen's zones
// (test/fixtures/zones.json) as the zones graph draws them.

import { readFileSync } from "fs";
import { join } from "path";
import { ColEdge, ColNode, columnPositions, orderColumns, routeEdges } from "../../web/src/columns";
import { ZoneLike, pseudoPlace, zoneColumn, zoneEdges } from "../../web/src/zonegraph";
import { check, done } from "./check";

const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";
const zones = JSON.parse(readFileSync(join(FIX, "zones.json"), "utf8")) as ZoneLike[];

// The zones graph's cards and lines, as Zones.tsx builds them.
const { edges, pseudo } = zoneEdges(zones);
const nodes: ColNode[] = [
  ...zones.map((z) => ({ id: z.name, w: 190, h: 74, col: zoneColumn(z), order: z.vlantag ?? 0 })),
  ...pseudo.map((p) => ({ id: p, w: 130, h: 44, ...pseudoPlace(p, zones) })),
];
for (const c of new Set(nodes.map((n) => n.col))) nodes.push({ id: `col-${c}`, w: 190, h: 22, col: c, head: true });
const byId = new Map(nodes.map((n) => [n.id, n]));

// Lines that cross: two lines between the same pair of columns whose ends
// swap order. Counted over the rows of a given order.
function crossings(order: Map<number, ColNode[]>, list: ColEdge[]): number {
  const row = (id: string): number => order.get(byIdOf(id).col ?? 0)!.findIndex((n) => n.id === id);
  let n = 0;
  for (let i = 0; i < list.length; i++)
    for (let j = i + 1; j < list.length; j++) {
      const [e, f] = [list[i], list[j]];
      if (byIdOf(e.source).col !== byIdOf(f.source).col || byIdOf(e.target).col !== byIdOf(f.target).col) continue;
      if ((row(e.source) - row(f.source)) * (row(e.target) - row(f.target)) < 0) n++;
    }
  return n;
}
let byIdOf = (id: string): ColNode => byId.get(id)!;

// The barycenter order.
const start = orderColumns(nodes, edges, 0);
const swept = orderColumns(nodes, edges);
check([...swept.values()].every((l) => l.every((n) => !n.head)), "the heads are not in the order");
check(crossings(swept, edges) <= crossings(start, edges), `no more crossings than the starting order (${crossings(start, edges)} → ${crossings(swept, edges)})`);
check([...swept.keys()].every((c) => swept.get(c)!.length === start.get(c)!.length), "every card keeps its column");

// A column whose starting order crosses: a→y and b→x, with x above y.
const small: ColNode[] = [
  { id: "a", w: 10, h: 10, col: 0, order: 0 },
  { id: "b", w: 10, h: 10, col: 0, order: 1 },
  { id: "x", w: 10, h: 10, col: 1, order: 0 },
  { id: "y", w: 10, h: 10, col: 1, order: 1 },
  { id: "z", w: 10, h: 10, col: 2, order: 0 },
];
const smallEdges = [{ source: "a", target: "y" }, { source: "b", target: "x" }, { source: "z", target: "b" }];
const keep = byIdOf;
byIdOf = (id) => small.find((n) => n.id === id)!;
const so = orderColumns(small, smallEdges);
check(so.get(1)!.map((n) => n.id).join() === "y,x" && crossings(so, smallEdges) === 0, "a crossing pair is untangled (y above x)");
check(orderColumns(small, smallEdges, 0).get(1)!.map((n) => n.id).join() === "x,y", "no sweeps: the starting order (order, then id)");
byIdOf = keep;

// A card kept below another: every zone directly below mgmt, through every sweep.
const tier0 = swept.get(1)!.map((n) => n.id);
check(tier0.indexOf("all") === tier0.indexOf("mgmt") + 1, `every zone sits directly below mgmt (${tier0.join(", ")})`);
const chain = orderColumns([{ id: "c", w: 1, h: 1, after: "b" }, { id: "b", w: 1, h: 1, after: "a" }, { id: "a", w: 1, h: 1 }, { id: "d", w: 1, h: 1, after: "nowhere" }], []);
check(chain.get(0)!.map((n) => n.id).join() === "a,b,c,d", "a chain of cards kept below each other; a missing anchor leaves the card where it is");

// The spread.
const gapY = 18;
const pos = columnPositions(nodes, edges, 70, gapY);
const heads = nodes.filter((n) => n.head);
check(heads.every((h) => pos.get(h.id)!.y === 10), "the column titles stay on top");
const top = 10 + 22 + gapY;
const cols = [...swept.keys()];
const height = Math.max(...cols.map((c) => swept.get(c)!.reduce((s, n) => s + n.h + gapY, 0)));
const tallest = cols.find((c) => swept.get(c)!.reduce((s, n) => s + n.h + gapY, 0) === height)!;
const ys = (c: number): { y: number; h: number }[] => swept.get(c)!.map((n) => ({ y: pos.get(n.id)!.y, h: n.h }));
const gaps = (c: number): number[] => ys(c).slice(1).map((r, i) => r.y - (ys(c)[i].y + ys(c)[i].h));
check(gaps(tallest).every((g) => Math.abs(g - gapY) < 1e-6), "the tallest column: the minimum gap between its cards");
check(cols.every((c) => ys(c).every((r) => r.y >= top - 1e-6 && r.y + r.h <= top + height + 1e-6)), "every card within the tallest column's height");
const spread = (c: number): number[] => gaps(c).filter((_, i) => swept.get(c)![i + 1].after !== swept.get(c)![i].id);
check(cols.every((c) => gaps(c).every((g) => g >= gapY - 1e-6) && spread(c).every((g) => Math.abs(g - spread(c)[0]) < 1e-6)), "each column evenly spread, never closer than the minimum gap");
check(pos.get("all")!.y === pos.get("mgmt")!.y + 74 + gapY, "every zone stays right under mgmt (the minimum gap), not spread away");
// A lone card: at the mean height of its neighbours (as they were spread),
// so the DMZ is not in the way of every line into the WAN card.
const dmzY = pos.get("dmz")!.y + 37;
const wanY = pos.get("wan")!.y + 37;
check(swept.get(5)!.length === 1 && swept.get(6)!.length === 1, "the DMZ and the WAN are alone in their columns");
check(Math.abs(dmzY - wanY) > 37, `the DMZ card is not level with the WAN card (${Math.round(dmzY)} vs ${Math.round(wanY)})`);
check(cols.every((c) => ys(c).every((r) => r.y >= top - 1e-6 && r.y + r.h <= top + height + 1e-6)), "…and every card still within the height");
check(cols.every((c) => new Set(swept.get(c)!.map((n) => pos.get(n.id)!.x + n.w / 2)).size === 1), "a column's cards share its centre line");

// Where the lines leave and enter.
const routes = routeEdges(nodes, pos, edges);
const at = (s: string, t: string) => routes[edges.findIndex((e) => e.source === s && e.target === t)];
const mgmtWan = at("mgmt", "wan");
check(mgmtWan.ss === "right" && mgmtWan.ts === "left" && mgmtWan.sx === pos.get("mgmt")!.x + 190 && mgmtWan.tx === pos.get("wan")!.x, "forward: from the right side into the left");
const pin = at("wan", "dmz");
check(pin.ss === "left" && pin.ts === "right" && pin.tx === pos.get("dmz")!.x + 190, "backward (a pinhole from the internet): from the left into the right");
const intoWan = routes.filter((r, i) => edges[i].target === "wan" && r.ts === "left");
const wanTop = pos.get("wan")!.y;
check(intoWan.length >= 8 && new Set(intoWan.map((r) => r.ty)).size === intoWan.length, "the lines into the WAN card enter at distinct heights");
check(intoWan.every((r) => r.ty > wanTop + 5 && r.ty < wanTop + 74 - 5), "…all within the card");
const mid = (id: string): number => pos.get(id)!.y + byId.get(id)!.h / 2;
const ins = edges.map((e, i) => ({ src: mid(e.source), r: routes[i], e })).filter((x) => x.e.target === "wan" && x.r.ts === "left");
check(ins.every((p) => ins.every((q) => !(p.src < q.src) || p.r.ty < q.r.ty)), "…in the order of their sources' heights, so they do not cross at the card");
const one = routeEdges(small, columnPositions(small, smallEdges, 20, 10), [{ source: "a", target: "y" }]);
check(one[0].sy === columnPositions(small, smallEdges, 20, 10).get("a")!.y + 5, "a single line leaves from the middle of the side");

done("columns");
