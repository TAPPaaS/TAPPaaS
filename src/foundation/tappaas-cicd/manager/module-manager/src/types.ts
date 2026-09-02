// types.ts — the module-manager entity model + the ModuleClient interface (the
// bash-script boundary the manager orchestrates through) + the validate result
// shapes.
//
// Mirrors people-manager / network-manager: the CONFIG-layer verbs (list / show
// / validate) operate on this in-process model; the LIFECYCLE verbs (add /
// modify / delete / reconcile / test / snapshot-vm) delegate to the existing
// bash scripts via the injected ModuleClient (production = CliModuleClient,
// tests = a fake). The heavy cluster logic stays in bash for this first-pass
// port — module-manager is a thin orchestration boundary.

// ── Module config entity (a deployed config/<module>.json) ────────────
// A deployed module config. The shape is open (modules carry many bespoke
// fields per module-fields.json); these are the ones list/show/validate read.
// Permitted `status` values — the single TS-side source of truth, mirroring the
// `status.values` set in schemas/module-fields.json (#556). `archived` = VM
// removed via delete-module.sh --archive, config kept as the archive record
// (#215); `external` = guest managed outside TAPPaaS (#216).
export const MODULE_STATUS_VALUES = [
  "Development",
  "Testing",
  "Production",
  "Deprecated",
  "archived",
  "external",
] as const;
export type ModuleStatus = (typeof MODULE_STATUS_VALUES)[number];

// `name` is the config basename (the deployed/effective module name).
export interface ModuleConfig {
  name: string; // basename of config/<name>.json (effective module name)
  kind?: string; // "module" once tagged by install-module.sh (ADR-007 #3)
  description?: string;
  vmname?: string;
  vmid?: number | null;
  node?: string | null;
  zone0?: string | null;
  zone1?: string | null;
  tier?: string | null; // foundation | app  (default app when absent)
  source?: string | null; // official | community | private | local (default official)
  status?: ModuleStatus | null; // permitted set: MODULE_STATUS_VALUES (validated in validate.ts)
  environment?: string | null;
  location?: string | null; // module source dir (where install/update/test.sh live)
  installTime?: string | null;
  updateTime?: string | null;
  dependsOn?: string[];
  integratesWith?: string[]; // optional deps: same wiring, silently skipped when absent (#501)
  provides?: string[];
  // Preserve any other fields so a load can round-trip / show in full.
  raw: Record<string, unknown>;
}

// ── A running guest as Proxmox reports it (pvesh /cluster/resources) ───
// Ported from health-manager so `module list` can fold the LIVE cluster state
// (running guest vs config) into its config table — the superset of what
// `health-manager list vm` used to show.
export interface RunningGuest {
  vmid: number;
  name: string;
  node: string;
  status: string; // running | stopped | ...
  type: "qemu" | "lxc";
  template?: boolean; // true for a Proxmox template (pvesh template=1)
}

// ── Lifecycle verb options (parsed from the CLI, forwarded to the bins) ─
export interface AddOptions {
  environment?: string;
  allowFork?: boolean;
  force?: boolean;
  reinstall?: boolean;
  // Arbitrary --<field> <value> overrides passed straight through to
  // install-module.sh / copy-update-json.sh (e.g. --node, --vmid, --zone0,
  // --proxyDomain, --proxyTls). Kept as a flat arg vector.
  passthrough: string[];
}

export interface ModifyOptions {
  environment?: string;
  force?: boolean;
  noSnapshot?: boolean;
  debug?: boolean;
  silent?: boolean;
}

export interface DeleteOptions {
  environment?: string;
  mode?: "archive" | "remove"; // default archive
  vmid?: string;
  yes?: boolean;
  force?: boolean;
}

export interface TestOptions {
  deep?: boolean;
  vmid?: string;
  zone0?: string;
}

export interface ReconcileOptions {
  environment?: string;
  debug?: boolean;
  silent?: boolean;
}

// Options for the READ-ONLY inspect (`reconcile` without --apply, and each
// module of `list --diff`).
export interface InspectOptions {
  // Check the state each dependsOn provider provisions outside the VM (firewall
  // rules, NAT rules, discovery relays) by running its read-only
  // test-service.sh (#458). Costs one child process — usually one firewall API
  // round-trip — per dependency, hence ON for a single-module reconcile and OFF
  // for the `list --diff` rollup / the reconcile --deep preview cascade.
  checkServices?: boolean;
}

export type SnapshotAction =
  | { kind: "create" }
  | { kind: "list" }
  | { kind: "cleanup"; keep: number }
  | { kind: "restore"; steps: number };

// ── ModuleClient — one method per lifecycle bash script ────────────────
// The orchestration layer depends ONLY on this interface. Each method shells
// out to the existing on-PATH script and returns its exit code. NO cluster
// logic is reimplemented in TS for this first-pass port.
export interface ModuleClient {
  // install-module.sh <module> [...]
  add(module: string, opts: AddOptions): number;
  // update-module.sh [opts] <module>  (release update: snapshot + test + merge)
  modify(module: string, opts: ModifyOptions): number;
  // delete-module.sh <module> [...]
  delete(module: string, opts: DeleteOptions): number;
  // src/reconcile.ts (native TS, in-process)  (the LEAF converge: re-apply
  // current config — NO snapshot/test/merge/updateTime; distinct from modify)
  reconcile(module: string, opts: ReconcileOptions): number;
  // src/inspect.ts (native TS, in-process)  (READ-ONLY three-way drift report:
  // Released[git] / Desired[~/config] / Actual[running VM]; config-only fallback
  // when the module has no vmid, plus the dependency-service state on both
  // paths). Backs `reconcile` WITHOUT --apply and, per module, the `list --diff`
  // rollup.
  inspect(module: string, opts?: InspectOptions): number;
  // test-module.sh [opts] <module>
  test(module: string, opts: TestOptions): number;
  // snapshot-vm.sh <module> [action]
  snapshot(module: string, action: SnapshotAction): number;
  // Cluster-wide running guests (pvesh /cluster/resources --type vm), used to
  // fold LIVE running-vs-config state into the default `list`. BEST-EFFORT: it
  // returns [] (never throws) when the cluster is unreachable, so `list` can
  // gracefully degrade to a config-only view.
  clusterResources(): RunningGuest[];
}

// ── validate result ───────────────────────────────────────────────────
export type ValidateSeverity = "error" | "warning";

export interface ValidateFinding {
  module: string; // config basename
  severity: ValidateSeverity;
  message: string;
}

export interface ValidateReport {
  findings: ValidateFinding[];
  errors: number;
  warnings: number;
}
