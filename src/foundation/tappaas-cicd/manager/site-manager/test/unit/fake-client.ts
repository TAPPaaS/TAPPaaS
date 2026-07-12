// fake-client.ts — in-memory SiteClient for offline reconcile unit tests.
//
// Records mutations so tests can assert exactly what the engine did, and so a
// second reconcile against the resulting state proves idempotency. Mirrors
// people-manager/test/unit/fake-client.ts.

import { SiteClient } from "../../src/types";

export class FakeSiteClient implements SiteClient {
  // Live state.
  clones = new Set<string>(); // repo paths that "exist on disk"
  branches = new Map<string, string>(); // path -> currently-checked-out branch
  validationErrors: string[] = []; // what validateSite() returns
  environments: string[] = []; // what listEnvironments() returns
  delegateRc = 0; // exit code returned by the .sh delegations

  log: string[] = [];

  // Seed a pre-existing clone (NOT via the recorded mutators).
  seedClone(path: string, branch: string): void {
    this.clones.add(path);
    this.branches.set(path, branch);
  }

  repoCloneExists(path: string): boolean {
    return this.clones.has(path);
  }
  cloneRepo(url: string, path: string, branch: string): void {
    this.log.push(`clone ${url} ${path} ${branch}`);
    this.clones.add(path);
    this.branches.set(path, branch);
  }
  currentBranch(path: string): string | null {
    return this.branches.get(path) ?? null;
  }
  checkoutRepo(path: string, branch: string): void {
    this.log.push(`checkout ${path} ${branch}`);
    this.branches.set(path, branch);
  }
  validateSite(_siteFile: string): string[] {
    return [...this.validationErrors];
  }
  // Live cluster node membership; null = unreachable. Defaults to the one
  // node every test fixture declares, so the node slice is a no-op unless a
  // test seeds drift. Registered nodes are recorded so a second reconcile
  // proves idempotency.
  liveNodes: string[] | null = ["tappaas1"];
  // Per-node discovered tank pools; missing key → null (discovery failed).
  // Default matches the fixture node so the node slice is a clean no-op.
  livePools = new Map<string, string[]>([["tappaas1", ["tanka1"]]]);
  registeredNodes: string[] = [];
  clusterNodes(_candidates: string[]): string[] | null {
    return this.liveNodes === null ? null : [...this.liveNodes];
  }
  nodeStoragePools(node: string): string[] | null {
    const p = this.livePools.get(node);
    return p === undefined ? null : [...p];
  }
  registerNode(_siteFile: string, name: string, pools: string[]): void {
    this.log.push(`register-node ${name} [${pools.join(",")}]`);
    this.registeredNodes.push(name);
  }
  setNodePools(_siteFile: string, name: string, pools: string[]): void {
    this.log.push(`set-node-pools ${name} [${pools.join(",")}]`);
  }
  cascade(manager: "people" | "network", apply: boolean): void {
    this.log.push(`cascade ${manager} ${apply ? "apply" : "preview"}`);
  }
  listEnvironments(): string[] {
    return [...this.environments];
  }
  cascadeEnvironment(env: string, apply: boolean): void {
    this.log.push(`cascade environment ${env} ${apply ? "apply" : "preview"}`);
  }
  createSite(args: string[]): number {
    this.log.push(`create-site ${args.join(" ")}`);
    return this.delegateRc;
  }
  repositoryAdd(args: string[]): number {
    this.log.push(`repository.sh add ${args.join(" ")}`);
    return this.delegateRc;
  }
  repositoryModify(args: string[]): number {
    this.log.push(`repository.sh modify ${args.join(" ")}`);
    return this.delegateRc;
  }
  repositoryRemove(name: string, force: boolean): number {
    this.log.push(`repository.sh remove ${name}${force ? " --force" : ""}`);
    return this.delegateRc;
  }
}
