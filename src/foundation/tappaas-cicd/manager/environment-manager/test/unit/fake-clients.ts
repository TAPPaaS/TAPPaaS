// fake-clients.ts — in-memory NetworkClient + ModuleClient for offline reconcile
// unit tests. Records calls so tests can assert exactly what the cascade did.

import { DnsTlsClient, ModuleClient, NetworkClient, WildcardDnsState } from "../../src/types";

export class FakeNetworkClient implements NetworkClient {
  zones = new Set<string>();
  // zone name → type, for the ADR-014 D1 "is it a Service zone?" check.
  types = new Map<string, string>();
  log: string[] = [];

  seedZone(name: string, type = "Service"): void {
    this.zones.add(name);
    this.types.set(name, type);
  }

  zoneExists(zone: string): boolean {
    return this.zones.has(zone);
  }
  zoneType(zone: string): string | undefined {
    return this.zones.has(zone) ? this.types.get(zone) : undefined;
  }
  createServiceZone(zone: string): void {
    this.log.push(`create-service-zone ${zone}`);
    this.zones.add(zone);
    this.types.set(zone, "Service");
  }
  reconcileNetwork(apply: boolean): void {
    this.log.push(`reconcile-network ${apply ? "apply" : "preview"}`);
  }
}

export class FakeModuleClient implements ModuleClient {
  // env name → deployed module names
  byEnv = new Map<string, string[]>();
  // all deployed module names (regardless of environment) — backs moduleDeployed.
  deployed = new Set<string>();
  log: string[] = [];
  // module name → error thrown by reconcileModule (#454 partial-failure tests).
  failures = new Map<string, Error>();

  seedModule(env: string, module: string): void {
    const arr = this.byEnv.get(env) ?? [];
    arr.push(module);
    this.byEnv.set(env, arr);
    this.deployed.add(module);
  }

  // Mark a module deployed without tying it to a queried environment (e.g. the
  // mgmt-zone identity module, environment: null) — #474.
  seedDeployed(module: string): void {
    this.deployed.add(module);
  }

  // Make reconcileModule(module) throw — models a module-manager child that ran
  // and exited non-zero.
  seedFailure(module: string, err: Error): void {
    this.failures.set(module, err);
  }

  modulesForEnvironment(env: string): string[] {
    return [...(this.byEnv.get(env) ?? [])].sort();
  }
  moduleDeployed(module: string): boolean {
    return this.deployed.has(module);
  }
  reconcileModule(module: string, apply: boolean): void {
    this.log.push(`reconcile-module ${module} ${apply ? "apply" : "preview"}`);
    const err = this.failures.get(module);
    if (err) throw err;
  }
}

// In-memory DnsTlsClient for offline #537 reconcile tests. Seed the current
// firewall/config state, then assert exactly what the cascade did via `log`.
export class FakeDnsTlsClient implements DnsTlsClient {
  // zone name → gateway IP (what zoneGatewayIp would derive from zones.json).
  gateways = new Map<string, string>();
  // domain → current `*` override target (undefined ⇒ no wildcard override yet).
  wildcardTargets = new Map<string, string>();
  // domain → per-service host names that collide with a wildcard redirect zone.
  collisions = new Map<string, string[]>();
  // domain → refid of an already-issued cert (absent ⇒ no cert issued).
  issuedRefids = new Map<string, string>();
  // env name → recorded refid in cert-refids.json.
  refids = new Map<string, string>();
  // Whether ~/.acme-dns-credentials.txt is present.
  credsPresent = false;
  // Refid acme-setup.sh yields on issuance (also what it records).
  issueYields = "REFID-ISSUED";
  // Make issueWildcardCert throw (models an acme-setup.sh failure).
  issueError?: Error;
  log: string[] = [];

  seedGateway(zone: string, ip: string): void {
    this.gateways.set(zone, ip);
  }
  seedWildcard(domain: string, target: string): void {
    this.wildcardTargets.set(domain, target);
  }
  private unpublished = new Set<string>();
  private wildcardRowCounts = new Map<string, number>();

  seedCollisions(domain: string, hosts: string[]): void {
    this.collisions.set(domain, hosts);
  }
  seedIssuedCert(domain: string, refid: string): void {
    this.issuedRefids.set(domain, refid);
  }
  seedRecordedRefid(env: string, refid: string): void {
    this.refids.set(env, refid);
  }

  // ADR-021 D5: the answer is the dmz gateway, whatever zone is passed —
  // the fake mirrors the real resolver rather than the retired per-env rule.
  seedUnpublished(domain: string): void {
    this.unpublished.add(domain);
  }
  // #594: seed N duplicate `*` rows for a domain.
  seedWildcardRows(domain: string, target: string, rows: number): void {
    this.wildcardTargets.set(domain, target);
    this.wildcardRowCounts.set(domain, rows);
  }

  wildcardDnsState(domain: string, _zone: string): WildcardDnsState {
    if (this.unpublished.has(domain)) {
      return { unpublished: true, rowCount: 0, collidingHosts: [] };
    }
    const gatewayIp = this.gateways.get("dmz");
    const current = this.wildcardTargets.get(domain);
    return {
      gatewayIp,
      gatewayZone: gatewayIp ? "dmz" : undefined,
      currentTarget: current,
      rowCount: this.wildcardRowCounts.get(domain) ?? (current ? 1 : 0),
      collidingHosts: [...(this.collisions.get(domain) ?? [])],
    };
  }
  registerWildcard(domain: string, gatewayIp: string, zone: string, envName: string): void {
    const c = this.collisions.get(domain) ?? [];
    this.log.push(`register-wildcard ${domain} -> ${gatewayIp} (${zone}, ${envName}) prune=[${c.join(",")}]`);
    this.collisions.delete(domain);
    this.wildcardTargets.set(domain, gatewayIp);
    // delete-all-rewrite-one converges on exactly one row (#594).
    this.wildcardRowCounts.set(domain, 1);
  }
  issuedCertRefid(domain: string): string | undefined {
    return this.issuedRefids.get(domain);
  }
  recordedCertRefid(envName: string): string | undefined {
    return this.refids.get(envName);
  }
  writeCertRefid(envName: string, refid: string): void {
    this.log.push(`write-cert-refid ${envName}=${refid}`);
    this.refids.set(envName, refid);
  }
  acmeCredsAvailable(): boolean {
    return this.credsPresent;
  }
  issueWildcardCert(envName: string): string {
    this.log.push(`issue-wildcard-cert ${envName}`);
    if (this.issueError) throw this.issueError;
    this.refids.set(envName, this.issueYields);
    return this.issueYields;
  }
}
