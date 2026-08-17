// types.ts — the Site entity model (mirrors src/foundation/schemas/site-fields.json)
// plus the client interfaces (the boundaries the engine depends on) and the
// reconcile plan shapes. Mirrors people-manager/src/types.ts.

// ── Site config entities (site.json) ──────────────────────────────────
export interface SiteLocation {
  country: string;
  timezone: string;
  locale?: string;
}

export interface SiteNetwork {
  isp?: string | null;
  publicIp?: string;
}

// A Proxmox node in hardware.nodes[].
export interface SiteNode {
  name: string;
  storagePools: string[];
}

export interface SiteBackup {
  target?: string | null;
  offsite?: string | null;
  defaultRetention?: string;
  offsiteResidency?: "eu-only" | "global";
}

// A module-catalog repository in repositories[].
export interface Repository {
  name: string;
  url: string;
  branch?: string;
  path?: string;
  managed?: "full" | "tracked";
  catalog?: string;
  // repositories[] is additionalProperties:true in the schema — keep extras.
  [k: string]: unknown;
}

// The canonical Site document (singleton).
export interface Site {
  name: string;
  // The default org/environment/zone name — decoupled from the site code `name`
  // so the site can be renamed without touching any environment/org/zone (#426).
  defaultEnvironment: string;
  displayName: string;
  owner: string;
  email?: string;
  version?: string;
  location: SiteLocation;
  network?: SiteNetwork;
  hardware: { nodes: SiteNode[] };
  backup?: SiteBackup | null;
  updateSchedule?: unknown[];
  automaticReboot?: boolean;
  snapshotRetention?: number;
  repositories: Repository[];
  // NOTE: environments are NOT a site field — they are enumerated from the
  // config/environments/*.json directory (SiteClient.listEnvironments), which is
  // what the --deep reconcile cascade fans out over.
  organizations?: string[];
}

// TODO(question): the editable surface of `site modify`. See PARKED Q1.
// The fields a `site modify --<field> <value>` is allowed to set. Discovery-
// derived fields (hardware.nodes via `node` CRUD) and lists managed by their
// own CRUD (repositories, organizations) are EXCLUDED here. (Environments are
// not a site field — they are the config/environments/*.json files.)
export type SiteModifiableField =
  | "displayName"
  | "owner"
  | "email"
  | "automaticReboot"
  | "snapshotRetention"
  | "backupTarget"
  | "backupOffsite"
  | "locationCountry"
  | "locationTimezone"
  | "locationLocale"
  | "networkIsp"
  | "networkPublicIp";

// ── Reconcile plan ─────────────────────────────────────────────────────
// site reconcile has two layers:
//   (1) own concern  — validate site.json + converge repositories[] to live
//                       clones (clone/checkout to match config).
//   (2) --deep cascade — shell out to dependent managers in dependency order:
//                        people → network → (every) environment.
export type SiteActionKind =
  | "validate-site"
  | "register-node"
  | "update-node-pools"
  | "clone-repo"
  | "checkout-repo"
  | "cascade-people"
  | "cascade-network"
  | "cascade-environment";

export interface SiteAction {
  kind: SiteActionKind;
  // Human-readable description for the plan summary.
  target: string;
  // Apply this action via the injected client. Returns the exit code of the
  // work: 0 = converged. Cascades return the child manager's rc, which MUST be
  // honoured — a cascade that fails is not an applied action (#461 follow-on:
  // the environment leg failed silently for as long as it existed, because
  // stream() returns the rc without throwing and nothing looked at it).
  // Local fs/git actions throw on failure and so always return 0.
  apply(client: SiteClient): number;
}

export interface SitePlan {
  actions: SiteAction[];
  warnings: string[];
}

// One planned action that ran and failed. Collected rather than thrown so a
// single failing cascade no longer strands every action planned after it —
// the shape environment-manager already uses for module failures (#454).
export interface SiteApplyFailure {
  // The action's target description.
  target: string;
  // What went wrong (child exit code, or the thrown error's message).
  error: string;
}

export interface SiteApplyResult {
  // Actions that completed successfully.
  applied: number;
  // Actions that ran and failed, in plan order. Empty ⇒ full convergence.
  failures: SiteApplyFailure[];
}

// ── SiteClient — the side-effecting boundary the engine depends on ─────
// Tests inject an in-memory fake; production uses CliSiteClient (spawnSync /
// fs). The reconcile engine is pure planning + apply against this interface.
export interface SiteClient {
  // (1) own concern.
  // Whether a repository's clone exists on disk at `path`.
  repoCloneExists(path: string): boolean;
  // Clone <url> into <path> (git clone https://<url> <path>).
  cloneRepo(url: string, path: string, branch: string): void;
  // The branch currently checked out at <path>, or null if unknown.
  currentBranch(path: string): string | null;
  // Check out <branch> at <path>.
  checkoutRepo(path: string, branch: string): void;
  // Validate site.json against site-fields.json (validate-site.sh). Returns
  // the list of validation errors (empty = valid).
  validateSite(siteFile: string): string[];

  // Live cluster NODE membership (node names), reached via one of the
  // `candidates` (the site's already-known node names). null = cluster
  // unreachable / query failed — the engine warns and plans nothing.
  // (F12 read-only carve-out: implemented via lib/ts cluster.ts.)
  clusterNodes(candidates: string[]): string[] | null;
  // The tankXY zpools physically present on <node> (create-site.sh's
  // discovery: `zpool list` on the node, tank* filter). null = query failed.
  nodeStoragePools(node: string): string[] | null;
  // Append a newly discovered cluster node to site.json .hardware.nodes
  // with its discovered pools (empty when discovery failed).
  registerNode(siteFile: string, name: string, pools: string[]): void;
  // Fill a known node's storagePools (used when site.json has [] but the
  // node reports pools — conservative: never overwrites a non-empty list).
  setNodePools(siteFile: string, name: string, pools: string[]): void;

  // (2) --deep cascade — shell out to a dependent manager's `reconcile`.
  // `apply` toggles preview vs commit (maps to the manager's --apply/--dry-run).
  //   people  → people-manager reconcile   (renamed from sync; now exists)
  //   network → network-manager reconcile  (system-wide: all zones, all planes)
  // Environments are enumerated then driven per-env via cascadeEnvironment().
  // Returns the child manager's exit code.
  cascade(manager: "people" | "network", apply: boolean): number;

  // The environment names registered for this site (config/environments/*.json)
  // — drives the per-environment leg of the --deep cascade.
  listEnvironments(): string[];

  // Drive one environment's deep reconcile, verb-first:
  //   environment-manager reconcile <env> --deep --skip-network [--apply]
  // --skip-network because the network cascade above already ran the one
  // system-wide pass; without it each environment repeats it (#461).
  // Returns the child manager's exit code.
  cascadeEnvironment(env: string, apply: boolean): number;

  // ── (3) thin delegations to the still-live bash tools ────────────────
  // The heavy git/cluster I/O stays in the .sh for this pass; TS owns config
  // CRUD + validate + reconcile and shells out for these.
  //   site add        → create-site.sh <args>
  createSite(args: string[]): number;
  //   repository add    → repository.sh add <args>
  repositoryAdd(args: string[]): number;
  //   repository modify → repository.sh modify <name> [--url u] [--branch b]
  repositoryModify(args: string[]): number;
  //   repository del    → repository.sh remove <name> [--force]
  repositoryRemove(name: string, force: boolean): number;
}
