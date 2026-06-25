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
  status?: string | null; // e.g. archived | Testing | Development
  environment?: string | null;
  location?: string | null; // module source dir (where install/update/test.sh live)
  installTime?: string | null;
  updateTime?: string | null;
  dependsOn?: string[];
  provides?: string[];
  // Preserve any other fields so a load can round-trip / show in full.
  raw: Record<string, unknown>;
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
  // reconcile-module.sh [opts] <module>  (the LEAF converge: re-apply current
  // config — NO snapshot/test/merge/updateTime; distinct from modify)
  reconcile(module: string, opts: ReconcileOptions): number;
  // test-module.sh [opts] <module>
  test(module: string, opts: TestOptions): number;
  // snapshot-vm.sh <module> [action]
  snapshot(module: string, action: SnapshotAction): number;
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
