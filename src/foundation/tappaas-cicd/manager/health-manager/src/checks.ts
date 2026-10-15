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
//   - guest-memory      (per guest: declared vs allocated vs used)
//   - backup-status    (was check-backup-status.sh; reads `backup-manager list --json`)
//   - service-liveness (guest-agent ping / running-state — see TODO)
//   - pending-reboot   (#730: guests whose update is waiting for a reboot)
//   - cve-status       (ADR-011: the last security scan — WARN, never FAIL)

import { spawnSync } from "child_process";
import { join } from "path";
import { isManaged, loadConfigModules, readModuleJson, siteNodeHostnames } from "./config";
import { CheckResult, CheckRow, CheckStatus, ClusterClient, HealthReport, NodeCapacity, StoragePool } from "./types";
import { existsSync, readFileSync } from "fs";
import { checkCveStatus } from "./security";

// Resolve a guest's `<vmname>.<zone0>.internal` target, as check-disk-threshold.sh
// does (defaulting zone0 to "mgmt"), for the gates that probe a guest over SSH.
export function guestTarget(configDir: string, module: string): string | null {
  const raw = readModuleJson(join(configDir, `${module}.json`));
  if (!raw) return null;
  // Pattern A keeps zone0 (and possibly vmname) under .config: a flat read
  // sent every such guest to <name>.mgmt.internal, which does not resolve.
  const vn = configField(raw, "vmname");
  const z0 = configField(raw, "zone0");
  const vmname = typeof vn === "string" && vn ? vn : module;
  const zone0 = typeof z0 === "string" && z0 ? z0 : "mgmt";
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
    const target = guestTarget(configDir, m.module);
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
  // A suspended module is stopped on purpose (#428): reported, never "down".
  const all = loadConfigModules(configDir, defaultNode).filter(isManaged);
  const suspended = all.filter((m) => m.suspended).map((m) => m.module);
  const managed = all.filter((m) => !m.suspended);
  const paused = suspended.length > 0 ? `; suspended: ${suspended.join(", ")}` : "";
  const down = managed.filter((m) => !running.has(m.vmid)).map((m) => m.module);
  if (down.length > 0) {
    return { name: "service-liveness", status: "fail", detail: `not running: ${down.join(", ")}${paused}` };
  }
  // Report the population, not just the verdict: a bare "all managed modules
  // running" over an EMPTY set read as PASS for as long as #441 was live.
  if (managed.length === 0) {
    return { name: "service-liveness", status: "skip", detail: "no managed modules configured" };
  }
  return {
    name: "service-liveness",
    status: "pass",
    detail: `${managed.length} managed module(s) running${paused}`,
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
//   declared - allocated memory the guest has NEVER TOUCHED. QEMU backs a page
//                        on first write, so this costs nothing and ballooning
//                        has nothing to reclaim from it.
//   allocated - used     memory the guest touched and then freed. The host was
//                        never told, so it still holds it. THIS is the only
//                        part a balloon driver could give back.
//
// Measured on hrossen: 60G declared, 31.9G allocated, ~20G used. A two-column
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
  const guests = caps.flatMap((c) => c.guests);
  if (guests.length === 0) {
    return { name: "guest-memory", status: "skip", detail: "no guests" };
  }

  // A module is short of memory when it is USING most of what it was given.
  // Over-declaring is waste, not danger, and must not be dressed as either.
  const CRITICAL = 90;
  const WARN = 75;
  const pad = (t: string, n: number): string => (t.length >= n ? t : t + " ".repeat(n - t.length));
  const col = (b: number): string => pad(`${gib(b)}G`, 8);

  type Row = { g: (typeof guests)[number]; gap: number; pct: number; status: CheckStatus };
  const rows: Row[] = guests.map((g) => {
    const running = g.status === "running";
    const gap = running && g.measured && g.residentMem > g.usedMem ? g.residentMem - g.usedMem : 0;
    const pct = running && g.measured && g.declaredMem > 0 ? (100 * g.usedMem) / g.declaredMem : -1;
    let status: CheckStatus = "pass";
    if (!running) status = "skip";
    else if (g.residentMem > 0 && g.residentMem > g.declaredMem * 1.05) status = "fail";
    else if (!g.measured) status = "skip";
    else if (pct >= CRITICAL) status = "fail";
    else if (pct >= WARN) status = "warn";
    return { g, gap, pct, status };
  });
  // Largest gap first: the reader's eye should land on the most reclaimable.
  rows.sort((a, b) => b.gap - a.gap || b.g.declaredMem - a.g.declaredMem);

  const out: CheckRow[] = rows.map(({ g, gap, pct, status }) => {
    const name = pad(g.name || String(g.vmid), 16);
    if (g.status !== "running") return { status, text: `${name}${pad("(stopped)", 30)}` };
    const used = g.measured ? col(g.usedMem) : pad("unmeasured", 8);
    const note = !g.measured
      ? "  usage figure is the host's, not the guest's"
      : g.type === "lxc"
        ? `  ${pct.toFixed(0)}% of its LXC limit`
        : `  ${pct.toFixed(0)}% of declared, gap ${gib(gap)}G`;
    return { status, text: `${name}${col(g.declaredMem)}${col(g.residentMem)}${used}${note}` };
  });

  // TWO totals, because the columns do not mean the same thing for both kinds.
  // A VM's declared memory is an ALLOCATION the host must find; an LXC's is a
  // LIMIT it may never reach. Adding them produces a number that describes
  // nothing — 106G on an estate whose VMs were promised 60G.
  const run = rows.filter((r) => r.g.status === "running");
  const vms = run.filter((r) => r.g.type !== "lxc");
  const cts = run.filter((r) => r.g.type === "lxc");
  const sum = (rs: Row[], f: (r: Row) => number): number => rs.reduce((a, r) => a + f(r), 0);
  const line = (label: string, rs: Row[], tail: string): CheckRow => ({
    status: "pass",
    text:
      `${pad(label, 16)}${col(sum(rs, (r) => r.g.declaredMem))}` +
      `${col(sum(rs, (r) => r.g.residentMem))}` +
      `${col(sum(rs, (r) => (r.g.measured ? r.g.usedMem : 0)))}  ${tail}`,
  });
  if (vms.length > 0) {
    out.push(line("── VM totals", vms, `reclaimable ${gib(sum(vms, (r) => r.gap))}G`));
  }
  if (cts.length > 0) {
    out.push(line("── LXC totals", cts, "declared is a limit, not an allocation"));
  }

  // Nothing running means nothing measured — the rows still list what is there,
  // but the gate asserts nothing.
  const worst: CheckStatus =
    run.length === 0
      ? "skip"
      : rows.some((r) => r.status === "fail")
        ? "fail"
        : rows.some((r) => r.status === "warn")
          ? "warn"
          : "pass";
  // The header names the columns and the ordering. What the numbers MEAN — why
  // the gap is the only reclaimable part, where the WARN and FAIL bands sit —
  // belongs in README/DESIGN, not in every run of the report.
  const detail = "declared / allocated / used, largest gap first";
  return { name: "guest-memory", status: worst, detail, rows: out };
}

// ── pending-reboot gate (#730) ─────────────────────────────────────────
// A guest whose update is waiting for a reboot: automaticReboot=false, a backup
// holding it, or the controller updating itself (update-os.sh skips all three
// and says DEFERRED:). Since #728 that can be a whole release move staged for
// the next boot, not just a kernel — the guest still RUNS the old release. A
// switched one runs the new userspace on the old kernel; the row says which.
//
// WARN, never FAIL: a pending reboot is debt, not an outage, and a site that
// reboots by hand in its own window is healthy while it waits. Derived on the
// guest (see PendingReboot), so a reboot by any route clears it.
const release = (v: string): string => /^\d+\.\d+/.exec(v)?.[0] ?? "";

export function checkPendingReboot(
  client: ClusterClient,
  configDir: string,
  defaultNode: string,
): CheckResult {
  const modules = loadConfigModules(configDir, defaultNode).filter(isManaged);
  const rows: CheckRow[] = [];
  let probed = 0;
  for (const m of modules) {
    const target = guestTarget(configDir, m.module);
    if (!target) continue;
    const p = client.pendingReboot(target);
    if (p === null) continue; // unreachable → skip this guest
    probed++;
    if (!p.pending) continue;
    const from = release(p.booted);
    const to = release(p.next);
    const what =
      p.os !== "nixos"
        ? "the OS asks for a reboot"
        : from && to && from !== to
          ? p.active
            ? `release move ${from} -> ${to} active, still on the ${from} kernel`
            : `release move ${from} -> ${to} staged, still running ${from}`
          : `booted ${p.booted || "?"}, next boot ${p.next || "?"}`;
    rows.push({ status: "warn", text: `${m.module.padEnd(16)}${what}` });
  }
  if (probed === 0) {
    return { name: "pending-reboot", status: "skip", detail: "no reachable guests probed" };
  }
  if (rows.length === 0) {
    return { name: "pending-reboot", status: "pass", detail: `${probed} guest(s) booted on their current system` };
  }
  return {
    name: "pending-reboot",
    status: "warn",
    detail: `${rows.length} of ${probed} guest(s) waiting for a reboot — health-manager reboot <module>`,
    rows,
  };
}

// ── storage-pools gate (#100) ─────────────────────────────────────────
// Every guest-disk pool on every node. Automatic disk growth stops at its
// pool ceiling (80%) and says so per module; this is the cluster-wide view of
// the same limit: warn at 80% used, fail at 90% — a full ZFS pool fails writes
// for every guest on it, and slows down well before. A pool whose disks add up
// to more than it holds (thin disks, #773) is a warning however empty it is.
export const POOL_WARN = 80;
export const POOL_FAIL = 90;

export function checkStoragePools(client: ClusterClient): CheckResult {
  let pools: StoragePool[];
  try {
    pools = client.storagePools();
  } catch (e) {
    return { name: "storage-pools", status: "skip", detail: `unavailable: ${(e as Error).message}` };
  }
  if (pools.length === 0) return { name: "storage-pools", status: "skip", detail: "no pools reported" };
  const rank: Record<CheckStatus, number> = { pass: 0, skip: 0, warn: 1, fail: 2 };
  let worst: CheckStatus = "pass";
  const rows: CheckRow[] = [];
  for (const p of [...pools].sort((a, b) => a.node.localeCompare(b.node) || a.storage.localeCompare(b.storage))) {
    const pct = (100 * p.used) / p.total;
    let status: CheckStatus = pct >= POOL_FAIL ? "fail" : pct >= POOL_WARN ? "warn" : "pass";
    let detail = `${pct.toFixed(0)}% used (${gib(p.used)}/${gib(p.total)}G)`;
    if (p.provisioned > p.total) {
      detail += `, disks add up to ${gib(p.provisioned)}G — overcommitted by thin disks`;
      if (status === "pass") status = "warn";
    }
    rows.push({ status, text: `${p.node}/${p.storage}: ${detail}` });
    if (rank[status] > rank[worst]) worst = status;
  }
  const bad = rows.filter((r) => r.status !== "pass");
  const detail = bad.length === 0
    ? `${rows.length} pool(s) under ${POOL_WARN}%`
    : bad.map((r) => r.text).join("; ");
  return { name: "storage-pools", status: worst, detail, rows };
}

// ── cpu-impact report (#827) ──────────────────────────────────────────
// What an HA guest gives up when haCpu common puts it on the CPU level its two
// nodes share. Measured, not guessed, for the instructions that can be: the
// kernel records per process how long ago it last used AVX-512, so a guest
// still running `host` on an AVX-512 node shows which of its processes would
// lose it. Nothing to measure for lower levels (no counter), nor once the
// guest already runs the common level. Never fails: it tells the operator
// whether to benchmark before restarting the guest onto the shared level.

interface CpuInventory {
  levels?: Record<string, number>;
  levelFlags?: Record<string, string[]>;
  nodes?: { node: string; level: string | null }[];
  matrix?: { from: string; to: string; liveSafe: boolean }[];
}

// A field anywhere in a module config (flat, or Pattern A under .config).
export function configField(raw: Record<string, unknown>, field: string): unknown {
  if (field in raw) return raw[field];
  const stack: unknown[] = [raw.config];
  while (stack.length > 0) {
    const o = stack.pop();
    if (!o || typeof o !== "object") continue;
    const rec = o as Record<string, unknown>;
    if (field in rec) return rec[field];
    stack.push(...Object.values(rec));
  }
  return undefined;
}

// The model haCpu common gives a pair (mirrors cluster/lib/ha-cpu-lib.sh):
// `host` when moves are live-safe both ways, else the lower of their levels.
export function haCommonCpu(inv: CpuInventory, a: string, b: string): string | null {
  const safe = (inv.matrix ?? []).filter(
    (m) => (m.from === a && m.to === b) || (m.from === b && m.to === a));
  if (safe.length === 2 && safe.every((m) => m.liveSafe)) return "host";
  const lv = (n: string) => (inv.nodes ?? []).find((x) => x.node === n)?.level ?? null;
  const la = lv(a), lb = lv(b), r = inv.levels ?? {};
  if (!la || !lb || r[la] === undefined || r[lb] === undefined) return null;
  return r[la] <= r[lb] ? la : lb;
}

export function checkCpuImpact(client: ClusterClient, configDir: string, defaultNode: string): CheckResult {
  const invPath = join(configDir, "cluster-cpu.json");
  if (!existsSync(invPath)) {
    return { name: "cpu-impact", status: "skip", detail: "no CPU inventory (proxmox-controller cpu-inventory --apply)" };
  }
  let inv: CpuInventory;
  try {
    inv = JSON.parse(readFileSync(invPath, "utf8")) as CpuInventory;
  } catch {
    return { name: "cpu-impact", status: "skip", detail: "CPU inventory unreadable" };
  }
  const rows: CheckRow[] = [];
  let worst: CheckStatus = "pass";
  for (const m of loadConfigModules(configDir, defaultNode).filter(isManaged)) {
    const raw = readModuleJson(join(configDir, `${m.module}.json`)) ?? {};
    const deps = configField(raw, "dependsOn");
    if (!Array.isArray(deps) || !deps.includes("cluster:ha")) continue;
    if ((configField(raw, "haCpu") ?? "common") === "host") {
      rows.push({ status: "pass", text: `${m.module}: haCpu host — keeps its node's full CPU` });
      continue;
    }
    // The defaults cluster:ha applies: node = the first site node, HANode =
    // the first other one (get_default_ha_node).
    const siteNodes = siteNodeHostnames(configDir);
    const nodeField = configField(raw, "node");
    const node = typeof nodeField === "string" && nodeField ? nodeField : siteNodes[0] ?? m.node;
    const haField = configField(raw, "HANode");
    const ha = typeof haField === "string" && haField ? haField : siteNodes.find((n) => n !== node);
    const level = typeof ha === "string" ? haCommonCpu(inv, node, ha) : null;
    if (!level) continue;
    const flags = level === "host" ? null : inv.levelFlags?.[level] ?? null;
    if (level === "host" || (flags && flags.includes("avx512f"))) {
      rows.push({ status: "pass", text: `${m.module}: ${level} keeps AVX-512 — nothing measurable lost` });
      continue;
    }
    const target = guestTarget(configDir, m.module);
    const use = target ? client.avx512Use(target) : null;
    if (!use) {
      rows.push({ status: "pass", text: `${m.module}: not measured (no answer from ${target ?? "its guest"}) — ${level} drops AVX-512` });
      continue;
    }
    let row: CheckRow;
    if (!use.available) {
      row = { status: "pass", text: `${m.module}: its CPU offers no AVX-512 now — ${level} takes nothing it uses` };
    } else if (use.recent.length > 0) {
      row = {
        status: "warn",
        text: `${m.module}: ${use.recent.length} process(es) used AVX-512 in the last minute (${use.recent.slice(0, 6).join(", ")}) — ${level} removes it; benchmark before restarting it onto ${level}, or set haCpu: host`,
      };
    } else if (use.earlier.length > 0) {
      row = { status: "pass", text: `${m.module}: AVX-512 used earlier, not in the last minute (${use.earlier.slice(0, 6).join(", ")}) — ${level} costs little` };
    } else {
      row = { status: "pass", text: `${m.module}: no process uses AVX-512 — ${level} costs nothing measurable` };
    }
    rows.push(row);
    if (row.status === "warn") worst = "warn";
  }
  if (rows.length === 0) return { name: "cpu-impact", status: "skip", detail: "no HA guest to assess" };
  const warns = rows.filter((r) => r.status === "warn").length;
  return {
    name: "cpu-impact",
    status: worst,
    detail: warns === 0 ? `${rows.length} HA guest(s): no measurable loss` : `${warns} of ${rows.length} HA guest(s) use instructions their shared CPU level drops`,
    rows,
  };
}

export function runHealthGates(client: ClusterClient, opts: ValidateOpts): HealthReport {
  const checks: CheckResult[] = [
    checkServiceLiveness(client, opts.configDir, opts.defaultNode),
    checkDiskThreshold(client, opts.configDir, opts.defaultNode, opts.threshold),
    checkMemoryCommitment(client, opts.memoryThreshold),
    checkStoragePools(client),
    checkCpuImpact(client, opts.configDir, opts.defaultNode),
    checkGuestMemory(client),
    checkBackupStatus(opts.configDir),
    checkPendingReboot(client, opts.configDir, opts.defaultNode),
    checkCveStatus(opts.configDir, Date.now()),
  ];
  const failed = checks.filter((c: CheckResult): boolean => c.status === ("fail" as CheckStatus)).length;
  return { checks, failed };
}
