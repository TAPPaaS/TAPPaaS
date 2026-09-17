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
import { ClusterClient, NodeCapacity, RunningGuest } from "./types";

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

  // #569: one /cluster/resources call answers both halves — the node rows carry
  // physical and used memory, the guest rows carry what each is configured for.
  // COMMITTED counts running guests only: a stopped guest holds nothing, and
  // counting it would report an overcommit the node is not living with.
  nodeCapacity(): NodeCapacity[] {
    const nodes = this.reachableNodes();
    if (nodes.length === 0) throw new Error("No Proxmox nodes reachable");
    const r = ssh("root", `${nodes[0]}.${mgmtDomain()}`,
      "pvesh get /cluster/resources --output-format json");
    if (r.rc !== 0) throw new Error("Failed to query cluster resources");
    let rows: Record<string, unknown>[];
    try {
      rows = JSON.parse(r.stdout) as Record<string, unknown>[];
    } catch {
      throw new Error("Failed to parse cluster resources");
    }
    const num = (v: unknown): number => (typeof v === "number" ? v : 0);
    const str = (v: unknown): string => (typeof v === "string" ? v : "");
    const caps = new Map<string, NodeCapacity>();
    for (const row of rows) {
      if (str(row.type) !== "node") continue;
      const n = str(row.node);
      caps.set(n, {
        node: n,
        physicalMem: num(row.maxmem),
        usedMem: num(row.mem),
        committedMem: 0,
        guests: [],
      });
    }
    for (const row of rows) {
      const type = str(row.type);
      if (type !== "qemu" && type !== "lxc") continue;
      const cap = caps.get(str(row.node));
      if (!cap) continue;
      const g = {
        vmid: num(row.vmid),
        name: str(row.name),
        node: str(row.node),
        status: str(row.status),
        type,
        declaredMem: num(row.maxmem),
        usedMem: num(row.mem),
        residentMem: 0,
        measured: type === "lxc", // a container has no agent and needs none
      };
      cap.guests.push(g);
      if (g.status === "running") cap.committedMem += g.declaredMem;
    }
    // Per node, ONE ssh answers both remaining questions: how much the host has
    // actually backed for each guest (RSS of its kvm process), and whether a
    // guest agent is answering at all. Without the second, `usedMem` is the
    // host's own view wearing the guest's clothes.
    for (const cap of caps.values()) {
      const vmids = cap.guests.filter((g) => g.type === "qemu" && g.status === "running").map((g) => g.vmid);
      if (vmids.length === 0) continue;
      // `free_mem` in the balloon statistics is the signal, NOT whether a guest
      // agent answers. The FreeBSD agent on an OPNsense firewall answers `ping`
      // and `get-osinfo` perfectly well while providing no memory statistics at
      // all — Proxmox then reports the HOST's view as the guest's usage, which
      // is how a VM using 1.15G read as 8.0G of 8.0G. Its `mem` even exceeded
      // its `maxmem`, which no guest-reported figure can do.
      const probe =
        `ps -eo rss,args | awk '/[k]vm -id/{for(i=1;i<=NF;i++) if($i=="-id") v=$(i+1); print "rss " v " " $1}'; ` +
        vmids
          .map(
            (v) =>
              `(qm status ${v} --verbose 2>/dev/null | grep -qE '^[[:space:]]*free_mem' && echo "stats ${v} 1" || echo "stats ${v} 0")`,
          )
          .join("; ");
      const r = ssh("root", `${cap.node}.${mgmtDomain()}`, probe);
      if (r.rc !== 0) continue; // a node we cannot reach leaves its guests unmeasured
      for (const line of r.stdout.split("\n")) {
        const f = line.trim().split(/\s+/);
        if (f.length !== 3) continue;
        const g = cap.guests.find((x) => x.vmid === Number(f[1]));
        if (!g) continue;
        if (f[0] === "rss") g.residentMem = Number(f[2]) * 1024; // ps reports KiB
        else if (f[0] === "stats") g.measured = f[2] === "1";
      }
    }
    return [...caps.values()].sort((a, b) => a.node.localeCompare(b.node));
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
