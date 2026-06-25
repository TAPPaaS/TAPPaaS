// bootstrap.ts — the create-minimal-environments.sh logic, ported.
//
// Every TAPPaaS system requires two environments:
//   - mgmt          : the management environment (foundation modules, internal
//                     DNS only). network.zone = mgmt, NO domains.
//   - <N>           : the DEFAULT tenant environment, named after the TAPPaaS
//                     system name <N> (= site.json.name = default-zone name =
//                     default-environment name). network.zone = <N>. A domain is
//                     added only when --domain is given.
//
// This module is the SINGLE OWNER of these two files. Idempotent: an existing
// file is left untouched unless force=true. A stale literal default.json from an
// older bootstrap is NOTED, never deleted.

import { existsSync, readFileSync, readdirSync } from "fs";
import { basename, join } from "path";
import { environmentsDir, serializeEnvironment } from "./config";
import { Environment } from "./types";
import { writeFileSync } from "fs";

export interface BootstrapOptions {
  configDir: string;
  name?: string; // explicit --name; else derived from site.json '.name'
  domain?: string; // --domain for the default env's domains.primary
  force: boolean;
}

export interface BootstrapResult {
  wrote: string[]; // paths written
  skipped: string[]; // paths left untouched (already existed)
  warnings: string[];
  name: string;
  owner: string;
}

// First organization slug under config/people/organizations/ (sorted), else "".
// Exported as firstOrg for reuse as the `add --owner` default (matches the
// bootstrap's ownerOrg derivation).
export function firstOrg(configDir: string): string {
  const dir = join(configDir, "people", "organizations");
  if (!existsSync(dir)) return "";
  const names = readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => basename(f, ".json"))
    .sort();
  return names[0] ?? "";
}

// Resolve the TAPPaaS system name <N>: explicit name, else site.json '.name'.
// Returns null when none is derivable.
export function resolveName(configDir: string, explicit?: string): string | null {
  if (explicit) return explicit;
  const site = join(configDir, "site.json");
  if (existsSync(site)) {
    try {
      const o = JSON.parse(readFileSync(site, "utf8")) as Record<string, unknown>;
      if (typeof o.name === "string" && o.name) return o.name;
    } catch {
      // fall through
    }
  }
  return null;
}

const SLUG_RE = /^[A-Za-z0-9_-]+$/;

// Build (do not write) the two bootstrap environments.
export function buildBootstrapEnvironments(
  name: string,
  owner: string,
  domain: string | undefined,
): { mgmt: Environment; def: Environment } {
  const display = name.charAt(0).toUpperCase() + name.slice(1);
  const mgmt: Environment = {
    name: "mgmt",
    displayName: "Management",
    ownerOrg: owner,
    network: { zone: "mgmt" },
  };
  const def: Environment = {
    name,
    displayName: display,
    ownerOrg: owner,
    network: { zone: name },
  };
  if (domain) def.domains = { primary: domain };
  return { mgmt, def };
}

// Run the bootstrap. Throws Error on unrecoverable input problems.
export function bootstrap(opts: BootstrapOptions): BootstrapResult {
  const configDir = opts.configDir.replace(/\/$/, "");
  const outDir = environmentsDir(configDir);

  const name = resolveName(configDir, opts.name);
  if (!name) {
    throw new Error(
      "Cannot determine the TAPPaaS system name. Pass --name <N>, or provide a site.json with '.name'.",
    );
  }
  if (!SLUG_RE.test(name)) {
    throw new Error(
      `Resolved system name '${name}' is not a valid slug (allowed: A-Z a-z 0-9 _ -).`,
    );
  }
  if (name === "mgmt") {
    throw new Error(
      "The TAPPaaS system name must not be 'mgmt' (that name is reserved for the management environment).",
    );
  }

  const warnings: string[] = [];
  const owner = firstOrg(configDir);
  if (!owner) {
    warnings.push(
      `No organization found under ${configDir}/people/organizations/ — ownerOrg left empty in bootstrap environments.`,
    );
  }

  const { mgmt, def } = buildBootstrapEnvironments(name, owner, opts.domain);

  const wrote: string[] = [];
  const skipped: string[] = [];
  for (const env of [mgmt, def]) {
    const path = join(outDir, `${env.name}.json`);
    if (existsSync(path) && !opts.force) {
      skipped.push(path);
      continue;
    }
    writeFileSync(path, serializeEnvironment(env));
    wrote.push(path);
  }

  // Note (do not delete) a stale literal default.json from older bootstraps.
  const legacy = join(outDir, "default.json");
  if (name !== "default" && existsSync(legacy)) {
    warnings.push(
      `A legacy '${legacy}' exists — the default environment is now '${name}.json'. ` +
        `It is left in place; remove it manually once you confirm nothing references it.`,
    );
  }

  return { wrote, skipped, warnings, name, owner };
}
