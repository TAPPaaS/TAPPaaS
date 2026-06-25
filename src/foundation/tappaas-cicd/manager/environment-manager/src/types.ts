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

// ── NetworkClient — the network-manager boundary (shallow reconcile) ──
// `environment reconcile` converges the environment's associated zone by
// shelling out to network-manager. The engine depends only on this interface;
// tests inject a fake, production uses CliNetworkClient (spawnSync).
export interface NetworkClient {
  // Whether a zone with this key exists in zones.json (network-manager zone exists).
  zoneExists(zone: string): boolean;
  // Converge the network planes. apply=false ⇒ dry-run/preview (the default).
  // network-manager reconciles ALL zones at once (no per-zone reconcile today);
  // the environment's zone is converged as part of that pass.
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
export type ActionKind = "reconcile-network" | "reconcile-module";

export interface Action {
  kind: ActionKind;
  // Human-readable target description for the plan summary.
  target: string;
}

export interface Plan {
  actions: Action[];
  warnings: string[];
}
