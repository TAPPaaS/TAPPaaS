// restore.ts — the `restore` SPECIAL verb (port of backup-restore.sh).
//
// A recovery action, NOT CRUD — stays a distinct verb per ADR-007 verb-alignment
// (#3, Table "backup restore stays special"). Thin operator-facing wrapper:
// resolves a module → vmid from the deployed config and forwards to the tested
// foundation restore script (src/foundation/backup/restore.sh); snapshot LISTING
// is delegated to backup-controller via the injected Client.
//
// Live PBS access is required for an actual restore; offline this prints what it
// would call and exits cleanly (so tests / dry inspection are safe) — exactly as
// the bash did.

import { existsSync } from "fs";
import { join } from "path";
import { moduleVmid } from "./config";
import { stream } from "../../../lib/ts/src/exec";
import { Client } from "./types";

// Foundation restore script (tested VM-restore logic). Overridable for tests.
function restoreScriptPath(): string {
  // Default mirrors backup-restore.sh: manager dir → ../../../backup/restore.sh.
  // __dirname here is .../backup-manager/dist/manager/backup-manager/src (the
  // shared tsconfig.base rootDir is the cicd root, so emit mirrors the tree);
  // walk up to the manager dir's parent chain. Overridable via RESTORE_SH for
  // tests / relocation.
  if (process.env.RESTORE_SH) return process.env.RESTORE_SH;
  // src → backup-manager → manager → dist → backup-manager → manager →
  // tappaas-cicd → foundation; backup/restore.sh
  return join(__dirname, "..", "..", "..", "..", "..", "..", "..", "backup", "restore.sh");
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

// `restore list <module>` — list snapshots for a module's VM (via controller).
export function restoreList(deps: RestoreDeps, module: string): number {
  const snaps = deps.client.listSnapshots(module);
  if (snaps.length === 0) {
    console.log(`No snapshots found for module '${module}' (or PBS offline).`);
    return 0;
  }
  for (const s of snaps) console.log(s);
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
  const script = restoreScriptPath();
  if (!existsSync(script)) {
    console.log(
      `Would run: ${script} --vmid ${vmid} ${opts.join(" ")} (foundation restore.sh not found)`,
    );
    return 0;
  }
  return spawnInherit(script, ["--vmid", vmid, ...opts]);
}

// `restore list-all` — list all backups (foundation restore.sh --list-all).
export function restoreListAll(): number {
  const script = restoreScriptPath();
  if (!existsSync(script)) {
    console.log(`Would run: ${script} --list-all (foundation restore.sh not found)`);
    return 0;
  }
  return spawnInherit(script, ["--list-all"]);
}
