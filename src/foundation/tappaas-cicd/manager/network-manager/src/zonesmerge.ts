// zonesmerge.ts — the rename-aware 3-way zones.json reconciliation (ADR-007
// "Design A"). This is the TypeScript port of the legacy apply-zones-merge.sh
// (#209), made rename-aware by materialising the repo template into THIS
// installation's renamed namespace as a third file before merging.
//
// Three files in ${CONFIG_DIR}, all keyed by zone name:
//   - current  = zones.json        (live, renamed namespace, e.g. myOrg)
//   - baseline = zones.json.orig    (the version of source `current` last merged from)
//   - source   = zones.rename.json  (the repo template with this install's rename
//                                    applied — regenerated each run; never re-adds
//                                    srv/home/guest because they are renamed away)
//
// Flow (every update-tappaas, replacing apply-zones-merge.sh):
//   1. read the repo template → apply the §B rename (name from site.json .name)
//      → (re)write zones.rename.json. This re-bases upstream into the renamed
//      namespace, reflecting any release changes.
//   2. 3-way merge current vs baseline vs source with the ported rules.
//   3. write merged → zones.json; advance zones.json.orig ← zones.rename.json.
//
// Merge rules (preserved exactly from apply-zones-merge.sh):
//   Per-field within a zone present in BOTH current and source:
//     - `state` is an AUTO_FIELD: operator-pinned, NEVER adopted from source.
//     - every other field: current==orig → adopt source; else pin current.
//   Zone-level:
//     - in source, absent in current → ADD (release introduced a new zone).
//     - in current, absent in source → KEEP + warn (operator-added or
//       release-removed but the operator still wants it; the documented
//       one-time surgical cleanup of stale srv/home/guest is NOT the merge's job).
//     - same vlantag, different name → flag a possible rename; do NOT auto-rename.
//   Backfill: if baseline (.orig) is missing, treat source as the baseline (so a
//     first merge pins operator customizations).
//
// Dependency-free TS (strict tsc, ambient env.d.ts), mirroring the rest of the
// component.

import { existsSync, readFileSync, writeFileSync, renameSync, mkdtempSync } from "fs";
import { dirname, join } from "path";

// Operator-pinned fields per zone — never adopted from the release source (#209).
const AUTO_FIELDS = new Set<string>(["state"]);

function isDocKey(k: string): boolean {
  return k.startsWith("_");
}

// A parsed zones document: the full raw object (doc blocks included). Unlike
// zones.ts's loadZones we keep EVERYTHING (incl. "_*") so writes round-trip the
// doc blocks; the merge only treats object-valued non-"_*" keys as zones.
type Raw = Record<string, unknown>;

function parseFile(file: string): Raw {
  const txt = readFileSync(file, "utf8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(txt);
  } catch (e) {
    throw new Error(`not valid JSON: ${file} (${(e as Error).message})`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`must be a JSON object: ${file}`);
  }
  return parsed as Raw;
}

// Is `v` a zone object (vs a "_*" doc block or a scalar/array)?
function isZoneObject(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// Deep value equality for leaf comparison (strings/numbers/bools/null and
// arrays-as-whole, mirroring the jq "arrays compared whole" rule). Objects are
// not expected at the field level inside a zone, but compared structurally for
// safety.
function valueEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((x, i) => valueEqual(x, b[i]));
  }
  if (isZoneObject(a) && isZoneObject(b)) {
    const ak = Object.keys(a);
    const bk = Object.keys(b);
    if (ak.length !== bk.length) return false;
    return ak.every((k) => k in b && valueEqual(a[k], b[k]));
  }
  return false;
}

export interface ZoneFieldDiff {
  zone: string;
  fields: string[];
}

export interface MergeReport {
  // The merged document (ready to serialise).
  merged: Raw;
  // Zones only in source → added with release defaults.
  added: string[];
  // Zones only in current → kept (operator-added / release-removed); warned.
  keptOrphan: string[];
  // Per-zone fields where a source change was adopted (current==orig).
  adopted: ZoneFieldDiff[];
  // Per-zone fields where current was pinned over a differing source value.
  pinned: ZoneFieldDiff[];
  // Possible renames: same vlantag, different name across current/source.
  renames: { vlantag: number; current: string; source: string }[];
}

// Merge a single zone present in BOTH current and source (orig may be absent).
// Walks the UNION of field keys; applies the per-field rule. Returns the merged
// zone plus the adopted/pinned field names for the report.
function mergeZone(
  cz: Record<string, unknown>,
  oz: Record<string, unknown> | undefined,
  sz: Record<string, unknown>,
): { zone: Record<string, unknown>; adopted: string[]; pinned: string[] } {
  const fields = new Set<string>([
    ...Object.keys(cz),
    ...(oz ? Object.keys(oz) : []),
    ...Object.keys(sz),
  ]);
  const out: Record<string, unknown> = {};
  const adopted: string[] = [];
  const pinned: string[] = [];

  for (const f of fields) {
    const inC = f in cz;
    const inS = f in sz;
    const inO = oz !== undefined && f in oz;
    const cv = cz[f];
    const sv = sz[f];
    const ov = oz ? oz[f] : undefined;

    if (AUTO_FIELDS.has(f)) {
      // state: always keep current (if current has it; else nothing to set).
      if (inC) out[f] = cv;
      else if (inS) out[f] = sv; // current lacks it but source defines it → take source
      continue;
    }
    if (!inS && inC) {
      // field removed upstream but present in current → keep current.
      out[f] = cv;
      continue;
    }
    if (!inC && inS) {
      // new field from source → adopt.
      out[f] = sv;
      if (!valueEqual(sv, cv)) adopted.push(f);
      continue;
    }
    // present in both current and source.
    if (inO && valueEqual(cv, ov)) {
      // current unchanged from baseline → adopt source.
      out[f] = sv;
      if (!valueEqual(sv, cv)) adopted.push(f);
    } else {
      // operator edited it (current != orig, or no baseline) → pin current.
      out[f] = cv;
      if (inS && !valueEqual(sv, cv)) pinned.push(f);
    }
  }
  return { zone: out, adopted, pinned };
}

function zoneNames(raw: Raw): string[] {
  return Object.keys(raw).filter((k) => !isDocKey(k) && isZoneObject(raw[k]));
}

// Compute the 3-way merge. Pure: no I/O. current/baseline/source are raw docs.
export function mergeZones(current: Raw, baseline: Raw, source: Raw): MergeReport {
  const merged: Raw = {};
  // Carry current's doc blocks (e.g. _README) through untouched.
  for (const [k, v] of Object.entries(current)) {
    if (isDocKey(k)) merged[k] = v;
  }

  const added: string[] = [];
  const keptOrphan: string[] = [];
  const adopted: ZoneFieldDiff[] = [];
  const pinned: ZoneFieldDiff[] = [];

  const cNames = zoneNames(current);
  const sNames = zoneNames(source);
  const allNames = Array.from(new Set<string>([...cNames, ...sNames]));

  for (const z of allNames) {
    const inC = cNames.includes(z);
    const inS = sNames.includes(z);
    if (inC && inS) {
      const r = mergeZone(
        current[z] as Record<string, unknown>,
        isZoneObject(baseline[z]) ? (baseline[z] as Record<string, unknown>) : undefined,
        source[z] as Record<string, unknown>,
      );
      merged[z] = r.zone;
      if (r.adopted.length) adopted.push({ zone: z, fields: r.adopted });
      if (r.pinned.length) pinned.push({ zone: z, fields: r.pinned });
    } else if (inC) {
      // Only in current — kept (operator-added or release-removed).
      merged[z] = current[z];
      keptOrphan.push(z);
    } else {
      // Only in source — added.
      merged[z] = source[z];
      added.push(z);
    }
  }

  // Rename detection: same vlantag (>0) under different names across the two.
  const renames: { vlantag: number; current: string; source: string }[] = [];
  const cByVlan = vlanMap(current, cNames);
  const sByVlan = vlanMap(source, sNames);
  for (const [vt, cName] of cByVlan) {
    const sName = sByVlan.get(vt);
    if (sName !== undefined && sName !== cName) {
      renames.push({ vlantag: vt, current: cName, source: sName });
    }
  }

  return { merged, added, keptOrphan, adopted, pinned, renames };
}

function vlanMap(raw: Raw, names: string[]): Map<number, string> {
  const m = new Map<number, string>();
  for (const n of names) {
    const z = raw[n] as Record<string, unknown>;
    const vt = z["vlantag"];
    if (typeof vt === "number" && vt > 0 && !m.has(vt)) m.set(vt, n);
  }
  return m;
}

// ── orchestration (I/O) ───────────────────────────────────────────────

export interface ZonesMergeOpts {
  current: string; // zones.json
  orig: string; // zones.json.orig
  rename: string; // zones.rename.json (the materialised source)
  template: string; // repo template (org-agnostic; ships srv/home/guest)
  name: string; // installation/site name (rename target)
  keepActive?: ReadonlySet<string>; // occupancy guard for the rename
  diff?: boolean; // show changes, write nothing
}

export interface Logger {
  info(msg: string): void;
  warn(msg: string): void;
}

// Atomic JSON write (temp in the SAME dir → rename), mirroring zones.ts.
function writeJsonAtomic(file: string, raw: Raw, indent: number): void {
  const text = JSON.stringify(raw, null, indent) + "\n";
  JSON.parse(text); // defence in depth
  const dir = dirname(file);
  const tmpDir = mkdtempSync(join(dir, ".zones-merge-"));
  const tmp = join(tmpDir, "zones.json");
  writeFileSync(tmp, text, "utf8");
  renameSync(tmp, file);
}

// Run the rename-aware 3-way merge. Returns the merge exit code (0 success).
// Reuses the shared rename transform via renameTemplateFile so init and merge
// cannot diverge. Imported here to keep the dependency direction one-way.
export function runZonesMerge(
  opts: ZonesMergeOpts,
  log: Logger,
  renameTransform: (templateFile: string, name: string, keepActive: ReadonlySet<string>) => Raw,
): number {
  // 1. (re)materialise the renamed source from the repo template.
  let renamedRaw: Raw;
  try {
    renamedRaw = renameTransform(opts.template, opts.name, opts.keepActive ?? new Set<string>());
  } catch (e) {
    log.warn(`zones-merge: cannot build renamed source from template: ${(e as Error).message}`);
    return 1;
  }
  if (!opts.diff) {
    writeJsonAtomic(opts.rename, renamedRaw, 4);
  }
  const source = renamedRaw;

  // 2. read current; backfill baseline from source if absent.
  if (!existsSync(opts.current)) {
    log.warn(`zones-merge: current zones.json not found: ${opts.current}`);
    return 1;
  }
  let current: Raw;
  try {
    current = parseFile(opts.current);
  } catch (e) {
    log.warn(`zones-merge: ${(e as Error).message}`);
    return 1;
  }

  let baseline: Raw;
  let backfilled = false;
  if (existsSync(opts.orig)) {
    try {
      baseline = parseFile(opts.orig);
    } catch (e) {
      log.warn(`zones-merge: ${(e as Error).message}`);
      return 1;
    }
  } else {
    // Backfill: treat source as baseline (first-merge pins operator edits).
    baseline = source;
    backfilled = true;
    log.info("  No zones.json.orig present — backfilling from renamed source");
  }

  // 3. merge.
  const r = mergeZones(current, baseline, source);

  const nAdopted = r.adopted.reduce((a, d) => a + d.fields.length, 0);
  const nPinned = r.pinned.reduce((a, d) => a + d.fields.length, 0);
  log.info(
    `  Merge: ${nAdopted} adopted, ${nPinned} pinned, ${r.added.length} added, ${r.keptOrphan.length} kept (orphan), ${r.renames.length} possible rename(s)`,
  );
  if (r.added.length) log.info(`    added (new in release): ${r.added.join(", ")}`);
  if (r.keptOrphan.length) {
    log.warn("    kept (in current but not in source — operator-added or release-removed):");
    for (const z of r.keptOrphan) log.warn(`      - ${z}`);
  }
  if (r.pinned.length) {
    log.info("    pinned (operator customizations preserved):");
    for (const d of r.pinned) log.info(`      ${d.zone}: ${d.fields.join(", ")}`);
  }
  if (r.adopted.length) {
    log.info("    adopted (release changes applied):");
    for (const d of r.adopted) log.info(`      ${d.zone}: ${d.fields.join(", ")}`);
  }
  if (r.renames.length) {
    log.warn("    possible rename(s) — same vlantag, different zone name:");
    for (const rn of r.renames) {
      log.warn(`      vlantag=${rn.vlantag}: source=${rn.source} vs current=${rn.current}`);
    }
    log.warn("      (no auto-rename — review and rename manually if appropriate)");
  }

  // 4. diff mode: stop here.
  if (opts.diff) {
    log.info("  --diff: no changes written");
    return 0;
  }

  // 5. write merged current (only if it changed) + advance baseline ← source.
  const before = existsSync(opts.current) ? readFileSync(opts.current, "utf8") : "";
  const mergedText = JSON.stringify(r.merged, null, 4) + "\n";
  if (mergedText !== before) {
    writeJsonAtomic(opts.current, r.merged, 4);
    log.info(`  ✓ Wrote merged ${opts.current}`);
    log.info("    Apply on OPNsense via:");
    log.info(`      zone-manager --no-ssl-verify --zones-file ${opts.current} --execute`);
  }
  // Advance baseline regardless: future merges compare against the new release.
  writeJsonAtomic(opts.orig, source, 4);
  if (backfilled) log.info(`  Backfilled ${opts.orig} from renamed source`);

  return 0;
}
