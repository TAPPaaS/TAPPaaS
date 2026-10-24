// platelayout.test.ts — where the rack view draws the shipped plates' ports
// (web/src/physical/platelayout.ts), each plate as its catalog file says, at
// the rack's 19in width (440 px): the patch panel across the whole plate, the
// UniFi switch in one row across it, the CRS317's cages in its left two thirds.

import { readFileSync } from "fs";
import { join } from "path";
import { parseFaceplate, recordedPlate, resolvePlate } from "../../../lib/ts/src/positions";
import { Placed, nameArea, portCells } from "../../web/src/physical/platelayout";
import { ResolvedPlate } from "../../web/src/types";
import { check, done } from "./check";

const CATALOG = join(__dirname, "..", "..", "..", "..", "..", "manager", "position-manager", "faceplates");
const W = 440;
const plateOf = (key: string): ResolvedPlate => {
  const f = parseFaceplate(key, JSON.parse(readFileSync(join(CATALOG, `${key}.json`), "utf8")));
  if ("error" in f) throw new Error(f.error);
  return resolvePlate(f, null) as ResolvedPlate;
};
const placed = (plate: ResolvedPlate): Placed => ({ device: "d", kind: "device", plate, box: { x: 0, y: 0, w: W, h: plate.units * 30 - 2 }, up: null, title: "d", sub: "", rack: null });
// Each port's centre x, by its id; and its row's y.
const xs = (plate: ResolvedPlate) => Object.fromEntries(portCells(placed(plate)).map((c) => [c.port.id, Math.round((c.box.x + c.box.w / 2) * 10) / 10]));
const ys = (plate: ResolvedPlate) => [...new Set(portCells(placed(plate)).map((c) => Math.round(c.box.y)))];
const near = (a: number, b: number) => Math.abs(a - b) < 0.2;
const evenly = (v: number[]) => v.slice(1).every((x, i) => Math.abs(x - v[i] - (v[1] - v[0])) < 0.2);

// The patch panel: 1 at 17.6, 24 at 422.4, 17.6 px apart; its name along the top.
const pp = plateOf("generic/patch-panel-24");
const ppx = xs(pp);
const ppRow = Array.from({ length: 24 }, (_, i) => ppx[String(i + 1)]);
check(near(ppRow[0], 17.6) && near(ppRow[23], 422.4) && evenly(ppRow), `patch panel: 24 ports from 17.6 to 422.4 px, evenly (${ppRow[0]}…${ppRow[23]})`);
check(ys(pp).length === 1 && nameArea(pp).at === "top", "patch panel: one row, its name along the top");
// A recorded 24-port panel is drawn the same.
const rec = recordedPlate("p", { kind: "patch-panel", ports: Array.from({ length: 24 }, (_, i) => String(i + 1)) }, []) ;
check(JSON.stringify(xs(resolvePlate(rec, null) as ResolvedPlate)) === JSON.stringify(ppx), "a recorded 24-port panel: the same places");

// The UniFi switch: thirteen places of 32.5 px across 8.8-431.2, 1-10, a gap, 11-12.
const usw = plateOf("unifi/usw-pro-xg-10-poe");
const ux = xs(usw);
const p = (W * 0.96) / 13;
check(near(ux["1"], 8.8 + p / 2) && near(ux["10"], 8.8 + 9.5 * p) && near(ux["11"], 8.8 + 11.5 * p) && near(ux["12"], 431.2 - p / 2), `UniFi: 1 at ${ux["1"]}, 10 at ${ux["10"]}, 11 at ${ux["11"]}, 12 at ${ux["12"]}`);
check(evenly(Array.from({ length: 10 }, (_, i) => ux[String(i + 1)])) && ys(usw).length === 1, "UniFi: one row, 1-10 evenly apart");

// The CRS317: cages 26.4-272.8 px in two aligned rows, ether1 over the console at 312.4, the name right of them.
const crs = plateOf("mikrotik/crs317-1g-16s");
const cx = xs(crs);
const topRow = [1, 3, 5, 7, 9, 11, 13, 15].map((n) => cx[`sfp-sfpplus${n}`]);
const bottomRow = [2, 4, 6, 8, 10, 12, 14, 16].map((n) => cx[`sfp-sfpplus${n}`]);
check(near(topRow[0], 26.4) && near(topRow[7], 272.8) && evenly(topRow) && JSON.stringify(topRow) === JSON.stringify(bottomRow), `CRS317: cages from 26.4 to 272.8 px, odd over even (${topRow.join(",")})`);
check(Math.max(...topRow) < (W * 2) / 3 && near(cx["ether1"], 312.4) && near(cx["console"], 312.4), "CRS317: the cages in the left two thirds, ether1 and the console at 312.4");
check(ys(crs).length === 2 && nameArea(crs).at === "right" && nameArea(crs).from === 0.73, "CRS317: two rows, its name in the right third");

// A plate without blocks keeps its grid right of its name.
const grid: ResolvedPlate = { key: "g", vendor: "G", model: "g", kind: "switch", units: 1, width: "full", passive: false, labels: [], rows: [[{ id: "1", name: "1", kind: "rj45", up: null, disabled: false, lag: null, zones: [] }]] };
check(nameArea(grid).at === "left" && portCells(placed(grid))[0].box.x > W * 0.9, "a grid plate: its name left, its ports at the right edge");
done("platelayout");
