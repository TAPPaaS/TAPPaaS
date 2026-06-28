// config.ts — load + validate + write the Site singleton (config/site.json).
//
// "config/" means the TARGET system (~tappaas/config), per the ADR-007
// convention. The default path resolves from TAPPAAS_CONFIG (or
// /home/tappaas/config); tests pass an explicit dir/file (fixtures).
//
// The Site is a SINGLETON: there is exactly one site.json. `node` and
// `repository` are sub-entities — arrays inside the singleton, each with their
// own CRUD that loads, mutates, and writes the whole document back atomically.

import { existsSync, readFileSync, writeFileSync, renameSync, mkdtempSync } from "fs";
import { dirname, join } from "path";
import { Repository, Site, SiteNode } from "./types";

export function defaultConfigDir(): string {
  return process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
}

export function defaultSiteFile(): string {
  return join(defaultConfigDir(), "site.json");
}

// Locate site-fields.json relative to the compiled bin. The wrapper runs
// $out/lib/main.js, but the schema lives in the source tree under
// foundation/schemas/. validate-site.sh resolves it from FOUNDATION_DIR; the
// CliSiteClient passes --schema-dir explicitly so we don't have to here.
export function defaultSchemaDir(): string {
  return process.env.SITE_SCHEMA_DIR ?? "";
}

function asString(v: unknown): string {
  return typeof v === "string" ? v : "";
}
function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is string => typeof x === "string");
}

// Load and (loosely) normalise site.json into the Site model. Structural
// validation against the schema is `validate` (validate-site.sh), kept separate
// so read commands work even on a slightly-off document.
export function loadSite(siteFile: string): Site {
  if (!existsSync(siteFile)) {
    throw new Error(`site.json not found: ${siteFile}`);
  }
  const raw = JSON.parse(readFileSync(siteFile, "utf8")) as Record<string, unknown>;

  const loc = (raw.location ?? {}) as Record<string, unknown>;
  const hw = (raw.hardware ?? {}) as Record<string, unknown>;
  const rawNodes = Array.isArray(hw.nodes) ? hw.nodes : [];
  const nodes: SiteNode[] = rawNodes.map((n) => {
    const o = n as Record<string, unknown>;
    return { name: asString(o.name), storagePools: asStringArray(o.storagePools) };
  });

  const rawRepos = Array.isArray(raw.repositories) ? raw.repositories : [];
  const repositories: Repository[] = rawRepos.map((r) => {
    const o = r as Record<string, unknown>;
    return { ...o, name: asString(o.name), url: asString(o.url) };
  });

  const site: Site = {
    name: asString(raw.name),
    displayName: asString(raw.displayName),
    owner: asString(raw.owner),
    email: typeof raw.email === "string" ? raw.email : undefined,
    version: typeof raw.version === "string" ? raw.version : undefined,
    location: {
      country: asString(loc.country),
      timezone: asString(loc.timezone),
      locale: typeof loc.locale === "string" ? loc.locale : undefined,
    },
    network: (raw.network ?? undefined) as Site["network"],
    hardware: { nodes },
    backup: (raw.backup ?? null) as Site["backup"],
    updateSchedule: Array.isArray(raw.updateSchedule) ? raw.updateSchedule : undefined,
    automaticReboot: typeof raw.automaticReboot === "boolean" ? raw.automaticReboot : undefined,
    snapshotRetention:
      typeof raw.snapshotRetention === "number" ? raw.snapshotRetention : undefined,
    repositories,
    organizations: asStringArray(raw.organizations),
  };
  return site;
}

// Load the raw document (no normalisation) — used by writers so we never drop
// unknown fields when rewriting the singleton. Returns {} if absent.
export function loadRaw(siteFile: string): Record<string, unknown> {
  if (!existsSync(siteFile)) return {};
  return JSON.parse(readFileSync(siteFile, "utf8")) as Record<string, unknown>;
}

// Atomically write the (whole) site document. Mirrors the bash mktemp+mv idiom.
export function writeSite(siteFile: string, doc: Record<string, unknown>): void {
  const dir = dirname(siteFile);
  const tmpDir = mkdtempSync(join(dir, ".site-"));
  const tmp = join(tmpDir, "site.json");
  writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n", "utf8");
  renameSync(tmp, siteFile);
}
