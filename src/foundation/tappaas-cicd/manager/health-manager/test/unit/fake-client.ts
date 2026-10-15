// fake-client.ts — in-memory ClusterClient for offline inspection/health unit
// tests. No SSH, no Proxmox; tests seed running guests + per-VM config and
// disk-usage answers, then assert the classification the pure logic produces.

import { Avx512Use, ClusterClient, NodeCapacity, PendingReboot, RunningGuest, StoragePool } from "../../src/types";

export class FakeClusterClient implements ClusterClient {
  nodes: string[] = ["tappaas1"];
  guests: RunningGuest[] = [];
  configs = new Map<string, Record<string, string>>(); // `${node}/${vmid}` → qm config
  statuses = new Map<string, string>(); // `${node}/${vmid}` → status word
  actualNodes = new Map<string, string>(); // `${node}/${vmid}` → live node
  diskUsage = new Map<string, number | null>(); // target → pct (null = unreachable)
  capacity: NodeCapacity[] = []; // #569: seeded per-node memory picture
  capacityThrows: string | null = null; // simulate an unreachable cluster
  reboots = new Map<string, PendingReboot | null>(); // target → pending state (null = unreachable)
  pools: StoragePool[] = []; // #100: seeded storage pools
  avx = new Map<string, Avx512Use | null>(); // #827: target → AVX-512 use (null = unreachable)
  poolsThrow: string | null = null;
  zones = new Map<string, string | null>(); // #837: target → timezone (null/absent = unreachable)

  reachableNodes(): string[] {
    return [...this.nodes];
  }
  clusterResources(): RunningGuest[] {
    return this.guests.map((g) => ({ ...g }));
  }
  vmConfig(node: string, vmid: number): Record<string, string> {
    const c = this.configs.get(`${node}/${vmid}`);
    if (!c) throw new Error(`no fake qm config for ${node}/${vmid}`);
    return { ...c };
  }
  vmStatus(node: string, vmid: number): string {
    return this.statuses.get(`${node}/${vmid}`) ?? "unknown";
  }
  actualNode(node: string, vmid: number): string {
    return this.actualNodes.get(`${node}/${vmid}`) ?? node;
  }
  diskUsagePct(target: string): number | null {
    return this.diskUsage.has(target) ? (this.diskUsage.get(target) as number | null) : null;
  }
  nodeCapacity(): NodeCapacity[] {
    if (this.capacityThrows) throw new Error(this.capacityThrows);
    return this.capacity.map((c) => ({ ...c, guests: c.guests.map((g) => ({ ...g })) }));
  }
  pendingReboot(target: string): PendingReboot | null {
    const p = this.reboots.get(target);
    return p ? { ...p } : null;
  }
  avx512Use(target: string): Avx512Use | null {
    const a = this.avx.get(target);
    return a ? { ...a } : null;
  }
  quorumState: { expectedVotes: number; qdevice: boolean } | null = null; // #835
  quorum(): { expectedVotes: number; qdevice: boolean } | null {
    return this.quorumState ? { ...this.quorumState } : null;
  }
  nodeTimezone(node: string): string | null {
    return this.zones.get(node) ?? null;
  }
  guestTimezone(target: string): string | null {
    return this.zones.get(target) ?? null;
  }
  storagePools(): StoragePool[] {
    if (this.poolsThrow) throw new Error(this.poolsThrow);
    return this.pools.map((p) => ({ ...p }));
  }
}
