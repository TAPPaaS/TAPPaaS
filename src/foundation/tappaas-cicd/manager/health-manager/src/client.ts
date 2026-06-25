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
//   vmConfig()       : ssh root@<node> qm config <vmid>
//   vmStatus()       : ssh root@<node> qm status <vmid>           → status word
//   actualNode()     : pvesh /cluster/resources | select vmid
//   diskUsagePct()   : ssh tappaas@<target> df / | tail -1 | awk '{print $5}'

import { spawnSync } from "child_process";
import { defaultConfigDir, siteNodeHostnames } from "./config";
import { ClusterClient, RunningGuest } from "./types";

const MGMT = "mgmt";

interface Run {
  rc: number;
  stdout: string;
  stderr: string;
  ran: boolean;
}

function run(cmd: string, args: string[]): Run {
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) return { rc: -1, stdout: "", stderr: r.error.message, ran: false };
  return { rc: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "", ran: true };
}

// ssh root@<node>.mgmt.internal "<remote>" with a short connect timeout.
function ssh(user: string, host: string, remote: string): Run {
  return run("ssh", [
    "-o",
    "ConnectTimeout=5",
    "-o",
    "BatchMode=yes",
    `${user}@${host}`,
    remote,
  ]);
}

export class CliClusterClient implements ClusterClient {
  reachableNodes(): string[] {
    // Primary source: site.json .hardware.nodes[].name (the bash
    // get_all_node_hostnames path). Fall back to scanning tappaas1..9 only when
    // site.json yields no nodes — exactly as inspect-cluster.sh does. Either way
    // each candidate is ping-probed so only reachable nodes are returned.
    let candidates = siteNodeHostnames(defaultConfigDir());
    if (candidates.length === 0) {
      candidates = Array.from({ length: 9 }, (_, i) => `tappaas${i + 1}`);
    }
    const out: string[] = [];
    for (const node of candidates) {
      const r = run("ping", ["-c", "1", "-W", "1", `${node}.${MGMT}.internal`]);
      if (r.ran && r.rc === 0) out.push(node);
    }
    return out;
  }

  clusterResources(): RunningGuest[] {
    const nodes = this.reachableNodes();
    if (nodes.length === 0) throw new Error("No Proxmox nodes reachable");
    const r = ssh(
      "root",
      `${nodes[0]}.${MGMT}.internal`,
      "pvesh get /cluster/resources --type vm --output-format json",
    );
    if (!r.ran || r.rc !== 0) throw new Error("Failed to query cluster resources");
    let arr: unknown;
    try {
      arr = JSON.parse(r.stdout);
    } catch {
      throw new Error("Cluster resources not valid JSON");
    }
    if (!Array.isArray(arr)) return [];
    const out: RunningGuest[] = [];
    for (const e of arr) {
      const o = e as Record<string, unknown>;
      const type = typeof o.type === "string" ? o.type : "";
      if (type !== "qemu" && type !== "lxc") continue;
      out.push({
        vmid: typeof o.vmid === "number" ? o.vmid : Number(o.vmid),
        name: typeof o.name === "string" ? o.name : "unknown",
        node: typeof o.node === "string" ? o.node : "unknown",
        status: typeof o.status === "string" ? o.status : "unknown",
        type: type as "qemu" | "lxc",
      });
    }
    return out;
  }

  vmConfig(node: string, vmid: number): Record<string, string> {
    const r = ssh("root", `${node}.${MGMT}.internal`, `qm config ${vmid}`);
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
    const r = ssh("root", `${node}.${MGMT}.internal`, `qm status ${vmid}`);
    if (!r.ran || r.rc !== 0) return "unknown";
    // "status: running" → "running"
    const parts = r.stdout.trim().split(/\s+/);
    return parts[1] ?? "unknown";
  }

  actualNode(node: string, vmid: number): string {
    const r = ssh(
      "root",
      `${node}.${MGMT}.internal`,
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
