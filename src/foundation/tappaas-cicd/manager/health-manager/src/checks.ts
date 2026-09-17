// checks.ts — the health gates aggregated under `validate`.
//
// Per ADR-007 §Health, health `validate` is SPECIAL: it does not check that
// config is well-formed (that's the other managers) — it ASSERTS THE LIVE SYSTEM
// IS HEALTHY by running the health gates against the running cluster and exiting
// non-zero if any fail. The current check-*.sh scripts become these checks.
//
// Gates ported here:
//   - disk-threshold   (= check-disk-threshold.sh, READ-ONLY subset — see note)
//   - memory-commitment (#569: physical RAM vs what running guests are entitled to)
//   - guest-memory      (per guest: declared vs used vs host-resident)
//   - backup-status    (was check-backup-status.sh; reads `backup-manager list --json`)
//   - service-liveness (guest-agent ping / running-state — see TODO)

import { spawnSync } from "child_process";
import { join } from "path";
import { isManaged, loadConfigModules, readModuleJson } from "./config";
import { CheckResult, CheckStatus, ClusterClient, HealthReport, NodeCapacity } from "./types";

// Resolve a guest's `<vmname>.<zone0>.internal` target, as check-disk-threshold.sh
// does (defaulting zone0 to "mgmt"). We only need it for the SSH disk probe.
function diskTarget(configDir: string, module: string): string | null {
  const raw = readModuleJson(join(configDir, `${module}.json`));
  if (!raw) return null;
  const vmname = typeof raw.vmname === "string" && raw.vmname ? raw.vmname : module;
  const zone0 = typeof raw.zone0 === "string" && raw.zone0 ? raw.zone0 : "mgmt";
  return `${vmname}.${zone0}.internal`;
}

// ── disk-threshold gate ───────────────────────────────────────────────
// check-disk-threshold.sh ALSO auto-grows the disk by 50% when over threshold.
// That is a MUTATION and does NOT belong in a read-only health assertion, so the
// gate here only ASSERTS usage < threshold (the resize stays in the .sh / an ops
// tool). A guest over threshold = FAIL; unreachable = SKIP (matches the .sh,
// which warns + exits 0 when a VM is unreachable).
export function checkDiskThreshold(
  client: ClusterClient,
  configDir: string,
  defaultNode: string,
  threshold: number,
): CheckResult {
  const modules = loadConfigModules(configDir, defaultNode).filter(isManaged);
  const over: string[] = [];
  let probed = 0;
  for (const m of modules) {
    const target = diskTarget(configDir, m.module);
    if (!target) continue;
    const pct = client.diskUsagePct(target);
    if (pct === null) continue; // unreachable → skip this guest
    probed++;
    if (pct >= threshold) over.push(`${m.module} (${pct}%)`);
  }
  if (probed === 0) {
    return { name: "disk-threshold", status: "skip", detail: "no reachable guests probed" };
  }
  if (over.length > 0) {
    return {
      name: "disk-threshold",
      status: "fail",
      detail: `over ${threshold}%: ${over.join(", ")}`,
    };
  }
  return {
    name: "disk-threshold",
    status: "pass",
    detail: `${probed} guest(s) under ${threshold}%`,
  };
}

// ── backup-status gate (was check-backup-status.sh) ───────────────────
// Shells out to the TS `backup-manager list --json` (which replaced the retired
// backup-status.sh — a JSON array of {module, environment, enabled, retention,
// residency, optedIn, archived, inPbsJob}) and flags modules that are DISABLED
// or opted-in-but-not-in-the-PBS-job. Skips cleanly when the backup tooling is
// unavailable (preserves the historical exit-0 behavior).
//
// #627 split the DECLARATION (optedIn) from real job membership (inPbsJob).
// Before that this gate had only the merged flag, and read it as membership:
// every module that had never declared backup:vm — `cluster`, `templates`,
// anything provider-only — was reported "not in PBS job", so the gate stood
// FAIL on a healthy cluster and the failure carried no information. Backup is
// OPT-IN (ADR-012 §3.1); only a module that asked and did not get it is a
// finding.
const BACKUP_MANAGER_BIN = process.env.BACKUP_MANAGER_BIN ?? "backup-manager";

export function checkBackupStatus(configDir: string): CheckResult {
  const r = spawnSync(BACKUP_MANAGER_BIN, ["list", "--config-dir", configDir, "--json"], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error || r.status !== 0) {
    return { name: "backup-status", status: "skip", detail: "backup tooling unavailable" };
  }
  let arr: unknown;
  try {
    arr = JSON.parse(r.stdout ?? "");
  } catch {
    return { name: "backup-status", status: "skip", detail: "backup status not parseable" };
  }
  if (!Array.isArray(arr)) {
    return { name: "backup-status", status: "skip", detail: "no backup entries" };
  }
  // A backup-manager that predates the split cannot answer this: its inPbsJob
  // IS the declaration, so "opted in but not a member" is not expressible.
  // Say so rather than passing an unasked question (or re-raising the old
  // false FAIL).
  if (arr.length > 0 && !("optedIn" in (arr[0] as Record<string, unknown>))) {
    return {
      name: "backup-status",
      status: "skip",
      detail: "backup status predates the optedIn/inPbsJob split (#627)",
    };
  }
  const disabled: string[] = [];
  const uncovered: string[] = [];
  for (const e of arr) {
    const o = e as Record<string, unknown>;
    const mod = typeof o.module === "string" ? o.module : "?";
    if (o.enabled === false) disabled.push(mod);
    // archived: the VM was deliberately destroyed and its snapshots kept, so
    // absence from the job is the correct state, not a coverage gap.
    else if (o.enabled === true && o.optedIn === true && o.archived !== true && o.inPbsJob === false)
      uncovered.push(mod);
  }
  if (disabled.length === 0 && uncovered.length === 0) {
    return { name: "backup-status", status: "pass", detail: `${arr.length} module(s) covered` };
  }
  const parts: string[] = [];
  if (disabled.length) parts.push(`disabled: ${disabled.join(", ")}`);
  if (uncovered.length) parts.push(`not in PBS job: ${uncovered.join(", ")}`);
  return { name: "backup-status", status: "fail", detail: parts.join("; ") };
}

// ── service-liveness gate ─────────────────────────────────────────────
// TODO(question): "service liveness" is listed in ADR-007 §Health ("…, service
// liveness, …") but there is no check-service-liveness.sh today. The DESIGN.md
// mentions `qm guest cmd <vmid> ping` (guest-agent health). Two candidate
// definitions: (a) every MANAGED config module's VM is in pvesh status=running;
// (b) additionally guest-agent ping responds. This first pass implements (a)
// from clusterResources() — a configured-but-not-running managed module = FAIL.
// PARKED: confirm whether (a) suffices or guest-agent ping is required.
export function checkServiceLiveness(
  client: ClusterClient,
  configDir: string,
  defaultNode: string,
): CheckResult {
  const running = new Set(
    client.clusterResources().filter((g) => g.status === "running").map((g) => g.vmid),
  );
  const managed = loadConfigModules(configDir, defaultNode).filter(isManaged);
  const down = managed.filter((m) => !running.has(m.vmid)).map((m) => m.module);
  if (down.length > 0) {
    return { name: "service-liveness", status: "fail", detail: `not running: ${down.join(", ")}` };
  }
  // Report the population, not just the verdict: a bare "all managed modules
  // running" over an EMPTY set read as PASS for as long as #441 was live.
  if (managed.length === 0) {
    return { name: "service-liveness", status: "skip", detail: "no managed modules configured" };
  }
  return {
    name: "service-liveness",
    status: "pass",
    detail: `${managed.length} managed module(s) running`,
  };
}

export interface ValidateOpts {
  configDir: string;
  defaultNode: string;
  threshold: number;
  // #569: percent of a node's physical RAM that committed memory may reach
  // before the gate fails. 100 = "promised more than it has".
  memoryThreshold: number;
}

// Aggregate all gates; `failed` counts FAIL (not skip). Caller maps failed>0 → exit 1.
// ── memory-commitment gate (#569) ─────────────────────────────────────
// Answering "is this node overcommitted, and by how much" needed raw SSH before
// this: module-manager knows each module's declared memory but never aggregates
// it, and site-manager lists nodes without their capacity.
//
// COMMITTED, not used. Without ballooning a guest's declared memory is pinned by
// the host whether the guest wants it or not, so `committed` is the number that
// decides whether another guest fits — and `used` can exceed it perfectly
// legitimately, because ZFS ARC and host overhead live outside any guest.
//
// Over 100% is a FAIL: the node has promised more than it has. A node at 0% (no
// running guests) is reported, not hidden — an empty node next to a full one is
// a placement problem worth seeing.
const GIB = 1024 ** 3;
const gib = (b: number): string => (b / GIB).toFixed(1);

export function checkMemoryCommitment(client: ClusterClient, threshold: number): CheckResult {
  let caps: NodeCapacity[];
  try {
    caps = client.nodeCapacity();
  } catch (e) {
    return {
      name: "memory-commitment",
      status: "skip",
      detail: `cluster capacity unavailable: ${(e as Error).message}`,
    };
  }
  if (caps.length === 0) {
    return { name: "memory-commitment", status: "skip", detail: "no nodes reported" };
  }
  const parts: string[] = [];
  const over: string[] = [];
  for (const c of caps) {
    const pct = c.physicalMem > 0 ? (100 * c.committedMem) / c.physicalMem : 0;
    parts.push(`${c.node} ${gib(c.committedMem)}/${gib(c.physicalMem)}G ${pct.toFixed(0)}%`);
    if (pct >= threshold) over.push(`${c.node} at ${pct.toFixed(0)}%`);
  }
  if (over.length > 0) {
    return {
      name: "memory-commitment",
      status: "fail",
      detail: `committed memory at or over ${threshold}% of physical: ${over.join(", ")} — [${parts.join("; ")}]`,
    };
  }
  return { name: "memory-commitment", status: "pass", detail: parts.join("; ") };
}

// ── guest-memory report ───────────────────────────────────────────────
// Three numbers per guest, because two cannot tell the cases apart:
//
//   declared - resident  memory the guest has NEVER TOUCHED. QEMU backs a page
//                        on first write, so this costs nothing and ballooning
//                        has nothing to reclaim from it.
//   resident - used      memory the guest touched and then freed. The host was
//                        never told, so it still holds it. THIS is the only
//                        part a balloon driver could give back.
//
// Measured on hrossen: 60G declared, 31.9G resident, ~20G used. A two-column
// report would have said "balloon everything"; the third column says most of
// the gap was never taken in the first place.
//
// An UNMEASURED guest is reported as such and never as a number. Without an
// agent Proxmox reports the host's own view as the guest's usage, so a FreeBSD
// firewall using 1.15G of 8G read as 8.0G of 8.0G — "full", and precisely
// backwards. Printing that figure would send an operator away from the one VM
// on the system with real memory to reclaim.
export function checkGuestMemory(client: ClusterClient): CheckResult {
  let caps: NodeCapacity[];
  try {
    caps = client.nodeCapacity();
  } catch (e) {
    return { name: "guest-memory", status: "skip", detail: `unavailable: ${(e as Error).message}` };
  }
  const guests = caps.flatMap((c) => c.guests).filter((g) => g.status === "running");
  if (guests.length === 0) {
    return { name: "guest-memory", status: "skip", detail: "no running guests" };
  }
  // Resident above declared is the one genuine anomaly: the host is holding
  // more for a guest than the guest was ever promised.
  const impossible = guests.filter((g) => g.residentMem > 0 && g.residentMem > g.declaredMem * 1.05);
  if (impossible.length > 0) {
    return {
      name: "guest-memory",
      status: "fail",
      detail: `resident memory exceeds the declared limit: ${impossible
        .map((g) => `${g.name} ${gib(g.residentMem)}G > ${gib(g.declaredMem)}G`)
        .join(", ")}`,
    };
  }
  const unmeasured = guests.filter((g) => !g.measured);
  // Reclaimable = touched-then-freed, and only where we can trust `used`.
  const reclaimable = guests
    .filter((g) => g.measured && g.residentMem > g.usedMem)
    .map((g) => ({ g, gap: g.residentMem - g.usedMem }))
    .sort((a, b) => b.gap - a.gap);
  const totalGap = reclaimable.reduce((a, x) => a + x.gap, 0);
  const top = reclaimable
    .slice(0, 3)
    .map((x) => `${x.g.name} ${gib(x.g.declaredMem)}/${gib(x.g.residentMem)}/${gib(x.g.usedMem)}G`)
    .join(", ");
  const parts = [`${guests.length} running; declared→resident→used, largest gaps: ${top || "none"}`];
  if (totalGap > 0) parts.push(`touched-then-freed total ${gib(totalGap)}G`);
  if (unmeasured.length > 0) {
    parts.push(
      `UNMEASURED (guest reports no memory statistics — the usage figure is the host's view, not the guest's): ${unmeasured
        .map((g) => `${g.name} declared ${gib(g.declaredMem)}G, host holds ${gib(g.residentMem)}G`)
        .join(", ")}`,
    );
  }
  return { name: "guest-memory", status: "pass", detail: parts.join(" | ") };
}

export function runHealthGates(client: ClusterClient, opts: ValidateOpts): HealthReport {
  const checks: CheckResult[] = [
    checkServiceLiveness(client, opts.configDir, opts.defaultNode),
    checkDiskThreshold(client, opts.configDir, opts.defaultNode, opts.threshold),
    checkMemoryCommitment(client, opts.memoryThreshold),
    checkGuestMemory(client),
    checkBackupStatus(opts.configDir),
  ];
  const failed = checks.filter((c: CheckResult): boolean => c.status === ("fail" as CheckStatus)).length;
  return { checks, failed };
}
