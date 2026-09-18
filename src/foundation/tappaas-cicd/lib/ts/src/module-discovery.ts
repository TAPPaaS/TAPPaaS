// module-discovery.ts — which files in config/ are deployed MODULES (#544).
//
// `config/` holds more than modules: site/zone state, the composed schema
// cache, switch desired/actual, run results like last-update-result.json, peer
// configs, .orig backups. Every reader that enumerates modules needs the same
// answer, and the two that existed disagreed:
//
//   module-manager  shape-based — the `kind:"module"` tag install-module.sh
//                   writes, else a module-shaped field. Correct.
//   backup-manager  a hand-maintained deny-list of five basenames, so every
//                   non-module file nobody had thought to add classified AS a
//                   module (#544: last-update-result.json, module-fields.json,
//                   zones.effective.json, …).
//
// A deny-list is the wrong shape for this: it fails open, and it fails silently
// — a new state file in config/ becomes a phantom module in every report. The
// rule lives here once, and both managers import it.
//
// The selection rule, in order:
//   1. A workload `kind` (ADR-022f: vm, lxc, machine, application, device) —
//      what a module authors. Or the LEGACY marker `kind: "module"`, which
//      install-module.sh stamped until #611: migration 0004 removes it wherever
//      another signal exists, and keeps it where it is the only one, so the
//      module does not vanish from discovery.
//   2. Otherwise a module-shaped field: dependsOn / integratesWith / provides /
//      location. Provider-only modules (e.g. `templates`) have no vmid or
//      vmname, so requiring those would drop them — the shape is the wiring,
//      not the guest.
//   3. Never *.orig, never unparseable JSON, never a non-object.

import { existsSync, readFileSync, readdirSync } from "fs";
import { basename, join } from "path";

// Files that are JSON objects in config/ and would otherwise pass the shape
// test. This is a small SAFETY NET under rule 1/2, not the selection mechanism:
// anything here must also be something the shape test cannot rule out.
const NON_MODULE_BASENAMES = new Set<string>([
  "zones",
  "site",
  "module-fields",
  "cert-refids",
  "switch-configuration-actual",
  "switch-configuration-desired",
]);

// Prefixes of the off-site peer configs (ADR-012 §1.4): pull-<n> (we pull
// theirs), remote-<n> (they pull ours), receive-<n> (they push into ours).
// They are peers, not modules.
const PEER_PREFIXES = ["pull-", "remote-", "receive-"];

/** True when a parsed config object is a deployed module. */
/** The workload kinds a module authors (ADR-022f D1). */
export const WORKLOAD_KINDS = ["vm", "lxc", "machine", "application", "device"] as const;

export function isModuleConfig(raw: Record<string, unknown>): boolean {
  if (raw.kind === "module") return true; // legacy marker (migration 0004)
  if (typeof raw.kind === "string" && (WORKLOAD_KINDS as readonly string[]).includes(raw.kind)) return true;
  return (
    Array.isArray(raw.dependsOn) ||
    Array.isArray(raw.integratesWith) ||
    Array.isArray(raw.provides) ||
    typeof raw.moduleSource === "string" ||
    typeof raw.location === "string" // its name before #609 (migration 0006)
  );
}

/** True when a basename is a known non-module config (state, schema, peer). */
export function isNonModuleBasename(name: string): boolean {
  return NON_MODULE_BASENAMES.has(name) || PEER_PREFIXES.some((p) => name.startsWith(p));
}

export interface DiscoveredModule {
  name: string;
  raw: Record<string, unknown>;
}

/**
 * Every deployed module config in `configDir`, sorted by name. Unreadable or
 * unparseable files are skipped rather than thrown on: enumerating modules must
 * not fail because something unrelated in config/ is malformed.
 */
export function discoverModules(configDir: string): DiscoveredModule[] {
  if (!existsSync(configDir)) return [];
  const out: DiscoveredModule[] = [];
  for (const f of readdirSync(configDir)) {
    if (!f.endsWith(".json")) continue;
    if (f.endsWith(".orig")) continue;
    const name = basename(f, ".json");
    if (isNonModuleBasename(name)) continue;
    let raw: unknown;
    try {
      raw = JSON.parse(readFileSync(join(configDir, f), "utf8"));
    } catch {
      continue;
    }
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
    const obj = raw as Record<string, unknown>;
    if (!isModuleConfig(obj)) continue;
    out.push({ name, raw: obj });
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

/**
 * True when a module has opted into a backup capability (ADR-012 §3.1/D18) by
 * EITHER relationship — `dependsOn` (hard) or `integratesWith` (optional, the
 * one the foundation VMs that bootstrap before the backup server use, #501).
 * Backup is opt-in: a module declaring neither is not backed up.
 */
export function declaresBackup(
  raw: Record<string, unknown>,
  capability: "vm" | "filesystem" | "any" = "any",
): boolean {
  const declared = [
    ...(Array.isArray(raw.dependsOn) ? raw.dependsOn : []),
    ...(Array.isArray(raw.integratesWith) ? raw.integratesWith : []),
  ].filter((x): x is string => typeof x === "string");
  if (capability === "any") {
    return declared.some((d) => d === "backup:vm" || d === "backup:filesystem");
  }
  return declared.includes(`backup:${capability}`);
}
