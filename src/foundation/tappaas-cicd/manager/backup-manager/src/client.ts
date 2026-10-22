// client.ts — CliClient: the real Client. Shells out to the `pbs-controller`
// bin on PATH for all PBS operations and parses its JSON output. NO PBS API is
// reimplemented here — this is a thin FFI boundary, exactly as identity-manager
// shells out to authentik-controller and network-manager to the plane controllers.
//
// pbs-controller is BASH (controller/pbs-controller/pbs-controller).
// Query verbs (`job-status` / `list`) accept `--json` and emit a
// single JSON object — including {"reachable": false} when PBS/the cluster is
// offline (the controller degrades gracefully and still exits 0). This client
// uses --json and parses the structured output (NO human-line scraping). The
// mutation verbs (`add-to-job` / `apply-schedule`) are how reconcile pushes the
// resolved cascade into PBS — the controller owns the PBS write. A non-zero exit
// (other than the graceful offline skip) throws.

import { captureResult, stream } from "../../../lib/ts/src/exec";
import { JobCoverage, BucketMembership, Client, JobStatus, PurgeResult, RawRuns, ScheduleBucket } from "./types";

export class BackupControllerUnreachable extends Error {}

const BIN = process.env.BACKUP_CONTROLLER_BIN ?? "pbs-controller";

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

const BUCKETS: ScheduleBucket[] = ["daily", "weekly", "monthly"];

// Parse the controller's `.buckets` array. An entry naming a bucket we do not
// model, or carrying no job id, is dropped rather than coerced: a membership
// list is used to answer "is this backed up?", so a half-understood entry must
// not become a confident answer.
function asBuckets(v: unknown): BucketMembership[] {
  if (!Array.isArray(v)) return [];
  const out: BucketMembership[] = [];
  for (const e of v) {
    if (!e || typeof e !== "object" || Array.isArray(e)) continue;
    const o = e as Record<string, unknown>;
    const bucket = BUCKETS.find((b) => b === o.bucket);
    if (!bucket || typeof o.jobId !== "string" || o.jobId === "") continue;
    out.push({ bucket, jobId: o.jobId, vmids: asStringArray(o.vmids) });
  }
  return out;
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
      buckets: asBuckets(o.buckets),
      reachable,
    };
  }

  coverage(module: string): JobCoverage[] | null {
    const o = runJson([...this.ep(), "coverage", module]);
    if (o.reachable !== true || !Array.isArray(o.jobs)) return null;
    const out: JobCoverage[] = [];
    for (const e of o.jobs as unknown[]) {
      if (!e || typeof e !== "object") continue;
      const j = e as Record<string, unknown>;
      if (typeof j.jobId !== "string" || !["explicit", "all", "pool"].includes(String(j.how))) continue;
      out.push({
        jobId: j.jobId,
        how: j.how as JobCoverage["how"],
        storage: typeof j.storage === "string" ? j.storage : "",
        schedule: typeof j.schedule === "string" ? j.schedule : "",
        enabled: j.enabled !== false,
        managed: j.managed === true,
      });
    }
    return out;
  }

  listSnapshots(module: string): string[] {
    // { reachable, module, vmid, snapshots: [backup-time, ...] }.
    const o = runJson([...this.ep(), "list", module]);
    return asStringArray(o.snapshots);
  }

  purge(vmid: string, yes: boolean): PurgeResult {
    // Read the JSON even on exit 1: a refusal is an answer, with its reasons.
    const args = [...this.ep(), "purge", vmid, "--json", ...(yes ? ["--yes"] : [])];
    const r = captureResult(BIN, args);
    if (!r.ran) throw new BackupControllerUnreachable(`${BIN} purge: ${r.stderr}`);
    // The object is the last line of stdout (jq -c); anything before it is noise.
    let o: Record<string, unknown> = {};
    const last = r.stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop() ?? "{}";
    try {
      o = JSON.parse(last) as Record<string, unknown>;
    } catch {
      o = {};
    }
    if (typeof o.vmid !== "string") {
      throw new Error(`${BIN} purge ${vmid} failed (exit ${r.rc}): ${r.stderr.trim()}`);
    }
    return {
      vmid: o.vmid,
      store: typeof o.store === "string" ? o.store : "",
      snapshots: typeof o.snapshots === "number" ? o.snapshots : 0,
      bytes: typeof o.bytes === "number" ? o.bytes : 0,
      refused: asStringArray(o.refused),
      purged: o.purged === true,
    };
  }

  runs(): RawRuns {
    const o = runJson([...this.ep(), "runs"]);
    return { ...o, reachable: o.reachable === true } as RawRuns;
  }

  addToJob(vmid: string, retention?: string, bucket?: string): void {
    const args = [...this.ep(), "add-to-job", vmid];
    if (retention) args.push("--retention", retention);
    if (bucket) args.push("--bucket", bucket);
    run(args);
  }

  applySchedule(spec: string): void {
    run([...this.ep(), "apply-schedule", spec]);
  }

  // Streamed, not captured: a backup takes minutes and the operator watches it.
  // Never with --pbs: the backup jobs are this cluster's, whichever PBS the
  // datastore verbs were pointed at.
  backupNow(modules: string[]): number {
    try {
      return stream(BIN, ["backup", ...modules]);
    } catch (e) {
      throw new BackupControllerUnreachable(`${BIN} backup: ${(e as Error).message}`);
    }
  }

  // Encryption-key escrow (ADR-012 §2.5.1). The controller owns the files;
  // this is the operator-facing surface the ADR names.
  //
  // These PRINT the controller's output rather than swallowing it: every other
  // verb here is a machine call whose result the manager interprets, but these
  // three are read by a person — the list of keys they hold, and the warnings
  // about what losing them costs. Captured and discarded, `key list` printed
  // nothing at all.
  keyList(): void {
    process.stdout.write(run([...this.ep(), "key", "list"]));
  }
  keyExport(dest: string): void {
    process.stdout.write(run([...this.ep(), "key", "export", dest]));
  }
  keyImport(src: string): void {
    process.stdout.write(run([...this.ep(), "key", "import", src]));
  }
}
