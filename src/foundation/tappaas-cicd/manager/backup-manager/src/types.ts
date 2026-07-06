// types.ts — the backup-policy entity model (the Site → Environment → Module
// cascade, ADR-007 P9 / verb-alignment #3) plus the Client interface (the
// backup-controller boundary) and the reconcile plan shapes.
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

// ── The resolved effective policy (the CRUD entity) ───────────────────
// One object per module — the JSON `bc_resolve` prints. residency has no
// module layer; schedule/target/offsite inherit from env/site.
export interface BackupPolicy {
  module: string;
  environment: string | null;
  enabled: boolean;
  retention: string;
  residency: string;
  schedule: string | null;
  target: string | null;
  offsite: string | null;
  exclude: string[];
}

// Policy as enriched by `list`/`show`: adds the PBS-job wiring flag.
export interface BackupPolicyStatus extends BackupPolicy {
  inPbsJob: boolean; // module declares dependsOn backup:vm
}

// ── Placement (ADR-012) — where/whether the local PBS is realized ─────
// Read from backup.json; the manager surfaces it (validate warns on a shim) so
// operators can see when backups have no datastore yet.
export interface Placement {
  placement: string; // policy: auto | node:<n> | shim | remote-only
  placementState: string | null; // resolved: local | shim | remote-only (null = legacy/unset)
  pbsStorageName: string; // datastore / pvesm storage the managed job targets
  pushTarget: string | null; // remote-only default push target name (or null)
}

// ── Off-site peer (ADR-012 §3.1) — the symmetric pull / receive / push ─
// A PBS is simultaneously a pull replicator (remote-<n>), a push receiver
// (external-<n>), and/or a push sender (push-<n>). listPeers surfaces all three.
export type PeerRole = "pull" | "receive" | "push";
export interface Peer {
  name: string;
  role: PeerRole; // pull=remote-<n>, receive=external-<n>, push=push-<n>
  remoteHost: string | null;
  namespace: string | null;
}

// ── Client — the backup-controller boundary ───────────────────────────
// The reconcile/restore logic depends ONLY on this interface; tests inject an
// in-memory fake, production uses CliClient (spawnSync → `backup-controller`).
// NO PBS API is reimplemented in TypeScript — exactly as people-manager shells
// out to authentik-manager and network-manager to the plane controllers.
export interface JobStatus {
  jobId: string | null; // managed PBS job id, null when none created yet
  vmids: string[]; // vmids covered by the shared job
  storage: string | null;
  reachable: boolean; // false ⇒ PBS/cluster offline (controller skipped)
}

export interface Client {
  // backup-controller job-status --json — the shared PBS backup job state.
  jobStatus(): JobStatus;
  // backup-controller list <module> --json — snapshot backup-times for a VM.
  listSnapshots(module: string): string[];
  // ── PBS mutations (reconcile apply → controller owns the PBS write) ──
  // backup-controller add-to-job <vmid> [--retention <spec>] — ensure a vmid
  // is a member of the shared managed PBS backup job.
  addToJob(vmid: string, retention?: string): void;
  // backup-controller apply-schedule <spec> — set the shared job's start time.
  applySchedule(spec: string): void;
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
