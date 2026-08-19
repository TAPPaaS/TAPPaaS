// client.ts — CliClusterClient: the real ClusterClient implementation.
//
// A thin FFI boundary that shells out to ping / ssh / pvesh / qm, exactly as
// network-manager's CliPlaneClient shells out to the plane controllers. NO
// Proxmox logic is reimplemented here. The inspection logic (inspect.ts) and the
// health gates (checks.ts) depend only on the ClusterClient interface, so tests
// inject an in-memory fake and never touch SSH.
//
// Mirrors inspect-cluster.sh / inspect-vm.sh / check-disk-threshold.sh:
//   reachableNodes() : site.json node list, ping-probed; tappaas{1..9} scan fallback
//   clusterResources(): ssh root@<node> pvesh get /cluster/resources --type vm --output-format json
//   vmConfig()       : ssh root@<node> qm|pct config <vmid>       (#465)
//   vmStatus()       : ssh root@<node> qm|pct status <vmid>       → status word
//   actualNode()     : pvesh /cluster/resources | select vmid
//   diskUsagePct()   : ssh tappaas@<target> df / | tail -1 | awk '{print $5}'

import {
  defaultNodeCandidates,
  mgmtDomain,
  queryClusterGuests,
  reachableNodes as pingReachableNodes,
  ssh,
} from "../../../lib/ts/src/cluster";
import { defaultConfigDir, siteNodeHostnames } from "./config";
import { ClusterClient, RunningGuest } from "./types";

export class CliClusterClient implements ClusterClient {
  reachableNodes(): string[] {
    // Primary source: site.json .hardware.nodes[].name (the bash
    // get_all_node_hostnames path). defaultNodeCandidates falls back to the
    // tappaas1..9 scan only when site.json yields no nodes — exactly as
    // inspect-cluster.sh does. Either way each candidate is ping-probed (at
    // <name>.<mgmtDomain()>) so only reachable nodes are returned.
    return pingReachableNodes(defaultNodeCandidates(siteNodeHostnames(defaultConfigDir())));
  }

  clusterResources(): RunningGuest[] {
    const nodes = this.reachableNodes();
    if (nodes.length === 0) throw new Error("No Proxmox nodes reachable");
    // queryClusterGuests returns null on ANY failure (no ssh, non-zero rc, bad
    // JSON) — for THIS manager that is a throw (health asserts, never degrades).
    const guests = queryClusterGuests(nodes[0]);
    if (guests === null) throw new Error("Failed to query cluster resources");
    return guests.map((g) => ({
      vmid: g.vmid,
      name: g.name,
      node: g.node,
      status: g.status,
      type: g.type,
    }));
  }

  // `qm` answers for a QEMU VM, `pct` for an LXC container; against the wrong
  // kind of guest the CLI fails outright (#465). This client has no guest-type
  // input of its own, so it tries qm and falls back to pct — the module-manager
  // inspect path derives the type from pvesh instead, which it already queries.
  vmConfig(node: string, vmid: number): Record<string, string> {
    let r = ssh("root", `${node}.${mgmtDomain()}`, `qm config ${vmid}`);
    if (!r.ran || r.rc !== 0) r = ssh("root", `${node}.${mgmtDomain()}`, `pct config ${vmid}`);
    if (!r.ran || r.rc !== 0) {
      throw new Error(`Failed to get VM config from Proxmox (VMID: ${vmid} on ${node})`);
    }
    const out: Record<string, string> = {};
    for (const line of r.stdout.split("\n")) {
      const idx = line.indexOf(":");
      if (idx <= 0) continue;
      const key = line.slice(0, idx).trim();
      const value = line.slice(idx + 1).trim();
      if (key) out[key] = value;
    }
    return out;
  }

  vmStatus(node: string, vmid: number): string {
    let r = ssh("root", `${node}.${mgmtDomain()}`, `qm status ${vmid}`);
    if (!r.ran || r.rc !== 0) r = ssh("root", `${node}.${mgmtDomain()}`, `pct status ${vmid}`);
    if (!r.ran || r.rc !== 0) return "unknown";
    // "status: running" → "running"
    const parts = r.stdout.trim().split(/\s+/);
    return parts[1] ?? "unknown";
  }

  actualNode(node: string, vmid: number): string {
    const r = ssh(
      "root",
      `${node}.${mgmtDomain()}`,
      "pvesh get /cluster/resources --type vm --output-format json",
    );
    if (!r.ran || r.rc !== 0) return "";
    try {
      const arr = JSON.parse(r.stdout);
      if (!Array.isArray(arr)) return "";
      for (const e of arr) {
        const o = e as Record<string, unknown>;
        if (Number(o.vmid) === vmid && typeof o.node === "string") return o.node;
      }
    } catch {
      return "";
    }
    return "";
  }

  diskUsagePct(target: string): number | null {
    // Reachability probe first (check-disk-threshold.sh skips unreachable guests).
    const probe = ssh("tappaas", target, "exit 0");
    if (!probe.ran || probe.rc !== 0) return null;
    const r = ssh("tappaas", target, "df / | tail -1 | awk '{print $5}'");
    if (!r.ran || r.rc !== 0) return null;
    const pct = Number(r.stdout.trim().replace("%", ""));
    return Number.isFinite(pct) ? pct : null;
  }
}
