// cableroute.test.ts — the rack view's cables (web/src/physical/cableroute.ts):
// one cubic curve port to port, leaving each port vertically (up from an upper
// row and a panel's rear, down from a lower row, toward the other end from a
// single row), pulled out further the farther the ends are apart, a bundle
// between two devices fanning out, its label's place halfway along.

import { PortAt, ROUTE, exitOf, routeCables } from "../../web/src/physical/cableroute";
import { check, done } from "./check";

// A port on a 1U plate (28 px) at plateY; a two-row plate's upper or lower row.
const at = (x: number, plateY: number, rack: string | null = "rack1"): PortAt => ({ x, y: plateY + 14, h: 13, plateY, plateH: 28, rack });
const row = (x: number, plateY: number, lower: boolean): PortAt => ({ x, y: plateY + (lower ? 20 : 8), h: 8, plateY, plateH: 28, rack: "rack1" });

const [r] = routeCables([{ a: at(300, 100), b: at(200, 400), device: ["sw", "node"] }]);
check(/^M 300 114 C [\d.]+ [\d.]+, [\d.]+ [\d.]+, 200 414$/.test(r.d), `one cubic curve from port centre to port centre (${r.d})`);
check(r.points[1][0] === 300 && r.points[2][0] === 200, "its control points straight above or below the ports: it leaves each port vertically");
check(r.points[1][1] > 114 && r.points[2][1] < 414, "a single-row plate's cable leaves toward the other end: down from the upper, up into the lower");
const pull = (x: { points: [number, number][] }) => Math.abs(x.points[1][1] - x.points[0][1]);
const near = routeCables([{ a: at(300, 100), b: at(300, 160), device: ["a", "b"] }])[0];
const far = routeCables([{ a: at(300, 100), b: at(300, 700), device: ["a", "b"] }])[0];
check(pull(near) < pull(far) && pull(near) >= ROUTE.pullMin && pull(far) <= ROUTE.pullMax, `the pull grows with the distance (${pull(near)} < ${pull(far)}), within its bounds`);
// A two-row plate: the upper row leaves up, the lower row down, wherever the other end is.
check(exitOf(row(300, 100, false), false, at(300, 500)) === -1 && exitOf(row(300, 100, true), false, at(300, 0)) === 1, "a two-row plate: the upper row up, the lower row down");
// A patch panel's rear: up.
check(exitOf(at(300, 200), true, at(300, 600)) === -1, "a patch panel port's rear wire leaves upward");
// A bundle between the same two devices fans out; another pair starts again.
const bundle = routeCables([
  { a: at(300, 100), b: at(310, 400), device: ["sw", "n"] },
  { a: at(320, 100), b: at(330, 400), device: ["n", "sw"] },
  { a: at(340, 100), b: at(350, 400), device: ["sw", "n"] },
  { a: at(360, 100), b: at(370, 400), device: ["sw", "m"] },
]);
const pulls = bundle.map(pull);
check(Math.abs(pulls[1] - pulls[0] - ROUTE.fan) < 1e-6 && Math.abs(pulls[2] - pulls[1] - ROUTE.fan) < 1e-6 && Math.abs(pulls[3] - pulls[0]) < 1e-6, `a bundle fans: each further cable between two devices pulls ${ROUTE.fan} px further (${pulls.join(", ")})`);
// To a loose device in another room: one long curve.
const [lo] = routeCables([{ a: at(300, 300), b: at(900, 60, null), device: ["sw", "ap"] }]);
check(lo.d.split(" C ").length === 2 && lo.points[3][0] === 900, "a loose device: one curve into its plate");
// Its label's place: halfway along the curve.
const m = r.mid;
check(Math.abs(m[0] - 250) < 0.01 && Math.abs(m[1] - 264) < 0.01, `the label's place halfway along (${m.join(", ")})`);
done("cableroute");
