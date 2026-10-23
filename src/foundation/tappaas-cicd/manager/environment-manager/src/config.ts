// config.ts — load / write / validate the Environment domain from
// config/environments/.
//
// "config/" means the TARGET system (~tappaas/config), per the ADR-007
// "Convention: config/ means the target system" note. Default path resolves
// from TAPPAAS_CONFIG (or /home/tappaas/config); tests pass an explicit dir
// (the fixture tree under test/fixtures/).

import { existsSync, readFileSync, readdirSync, writeFileSync } from "fs";
import { basename, join } from "path";
import { asString, asStringArray, defaultConfigDir, identityDir } from "../../../lib/ts/src/config-io";
import {
  Environment,
  EnvironmentModel,
  RefSources,
  ZoneLink,
} from "./types";

export { defaultConfigDir };

// The environments directory under a config root.
export function environmentsDir(configDir: string): string {
  return join(configDir, "environments");
}

// Parse one raw JSON object into an Environment (lenient — schema-conformance
// is checked separately by the `validate` verb, src/validate.ts).
// `fallbackName` (the filename stem) is used when the JSON omits `name`.
export function parseEnvironment(raw: unknown, fallbackName?: string): Environment {
  const o = (raw ?? {}) as Record<string, unknown>;
  const env: Environment = {
    name: asString(o.name),
    displayName: asString(o.displayName),
    ownerOrg: asString(o.ownerOrg),
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
// The zones.json file read as zone → {type, environment}. Doc blocks ("_*")
// and non-object values are skipped. Throws on unreadable or malformed JSON.
export function readZoneLinks(zonesFile: string): Map<string, ZoneLink> {
  const out = new Map<string, ZoneLink>();
  const z = JSON.parse(readFileSync(zonesFile, "utf8")) as unknown;
  if (!z || typeof z !== "object" || Array.isArray(z)) return out;
  for (const [k, v] of Object.entries(z as Record<string, unknown>)) {
    if (k.startsWith("_") || !v || typeof v !== "object" || Array.isArray(v)) continue;
    const o = v as Record<string, unknown>;
    out.set(k, {
      type: typeof o.type === "string" ? o.type : undefined,
      environment: typeof o.environment === "string" && o.environment ? o.environment : undefined,
    });
  }
  return out;
}

// The zone types that are an environment's own zone (#865): Service, and the
// Management zone for mgmt.
export const OWN_ZONE_TYPES: ReadonlySet<string> = new Set(["Service", "Management"]);

// The zones that are environment `env`'s own: Service/Management zones naming it.
export function ownZones(zones: Map<string, ZoneLink>, env: string): string[] {
  return [...zones].filter(([, z]) => OWN_ZONE_TYPES.has(z.type ?? "") && z.environment === env).map(([n]) => n).sort();
}

// The environment's zone, when exactly one zone is its own.
export function environmentZone(refs: Pick<RefSources, "zones">, env: string): string | undefined {
  const own = ownZones(refs.zones, env);
  return own.length === 1 ? own[0] : undefined;
}

// The refs as they will be once `zone` is environment `env`'s zone: the zone
// names env, and any other own zone of env no longer does. Used to validate an
// add/modify --zone before network-manager is asked to make it so.
export function withBinding(refs: RefSources, zone: string, env: string): RefSources {
  const zones = new Map(refs.zones);
  for (const n of ownZones(zones, env)) zones.set(n, { ...zones.get(n), environment: undefined });
  zones.set(zone, { type: zones.get(zone)?.type ?? "Service", environment: env });
  return { ...refs, zones, zoneNames: new Set([...refs.zoneNames, zone]) };
}

export function loadRefSources(configDir: string): RefSources {
  const zoneNames = new Set<string>();
  let zones = new Map<string, ZoneLink>();
  let zonesAvailable = false;
  const zonesFile = join(configDir, "zones.json");
  if (existsSync(zonesFile)) {
    zonesAvailable = true;
    try {
      zones = readZoneLinks(zonesFile);
      for (const k of zones.keys()) zoneNames.add(k);
    } catch {
      // malformed zones.json — treat as unavailable (warning path).
      zonesAvailable = false;
    }
  }

  const orgNames = new Set<string>();
  const orgDir = join(identityDir(configDir), "organizations");
  if (existsSync(orgDir)) {
    for (const f of readdirSync(orgDir)) {
      if (f.endsWith(".json")) orgNames.add(basename(f, ".json"));
    }
  }

  return { zoneNames, zones, zonesAvailable, orgNames };
}

// ── Validation (the in-process PRE-WRITE guard) ───────────────────────
// Full schema conformance (additionalProperties:false, pattern/enum/minLength)
// is the `validate` verb's job — src/validate.ts interprets
// environment-fields.json directly. Here we keep the lighter cross-reference +
// required-field + tlsCertRefid checks used by add/modify (refuse a write
// before it touches disk) and by reconcile (refuse to run on a broken tree).
// Returns { errors, warnings }.
export interface ValidationResult {
  errors: string[];
  warnings: string[];
}

// The problems with environment `env`'s zone link, as message bodies: none of
// its own, or more than one. Shared by add/modify and the `validate` verb.
export function zoneLinkErrors(zones: Map<string, ZoneLink>, env: string): string[] {
  const own = ownZones(zones, env);
  if (own.length === 1) return [];
  if (own.length === 0) {
    return [
      `no Service or Management zone names environment '${env}' — give it one with ` +
        `\`environment-manager modify ${env} --zone <zone>\``,
    ];
  }
  return [
    `environment '${env}' is named by ${own.length} Service/Management zones (${own.join(", ")}) — ` +
      `an environment has one zone; unbind the others with \`network-manager bind <zone> --unbind\``,
  ];
}

// Recursively test whether any object node carries a `tlsCertRefid` key.
// Also used by the `validate` verb (src/validate.ts) as the belt-and-braces
// check over the schema's additionalProperties:false rejection.
export function hasTlsCertRefid(v: unknown): boolean {
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

  // Reject an authored tlsCertRefid anywhere (runtime state, not config).
  if (hasTlsCertRefid(raw)) {
    errors.push(
      `${base}: authored 'tlsCertRefid' is not allowed (it is runtime state, not config)`,
    );
  }

  // Exactly one Service (or Management) zone names the environment (#865).
  if (env.name) {
    if (refs.zonesAvailable) {
      for (const e of zoneLinkErrors(refs.zones, env.name)) errors.push(`${base}: ${e}`);
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
