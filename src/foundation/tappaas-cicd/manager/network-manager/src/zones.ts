// zones.ts — load + CRUD on zones.json (the desired network state network-manager
// owns). Ports the jq-based authoring in zone-controller.sh into typed,
// dependency-free TS.
//
// zones.json lives at ${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json (it
// does NOT move in this chunk). Doc blocks (keys beginning "_") are preserved
// across writes; only real zones are indexed.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { defaultConfigDir, writeJsonAtomic } from "../../../lib/ts/src/config-io";
import { Zone, ZonesDoc } from "./types";
import { archetypeByName, archetypeNames } from "./archetypes";

// Dynamic-allocation VLAN window within a type band (10.<typeId>.<sub>.0/24).
// Matches zone-controller.sh so zone choices are unchanged.
export const ZONE_SUB_MAX = 99;
export const ZONE_SUB_MIN = 60;

// Config-root resolution is the shared lib rule (TAPPAAS_CONFIG > CONFIG_DIR >
// /home/tappaas/config); re-exported so callers keep importing it from here.
export { defaultConfigDir };

export function defaultZonesFile(): string {
  return join(defaultConfigDir(), "zones.json");
}

// The 3-way-merge baseline file (the version of `source` that `current` was last
// merged from). Lives next to zones.json under ${CONFIG_DIR}.
export function defaultOrigFile(): string {
  return join(defaultConfigDir(), "zones.json.orig");
}

// The rename-applied source template (Design A's third file): the repo template
// with THIS installation's zones-init rename applied. Regenerated on demand by
// zones-init / zones-merge; never hand-edited. Lives under ${CONFIG_DIR}.
export function defaultRenameFile(): string {
  return join(defaultConfigDir(), "zones.rename.json");
}

// Resolve the default-environment name — the slug zones-init/zones-merge rename
// `srv` to — from ${CONFIG_DIR}/site.json's `.defaultEnvironment` (#426: the
// zone/env name, decoupled from the neutral site code `.name`; a pre-#426
// site.json falls back to `.name`, which WAS the org/env name). Merge MUST resolve
// the same name init used, or it would rename into a different namespace. Throws a
// clear error if site.json is missing / unreadable / names nothing.
export function readSiteName(configDir: string = defaultConfigDir()): string {
  const site = join(configDir, "site.json");
  if (!existsSync(site)) {
    throw new Error(
      `site.json not found: ${site} — cannot resolve the default-environment name for the zones rename`,
    );
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(site, "utf8"));
  } catch (e) {
    throw new Error(`site.json is not valid JSON: ${site} (${(e as Error).message})`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`site.json must be a JSON object: ${site}`);
  }
  const rec = parsed as Record<string, unknown>;
  const def = rec["defaultEnvironment"];
  const name = rec["name"];
  const resolved =
    typeof def === "string" && def.length > 0
      ? def
      : typeof name === "string" && name.length > 0
        ? name
        : undefined;
  if (resolved === undefined) {
    throw new Error(`site.json has no string '.defaultEnvironment' or '.name' field: ${site}`);
  }
  return resolved;
}

// The distributed zones.json TEMPLATE shipped alongside the bin. The compiled
// entry (main.js) lives at <out>/lib/manager/network-manager/src/main.js and
// the nix postInstall copies zones.json next to it; __dirname therefore
// resolves the template via the bin's REAL dir (node follows the
// /home/tappaas/bin symlink), exactly as the component locates its own assets.
// An override is allowed for tests / source-tree runs via NM_TEMPLATE.
export function defaultTemplateFile(): string {
  return process.env.NM_TEMPLATE ?? join(__dirname, "zones.json");
}

// Doc-block / comment keys ("_comment" etc.): never treated as zones.
// Shared by zonesinit.ts and zonesmerge.ts.
export function isDocKey(k: string): boolean {
  return k.startsWith("_");
}

// Load + index zones.json. Throws if the file is missing or not valid JSON.
export function loadZones(file: string): ZonesDoc {
  if (!existsSync(file)) {
    throw new Error(`zones.json not found: ${file}`);
  }
  const txt = readFileSync(file, "utf8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(txt);
  } catch (e) {
    throw new Error(`zones.json is not valid JSON: ${file} (${(e as Error).message})`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`zones.json must be a JSON object: ${file}`);
  }
  const raw = parsed as Record<string, unknown>;
  const zones = new Map<string, Zone>();
  for (const [k, v] of Object.entries(raw)) {
    if (isDocKey(k)) continue;
    if (v === null || typeof v !== "object" || Array.isArray(v)) continue;
    const o = v as Record<string, unknown>;
    // Only treat entries that look like real zones (have a state or vlantag),
    // matching the jq-based bash tooling's selection rule.
    if (!("state" in o) && !("vlantag" in o)) continue;
    zones.set(k, { ...(o as Zone), name: k });
  }
  return { raw, zones };
}

// Atomically write the raw document back (temp → rename via the shared
// config-io helper), mirroring zone-controller.sh's jq_write safety.
export function saveZones(file: string, doc: ZonesDoc): void {
  writeJsonAtomic(file, doc.raw);
}

export function zoneExists(doc: ZonesDoc, name: string): boolean {
  return doc.zones.has(name);
}

export function getZone(doc: ZonesDoc, name: string): Zone | undefined {
  return doc.zones.get(name);
}

export function listZoneNames(doc: ZonesDoc): string[] {
  return Array.from(doc.zones.keys()).sort();
}

// ── allocation helpers (port of zone-controller.sh) ──────────────────
function vlanInUse(doc: ZonesDoc, tag: number): boolean {
  for (const z of doc.zones.values()) {
    if (typeof z.vlantag === "number" && z.vlantag === tag) return true;
  }
  return false;
}

// Allocate a VLAN tag in band typeId (highest free sub in [MIN,MAX]).
export function allocateVlan(doc: ZonesDoc, typeId: number): number {
  for (let s = ZONE_SUB_MAX; s >= ZONE_SUB_MIN; s--) {
    const vt = typeId * 100 + s;
    if (!vlanInUse(doc, vt)) return vt;
  }
  throw new Error(
    `No free VLAN in type ${typeId} (${typeId}${ZONE_SUB_MIN}-${typeId}${ZONE_SUB_MAX} all used)`,
  );
}

export interface AddZoneOpts {
  fromZone?: string;
  type?: string;
  typeId?: string;
  vlan?: number;
  variant?: string;
  // ADR-014 D5/D3: stamp type/typeId/tier/isolated + the access-to seed from a
  // named archetype instead of copy-pasting a template block. Subsumes D3's
  // `--class` for IoT.
  archetype?: string;
  // ADR-014 D2: bind the new Client/IoT/Guest zone to an environment in the
  // same command.
  serves?: string;
}

// Author a new zone entry into the doc (in memory; caller persists). Ports
// cmd_add's template-resolution + VLAN allocation + entry authoring +
// mgmt.access-to invariant. Returns the created Zone.
export function authorZone(doc: ZonesDoc, name: string, opts: AddZoneOpts): Zone {
  if (!/^[a-z][a-zA-Z0-9]*$/.test(name)) {
    throw new Error(
      `zone name '${name}' must be camelCase (^[a-z][a-zA-Z0-9]*$, no hyphens — see #278)`,
    );
  }
  if (zoneExists(doc, name)) {
    throw new Error(`Zone '${name}' already exists`);
  }

  let typeId: string;
  let type: string;
  let bridge: string;
  let accessTo: string[];
  let pinhole: string[];
  let parent = "";
  let tier: number | undefined;
  let isolated = false;

  if (opts.archetype) {
    // Archetype wins over the low-level knobs; main.ts rejects the combination
    // up front, so reaching here with both is a programming error.
    const a = archetypeByName(opts.archetype);
    if (!a) {
      throw new Error(
        `unknown archetype '${opts.archetype}' (known: ${archetypeNames().join(", ")})`,
      );
    }
    type = a.type;
    typeId = String(a.typeId);
    bridge = "lan";
    accessTo = [...a.accessTo];
    pinhole = [];
    tier = a.tier;
    isolated = a.isolated;
  } else if (opts.fromZone) {
    const src = getZone(doc, opts.fromZone);
    if (!src) throw new Error(`--from-zone '${opts.fromZone}' not found`);
    typeId = opts.typeId ?? String(src.typeId ?? "");
    type = opts.type ?? String(src.type ?? "");
    bridge = typeof src.bridge === "string" ? src.bridge : "lan";
    accessTo = Array.isArray(src["access-to"]) ? [...(src["access-to"] as string[])] : [];
    pinhole = Array.isArray(src["pinhole-allowed-from"])
      ? [...(src["pinhole-allowed-from"] as string[])]
      : [];
    parent = opts.fromZone;
  } else {
    typeId = opts.typeId ?? "2";
    type = opts.type ?? "Service";
    bridge = "lan";
    accessTo = ["internet", "dmz"];
    pinhole = [];
  }

  if (!/^[0-9]+$/.test(typeId)) {
    throw new Error(`typeId must be numeric (got '${typeId}')`);
  }
  const typeIdNum = parseInt(typeId, 10);

  let vt: number;
  if (opts.vlan !== undefined) {
    vt = opts.vlan;
    if (!Number.isInteger(vt)) throw new Error("--vlan must be numeric");
    if (vlanInUse(doc, vt)) throw new Error(`VLAN ${vt} is already in use`);
  } else {
    vt = allocateVlan(doc, typeIdNum);
  }
  const sub = vt % 100;
  const ip = `10.${typeIdNum}.${sub}.0/24`;
  const variant = opts.variant ?? "";
  const arch = opts.archetype ? archetypeByName(opts.archetype) : undefined;
  const descr = variant
    ? `Variant zone for ${variant}${parent ? ` (inherited from ${parent})` : ""}`
    : arch
      ? arch.description
      : `Zone ${name}${parent ? ` (inherited from ${parent})` : ""}`;

  const zone: Zone = {
    name,
    type,
    typeId,
    subId: String(sub),
    vlantag: vt,
    ip,
    bridge,
    state: "Active",
    "access-to": accessTo,
    "pinhole-allowed-from": pinhole,
    description: descr,
  };
  // ADR-014: only stamp the security fields when an archetype supplied them —
  // a --from-zone/--type zone stays untiered (validate notes it) rather than
  // being given a guessed rank.
  if (tier !== undefined) zone.tier = tier;
  if (isolated) zone.isolated = true;
  if (opts.serves) zone.serves = opts.serves;
  if (parent) zone.parent = parent;
  if (variant) zone.variant = variant;

  doc.raw[name] = stripName(zone);
  doc.zones.set(name, zone);
  ensureMgmtAccess(doc, name);
  return zone;
}

// Remove a zone from the doc (in memory). Ports cmd_delete's key removal +
// mgmt.access-to invariant cleanup. Returns the deleted zone's vlantag (if any).
export function removeZone(doc: ZonesDoc, name: string): number | undefined {
  const z = getZone(doc, name);
  if (!z) throw new Error(`Zone '${name}' not found`);
  const vt = typeof z.vlantag === "number" ? z.vlantag : undefined;
  removeMgmtAccess(doc, name);
  delete doc.raw[name];
  doc.zones.delete(name);
  return vt;
}

// Set a zone's state (in memory). Used by the delete lifecycle (→ "Disabled"
// before the OPNsense reconcile drops its interface).
export function setZoneState(doc: ZonesDoc, name: string, state: string): void {
  const z = getZone(doc, name);
  if (!z) throw new Error(`Zone '${name}' not found`);
  z.state = state;
  const rawZone = doc.raw[name];
  if (rawZone && typeof rawZone === "object") {
    (rawZone as Record<string, unknown>).state = state;
  }
}

// ── operator state verbs (port of zone-state.sh, #209) ────────────────
// enable/disable/manual flip a zone's `state` field with the transition
// guards; "Mandatory" and "Disabled" are intentionally NOT exposed as verbs
// (Mandatory is the platform security model; Disabled is reserved for the
// delete lifecycle).
export const STATE_VERBS: Record<string, string> = {
  enable: "Active",
  disable: "Inactive",
  manual: "Manual",
};

export interface StateChange {
  from: string;
  to: string;
  changed: boolean; // false ⇒ already in the target state (no-op)
}

// Guarded state change (in memory; caller persists when `changed`). Throws on
// an unknown verb, an unknown zone, a zone without a `state` field, or on
// leaving "Mandatory" without force — exactly zone-state.sh's contract.
export function changeZoneState(
  doc: ZonesDoc,
  name: string,
  verb: string,
  force = false,
): StateChange {
  const to = STATE_VERBS[verb];
  if (!to) {
    throw new Error(`unknown state verb '${verb}' (expected enable|disable|manual)`);
  }
  const z = getZone(doc, name);
  if (!z) {
    throw new Error(
      `Zone '${name}' not found (known zones: ${listZoneNames(doc).join(", ")})`,
    );
  }
  const from = typeof z.state === "string" ? z.state : "";
  if (!from) throw new Error(`Zone '${name}' has no 'state' field`);
  if (from === to) return { from, to, changed: false };
  if (from === "Mandatory" && !force) {
    throw new Error(
      `Zone '${name}' is currently 'Mandatory' — refusing to change without --force ` +
        `(Mandatory zones, e.g. dmz, are required for the platform's security model)`,
    );
  }
  setZoneState(doc, name, to);
  return { from, to, changed: true };
}

// ── mgmt reachability invariant (#372/#373 — operational visibility) ──
// mgmt.access-to must list every standard zone so the control plane keeps
// operational visibility. Ports ensure_mgmt_access / remove_mgmt_access.
export function ensureMgmtAccess(doc: ZonesDoc, name: string): void {
  const mgmt = doc.raw["mgmt"];
  if (!mgmt || typeof mgmt !== "object") return;
  const m = mgmt as Record<string, unknown>;
  const cur = Array.isArray(m["access-to"]) ? (m["access-to"] as string[]) : [];
  if (cur.includes(name)) return;
  m["access-to"] = [...cur, name];
  const zm = doc.zones.get("mgmt");
  if (zm) zm["access-to"] = m["access-to"] as string[];
}

export function removeMgmtAccess(doc: ZonesDoc, name: string): void {
  const mgmt = doc.raw["mgmt"];
  if (!mgmt || typeof mgmt !== "object") return;
  const m = mgmt as Record<string, unknown>;
  const cur = Array.isArray(m["access-to"]) ? (m["access-to"] as string[]) : [];
  m["access-to"] = cur.filter((z) => z !== name);
  const zm = doc.zones.get("mgmt");
  if (zm) zm["access-to"] = m["access-to"] as string[];
}

// Drop the synthetic `name` key before persisting (it is the object key, not a
// stored field).
function stripName(z: Zone): Record<string, unknown> {
  const copy: Record<string, unknown> = { ...z };
  delete copy.name;
  return copy;
}
