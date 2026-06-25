// config.ts — load / write / validate the Environment domain from
// config/environments/.
//
// "config/" means the TARGET system (~tappaas/config), per the ADR-007
// "Convention: config/ means the target system" note. Default path resolves
// from TAPPAAS_CONFIG (or /home/tappaas/config); tests pass an explicit dir
// (the fixture tree under test/fixtures/).

import { existsSync, readFileSync, readdirSync, writeFileSync } from "fs";
import { basename, join } from "path";
import {
  Environment,
  EnvironmentModel,
  RefSources,
} from "./types";

export function defaultConfigDir(): string {
  return process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
}

// The environments directory under a config root.
export function environmentsDir(configDir: string): string {
  return join(configDir, "environments");
}

function asString(v: unknown): string {
  return typeof v === "string" ? v : "";
}
function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is string => typeof x === "string");
}

// Parse one raw JSON object into an Environment (lenient — schema-conformance is
// checked separately by validateEnvironment via the .sh schema, see TODO below).
// `fallbackName` (the filename stem) is used when the JSON omits `name`.
export function parseEnvironment(raw: unknown, fallbackName?: string): Environment {
  const o = (raw ?? {}) as Record<string, unknown>;
  const net = (o.network ?? {}) as Record<string, unknown>;
  const env: Environment = {
    name: asString(o.name),
    displayName: asString(o.displayName),
    ownerOrg: asString(o.ownerOrg),
    network: { zone: asString(net.zone) },
  };
  if (!env.name && fallbackName) env.name = fallbackName;
  if (o.domains && typeof o.domains === "object") {
    const d = o.domains as Record<string, unknown>;
    env.domains = {
      primary: asString(d.primary),
      aliases: asStringArray(d.aliases),
      aliasMode: d.aliasMode === "mirror" ? "mirror" : "redirect",
      dnsMode: d.dnsMode === "wildcard" ? "wildcard" : "per-service",
    };
  }
  if (o.dataResidency === "global" || o.dataResidency === "eu-only") {
    env.dataResidency = o.dataResidency;
  }
  if (o.backup === null) env.backup = null;
  else if (o.backup && typeof o.backup === "object") {
    const b = o.backup as Record<string, unknown>;
    env.backup = {
      retention: typeof b.retention === "string" ? b.retention : undefined,
      residency:
        b.residency === "global" || b.residency === "eu-only" ? b.residency : undefined,
      schedule: typeof b.schedule === "string" ? b.schedule : null,
    };
  }
  if (o.legal === null) env.legal = null;
  else if (o.legal && typeof o.legal === "object") {
    const l = o.legal as Record<string, unknown>;
    env.legal = { processor: typeof l.processor === "string" ? l.processor : null };
  }
  return env;
}

// Load all environments under <configDir>/environments/.
export function loadEnvironments(configDir: string): EnvironmentModel {
  const model: EnvironmentModel = { environments: new Map() };
  const dir = environmentsDir(configDir);
  if (!existsSync(dir)) return model;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    const txt = readFileSync(join(dir, f), "utf8");
    const env = parseEnvironment(JSON.parse(txt));
    if (!env.name) env.name = basename(f, ".json");
    model.environments.set(env.name, env);
  }
  return model;
}

// Load one environment by name; null when absent.
export function loadEnvironment(configDir: string, name: string): Environment | null {
  const path = join(environmentsDir(configDir), `${name}.json`);
  if (!existsSync(path)) return null;
  return parseEnvironment(JSON.parse(readFileSync(path, "utf8")));
}

// Serialize an Environment to canonical JSON (stable key order, schema order).
export function serializeEnvironment(env: Environment): string {
  const out: Record<string, unknown> = {
    name: env.name,
    displayName: env.displayName,
    ownerOrg: env.ownerOrg,
  };
  if (env.domains) out.domains = env.domains;
  out.network = env.network;
  if (env.dataResidency) out.dataResidency = env.dataResidency;
  if (env.backup !== undefined) out.backup = env.backup;
  if (env.legal !== undefined) out.legal = env.legal;
  return JSON.stringify(out, null, 2) + "\n";
}

// Write one environment file (caller decides overwrite policy).
export function writeEnvironment(configDir: string, env: Environment): string {
  const path = join(environmentsDir(configDir), `${env.name}.json`);
  writeFileSync(path, serializeEnvironment(env));
  return path;
}

// ── Reference sources (zones.json + organizations) ────────────────────
export function loadRefSources(configDir: string): RefSources {
  const zoneNames = new Set<string>();
  let zonesAvailable = false;
  const zonesFile = join(configDir, "zones.json");
  if (existsSync(zonesFile)) {
    zonesAvailable = true;
    try {
      const z = JSON.parse(readFileSync(zonesFile, "utf8"));
      if (z && typeof z === "object") {
        for (const k of Object.keys(z as Record<string, unknown>)) zoneNames.add(k);
      }
    } catch {
      // malformed zones.json — treat as unavailable (warning path).
      zonesAvailable = false;
    }
  }

  const orgNames = new Set<string>();
  const orgDir = join(configDir, "people", "organizations");
  if (existsSync(orgDir)) {
    for (const f of readdirSync(orgDir)) {
      if (f.endsWith(".json")) orgNames.add(basename(f, ".json"));
    }
  }

  return { zoneNames, zonesAvailable, orgNames };
}

// ── Validation (mirrors validate-environment.sh reference checks) ─────
// Schema conformance (additionalProperties:false, required fields, the
// tlsCertRefid rejection) is delegated to validate-environment.sh — see the
// TODO(question) in validate.ts. Here we replicate the cross-reference +
// tlsCertRefid checks in-process so reconcile can refuse to run on a broken
// tree. Returns { errors, warnings }.
export interface ValidationResult {
  errors: string[];
  warnings: string[];
}

// Recursively test whether any object node carries a `tlsCertRefid` key.
function hasTlsCertRefid(v: unknown): boolean {
  if (Array.isArray(v)) return v.some(hasTlsCertRefid);
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    if (Object.prototype.hasOwnProperty.call(o, "tlsCertRefid")) return true;
    return Object.values(o).some(hasTlsCertRefid);
  }
  return false;
}

// Validate a single environment's references against the ref sources.
// `raw` is the parsed JSON object (for the tlsCertRefid deep-scan); `env` is the
// typed view.
export function validateEnvironmentRefs(
  env: Environment,
  raw: unknown,
  refs: RefSources,
): ValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  const base = `${env.name || "(unnamed)"}`;

  // Required fields (the jq-fallback level of the schema check).
  if (!env.name) errors.push(`${base}: missing required field 'name'`);
  if (!env.displayName) errors.push(`${base}: missing required field 'displayName'`);
  if (!env.ownerOrg) errors.push(`${base}: missing required field 'ownerOrg'`);
  if (!env.network.zone) errors.push(`${base}: missing required field 'network.zone'`);

  // Reject an authored tlsCertRefid anywhere (runtime state, not config).
  if (hasTlsCertRefid(raw)) {
    errors.push(
      `${base}: authored 'tlsCertRefid' is not allowed (it is runtime state, not config)`,
    );
  }

  // network.zone must exist in zones.json (when available).
  if (env.network.zone) {
    if (refs.zonesAvailable) {
      if (!refs.zoneNames.has(env.network.zone)) {
        errors.push(
          `${base}: network.zone references unknown zone '${env.network.zone}' (not in zones.json)`,
        );
      }
    } else {
      warnings.push(`${base}: zones.json not available — skipping zone reference check`);
    }
  }

  // ownerOrg (when present) must reference an existing organization.
  if (env.ownerOrg && !refs.orgNames.has(env.ownerOrg)) {
    errors.push(
      `${base}: ownerOrg references unknown organization '${env.ownerOrg}'`,
    );
  }

  return { errors, warnings };
}
