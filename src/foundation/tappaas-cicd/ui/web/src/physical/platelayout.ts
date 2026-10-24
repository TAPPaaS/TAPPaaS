// platelayout.ts — where a plate's ports and name are drawn (the Physical
// view's racks, the device panel, the Add a faceplate preview): a plate with
// blocks spreads each block's ports over its share of the plate's width; one
// without them is a grid right of its name. Pure, so the console's unit tests
// pin where the shipped plates put their ports.

import { PlacementInfo, PlatePort, ResolvedPlate } from "../types";
import { blockX } from "./portspec";

export interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}
export interface Placed {
  device: string;
  kind: PlacementInfo["kind"] | "outside";
  plate: ResolvedPlate | null;
  box: Box;
  up: boolean | null;
  title: string;
  sub: string;
  rack: string | null;
}

// Where a plate's name goes: left of its ports (a grid, or blocks that leave a
// fifth of the plate free on the left), else right of them, else along its top.
export function nameArea(plate: ResolvedPlate | null): { at: "left" | "right" | "top"; from: number; to: number } {
  const blocks = plate?.blocks ?? [];
  if (!blocks.length) return { at: "left", from: 0, to: 0.34 };
  const lo = Math.min(...blocks.map((b) => b.from));
  const hi = Math.max(...blocks.map((b) => b.to));
  if (lo >= 0.2) return { at: "left", from: 0, to: lo };
  if (1 - hi >= 0.2) return { at: "right", from: hi, to: 1 };
  return { at: "top", from: 0, to: 1 };
}
export const NAME_TOP = 11; // the strip a name along the top takes

// A plate with blocks: each block's ports spread evenly over its share of the
// plate's width, its rows centred in the plate's height (below the name when
// the name runs along the top).
function blockCells(p: Placed, blocks: NonNullable<ResolvedPlate["blocks"]>): { port: PlatePort; box: Box }[] {
  const top = nameArea(p.plate).at === "top" ? NAME_TOP : 0;
  const rows = Math.max(1, ...blocks.map((b) => b.rows.length));
  const ch = Math.max(6, Math.min(13, (p.box.h - top - 6) / rows - 3));
  const out: { port: PlatePort; box: Box }[] = [];
  for (const b of blocks) {
    const cols = Math.max(1, ...b.rows.map((r) => r.length));
    const pitch = ((b.to - b.from) * p.box.w) / cols;
    const cw = Math.max(4, Math.min(22, pitch - 3));
    const gridH = b.rows.length * (ch + 3);
    const y0 = p.box.y + top + (p.box.h - top - gridH) / 2 + 1.5;
    b.rows.forEach((row, ri) =>
      row.forEach((c, ci) => {
        if (!c) return;
        const cx = p.box.x + p.box.w * blockX(b, ci);
        out.push({ port: c, box: { x: cx - cw / 2, y: y0 + ri * (ch + 3), w: cw, h: ch } });
      }),
    );
  }
  return out;
}

// Where every port of every plate is drawn: by its blocks, else one cell per
// port of the plate's grid, right-aligned, the label on the left.
export function portCells(p: Placed): { port: PlatePort; box: Box }[] {
  if (p.plate?.blocks?.length) return blockCells(p, p.plate.blocks);
  const rows = p.plate?.rows ?? [];
  if (!rows.length) return [];
  const cols = Math.max(...rows.map((r) => r.length), 1);
  const labelW = Math.min(124, p.box.w * 0.34);
  const avail = p.box.w - labelW - 12;
  const cw = Math.max(9, Math.min(22, avail / cols));
  const ch = Math.max(7, Math.min(13, (p.box.h - 8) / rows.length - 3));
  const gridW = cols * cw;
  const gridH = rows.length * (ch + 3);
  const x0 = p.box.x + p.box.w - 8 - gridW;
  const y0 = p.box.y + (p.box.h - gridH) / 2 + 1.5;
  const out: { port: PlatePort; box: Box }[] = [];
  rows.forEach((row, ri) =>
    row.forEach((c, ci) => {
      if (c) out.push({ port: c, box: { x: x0 + ci * cw + 1, y: y0 + ri * (ch + 3), w: cw - 3, h: ch } });
    }),
  );
  return out;
}
