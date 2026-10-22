// storage.ts — the storage inventory as the Storage view draws it: which
// column each node, pool and disk sits in, the findings on each, and what a
// pool holds as the slices of its pie. Plain data, no React: the unit tests
// run it over hrossen's inventory.

import { Gate, StorageDisk, StorageInventory, StoragePool, StorageState } from "../types";

// ── sizes ─────────────────────────────────────────────────────────────
const UNITS = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];

export function bytes(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return "?";
  let v = n;
  let i = 0;
  while (Math.abs(v) >= 1024 && i < UNITS.length - 1) {
    v /= 1024;
    i++;
  }
  return `${i === 0 ? v : v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${UNITS[i]}`;
}

// A pool's fill, 0..100: what ZFS lets the datasets use.
export function poolPct(p: StoragePool): number | null {
  return p.usable ? p.usable.pct : p.size && p.allocated !== null ? (100 * p.allocated) / p.size : null;
}

// ── states ────────────────────────────────────────────────────────────
const RANK: Record<StorageState, number> = { ok: 0, warn: 1, fail: 2 };

export function worst(states: StorageState[]): StorageState {
  return states.reduce<StorageState>((w, s) => (RANK[s] > RANK[w] ? s : w), "ok");
}

// The objects of the view, by key: "node:<node>", "pool:<node>/<pool>",
// "disk:<node>:<device>", "repl:<node>:<id>".
export const nodeKey = (node: string) => `node:${node}`;
export const poolKey = (node: string, pool: string) => `pool:${node}/${pool}`;
export const diskKey = (node: string, device: string) => `disk:${node}:${device}`;

export interface StorageNote {
  level: "warn" | "fail";
  text: string;
  source: string; // "inventory", or the health gate that said it
}

// Every finding on every object: the inventory's own, and the rows of the
// storage-pools and storage-disks gates (health-manager validate) by their
// subjects — a pool "<node>/<pool>", a disk "<node>:<device>", a module (a
// replication job, placed on the node the job runs from). The same text twice
// is one finding.
export function storageNotes(inv: StorageInventory, gates: Gate[] = []): Map<string, StorageNote[]> {
  const out = new Map<string, StorageNote[]>();
  const add = (key: string, n: StorageNote): void => {
    const list = out.get(key) ?? [];
    if (!list.some((x) => x.text === n.text)) list.push(n);
    out.set(key, list);
  };
  for (const f of inv.findings) {
    const key = f.on.kind === "disk" ? diskKey(f.on.node, f.on.name) : f.on.kind === "pool" ? poolKey(f.on.node, f.on.name) : f.on.kind === "replication" ? `repl:${f.on.node}:${f.on.name}` : nodeKey(f.on.node);
    add(key, { level: f.level, text: f.text, source: "inventory" });
  }
  for (const g of gates.filter((x) => x.name === "storage-pools" || x.name === "storage-disks")) {
    for (const r of g.findings) {
      const level = r.status === "fail" ? "fail" : r.status === "warn" ? "warn" : null;
      if (!level || !r.subject) continue;
      const s = r.subject;
      if (s.kind === "pool" && s.name.includes("/")) add(`pool:${s.name}`, { level, text: r.text, source: g.name });
      else if (s.kind === "disk" && s.name.includes(":")) add(`disk:${s.name}`, { level, text: r.text, source: g.name });
      else if (s.kind === "module") {
        const n = inv.nodes.find((x) => x.replication.some((j) => j.module === s.name));
        add(nodeKey(n?.name ?? s.name), { level, text: r.text, source: g.name });
      } else if (s.kind === "node") add(nodeKey(s.name), { level, text: r.text, source: g.name });
    }
  }
  return out;
}

// An object's state: its own, raised by any finding on it (a gate may know
// what the inventory does not, a pool over 80% say).
export function stateWith(own: StorageState, notes: StorageNote[] | undefined): StorageState {
  return worst([own, ...(notes ?? []).map((n) => n.level === "fail" ? "fail" as const : "warn" as const)]);
}

// ── a pool's pie ──────────────────────────────────────────────────────
export interface Slice {
  key: string;
  kind: "guest" | "mirror" | "store" | "other" | "free";
  label: string;
  bytes: number;
  module?: string; // a guest's slice: its module
  parts?: { label: string; module: string | null; bytes: number; of: string | null }[]; // what the slice sums
}

const guestName = (v: { module: string | null; guest: string | null; vmid: number }): string => v.module ?? v.guest ?? `vmid ${v.vmid}`;

// What a pool holds, as slices that add up to its usable size (the
// inventory's totals): one per guest with its own disks here, the HA mirror
// copies of other nodes' guests as one slice (its parts the guests), the PBS
// datastores and NFS shares, every other dataset (templates, orphans, the
// pool's own), and free. Empty slices are left out, free never.
export function poolSlices(p: StoragePool): Slice[] {
  const t = p.totals;
  const out: Slice[] = [];
  const own = new Map<string, number>();
  for (const v of p.volumes.filter((x) => x.kind === "own")) own.set(guestName(v), (own.get(guestName(v)) ?? 0) + v.used);
  for (const [m, b] of [...own.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))) {
    if (b > 0) out.push({ key: `guest:${m}`, kind: "guest", label: m, bytes: b, module: p.volumes.find((v) => guestName(v) === m)?.module ?? undefined });
  }
  if (t.mirror > 0) {
    const parts = new Map<string, { label: string; module: string | null; bytes: number; of: string | null }>();
    for (const v of p.volumes.filter((x) => x.kind === "mirror")) {
      const k = guestName(v);
      const e = parts.get(k) ?? { label: k, module: v.module, bytes: 0, of: v.runsOn };
      e.bytes += v.used;
      parts.set(k, e);
    }
    out.push({ key: "mirror", kind: "mirror", label: "HA mirrors", bytes: t.mirror, parts: [...parts.values()].sort((a, b) => b.bytes - a.bytes) });
  }
  // The datastores and shares are inside "other": never more than it.
  const stores = p.datasets.filter((d) => d.kind === "pbs-datastore" || d.kind === "nfs-share");
  const storeBytes = Math.min(t.other, stores.reduce((s, d) => s + d.used, 0));
  if (storeBytes > 0) {
    out.push({
      key: "store",
      kind: "store",
      label: "datastores and shares",
      bytes: storeBytes,
      parts: stores.map((d) => ({ label: `${d.kind === "pbs-datastore" ? "PBS datastore" : "NFS share"} ${d.label}`, module: null, bytes: d.used, of: null })),
    });
  }
  const other = t.other - storeBytes;
  if (other > 0) {
    const listed = p.volumes.filter((v) => v.kind === "template" || v.kind === "orphan").map((v) => ({ label: `${v.kind} ${v.name.replace(/^[^/]*\//, "")}`, module: v.module, bytes: v.used, of: null }));
    const ds = p.datasets.filter((d) => d.kind === "dataset" || d.kind === "volume").map((d) => ({ label: d.label, module: null, bytes: d.used, of: null }));
    out.push({ key: "other", kind: "other", label: "other datasets", bytes: other, parts: [...listed, ...ds] });
  }
  out.push({ key: "free", kind: "free", label: "free", bytes: Math.max(0, t.free) });
  return out;
}

// ── the columns ───────────────────────────────────────────────────────
// Column 1 the nodes, column 2 each node's boot devices and pools (and, when
// it has disks in no pool, a "no pool" group), column 3 the disks, each disk
// of a vdev that groups them (a mirror, a raidz) marked with the vdev's label,
// kept together in the vdev's order.
export type StorageItem =
  | { id: string; col: 0; kind: "node"; node: string }
  | { id: string; col: 1; kind: "boot"; node: string; disk: StorageDisk }
  | { id: string; col: 1; kind: "pool"; node: string; pool: StoragePool }
  | { id: string; col: 1; kind: "nopool"; node: string; disks: StorageDisk[] }
  | { id: string; col: 2; kind: "disk"; node: string; disk: StorageDisk; pool: string | null; vdev: string | null; group: { label: string; first: boolean; last: boolean } | null; after?: string }
  | { id: string; col: 2; kind: "missing"; node: string; pool: string; name: string; state: string; after?: string };

export interface StorageLayout {
  items: StorageItem[];
  edges: { source: string; target: string }[];
}

// A vdev that groups disks: anything but a lone disk.
const grouped = (type: string, n: number): boolean => type !== "stripe" || n > 1;

export function storageLayout(inv: StorageInventory): StorageLayout {
  const items: StorageItem[] = [];
  const edges: { source: string; target: string }[] = [];
  for (const n of inv.nodes) {
    const nid = nodeKey(n.name);
    items.push({ id: nid, col: 0, kind: "node", node: n.name });
    for (const b of n.boot) {
      const id = `boot:${n.name}:${b.device}`;
      items.push({ id, col: 1, kind: "boot", node: n.name, disk: b });
      edges.push({ source: nid, target: id });
    }
    for (const p of n.pools) {
      const pid = poolKey(n.name, p.name);
      items.push({ id: pid, col: 1, kind: "pool", node: n.name, pool: p });
      edges.push({ source: nid, target: pid });
      let prev: string | undefined;
      for (const v of p.vdevs) {
        const label = grouped(v.type, v.disks.length + v.missing.length)
          ? `${v.name}${v.type !== v.name.replace(/-\d+$/, "") ? ` · ${v.type}` : ""}${v.role !== "data" ? ` · ${v.role}` : ""}${v.health && v.health !== "ONLINE" ? ` · ${v.health}` : ""}`
          : null;
        v.disks.forEach((d, i) => {
          const id = diskKey(n.name, d.device);
          const group = label ? { label, first: i === 0, last: i === v.disks.length - 1 && v.missing.length === 0 } : null;
          items.push({ id, col: 2, kind: "disk", node: n.name, disk: d, pool: p.name, vdev: v.name, group, after: prev });
          edges.push({ source: pid, target: id });
          prev = id;
        });
        for (const m of v.missing) {
          const id = `missing:${n.name}/${p.name}/${m.name}`;
          items.push({ id, col: 2, kind: "missing", node: n.name, pool: p.name, name: m.name, state: m.state, after: prev });
          edges.push({ source: pid, target: id });
          prev = id;
        }
      }
    }
    if (n.otherDisks.length) {
      const gid = `nopool:${n.name}`;
      items.push({ id: gid, col: 1, kind: "nopool", node: n.name, disks: n.otherDisks });
      edges.push({ source: nid, target: gid });
      let prev: string | undefined;
      for (const d of n.otherDisks) {
        const id = diskKey(n.name, d.device);
        items.push({ id, col: 2, kind: "disk", node: n.name, disk: d, pool: null, vdev: null, group: null, after: prev });
        edges.push({ source: gid, target: id });
        prev = id;
      }
    }
  }
  return { items, edges };
}

// A disk wherever it is: boot, in a pool, or in none.
export function findDisk(inv: StorageInventory, node: string, device: string): { disk: StorageDisk; pool: StoragePool | null; vdev: string | null; boot: boolean } | null {
  const n = inv.nodes.find((x) => x.name === node);
  if (!n) return null;
  const b = n.boot.find((d) => d.device === device);
  if (b) return { disk: b, pool: null, vdev: null, boot: true };
  for (const p of n.pools) {
    for (const v of p.vdevs) {
      const d = v.disks.find((x) => x.device === device);
      if (d) return { disk: d, pool: p, vdev: v.name, boot: false };
    }
  }
  const o = n.otherDisks.find((d) => d.device === device);
  return o ? { disk: o, pool: null, vdev: null, boot: false } : null;
}

// Totals per node for the overview: its pools' sizes and what is used.
export function nodeTotals(inv: StorageInventory): { node: string; state: StorageState; pools: number; disks: number; total: number; used: number }[] {
  return inv.nodes.map((n) => {
    const total = n.pools.reduce((s, p) => s + p.totals.total, 0);
    const free = n.pools.reduce((s, p) => s + p.totals.free, 0);
    const disks = n.boot.length + n.otherDisks.length + n.pools.reduce((s, p) => s + p.vdevs.reduce((x, v) => x + v.disks.length, 0), 0);
    return { node: n.name, state: n.state, pools: n.pools.length, disks, total, used: total - free };
  });
}
