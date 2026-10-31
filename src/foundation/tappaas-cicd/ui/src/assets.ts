// assets.ts — the Assets view's tree: every asset of the site by where it
// stands, location → room → rack → asset, from the positions the topology
// carries (asset-manager's record, resolved against the site), each asset with
// its ports and the cables on them, and the role the CMDB has it allocated to
// beside the role the record gives it. An asset placed nowhere — in stock,
// ordered, or a device a switch port sees that nobody recorded — stands under
// its location as not placed; a disposed one under its location's disposed.
// Pure: reads.ts reads, this shapes.

import { CmdbRelationRow } from "./cmdb";

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
  disks?: unknown[];
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

export interface TreeAsset extends Omit<PosAsset, "ports"> {
  placedAs: string; // the name placements and cables know it by: its role's while it plays one
  where: { location: string; room: string | null; rack: string | null; at: string | null };
  ports: TreePort[];
  cmdb: { id: string; allocatedTo: string | null } | null; // null: the CMDB has no allocation of it (or was not read)
  allocationDrift: boolean; // the CMDB's allocation is not the record's role
}

export interface AssetTree {
  locations: TreeLocation[];
  assets: TreeAsset[];
  allocationsError: string | null;
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

/** The tree of a site's assets. allocations: the CMDB's allocated-to
 *  relations, or an error when the CMDB could not be read. */
export function assetTree(pos: AssetPositions | null, allocations: CmdbRelationRow[] | Error): AssetTree {
  const alloc = allocations instanceof Error ? null : allocationsOf(allocations);
  const assets = [...(pos?.assets ?? [])].sort(byName);
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
    const l = loc(a.location);
    (a.stage === "disposed" ? l.disposed : l.unplaced).push({ device, asset: a.name, kind: a.kind, at: null, seen: false });
    where.set(device, { location: l.name, room: null, rack: null, at: null });
  }
  for (const l of locs.values()) {
    const order = (x: TreeItem, y: TreeItem) => Number(x.seen) - Number(y.seen) || x.device.localeCompare(y.device, "en", { numeric: true });
    l.unplaced.sort(order);
    l.disposed.sort(order);
  }

  const out: TreeAsset[] = assets.map((a) => {
    const placedAs = a.role ?? a.name;
    const c = alloc?.get(a.name) ?? null;
    const { ports: _ports, ...rest } = a;
    return {
      ...rest,
      placedAs,
      where: where.get(placedAs) ?? { location: a.location ?? primary ?? "", room: null, rack: null, at: null },
      ports: portsOf(a, placedAs, cables),
      cmdb: c,
      allocationDrift: alloc !== null && (c?.allocatedTo ?? null) !== (a.role ?? null),
    };
  });
  // The primary location first, then by name; a location with nothing in it stays.
  const locations = [...locs.values()].sort((x, y) => Number(y.primary) - Number(x.primary) || x.name.localeCompare(y.name));
  return { locations, assets: out, allocationsError: allocations instanceof Error ? allocations.message : null };
}
