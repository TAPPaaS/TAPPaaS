// fake-clients.ts — in-memory NetworkClient + ModuleClient for offline reconcile
// unit tests. Records calls so tests can assert exactly what the cascade did.

import { ModuleClient, NetworkClient } from "../../src/types";

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
