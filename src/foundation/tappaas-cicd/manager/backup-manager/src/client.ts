// client.ts — CliClient: the real Client. Shells out to the `backup-controller`
// bin on PATH for all PBS operations and parses its JSON output. NO PBS API is
// reimplemented here — this is a thin FFI boundary, exactly as people-manager
// shells out to authentik-manager and network-manager to the plane controllers.
//
// backup-controller is BASH (controller/backup-controller/backup-controller).
// Query verbs (`job-status` / `list`) accept `--json` and emit a
// single JSON object — including {"reachable": false} when PBS/the cluster is
// offline (the controller degrades gracefully and still exits 0). This client
// uses --json and parses the structured output (NO human-line scraping). The
// mutation verbs (`add-to-job` / `apply-schedule`) are how reconcile pushes the
// resolved cascade into PBS — the controller owns the PBS write. A non-zero exit
// (other than the graceful offline skip) throws.

import { captureResult } from "../../../lib/ts/src/exec";
import { Client, JobStatus } from "./types";

export class BackupControllerUnreachable extends Error {}

const BIN = process.env.BACKUP_CONTROLLER_BIN ?? "backup-controller";

function run(args: string[]): string {
  // The controller reads CONFIG_DIR (module/site JSONs live there); the lib's
  // captureResult injects the resolved config root in BOTH spellings
  // (CONFIG_DIR + TAPPAAS_CONFIG), so it never fails with "CONFIG_DIR is not
  // set". A spawn failure (binary missing on PATH) is the DISTINCT
  // BackupControllerUnreachable — callers (e.g. cmdReconcile's offline
  // preview) rely on catching it; a non-zero exit stays a generic Error.
  const r = captureResult(BIN, args);
  if (!r.ran) {
    throw new BackupControllerUnreachable(`${BIN} ${args[0]}: ${r.stderr}`);
  }
  if (r.rc !== 0) {
    throw new Error(`${BIN} ${args.join(" ")} failed (exit ${r.rc}): ${r.stderr.trim()}`);
  }
  return r.stdout;
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
  // ADR-012 P7: endpoint-agnostic. When constructed with a PBS endpoint (e.g. a
  // satellite tunnel host), every controller call is prefixed `--pbs <endpoint>`
  // so the SAME operations drive the local or a remote/satellite PBS. Omitted →
  // the controller acts on the local PBS (unchanged default).
  constructor(private readonly pbsEndpoint?: string) {}
  private ep(): string[] {
    return this.pbsEndpoint ? ["--pbs", this.pbsEndpoint] : [];
  }

  jobStatus(): JobStatus {
    // { reachable, jobId, storage, vmids } — reachable:false when PBS offline.
    const o = runJson([...this.ep(), "job-status"]);
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
    const o = runJson([...this.ep(), "list", module]);
    return asStringArray(o.snapshots);
  }

  addToJob(vmid: string, retention?: string): void {
    const args = [...this.ep(), "add-to-job", vmid];
    if (retention) args.push("--retention", retention);
    run(args);
  }

  applySchedule(spec: string): void {
    run([...this.ep(), "apply-schedule", spec]);
  }
}
