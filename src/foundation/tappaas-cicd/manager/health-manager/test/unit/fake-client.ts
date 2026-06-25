// fake-client.ts — in-memory ClusterClient for offline inspection/health unit
// tests. No SSH, no Proxmox; tests seed running guests + per-VM config and
// disk-usage answers, then assert the classification the pure logic produces.

import { ClusterClient, RunningGuest } from "../../src/types";

export class FakeClusterClient implements ClusterClient {
  nodes: string[] = ["tappaas1"];
  guests: RunningGuest[] = [];
  configs = new Map<string, Record<string, string>>(); // `${node}/${vmid}` → qm config
  statuses = new Map<string, string>(); // `${node}/${vmid}` → status word
  actualNodes = new Map<string, string>(); // `${node}/${vmid}` → live node
  diskUsage = new Map<string, number | null>(); // target → pct (null = unreachable)

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
}
