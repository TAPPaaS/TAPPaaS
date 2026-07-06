// cluster.ts — shared Proxmox-cluster query helpers (ADR-007 post-
// implementation refactor, Phase 3). Deduplicates the ssh/reachableNodes/
// clusterResources block that health-manager and module-manager used to
// copy-paste (and that had already drifted: one copy hardcoded the mgmt
// domain, the other made it overridable — the overridable variant wins).
//
// NOTE (F12, parked): these helpers ssh straight to the nodes (pvesh/qm) —
// the documented manager→proxmox-controller boundary question is tracked in
// docs/design/ADR007-post-implement-refactor.md §6 "Parked".

import { spawnSync } from "child_process";

// The mgmt-zone DNS suffix nodes/guests are addressed under. Overridable for
// tests and relocated sites (replaces module-manager's MM_MGMT_DOMAIN).
export function mgmtDomain(): string {
  return process.env.TAPPAAS_MGMT_DOMAIN ?? "mgmt.internal";
}

export interface RemoteResult {
  rc: number;
  stdout: string;
  stderr: string;
  // false when the binary could not be spawned at all.
  ran: boolean;
}

function runLocal(cmd: string, args: string[]): RemoteResult {
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) return { rc: -1, stdout: "", stderr: r.error.message, ran: false };
  return { rc: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "", ran: true };
}

// ssh <user>@<host> "<remote>" with a short connect timeout + batch mode (no
// interactive prompts). host is a full hostname/FQDN — callers append
// mgmtDomain() themselves where applicable.
export function ssh(user: string, host: string, remote: string): RemoteResult {
  return runLocal("ssh", [
    "-o",
    "ConnectTimeout=5",
    "-o",
    "BatchMode=yes",
    `${user}@${host}`,
    remote,
  ]);
}

// Ping-probe candidate node names (bare names, probed at <name>.<mgmtDomain>)
// and return the reachable ones. When the caller has no site.json-derived
// candidates, pass defaultNodeCandidates([]) to get the tappaas1..9 scan
// fallback (mirrors inspect-cluster.sh).
export function defaultNodeCandidates(siteNames: string[]): string[] {
  if (siteNames.length > 0) return siteNames;
  return Array.from({ length: 9 }, (_, i) => `tappaas${i + 1}`);
}

export function reachableNodes(candidates: string[]): string[] {
  const out: string[] = [];
  for (const node of candidates) {
    const r = runLocal("ping", ["-c", "1", "-W", "1", `${node}.${mgmtDomain()}`]);
    if (r.ran && r.rc === 0) out.push(node);
  }
  return out;
}

// Query the cluster's NODE membership via one reachable node. Returns the
// node names, or null on ANY failure (no ssh, non-zero rc, bad JSON).
// Uses /cluster/resources --type node — same endpoint family as the guest
// query, so one API surface covers both.
export function queryClusterNodes(node: string): string[] | null {
  const r = ssh(
    "root",
    `${node}.${mgmtDomain()}`,
    "pvesh get /cluster/resources --type node --output-format json",
  );
  if (!r.ran || r.rc !== 0) return null;
  let arr: unknown;
  try {
    arr = JSON.parse(r.stdout);
  } catch {
    return null;
  }
  if (!Array.isArray(arr)) return null;
  const out: string[] = [];
  for (const e of arr) {
    const o = e as Record<string, unknown>;
    if (o.type === "node" && typeof o.node === "string" && o.node.length > 0) {
      out.push(o.node);
    }
  }
  return out.sort();
}

// The tankXY zpools physically present on a node (the TAPPaaS storagePools
// naming convention) — mirrors create-site.sh's discovery: query the node
// directly with `zpool list` (the cluster storage.cfg lists pools that may
// not exist on every node). null on any failure.
export function queryNodeTankPools(node: string): string[] | null {
  const r = ssh("root", `${node}.${mgmtDomain()}`, "zpool list -H -o name 2>/dev/null");
  if (!r.ran || r.rc !== 0) return null;
  return r.stdout
    .split("\n")
    .map((s) => s.trim())
    .filter((s) => /^tank/.test(s))
    .sort();
}

// One row of `pvesh get /cluster/resources --type vm`.
export interface ClusterGuest {
  vmid: number;
  name: string;
  node: string;
  status: string;
  type: "qemu" | "lxc";
  template: boolean;
}

// Query the cluster's guest list via the first node. Returns null on ANY
// failure (no ssh, non-zero rc, bad JSON) — callers choose whether that is
// a throw (health-manager) or a degrade-to-empty (module-manager list).
export function queryClusterGuests(node: string): ClusterGuest[] | null {
  const r = ssh(
    "root",
    `${node}.${mgmtDomain()}`,
    "pvesh get /cluster/resources --type vm --output-format json",
  );
  if (!r.ran || r.rc !== 0) return null;
  let arr: unknown;
  try {
    arr = JSON.parse(r.stdout);
  } catch {
    return null;
  }
  if (!Array.isArray(arr)) return null;
  const out: ClusterGuest[] = [];
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
      template: o.template === 1 || o.template === true,
    });
  }
  return out;
}
