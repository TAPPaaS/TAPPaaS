// platelayout.test.ts — where the rack view draws the shipped plates' ports
// (web/src/physical/platelayout.ts), each plate as its catalog file says, at
// the rack's 19in width (440 px): the patch panel across the whole plate, the
// UniFi switch in one row over its right half, the CRS317's cages in one row
// over its left two thirds.

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

// The UniFi switch: twelve places of 17.2 px over the right half, 224.4-431.2, its name left of them.
const usw = plateOf("unifi/usw-pro-xg-10-poe");
const ux = xs(usw);
const uRow = Array.from({ length: 12 }, (_, i) => ux[String(i + 1)]);
check(near(uRow[0], 233) && near(uRow[11], 422.6) && evenly(uRow) && ys(usw).length === 1, `UniFi: one row, 1-12 evenly from ${uRow[0]} to ${uRow[11]} px`);
check(Math.min(...uRow) > W / 2 && nameArea(usw).at === "left", "UniFi: the left half blank but for its name");

// The CRS317: sixteen cages in one row, 16.8-256 px, ether1 and the console at 275 and 288.2, the name right of them.
const crs = plateOf("mikrotik/crs317-1g-16s");
const cx = xs(crs);
const cages = Array.from({ length: 16 }, (_, i) => cx[`sfp-sfpplus${i + 1}`]);
check(near(cages[0], 16.8) && near(cages[15], 256) && evenly(cages) && ys(crs).length === 1, `CRS317: one row of cages from ${cages[0]} to ${cages[15]} px`);
check(near(cx["ether1"], 275) && near(cx["console"], 288.2) && Math.max(...Object.values(cx)) < (W * 2) / 3, "CRS317: ether1 and the console at the row's right end, all in the left two thirds");
check(nameArea(crs).at === "right" && nameArea(crs).from === 0.67, "CRS317: its name in the right third");

// A plate without blocks keeps its grid right of its name.
const grid: ResolvedPlate = { key: "g", vendor: "G", model: "g", kind: "switch", units: 1, width: "full", passive: false, labels: [], rows: [[{ id: "1", name: "1", kind: "rj45", up: null, disabled: false, lag: null, zones: [] }]] };
check(nameArea(grid).at === "left" && portCells(placed(grid))[0].box.x > W * 0.9, "a grid plate: its name left, its ports at the right edge");
done("platelayout");
