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
//   pendingReboot()  : ssh tappaas@<target> booted-system vs system profile (#730)

import {
  defaultNodeCandidates,
  mgmtDomain,
  queryClusterGuests,
  reachableNodes as pingReachableNodes,
  ssh,
} from "../../../lib/ts/src/cluster";
import { defaultConfigDir, siteNodeHostnames } from "./config";
import { Avx512Use, ClusterClient, NodeCapacity, PendingReboot, RunningGuest, StoragePool } from "./types";

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
      // A PVE template is the image modules are cloned FROM, not a module. It
      // holds no memory and reporting it as a stopped guest is noise.
      if (num(row.template) === 1) continue;
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

  // #730: one ssh answers it. On NixOS the booted system differs from the
  // system profile until a reboot takes the new generation; the release of
  // each says whether that is a release move (#728) or a kernel. Debian has
  // /var/run/reboot-required.
  pendingReboot(target: string): PendingReboot | null {
    const probe =
      "if [ -e /run/booted-system ]; then " +
      "b=$(readlink -f /run/booted-system); p=$(readlink -f /nix/var/nix/profiles/system); " +
      "c=$(readlink -f /run/current-system); " +
      '[ "$b" = "$p" ] && s=0 || s=1; [ "$c" = "$p" ] && a=1 || a=0; ' +
      'echo "nixos $s $(cat $b/nixos-version 2>/dev/null) $(cat $p/nixos-version 2>/dev/null) $a"; ' +
      "elif [ -f /etc/debian_version ]; then " +
      '[ -e /var/run/reboot-required ] && echo "debian 1" || echo "debian 0"; ' +
      'else echo "other 0"; fi';
    const r = ssh("tappaas", target, probe);
    if (!r.ran || r.rc !== 0) return null;
    return parsePendingReboot(r.stdout);
  }

  // #827: one ssh — does the guest's CPU offer AVX-512, and which processes
  // used it how long ago.
  avx512Use(target: string): Avx512Use | null {
    const probe =
      "grep -qw avx512f /proc/cpuinfo && echo cpu 1 || echo cpu 0; " +
      "for p in /proc/[0-9]*; do s=$(sed -n 's/^AVX512_elapsed_ms:[[:space:]]*//p' $p/arch_status 2>/dev/null); " +
      '[ -n "$s" ] && [ "$s" != -1 ] && echo "use $s $(cat $p/comm 2>/dev/null)"; done; true';
    const r = ssh("tappaas", target, probe);
    if (!r.ran || r.rc !== 0) return null;
    return parseAvx512Use(r.stdout);
  }

  // #837: timedatectl names the zone on Debian, Proxmox and NixOS alike.
  quorum(): { expectedVotes: number; qdevice: boolean } | null {
    for (const node of this.reachableNodes()) {
      const r = ssh("root", `${node}.${mgmtDomain()}`, "pvecm status");
      if (!r.ran || r.rc !== 0) continue;
      const votes = Number(/Expected votes:\s*(\d+)/.exec(r.stdout)?.[1] ?? "NaN");
      if (!Number.isFinite(votes)) continue;
      return { expectedVotes: votes, qdevice: /Qdevice/i.test(r.stdout) };
    }
    return null;
  }

  pulse(node: string): { timer: string; targets: { id: string; state: string }[] } | null {
    const r = ssh("root", node.includes(".") ? node : `${node}.${mgmtDomain()}`,
      "systemctl is-active tappaas-pulse.timer; /usr/local/sbin/tappaas-pulse --status 2>/dev/null; true");
    if (!r.ran) return null;
    const lines = r.stdout.split("\n");
    const targets = lines.slice(2).map((l) => l.trim().split(/\s+/)).filter((f) => f.length >= 2 && f[0])
      .map((f) => ({ id: f[0], state: f[1] }));
    return { timer: (lines[0] ?? "").trim(), targets };
  }

  nodeTimezone(node: string): string | null {
    return readTimezone(ssh("root", `${node}.${mgmtDomain()}`, TZ_PROBE));
  }
  guestTimezone(target: string): string | null {
    return readTimezone(ssh("tappaas", target, TZ_PROBE));
  }

  // #100: the pools from the cluster's own resource list, plus one `zfs list`
  // per node for what the zvols on each ZFS pool add up to.
  storagePools(): StoragePool[] {
    const nodes = this.reachableNodes();
    if (nodes.length === 0) throw new Error("No Proxmox nodes reachable");
    const r = ssh("root", `${nodes[0]}.${mgmtDomain()}`,
      "pvesh get /cluster/resources --type storage --output-format json");
    if (r.rc !== 0) throw new Error("Failed to query cluster storage");
    const rows = JSON.parse(r.stdout) as Record<string, unknown>[];
    const pools = parseStoragePools(rows);
    for (const n of new Set(pools.filter((p) => p.type === "zfspool").map((p) => p.node))) {
      const z = ssh("root", `${n}.${mgmtDomain()}`, "zfs list -Hp -t volume -o name,volsize");
      if (!z.ran || z.rc !== 0) continue;
      const sums = sumVolsizes(z.stdout);
      for (const p of pools) {
        if (p.node === n && p.type === "zfspool") p.provisioned = sums.get(p.storage) ?? 0;
      }
    }
    return pools;
  }
}

const TZ_PROBE = "timedatectl show -p Timezone --value";
function readTimezone(r: { ran: boolean; rc: number; stdout: string }): string | null {
  if (!r.ran || r.rc !== 0) return null;
  return r.stdout.trim() || null;
}

// Active, non-backup pools from `pvesh get /cluster/resources --type storage`.
// A shared store (PBS, NFS) is listed once per node; it holds no guest disks
// TAPPaaS grows, and the backup manager watches the backup store.
export function parseStoragePools(rows: Record<string, unknown>[]): StoragePool[] {
  const num = (v: unknown): number => (typeof v === "number" ? v : 0);
  const str = (v: unknown): string => (typeof v === "string" ? v : "");
  return rows
    .filter((r) => str(r.type) === "storage" && str(r.status) === "available"
      && num(r.shared) !== 1 && str(r.plugintype) !== "pbs" && num(r.maxdisk) > 0)
    .map((r) => ({
      node: str(r.node), storage: str(r.storage), type: str(r.plugintype),
      total: num(r.maxdisk), used: num(r.disk), provisioned: -1,
    }));
}

// `zfs list -Hp -t volume -o name,volsize` → bytes per top-level pool. A
// zfspool storage's id is its pool's name on TAPPaaS (tanka1, tankb1, …).
export function sumVolsizes(out: string): Map<string, number> {
  const m = new Map<string, number>();
  for (const line of out.split("\n")) {
    const [name, size] = line.trim().split(/\s+/);
    if (!name || !size || !/^\d+$/.test(size)) continue;
    const pool = name.split("/")[0];
    m.set(pool, (m.get(pool) ?? 0) + Number(size));
  }
  return m;
}

// `<os> <pending 0|1> [<booted> <next> <active 0|1>]` — the probe's last line
// (a login banner may precede it).
export function parsePendingReboot(out: string): PendingReboot | null {
  const f = (out.trim().split("\n").pop() ?? "").trim().split(/\s+/);
  if (f.length < 2 || (f[1] !== "0" && f[1] !== "1")) return null;
  const os = f[0] === "nixos" || f[0] === "debian" ? f[0] : "other";
  return { os, pending: f[1] === "1", booted: f[2] ?? "", next: f[3] ?? "", active: f[4] === "1" };
}

// `cpu <0|1>` then `use <ms> <comm>` per process (#827). Pure. A process name
// is counted once; "recent" means within the last minute.
export function parseAvx512Use(out: string): Avx512Use {
  const recent = new Set<string>();
  const earlier = new Set<string>();
  let available = false;
  for (const line of out.split("\n")) {
    const f = line.trim().split(/\s+/);
    if (f[0] === "cpu") available = f[1] === "1";
    if (f[0] === "use" && /^\d+$/.test(f[1] ?? "") && f[2]) {
      const name = f.slice(2).join(" ");
      if (Number(f[1]) <= 60000) recent.add(name);
      else earlier.add(name);
    }
  }
  for (const n of recent) earlier.delete(n);
  return { available, recent: [...recent].sort(), earlier: [...earlier].sort() };
}
