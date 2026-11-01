// guests.ts — `health-manager guests [<node>] --json`: each guest's memory and
// the ZFS volumes behind it, by module. The memory is nodeCapacity's, the
// balloon figures included; the volumes are `zfs list` on the node. What a page
// reads to say what uses a node (the console's Memory by module, Storage used
// by modules). Read-only.

import { GuestMemory, GuestVolume, NodeCapacity, NodeCpu } from "./types";

export interface GuestRow extends GuestMemory {
  module: string | null; // the deployed instance with this vmid; null: none
}

export interface VolumeRow extends GuestVolume {
  module: string | null;
  replica: boolean; // a guest running on another node: this is its replicated copy
}

export interface NodeGuests {
  node: string;
  physicalMem: number;
  usedMem: number;
  committedMem: number;
  cpu: NodeCpu | null; // null: the node did not answer
  guests: GuestRow[];
  volumes: VolumeRow[];
}

// `zfs list -Hp -t filesystem,volume -o name,usedbydataset,usedbysnapshots,volsize`:
// the datasets Proxmox names after a vmid (vm-110-disk-0, subvol-200-disk-0,
// vm-110-cloudinit); a filesystem's volsize is "-". `used` is what the dataset
// itself holds on disk (after compression), not ZFS's `used`, which adds the
// snapshots and, on a thick zvol, the whole refreservation — a 64 GiB disk
// with 37 GiB written read 107 GiB that way. Snapshots are a column of their own.
export function parseVolumes(text: string): GuestVolume[] {
  const out: GuestVolume[] = [];
  for (const line of text.split("\n")) {
    const [name, used, snaps, size] = line.trim().split(/\s+/);
    const m = /^([^/]+)\/(?:.*\/)?((?:vm|subvol)-(\d+)-[^/]+)$/.exec(name ?? "");
    if (!m || !/^\d+$/.test(used ?? "")) continue;
    out.push({ pool: m[1], volume: m[2], vmid: Number(m[3]), used: Number(used), snapshots: /^\d+$/.test(snaps ?? "") ? Number(snaps) : 0, size: /^\d+$/.test(size ?? "") ? Number(size) : null });
  }
  return out;
}

// `lscpu -p=CORE,SOCKET`: a line per thread, so the distinct lines are the
// physical cores, over every socket. pvesh's cpuinfo.cores is left alone: what
// it counts on a machine of several sockets depends on the version.
export function parseCpu(text: string): NodeCpu | null {
  const lines = text.split("\n").map((l) => l.trim()).filter((l) => /^\d+,\d+$/.test(l));
  return lines.length ? { cores: new Set(lines).size, threads: lines.length } : null;
}

export function nodeGuests(caps: NodeCapacity[], volumes: Map<string, GuestVolume[]>, modules: Map<number, string>, cpus: Map<string, NodeCpu | null> = new Map()): NodeGuests[] {
  const homes = new Map(caps.flatMap((c) => c.guests.map((g) => [g.vmid, c.node] as [number, string])));
  return caps.map((c) => ({
    node: c.node,
    physicalMem: c.physicalMem,
    usedMem: c.usedMem,
    committedMem: c.committedMem,
    cpu: cpus.get(c.node) ?? null,
    guests: c.guests.map((g) => ({ ...g, module: modules.get(g.vmid) ?? null })).sort((a, b) => b.declaredMem - a.declaredMem),
    volumes: (volumes.get(c.node) ?? [])
      .map((v) => ({ ...v, module: modules.get(v.vmid) ?? null, replica: (homes.get(v.vmid) ?? c.node) !== c.node }))
      .sort((a, b) => b.used - a.used),
  }));
}
