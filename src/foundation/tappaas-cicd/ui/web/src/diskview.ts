// diskview.ts — the disks of the Assets, Physical and Storage views as plain
// data: a disk asset found by its serial, a disk as one short line, the bay
// row a server's card draws, where a disk can be moved to, whether a server's
// CI knows disks its asset does not record, and which placement fields a
// form offers (a disk is placed in a bay of another asset, everything else
// in a rack or a room). Plain data: the unit tests read it.

import { bytes } from "./physical/storage";
import { AssetRow, AssetTree, AssetTreeDisk, DiskPlacement, DiskState } from "./types";

// A serial as it is compared: case, whitespace and dashes do not count.
export const serialKey = (s: string | null | undefined): string => (s ?? "").toLowerCase().replace(/[\s-]+/g, "");

// The disk asset that records a serial; null when none does.
export function diskAssetOf(tree: AssetTree | null | undefined, serial: string | null | undefined): AssetRow | null {
  const k = serialKey(serial);
  if (!tree || !k) return null;
  return tree.assets.find((a) => a.kind === "disk" && serialKey(a.serial) === k) ?? null;
}

// The disks in the asset that plays a role (a node's name) or has a name.
export function disksOf(tree: AssetTree | null | undefined, device: string): AssetTreeDisk[] {
  const a = tree?.assets.find((x) => x.kind !== "disk" && (x.placedAs === device || x.name === device));
  return a?.disks ?? [];
}

// The colours of a disk's state: the Physical views' ok, warn, fail, and
// grey for a disk nothing has judged.
export const DISK_COLOR: Record<DiskState, string> = { ok: "var(--pass)", warn: "var(--warn)", fail: "var(--fail)", unknown: "var(--skip)" };
// The same as a Badge's level.
export const DISK_LEVEL: Record<DiskState, "pass" | "warn" | "fail" | "unknown"> = { ok: "pass", warn: "warn", fail: "fail", unknown: "unknown" };

// A disk's health in words: its state, the reason, Proxmox's word.
export function healthText(d: Pick<AssetTreeDisk, "state" | "reason" | "health" | "ci">): string {
  if (!d.ci) return "not in the CMDB";
  const word = d.state === "unknown" ? "not judged" : d.state;
  return [word, d.reason, d.health ? `Proxmox ${d.health}` : null].filter(Boolean).join(" · ");
}

// The pool a disk is a member of, in words: "tanka1 · mirror-0 on tappaas1".
export function poolText(p: AssetTreeDisk["pool"]): string {
  if (!p) return "";
  return `${p.name}${p.vdev ? ` · ${p.vdev}` : ""}${p.node ? ` on ${p.node}` : ""}`;
}

// A disk as one short line: its size and kind, its serial, its pool.
export function diskText(d: AssetTreeDisk): string {
  return [d.size !== null ? bytes(d.size) : null, d.kind, d.serial, d.pool ? `pool ${poolText(d.pool)}` : null].filter(Boolean).join(" · ");
}

// The bay row of a server's card: one cell per disk, in bay order, coloured
// by its state, its bay (else its tag) as the label.
export interface BayCell {
  disk: string; // its tag
  label: string;
  state: DiskState;
  title: string;
}
export function bayRow(disks: AssetTreeDisk[]): BayCell[] {
  return disks.map((d) => ({
    disk: d.name,
    label: d.bay ?? d.name,
    state: d.state,
    title: `${d.bay ? `bay ${d.bay}: ` : ""}${d.displayName ?? d.name} (${d.name}) · ${diskText(d)} · ${healthText(d)}`,
  }));
}

// The worst state of a row, for a card that shows only one colour.
const RANK: Record<DiskState, number> = { ok: 0, unknown: 1, warn: 2, fail: 3 };
export function worstDisk(disks: AssetTreeDisk[]): DiskState | null {
  return disks.length ? disks.map((d) => d.state).reduce((w, s) => (RANK[s] > RANK[w] ? s : w), "ok" as DiskState) : null;
}

// The assets a disk can be moved into: every asset that is no disk, not
// ordered and not disposed, but the one it is in.
export function hostChoices(tree: AssetTree | null | undefined, disk: Pick<AssetRow, "in">): string[] {
  return (tree?.assets ?? [])
    .filter((a) => a.kind !== "disk" && a.stage !== "ordered" && a.stage !== "disposed" && a.name !== disk.in?.asset)
    .map((a) => a.name)
    .sort((x, y) => x.localeCompare(y, "en", { numeric: true }));
}

// Adopt the disks the CMDB knows…: offered when a server's CI lists disks
// with a serial that no asset records.
export function adoptOffer(a: Pick<AssetRow, "kind" | "unrecordedDisks">): { count: number; text: string } | null {
  if (a.kind === "disk") return null;
  const with_ = a.unrecordedDisks.filter((d) => d.serial);
  if (!with_.length) return null;
  return { count: with_.length, text: with_.map((d) => `${d.name}${d.serial ? ` (${d.serial})` : ""}`).join(", ") };
}

// A disk's placements as its page lists them: the newest first, each with
// the asset it was in and how long.
export function placementLines(list: DiskPlacement[]): { asset: string; bay: string | null; from: string; until: string | null; now: boolean }[] {
  return [...list].sort((a, b) => Date.parse(b.from) - Date.parse(a.from)).map((p) => ({ asset: p.asset, bay: p.bay, from: p.from, until: p.until, now: p.until === null }));
}

// A placement's fields (positions-fields' placement): a disk is placed in a
// bay of another asset and nowhere else; anything else in a rack or a room,
// never in an asset.
export const PLACEMENT_FIELDS = ["rack", "u", "room", "height", "width", "slot", "face", "faceplate", "label", "description", "in", "bay"] as const;
const DISK_FIELDS = ["in", "bay"];
export function placeFieldsFor(kind: string | null | undefined): string[] {
  return kind === "disk" ? [...DISK_FIELDS] : PLACEMENT_FIELDS.filter((f) => !DISK_FIELDS.includes(f));
}
