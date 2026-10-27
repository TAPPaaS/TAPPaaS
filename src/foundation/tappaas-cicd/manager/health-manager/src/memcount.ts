// memcount.ts — what a running guest commits on its node (#569, #891).
//
// A VM commits its configured memory: without ballooning the host keeps every
// page the guest has touched, so its full size is what the node must be able
// to hold. A container's memory setting is a ceiling the kernel enforces, not
// memory set aside — containers share the host's and take only what they use.
// Counting a container at its limit made a node read as full that was not
// (hrossen: 46 GB of container limits, 2.9 GB used). So a container counts at
// its highest use over the last week plus a quarter, at least LXC_FLOOR and at
// most its limit; with no history yet (just installed) at its limit.

import { GuestMemory } from "./types";

const MIB = 1024 ** 2;
export const LXC_FLOOR = 512 * MIB;
export const LXC_MARGIN = 1.25;

// `limit` overrides the guest's own (the limit a release sets).
export function countedMem(g: Pick<GuestMemory, "type" | "declaredMem" | "peakMem">, limit = g.declaredMem): number {
  if (g.type !== "lxc") return limit;
  const peak = g.peakMem ?? 0;
  if (!(peak > 0)) return limit;
  return Math.min(limit, Math.max(LXC_FLOOR, peak * LXC_MARGIN));
}
