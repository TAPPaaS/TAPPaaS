// assets.ts — the Assets view's tree: every asset of the site by where it
// stands, location → room → rack → asset, from the positions the topology
// carries (asset-manager's record, resolved against the site), each asset with
// its ports and the cables on them, and the role the CMDB has it allocated to
// beside the role the record gives it. An asset placed nowhere — in stock,
// ordered, or a device a switch port sees that nobody recorded — stands under
// its location as not placed; a disposed one under its location's disposed.
// A disk (an asset of kind disk) is a part of the asset it is in: listed with
// that asset, by bay, with its health and the pool it is a member of from the
// CMDB (the disk CI and the pool's built-on relation); a disk in stock stands
// under its location's not placed like any other asset. Pure: reads.ts reads,
// this shapes.

import { CmdbObject, CmdbRelationRow } from "./cmdb";
import { conditionsOf } from "./health";

// ── the input: the parts of the topology's positions read here ──────────

export interface PosPort {
  name: string;
  kind?: string;
  speed?: string;
  standard?: string;
  bands?: string[];
  module?: string;
  role?: string;
  mac?: string;
  side?: string;
}

export interface PosAsset {
  name: string;
  kind: string;
  displayName: string | null;
  vendor: string | null;
  model: string | null;
  serial: string | null;
  assetTag?: string | null;
  stage: string;
  faulty?: boolean;
  faultNote?: string | null;
  role: string | null;
  location?: string | null;
  placed: boolean;
  ports?: PosPort[];
  in?: { asset: string; bay: string | null }; // a disk's: the asset it is in
  disk?: { kind?: string; bus?: string; wwn?: string; size?: number; firmware?: string }; // a disk's own record
}

export interface PosPlacement {
  device: string;
  kind: string;
  u?: number;
  height?: number;
  face?: string;
  room?: string | null;
}

export interface PosEnd {
  device: string;
  port: string;
  side?: string;
}

export interface PosCable {
  from: PosEnd;
  to: PosEnd;
  kind: string;
  source: string;
  label?: string | null;
  via?: { device: string; port: string }[];
}

export interface AssetPositions {
  assets?: PosAsset[];
  locations?: { name: string; displayName: string | null; primary: boolean; rooms: string[]; unplaced: string[] }[];
  racks: { name: string; displayName: string | null; units: number; room: string | null; location?: string | null; placements: PosPlacement[] }[];
  rooms?: { name: string; displayName: string | null; location?: string | null; recorded: boolean; racks: string[]; loose: PosPlacement[] }[];
  unplaced: { device: string; kind: string; seen?: boolean; location?: string | null }[];
  cables?: PosCable[];
}

// ── the output ───────────────────────────────────────────────────────────

// One row under a rack, a room or a location: a placed or unplaced device and
// the asset it is (null: a device the topology knows that no asset records,
// or one a switch port only sees).
export interface TreeItem {
  device: string;
  asset: string | null;
  kind: string;
  at: string | null; // "U12-13 front" in a rack; null elsewhere
  seen: boolean;
}

export interface TreeRack {
  name: string;
  displayName: string | null;
  units: number;
  items: TreeItem[];
}

export interface TreeRoom {
  name: string; // "" for the racks that stand in no room
  displayName: string | null;
  recorded: boolean;
  racks: TreeRack[];
  loose: TreeItem[];
}

export interface TreeLocation {
  name: string; // "" when the site names no location
  displayName: string | null;
  primary: boolean;
  rooms: TreeRoom[];
  unplaced: TreeItem[];
  disposed: TreeItem[];
}

export interface TreeCable {
  to: string; // the far end, "<device>:<port>"
  kind: string;
  source: string; // recorded, topology
  label: string | null;
  via: string[]; // the patch panel ports it runs through
}

export interface TreePort extends PosPort {
  listed: boolean; // false: a port only a cable names (a node's NIC)
  cables: TreeCable[];
}

// A disk's state as the views colour it: the worst condition health-manager
// judged on its CI, else Proxmox's health word; unknown when neither is known.
export type DiskState = "ok" | "warn" | "fail" | "unknown";

// A disk as the asset it is in lists it (and as its own page shows it).
export interface TreeDisk {
  name: string; // its tag, dsk-NN
  displayName: string | null; // its by-id name
  serial: string | null;
  size: number | null; // bytes
  kind: string | null; // nvme, ssd, hdd, usb
  stage: string;
  faulty: boolean;
  host: string | null; // the asset it is in, by its own name; null: in stock
  bay: string | null;
  ci: string | null; // its live disk CI's id
  health: string | null; // Proxmox's word on the CI: PASSED, FAILED, UNKNOWN
  state: DiskState;
  reason: string | null; // the worst condition's message, when one is not ok
  pool: { name: string; node: string | null; vdev: string | null } | null; // the pool built on it
}

// A disk the CMDB's server CI lists (site-manager's discovery) that no disk
// asset records, by serial: what disk adopt would record.
export interface UnrecordedDisk {
  name: string;
  serial: string | null;
  model: string | null;
  size: number | null;
  type: string | null;
}

export interface TreeAsset extends Omit<PosAsset, "ports"> {
  placedAs: string; // the name placements and cables know it by: its role's while it plays one
  where: { location: string; room: string | null; rack: string | null; at: string | null };
  ports: TreePort[];
  disks: TreeDisk[]; // the disks in it, by bay
  unrecordedDisks: UnrecordedDisk[]; // the disks its CI lists that no asset records
  asDisk: TreeDisk | null; // a disk's own row
  cmdb: { id: string; allocatedTo: string | null } | null; // null: the CMDB has no allocation of it (or was not read)
  allocationDrift: boolean; // the CMDB's allocation is not the record's role
}

export interface AssetTree {
  locations: TreeLocation[];
  assets: TreeAsset[];
  allocationsError: string | null;
  disksError: string | null; // the CMDB's disks were not read: no health, no pool
}

// What the CMDB says of disks: the live disk CIs, the built-on relations from
// the pools to them, and the server CIs with their discovered disks[].
export interface DiskFacts {
  disks: CmdbObject[];
  builtOn: CmdbRelationRow[];
  servers: CmdbObject[];
}

const byName = (a: { name: string }, b: { name: string }) => a.name.localeCompare(b.name, "en", { numeric: true });

function unitText(m: PosPlacement): string | null {
  if (typeof m.u !== "number") return null;
  const h = m.height ?? 1;
  return `U${m.u}${h > 1 ? `-${m.u + h - 1}` : ""}${m.face && m.face !== "front" ? ` ${m.face}` : ""}`;
}

// The cables on each of an asset's ports, from the device name it is placed by.
function portsOf(a: PosAsset, device: string, cables: PosCable[]): TreePort[] {
  const ports: TreePort[] = (a.ports ?? []).map((p) => ({ ...p, listed: true, cables: [] }));
  const at = (name: string): TreePort => {
    let p = ports.find((x) => x.name === name);
    if (!p) {
      p = { name, listed: false, cables: [] };
      ports.push(p);
    }
    return p;
  };
  for (const c of cables) {
    const via = (c.via ?? []).map((v) => `${v.device}:${v.port}`);
    const one = (mine: PosEnd, far: PosEnd) => at(mine.port).cables.push({ to: `${far.device}:${far.port}`, kind: c.kind, source: c.source, label: c.label ?? null, via });
    if (c.from.device === device) one(c.from, c.to);
    if (c.to.device === device) one(c.to, c.from);
    // A patch panel: the links that run through its ports.
    for (const v of c.via ?? []) if (v.device === device) at(v.port).cables.push({ to: `${c.from.device}:${c.from.port} — ${c.to.device}:${c.to.port}`, kind: c.kind, source: c.source, label: c.label ?? null, via: [] });
  }
  return ports;
}

// The CMDB's allocations: asset → the node it is allocated to.
export function allocationsOf(rows: CmdbRelationRow[]): Map<string, { id: string; allocatedTo: string }> {
  const m = new Map<string, { id: string; allocatedTo: string }>();
  for (const r of rows) if (r.type === "allocated-to") m.set(r.from.name, { id: r.from.id, allocatedTo: r.to.name });
  return m;
}

// A serial as it is compared (ADR-042 D2, lib/ts positions.ts serialKey):
// case, whitespace and dashes do not count.
export const serialKey = (s: string | null | undefined): string => (s ?? "").toLowerCase().replace(/[\s-]+/g, "");

const STATE_RANK: Record<DiskState, number> = { ok: 0, unknown: 1, warn: 2, fail: 3 };
const FROM_STATUS: Record<string, DiskState> = { ok: "ok", unknown: "unknown", warning: "warn", critical: "fail" };

/** A disk CI's state: the worst of its conditions, else its health word. */
export function diskState(attributes: Record<string, unknown> | null | undefined): { state: DiskState; reason: string | null } {
  const conds = conditionsOf(attributes ?? {});
  if (conds.length) {
    const worst = conds.map((c) => ({ c, s: FROM_STATUS[c.status] ?? "unknown" })).sort((a, b) => STATE_RANK[b.s] - STATE_RANK[a.s])[0];
    return { state: worst.s, reason: worst.s === "ok" ? null : worst.c.message ?? worst.c.reason ?? null };
  }
  const h = typeof attributes?.health === "string" ? attributes.health.toUpperCase() : "";
  if (h === "FAILED") return { state: "fail", reason: "Proxmox says FAILED" };
  if (h === "PASSED" || h === "OK") return { state: "ok", reason: null };
  return { state: "unknown", reason: null };
}

// The pool built on a disk CI: its name, and the node and vdev its
// redundancy group names (<node>:<pool>:<vdev>).
function poolOf(builtOn: CmdbRelationRow[], ci: string): TreeDisk["pool"] {
  const r = builtOn.find((x) => x.to.id === ci);
  if (!r) return null;
  const g = typeof r.attributes?.redundancyGroup === "string" ? r.attributes.redundancyGroup.split(":") : null;
  return { name: r.from.name, node: g && g.length >= 3 ? g[0] : null, vdev: g && g.length >= 3 ? g.slice(2).join(":") : null };
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);

/** The disks of the tree: each disk asset's row (its CI's health and pool
 *  when the CMDB answered), and per server the disks its CI lists that no
 *  asset records. */
export function diskRows(assets: PosAsset[], facts: DiskFacts | null): { rows: Map<string, TreeDisk>; unrecorded: Map<string, UnrecordedDisk[]> } {
  const cis = new Map((facts?.disks ?? []).map((o) => [o.name, o]));
  const rows = new Map<string, TreeDisk>();
  for (const a of assets) {
    if (a.kind !== "disk") continue;
    const ci = a.in ? cis.get(a.name) ?? null : null;
    const st = ci ? diskState(ci.attributes) : { state: "unknown" as DiskState, reason: null };
    rows.set(a.name, {
      name: a.name,
      displayName: a.displayName,
      serial: a.serial,
      size: num(a.disk?.size),
      kind: str(a.disk?.kind),
      stage: a.stage,
      faulty: a.faulty === true,
      host: a.in?.asset ?? null,
      bay: a.in?.bay ?? null,
      ci: ci?.id ?? null,
      health: str(ci?.attributes.health),
      state: st.state,
      reason: st.reason,
      pool: ci ? poolOf(facts?.builtOn ?? [], ci.id) : null,
    });
  }
  const known = new Set(assets.map((a) => serialKey(a.serial)).filter((k) => k));
  const unrecorded = new Map<string, UnrecordedDisk[]>();
  for (const s of facts?.servers ?? []) {
    const list = Array.isArray(s.attributes.disks) ? (s.attributes.disks as Record<string, unknown>[]) : [];
    const missing = list
      .filter((d) => d && typeof d === "object" && !known.has(serialKey(str(d.serial))))
      .map((d) => ({ name: str(d.name) ?? str(d.device) ?? "?", serial: str(d.serial), model: str(d.model), size: num(d.size), type: str(d.type) }));
    if (missing.length) unrecorded.set(s.name, missing);
  }
  return { rows, unrecorded };
}

// Bays in their natural order (1, 2, … 10; a by-id name after the numbers);
// a disk with no bay last, by its tag.
export function byBay(a: TreeDisk, b: TreeDisk): number {
  if (a.bay === null || b.bay === null) return Number(a.bay === null) - Number(b.bay === null) || a.name.localeCompare(b.name, "en", { numeric: true });
  return a.bay.localeCompare(b.bay, "en", { numeric: true }) || a.name.localeCompare(b.name, "en", { numeric: true });
}

/** The tree of a site's assets. allocations: the CMDB's allocated-to
 *  relations, or an error when the CMDB could not be read; disks: what the
 *  CMDB says of disks, or an error (the disks are listed without health). */
export function assetTree(pos: AssetPositions | null, allocations: CmdbRelationRow[] | Error, disks: DiskFacts | Error | null = null): AssetTree {
  const alloc = allocations instanceof Error ? null : allocationsOf(allocations);
  const assets = [...(pos?.assets ?? [])].sort(byName);
  const facts = disks instanceof Error ? null : disks;
  const { rows: diskOf, unrecorded } = diskRows(assets, facts);
  const cables = pos?.cables ?? [];
  const byDevice = new Map(assets.map((a) => [a.role ?? a.name, a]));
  const primary = pos?.locations?.find((l) => l.primary)?.name ?? null;
  const item = (device: string, kind: string, at: string | null, seen = false): TreeItem => ({ device, asset: byDevice.get(device)?.name ?? null, kind, at, seen });

  // The locations, the site's first (in its order), then any an asset names.
  const locs = new Map<string, TreeLocation>();
  const loc = (name: string | null | undefined): TreeLocation => {
    const n = name ?? primary ?? "";
    let l = locs.get(n);
    if (!l) {
      const site = pos?.locations?.find((x) => x.name === n);
      l = { name: n, displayName: site?.displayName ?? null, primary: site?.primary ?? false, rooms: [], unplaced: [], disposed: [] };
      locs.set(n, l);
    }
    return l;
  };
  for (const l of pos?.locations ?? []) loc(l.name);

  const where = new Map<string, TreeAsset["where"]>();
  const rooms = pos?.rooms ?? [];
  const racks = pos?.racks ?? [];
  const rackNode = (r: AssetPositions["racks"][number], location: string, room: string | null): TreeRack => {
    const items = [...r.placements].sort((a, b) => (b.u ?? 0) - (a.u ?? 0) || a.device.localeCompare(b.device)).map((m) => {
      where.set(m.device, { location, room, rack: r.name, at: unitText(m) });
      return item(m.device, m.kind, unitText(m));
    });
    return { name: r.name, displayName: r.displayName, units: r.units, items };
  };
  for (const room of [...rooms].sort(byName)) {
    const l = loc(room.location);
    const node: TreeRoom = { name: room.name, displayName: room.displayName, recorded: room.recorded, racks: [], loose: [] };
    for (const name of [...room.racks].sort((a, b) => a.localeCompare(b, "en", { numeric: true }))) {
      const r = racks.find((x) => x.name === name);
      if (r) node.racks.push(rackNode(r, l.name, room.name));
    }
    node.loose = [...room.loose].sort((a, b) => a.device.localeCompare(b.device)).map((m) => {
      where.set(m.device, { location: l.name, room: room.name, rack: null, at: null });
      return item(m.device, m.kind, null);
    });
    l.rooms.push(node);
  }
  // A rack that stands in no recorded room: under its location's "no room".
  for (const r of [...racks].sort(byName)) {
    if (rooms.some((x) => x.racks.includes(r.name))) continue;
    const l = loc(r.location);
    let none = l.rooms.find((x) => x.name === "");
    if (!none) {
      none = { name: "", displayName: null, recorded: false, racks: [], loose: [] };
      l.rooms.push(none);
    }
    none.racks.push(rackNode(r, l.name, null));
  }
  // Placed nowhere: the topology's unplaced devices (with the seen ones), then
  // the assets it does not list (ordered, in stock, disposed).
  const listed = new Set<string>();
  for (const u of pos?.unplaced ?? []) {
    const l = loc(u.location);
    l.unplaced.push(item(u.device, u.kind, null, u.seen === true));
    where.set(u.device, { location: l.name, room: null, rack: null, at: null });
    listed.add(u.device);
  }
  for (const a of assets) {
    const device = a.role ?? a.name;
    if (where.has(device) || listed.has(device)) continue;
    // A disk in an asset is listed with it (below), not under a location.
    if (a.kind === "disk" && a.in && a.stage !== "disposed" && assets.some((x) => x.name === a.in!.asset)) continue;
    const l = loc(a.location);
    (a.stage === "disposed" ? l.disposed : l.unplaced).push({ device, asset: a.name, kind: a.kind, at: null, seen: false });
    where.set(device, { location: l.name, room: null, rack: null, at: null });
  }
  for (const l of locs.values()) {
    const order = (x: TreeItem, y: TreeItem) => Number(x.seen) - Number(y.seen) || x.device.localeCompare(y.device, "en", { numeric: true });
    l.unplaced.sort(order);
    l.disposed.sort(order);
  }

  const whereOf = (a: PosAsset): TreeAsset["where"] => {
    const placedAs = a.role ?? a.name;
    const own = where.get(placedAs);
    if (own) return own;
    // A disk stands where the asset it is in stands.
    const host = a.in ? assets.find((x) => x.name === a.in!.asset) : undefined;
    const at = host ? where.get(host.role ?? host.name) : undefined;
    return at ? { ...at, at: null } : { location: a.location ?? primary ?? "", room: null, rack: null, at: null };
  };
  const out: TreeAsset[] = assets.map((a) => {
    const placedAs = a.role ?? a.name;
    const c = alloc?.get(a.name) ?? null;
    const { ports: _ports, ...rest } = a;
    return {
      ...rest,
      placedAs,
      where: whereOf(a),
      ports: portsOf(a, placedAs, cables),
      disks: [...diskOf.values()].filter((d) => d.host === a.name && d.stage !== "disposed").sort(byBay),
      unrecordedDisks: unrecorded.get(a.name) ?? [],
      asDisk: diskOf.get(a.name) ?? null,
      cmdb: c,
      // A disk plays no role; the CMDB allocates none to it.
      allocationDrift: a.kind !== "disk" && alloc !== null && (c?.allocatedTo ?? null) !== (a.role ?? null),
    };
  });
  // The primary location first, then by name; a location with nothing in it stays.
  const locations = [...locs.values()].sort((x, y) => Number(y.primary) - Number(x.primary) || x.name.localeCompare(y.name));
  return {
    locations,
    assets: out,
    allocationsError: allocations instanceof Error ? allocations.message : null,
    disksError: disks instanceof Error ? disks.message : null,
  };
}

// ── a disk's placements (ADR-042 D6) ──────────────────────────────────

// One period of a disk in an asset: the disk CI that was part of it.
export interface DiskPlacement {
  asset: string; // the asset it was in
  bay: string | null;
  ci: string;
  from: string;
  until: string | null; // null: it is there now
}

/** Which assets a disk has been in, the newest first: each disk CI of its
 *  name (moved, the CI in the old asset ends and one in the new begins), the
 *  asset from its part-of relation's period, the bay its last. */
export function diskPlacements(cis: { id: string; created?: string | null; ended?: string | null }[], histories: Map<string, { attributes: { name: string; value: unknown; from: string; to: string | null }[]; relations?: { type: string; direction: string; other: { name: string }; from: string; to: string | null }[] }>): DiskPlacement[] {
  const out: DiskPlacement[] = [];
  for (const ci of cis) {
    const h = histories.get(ci.id);
    const parts = (h?.relations ?? []).filter((r) => r.type === "part-of" && r.direction === "out");
    const bays = (h?.attributes ?? []).filter((x) => x.name === "bay").sort((a, b) => Date.parse(b.from) - Date.parse(a.from));
    const bay = typeof bays[0]?.value === "string" ? (bays[0].value as string) : null;
    if (parts.length) {
      for (const r of parts) out.push({ asset: r.other.name, bay, ci: ci.id, from: r.from, until: r.to });
    } else if (ci.created) {
      out.push({ asset: "?", bay, ci: ci.id, from: ci.created, until: ci.ended ?? null });
    }
  }
  return out.sort((a, b) => Date.parse(b.from) - Date.parse(a.from));
}
