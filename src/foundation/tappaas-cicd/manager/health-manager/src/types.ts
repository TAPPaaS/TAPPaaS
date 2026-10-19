// types.ts — the health-manager entity model + the ClusterClient interface
// (the Proxmox/cluster boundary) and the check/validate result shapes.
//
// health-manager is READ-ONLY: it surfaces the live cluster against the module
// config; it never writes config and never reconciles. The CRUD entities of the
// other managers (add/modify/delete/reconcile) are N/A here.

// ── A running guest as Proxmox reports it (pvesh /cluster/resources) ───
export interface RunningGuest {
  vmid: number;
  name: string;
  node: string;
  status: string; // running | stopped | ...
  type: "qemu" | "lxc";
}

// ── A module as the deployed config (config/<module>.json) describes it ─
// `status` mirrors inspect-cluster.sh: archived (#215) / external (#216) /
// implicit-active (empty).
export interface ConfigModule {
  module: string; // basename of the JSON (the module name)
  vmid: number;
  node: string;
  status: string; // "", "archived", "external", ...
  suspended?: boolean; // paused by `module-manager suspend` (#428): stopped on purpose
}

// ── `list vm` (no --diff): one row of the cluster overview ─────────────
// `config` classifies the running guest against the config set, exactly as
// inspect-cluster.sh's "Config" column does.
export type ConfigMatch = "managed" | "external" | "not-in-config";

export interface ClusterRow {
  vmid: number;
  name: string;
  node: string;
  type: "vm" | "ct";
  status: string;
  config: ConfigMatch;
}

// A configured module whose VM is not currently running (the inverse view).
export type MissingKind = "missing" | "archived" | "external";
export interface MissingModule {
  vmid: number;
  module: string;
  node: string;
  kind: MissingKind;
}

export interface ClusterInspection {
  rows: ClusterRow[];
  missing: MissingModule[];
  warnings: number; // running-but-not-in-config count
  missingCount: number; // genuinely-not-running (excludes archived/external)
}

// ── `show vm <name>` (= inspect-vm.sh): the three-way drift table ──────
// Released = git source JSON (the module's `location`); Desired = config/<m>.json;
// Actual = the running VM via Proxmox. A field is "warn" when Desired != Released
// (config drift) and "error" when Actual != Desired (VM drift).
export type DriftLevel = "ok" | "warn" | "error";

export interface DriftRow {
  field: string;
  released: string; // git value (orig)
  desired: string; // config value
  actual: string; // live value
  level: DriftLevel;
}

export interface VmInspection {
  module: string;
  vmname: string;
  vmid: number;
  node: string;
  rows: DriftRow[];
  warnings: number;
  errors: number;
}

// ── `list vm --diff`: the per-VM three-way rollup ─────────────────────
// Runs the inspectVm three-way (orig/config/running) for every MANAGED config
// module and rolls up the per-VM drift counts. `unreachable` collects modules
// whose live VM could not be queried (so the rollup degrades cleanly instead of
// aborting the whole cluster diff on one bad node).
export interface ClusterDiff {
  vms: VmInspection[];
  unreachable: { module: string; error: string }[];
  warnings: number; // total config-vs-git drift across all VMs
  errors: number; // total actual-vs-config drift across all VMs
}

// ── ClusterClient — one method per cluster primitive ──────────────────
// The inspection logic depends ONLY on this interface; tests inject an
// in-memory fake, production uses CliClusterClient (ssh + pvesh + qm).
// ── node capacity (#569) ──────────────────────────────────────────────
// Physical RAM against the memory COMMITTED to the guests running on it. The
// distinction that matters: `committed` is what the guests are entitled to,
// `used` is what the host has actually handed out. Without ballooning those
// converge, which is exactly why the ratio is worth reporting.
export interface NodeCapacity {
  node: string;
  physicalMem: number; // bytes
  usedMem: number; // bytes the host reports in use (guests + ARC + overhead)
  committedMem: number; // sum of maxmem over RUNNING guests
  guests: GuestMemory[];
}

export interface GuestMemory {
  vmid: number;
  name: string;
  node: string;
  status: string;
  type: "qemu" | "lxc" | string;
  declaredMem: number; // bytes the guest is configured for (a LIMIT for lxc)
  usedMem: number; // bytes the guest reports using — only meaningful if `measured`
  residentMem: number; // bytes the HOST actually has backed for it (0 = unknown)
  // True only when the balloon statistics carry `free_mem` — i.e. the usage
  // figure genuinely came from inside the guest. NOT the same as "an agent
  // answered": the FreeBSD agent on an OPNsense firewall answers `ping` and
  // `get-osinfo` while providing no memory statistics, and Proxmox then reports
  // the HOST's view as the guest's. That is how a firewall using 1.15G read as
  // 8.0G of 8.0G — its `mem` even exceeded its `maxmem`.
  measured: boolean;
}

// ── AVX-512 use inside a guest (#827) ─────────────────────────────────
// The kernel keeps, per process, how long ago it last used AVX-512
// (/proc/<pid>/arch_status, AVX512_elapsed_ms; -1 = never). That is the one
// instruction family a common CPU level drops on hrossen-like pairs, and the
// only one with a counter: AVX2 and below have none.
export interface Avx512Use {
  available: boolean; // the guest's CPU offers AVX-512 at all
  recent: string[]; // processes that used it within the last minute
  earlier: string[]; // used it before that
}

// ── a storage pool on a node (#100) ───────────────────────────────────
// Proxmox's own numbers (pvesh /cluster/resources): `used` counts a thick
// disk's full size, so it is what decides whether a grow fits. `provisioned`
// is the sum of the pool's disk sizes, thin ones included — above `total` the
// pool is overcommitted and only stays healthy while the thin disks stay
// partly empty. -1 when it could not be read.
export interface StoragePool {
  node: string;
  storage: string;
  type: string; // plugintype: zfspool, lvmthin, dir, …
  total: number; // bytes
  used: number; // bytes
  provisioned: number; // bytes, -1 = unknown
}

export interface ClusterClient {
  // Hostnames of the reachable Proxmox nodes (ping-probed).
  reachableNodes(): string[];
  // Cluster-wide running guests (pvesh /cluster/resources --type vm).
  clusterResources(): RunningGuest[];
  // `qm config <vmid>` on <node>, parsed into key→value pairs.
  vmConfig(node: string, vmid: number): Record<string, string>;
  // `qm status <vmid>` → the status word (running/stopped/…).
  vmStatus(node: string, vmid: number): string;
  // The node a VM is actually running on (may differ from config if migrated).
  actualNode(node: string, vmid: number): string;
  // Disk-usage percentage of `/` on a guest (via SSH); null if unreachable.
  diskUsagePct(target: string): number | null;
  // Per-node physical/used/committed memory and the guests behind it (#569).
  nodeCapacity(): NodeCapacity[];
  // Whether a guest is waiting for a reboot (via SSH); null if unreachable (#730).
  pendingReboot(target: string): PendingReboot | null;
  // Every active guest-disk pool on every node (#100); backup stores excluded.
  storagePools(): StoragePool[];
  // AVX-512 use in a guest (via SSH); null if unreachable (#827).
  avx512Use(target: string): Avx512Use | null;
  // The timezone a node or a guest runs; null if unreachable or it does not say (#837).
  nodeTimezone(node: string): string | null;
  // Corosync's votes and whether a QDevice gives one (pvecm status); null if no
  // node answers (#835).
  quorum(): { expectedVotes: number; qdevice: boolean } | null;
  // The backup node's pulse (ADR-031): its timer's state and each target's
  // state (up / failing / DOWN); null if the node does not answer.
  pulse(node: string): { timer: string; targets: { id: string; state: string }[] } | null;
  guestTimezone(target: string): string | null;
  // #40: the node's lan uplink as the cluster module's lan-uplink.sh judges it
  // (declared vs live, legs, LACP, LLDP, fencing); null if it cannot say.
  lanUplink(node: string): LanUplink | null;
}

// ── a node's lan uplink (#40) ──────────────────────────────────────────
// What lan-uplink.sh show --json reports: the live mode and ports, and its
// findings. The rules live in the cluster module, beside the converge.
export interface LanUplink {
  mode: string; // single | active-backup | lacp
  ports: string[]; // the lan bridge's physical ports
  findings: { level: "warn" | "info"; text: string }[];
}

// ── a guest waiting for a reboot (#730) ───────────────────────────────
// DERIVED on the guest, never stored: a recorded flag goes stale the moment
// someone reboots by hand, the derived one cannot. NixOS: the booted system is
// not the system profile (a switched generation whose kernel is not running,
// or a release move staged for the next boot, #728). Debian:
// /var/run/reboot-required.
export interface PendingReboot {
  os: "nixos" | "debian" | "other";
  pending: boolean;
  booted: string; // NixOS system the guest booted ("" when not NixOS)
  next: string; // NixOS system the next boot takes
  // The next system is already ACTIVE (switched: its userspace runs, the kernel
  // is the booted one's) — false when it is only staged for the next boot, as
  // a release move is since #728, and the guest still runs `booted` entirely.
  active: boolean;
}

// ── validate (health gate) result shapes ──────────────────────────────
// "warn" is reported and coloured but does NOT fail the assertion: it is the
// band between healthy and critical, where an operator should look before the
// machine makes them.
export type CheckStatus = "pass" | "fail" | "warn" | "skip";

// A gate that reports per-subject rather than per-cluster renders its rows
// beneath its own line. The gate's status is the worst row's.
export interface CheckRow {
  status: CheckStatus;
  text: string;
  // What the row is about, for a reader that places it (validate --json, the
  // console): absent on a total or a site-wide line.
  subject?: CheckSubject;
}

// The object a finding mentions. A module is named as config/<module>.json
// names it; a pool is "<node>/<storage>"; a peer is a backup buddy (ADR-031).
export interface CheckSubject {
  kind: "module" | "node" | "pool" | "peer" | "site" | "switch" | "port"; // a port is "<switch>:<port>"
  name: string;
}

export interface CheckResult {
  name: string; // "disk-threshold", "backup-status", "service-liveness"
  status: CheckStatus;
  detail: string;
  rows?: CheckRow[];
  // Per-object findings of a gate that prints none beneath its line (its detail
  // carries them): validate --json reports these, the text output does not.
  findings?: CheckRow[];
}

export interface HealthReport {
  checks: CheckResult[];
  failed: number;
}
