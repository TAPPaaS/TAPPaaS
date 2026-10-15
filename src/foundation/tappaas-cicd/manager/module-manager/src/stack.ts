// stack.ts — install a stack: its modules, in dependsOn order (#763).
//
// A stack is the first and simplest form of a solution (#421): every catalogue
// entry whose `stack` names it. The order is the one the stack's generated
// INSTALL.md shows (gen-stack-readme.py), so the document and the verb cannot
// disagree: dependsOn and integratesWith inside the stack, ties by name.
//
// Pure: the caller reads the catalogue, the module JSONs and the config dir and
// hands the facts in; everything here is decided from them.

export const NOT_INSTALLABLE = new Set(["foundation", "template", "test"]);

export interface StackModule {
  name: string;
  dependsOn: string[];
  integratesWith: string[];
  // The module's INSTALL.md has steps for the operator after the install.
  handSteps: boolean;
  // Its declared VMID — the first of its block of ten (catalogue convention).
  vmid?: number;
}

export interface StackFacts {
  // The instance name `add` would create, for the environment asked for.
  instanceOf: (module: string) => string;
  // Is a config with this instance name deployed?
  installed: (instance: string) => boolean;
  // Is the provider of an outside dependency deployed, for the environment?
  providerInstalled: (provider: string) => boolean;
  // Is a VMID taken — by a deployed config or a guest on the cluster?
  vmidUsed: (vmid: number) => boolean;
}

export type StackStep =
  // vmid: the VMID to install with when it is not the declared one (another
  // instance of the module holds that): the first free one in its block.
  | { module: string; action: "install"; handSteps: boolean; vmid?: number }
  | { module: string; action: "skip"; instance: string };

export interface StackPlan {
  steps: StackStep[];
  // Outside dependencies that are not installed: refused before anything runs.
  missing: { module: string; dependency: string }[];
  // Modules in a dependsOn cycle: refused, never guessed at.
  cycle: string[];
  // Modules whose whole block of ten VMIDs is taken.
  noVmid: string[];
}

const provider = (coordinate: string): string => coordinate.split(":")[0];

// Topological order inside the stack; ties by name. A cycle is returned apart.
export function installOrder(mods: StackModule[]): { order: string[]; cycle: string[] } {
  const names = new Set(mods.map((m) => m.name));
  const deps = new Map<string, Set<string>>();
  for (const m of mods) {
    const inside = [...m.dependsOn, ...m.integratesWith]
      .map(provider)
      .filter((p) => names.has(p) && p !== m.name);
    deps.set(m.name, new Set(inside));
  }
  const order: string[] = [];
  const done = new Set<string>();
  while (done.size < names.size) {
    const ready = [...names]
      .filter((n) => !done.has(n) && [...(deps.get(n) ?? [])].every((d) => done.has(d)))
      .sort();
    if (ready.length === 0) {
      return { order, cycle: [...names].filter((n) => !done.has(n)).sort() };
    }
    for (const n of ready) {
      order.push(n);
      done.add(n);
    }
  }
  return { order, cycle: [] };
}

export function planStack(mods: StackModule[], facts: StackFacts): StackPlan {
  const { order, cycle } = installOrder(mods);
  const names = new Set(mods.map((m) => m.name));
  const by = new Map(mods.map((m) => [m.name, m]));
  const missing: StackPlan["missing"] = [];
  for (const m of mods) {
    for (const d of m.dependsOn) {
      const p = provider(d);
      if (names.has(p) || p === m.name) continue;
      if (!facts.providerInstalled(p)) missing.push({ module: m.name, dependency: d });
    }
  }
  const noVmid: string[] = [];
  const claimed = new Set<number>();
  const steps: StackStep[] = order.map((name) => {
    const instance = facts.instanceOf(name);
    if (facts.installed(instance)) return { module: name, action: "skip", instance };
    const m = by.get(name);
    const step: Extract<StackStep, { action: "install" }> = { module: name, action: "install", handSteps: m?.handSteps ?? false };
    if (m?.vmid !== undefined) {
      const free = (v: number) => !facts.vmidUsed(v) && !claimed.has(v);
      if (!free(m.vmid)) {
        const alt = Array.from({ length: 9 }, (_, i) => m.vmid! + 1 + i).find(free);
        if (alt === undefined) noVmid.push(name);
        else { step.vmid = alt; claimed.add(alt); }
      } else {
        claimed.add(m.vmid);
      }
    }
    return step;
  });
  return { steps, missing, cycle, noVmid };
}

// An INSTALL.md that leaves work for the operator after the install.
export function hasHandSteps(installMd: string): boolean {
  return /^##\s+(Post-install|First-Time Setup|Configure)\b/im.test(installMd);
}
