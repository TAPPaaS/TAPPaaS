// config.ts — load + validate + write the Site singleton (config/site.json).
//
// "config/" means the TARGET system (~tappaas/config), per the ADR-007
// convention. The default path resolves from TAPPAAS_CONFIG (or
// /home/tappaas/config); tests pass an explicit dir/file (fixtures).
//
// The Site is a SINGLETON: there is exactly one site.json. `node` and
// `repository` are sub-entities — arrays inside the singleton, each with their
// own CRUD that loads, mutates, and writes the whole document back atomically.

import { spawnSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { dirname, join } from "path";
import {
  asString,
  defaultConfigDir,
  writeJsonAtomic,
} from "../../../lib/ts/src/config-io";
import { readLocations, siteLocale } from "../../../lib/ts/src/locations";
import { clusterNodes } from "../../../lib/ts/src/nodes";
import { Repository, Site, SiteNode } from "./types";

export { defaultConfigDir };

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

// site-fields.json itself, for what `site modify` reads from it (a field's
// change class and why): --schema-dir, $SITE_SCHEMA_DIR, the schemas/ beside
// the source tree this runs from, the installed checkout's. null: none found.
export function siteSchema(schemaDir: string): Record<string, unknown> | null {
  const dirs = [schemaDir, process.env.SITE_SCHEMA_DIR ?? ""];
  for (let d = __dirname, i = 0; i < 12; i++, d = join(d, "..")) dirs.push(join(d, "schemas"));
  dirs.push("/home/tappaas/TAPPaaS/src/foundation/schemas");
  for (const d of dirs) {
    const f = d ? join(d, "site-fields.json") : "";
    if (!f || !existsSync(f)) continue;
    try {
      return JSON.parse(readFileSync(f, "utf8")) as Record<string, unknown>;
    } catch { /* the next */ }
  }
  return null;
}

// Why a top-level site field cannot change through `site modify` — its change
// class is not in-place — in the schema's words; null when it may.
export function refusedField(schema: Record<string, unknown> | null, field: string): string | null {
  const props = (schema?.properties ?? {}) as Record<string, { changeClass?: string; changeNote?: string }>;
  const p = props[field];
  if (!p) return schema ? `site.json has no field '${field}'` : null;
  if (!p.changeClass || p.changeClass === "in-place") return null;
  return `${p.changeClass}: ${p.changeNote ?? "not changed by site modify"}`;
}

// Load and (loosely) normalise site.json into the Site model. Structural
// validation against the schema is `validate` (validate-site.sh), kept separate
// so read commands work even on a slightly-off document.
export function loadSite(siteFile: string): Site {
  if (!existsSync(siteFile)) {
    throw new Error(`site.json not found: ${siteFile}`);
  }
  const raw = JSON.parse(readFileSync(siteFile, "utf8")) as Record<string, unknown>;

  // The pre-0019 location reads as the primary location it becomes.
  const { locations, primary } = readLocations(raw);
  // The nodes are their pvehost instances beside site.json (ADR-036 D6).
  const nodes: SiteNode[] = clusterNodes(dirname(siteFile));

  const rawRepos = Array.isArray(raw.repositories) ? raw.repositories : [];
  const repositories: Repository[] = rawRepos.map((r) => {
    const o = r as Record<string, unknown>;
    const t = o.trust as Record<string, unknown> | undefined;
    const trust =
      t && typeof t === "object"
        ? {
            // An entry written before the introduction became fingerprint-only
            // carried one `signer`; it reads as a list of one.
            signers: Array.isArray(t.signers)
              ? t.signers.map(asString).filter((x) => x !== "")
              : typeof t.signer === "string" && t.signer ? [t.signer] : [],
          }
        : undefined;
    return { ...o, name: asString(o.name), url: asString(o.url), ...(trust ? { trust } : {}) };
  });

  const site: Site = {
    name: asString(raw.name),
    defaultEnvironment: asString(raw.defaultEnvironment),
    displayName: asString(raw.displayName),
    owner: asString(raw.owner),
    email: typeof raw.email === "string" ? raw.email : undefined,
    supportEmail: typeof raw.supportEmail === "string" ? raw.supportEmail : undefined,
    version: typeof raw.version === "string" ? raw.version : undefined,
    locations,
    primaryLocation: primary,
    ...siteLocale(raw),
    network: (raw.network ?? undefined) as Site["network"],
    nodes,
    backup: (raw.backup ?? null) as Site["backup"],
    updateSchedule: Array.isArray(raw.updateSchedule) ? raw.updateSchedule : undefined,
    channel: raw.channel === "unstable" || raw.channel === "staging" || raw.channel === "production"
      ? raw.channel
      : undefined,
    automaticReboot: typeof raw.automaticReboot === "boolean" ? raw.automaticReboot : undefined,
    ipv6: typeof raw.ipv6 === "boolean" ? raw.ipv6 : undefined,
    requireSigned: typeof raw.requireSigned === "boolean" ? raw.requireSigned : undefined,
    snapshotRetention:
      typeof raw.snapshotRetention === "number" ? raw.snapshotRetention : undefined,
    repositories,
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
  writeJsonAtomic(siteFile, doc);
}

// Locate a cluster module script (reboot-node.sh, remove-node.sh, lan-uplink.sh).
// Not on PATH and has no ~/bin symlink (unlike most TAPPaaS tooling), so resolve
// it from the cluster module's recorded location the same way update-tappaas
// resolves reboot-cluster.sh.
export function clusterScript(file: string): string | null {
  const r = spawnSync("module-manager", ["show", "cluster", "--json"], { encoding: "utf8" });
  if (r.status === 0 && r.stdout) {
    try {
      const loc = (JSON.parse(r.stdout) as Record<string, unknown>).location;
      if (typeof loc === "string" && loc) {
        const p = `${loc}/${file}`;
        if (existsSync(p)) return p;
      }
    } catch {
      // fall through to the well-known path
    }
  }
  const fallback = `/home/tappaas/TAPPaaS/src/foundation/cluster/${file}`;
  return existsSync(fallback) ? fallback : null;
}
