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
  environments?: string[];
  organizations?: string[];
}

// TODO(question): the editable surface of `site modify`. See PARKED Q1.
// The fields a `site modify --<field> <value>` is allowed to set. Discovery-
// derived fields (hardware.nodes via `node` CRUD) and lists managed by their
// own CRUD (repositories, environments, organizations) are EXCLUDED here.
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
  | "clone-repo"
  | "checkout-repo"
  | "cascade-people"
  | "cascade-network"
  | "cascade-environment";

export interface SiteAction {
  kind: SiteActionKind;
  // Human-readable description for the plan summary.
  target: string;
  // Apply this action via the injected client.
  apply(client: SiteClient): void;
}

export interface SitePlan {
  actions: SiteAction[];
  warnings: string[];
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

  // (2) --deep cascade — shell out to a dependent manager's `reconcile`.
  // `apply` toggles preview vs commit (maps to the manager's --apply/--dry-run).
  //   people  → people-manager reconcile   (renamed from sync; now exists)
  //   network → network-manager reconcile
  // Environments are enumerated then driven per-env via cascadeEnvironment().
  cascade(manager: "people" | "network", apply: boolean): void;

  // The environment names registered for this site (config/environments/*.json)
  // — drives the per-environment leg of the --deep cascade.
  listEnvironments(): string[];

  // Drive one environment's deep reconcile:
  //   environment-manager <env> reconcile --deep [--apply]
  cascadeEnvironment(env: string, apply: boolean): void;

  // ── (3) thin delegations to the still-live bash tools ────────────────
  // The heavy git/cluster I/O stays in the .sh for this pass; TS owns config
  // CRUD + validate + reconcile and shells out for these.
  //   site add        → create-site.sh <args>
  createSite(args: string[]): number;
  //   repository add  → repository.sh add <args>
  repositoryAdd(args: string[]): number;
  //   repository del  → repository.sh remove <name> [--force]
  repositoryRemove(name: string, force: boolean): number;
}
