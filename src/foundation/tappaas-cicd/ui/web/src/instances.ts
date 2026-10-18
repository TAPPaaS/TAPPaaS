// instances.ts — a module and its instances (ADR-026): the Installed tab shows
// one row per module with every environment it is in, and the repository tabs
// install a module again in another environment. Pure, so the unit tests
// (test/unit/instances.test.ts) run it without a browser.

// What the two need of a deployed instance (ModuleSummary has it).
export interface InstanceLike {
  name: string;
  environment: string | null;
  stack: string | null;
}

export interface ModuleGroup<T extends InstanceLike> {
  module: string;
  stack: string | null;
  instances: T[]; // the one named like the module first, then by environment
}

// The catalogues say which module an instance is (deconz-test is deconz); an
// instance no catalogue claims is a module of its own name.
export function instanceOwners(catalogs: { modules: { name: string; instances: string[] }[] }[]): Map<string, string> {
  const owner = new Map<string, string>();
  for (const c of catalogs) for (const m of c.modules) for (const i of m.instances) owner.set(i, m.name);
  return owner;
}

export function groupInstances<T extends InstanceLike>(list: T[], owner: Map<string, string>): ModuleGroup<T>[] {
  const groups = new Map<string, T[]>();
  for (const i of list) {
    const m = owner.get(i.name) ?? i.name;
    groups.set(m, [...(groups.get(m) ?? []), i]);
  }
  return [...groups.entries()].map(([module, instances]) => {
    const sorted = [...instances].sort((a, b) => Number(b.name === module) - Number(a.name === module) || (a.environment ?? "").localeCompare(b.environment ?? "") || a.name.localeCompare(b.name));
    return { module, stack: sorted[0].stack, instances: sorted };
  });
}

// The environment column: each environment once, and after it the names of its
// instances that are not the module's ("rossen, test (vaultwarden-test)";
// "mgmt (tappaas1, tappaas2, tappaas3)" for pvehost on three nodes).
export function environmentsOf<T extends InstanceLike>(g: ModuleGroup<T>): { environment: string; instances: string[] }[] {
  const out: { environment: string; instances: string[] }[] = [];
  for (const i of g.instances) {
    const env = i.environment ?? "—";
    let row = out.find((r) => r.environment === env);
    if (!row) out.push((row = { environment: env, instances: [] }));
    if (i.name !== g.module) row.instances.push(i.name);
  }
  return out;
}

// Where Install may put a module: a site-scoped one (the foundation stack) in
// mgmt only, any other in every environment but mgmt. The default is the first
// one it is not in yet, the site's default environment first.
export function installEnvironments(stack: string | null, environments: string[], installedIn: string[], defaultEnv: string | null): { choices: string[]; initial: string | null } {
  if (stack === "foundation") return { choices: ["mgmt"], initial: "mgmt" };
  const choices = environments.filter((e) => e !== "mgmt");
  const free = choices.filter((e) => !installedIn.includes(e));
  const initial = defaultEnv && free.includes(defaultEnv) ? defaultEnv : free[0] ?? choices[0] ?? null;
  return { choices, initial };
}

// The instance `module-manager add <m> --environment <env>` makes: the module's
// own name in mgmt and in the default environment, else <module>-<env>.
export function defaultInstanceName(module: string, env: string, defaultEnv: string | null): string {
  return env === "mgmt" || env === defaultEnv ? module : `${module}-${env}`;
}
