// fake-clients.ts — in-memory NetworkClient + ModuleClient for offline reconcile
// unit tests. Records calls so tests can assert exactly what the cascade did.

import { ModuleClient, NetworkClient } from "../../src/types";

export class FakeNetworkClient implements NetworkClient {
  zones = new Set<string>();
  log: string[] = [];

  seedZone(name: string): void {
    this.zones.add(name);
  }

  zoneExists(zone: string): boolean {
    return this.zones.has(zone);
  }
  reconcileNetwork(apply: boolean): void {
    this.log.push(`reconcile-network ${apply ? "apply" : "preview"}`);
  }
}

export class FakeModuleClient implements ModuleClient {
  // env name → deployed module names
  byEnv = new Map<string, string[]>();
  log: string[] = [];

  seedModule(env: string, module: string): void {
    const arr = this.byEnv.get(env) ?? [];
    arr.push(module);
    this.byEnv.set(env, arr);
  }

  modulesForEnvironment(env: string): string[] {
    return [...(this.byEnv.get(env) ?? [])].sort();
  }
  reconcileModule(module: string, apply: boolean): void {
    this.log.push(`reconcile-module ${module} ${apply ? "apply" : "preview"}`);
  }
}
