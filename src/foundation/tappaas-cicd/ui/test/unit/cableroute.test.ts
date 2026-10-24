// cableroute.test.ts — the rack view's cable routes (web/src/physical/cableroute.ts):
// stubs out of the ports, only horizontal and vertical runs, a bend in the
// gutter beside the rack when two ports are not aligned, a lane each, a loose
// device reached from the rack's gutter on its side, a panel's rear upwards.

import { PortAt, routeCables } from "../../web/src/physical/cableroute";
import { check, done } from "./check";

// A 19in rack frame from 100 to 588; plates 28 px high.
const at = (x: number, plateY: number, rack: string | null = "rack1", h = 13): PortAt => ({ x, y: plateY + 14, h, plateY, plateH: 28, rack, rackLeft: rack ? 100 : x - 50, rackRight: rack ? 588 : x + 50 });
const orthogonal = (pts: [number, number][]) => pts.slice(1).every((p, i) => Math.abs(p[0] - pts[i][0]) < 0.01 || Math.abs(p[1] - pts[i][1]) < 0.01);

// Two ports of one rack, not aligned: through the right gutter.
const [g] = routeCables([{ a: at(400, 100), b: at(300, 300), device: ["sw", "node"] }]);
check(orthogonal(g.points), "a route runs only horizontally and vertically");
check(g.points[0][1] === 100 + 14 + 6.5 && g.points[1][0] === 400 && g.points[1][1] > g.points[0][1], "out of the port's lower edge, a stub down");
check(g.points.some((p) => p[0] > 588) && Math.max(...g.points.map((p) => p[0])) === 588 + 9, "bent in the gutter right of the rack");
check(g.points[g.points.length - 1][0] === 300 && g.d.startsWith("M 400 120.5") && g.d.includes(" Q "), "into the far port, corners rounded");
// Ports left of the middle: the left gutter.
const [l] = routeCables([{ a: at(150, 100), b: at(200, 300), device: ["sw", "node"] }]);
check(Math.min(...l.points.map((p) => p[0])) === 100 - 9, "ports left of the middle: the left gutter");
// Several through one gutter: a lane each, the shortest innermost; a stub depth each on one plate.
const many = routeCables([
  { a: at(400, 100), b: at(300, 500), device: ["sw", "n1"] },
  { a: at(420, 100), b: at(300, 200), device: ["sw", "n2"] },
  { a: at(440, 100), b: at(300, 300), device: ["sw", "n3"] },
]);
const gx = many.map((r) => Math.max(...r.points.map((p) => p[0])));
check(new Set(gx).size === 3 && gx[1] < gx[2] && gx[2] < gx[0], `a lane each, the shortest run innermost (${gx.join(", ")})`);
const sy = many.map((r) => r.points[1][1]);
check(new Set(sy).size === 3 && sy[2] < sy[1] && sy[1] < sy[0], `a stub depth each, the port nearest the gutter shortest (${sy.join(", ")})`);
// One plate row: under the plate, no gutter.
const [u] = routeCables([{ a: at(200, 100), b: at(260, 100), device: ["sw", "sw"] }]);
check(u.points.length === 4 && u.points[1][1] === u.points[2][1] && u.points.every((p) => p[0] >= 200 && p[0] <= 260), "two ports of one row: joined under the plate");
// One above the other: straight.
const [s] = routeCables([{ a: at(300, 100), b: at(300, 300), device: ["a", "b"] }]);
check(s.points.length === 2 && s.points[0][0] === 300 && s.points[1][0] === 300, "two ports one above the other: a straight line");
// A loose device right of the rack: from the right gutter to its plate.
const [lo] = routeCables([{ a: at(300, 200), b: at(800, 60, null), device: ["sw", "ap"] }]);
check(orthogonal(lo.points) && lo.points.some((p) => p[0] === 597) && lo.points[lo.points.length - 1][0] === 800, "a loose device: out by the gutter on its side, into its plate");
// A device left of the racks (the ISP's modem): the left gutter.
const [ou] = routeCables([{ a: at(40, 150, null), b: at(300, 200), device: ["modem", "sw"] }]);
check(ou.points.some((p) => p[0] === 91), "a device left of the racks: the left gutter");
// A patch panel: the front wire leaves down, the rear wire up.
const [fr, re] = routeCables([
  { a: at(300, 200), b: at(500, 400), device: ["pp", "n"] },
  { a: at(300, 200), b: at(200, 50), rearA: true, device: ["pp", "sw"] },
]);
check(fr.points[1][1] > 214 && re.points[1][1] < 214, "a panel port: its front wire down, its rear wire up");
// A plate's upper row leaves up, its lower row down.
const two = (y: number): PortAt => ({ x: 300, y, h: 8, plateY: 100, plateH: 28, rack: "rack1", rackLeft: 100, rackRight: 588 });
const [up, dn] = routeCables([
  { a: two(107), b: at(500, 400), device: ["crs", "n1"] },
  { a: { ...two(119), x: 320 }, b: at(520, 400), device: ["crs", "n2"] },
]);
check(up.points[1][1] < 107 && dn.points[1][1] > 119, "a two-row plate: the upper row up, the lower row down");
done("cableroute");
