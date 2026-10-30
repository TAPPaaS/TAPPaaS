// balloon.ts — what a guest can actually use, from its balloon statistics.
//
// Proxmox computes a running VM's `mem` as the balloon's total minus free, and
// free is Linux's MemFree, near zero on any busy guest: page cache counts as
// used. tappaas-cicd read 93% of 16 GB with 1 GB in use and 14.6 GB of cache.
// The statistics QEMU keeps carry the right figure, stat-available-memory
// (Linux's MemAvailable), but Proxmox does not expose it, so it is read on the
// node with qom-get. A guest that reports nothing has every stat at 2^64-1 and
// last-update 0 (the FreeBSD firewall); a Windows guest has no available figure.

import { GuestMemory } from "./types";

export interface BalloonStats {
  total?: number; // bytes the guest's kernel manages
  available?: number; // bytes it could use without swapping
  cache?: number; // bytes of page cache
}

// One line per stat: `balloon <vmid> <stat> <bytes>`. Read-only, and a guest
// without a balloon device prints nothing.
export function balloonProbe(vmid: number): string {
  return (
    `echo 'qom-get /machine/peripheral/balloon0 guest-stats' | qm monitor ${vmid} 2>/dev/null | ` +
    `sed -n 's/.*"\\(stat-total-memory\\|stat-available-memory\\|stat-disk-caches\\)": \\([0-9]*\\).*/balloon ${vmid} \\1 \\2/p'`
  );
}

// 2^64-1 is QEMU's "no such statistic"; it does not fit a Number exactly, so
// anything of that order is treated as absent.
const reported = (v: number): boolean => Number.isFinite(v) && v < 2 ** 63;

export function parseBalloonStats(stdout: string): Map<number, BalloonStats> {
  const out = new Map<number, BalloonStats>();
  for (const line of stdout.split("\n")) {
    const f = line.trim().split(/\s+/);
    if (f.length !== 4 || f[0] !== "balloon") continue;
    const vmid = Number(f[1]);
    const bytes = Number(f[3]);
    if (!reported(bytes)) continue;
    const s = out.get(vmid) ?? {};
    if (f[2] === "stat-total-memory") s.total = bytes;
    else if (f[2] === "stat-available-memory") s.available = bytes;
    else if (f[2] === "stat-disk-caches") s.cache = bytes;
    out.set(vmid, s);
  }
  return out;
}

// Replace Proxmox's `mem` only when the guest gave both figures, and they make
// sense together. Otherwise the guest keeps what it had, and availableMem stays
// unset: the row then says cache counts as used.
export function applyBalloonStats(g: GuestMemory, s: BalloonStats | undefined): void {
  if (s?.total === undefined || s.available === undefined || s.available > s.total) return;
  g.usedMem = s.total - s.available;
  g.availableMem = s.available;
  g.cacheMem = s.cache;
  g.measured = true;
}
