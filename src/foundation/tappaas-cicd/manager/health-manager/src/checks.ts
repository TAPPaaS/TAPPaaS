// checks.ts — the health gates aggregated under `validate`.
//
// Per ADR-007 §Health, health `validate` is SPECIAL: it does not check that
// config is well-formed (that's the other managers) — it ASSERTS THE LIVE SYSTEM
// IS HEALTHY by running the health gates against the running cluster and exiting
// non-zero if any fail. The current check-*.sh scripts become these checks.
//
// Gates ported here:
//   - disk-threshold   (= check-disk-threshold.sh, READ-ONLY subset — see note)
//   - backup-status    (= check-backup-status.sh)
//   - service-liveness (guest-agent ping / running-state — see TODO)

import { spawnSync } from "child_process";
import { join } from "path";
import { loadConfigModules, readModuleJson } from "./config";
import { CheckResult, CheckStatus, ClusterClient, HealthReport } from "./types";

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
  const modules = loadConfigModules(configDir, defaultNode).filter((m) => m.status === "");
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

// ── backup-status gate (= check-backup-status.sh) ─────────────────────
// Shells out to backup-status.sh --json (the same source check-backup-status.sh
// reads) and flags modules that are DISABLED or enabled-but-not-in-the-PBS-job.
// Skips cleanly when the backup tooling is unavailable (matches the .sh exit 0).
const BACKUP_STATUS_BIN = process.env.BACKUP_STATUS_BIN ?? "backup-status.sh";

export function checkBackupStatus(configDir: string): CheckResult {
  const r = spawnSync(BACKUP_STATUS_BIN, ["--config-dir", configDir, "--json"], {
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
  const disabled: string[] = [];
  const uncovered: string[] = [];
  for (const e of arr) {
    const o = e as Record<string, unknown>;
    const mod = typeof o.module === "string" ? o.module : "?";
    if (o.enabled === false) disabled.push(mod);
    else if (o.enabled === true && o.inPbsJob === false) uncovered.push(mod);
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
  const down = loadConfigModules(configDir, defaultNode)
    .filter((m) => m.status === "" && !running.has(m.vmid))
    .map((m) => m.module);
  if (down.length > 0) {
    return { name: "service-liveness", status: "fail", detail: `not running: ${down.join(", ")}` };
  }
  return { name: "service-liveness", status: "pass", detail: "all managed modules running" };
}

export interface ValidateOpts {
  configDir: string;
  defaultNode: string;
  threshold: number;
}

// Aggregate all gates; `failed` counts FAIL (not skip). Caller maps failed>0 → exit 1.
export function runHealthGates(client: ClusterClient, opts: ValidateOpts): HealthReport {
  const checks: CheckResult[] = [
    checkServiceLiveness(client, opts.configDir, opts.defaultNode),
    checkDiskThreshold(client, opts.configDir, opts.defaultNode, opts.threshold),
    checkBackupStatus(opts.configDir),
  ];
  const failed = checks.filter((c: CheckResult): boolean => c.status === ("fail" as CheckStatus)).length;
  return { checks, failed };
}
