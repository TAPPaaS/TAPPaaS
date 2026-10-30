// guests.ts — `health-manager guests [<node>] --json`: each guest's memory and
// the ZFS volumes behind it, by module. The memory is nodeCapacity's, the
// balloon figures included; the volumes are `zfs list` on the node. What a page
// reads to say what uses a node (the console's Memory by module, Storage used
// by modules). Read-only.

import { GuestMemory, GuestVolume, NodeCapacity } from "./types";

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
  guests: GuestRow[];
  volumes: VolumeRow[];
}

// `zfs list -Hp -t filesystem,volume -o name,used,volsize`: the datasets Proxmox
// names after a vmid (vm-110-disk-0, subvol-200-disk-0, vm-110-cloudinit); a
// filesystem's volsize is "-".
export function parseVolumes(text: string): GuestVolume[] {
  const out: GuestVolume[] = [];
  for (const line of text.split("\n")) {
    const [name, used, size] = line.trim().split(/\s+/);
    const m = /^([^/]+)\/(?:.*\/)?((?:vm|subvol)-(\d+)-[^/]+)$/.exec(name ?? "");
    if (!m || !/^\d+$/.test(used ?? "")) continue;
    out.push({ pool: m[1], volume: m[2], vmid: Number(m[3]), used: Number(used), size: /^\d+$/.test(size ?? "") ? Number(size) : 0 });
  }
  return out;
}

export function nodeGuests(caps: NodeCapacity[], volumes: Map<string, GuestVolume[]>, modules: Map<number, string>): NodeGuests[] {
  const homes = new Map(caps.flatMap((c) => c.guests.map((g) => [g.vmid, c.node] as [number, string])));
  return caps.map((c) => ({
    node: c.node,
    physicalMem: c.physicalMem,
    usedMem: c.usedMem,
    committedMem: c.committedMem,
    guests: c.guests.map((g) => ({ ...g, module: modules.get(g.vmid) ?? null })).sort((a, b) => b.declaredMem - a.declaredMem),
    volumes: (volumes.get(c.node) ?? [])
      .map((v) => ({ ...v, module: modules.get(v.vmid) ?? null, replica: (homes.get(v.vmid) ?? c.node) !== c.node }))
      .sort((a, b) => b.used - a.used),
  }));
}
