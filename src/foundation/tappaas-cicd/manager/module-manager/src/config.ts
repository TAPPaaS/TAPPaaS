// config.ts — load the deployed module domain from config/ (the TARGET system
// directory, NOT the repo), plus the environment/effective-name resolution
// helpers ported from install-module.sh / update-module.sh.
//
// "config/" means the target system (~tappaas/config), per the ADR-007
// convention. Default path resolves from TAPPAAS_CONFIG (or /home/tappaas/config);
// tests pass an explicit dir (a fixture tree).

import { existsSync, readFileSync, readdirSync, statSync } from "fs";
import { basename, dirname, join } from "path";
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import { ModuleConfig, ModuleStatus } from "./types";

// Config-root resolution comes from the shared lib (TAPPAAS_CONFIG, then
// CONFIG_DIR, then /home/tappaas/config). Re-exported for main.ts/client.ts.
export { defaultConfigDir };

// Node hostnames from site.json (.hardware.nodes[].name) — the bash
// `get_all_node_hostnames` equivalent (ported from health-manager). Authoritative
// source for the cluster node list; an empty array means "fall back to the
// tappaas1..9 scan" (the CliModuleClient does that for its live cluster query).
export function siteNodeHostnames(configDir: string): string[] {
  const siteFile = join(configDir, "site.json");
  if (!existsSync(siteFile)) return [];
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(readFileSync(siteFile, "utf8")) as Record<string, unknown>;
  } catch {
    return [];
  }
  const hw = raw.hardware;
  if (!hw || typeof hw !== "object") return [];
  const nodes = (hw as Record<string, unknown>).nodes;
  if (!Array.isArray(nodes)) return [];
  const out: string[] = [];
  for (const n of nodes) {
    if (n && typeof n === "object") {
      const name = (n as Record<string, unknown>).name;
      if (typeof name === "string" && name) out.push(name);
    }
  }
  return out;
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
    // Kept as-loaded (round-trips any value); validate.ts warns on one outside
    // MODULE_STATUS_VALUES rather than dropping it here.
    status: (asString(raw.status) ?? null) as ModuleStatus | null,
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

// ── Pattern-A → flat normalization (#161/#207) ─────────────────────────
// Port of the bash `normalize_module_config` (common-install-routines.sh): a
// module JSON may group per-service configuration under a `config` block keyed
// by the "<module>:<service>" dependency coordinate. Flatten every config block
// up to the top level (jq `. * $s.value` = recursive object merge, later blocks
// win) and drop `config`. Already-flat ("Pattern C") docs pass through
// unchanged. Used by the native reconcile + inspect (Phase 7.3 ports).
function deepMergeObjects(
  a: Record<string, unknown>,
  b: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = { ...a };
  for (const [k, v] of Object.entries(b)) {
    const cur = out[k];
    if (
      cur !== null && typeof cur === "object" && !Array.isArray(cur) &&
      v !== null && typeof v === "object" && !Array.isArray(v)
    ) {
      out[k] = deepMergeObjects(cur as Record<string, unknown>, v as Record<string, unknown>);
    } else {
      out[k] = v;
    }
  }
  return out;
}

export function normalizeModuleConfig(raw: Record<string, unknown>): Record<string, unknown> {
  const cfg = raw.config;
  if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) return raw;
  let out: Record<string, unknown> = { ...raw };
  for (const block of Object.values(cfg as Record<string, unknown>)) {
    // (jq would ERROR on a non-object block; we skip it — forgiving delta.)
    if (block !== null && typeof block === "object" && !Array.isArray(block)) {
      out = deepMergeObjects(out, block as Record<string, unknown>);
    }
  }
  delete out.config;
  return out;
}

// ── Module source-directory resolution (bash get_module_dir port) ──────
// Reads .location from the deployed config. ADR-007 P8: a not-yet-migrated
// firewall.json may record .location=.../firewall while the source dir was
// renamed to .../network — follow the rename when the recorded dir is gone.
// Returns null when the config or its .location is absent (bash `return 1`).
function isDirectory(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// The three ways resolution fails used to collapse into a single `null`, so no
// caller could tell "this module has no directory" from "its directory is
// gone" (#460). ModuleDirResult keeps them apart; `dir` carries the RECORDED
// path on "missing-dir" so callers can name it.
export type ModuleDirResult =
  | { kind: "found"; dir: string }
  | { kind: "not-installed" }
  | { kind: "no-location" }
  | { kind: "missing-dir"; dir: string };

export function getModuleDirResult(configDir: string, module: string): ModuleDirResult {
  const file = join(configDir, `${module}.json`);
  if (!existsSync(file)) return { kind: "not-installed" };
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
  } catch {
    return { kind: "not-installed" };
  }
  let location = typeof raw.location === "string" ? raw.location : "";
  if (!location) return { kind: "no-location" };
  if (!isDirectory(location) && location.endsWith("/firewall")) {
    const renamed = location.slice(0, -"/firewall".length) + "/network";
    if (isDirectory(renamed)) location = renamed;
  }
  return isDirectory(location) ? { kind: "found", dir: location } : { kind: "missing-dir", dir: location };
}

// Legacy signature, unchanged in behaviour: the recorded .location is returned
// whether or not the directory still exists (bash `get_module_dir` likewise
// still ECHOES the path when it exits 2). Callers that need to tell the two
// apart use getModuleDirResult; the rest keep working untouched.
export function getModuleDir(configDir: string, module: string): string | null {
  const r = getModuleDirResult(configDir, module);
  return r.kind === "found" || r.kind === "missing-dir" ? r.dir : null;
}

// ── Provider-name resolution (bash resolve_provider_module port). Prefer the
// provider serving the CONSUMING module's environment; else the named
// provider's own deployed config; else its legacy firewall<->network
// counterpart if THAT is the one actually deployed; else echo the name back
// (the caller handles the miss).
//
// #438: this was ported in the "no-variant form" — it took no environment at
// all, so `module-manager reconcile` re-applied every consumer against the
// SHARED provider even when a dedicated one served its environment. Keep the
// signature aligned with the bash: environment last, optional, file-existence
// guarded (so mgmt / the default environment, whose configs are unsuffixed by
// design, correctly fall through to the base name).
export function resolveProviderModule(
  configDir: string,
  provider: string,
  environment = "",
): string {
  if (environment && existsSync(join(configDir, `${provider}-${environment}.json`))) {
    return `${provider}-${environment}`;
  }
  if (existsSync(join(configDir, `${provider}.json`))) return provider;
  const alias = provider === "network" ? "firewall" : provider === "firewall" ? "network" : "";
  if (alias && existsSync(join(configDir, `${alias}.json`))) return alias;
  return provider;
}

// ── Module-resolution classification (#460) ───────────────────────────
// A module's source directory is found by one of three INDEPENDENT paths, and
// only the first was ever described in site-fields.json:
//
//   A  the repository module catalogs   (resolve-module.sh, needs registration)
//   B  the deployed config's .location  (install-module.sh records the CWD it
//      installed from — works with no repository registered at all)
//   C  neither — nothing can locate it, which today surfaces only when some
//      operation finally needs the directory
//
// This is the reporting side: `module-manager list --resolution` names each
// module's path so C is visible up front instead of at first use.

export interface SiteRepository {
  name: string;
  path: string;
  catalog: string;
  managed: string;
}

// site.json .repositories[], normalized. Entries with no .path are kept: they
// are a misconfiguration worth reporting, not worth hiding.
export function siteRepositories(configDir: string): SiteRepository[] {
  const siteFile = join(configDir, "site.json");
  if (!existsSync(siteFile)) return [];
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(readFileSync(siteFile, "utf8")) as Record<string, unknown>;
  } catch {
    return [];
  }
  const repos = raw.repositories;
  if (!Array.isArray(repos)) return [];
  const out: SiteRepository[] = [];
  for (const r of repos) {
    if (!r || typeof r !== "object") continue;
    const o = r as Record<string, unknown>;
    out.push({
      name: asString(o.name) ?? "",
      path: asString(o.path) ?? "",
      catalog: asString(o.catalog) ?? "",
      managed: asString(o.managed) ?? "full",
    });
  }
  return out;
}

// Port of repo_catalog_file (lib/module-catalog-lib.sh): the DECLARED catalog
// path wins, then the current convention, then the legacy name (#305, #459).
export function repoCatalogFile(repoPath: string, declared: string): string {
  const root = repoPath.replace(/\/+$/, "");
  const declaredAbs = declared ? join(root, declared) : "";
  if (declaredAbs && existsSync(declaredAbs)) return declaredAbs;
  const current = join(root, "src", "module-catalog.json");
  if (existsSync(current)) return current;
  const legacy = join(root, "src", "modules.json");
  if (existsSync(legacy)) return legacy;
  return current;
}

export interface CatalogHit {
  repo: string;
  moduleJson: string;
  tier: string;
}

// Port of resolve-module.sh's catalog scan: first repository in site.json order
// carrying the module (by moduleName OR legacyName) wins.
export function resolveViaCatalog(configDir: string, module: string): CatalogHit | null {
  for (const repo of siteRepositories(configDir)) {
    if (!repo.path) continue;
    const catalogFile = repoCatalogFile(repo.path, repo.catalog);
    if (!existsSync(catalogFile)) continue;
    let cat: Record<string, unknown>;
    try {
      cat = JSON.parse(readFileSync(catalogFile, "utf8")) as Record<string, unknown>;
    } catch {
      continue;
    }
    const entries = [
      ...(Array.isArray(cat.foundationModules) ? cat.foundationModules : []),
      ...(Array.isArray(cat.applicationModules) ? cat.applicationModules : []),
    ];
    for (const e of entries) {
      if (!e || typeof e !== "object") continue;
      const o = e as Record<string, unknown>;
      if (o.moduleName !== module && o.legacyName !== module) continue;
      const moduleJson = asString(o.moduleJson) ?? "";
      return {
        repo: repo.name,
        moduleJson: moduleJson ? join(repo.path.replace(/\/+$/, ""), moduleJson) : "",
        tier: asString(o.tier) ?? "app",
      };
    }
  }
  return null;
}

// Which path (if any) locates this module.
//   location        .location resolves to a real directory
//   catalog         no usable .location, but a repository catalog carries it
//   broken-location .location recorded, directory gone, catalog does not cover it
//   unresolvable    no .location and no catalog entry — nothing can find it
export type ResolutionPath = "location" | "catalog" | "broken-location" | "unresolvable";

export interface ModuleResolution {
  module: string;
  path: ResolutionPath;
  dir: string | null;
  /** Repository whose catalog carries it, independent of `path`. */
  catalogRepo: string | null;
  tier: string | null;
  /** Where `tier` came from — the deployed config outranks the catalog (#460). */
  tierSource: "config" | "catalog" | null;
}

export function classifyModuleResolution(configDir: string, module: string): ModuleResolution {
  const dirResult = getModuleDirResult(configDir, module);
  const hit = resolveViaCatalog(configDir, module);
  const cfg = loadModule(configDir, module);

  let path: ResolutionPath;
  let dir: string | null = null;
  if (dirResult.kind === "found") {
    path = "location";
    dir = dirResult.dir;
  } else if (hit) {
    path = "catalog";
    dir = hit.moduleJson ? dirname(hit.moduleJson) : null;
  } else if (dirResult.kind === "missing-dir") {
    path = "broken-location";
    dir = dirResult.dir;
  } else {
    path = "unresolvable";
  }

  const configTier = cfg?.tier ?? null;
  return {
    module,
    path,
    dir,
    catalogRepo: hit ? hit.repo : null,
    tier: configTier ?? hit?.tier ?? null,
    tierSource: configTier ? "config" : hit ? "catalog" : null,
  };
}
