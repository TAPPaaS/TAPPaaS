// types.ts — the backup-policy entity model (the Site → Environment → Module
// cascade, ADR-007 P9 / verb-alignment #3) plus the Client interface (the
// pbs-controller boundary) and the reconcile plan shapes.
//
// Entity model: the backup `job`/`policy` is the EFFECTIVE backup policy
// resolved for a deployed module by cascading site.json `.backup`, the
// module's environment `.backup`, and the module's own `.backup` (module >
// environment > site). It is NOT a standalone object stored in one place — it
// is computed by the cascade (mirrors lib-cascade.sh `bc_resolve`).

// ── Raw config layers (the `.backup` object on each JSON file) ─────────
// Each is the parsed `.backup` block (or {} when absent). Only the fields the
// cascade reads are modelled; unknown keys are ignored.
export interface SiteBackup {
  defaultRetention?: string;
  target?: string | null;
  offsite?: string | null;
  offsiteResidency?: string;
}

export interface EnvironmentBackup {
  retention?: string;
  residency?: string;
  schedule?: string | null;
  // dataResidency lives at the environment top level, not under .backup, but
  // the cascade folds it in as a residency fallback.
  dataResidency?: string | null;
}

export interface ModuleBackup {
  enabled?: boolean;
  retention?: string;
  exclude?: string[];
}

// A resolved schedule maps to exactly one cluster backup job (ADR-012 D16).
export type ScheduleBucket = "daily" | "weekly" | "monthly";

// ── The resolved effective policy (the CRUD entity) ───────────────────
// One object per module — the JSON `bc_resolve` prints. residency has no
// module layer; target/offsite come from the site.
export interface BackupPolicy {
  module: string;
  environment: string | null;
  enabled: boolean;
  retention: string;
  residency: string;
  // Always resolved (ADR-012 §3.2): module > environment > site > "daily".
  schedule: string;
  // The job this resolves to; null when the schedule is not a supported one,
  // which `validate` reports as an error rather than defaulting away.
  scheduleBucket: ScheduleBucket | null;
  target: string | null;
  offsite: string | null;
  exclude: string[];
}

// Where a membership answer came from — `list`/`show` say so rather than
// letting the reader assume PBS was consulted (#627).
//   "job"         read from the managed bucket jobs
//   "declaration" PBS unreachable; the opt-in echoed as a fallback
export type MembershipSource = "job" | "declaration";

// Policy as enriched by `list`/`show`. The declaration and actual job
// membership are SEPARATE fields, because they diverge and the divergence is
// the interesting part (#627): `IN-PBS-JOB` used to be computed from the
// declaration alone, so an archived module — VM destroyed, config and
// declaration kept — reported as backed up when no snapshot could be taken.
export interface BackupPolicyStatus extends BackupPolicy {
  // The DECLARATION: dependsOn or integratesWith contains backup:vm.
  optedIn: boolean;
  // status=archived: the VM is gone, the config and its snapshots are kept.
  // Explains a true/false split as intended state rather than drift.
  archived: boolean;
  // ACTUAL membership of a managed bucket job (the union over all buckets).
  // Falls back to optedIn when PBS is unreachable — membershipSource says which.
  inPbsJob: boolean;
  // Which bucket job holds it; null when it is not a member (or unknown).
  jobBucket: ScheduleBucket | null;
  membershipSource: MembershipSource;
}

// ── Placement (ADR-012 §2.1) — where/whether PBS is realized ──────────
// Read from backup.json. There is no `placement` policy field: placementState
// is the single source of truth, install-resolved. The manager surfaces it
// (validate warns on a shim) so operators can see when backups have no
// datastore yet.
export type PlacementKind = "shim" | "external" | "local" | "unresolved";
export interface Placement {
  // node:<name> | shim | external — or a legacy local | remote-only until the
  // module's next update migrates it; null when never resolved.
  placementState: string | null;
  kind: PlacementKind; // classified state, legacy values folded in
  node: string | null; // the node PBS runs on, when kind is "local"
  pbsUrl: string; // the PBS clients push to (default backup.mgmt.internal)
  pbsStorageName: string; // datastore / pvesm storage the managed job targets
  pushTarget: string | null; // DEPRECATED — legacy remote-only push target
}

// ── Off-site peer (ADR-012 §3.1) — the symmetric pull / receive / push ─
// A PBS is simultaneously a pull replicator (remote-<n>), a push receiver
// (external-<n>), and/or a push sender (push-<n>). listPeers surfaces all three.
export type PeerRole = "pull" | "remote" | "receive";
export interface Peer {
  name: string;
  // pull: we pull theirs · remote: they pull ours · receive: they push into ours
  role: PeerRole;
  remoteHost: string | null;
  namespace: string | null;
  // Where it is (ADR-036 D5): the location it names, and that location's place
  // from site.json. A peer migration 0019 has not reached names none; its
  // physicalLocation is its place until then.
  location: string | null;
  place: { displayName?: string; country?: string; city?: string; address?: string } | null;
  // #796: "<serve|dial> <net/30>[ :port]" when the pull runs over a buddy tunnel.
  tunnel: string | null;
}

// ── Client — the pbs-controller boundary ───────────────────────────
// The reconcile/restore logic depends ONLY on this interface; tests inject an
// in-memory fake, production uses CliClient (spawnSync → `pbs-controller`).
// NO PBS API is reimplemented in TypeScript — exactly as identity-manager shells
// out to authentik-controller and network-manager to the plane controllers.
// One managed bucket job (ADR-012 D16) and who is in it.
export interface BucketMembership {
  bucket: ScheduleBucket;
  jobId: string;
  vmids: string[];
}

export interface JobStatus {
  jobId: string | null; // managed DAILY job id, null when none created yet
  vmids: string[]; // vmids covered by the DAILY job (not the union — see buckets)
  storage: string | null;
  // Every managed bucket job that exists. A coverage question is the union over
  // these; `vmids` alone answers only for daily (#627). Empty when offline.
  buckets: BucketMembership[];
  reachable: boolean; // false ⇒ PBS/cluster offline (controller skipped)
}

// One cluster backup job that covers a VM (#554) — TAPPaaS's own or anyone else's.
export interface JobCoverage {
  jobId: string;
  how: "explicit" | "all" | "pool"; // its --vmid list | --all | a pool selection
  storage: string;
  schedule: string;
  enabled: boolean;
  managed: boolean; // one of TAPPaaS's marked bucket jobs
}

export interface PurgeResult {
  vmid: string;
  store: string;
  snapshots: number;
  bytes: number;
  refused: string[];
  purged: boolean;
}

// pbs-controller runs --json: the datastore's snapshots, the verify and sync
// jobs, the cluster's backup jobs and recent vzdump tasks, as PBS/PVE give them.
// Shaped into BackupRuns by restore.ts (shapeRuns).
export interface RawSnapshot {
  ns: string;
  type: string; // vm | ct | host
  id: string;
  time: number;
  size?: number | null;
  verification?: { state?: string; upid?: string } | null;
}
export interface RawRuns {
  reachable: boolean;
  node?: string;
  store?: string;
  marker?: string;
  snapshots?: RawSnapshot[];
  verifyJobs?: Record<string, unknown>[];
  syncJobs?: Record<string, unknown>[];
  backupJobs?: { id: string; comment: string; schedule: string; enabled: boolean; vmid: string; storage: string }[];
  tasks?: { node?: string; id?: string; starttime?: number; endtime?: number; status?: string }[];
}

export type VerifyState = "ok" | "failed" | "unverified";
export interface LastVerify { time: number | null; state: "ok" | "failed" }

// One backup group (a guest, or a host's file backup) in one namespace.
export interface GuestRuns {
  ns: string;
  type: string;
  id: string;
  module: string | null;
  snapshots: number;
  lastBackup: number | null;
  // The job that covers it (own guests) and how often that job runs.
  job: string | null;
  bucket: ScheduleBucket | null;
  // ok: backed up within its job's interval · late: not · not-in-job: no
  // TAPPaaS job covers it (a removed guest, a copy, a host's file backup).
  outcome: "ok" | "late" | "not-in-job";
  // The newest snapshot's verification, and the newest verify of any snapshot.
  latestVerify: VerifyState;
  lastVerify: LastVerify | null;
  failedVerifies: number;
}

// One namespace: this site's own guests, a host's file backups, another
// site's copy pulled or pushed here.
export interface TargetRuns {
  ns: string;
  kind: "own" | "host" | "pull" | "receive" | "other";
  groups: number;
  snapshots: number;
  lastBackup: number | null;
  lastVerify: LastVerify | null;
  unverified: number;
  failedVerifies: number;
}

export interface JobLastRun { time: number; end: number | null; state: string }
export interface BackupRuns {
  reachable: boolean;
  node: string | null;
  store: string | null;
  guests: GuestRuns[];
  targets: TargetRuns[];
  // The cluster's backup jobs; lastRun is the newest scheduled vzdump run on
  // any node (PVE does not name the job in its task), per node in `runs`.
  jobs: { id: string; managed: boolean; bucket: ScheduleBucket | null; schedule: string; enabled: boolean; guests: number }[];
  runs: { node: string; time: number; end: number | null; state: string; guest: string | null }[];
  verifyJobs: { id: string; schedule: string; lastRun: JobLastRun | null; nextRun: number | null }[];
  syncJobs: { id: string; remote: string; ns: string; schedule: string; lastRun: JobLastRun | null; nextRun: number | null }[];
}

export interface Client {
  // pbs-controller job-status --json — the shared PBS backup job state.
  jobStatus(): JobStatus;
  // pbs-controller coverage <module> --json — every job covering its VM;
  // null when the cluster did not answer (#554).
  coverage(module: string): JobCoverage[] | null;
  // pbs-controller list <module> --json — snapshot backup-times for a VM.
  listSnapshots(module: string): string[];
  // ── PBS mutations (reconcile apply → controller owns the PBS write) ──
  // pbs-controller add-to-job <vmid> [--retention <spec>] — ensure a vmid
  // is a member of the shared managed PBS backup job.
  addToJob(vmid: string, retention?: string, bucket?: string): void;
  // pbs-controller apply-schedule <spec> — set the shared job's start time.
  applySchedule(spec: string): void;
  // pbs-controller backup <module>... — take each module's backup NOW, through
  // the TAPPaaS job that covers it (#759). Streams the controller's output (a
  // backup takes minutes) and returns its exit code: 0 only if every module's
  // snapshot was written and found.
  backupNow(modules: string[]): number;
  // pbs-controller purge <vmid> --json [--yes] (#789) — erase vm/<vmid>'s
  // restore points and start GC; without yes, only the plan. Refusals come back
  // in `refused` (the controller exits 1 then), never as a throw.
  purge(vmid: string, yes: boolean): PurgeResult;
  // pbs-controller runs --json — what restore list-all --json shapes;
  // {reachable:false} when PBS/the cluster did not answer.
  runs(): RawRuns;
  keyList(): void;
  keyExport(dest: string): void;
  keyImport(src: string): void;
  keyStatus(json: boolean): void;
  keyStamp(dir: string, label: string | null): void;
}

// ── Reconcile plan ────────────────────────────────────────────────────
// reconcile = apply the resolved cascade to PBS (port of backup-manager.sh).
// The manager RESOLVES the Site→Environment→Module policy; the controller OWNS
// the PBS write (add-to-job / apply-schedule). Modelled as a preview/apply plan
// matching the network-manager reconcile shape.
export type ActionKind = "ensure-job-member" | "apply-schedule";

export interface Action {
  kind: ActionKind;
  target: string; // human-readable summary for the plan
  apply(client: Client): void;
}

export interface Plan {
  actions: Action[];
  warnings: string[];
}
