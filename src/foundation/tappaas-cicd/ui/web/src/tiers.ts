// tiers.ts — a dagre layout pressed into rows: the Health view's dependency
// order, the planes at the bottom and the site on top, whatever the edges did
// to the ranks. dagre chooses each card's place along its row, so the lines stay
// as uncrossed as it could make them; a row is then swept for overlaps and
// recentred. Plain data, no React: the unit tests run it over fixtures.

export interface TierNode {
  id: string;
  w: number;
  h: number;
  tier: number; // 0 is the bottom row
  x: number; // dagre's centre
}

export function tierPositions(nodes: TierNode[], gapX: number, gapY: number): Map<string, { x: number; y: number }> {
  const rows = new Map<number, TierNode[]>();
  for (const n of nodes) rows.set(n.tier, [...(rows.get(n.tier) ?? []), n]);
  const pos = new Map<string, { x: number; y: number }>();
  let y = 0;
  for (const tier of [...rows.keys()].sort((a, b) => b - a)) {
    const row = [...(rows.get(tier) ?? [])].sort((a, b) => a.x - b.x || a.id.localeCompare(b.id));
    let right = -Infinity;
    const left = row.map((n) => {
      const l = Math.max(n.x - n.w / 2, right + gapX);
      right = l + n.w;
      return l;
    });
    // The sweep only pushes right: give the row back what it drifted.
    const drift = row.reduce((s, n, i) => s + (left[i] - (n.x - n.w / 2)), 0) / row.length;
    row.forEach((n, i) => pos.set(n.id, { x: left[i] - drift, y }));
    y += Math.max(...row.map((n) => n.h)) + gapY;
  }
  return pos;
}
