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
//   6. Tier invariants  — the ADR-014 security gates I1-I4 (R1 monotonic
//      (I1-I4)            access-to, R2 isolation floor, egress boundary,
//                         archetype conformance). These promote what used to be
//                         the human `_README.pr_review_checklist` into code.
//                         WARN-only by default; `--strict` makes them errors.
//                         Nothing in the install or update path is wired to
//                         `--strict` — no check here can fail a deployment.
//
// Exit code: 0 if no errors (warnings allowed); non-zero only on hard errors.
// `--strict` promotes warnings to errors. NEVER writes zones.json.
//
// Dependency-free TS (strict tsc, ambient env.d.ts), mirroring the rest of the
// component.

import { existsSync, readdirSync, readFileSync } from "fs";
import { join } from "path";
import { CL, GN, RD, YW } from "../../../lib/ts/src/cli";
import { Zone, ZonesDoc } from "./types";
import { loadZones } from "./zones";
import { resolveServes } from "./serves";
import {
  CONTROL_PLANE_ZONE,
  TIER_INTERNET,
  archetypeForTriple,
  isTierExempt,
  zoneIsolated,
  zoneTier,
} from "./archetypes";

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

// ── 6. the ADR-014 tier invariants (I1-I4) ───────────────────────────
//
// All four are WARNINGS by default. A zone with no authored `tier` is reported
// once as a note and then skipped — an un-back-filled zones.json must not drown
// the operator in warnings for a field it has never had.
function checkTierInvariants(doc: ZonesDoc, rep: Reporter): void {
  // Index the tier of every zone that has one, and note the ones that do not.
  const tiers = new Map<string, number>();
  const untiered: string[] = [];
  for (const [name, z] of doc.zones) {
    if (isTierExempt(z.type)) continue; // Overlay / WAN are outside the model
    const t = zoneTier(z.tier);
    if (t === undefined) untiered.push(name);
    else tiers.set(name, t);
  }
  if (untiered.length > 0) {
    rep.note(
      `tier: ${untiered.length} zone(s) carry no 'tier' and are skipped by I1/I3/I4 ` +
        `(back-fill with \`add --archetype\` or a release update): ${untiered.sort().join(", ")}`,
    );
  }

  // Resolve a reference's tier: the literal "internet" is the boundary token;
  // an exempt or untiered target yields undefined (the edge is not checkable).
  const refTier = (ref: string): number | undefined =>
    ref === "internet" ? TIER_INTERNET : tiers.get(ref);

  // ── I1 — monotonic access-to: tier(A) <= tier(B), never upward. ──
  let i1 = 0;
  for (const [name, z] of doc.zones) {
    if (name === CONTROL_PLANE_ZONE) continue; // control plane reaches everything
    const from = tiers.get(name);
    if (from === undefined) continue;
    const arr = z["access-to"];
    if (!Array.isArray(arr)) continue;
    for (const ref of arr) {
      if (typeof ref !== "string" || ref === "all") continue;
      const to = refTier(ref);
      if (to === undefined) continue;
      if (from > to) {
        rep.warn(
          `I1: zone '${name}' (tier ${from}) has access-to '${ref}' (tier ${to}) — ` +
            `an UPWARD edge. Zone-wide access-to may only flow downward; express ` +
            `this as a per-module pinhole instead (add '${name}' to ` +
            `'${ref}'.pinhole-allowed-from and declare the IP/port rule in the module).`,
        );
        i1++;
      }
    }
  }
  if (i1 === 0) rep.ok("I1: every access-to edge flows downward (tier(A) <= tier(B))");

  // ── I2 — isolation floor: an isolated zone is in nobody's access-to. ──
  const isolated = new Set<string>();
  for (const [name, z] of doc.zones) {
    if (zoneIsolated(z.isolated)) isolated.add(name);
  }
  let i2 = 0;
  if (isolated.size > 0) {
    for (const [name, z] of doc.zones) {
      if (name === CONTROL_PLANE_ZONE) continue; // the documented exception
      const arr = z["access-to"];
      if (!Array.isArray(arr)) continue;
      for (const ref of arr) {
        if (typeof ref === "string" && isolated.has(ref)) {
          rep.warn(
            `I2: zone '${name}' has access-to isolated zone '${ref}' — this nullifies ` +
              `the pinhole mechanism (every host in '${name}' would gain unconditional ` +
              `zone-wide reach). Grant access per-module via ` +
              `'${ref}'.pinhole-allowed-from instead.`,
          );
          i2++;
        }
      }
    }
  }
  if (i2 === 0) {
    rep.ok(
      isolated.size === 0
        ? "I2: isolation floor holds (no zone is marked isolated)"
        : `I2: isolation floor holds (${isolated.size} isolated zone(s) reachable only by pinhole)`,
    );
  }

  // ── I3 — egress boundary: a tier-6 (no-egress) zone must not list internet. ──
  let i3 = 0;
  for (const [name, z] of doc.zones) {
    if (tiers.get(name) !== 6) continue;
    const arr = z["access-to"];
    if (Array.isArray(arr) && arr.includes("internet")) {
      rep.warn(
        `I3: zone '${name}' is tier 6 (no egress) but lists 'internet' in access-to — ` +
          `a zone whose devices need the internet is tier 3 (iot-cloud / iot-untrust), not tier 6.`,
      );
      i3++;
    }
  }
  if (i3 === 0) rep.ok("I3: no tier-6 (no-egress) zone claims internet egress");

  // ── I4 — archetype conformance on the (type, tier, isolated) triple. ──
  let i4 = 0;
  for (const [name, z] of doc.zones) {
    if (isTierExempt(z.type)) continue;
    const t = tiers.get(name);
    if (t === undefined) continue;
    const iso = zoneIsolated(z.isolated);
    if (archetypeForTriple(z.type, t, iso) === undefined) {
      rep.warn(
        `I4: zone '${name}' has (type=${String(z.type)}, tier=${t}, isolated=${iso}) — ` +
          `no archetype defines that combination, so the zone is configured against ` +
          `its declared intent. Correct the fields, or recreate it with ` +
          `\`add --archetype <A>\`.`,
      );
      i4++;
    }
  }
  if (i4 === 0) rep.ok("I4: every tiered zone conforms to a defined archetype");
}

// ── 7. `serves` link resolution (ADR-014 D2) ─────────────────────────
// A link that cannot resolve is a hard ERROR, not a warning: the derived edge
// simply would not exist, so the operator's declared reachability is silently
// absent. Same for `serves` on a zone type that must not carry it.
function checkServes(doc: ZonesDoc, configDir: string, rep: Reporter): void {
  const linked = Array.from(doc.zones.values()).filter(
    (z) => typeof z.serves === "string" && z.serves.length > 0,
  );
  if (linked.length === 0) {
    rep.note("serves: no zone declares a 'serves' link (pre-ADR-014, or all links are literal)");
    return;
  }
  const scratch: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(doc.raw)) {
    if (v !== null && typeof v === "object" && !Array.isArray(v)) {
      scratch[k] = { ...(v as Record<string, unknown>) };
    } else {
      scratch[k] = v;
    }
  }
  const r = resolveServes(doc, scratch, configDir);
  for (const e of r.errors) rep.err(`serves: ${e}`);
  if (r.errors.length === 0) {
    rep.ok(
      `serves: ${r.edges.length} link(s) resolve — ` +
        r.edges.map((e) => `${e.zone}→${e.environment}(${e.serviceZone})`).join(", "),
    );
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
  checkTierInvariants(doc, rep);
  checkServes(doc, configDir, rep);
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
