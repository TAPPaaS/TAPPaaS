// types.ts — the Environment entity model (mirrors
// src/foundation/schemas/environment-fields.json) plus the NetworkClient /
// ModuleClient interfaces (the reconcile-cascade boundary) and the reconcile
// plan shapes.
//
// An Environment is a per-tenant deployment context (ADR-007c): it owns the
// public domain(s), DNS mode, network-zone reference, data-residency, backup
// retention and legal processor for a set of services. ownerOrg references a
// People Organization by name; network.zone references a zone in zones.json.

// ── Environment config entity ────────────────────────────────────────
export type DnsMode = "per-service" | "wildcard";
export type AliasMode = "redirect" | "mirror";
export type DataResidency = "eu-only" | "global";

export interface Domains {
  primary: string;
  aliases?: string[];
  aliasMode?: AliasMode;
  dnsMode?: DnsMode;
}

export interface NetworkRef {
  // Reference to a zone key in zones.json (validated).
  zone: string;
}

export interface BackupPolicy {
  retention?: string;
  residency?: DataResidency;
  schedule?: string | null;
}

export interface LegalMeta {
  processor?: string | null;
}

export interface Environment {
  name: string;
  displayName: string;
  ownerOrg: string;
  network: NetworkRef;
  domains?: Domains;
  dataResidency?: DataResidency;
  backup?: BackupPolicy | null;
  legal?: LegalMeta | null;
}

// The loaded + indexed environment domain (keyed by environment name).
export interface EnvironmentModel {
  environments: Map<string, Environment>;
}

// ── External references the validator checks against ──────────────────
// A read view of zones.json (zone key → anything) and of the People
// organizations on disk — both injected so the validator/reconcile engines stay
// pure and testable.
export interface RefSources {
  // The set of zone keys present in zones.json (empty set ⇒ zones.json absent).
  zoneNames: Set<string>;
  // Whether zones.json was available at all (distinguishes "no zones" from
  // "couldn't read zones.json" → warning vs error, mirroring the bash script).
  zonesAvailable: boolean;
  // The set of known People organization names (config/people/organizations/*).
  orgNames: Set<string>;
}

// ── Client boundary errors ────────────────────────────────────────────
// Raised when a manager binary cannot be SPAWNED at all (missing on PATH) — an
// environment fault, not a fault of the target being reconciled. It lives here
// rather than in clients.ts so the pure reconcile engine can tell it apart from
// a target that ran and failed, without depending on the CLI implementation.
// clients.ts re-exports it for existing importers.
export class NetworkUnreachable extends Error {}

// ── NetworkClient — the network-manager boundary (shallow reconcile) ──
// `environment reconcile` triggers a network convergence by shelling out to
// network-manager. The engine depends only on this interface; tests inject a
// fake, production uses CliNetworkClient (spawnSync).
export interface NetworkClient {
  // Whether a zone with this key exists in zones.json (network-manager exists).
  zoneExists(zone: string): boolean;
  // Converge the network planes. apply=false ⇒ dry-run/preview (the default).
  //
  // SYSTEM-WIDE (#461): network-manager reconcile takes no zone or environment
  // filter — it converges every zone on every plane, and none of the four plane
  // bins (zone-manager, proxmox-controller, switch-controller, ap-controller)
  // accepts a zone selector either. Callers must NOT present this as scoped to
  // one environment, and must not repeat it per environment: N environments
  // means N identical whole-system passes. See --skip-network.
  reconcileNetwork(apply: boolean): void;
}

// ── ModuleClient — the module-manager boundary (--deep cascade) ───────
// `environment reconcile --deep` additionally re-applies every module that was
// deployed into this environment (module reconcile, the leaf re-apply).
export interface ModuleClient {
  // Enumerate the deployed modules whose `environment` field == env.
  modulesForEnvironment(env: string): string[];
  // Re-apply a deployed module's current config to its VM/service.
  reconcileModule(module: string, apply: boolean): void;
}

// ── Reconcile plan ────────────────────────────────────────────────────
export type ActionKind =
  | "reconcile-network"
  | "reconcile-module"
  // Repair a bootstrap environment left with an empty ownerOrg. The
  // environment bootstrap necessarily runs before any organization can
  // exist, so it writes ownerOrg:"" and the schema rejects the result;
  // reconcile is the verb that can close the gap once an org exists.
  | "backfill-owner-org";

// How much of the system an action actually touches (#461). "environment" =
// scoped to the environment being reconciled; "system-wide" = converges the
// whole platform and merely includes this environment. The plan summary prints
// it so an operator never reads a system-wide action as a narrow one.
export type ActionScope = "system-wide" | "environment";

export interface Action {
  kind: ActionKind;
  scope: ActionScope;
  // Human-readable target description for the plan summary.
  target: string;
  // Machine-readable payload for actions that carry one (backfill-owner-org:
  // the org to adopt). Kept separate from `target` so apply never has to parse
  // prose back out of a display string.
  value?: string;
}

export interface Plan {
  actions: Action[];
  warnings: string[];
  // Operator prose that is neither an action nor a fault: what a planned action
  // really covers, why one was skipped. Printed plain, not as a yellow warning.
  notes: string[];
}

// One planned target that ran and failed. Collected rather than thrown so a
// single bad module no longer strands every module planned after it (#454).
export interface ApplyFailure {
  // The module name (or action target) that failed.
  target: string;
  // The child process's error, as reported by the client.
  error: string;
}

export interface ApplyResult {
  // Targets successfully reconciled.
  applied: number;
  // Targets that ran and failed, in plan order. Empty ⇒ full convergence.
  failures: ApplyFailure[];
}
