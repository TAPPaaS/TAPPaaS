// config.ts — load the deployed module domain from config/ (the TARGET system
// directory, NOT the repo), plus the environment/effective-name resolution
// helpers ported from install-module.sh / update-module.sh.
//
// "config/" means the target system (~tappaas/config), per the ADR-007
// convention. Default path resolves from TAPPAAS_CONFIG (or /home/tappaas/config);
// tests pass an explicit dir (a fixture tree).

import { existsSync, readFileSync, readdirSync } from "fs";
import { basename, join } from "path";
import { ModuleConfig } from "./types";

export function defaultConfigDir(): string {
  return process.env.TAPPAAS_CONFIG ?? process.env.CONFIG_DIR ?? "/home/tappaas/config";
}

// Non-module config files that also live in config/ and must NOT be enumerated
// as modules (network/site/zone state, the schema copy, switch desired/actual).
// NOTE: `templates` is NOT here — it IS a module (a provider-only module:
// provides ["nixos","debian"], no vmid/vmname). Provider-only modules are kept
// by the heuristic via their `provides`/`location`.
const NON_MODULE_BASENAMES = new Set<string>([
  "zones",
  "site",
  "module-fields",
  "cert-refids",
  "switch-configuration-actual",
  "switch-configuration-desired",
]);

function asString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}
function asStringArray(v: unknown): string[] | undefined {
  if (!Array.isArray(v)) return undefined;
  return v.filter((x): x is string => typeof x === "string");
}
function asNumberOrNull(v: unknown): number | null {
  return typeof v === "number" ? v : null;
}

// Module selection (ADR-007 #3). The AUTHORITATIVE marker is `"kind":"module"`,
// written onto every deployed config by install-module.sh. For configs not yet
// re-installed (pre-tag), fall back to a heuristic: a module config carries at
// least one of the module-shaped fields (dependsOn / provides / location).
//
// NOTE: provider-only modules (e.g. `templates`: provides ["nixos","debian"])
// have NO vmid/vmname — so the heuristic must NOT require vmname, otherwise such
// modules would be dropped from `list`. We require a module-shaped field instead.
function isModuleConfig(raw: Record<string, unknown>): boolean {
  if (raw.kind === "module") return true;
  return (
    Array.isArray(raw.dependsOn) ||
    Array.isArray(raw.provides) ||
    typeof raw.location === "string"
  );
}

function toModuleConfig(name: string, raw: Record<string, unknown>): ModuleConfig {
  return {
    name,
    kind: asString(raw.kind),
    description: asString(raw.description),
    vmname: asString(raw.vmname),
    vmid: asNumberOrNull(raw.vmid),
    node: asString(raw.node) ?? null,
    zone0: asString(raw.zone0) ?? null,
    zone1: asString(raw.zone1) ?? null,
    tier: asString(raw.tier) ?? null,
    source: asString(raw.source) ?? null,
    status: asString(raw.status) ?? null,
    environment: asString(raw.environment) ?? null,
    location: asString(raw.location) ?? null,
    installTime: asString(raw.installTime) ?? null,
    updateTime: asString(raw.updateTime) ?? null,
    dependsOn: asStringArray(raw.dependsOn),
    provides: asStringArray(raw.provides),
    raw,
  };
}

// Load one deployed module config by (effective) name. Returns null if absent.
export function loadModule(configDir: string, name: string): ModuleConfig | null {
  const file = join(configDir, `${name}.json`);
  if (!existsSync(file)) return null;
  const raw = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
  return toModuleConfig(name, raw);
}

// Enumerate every deployed module config in configDir (sorted by name).
// Skips *.orig backups, the explicit non-module deny-list, and anything that is
// not a module (no kind=="module" tag and no module-shaped field).
export function listModules(configDir: string): ModuleConfig[] {
  if (!existsSync(configDir)) return [];
  const out: ModuleConfig[] = [];
  for (const f of readdirSync(configDir)) {
    if (!f.endsWith(".json")) continue;
    if (f.endsWith(".orig")) continue;
    const name = basename(f, ".json");
    if (NON_MODULE_BASENAMES.has(name)) continue;
    let raw: Record<string, unknown>;
    try {
      raw = JSON.parse(readFileSync(join(configDir, f), "utf8")) as Record<string, unknown>;
    } catch {
      continue; // not parseable as JSON → not a module config
    }
    if (!isModuleConfig(raw)) continue;
    out.push(toModuleConfig(name, raw));
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

// ── Environment / effective-name resolution (ported from install/update) ─
//
// The default environment is the single non-mgmt environment / site name <N>.
// resolve_default_environment() in install-module.sh: site.json '.name' wins;
// else the single non-mgmt environments/<env>.json basename.
export function resolveDefaultEnvironment(configDir: string): string {
  const siteFile = join(configDir, "site.json");
  if (existsSync(siteFile)) {
    try {
      const site = JSON.parse(readFileSync(siteFile, "utf8")) as Record<string, unknown>;
      const siteName = asString(site.name);
      if (siteName && siteName !== "mgmt") return siteName;
    } catch {
      // fall through to environments scan
    }
  }
  const envDir = join(configDir, "environments");
  if (existsSync(envDir)) {
    const envs: string[] = [];
    for (const f of readdirSync(envDir)) {
      if (!f.endsWith(".json")) continue;
      const base = basename(f, ".json");
      if (base === "mgmt") continue;
      envs.push(base);
    }
    if (envs.length === 1) return envs[0];
  }
  return "";
}

// Compute the installed (effective) module name from a base module +
// environment (ADR-007 P5). No suffix for an empty env, 'mgmt', or the default
// environment; otherwise <module>-<env>. Mirrors install/update/delete.
export function resolveEffectiveModuleName(
  configDir: string,
  module: string,
  environment: string | undefined,
): string {
  if (!environment) return module;
  if (environment === "mgmt") return module;
  const defaultEnv = resolveDefaultEnvironment(configDir);
  if (defaultEnv && environment === defaultEnv) return module;
  return `${module}-${environment}`;
}
