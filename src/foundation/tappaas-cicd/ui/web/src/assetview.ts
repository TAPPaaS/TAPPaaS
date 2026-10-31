// assetview.ts — the Assets view's plain logic: an asset by the name it is
// asked by (its own, or the role it plays), the history of its allocations
// from its CMDB history, what the page's ?select= names, and which tree rows
// a filter keeps. Plain data: the unit tests read it.

import { AssetRow, AssetTree, AssetTreeItem, AssetTreeLocation, CiHistoryRow } from "./types";

// An asset by its own name, or by the role it plays (a node's name).
export function findAsset(tree: AssetTree | null | undefined, name: string): AssetRow | null {
  if (!tree) return null;
  return tree.assets.find((a) => a.name === name) ?? tree.assets.find((a) => a.role === name || a.placedAs === name) ?? null;
}

// One allocation of an asset: the role it played, from when, until when (null: it still does).
export interface Allocation {
  role: string;
  id: string | null; // the node's CI
  from: string;
  until: string | null;
  source: string | null;
}

// The allocations an asset has had, the newest first: its allocated-to
// relation's periods in its CMDB history.
export function allocationHistory(rows: CiHistoryRow[]): Allocation[] {
  return rows
    .filter((h) => h.what === "relation" && h.name === "allocated-to" && h.detail !== "in")
    .map((h) => {
      const v = h.value && typeof h.value === "object" ? (h.value as { id?: string; name?: string }) : null;
      return { role: v?.name ?? String(h.value ?? "?"), id: v?.id ?? null, from: h.at, until: h.until, source: h.source };
    })
    .sort((a, b) => Date.parse(b.from) - Date.parse(a.from) || a.role.localeCompare(b.role));
}

// The current allocation's since: the open period of the role it plays now.
export function allocatedSince(list: Allocation[], role: string | null): string | null {
  if (!role) return null;
  return list.find((a) => a.role === role && a.until === null)?.from ?? null;
}

// What the Assets page's ?select= names: a location, a room, a rack, or a
// device placed nowhere (one a switch port sees, or one no asset records).
export type AssetsSel = { kind: "location" | "room" | "rack" | "device"; id: string };

export function assetsSelOf(v: string | null): AssetsSel | null {
  if (!v) return null;
  const i = v.indexOf(":");
  if (i < 1) return null;
  const kind = v.slice(0, i);
  const id = v.slice(i + 1);
  if (kind !== "location" && kind !== "room" && kind !== "rack" && kind !== "device") return null;
  return { kind, id };
}

export const assetsSelText = (s: AssetsSel): string => `${s.kind}:${s.id}`;

// A filter's text against a row: its device, its asset, the asset's display
// name, kind, model, serial, tag and role.
export function itemMatches(tree: AssetTree, it: AssetTreeItem, q: string): boolean {
  const t = q.trim().toLowerCase();
  if (!t) return true;
  const a = it.asset ? tree.assets.find((x) => x.name === it.asset) : null;
  return [it.device, it.asset, it.kind, a?.displayName, a?.model, a?.vendor, a?.serial, a?.assetTag, a?.role, a?.stage].some((x) => typeof x === "string" && x.toLowerCase().includes(t));
}

// A location as a filter leaves it: only the rows that match, and the rooms
// and racks that still hold one; null when nothing is left.
export function filterLocation(tree: AssetTree, l: AssetTreeLocation, q: string): AssetTreeLocation | null {
  if (!q.trim()) return l;
  const keep = (xs: AssetTreeItem[]) => xs.filter((x) => itemMatches(tree, x, q));
  const rooms = l.rooms
    .map((r) => ({ ...r, racks: r.racks.map((k) => ({ ...k, items: keep(k.items) })).filter((k) => k.items.length), loose: keep(r.loose) }))
    .filter((r) => r.racks.length || r.loose.length);
  const unplaced = keep(l.unplaced);
  const disposed = keep(l.disposed);
  return rooms.length || unplaced.length || disposed.length ? { ...l, rooms, unplaced, disposed } : null;
}

// The rows a location holds, every one.
export function itemsOf(l: AssetTreeLocation): AssetTreeItem[] {
  return [...l.rooms.flatMap((r) => [...r.racks.flatMap((k) => k.items), ...r.loose]), ...l.unplaced, ...l.disposed];
}

// The stages, as the tree's tags show them, and the count of each.
export const STAGES = ["ordered", "stock", "placed", "operational", "disposed"] as const;
export function stageCounts(tree: AssetTree): Record<string, number> {
  const out: Record<string, number> = Object.fromEntries(STAGES.map((s) => [s, 0]));
  for (const a of tree.assets) out[a.stage] = (out[a.stage] ?? 0) + 1;
  return out;
}
