// config.ts — load the module config domain that health-manager READS.
//
// "config/" means the TARGET system (~tappaas/config), per the ADR-007
// "config/ means the target system" convention. Default path resolves from
// TAPPAAS_CONFIG (or /home/tappaas/config); tests pass an explicit dir.
//
// health-manager owns NO config of its own — it reads the per-module JSONs that
// module-manager writes, plus (for the three-way diff) the git source JSON the
// module's `location` field points at.

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { ConfigModule } from "./types";

export function defaultConfigDir(): string {
  return process.env.CONFIG_DIR ?? process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
}

function asString(v: unknown): string {
  if (typeof v === "string") return v;
  if (typeof v === "number") return String(v);
  return "";
}

// Parse one module JSON into a flat Record. inspect-vm.sh runs the on-disk JSON
// through `normalize_module_config` (the bash "Pattern A → flat" normalizer) so
// nested-shape configs resolve the same as flat ones.
// TODO(question): the bash `normalize_module_config` flattens a "Pattern A"
// nested module shape (variant/tier wrapper) into flat keys. This port reads
// flat keys only. Need the exact Pattern-A → flat mapping rules (which keys are
// nested, precedence) before the three-way diff matches inspect-vm.sh on
// nested-shape configs. PARKED — see returned question list.
export function readModuleJson(path: string): Record<string, unknown> | null {
  if (!existsSync(path)) return null;
  try {
    const o = JSON.parse(readFileSync(path, "utf8"));
    return o && typeof o === "object" ? (o as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

// Node hostnames from site.json (.hardware.nodes[].name) — the bash
// `get_all_node_hostnames` equivalent. Authoritative source for the cluster
// node list; an empty array means "fall back to the tappaas1..9 scan" (the
// CliClusterClient does that). Read here so the inspection logic and the SSH
// client share one source of truth.
export function siteNodeHostnames(configDir: string): string[] {
  const raw = readModuleJson(join(configDir, "site.json"));
  if (!raw) return [];
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

// Enumerate the configured modules (the JSONs in config/ that carry a vmid).
// Non-module configs (site.json, firewall.json, zones.json, …) lack a vmid and
// are skipped — exactly as inspect-cluster.sh does.
export function loadConfigModules(configDir: string, defaultNode: string): ConfigModule[] {
  if (!existsSync(configDir)) return [];
  const out: ConfigModule[] = [];
  for (const f of readdirSync(configDir)) {
    if (!f.endsWith(".json")) continue;
    const raw = readModuleJson(join(configDir, f));
    if (!raw) continue;
    const vmidStr = asString(raw.vmid);
    if (!vmidStr) continue;
    const vmid = Number(vmidStr);
    if (!Number.isFinite(vmid)) continue;
    out.push({
      module: f.slice(0, -".json".length),
      vmid,
      node: asString(raw.node) || defaultNode,
      status: asString(raw.status),
    });
  }
  return out;
}

// Resolve the git source JSON for a module via its `location` field — the
// Released column in the three-way diff. Tries <location>/<module>.json then
// <location>/<vmname>.json (matching inspect-vm.sh). Returns null when absent.
export function resolveGitJson(
  configDir: string,
  module: string,
  vmname: string,
): Record<string, unknown> | null {
  const cfg = readModuleJson(join(configDir, `${module}.json`));
  const location = cfg ? asString(cfg.location) : "";
  if (!location) return null;
  for (const cand of [join(location, `${module}.json`), join(location, `${vmname}.json`)]) {
    const g = readModuleJson(cand);
    if (g) return g;
  }
  return null;
}
