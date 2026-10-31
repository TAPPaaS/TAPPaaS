// declared.ts — the groups something other than config/identities declares.
//
// Groups come from three places. The model's are the files under
// config/identities/groups. A module installed with an identity integration
// that sets identity.providesAdminRole gets a `<module>-admins` group from the
// identity service (services/identity/install-service.sh: the module's name
// without its -<environment> suffix). And Authentik ships groups of its own,
// which come with the identity module's bootstrap.
//
// The last two have no config file, yet they are desired: what declares them
// is a module's `identity` block, or the identity module itself. The report
// gives them that as their `desired`, the group verbs list them beside the
// model's and refuse to edit them.

import { discoverModules } from "../../../lib/ts/src/module-discovery";

// Authentik's own groups (its bootstrap creates them).
export const AUTHENTIK_BUILTIN_GROUPS = ["authentik Admins", "authentik Read-only", "authentik Agent-Users"];

export interface DeclaredGroup {
  name: string;
  origin: string; // "module forgejo", "Authentik built-in"
  module?: string; // the base module name, for a module's group
  declaredBy: { file: string; key: string }; // relative to config/
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => v !== null && typeof v === "object" && !Array.isArray(v);

// A module's identity block: top-level, or in a legacy config.<service> block
// (module-manager's normalizeModuleConfig flattens those the same way).
function identityBlock(raw: Obj): Obj | null {
  if (isObj(raw.identity)) return raw.identity;
  if (isObj(raw.config)) for (const b of Object.values(raw.config)) if (isObj(b) && isObj(b.identity)) return b.identity;
  return null;
}

/** The groups the installed modules and Authentik declare, by name, read from
 *  config/ (the root, not config/identities). A group the model also has a
 *  file for is the model's, so callers drop those. */
export function declaredGroups(configRoot: string): Map<string, DeclaredGroup> {
  const out = new Map<string, DeclaredGroup>();
  const modules = discoverModules(configRoot);
  for (const m of modules) {
    if (identityBlock(m.raw)?.providesAdminRole !== true) continue;
    const env = typeof m.raw.environment === "string" ? m.raw.environment : "";
    const base = env && m.name.endsWith(`-${env}`) ? m.name.slice(0, -(env.length + 1)) : m.name;
    const name = `${base}-admins`;
    const had = out.get(name);
    // An environment's install shares the base's group: the base's file names it.
    if (had && had.declaredBy.file === `${base}.json`) continue;
    out.set(name, { name, origin: `module ${base}`, module: base, declaredBy: { file: `${m.name}.json`, key: "identity" } });
  }
  if (modules.some((m) => m.name === "identity")) {
    for (const name of AUTHENTIK_BUILTIN_GROUPS) {
      if (!out.has(name)) out.set(name, { name, origin: "Authentik built-in", declaredBy: { file: "identity.json", key: "bootstrap" } });
    }
  }
  return out;
}
