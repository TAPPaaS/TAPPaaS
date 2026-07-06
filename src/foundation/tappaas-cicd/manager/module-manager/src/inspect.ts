// inspect.ts — the read-only three-way drift report (`module reconcile` without
// --apply, and per-module inside `list --diff`): the native TS port of the
// retired inspect-vm.sh (ADR-007 post-implementation refactor, Phase 7.3).
//
// Generates a 3-column comparison table for a module's VM showing:
//   1. Released (Git)     — from the source module JSON (the module's .location)
//   2. Desired (~/config) — from config/<module>.json (deployed config)
//   3. Actual             — from the running VM via Proxmox (ssh qm/pvesh)
//
// Color coding (same rules as the bash):
//   Yellow — Desired differs from Released (config drift; counts a warning)
//   Red    — Actual differs from Desired  (VM drift; counts an error)
//
// A module WITHOUT a vmid (provider-only / non-VM module) degrades to a
// two-way Released-vs-Desired config diff (Actual = N/A) and still exits 0 —
// this is a report, not a failure. Drift never fails the command either (the
// bash exited 0 after printing the summary); only a missing config or an
// unreachable Proxmox node returns 1.
//
// STRUCTURE: everything above the I/O line is PURE (string/JSON in → lines +
// counters out) so the diff/render logic is unit-testable offline
// (test/unit/inspect.test.ts); inspectModule() at the bottom is the only part
// that touches the filesystem and ssh.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { mgmtDomain, ssh } from "../../../lib/ts/src/cluster";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { defaultConfigDir, normalizeModuleConfig } from "./config";
import { BL, BOLD, CL, GN, RD, YW, error, info, warn } from "./shlog";

// ── pure: jq-compatible field access ───────────────────────────────────
// `jq -r '.[$k] // empty'` semantics: missing / null / false → "", numbers and
// true → their string form, strings raw, containers as JSON.
export function jqStr(v: unknown): string {
  if (v === undefined || v === null || v === false) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return JSON.stringify(v);
}

export function getField(o: Record<string, unknown> | null, key: string): string {
  return o ? jqStr(o[key]) : "";
}

// ── pure: qm-config / vm-net helpers (ports of cluster/lib/vm-net.sh) ──

// Parse the `qm config <vmid>` key: value text into a map (the bash while-read
// loop; keys up to the first colon, values trimmed).
export function parseQmConfig(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const idx = line.indexOf(":");
    if (idx <= 0) continue;
    const key = line.slice(0, idx).trim();
    if (key) out[key] = line.slice(idx + 1).trim();
  }
  return out;
}

// Extract one field from a live `qm config` netN value, e.g.
// "virtio=02:..,bridge=lan,tag=210". The model=MAC token yields the mac.
const NIC_MODELS = new Set(["virtio", "e1000", "e1000e", "rtl8139", "vmxnet3"]);
export function vmnetParse(
  line: string,
  field: "mac" | "bridge" | "tag" | "trunks" | "queues",
): string {
  for (const part of line.split(",")) {
    const eq = part.indexOf("=");
    const k = eq === -1 ? part : part.slice(0, eq);
    const v = eq === -1 ? part : part.slice(eq + 1);
    if (field === "mac") {
      if (NIC_MODELS.has(k)) return v;
    } else if (k === field) {
      return v;
    }
  }
  return "";
}

// zones.json as parsed JSON (null when absent/unreadable — every lookup then
// resolves to "undefined zone", exactly as jq against a missing file did).
export type ZonesFile = Record<string, unknown> | null;

function zoneEntry(zones: ZonesFile, zone: string): Record<string, unknown> | null {
  if (!zones || !(zone in zones)) return null;
  const z = zones[zone];
  return z !== null && typeof z === "object" && !Array.isArray(z)
    ? (z as Record<string, unknown>)
    : {};
}

function zoneTag(entry: Record<string, unknown>): number {
  const t = entry.vlantag;
  return typeof t === "number" ? t : 0; // jq `.vlantag // 0`
}

// Resolve a zone name to its VLAN tag (vmnet_zone_vlantag). Returns null when
// the zone is undefined or Inactive (the bash returned rc 1; inspect-vm.sh
// discarded the error via `|| true` → empty value, which fmtVlan renders as
// "(untagged)").
export function vmnetZoneVlantag(zone: string, zones: ZonesFile): string | null {
  const entry = zoneEntry(zones, zone);
  if (!entry) return null;
  if (jqStr(entry.state) === "Inactive") return null;
  return String(zoneTag(entry));
}

// Every Active/Mandatory zone's non-zero tag, sorted, ';'-joined — the "ALL"
// trunk-sentinel expansion (vmnet_all_active_tags, issue #194).
export function vmnetAllActiveTags(zones: ZonesFile): string {
  if (!zones) return "";
  const tags: number[] = [];
  for (const v of Object.values(zones)) {
    if (v === null || typeof v !== "object" || Array.isArray(v)) continue;
    const entry = v as Record<string, unknown>;
    const state = jqStr(entry.state);
    if (state !== "Active" && state !== "Mandatory") continue;
    const tag = zoneTag(entry);
    if (tag > 0) tags.push(tag);
  }
  return [...new Set(tags)].sort((a, b) => a - b).map(String).join(";");
}

// Convert a ';'-separated list of trunk ZONE NAMES to VLAN tags
// (vmnet_resolve_trunks). "ALL"/"*" expands to every active zone tag. An
// UNDEFINED zone is an error → null (the bash returned 1 and inspect-vm.sh's
// `|| true` collapsed the value to ""). Non-trunkable (not
// Active/Mandatory/Manual) and untagged (vlantag<=0) zones are skipped —
// silently here: the bash warn lines were emitted INTO the command
// substitution and polluted the captured value (a latent bug this port fixes).
export function vmnetResolveTrunks(zoneList: string, zones: ZonesFile): string | null {
  if (zoneList === "ALL" || zoneList === "*") return vmnetAllActiveTags(zones);
  const out: string[] = [];
  for (const name of zoneList.split(";")) {
    if (!name) continue;
    const entry = zoneEntry(zones, name);
    if (!entry) return null; // undefined trunk zone (or no zones.json)
    const state = jqStr(entry.state);
    if (state !== "Active" && state !== "Mandatory" && state !== "Manual") continue;
    const tag = zoneTag(entry);
    if (tag <= 0) continue;
    out.push(String(tag));
  }
  return out.join(";");
}

// Proxmox tag=0 means untagged — collapse 0/""/missing to "(untagged)" so they
// never show up as spurious drift (issue #334).
export function fmtVlan(t: string): string {
  return !t || t === "0" ? "(untagged)" : t;
}

// Sort a ';'-separated VLAN list numerically and drop blanks, so resolved
// config trunks and the live trunk list compare equal regardless of order.
export function normTrunks(s: string): string {
  return s
    .split(";")
    .filter((x) => x !== "")
    .sort((a, b) => Number(a) - Number(b))
    .join(";");
}

// Proxmox stores tags semicolon-separated lowercase sorted — normalize both
// sides to that before comparing.
export function normalizeTags(s: string): string {
  return s
    .split(/[,;]/)
    .map((x) => x.toLowerCase())
    .filter(Boolean)
    .sort()
    .join(";");
}

// ── pure: table building / rendering ───────────────────────────────────

export interface OutLine {
  kind: "info" | "warn" | "error" | "raw";
  text: string;
}

export interface InspectReport {
  lines: OutLine[];
  warnings: number;
  errors: number;
}

const pad = (s: string, n: number): string => s.padEnd(n);

// One table row with the bash print_row color rules. Argument order matches
// the bash function (config=Desired, git=Released, actual) even though the
// printed column order is Released, Desired, Actual.
class Table {
  lines: OutLine[] = [];
  warnings = 0;
  errors = 0;

  raw(text: string): void {
    this.lines.push({ kind: "raw", text });
  }

  header(): void {
    this.raw(
      `  ${BOLD}${pad("Field", 18)}  ${pad("Released (Git)", 20)}  ` +
        `${pad("Desired (~/config)", 20)}  ${pad("Actual", 20)}${CL}`,
    );
    this.raw(
      `  ${"-".repeat(18)}  ${"-".repeat(20)}  ${"-".repeat(20)}  ${"-".repeat(20)}`,
    );
  }

  row(field: string, configVal: string, gitVal: string, actualVal: string): void {
    let cfgColor = CL;
    let gitColor = CL;
    let actColor = CL;

    // Yellow: config differs from git
    if (gitVal !== "" && configVal !== gitVal) {
      cfgColor = YW;
      gitColor = YW;
      this.warnings++;
    }
    // Red: actual differs from config (only when both have values)
    if (actualVal !== "" && configVal !== "" && configVal !== "-" && actualVal !== configVal) {
      actColor = RD;
      cfgColor = RD;
      this.errors++;
    }

    this.raw(
      `  ${pad(field, 18)}  ${gitColor}${pad(gitVal || "-", 20)}${CL}  ` +
        `${cfgColor}${pad(configVal || "-", 20)}${CL}  ` +
        `${actColor}${pad(actualVal || "-", 20)}${CL}`,
    );
  }
}

// The two pre-table warnings when the git source JSON cannot be located.
export function gitSourceWarnings(gitFound: boolean, location: string): OutLine[] {
  if (gitFound) return [];
  return [
    { kind: "warn", text: `Git source JSON not found (location: ${location || "not set"})` },
    { kind: "warn", text: "Git column will show 'N/A'" },
  ];
}

// Config-only fallback for a NON-VM module (no vmid): two-way Released-vs-
// Desired diff, Actual column N/A. Always rc 0.
const CONFIG_ONLY_FIELDS = [
  "vmname", "node", "zone0", "zone1", "tier", "source", "status",
  "environment", "cores", "memory", "diskSize", "storage", "description",
];

export function buildConfigOnlyReport(
  module: string,
  cfg: Record<string, unknown>,
  git: Record<string, unknown> | null,
): InspectReport {
  const t = new Table();
  t.lines.push({
    kind: "info",
    text: `${BOLD}TAPPaaS Module Inspection: ${BL}${module}${CL} (no VM — vmid not set)`,
  });
  t.raw("");
  t.header();
  for (const f of CONFIG_ONLY_FIELDS) {
    const cfgV = getField(cfg, f);
    const gitV = getField(git, f);
    // Skip fields absent from BOTH config and git — keep the table tight.
    if (!cfgV && !gitV) continue;
    t.row(f, cfgV, gitV, "");
  }
  t.raw("");
  t.lines.push({
    kind: "warn",
    text: "no VM (vmid) — running/Actual column N/A (config-only Released-vs-Desired diff)",
  });
  if (t.warnings === 0) {
    t.lines.push({
      kind: "info",
      text: `${GN}Config inspection passed — no config-vs-git discrepancies found${CL}`,
    });
  } else {
    t.lines.push({
      kind: "warn",
      text: `${t.warnings} field(s) differ between config and git (${YW}yellow${CL})`,
    });
  }
  return { lines: t.lines, warnings: t.warnings, errors: t.errors };
}

// Everything the VM three-way table needs, gathered by the I/O layer.
export interface VmInspectInputs {
  vmid: string;
  cfg: Record<string, unknown>; // normalized deployed config
  git: Record<string, unknown> | null; // normalized git source (null = not found)
  zones: ZonesFile;
  actual: Record<string, string>; // parsed `qm config`
  vmStatus: string;
  actualNode: string;
}

export function buildVmReport(inp: VmInspectInputs): InspectReport {
  const { vmid, cfg, git, zones, actual, vmStatus, actualNode } = inp;
  const cfgF = (k: string): string => getField(cfg, k);
  const gitF = (k: string): string => getField(git, k);
  const t = new Table();
  t.header();

  // VM identity
  t.row("vmname", cfgF("vmname"), gitF("vmname"), actual.name ?? "");
  t.row("vmid", cfgF("vmid"), gitF("vmid"), vmid);
  t.row("node", cfgF("node"), gitF("node"), actualNode);
  t.row("status", "-", "-", vmStatus);

  // CPU / memory
  t.row("cores", cfgF("cores"), gitF("cores"), actual.cores ?? "");
  t.row("memory", cfgF("memory"), gitF("memory"), actual.memory ?? "");

  // Storage / disk — actual size parsed from the first present disk bus
  // (e.g. "tanka1:vm-311-disk-0,size=32G").
  let actualDisk = "";
  for (const key of ["scsi0", "virtio0", "ide0", "sata0"]) {
    if (actual[key]) {
      const m = /size=([^,]+)/.exec(actual[key]);
      actualDisk = m ? m[1] : "";
      break;
    }
  }
  t.row("diskSize", cfgF("diskSize"), gitF("diskSize"), actualDisk);
  t.row("storage", cfgF("storage"), gitF("storage"), "");

  // BIOS / CPU type
  t.row("bios", cfgF("bios"), gitF("bios"), actual.bios || "seabios");
  t.row("cputype", cfgF("cputype"), gitF("cputype"), actual.cpu ?? "");

  // Network — net0 and net1 (TAPPaaS allows at most two NICs per VM). For each
  // NIC: bridge, zone (by name AND by VLAN tag — two views of the same thing),
  // the trunk allow-list resolved to VLAN tags, and the MAC (issue #334).
  for (const i of [0, 1]) {
    const actualNet = actual[`net${i}`] ?? "";
    const cfgBridge = cfgF(`bridge${i}`);
    const gitBridge = gitF(`bridge${i}`);
    const cfgZone = cfgF(`zone${i}`);

    // NIC absent from config, git, AND the live VM → single "none" line (#334).
    if (!actualNet && !cfgBridge && !gitBridge) {
      t.raw(`  ${pad(`nic${i}`, 18)}  ${pad("none", 20)}  ${pad("none", 20)}  ${pad("none", 20)}`);
      continue;
    }

    t.row(`bridge${i}`, cfgBridge, gitBridge, vmnetParse(actualNet, "bridge"));

    // Zone shown two ways: the (tag) row carries the zone NAME and catches a
    // config-vs-git name change; the (vlan) row carries the VLAN NUMBER and
    // catches actual-vs-config drift (#334).
    const actualTag = vmnetParse(actualNet, "tag");
    const cfgVlan = cfgZone ? vmnetZoneVlantag(cfgZone, zones) ?? "" : "";
    t.row(`zone${i} (tag)`, cfgZone, gitF(`zone${i}`), cfgZone);
    t.row(`zone${i} (vlan)`, fmtVlan(cfgVlan), fmtVlan(cfgVlan), fmtVlan(actualTag));

    // Trunks — resolve the zone-name/sentinel config form to VLAN tags so it
    // lines up with the live list, and normalize ordering on both sides.
    const cfgTrunksV = normTrunks(vmnetResolveTrunks(cfgF(`trunks${i}`), zones) ?? "");
    const gitTrunksV = normTrunks(vmnetResolveTrunks(gitF(`trunks${i}`), zones) ?? "");
    const actTrunksV = normTrunks(vmnetParse(actualNet, "trunks"));
    t.row(`trunks${i}`, cfgTrunksV, gitTrunksV, actTrunksV);

    t.row(`mac${i}`, cfgF(`mac${i}`), gitF(`mac${i}`), vmnetParse(actualNet, "mac"));
  }

  // HA
  t.row("HANode", cfgF("HANode"), gitF("HANode"), "");

  // Description — Proxmox wraps it in HTML, so only config-vs-git is compared;
  // the Actual cell is info-only.
  const cfgDesc = cfgF("description");
  const gitDesc = gitF("description");
  const descDrift = gitDesc !== "" && cfgDesc !== gitDesc;
  const dColor = descDrift ? YW : CL;
  t.raw(
    `  ${pad("description", 18)}  ${dColor}${pad(gitDesc || "-", 20)}${CL}  ` +
      `${dColor}${pad(cfgDesc || "-", 20)}${CL}  ${pad("(see Proxmox UI)", 20)}`,
  );
  if (descDrift) t.warnings++;

  // Tags — Proxmox stores tags semicolon-separated lowercase sorted; when the
  // normalized forms match, echo the config spelling so it never reads as drift.
  const cfgTag = cfgF("vmtag");
  const actualTags = actual.tags ?? "";
  if (cfgTag && actualTags && normalizeTags(cfgTag) === normalizeTags(actualTags)) {
    t.row("vmtag", cfgTag, gitF("vmtag"), cfgTag);
  } else {
    t.row("vmtag", cfgTag, gitF("vmtag"), actualTags);
  }

  t.raw("");

  // Summary
  if (t.warnings === 0 && t.errors === 0) {
    t.lines.push({ kind: "info", text: `${GN}VM inspection passed — no discrepancies found${CL}` });
  } else {
    if (t.warnings > 0) {
      t.lines.push({
        kind: "warn",
        text: `${t.warnings} field(s) differ between config and git (${YW}yellow${CL})`,
      });
    }
    if (t.errors > 0) {
      t.lines.push({
        kind: "error",
        text: `${t.errors} field(s) differ between config and actual VM (${RD}red${CL})`,
      });
    }
  }
  return { lines: t.lines, warnings: t.warnings, errors: t.errors };
}

// ── I/O: gather inputs (files + ssh) and print ─────────────────────────

function emit(lines: OutLine[]): void {
  for (const l of lines) {
    if (l.kind === "raw") console.log(l.text);
    else if (l.kind === "info") info(l.text);
    else if (l.kind === "warn") warn(l.text);
    else error(l.text);
  }
}

// Read + normalize a module JSON; a present-but-malformed git source degrades
// to an empty object (the bash get_git 2>/dev/null → empty values per key).
function readNormalized(path: string): Record<string, unknown> | null {
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return {};
    return normalizeModuleConfig(raw as Record<string, unknown>);
  } catch {
    return {};
  }
}

// The full inspect verb: prints the report, returns the exit code. Errors are
// RETURNED (1), never thrown, so the `list --diff` rollup keeps iterating past
// an unreachable module — matching the bash script's per-module exit code.
export function inspectModule(module: string): number {
  const configDir = defaultConfigDir();
  const moduleJson = join(configDir, `${module}.json`);

  if (!existsSync(moduleJson)) {
    error(`Module config not found: ${moduleJson} — is '${module}' installed?`);
    return 1;
  }
  let rawCfg: Record<string, unknown> | null;
  try {
    rawCfg = readJsonObject(moduleJson);
  } catch (e) {
    error(e instanceof Error ? e.message : String(e));
    return 1;
  }
  if (!rawCfg) {
    error(`Module config not found: ${moduleJson} — is '${module}' installed?`);
    return 1;
  }
  const cfg = normalizeModuleConfig(rawCfg);

  const vmid = getField(cfg, "vmid");
  const node = getField(cfg, "node") || "tappaas1";
  const vmname = getField(cfg, "vmname") || module;

  // Locate the git source JSON via the module's .location:
  // <location>/<module>.json, else <location>/<vmname>.json.
  const location = getField(cfg, "location");
  let git: Record<string, unknown> | null = null;
  if (location) {
    for (const cand of [join(location, `${module}.json`), join(location, `${vmname}.json`)]) {
      const g = readNormalized(cand);
      if (g) {
        git = g;
        break;
      }
    }
  }
  emit(gitSourceWarnings(git !== null, location));

  // zones.json for the zone→VLAN and trunk resolution (null when absent).
  let zones: ZonesFile = null;
  try {
    zones = readJsonObject(join(configDir, "zones.json"));
  } catch {
    zones = null;
  }

  // ── Config-only fallback: NON-VM module (no vmid) ────────────────
  if (!vmid) {
    emit(buildConfigOnlyReport(module, cfg, git).lines);
    return 0;
  }

  info(`${BOLD}TAPPaaS VM Inspection: ${BL}${vmname}${CL} (VMID: ${vmid}) on ${node}`);
  console.log("");

  const fqdn = `${node}.${mgmtDomain()}`;

  const rCfg = ssh("root", fqdn, `qm config ${vmid}`);
  if (!rCfg.ran || rCfg.rc !== 0) {
    error(`Failed to get VM config from Proxmox (VMID: ${vmid} on ${node})`);
    return 1;
  }
  const actual = parseQmConfig(rCfg.stdout);

  const rStat = ssh("root", fqdn, `qm status ${vmid}`);
  const vmStatus =
    !rStat.ran || rStat.rc !== 0 ? "unknown" : rStat.stdout.trim().split(/\s+/)[1] ?? "";

  let actualNode = "";
  const rRes = ssh("root", fqdn, "pvesh get /cluster/resources --type vm --output-format json");
  if (rRes.ran && rRes.rc === 0) {
    try {
      const arr = JSON.parse(rRes.stdout);
      if (Array.isArray(arr)) {
        for (const e of arr) {
          const o = e as Record<string, unknown>;
          if (Number(o.vmid) === Number(vmid) && typeof o.node === "string") {
            actualNode = o.node;
            break;
          }
        }
      }
    } catch {
      actualNode = "";
    }
  }

  emit(buildVmReport({ vmid, cfg, git, zones, actual, vmStatus, actualNode }).lines);
  return 0;
}
