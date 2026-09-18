// restore.ts — the `restore` SPECIAL verb (port of backup-restore.sh).
//
// A recovery action, NOT CRUD — stays a distinct verb per ADR-007 verb-alignment
// (#3, Table "backup restore stays special"). Thin operator-facing wrapper:
// resolves a module → vmid from the deployed config and forwards to the tested
// foundation restore script (src/foundation/backup/scripts/restore.sh); snapshot LISTING
// is delegated to backup-controller via the injected Client.
//
// Live PBS access is required for an actual restore; offline this prints what it
// would call and exits cleanly (so tests / dry inspection are safe) — exactly as
// the bash did.

import { existsSync } from "fs";
import { join } from "path";
import { defaultConfigDir, moduleVmid } from "./config";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { stream } from "../../../lib/ts/src/exec";
import { Client } from "./types";
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

// `restore restore <module> [opts...]` — restore a module's VM via foundation
// restore.sh. Resolves vmid; forwards remaining options.
export function restoreRun(deps: RestoreDeps, module: string, opts: string[]): number {
  const vmid = moduleVmid(deps.configDir, module);
  if (!vmid) {
    console.error(`Module '${module}' has no vmid in ${deps.configDir}`);
    return 1;
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
  return spawnInherit(script, ["--vmid", vmid, ...opts]);
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
