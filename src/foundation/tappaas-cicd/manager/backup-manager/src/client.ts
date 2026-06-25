// client.ts — CliClient: the real Client. Shells out to the `backup-controller`
// bin on PATH for all PBS operations and parses its JSON output. NO PBS API is
// reimplemented here — this is a thin FFI boundary, exactly as people-manager
// shells out to authentik-manager and network-manager to the plane controllers.
//
// backup-controller is BASH (controller/backup-controller/backup-controller).
// Query verbs (`job-status` / `list` / `namespaces`) accept `--json` and emit a
// single JSON object — including {"reachable": false} when PBS/the cluster is
// offline (the controller degrades gracefully and still exits 0). This client
// uses --json and parses the structured output (NO human-line scraping). The
// mutation verbs (`add-to-job` / `apply-schedule`) are how reconcile pushes the
// resolved cascade into PBS — the controller owns the PBS write. A non-zero exit
// (other than the graceful offline skip) throws.

import { spawnSync } from "child_process";
import { Client, JobStatus } from "./types";

export class BackupControllerUnreachable extends Error {}

const BIN = process.env.BACKUP_CONTROLLER_BIN ?? "backup-controller";

function run(args: string[]): string {
  // The controller reads CONFIG_DIR (module/site JSONs live there); pass it
  // through explicitly so it never fails with "CONFIG_DIR is not set".
  const configDir =
    process.env.CONFIG_DIR ?? process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
  const env = { ...process.env, CONFIG_DIR: configDir, TAPPAAS_CONFIG: configDir };
  const r = spawnSync(BIN, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, env });
  if (r.error) {
    throw new BackupControllerUnreachable(`${BIN} ${args[0]}: ${r.error.message}`);
  }
  if (r.status !== 0) {
    const stderr = (r.stderr ?? "").trim();
    throw new Error(`${BIN} ${args.join(" ")} failed (exit ${r.status}): ${stderr}`);
  }
  return r.stdout ?? "";
}

// Run a query verb with --json and parse the single JSON object it emits.
// Returns {} when the output is not parseable (defensive; treated as offline).
function runJson(args: string[]): Record<string, unknown> {
  const out = run([...args, "--json"]).trim();
  if (out === "") return {};
  try {
    const v = JSON.parse(out);
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function asStringArray(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
}

export class CliClient implements Client {
  jobStatus(): JobStatus {
    // { reachable, jobId, storage, vmids } — reachable:false when PBS offline.
    const o = runJson(["job-status"]);
    // The controller always emits a `reachable` boolean; if it is absent the
    // output was empty/unparseable ⇒ treat as offline (defensive).
    const reachable = o.reachable === true;
    return {
      jobId: typeof o.jobId === "string" ? o.jobId : null,
      vmids: asStringArray(o.vmids),
      storage: typeof o.storage === "string" ? o.storage : null,
      reachable,
    };
  }

  listSnapshots(module: string): string[] {
    // { reachable, module, vmid, snapshots: [backup-time, ...] }.
    const o = runJson(["list", module]);
    return asStringArray(o.snapshots);
  }

  namespaces(): string[] {
    // { reachable, storage, namespaces: [...] }.
    const o = runJson(["namespaces"]);
    return asStringArray(o.namespaces);
  }

  verify(module: string): void {
    run(["verify", module]);
  }

  addToJob(vmid: string, retention?: string): void {
    const args = ["add-to-job", vmid];
    if (retention) args.push("--retention", retention);
    run(args);
  }

  applySchedule(spec: string): void {
    run(["apply-schedule", spec]);
  }
}
