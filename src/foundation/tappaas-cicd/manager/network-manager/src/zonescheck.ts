// zonescheck.ts — consistency check of the live zones.json against the
// installation (ADR-007 "S6 N4").
//
// A pure, offline, READ-ONLY audit run at every tappaas-cicd update (wired
// non-fatally into pre-update.sh). It loads the live zones.json and, optionally,
// the installed module configs, and reports a per-check summary:
//
//   1. Well-formed     — zones.json parses; each (non-"_*") zone is an object
//                        with the core fields (≥ state; warn on missing
//                        access-to / ip / subId).
//   2. VLAN/subId       — no two zones share a VLAN tag, nor a subId within a
//      uniqueness        type band.
//   3. Referential      — every access-to / pinhole-allowed-from entry resolves
//      integrity         to an existing zone key (or the literal "internet"); a
//                        ref to an Inactive zone is allowed but noted.
//   4. mgmt invariant   — a `mgmt` zone exists and is Active.
//   5. Installation     — every zone named by an installed module config's
//      consistency       `zone`/`zone0` field exists and is Active.
//
// Exit code: 0 if no errors (warnings allowed); non-zero only on hard errors.
// `--strict` promotes warnings to errors. NEVER writes zones.json.
//
// Dependency-free TS (strict tsc, ambient env.d.ts), mirroring the rest of the
// component.

import { existsSync, readdirSync, readFileSync } from "fs";
import { join } from "path";
import { Zone, ZonesDoc } from "./types";
import { loadZones } from "./zones";

const YW = "\x1b[01;33m";
const RD = "\x1b[01;31m";
const GN = "\x1b[1;92m";
const CL = "\x1b[0m";

// A zone is considered "active" for reference/installation purposes when its
// state is one that zone-manager actually provisions an interface for. Inactive
// / Disabled zones exist in the file but are not live.
function isActiveState(state: unknown): boolean {
  return state === "Active" || state === "Manual" || state === "Mandatory";
}

export interface CheckResult {
  // The accumulated, human-readable lines (printed by the CLI).
  lines: string[];
  warnings: number;
  errors: number;
}

interface Reporter {
  ok(msg: string): void;
  note(msg: string): void; // informational; never a warning/error
  warn(msg: string): void;
  err(msg: string): void;
}

function makeReporter(strict: boolean): { rep: Reporter; result: CheckResult } {
  const result: CheckResult = { lines: [], warnings: 0, errors: 0 };
  const rep: Reporter = {
    ok(msg) {
      result.lines.push(`  ${GN}✓${CL} ${msg}`);
    },
    note(msg) {
      result.lines.push(`  ${YW}·${CL} ${msg}`);
    },
    warn(msg) {
      // --strict promotes a warning to a hard error.
      if (strict) {
        result.errors++;
        result.lines.push(`  ${RD}✗${CL} ${msg} (warning→error under --strict)`);
      } else {
        result.warnings++;
        result.lines.push(`  ${YW}!${CL} ${msg}`);
      }
    },
    err(msg) {
      result.errors++;
      result.lines.push(`  ${RD}✗${CL} ${msg}`);
    },
  };
  return { rep, result };
}

// ── module-config zone-field discovery ───────────────────────────────
// A module JSON may name the zone it deploys into via `zone` (current) or
// `zone0` (historical). Returns the zone name (preferring `zone`) or undefined.
function moduleZoneField(cfg: Record<string, unknown>): string | undefined {
  const z = cfg["zone"];
  if (typeof z === "string" && z.length > 0) return z;
  const z0 = cfg["zone0"];
  if (typeof z0 === "string" && z0.length > 0) return z0;
  return undefined;
}

interface ModuleRef {
  file: string; // basename of the config
  zone: string; // the zone it names
}

// The set of zone names occupied by installed module configs (zone/zone0).
// Used by zones-init to avoid inactivating a zone that still has tenants.
export function occupiedZones(configDir: string): Set<string> {
  return new Set(scanModuleConfigs(configDir).map((r) => r.zone));
}

// Scan a config dir for *.json module configs that carry a zone/zone0 field.
// Skips zones.json itself and any non-module schema files (site.json,
// configuration.json, module-fields.json) which never carry a module `zone`.
function scanModuleConfigs(configDir: string): ModuleRef[] {
  const refs: ModuleRef[] = [];
  if (!existsSync(configDir)) return refs;
  let entries: string[];
  try {
    entries = readdirSync(configDir);
  } catch {
    return refs;
  }
  for (const name of entries.sort()) {
    if (!name.endsWith(".json")) continue;
    if (name === "zones.json") continue;
    const path = join(configDir, name);
    let cfg: unknown;
    try {
      cfg = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      // A non-parseable JSON is not this check's concern; skip silently.
      continue;
    }
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) continue;
    const zone = moduleZoneField(cfg as Record<string, unknown>);
    if (zone === undefined) continue;
    refs.push({ file: name, zone });
  }
  return refs;
}

// ── the individual checks (each appends to the reporter) ──────────────

// 1. Well-formed: zones present + each has the core fields.
function checkWellFormed(doc: ZonesDoc, rep: Reporter): void {
  const names = Array.from(doc.zones.keys());
  if (names.length === 0) {
    rep.err("well-formed: zones.json contains no zones");
    return;
  }
  let missing = 0;
  for (const [name, z] of doc.zones) {
    if (z.state === undefined) {
      rep.err(`well-formed: zone '${name}' has no 'state' field`);
      missing++;
      continue;
    }
    const lacks: string[] = [];
    if (z["access-to"] === undefined) lacks.push("access-to");
    if (z.ip === undefined) lacks.push("ip");
    if (z.subId === undefined) lacks.push("subId");
    if (lacks.length > 0) {
      rep.warn(`well-formed: zone '${name}' missing ${lacks.join(", ")}`);
      missing++;
    }
  }
  if (missing === 0) {
    rep.ok(`well-formed: ${names.length} zone(s), all carry the core fields`);
  } else {
    rep.note(`well-formed: ${names.length} zone(s) parsed`);
  }
}

// 2. VLAN/subId uniqueness: no duplicate vlantag; no duplicate subId within a
//    type band (typeId). vlantag 0 (mgmt/overlay sentinels) is exempt — several
//    Manual non-VLAN zones legitimately carry vlantag 0.
function checkUniqueness(doc: ZonesDoc, rep: Reporter): void {
  const byVlan = new Map<number, string[]>();
  const bySub = new Map<string, string[]>(); // key: `${typeId}/${subId}`
  for (const [name, z] of doc.zones) {
    if (typeof z.vlantag === "number" && z.vlantag !== 0) {
      const arr = byVlan.get(z.vlantag) ?? [];
      arr.push(name);
      byVlan.set(z.vlantag, arr);
    }
    if (z.typeId !== undefined && z.subId !== undefined) {
      const key = `${String(z.typeId)}/${String(z.subId)}`;
      const arr = bySub.get(key) ?? [];
      arr.push(name);
      bySub.set(key, arr);
    }
  }
  let collisions = 0;
  for (const [tag, zs] of byVlan) {
    if (zs.length > 1) {
      rep.err(`uniqueness: VLAN tag ${tag} shared by ${zs.sort().join(", ")}`);
      collisions++;
    }
  }
  for (const [key, zs] of bySub) {
    if (zs.length > 1) {
      const [typeId, subId] = key.split("/");
      rep.err(`uniqueness: subId ${subId} reused in type band ${typeId} by ${zs.sort().join(", ")}`);
      collisions++;
    }
  }
  if (collisions === 0) {
    rep.ok("uniqueness: VLAN tags and per-band subIds are unique");
  }
}

// 3. Referential integrity: access-to / pinhole-allowed-from refs resolve.
function checkReferentialIntegrity(doc: ZonesDoc, rep: Reporter): void {
  let dangling = 0;
  let inactiveRefs = 0;
  const REF_FIELDS: (keyof Zone)[] = ["access-to", "pinhole-allowed-from"];
  for (const [name, z] of doc.zones) {
    for (const field of REF_FIELDS) {
      const arr = z[field];
      if (!Array.isArray(arr)) continue;
      for (const ref of arr) {
        if (typeof ref !== "string") continue;
        if (ref === "internet") continue;
        const target = doc.zones.get(ref);
        if (target === undefined) {
          rep.err(`refs: zone '${name}' ${String(field)} references unknown zone '${ref}'`);
          dangling++;
        } else if (!isActiveState(target.state)) {
          // An Inactive ref is allowed but worth noting.
          rep.note(`refs: zone '${name}' ${String(field)} references Inactive zone '${ref}'`);
          inactiveRefs++;
        }
      }
    }
  }
  if (dangling === 0) {
    if (inactiveRefs === 0) {
      rep.ok("refs: all access-to / pinhole-allowed-from references resolve");
    } else {
      rep.ok(`refs: all references resolve (${inactiveRefs} point at Inactive zone(s) — see notes)`);
    }
  }
}

// 4. mgmt invariant: a mgmt zone exists and is Active.
function checkMgmtInvariant(doc: ZonesDoc, rep: Reporter): void {
  const mgmt = doc.zones.get("mgmt");
  if (mgmt === undefined) {
    rep.err("mgmt: no 'mgmt' zone defined (the control plane is mandatory)");
    return;
  }
  if (!isActiveState(mgmt.state)) {
    rep.err(`mgmt: 'mgmt' zone exists but is not Active (state='${String(mgmt.state)}')`);
    return;
  }
  rep.ok(`mgmt: control-plane zone present and active (state='${String(mgmt.state)}')`);
}

// 5. Installation consistency: each module config's zone resolves + is Active.
function checkInstallation(doc: ZonesDoc, configDir: string, rep: Reporter): void {
  const refs = scanModuleConfigs(configDir);
  if (refs.length === 0) {
    rep.note(`install: no module configs with a zone/zone0 field under ${configDir}`);
    return;
  }
  let bad = 0;
  for (const ref of refs) {
    const target = doc.zones.get(ref.zone);
    if (target === undefined) {
      rep.err(`install: module '${ref.file}' deploys into zone '${ref.zone}' which does not exist`);
      bad++;
    } else if (!isActiveState(target.state)) {
      rep.err(
        `install: module '${ref.file}' deploys into zone '${ref.zone}' which is not Active (state='${String(target.state)}')`,
      );
      bad++;
    }
  }
  if (bad === 0) {
    rep.ok(`install: all ${refs.length} module config zone reference(s) exist and are active`);
  }
}

export interface ZonesCheckOpts {
  zonesFile: string;
  configDir: string;
  strict: boolean;
}

// Run every check against an already-loaded doc + config dir. Pure (no I/O on
// zones.json; reads module configs read-only). Returns the accumulated result.
export function runChecks(doc: ZonesDoc, configDir: string, strict: boolean): CheckResult {
  const { rep, result } = makeReporter(strict);
  checkWellFormed(doc, rep);
  checkUniqueness(doc, rep);
  checkReferentialIntegrity(doc, rep);
  checkMgmtInvariant(doc, rep);
  checkInstallation(doc, configDir, rep);
  return result;
}

// CLI entry: load zones.json (READ-ONLY), run the checks, print the summary.
// Returns the process exit code (0 ok, 1 on hard errors).
export function zonesCheck(
  opts: ZonesCheckOpts,
  log: (msg: string) => void,
): number {
  let doc: ZonesDoc;
  try {
    doc = loadZones(opts.zonesFile);
  } catch (e) {
    log(`  ${RD}✗${CL} well-formed: ${(e as Error).message}`);
    log(`zones-check: 0 ok, 0 warning(s), 1 error(s)`);
    return 1;
  }

  log(`zones-check: ${opts.zonesFile} (config-dir ${opts.configDir})`);
  const result = runChecks(doc, opts.configDir, opts.strict);
  for (const line of result.lines) log(line);

  const okCount = result.lines.filter((l) => l.includes("✓")).length;
  log(
    `zones-check: ${okCount} ok, ${result.warnings} warning(s), ${result.errors} error(s)`,
  );
  return result.errors > 0 ? 1 : 0;
}
