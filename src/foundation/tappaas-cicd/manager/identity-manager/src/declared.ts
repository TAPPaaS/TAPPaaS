// declared.ts — the groups and users something other than config/identities
// declares.
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
//
// Users likewise: Authentik's bootstrap creates `akadmin` (the break-glass
// login) and a service account per outpost, `ak-outpost-<hex>`. They come with
// the identity module, so its bootstrap declares them; the user verbs list them
// with that origin and refuse to edit them.

import { discoverModules } from "../../../lib/ts/src/module-discovery";

// Authentik's own groups (its bootstrap creates them).
export const AUTHENTIK_BUILTIN_GROUPS = ["authentik Admins", "authentik Read-only", "authentik Agent-Users"];

// Authentik's own users: akadmin, and an outpost's service account.
export const AUTHENTIK_BUILTIN_USERS = ["akadmin"];
const OUTPOST_USER = /^ak-outpost-[0-9a-f]+$/;
export const isAuthentikBuiltinUser = (name: string): boolean => AUTHENTIK_BUILTIN_USERS.includes(name) || OUTPOST_USER.test(name);

export interface DeclaredGroup {
  name: string;
  origin: string; // "module forgejo", "Authentik built-in"
  module?: string; // the base module name, for a module's group
  declaredBy: { file: string; key: string }; // relative to config/
}

const BOOTSTRAP = { origin: "Authentik built-in", declaredBy: { file: "identity.json", key: "bootstrap" } };
const hasIdentity = (modules: { name: string }[]): boolean => modules.some((m) => m.name === "identity");

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
  if (hasIdentity(modules)) {
    for (const name of AUTHENTIK_BUILTIN_GROUPS) {
      if (!out.has(name)) out.set(name, { name, ...BOOTSTRAP, declaredBy: { ...BOOTSTRAP.declaredBy } });
    }
  }
  return out;
}

/** The user the identity module's bootstrap declares by this name, if any:
 *  akadmin or an outpost's ak-outpost-<hex>, when the identity module is
 *  installed. A user the model also has a file for is the model's. */
export function declaredUser(configRoot: string, name: string): DeclaredGroup | undefined {
  if (!isAuthentikBuiltinUser(name) || !hasIdentity(discoverModules(configRoot))) return undefined;
  return { name, ...BOOTSTRAP, declaredBy: { ...BOOTSTRAP.declaredBy } };
}

/** The users the identity module declares, by name: akadmin, and the outpost
 *  accounts among `live` (Authentik's user names; their hex is Authentik's,
 *  so only a read of it names them). */
export function declaredUsers(configRoot: string, live: string[] = []): Map<string, DeclaredGroup> {
  const out = new Map<string, DeclaredGroup>();
  if (!hasIdentity(discoverModules(configRoot))) return out;
  for (const name of [...AUTHENTIK_BUILTIN_USERS, ...live.filter((n) => OUTPOST_USER.test(n))]) {
    out.set(name, { name, ...BOOTSTRAP, declaredBy: { ...BOOTSTRAP.declaredBy } });
  }
  return out;
}
