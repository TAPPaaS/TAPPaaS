// modify.ts — the backup CRUD that WRITES the module `.backup` layer (ADR-007
// verb-alignment #3, approved decision 7). backup-manager OWNS `.backup` writes.
//
//   modify <module> [--enabled true|false] [--retention <spec>] [--exclude a,b]
//       Writes the module's `.backup` {enabled, retention, exclude} onto
//       config/<module>.json. ATOMIC (write temp + rename). Only the flags
//       given are changed; others are preserved. Then the cascade re-resolves
//       (module > environment > site), so this is the per-module override knob.
//
//   add <module>      Manage the module's PBS-job WIRING (dependsOn backup:vm):
//   delete <module>   add ⇒ ensure "backup:vm" ∈ .dependsOn (joins the shared
//                     job at next reconcile); delete ⇒ remove it (leaves the
//                     job). Both are modify-driven .json writes; the live PBS
//                     membership converges on `reconcile`.
//
// install-module keeps calling `resolve` to RECORD the resolved policy after a
// deploy (DESIGN.md) — that path is unchanged; this manager does not duplicate
// it. These verbs are the operator's hand-free way to change the override.

import { existsSync, readFileSync, renameSync, writeFileSync } from "fs";
import { join } from "path";

export interface ModifyOpts {
  enabled?: boolean;
  retention?: string;
  exclude?: string[];
}

function moduleFile(configDir: string, module: string): string {
  return join(configDir, `${module}.json`);
}

// Read the module JSON as a mutable object. Throws if absent (you can only
// modify a deployed module's backup policy).
function readModule(configDir: string, module: string): Record<string, unknown> {
  const f = moduleFile(configDir, module);
  if (!existsSync(f)) {
    throw new Error(`no config for module '${module}' in ${configDir} (deploy it first)`);
  }
  const v = JSON.parse(readFileSync(f, "utf8"));
  if (!v || typeof v !== "object" || Array.isArray(v)) {
    throw new Error(`module config ${f} is not a JSON object`);
  }
  return v as Record<string, unknown>;
}

// Atomic write: stringify (2-space, trailing newline) → temp → rename.
function writeModule(configDir: string, module: string, obj: Record<string, unknown>): void {
  const f = moduleFile(configDir, module);
  const tmp = `${f}.tmp`;
  writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n", "utf8");
  renameSync(tmp, f);
}

function asObject(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

// modify: merge the given fields into module .backup. Returns the new .backup.
export function modifyBackup(
  configDir: string,
  module: string,
  opts: ModifyOpts,
): Record<string, unknown> {
  const obj = readModule(configDir, module);
  const backup = asObject(obj.backup);
  if (opts.enabled !== undefined) backup.enabled = opts.enabled;
  if (opts.retention !== undefined) backup.retention = opts.retention;
  if (opts.exclude !== undefined) backup.exclude = opts.exclude;
  obj.backup = backup;
  writeModule(configDir, module, obj);
  return backup;
}

// add: ensure "backup:vm" ∈ .dependsOn (idempotent). Returns true if changed.
export function addToBackupJob(configDir: string, module: string): boolean {
  const obj = readModule(configDir, module);
  const deps = Array.isArray(obj.dependsOn)
    ? obj.dependsOn.filter((x): x is string => typeof x === "string")
    : [];
  if (deps.includes("backup:vm")) return false;
  deps.push("backup:vm");
  obj.dependsOn = deps;
  writeModule(configDir, module, obj);
  return true;
}

// delete: remove "backup:vm" from .dependsOn (idempotent). Returns true if changed.
export function removeFromBackupJob(configDir: string, module: string): boolean {
  const obj = readModule(configDir, module);
  const deps = Array.isArray(obj.dependsOn)
    ? obj.dependsOn.filter((x): x is string => typeof x === "string")
    : [];
  if (!deps.includes("backup:vm")) return false;
  obj.dependsOn = deps.filter((d) => d !== "backup:vm");
  writeModule(configDir, module, obj);
  return true;
}
