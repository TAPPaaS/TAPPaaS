// config.ts — load + resolve the backup-policy cascade from CONFIG_DIR.
//
// Direct port of lib-cascade.sh `bc_resolve` / `bc_module_in_pbs_job` /
// `bc_list_modules` / `bc_module_environment`. Pure config reads from
// CONFIG_DIR; never mutates state and never contacts PBS — so it is fully
// unit-testable against fixtures (exactly as the bash lib was).
//
// The lib stays the source of truth for the BASH controller (which may still
// source it); this is the manager-side reimplementation in TypeScript. The two
// must agree on precedence — keep them in lock-step.
//
// Cascade precedence (most specific wins), verbatim from lib-cascade.sh:
//   retention : module.backup.retention > environment.backup.retention
//               > site.backup.defaultRetention > "7y"
//   residency : module has none; environment.backup.residency
//               > environment.dataResidency > "eu-only"
//   enabled   : module.backup.enabled (default true)
//   exclude   : module.backup.exclude (default [])
//   target    : site.backup.target
//   offsite   : site.backup.offsite
//   schedule  : environment.backup.schedule > null (inherit site job)

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { BackupPolicy } from "./types";

export function defaultConfigDir(): string {
  // The cascade reads the TARGET config root directly (it holds <module>.json,
  // site.json, environments/). lib-cascade.sh defaults to /home/tappaas/config.
  return process.env.CONFIG_DIR ?? process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
}

// Read + parse a JSON file, or null when absent / unparseable (the bash lib
// treats a bad/missing layer as {}).
function readJson(file: string): Record<string, unknown> | null {
  if (!existsSync(file)) return null;
  try {
    const v = JSON.parse(readFileSync(file, "utf8"));
    return v && typeof v === "object" ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function asObject(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}
function asString(v: unknown): string | null {
  return typeof v === "string" && v !== "" ? v : null;
}
function asStringArray(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
}

// Resolve the environment name for a deployed module: explicit override, else
// the module config's .environment, else null. (bc_module_environment)
export function moduleEnvironment(
  configDir: string,
  module: string,
  override?: string,
): string | null {
  if (override) return override;
  const m = readJson(join(configDir, `${module}.json`));
  if (!m) return null;
  return asString(m.environment);
}

// Resolve the effective backup policy for a module (port of bc_resolve).
export function resolvePolicy(
  configDir: string,
  module: string,
  envOverride?: string,
): BackupPolicy {
  const site = asObject(readJson(join(configDir, "site.json"))?.backup);
  const envName = moduleEnvironment(configDir, module, envOverride);
  const envFile = envName ? readJson(join(configDir, "environments", `${envName}.json`)) : null;
  const envBackup = asObject(envFile?.backup);
  const envDataResidency = envFile ? asString(envFile.dataResidency) : null;
  const mod = asObject(readJson(join(configDir, `${module}.json`))?.backup);

  // retention: module > environment > site.defaultRetention > "7y"
  const siteRet = asString(site.defaultRetention) ?? "7y";
  const envRet = asString(envBackup.retention) ?? siteRet;
  const retention = asString(mod.retention) ?? envRet;

  // residency: environment.backup.residency > environment.dataResidency > "eu-only"
  const residency = asString(envBackup.residency) ?? envDataResidency ?? "eu-only";

  // enabled: module.backup.enabled (default true) — only an explicit false disables.
  const enabled = mod.enabled === false ? false : true;

  return {
    module,
    environment: envName,
    enabled,
    retention,
    residency,
    schedule: asString(envBackup.schedule),
    target: asString(site.target),
    offsite: asString(site.offsite),
    exclude: asStringArray(mod.exclude),
  };
}

// True if <module> declares dependsOn backup:vm (wired into the shared PBS
// job). Port of bc_module_in_pbs_job.
export function moduleInPbsJob(configDir: string, module: string): boolean {
  const m = readJson(join(configDir, `${module}.json`));
  if (!m) return false;
  const deps = asStringArray(m.dependsOn);
  return deps.includes("backup:vm");
}

// Non-module config basenames the bash lib skips (bc_list_modules).
const NON_MODULES = new Set(["site", "zones", "backup", "configuration", "module-catalog"]);

// List deployed module config basenames (without .json). Port of bc_list_modules.
export function listModules(configDir: string): string[] {
  if (!existsSync(configDir)) return [];
  const out: string[] = [];
  for (const f of readdirSync(configDir)) {
    if (!f.endsWith(".json")) continue;
    const b = f.slice(0, -".json".length);
    if (NON_MODULES.has(b)) continue;
    if (b.startsWith("remote-") || b.startsWith("external-")) continue;
    out.push(b);
  }
  return out.sort();
}

// Resolve a module name to its VMID from the deployed config (used by restore).
export function moduleVmid(configDir: string, module: string): string | null {
  const m = readJson(join(configDir, `${module}.json`));
  if (!m) return null;
  return asString(m.vmid);
}

// Read the raw site.backup block (validate needs offsite/target/offsiteResidency).
export function siteBackup(configDir: string): Record<string, unknown> {
  return asObject(readJson(join(configDir, "site.json"))?.backup);
}

// List environment names that have a JSON file (validate iterates these).
export function listEnvironments(configDir: string): string[] {
  const dir = join(configDir, "environments");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => f.slice(0, -".json".length))
    .sort();
}

// Raw environment block (validate reads residency/dataResidency/backup.retention).
export function environmentRaw(configDir: string, env: string): Record<string, unknown> {
  return asObject(readJson(join(configDir, "environments", `${env}.json`)));
}
