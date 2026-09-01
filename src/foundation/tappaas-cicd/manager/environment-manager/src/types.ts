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
  // The `type` of an existing zone (Service / Client / IoT / ...), or undefined
  // when the zone does not exist. ADR-014 D1 needs it to tell "the zone is
  // missing, materialize it" from "the environment points at a client/IoT zone,
  // which is a configuration mistake".
  zoneType(zone: string): string | undefined;
  // Author a Service zone (ADR-014 D1). Idempotent: a zone that already exists
  // is left untouched. environment-manager NEVER writes zones.json itself — this
  // shells out to `network-manager add <Z> --archetype service`, keeping
  // network-manager the sole writer (the ownership boundary ADR-014 restates).
  createServiceZone(zone: string): void;
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

// ── DnsTlsClient — the wildcard DNS + cert-refid runtime-state boundary ─
// ADR-007c v1.4: for a `dnsMode: wildcard` environment two pieces of runtime
// state are reconciler-populated, NOT authored config (#537):
//   1. the split-horizon wildcard `*.<primary>` Unbound override, pointed at the
//      environment's own service-zone gateway (ADR-005 §6, #504);
//   2. `config/cert-refids.json[<env>]` — the OPNsense Trust refid of the issued
//      `*.<primary>` cert, read back by the proxy install to bind Caddy's
//      CustomCertificate.
// Until #537 these were written ONLY by the manual scripts/acme-setup.sh, so an
// environment created after site bootstrap never got them. This boundary lets
// the reconcile engine materialize both. Reads are cheap enough for one
// environment (they mirror what acme-setup already does); tests inject a fake.
export interface WildcardDnsState {
  // The IP the wildcard SHOULD resolve to: the environment's service-zone
  // gateway (<subnet>.1), falling back to the dmz gateway. undefined ⇒ no subnet
  // for the zone in zones.json, so no gateway could be derived.
  gatewayIp?: string;
  // The zone the gateway was derived from (the env's own zone, or "dmz"). Used
  // only for the human description on the Unbound override.
  gatewayZone?: string;
  // What the `*` override currently resolves to in Unbound, or undefined when no
  // wildcard override exists for this domain yet.
  currentTarget?: string;
  // Per-service host overrides under this domain (host names, excluding `*`).
  // A wildcard installs a `redirect` local-zone that permits local-data only at
  // the apex, so these collide and are FATAL to Unbound (#474) — they must be
  // pruned when the wildcard is (re)registered.
  collidingHosts: string[];
}

export interface DnsTlsClient {
  // ── DNS (Unbound split-horizon wildcard) ──
  // Inspect the current wildcard/collision state for <domain> given the env's
  // service <zone> (used to derive the desired gateway target).
  wildcardDnsState(domain: string, zone: string): WildcardDnsState;
  // Converge the wildcard: prune any colliding per-service overrides, then
  // add/update `*.<domain>` → <gatewayIp> (idempotent). <zone> and <envName>
  // feed the override description only.
  registerWildcard(domain: string, gatewayIp: string, zone: string, envName: string): void;

  // ── TLS (cert refid runtime state) ──
  // The OPNsense Trust refid of an already-issued `*.<domain>` cert, or undefined
  // when no cert is issued yet (queried non-interactively via `acme-manager
  // status` — no DNS-API credentials needed).
  issuedCertRefid(domain: string): string | undefined;
  // The refid currently recorded in cert-refids.json for this environment, or
  // undefined when the file/key is absent.
  recordedCertRefid(envName: string): string | undefined;
  // Persist a refid into cert-refids.json[<envName>] (merge; create if absent).
  writeCertRefid(envName: string, refid: string): void;
  // Whether ACME DNS-API credentials are on disk (~/.acme-dns-credentials.txt),
  // which is what lets acme-setup.sh run non-interactively.
  acmeCredsAvailable(): boolean;
  // Issue the wildcard cert for this environment via acme-setup.sh (needs creds),
  // returning the resulting Trust refid. acme-setup.sh also (idempotently)
  // registers the wildcard DNS and writes cert-refids.json itself. Throws on
  // failure.
  issueWildcardCert(envName: string): string;
}

// ── ModuleClient — the module-manager boundary (--deep cascade) ───────
// `environment reconcile --deep` additionally re-applies every module that was
// deployed into this environment (module reconcile, the leaf re-apply).
export interface ModuleClient {
  // Enumerate the deployed modules whose `environment` field == env.
  modulesForEnvironment(env: string): string[];
  // Whether a module of this name is deployed at all (its <config>/<name>.json
  // exists), regardless of which environment it declares. Used to reconcile the
  // mgmt-zone identity module on a default-environment domain change (#474).
  moduleDeployed(module: string): boolean;
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
  | "backfill-owner-org"
  // ADR-014 D1: materialize the Service zone an environment names but that does
  // not yet exist in zones.json. Previously reconcile only WARNED about this,
  // leaving an environment permanently unable to converge.
  | "create-service-zone"
  // #537: register/converge the split-horizon `*.<domain>` Unbound override for
  // a wildcard-mode environment, pointed at its service-zone gateway.
  | "register-wildcard-dns"
  // #537: record an already-issued `*.<domain>` cert's OPNsense Trust refid into
  // cert-refids.json[<env>] (runtime state — ADR-007c v1.4).
  | "record-cert-refid"
  // #537: issue the `*.<domain>` wildcard cert via acme-setup.sh when none exists
  // yet and ACME DNS-API credentials are on disk, then record its refid.
  | "issue-wildcard-cert";

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
  // the org to adopt; register-wildcard-dns: the gateway IP; record-cert-refid:
  // the refid). Kept separate from `target` so apply never has to parse prose
  // back out of a display string.
  value?: string;
  // #537 DNS/TLS actions carry the domain the action operates on (the env's
  // domains.primary), so apply never re-parses it from `target`.
  domain?: string;
  // #537 register-wildcard-dns: the zone the gateway was derived from, for the
  // Unbound override description only.
  zone?: string;
}

export interface Plan {
  actions: Action[];
  warnings: string[];
  // Operator prose that is neither an action nor a fault: what a planned action
  // really covers, why one was skipped. Printed plain, not as a yellow warning.
  notes: string[];
  // HARD faults in the plan itself (ADR-014 D1): a configuration mistake that
  // reconcile must not paper over, e.g. an environment whose network.zone names
  // a Client/IoT zone. A plan with errors is reported and REFUSED — unlike a
  // warning, which reconcile proceeds through. Absent on plans built before
  // D1 introduced the concept, so treat undefined as empty.
  errors?: string[];
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
