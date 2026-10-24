// cableroute.ts — how the rack view runs its cables: a short straight stub out
// of each port (down, or up from a plate's upper row and from a patch panel's
// rear), then straight lines that bend only in a gutter beside the rack, the
// way cable management runs them. Two ports on one plate row are joined under
// the plate; two ports one above the other, straight; a loose device in the
// room, or a device beside the racks, is reached from the rack's gutter on
// its side. Each cable has its own lane in a gutter and its own stub depth at
// a plate, so parallel cables never lie on each other. Pure: the drawing
// (rack.tsx) and the unit tests run the same routes.

// A port as the layout places it: its centre and height, its plate's box, and
// its rack's frame (a device in no rack: its own plate's box).
export interface PortAt {
  x: number;
  y: number;
  h: number;
  plateY: number;
  plateH: number;
  rack: string | null;
  rackLeft: number;
  rackRight: number;
}
export interface WireEnds {
  a: PortAt;
  b: PortAt;
  rearA?: boolean; // the end is a patch panel port's rear
  rearB?: boolean;
  device: [string, string]; // the devices at its ends, for the stub depths
}
export interface Route {
  points: [number, number][];
  d: string;
}

export const ROUTE = { gutter: 9, lane: 4.5, stub: 4, step: 2.2, maxSteps: 9, radius: 4 };

type Side = "left" | "right";
// The stub's direction: up out of a plate's upper row or a panel's rear, else down.
const dirOf = (p: PortAt, rear: boolean): 1 | -1 => (rear || p.y < p.plateY + p.plateH / 2 - 2 ? -1 : 1);
const centre = (p: PortAt) => (p.rackLeft + p.rackRight) / 2;

// The path through the points, its corners rounded.
export function pathOf(points: [number, number][], r = ROUTE.radius): string {
  const pts = points.filter((p, i) => i === 0 || Math.abs(p[0] - points[i - 1][0]) > 0.01 || Math.abs(p[1] - points[i - 1][1]) > 0.01);
  if (pts.length < 2) return "";
  const f = (n: number) => Math.round(n * 10) / 10;
  let d = `M ${f(pts[0][0])} ${f(pts[0][1])}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const [px, py] = pts[i - 1];
    const [x, y] = pts[i];
    const [nx, ny] = pts[i + 1];
    const l1 = Math.hypot(x - px, y - py);
    const l2 = Math.hypot(nx - x, ny - y);
    const k = Math.min(r, l1 / 2, l2 / 2);
    const ax = x - ((x - px) / l1) * k;
    const ay = y - ((y - py) / l1) * k;
    const bx = x + ((nx - x) / l2) * k;
    const by = y + ((ny - y) / l2) * k;
    d += ` L ${f(ax)} ${f(ay)} Q ${f(x)} ${f(y)} ${f(bx)} ${f(by)}`;
  }
  const last = pts[pts.length - 1];
  return `${d} L ${f(last[0])} ${f(last[1])}`;
}

// Every wire's route. Lanes are handed out per gutter, the shortest runs
// nearest the rack; stub depths per plate and direction, the end nearest
// where its cable turns the shortest.
export function routeCables(wires: WireEnds[]): Route[] {
  type Plan = {
    kind: "straight" | "under" | "gutter" | "between" | "loose";
    side?: Side; // the gutter, for one rack
    sideA?: Side; // each rack end's gutter, between two places
    sideB?: Side;
  };
  const plans: Plan[] = wires.map(({ a, b }) => {
    if (a.rack && a.rack === b.rack) {
      if (Math.abs(a.x - b.x) < 2) return { kind: "straight" };
      if (Math.abs(a.y - b.y) < 2 && Math.abs(a.plateY - b.plateY) < 1) return { kind: "under" };
      return { kind: "gutter", side: (a.x + b.x) / 2 < centre(a) ? "left" : "right" };
    }
    if (!a.rack && !b.rack) return { kind: "loose" };
    // Between places: a rack end leaves by the gutter on the other end's side.
    return { kind: "between", ...(a.rack ? { sideA: b.x < centre(a) ? "left" : "right" } : {}), ...(b.rack ? { sideB: a.x < centre(b) ? "left" : "right" } : {}) } as Plan;
  });

  // Lanes: per rack and side, the shortest vertical runs innermost.
  const lane = new Map<string, number>(); // `${wire}:${end}` → lane
  const users = new Map<string, { key: string; span: number }[]>();
  const use = (rack: string, side: Side, key: string, span: number) => {
    const g = `${rack}\u0000${side}`;
    users.set(g, [...(users.get(g) ?? []), { key, span }]);
  };
  wires.forEach(({ a, b }, i) => {
    const p = plans[i];
    if (p.kind === "gutter") use(a.rack!, p.side!, `${i}:g`, Math.abs(a.y - b.y));
    if (p.kind === "between") {
      if (p.sideA) use(a.rack!, p.sideA, `${i}:a`, Math.abs(a.y - b.y));
      if (p.sideB) use(b.rack!, p.sideB, `${i}:b`, Math.abs(a.y - b.y));
    }
  });
  for (const list of users.values()) list.sort((x, y) => x.span - y.span).forEach((u, k) => lane.set(u.key, k));
  const gutterX = (p: PortAt, side: Side, k: number) => (side === "right" ? p.rackRight + ROUTE.gutter + k * ROUTE.lane : p.rackLeft - ROUTE.gutter - k * ROUTE.lane);

  // Where each end's run turns: its gutter, or the other end.
  const turnX = (i: number, end: "a" | "b"): number => {
    const { a, b } = wires[i];
    const p = plans[i];
    const me = end === "a" ? a : b;
    const other = end === "a" ? b : a;
    if (p.kind === "gutter") return gutterX(me, p.side!, lane.get(`${i}:g`) ?? 0);
    if (p.kind === "between") {
      const side = end === "a" ? p.sideA : p.sideB;
      return side ? gutterX(me, side, lane.get(`${i}:${end}`) ?? 0) : other.x;
    }
    return other.x;
  };
  // Stub depths: per plate and direction, the end nearest its turn the shortest.
  const depth = new Map<string, number>();
  const ends = new Map<string, { key: string; dist: number }[]>();
  wires.forEach((w, i) => {
    for (const end of ["a", "b"] as const) {
      const p = end === "a" ? w.a : w.b;
      const rear = end === "a" ? !!w.rearA : !!w.rearB;
      const g = `${w.device[end === "a" ? 0 : 1]}\u0000${p.plateY}\u0000${dirOf(p, rear)}`;
      ends.set(g, [...(ends.get(g) ?? []), { key: `${i}:${end}`, dist: Math.abs(p.x - turnX(i, end)) }]);
    }
  });
  for (const list of ends.values()) list.sort((x, y) => x.dist - y.dist).forEach((e, k) => depth.set(e.key, Math.min(k, ROUTE.maxSteps)));

  return wires.map((w, i) => {
    const { a, b } = w;
    const p = plans[i];
    const da = dirOf(a, !!w.rearA);
    const db = dirOf(b, !!w.rearB);
    // Out of the port's edge, then the stub.
    const edgeA: [number, number] = [a.x, a.y + (da * a.h) / 2];
    const edgeB: [number, number] = [b.x, b.y + (db * b.h) / 2];
    const sa = a.y + da * (a.h / 2 + ROUTE.stub + (depth.get(`${i}:a`) ?? 0) * ROUTE.step);
    const sb = b.y + db * (b.h / 2 + ROUTE.stub + (depth.get(`${i}:b`) ?? 0) * ROUTE.step);
    let pts: [number, number][];
    if (p.kind === "straight") {
      // One above the other: port edge to port edge.
      const s = b.y > a.y ? 1 : -1;
      pts = [
        [a.x, a.y + (s * a.h) / 2],
        [b.x, b.y - (s * b.h) / 2],
      ];
    } else if (p.kind === "under") {
      // One plate row: both stubs the same way, a straight line between them.
      const y = da === db ? (da > 0 ? Math.max(sa, sb) : Math.min(sa, sb)) : sa;
      pts = [edgeA, [a.x, y], [b.x, y], edgeB];
    } else if (p.kind === "gutter") {
      const gx = turnX(i, "a");
      pts = [edgeA, [a.x, sa], [gx, sa], [gx, sb], [b.x, sb], edgeB];
    } else if (p.kind === "between") {
      const ga = p.sideA ? turnX(i, "a") : null;
      const gb = p.sideB ? turnX(i, "b") : null;
      if (ga !== null && gb !== null) pts = [edgeA, [a.x, sa], [ga, sa], [ga, sb], [gb, sb], [b.x, sb], edgeB];
      else if (ga !== null) pts = [edgeA, [a.x, sa], [ga, sa], [ga, sb], [b.x, sb], edgeB];
      else pts = [edgeA, [a.x, sa], [gb!, sa], [gb!, sb], [b.x, sb], edgeB];
    } else pts = [edgeA, [a.x, sa], [b.x, sa], edgeB];
    return { points: pts, d: pathOf(pts) };
  });
}
