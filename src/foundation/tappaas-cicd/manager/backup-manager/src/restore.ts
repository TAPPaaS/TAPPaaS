// restore.ts — the `restore` SPECIAL verb (port of backup-restore.sh).
//
// A recovery action, NOT CRUD — stays a distinct verb per ADR-007 verb-alignment
// (#3, Table "backup restore stays special"). Thin operator-facing wrapper:
// resolves a module → vmid from the deployed config and forwards to the tested
// foundation restore script (src/foundation/backup/scripts/restore.sh); snapshot LISTING
// is delegated to pbs-controller via the injected Client.
//
// Live PBS access is required for an actual restore; offline this prints what it
// would call and exits cleanly (so tests / dry inspection are safe) — exactly as
// the bash did.

import { existsSync } from "fs";
import { join } from "path";
import { defaultConfigDir, moduleNode, moduleVmid } from "./config";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { stream } from "../../../lib/ts/src/exec";
import { BackupRuns, Client, GuestRuns, JobLastRun, LastVerify, RawRuns, RawSnapshot, ScheduleBucket, TargetRuns } from "./types";
import { moduleSourceOf } from "../../../lib/ts/src/instance";

// Foundation restore script (the tested VM-restore logic this verb drives).
//
// Resolution order, most authoritative first:
//   1. $RESTORE_SH                     — explicit override (tests, relocation)
//   2. config/backup.json .moduleSource — where the module actually is. This is
//      the module's own record of its source directory, written at install, and
//      it is the only answer that survives being run from anywhere.
//   3. a repo-relative walk             — for running out of a checkout
//   4. the conventional checkout path
//
// The walk alone used to be the whole implementation, and it is wrong for the
// INSTALLED binary: from /nix/store/<hash>-backup-manager/lib/... seven levels
// up is `/`, so it resolved to "/backup/scripts/restore.sh", reported "foundation
// restore.sh not found" and exited 0 — `restore` looked like it worked and
// restored nothing.
function restoreScriptPath(configDir?: string): string {
  if (process.env.RESTORE_SH) return process.env.RESTORE_SH;

  const dir = configDir ?? defaultConfigDir();
  const location = moduleSourceOf(readJsonObject(join(dir, "backup.json")));
  if (location) {
    // scripts/ since the helper-script move; the flat path is the pre-move
    // layout, kept so an older deployed config still resolves.
    for (const rel of ["scripts/restore.sh", "restore.sh"]) {
      const fromConfig = join(location, rel);
      if (existsSync(fromConfig)) return fromConfig;
    }
  }

  const walked = join(__dirname, "..", "..", "..", "..", "..", "..", "..",
                      "backup", "scripts", "restore.sh");
  if (existsSync(walked)) return walked;

  return "/home/tappaas/TAPPaaS/src/foundation/backup/scripts/restore.sh";
}

/**
 * The backup module's own directory, from its deployed config's `.moduleSource`.
 * Peer onboarding scripts live under `<moduleDir>/scripts/<kind>/`, so this is
 * the same lookup restoreScriptPath does — one place that knows where the
 * module is, rather than each caller walking up from __dirname and getting it
 * wrong once installed.
 */
export function moduleScriptDir(configDir?: string): string {
  const dir = configDir ?? defaultConfigDir();
  const location = moduleSourceOf(readJsonObject(join(dir, "backup.json")));
  if (location) return location;
  return "/home/tappaas/TAPPaaS/src/foundation/backup";
}

function spawnInherit(bin: string, args: string[]): number {
  // Stream the child's output LIVE via lib exec.stream (stdio: "inherit") — a
  // long restore.sh run shows progress as it happens. (The old vendored
  // env.d.ts lacked the stdio declaration, so output was buffered and replayed
  // only after exit; fixed with the shared lib — task 6.3.)
  try {
    return stream(bin, args);
  } catch {
    // stream() throws only when the binary cannot be spawned — keep the old
    // spawn-failure rc mapping (-1).
    return -1;
  }
}

export interface RestoreDeps {
  client: Client;
  configDir: string;
}

// PBS reports a snapshot as a unix backup-time. Printing that raw is useless to
// the person choosing which one to restore — "1788807649" is not a date anyone
// reads. Render it, newest first, and keep the raw value alongside since that is
// what the restore itself takes.
function formatSnapshot(epoch: string): string {
  const n = Number(epoch);
  if (!Number.isFinite(n) || n <= 0) return epoch;
  const iso = new Date(n * 1000).toISOString().replace("T", " ").replace(/\..*$/, " UTC");
  const ageDays = Math.floor((Date.now() / 1000 - n) / 86400);
  const age = ageDays === 0 ? "today" : ageDays === 1 ? "1 day ago" : `${ageDays} days ago`;
  return `${iso}  (${age})  ${epoch}`;
}

// `restore list <module>` — list snapshots for a module's VM (via controller).
export function restoreList(deps: RestoreDeps, module: string): number {
  const snaps = deps.client.listSnapshots(module);
  if (snaps.length === 0) {
    console.log(`No snapshots found for module '${module}' (or PBS offline).`);
    return 0;
  }
  const sorted = [...snaps].sort((a, b) => Number(b) - Number(a));
  for (const s of sorted) console.log(formatSnapshot(s));
  return 0;
}

// restoreArgs — the restore.sh arguments for `restore restore <module> [opts]`.
//
// Plain: the module's own backup, over the module's own guest (`--vmid <its>`).
// `--from <module|vmid>` (RESTORE.md §2, #729): ANOTHER guest's backup, into this
// module's guest, replacing it — `--vmid <source> --target-vmid <this> --replace`.
// The destination is always the module named on the command line. Before
// `--from`, the only way to name a source was a second `--vmid`, and restore.sh
// takes the LAST one as both source and destination: one missing flag away from
// restoring over the production original instead of the new instance.
//
// The source may be a module that is declared here, or a bare VMID — a backup
// from a site, or an incarnation, that this config never had.
//
// `--node` defaults to the node the module is declared on, as the help has
// always said. restore.sh's own default is the site's first node: an existing
// guest elsewhere then reads as absent — for `--from`, "does not exist".
export function restoreArgs(
  vmid: string, opts: string[], resolveVmid: (module: string) => string | null,
  node: string | null = null,
): { args: string[] } | { error: string } {
  if (node && !opts.some((o) => o === "--node" || o === "-n")) opts = [...opts, "--node", node];
  const i = opts.indexOf("--from");
  if (i < 0) return { args: ["--vmid", vmid, ...opts] };
  const from = opts[i + 1];
  if (!from || from.startsWith("-")) return { error: "--from needs a module name or a VMID" };
  const rest = [...opts.slice(0, i), ...opts.slice(i + 2)];
  if (rest.some((o) => o === "--target-vmid" || o === "-t")) {
    return { error: "--from restores INTO this module's guest; --target-vmid restores beside a guest — use one or the other" };
  }
  const source = /^[0-9]+$/.test(from) ? from : resolveVmid(from);
  if (!source) return { error: `--from ${from}: no such module with a vmid here (give the backup's VMID instead)` };
  if (source === vmid) return { error: `--from ${from} is this module's own VMID (${vmid}) — drop --from to restore its own backup` };
  return { args: ["--vmid", source, "--target-vmid", vmid, "--replace", ...rest] };
}

// `restore restore <module> [opts...]` — restore via foundation restore.sh.
export function restoreRun(deps: RestoreDeps, module: string, opts: string[]): number {
  const vmid = moduleVmid(deps.configDir, module);
  if (!vmid) {
    console.error(`Module '${module}' has no vmid in ${deps.configDir}`);
    return 1;
  }
  const planned = restoreArgs(vmid, opts, (m) => moduleVmid(deps.configDir, m),
    moduleNode(deps.configDir, module));
  if ("error" in planned) {
    console.error(`restore restore ${module}: ${planned.error}`);
    return 2;
  }
  const script = restoreScriptPath(deps.configDir);
  if (!existsSync(script)) {
    // Not found is a FAILURE, not a dry run: a restore verb that prints what it
    // would have done and exits 0 reads as success to anyone (and any script)
    // that checks the exit code.
    console.error(`Cannot restore: ${script} not found. Set RESTORE_SH, or check`);
    console.error(`config/backup.json .moduleSource points at the backup module.`);
    return 1;
  }
  return spawnInherit(script, planned.args);
}

// `restore list-all` — list all backups (foundation restore.sh --list-all).
export function restoreListAll(configDir?: string): number {
  const script = restoreScriptPath(configDir);
  if (!existsSync(script)) {
    console.error(`Cannot list backups: ${script} not found. Set RESTORE_SH, or check`);
    console.error(`config/backup.json .moduleSource points at the backup module.`);
    return 1;
  }
  return spawnInherit(script, ["--list-all"]);
}

// ── restore list-all --json: last backup and last verify ──────────────
// What the text table cannot answer at a glance: when each guest last backed
// up, whether that is within its job's interval, and when a verify last read
// it — per guest, per namespace (target), per job. From `pbs-controller runs`.

// The start time a UPID carries (hex). PBS: UPID:node:pid:pstart:task:start:…;
// PVE has no task field: UPID:node:pid:pstart:start:…
export function upidTime(upid: string | undefined): number | null {
  if (!upid || !upid.startsWith("UPID:")) return null;
  const p = upid.split(":");
  const hex = p.length >= 10 ? p[5] : p[4];
  const n = parseInt(hex ?? "", 16);
  return Number.isFinite(n) && n > 0 ? n : null;
}

const DAY = 86400;
const INTERVAL: Record<ScheduleBucket, number> = { daily: DAY, weekly: 7 * DAY, monthly: 31 * DAY };
// A job's run takes time, and a guest late in a long run is not late.
const SLACK = 6 * 3600;

function bucketOf(comment: string, marker: string): ScheduleBucket | null {
  if (!marker) return null;
  if (comment === marker) return "daily";
  if (comment === `${marker}-weekly`) return "weekly";
  if (comment === `${marker}-monthly`) return "monthly";
  return null;
}

export function targetKind(ns: string): TargetRuns["kind"] {
  if (ns === "") return "own";
  const top = ns.split("/")[0];
  if (top === "fs") return "host";
  if (top === "pull") return "pull";
  if (top === "receive" || top === "external") return "receive";
  return "other";
}

function verifyOf(s: RawSnapshot): { state: "ok" | "failed"; time: number | null } | null {
  const st = s.verification?.state;
  if (!st) return null;
  return { state: st === "ok" ? "ok" : "failed", time: upidTime(s.verification?.upid) };
}

function newerVerify(a: LastVerify | null, b: LastVerify | null): LastVerify | null {
  if (!a) return b;
  if (!b) return a;
  return (b.time ?? 0) > (a.time ?? 0) ? b : a;
}

function lastRun(j: Record<string, unknown>): JobLastRun | null {
  const end = typeof j["last-run-endtime"] === "number" ? (j["last-run-endtime"] as number) : null;
  const state = typeof j["last-run-state"] === "string" ? (j["last-run-state"] as string) : null;
  const start = upidTime(typeof j["last-run-upid"] === "string" ? (j["last-run-upid"] as string) : undefined);
  if (end === null && state === null && start === null) return null;
  return { time: start ?? end ?? 0, end, state: state ?? "running" };
}

const str = (v: unknown): string => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "");
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Pure: shape the controller's raw answer. `moduleOf` maps a VMID to its module. */
export function shapeRuns(raw: RawRuns, moduleOf: (vmid: string) => string | null, now: number): BackupRuns {
  const out: BackupRuns = {
    reachable: raw.reachable === true, node: raw.node ?? null, store: raw.store ?? null,
    guests: [], targets: [], jobs: [], runs: [], verifyJobs: [], syncJobs: [],
  };
  if (!out.reachable) return out;
  const marker = raw.marker ?? "";

  // Jobs, and which one covers each VMID (an enabled TAPPaaS job first).
  const cover = new Map<string, { job: string; bucket: ScheduleBucket | null; managed: boolean }>();
  for (const j of raw.backupJobs ?? []) {
    const bucket = bucketOf(j.comment, marker);
    const vmids = j.vmid.split(",").map((v) => v.trim()).filter(Boolean);
    out.jobs.push({ id: j.id, managed: bucket !== null, bucket, schedule: j.schedule, enabled: j.enabled, guests: vmids.length });
    if (!j.enabled) continue;
    for (const v of vmids) {
      const had = cover.get(v);
      if (!had || (!had.managed && bucket !== null)) cover.set(v, { job: j.id, bucket, managed: bucket !== null });
    }
  }
  out.runs = (raw.tasks ?? [])
    .filter((t) => typeof t.starttime === "number")
    .map((t) => ({ node: t.node ?? "", time: t.starttime as number, end: num(t.endtime), state: t.status ?? "running", guest: t.id ? t.id : null }))
    .sort((a, b) => b.time - a.time);

  // Groups: one per (namespace, type, id).
  const groups = new Map<string, RawSnapshot[]>();
  for (const s of raw.snapshots ?? []) {
    const k = `${s.ns}\u0000${s.type}\u0000${s.id}`;
    const g = groups.get(k);
    if (g) g.push(s); else groups.set(k, [s]);
  }
  for (const snaps of groups.values()) {
    const { ns, type, id } = snaps[0];
    snaps.sort((a, b) => b.time - a.time);
    const latest = snaps[0];
    let lastVerify: LastVerify | null = null;
    let failed = 0;
    for (const s of snaps) {
      const v = verifyOf(s);
      if (!v) continue;
      if (v.state === "failed") failed++;
      lastVerify = newerVerify(lastVerify, { time: v.time, state: v.state });
    }
    const own = ns === "" && (type === "vm" || type === "ct");
    const c = own ? cover.get(id) : undefined;
    const interval = c ? INTERVAL[c.bucket ?? "daily"] : 0;
    out.guests.push({
      ns, type, id,
      module: own ? moduleOf(id) : null,
      snapshots: snaps.length,
      lastBackup: latest.time,
      job: c?.job ?? null,
      bucket: c?.bucket ?? null,
      outcome: !c ? "not-in-job" : now - latest.time <= interval + SLACK ? "ok" : "late",
      latestVerify: verifyOf(latest)?.state ?? "unverified",
      lastVerify,
      failedVerifies: failed,
    });
  }
  // A guest a job covers with no snapshot at all: never backed up.
  const seen = new Set(out.guests.filter((g) => g.ns === "").map((g) => g.id));
  for (const [vmid, c] of cover) {
    if (seen.has(vmid)) continue;
    out.guests.push({
      ns: "", type: "vm", id: vmid, module: moduleOf(vmid), snapshots: 0, lastBackup: null,
      job: c.job, bucket: c.bucket, outcome: "late", latestVerify: "unverified", lastVerify: null, failedVerifies: 0,
    });
  }
  out.guests.sort((a, b) => a.ns.localeCompare(b.ns) || Number(a.id) - Number(b.id) || a.id.localeCompare(b.id));

  // Targets: per namespace.
  const byNs = new Map<string, GuestRuns[]>();
  for (const g of out.guests) {
    if (g.snapshots === 0) continue;
    const l = byNs.get(g.ns);
    if (l) l.push(g); else byNs.set(g.ns, [g]);
  }
  for (const [ns, gs] of [...byNs].sort((a, b) => a[0].localeCompare(b[0]))) {
    out.targets.push({
      ns, kind: targetKind(ns), groups: gs.length,
      snapshots: gs.reduce((n, g) => n + g.snapshots, 0),
      lastBackup: Math.max(...gs.map((g) => g.lastBackup ?? 0)) || null,
      lastVerify: gs.reduce<LastVerify | null>((v, g) => newerVerify(v, g.lastVerify), null),
      unverified: gs.filter((g) => g.latestVerify === "unverified").length,
      failedVerifies: gs.reduce((n, g) => n + g.failedVerifies, 0),
    });
  }

  out.verifyJobs = (raw.verifyJobs ?? []).map((j) => ({
    id: str(j.id), schedule: str(j.schedule), lastRun: lastRun(j), nextRun: num(j["next-run"]),
  }));
  out.syncJobs = (raw.syncJobs ?? []).map((j) => ({
    id: str(j.id), remote: str(j.remote), ns: str(j.ns), schedule: str(j.schedule), lastRun: lastRun(j), nextRun: num(j["next-run"]),
  }));
  return out;
}
