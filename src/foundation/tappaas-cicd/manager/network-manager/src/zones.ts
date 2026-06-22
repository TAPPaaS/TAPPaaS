// zones.ts — load + CRUD on zones.json (the desired network state network-manager
// owns). Ports the jq-based authoring in zone-controller.sh into typed,
// dependency-free TS.
//
// zones.json lives at ${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json (it
// does NOT move in this chunk). Doc blocks (keys beginning "_") are preserved
// across writes; only real zones are indexed.

import { existsSync, readFileSync, writeFileSync, renameSync, mkdtempSync } from "fs";
import { dirname, join } from "path";
import { Zone, ZonesDoc } from "./types";

// Dynamic-allocation VLAN window within a type band (10.<typeId>.<sub>.0/24).
// Matches zone-controller.sh / variant-manager so zone choices are unchanged.
export const ZONE_SUB_MAX = 99;
export const ZONE_SUB_MIN = 60;

export function defaultZonesFile(): string {
  const base = process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
  return join(base, "zones.json");
}

// The distributed zones.json TEMPLATE shipped alongside the bin. The compiled
// entry (main.js) lives at <out>/lib/main.js and the nix installPhase copies
// zones.json next to it (<out>/lib/zones.json); __dirname therefore resolves
// the template via the bin's REAL dir (node follows the /home/tappaas/bin
// symlink), exactly as the component locates its own assets. An override is
// allowed for tests / source-tree runs via NM_TEMPLATE.
export function defaultTemplateFile(): string {
  return process.env.NM_TEMPLATE ?? join(__dirname, "zones.json");
}

function isDocKey(k: string): boolean {
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

// Atomically write the raw document back (temp → validate-parse → rename),
// mirroring zone-controller.sh's jq_write safety.
export function saveZones(file: string, doc: ZonesDoc): void {
  const out = JSON.stringify(doc.raw, null, 2) + "\n";
  // Re-parse to confirm we are writing valid JSON (defence in depth).
  JSON.parse(out);
  const dir = dirname(file);
  const tmpDir = mkdtempSync(join(dir, ".zones-"));
  const tmp = join(tmpDir, "zones.json");
  writeFileSync(tmp, out, "utf8");
  renameSync(tmp, file);
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

  if (opts.fromZone) {
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
  const descr = variant
    ? `Variant zone for ${variant}${parent ? ` (inherited from ${parent})` : ""}`
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
