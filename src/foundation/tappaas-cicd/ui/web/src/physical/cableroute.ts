// cableroute.ts — how the rack view draws its cables: each one smooth cubic
// curve from port to port, leaving each port vertically — upward out of a
// plate's upper row or a patch panel's rear, downward out of a lower row; out
// of a plate with one row, toward the other end. The control points pull out
// of the ports by more the farther apart the ends are, and a little more for
// each further cable between the same two devices, so a bundle fans out
// instead of lying on itself; a cable to another rack or a loose device is
// one long gentle curve. Pure: the drawing (rack.tsx) and the unit tests run
// the same curves.

// A port as the layout places it: its centre and height, and its plate's box.
export interface PortAt {
  x: number;
  y: number;
  h: number;
  plateY: number;
  plateH: number;
  rack: string | null;
}
export interface WireEnds {
  a: PortAt;
  b: PortAt;
  rearA?: boolean; // the end is a patch panel port's rear
  rearB?: boolean;
  device: [string, string]; // the devices at its ends: a bundle is the cables between two
}
export interface Route {
  // The curve's ends and control points: from, its pull, the other's pull, to.
  points: [[number, number], [number, number], [number, number], [number, number]];
  d: string;
  mid: [number, number]; // halfway along the curve: where a selected cable's label goes
}

export const ROUTE = { pullMin: 18, pullMax: 170, perDy: 0.35, perDx: 0.12, fan: 7 };

// Which way a cable leaves a port: up (-1) or down (1).
export function exitOf(p: PortAt, rear: boolean, other: PortAt): 1 | -1 {
  if (rear) return -1;
  const mid = p.plateY + p.plateH / 2;
  if (p.y < mid - 2) return -1;
  if (p.y > mid + 2) return 1;
  // One row: toward the other end (down when level with it).
  return other.y < p.y - 2 ? -1 : 1;
}

const f = (n: number) => Math.round(n * 10) / 10;

// Every wire's curve; the n-th cable between the same two devices pulls a
// little further out than the one before, so the bundle fans.
export function routeCables(wires: WireEnds[]): Route[] {
  const seen = new Map<string, number>();
  return wires.map((w) => {
    const { a, b } = w;
    const pair = [...w.device].sort().join("\u0000");
    const n = seen.get(pair) ?? 0;
    seen.set(pair, n + 1);
    const da = exitOf(a, !!w.rearA, b);
    const db = exitOf(b, !!w.rearB, a);
    const dy = Math.abs(a.y - b.y);
    const dx = Math.abs(a.x - b.x);
    const pull = Math.min(ROUTE.pullMax, Math.max(ROUTE.pullMin, ROUTE.perDy * dy + ROUTE.perDx * dx)) + n * ROUTE.fan;
    const p0: [number, number] = [a.x, a.y];
    const p1: [number, number] = [a.x, a.y + da * pull];
    const p2: [number, number] = [b.x, b.y + db * pull];
    const p3: [number, number] = [b.x, b.y];
    const mid: [number, number] = [(p0[0] + 3 * p1[0] + 3 * p2[0] + p3[0]) / 8, (p0[1] + 3 * p1[1] + 3 * p2[1] + p3[1]) / 8];
    return { points: [p0, p1, p2, p3], d: `M ${f(p0[0])} ${f(p0[1])} C ${f(p1[0])} ${f(p1[1])}, ${f(p2[0])} ${f(p2[1])}, ${f(p3[0])} ${f(p3[1])}`, mid };
  });
}
