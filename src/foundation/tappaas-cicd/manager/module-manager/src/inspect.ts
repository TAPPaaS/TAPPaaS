// inspect.ts — the read-only three-way drift report (`module reconcile` without
// --apply, and per-module inside `list --diff`): the native TS port of the
// retired inspect-vm.sh (ADR-007 post-implementation refactor, Phase 7.3).
//
// Generates a 3-column comparison table for a module's VM showing:
//   1. Released (Git)     — from the source module JSON (the module's .location)
//   2. Desired (~/config) — from config/<module>.json (deployed config)
//   3. Actual             — from the running guest via Proxmox (ssh qm/pct/pvesh;
//                           qm for a QEMU VM, pct for an LXC container — #465)
//
// Color coding (same rules as the bash):
//   Yellow — Desired differs from Released (config drift; counts a warning)
//   Red    — Actual differs from Desired  (VM drift; counts an error)
//
// A module WITHOUT a vmid (provider-only / non-VM module) degrades to a
// two-way Released-vs-Desired config diff (Actual = N/A) and still exits 0 —
// this is a report, not a failure. Drift never fails the command either (the
// bash exited 0 after printing the summary); only a missing config, an
// unreachable Proxmox node, or a dependency-service check that could not RUN
// returns 1.
//
// Neither table covers the state a module's dependsOn providers provision
// OUTSIDE the VM (firewall rules, NAT rules, discovery relays). For a
// policy-only module that state is the ENTIRE module, so a field-clean report
// read as "no drift" while declared rules were missing (#458). The
// dependency-service section (src/services.ts, delegating to each provider's
// read-only test-service.sh) closes that gap on BOTH paths; when the caller
// opts out, the summary NAMES what it did not check instead of claiming clean.
//
// STRUCTURE: everything above the I/O line is PURE (string/JSON in → lines +
// counters out) so the diff/render logic is unit-testable offline
// (test/unit/inspect.test.ts); inspectModule() at the bottom is the only part
// that touches the filesystem, ssh, and the test-service.sh children.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { mgmtDomain, ssh } from "../../../lib/ts/src/cluster";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { defaultConfigDir, normalizeModuleConfig } from "./config";
import {
  ServiceSection,
  buildServiceSection,
  checkDependencyServices,
  serviceExitCode,
  serviceSummaryLines,
} from "./services";
import { InspectOptions } from "./types";
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

// Extract one field from a live netN value. QEMU spells it
// "virtio=02:..,bridge=lan,tag=210" (the model=MAC token yields the mac); LXC
// spells the same NIC "name=eth0,bridge=lan,hwaddr=02:..,ip=dhcp,tag=200"
// (#465) — bridge/tag/trunks are shared, only the MAC token differs, so the
// mac lookup accepts either form and every caller stays type-agnostic.
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
      if (NIC_MODELS.has(k) || k === "hwaddr") return v;
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
  svc: ServiceSection = buildServiceSection(dependsOnOf(cfg), null),
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
  t.lines.push(...svc.lines);
  if (t.warnings > 0) {
    t.lines.push({
      kind: "warn",
      text: `${t.warnings} field(s) differ between config and git (${YW}yellow${CL})`,
    });
  } else if (svc.deps.length === 0) {
    // Nothing outside the fields to cover — the historical wording still holds.
    t.lines.push({
      kind: "info",
      text: `${GN}Config inspection passed — no config-vs-git discrepancies found${CL}`,
    });
  } else {
    // Deps exist, so the field verdict is only PART of the picture — say exactly
    // that much and let the service summary below carry the rest (#458).
    t.lines.push({ kind: "info", text: `${GN}Config fields match git${CL}` });
  }
  t.lines.push(...serviceSummaryLines(module, svc));
  return {
    lines: t.lines,
    warnings: t.warnings,
    errors: t.errors + svc.drift + svc.unknown,
  };
}

// The module's dependsOn coordinates (string entries only), from a normalized
// config — what the dependency-service section reports on.
export function dependsOnOf(cfg: Record<string, unknown>): string[] {
  const d = cfg.dependsOn;
  return Array.isArray(d) ? d.filter((x): x is string => typeof x === "string") : [];
}

// ── pure: Proxmox guest type ───────────────────────────────────────────
// Which Proxmox CLI owns a guest, and which config keys its `config` output
// uses: `qm` for a QEMU VM, `pct` for an LXC container (#465). Against an LXC
// vmid `qm config` fails outright, so the whole live half of the report died
// for a container that was in fact up and healthy.
export type GuestType = "qemu" | "lxc";

// FALLBACK discriminator, for when the cluster-resources query could not answer
// (unreachable node, bad JSON, guest not in the cluster listing). The live
// query is the authority — a module's declared dependsOn is a statement of
// intent, not of what Proxmox actually holds. cluster:lxc is the only LXC
// marker; every other form (cluster:vm, cluster:ha, or no cluster:* dep at all
// — plenty of deployed modules declare none) keeps the qm path it has always
// taken, so this is additive for every VM module.
export function guestTypeFromDeps(cfg: Record<string, unknown>): GuestType {
  return dependsOnOf(cfg).includes("cluster:lxc") ? "lxc" : "qemu";
}

// Everything the VM three-way table needs, gathered by the I/O layer.
export interface VmInspectInputs {
  module: string; // deployed (effective) module name — used in the summary hints
  vmid: string;
  cfg: Record<string, unknown>; // normalized deployed config
  git: Record<string, unknown> | null; // normalized git source (null = not found)
  zones: ZonesFile;
  actual: Record<string, string>; // parsed `qm config` / `pct config`
  vmStatus: string;
  actualNode: string;
  // Which CLI produced `actual` — decides how its keys are read (#465).
  // Omitted = "qemu", the shape every caller produced before LXC support.
  guest?: GuestType;
  // Dependency-service state (#458). Omitted = not checked; the summary then
  // names the uncovered deps rather than reporting a bare clean.
  svc?: ServiceSection;
}

export function buildVmReport(inp: VmInspectInputs): InspectReport {
  const { vmid, cfg, git, zones, actual, vmStatus, actualNode } = inp;
  const guest = inp.guest ?? "qemu";
  const isLxc = guest === "lxc";
  const svc = inp.svc ?? buildServiceSection(dependsOnOf(cfg), null);
  const cfgF = (k: string): string => getField(cfg, k);
  const gitF = (k: string): string => getField(git, k);
  const t = new Table();
  t.header();

  // VM identity
  t.row("vmname", cfgF("vmname"), gitF("vmname"), (isLxc ? actual.hostname : actual.name) ?? "");
  t.row("vmid", cfgF("vmid"), gitF("vmid"), vmid);
  t.row("node", cfgF("node"), gitF("node"), actualNode);
  t.row("status", "-", "-", vmStatus);

  // CPU / memory
  t.row("cores", cfgF("cores"), gitF("cores"), actual.cores ?? "");
  t.row("memory", cfgF("memory"), gitF("memory"), actual.memory ?? "");

  // Storage / disk — actual size parsed from the first present disk bus
  // (e.g. "tanka1:vm-311-disk-0,size=32G"). An LXC has no bus: its root volume
  // is the single `rootfs` key ("tanka1:subvol-312-disk-0,size=32G"), same
  // size= token (#465).
  let actualDisk = "";
  for (const key of isLxc ? ["rootfs"] : ["scsi0", "virtio0", "ide0", "sata0"]) {
    if (actual[key]) {
      const m = /size=([^,]+)/.exec(actual[key]);
      actualDisk = m ? m[1] : "";
      break;
    }
  }
  t.row("diskSize", cfgF("diskSize"), gitF("diskSize"), actualDisk);
  t.row("storage", cfgF("storage"), gitF("storage"), "");

  // BIOS / CPU type — QEMU-only concepts. A container has neither, so the
  // Actual cells stay EMPTY rather than defaulting to "seabios": an invented
  // firmware would read as real drift against any LXC module that sets bios
  // (the empty cell is exempt from the red actual-vs-config rule) (#465).
  t.row("bios", cfgF("bios"), gitF("bios"), isLxc ? "" : actual.bios || "seabios");
  t.row("cputype", cfgF("cputype"), gitF("cputype"), (isLxc ? "" : actual.cpu) ?? "");

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
  t.lines.push(...svc.lines);

  // Summary
  if (t.warnings === 0 && t.errors === 0) {
    // A VM module's dependsOn services provision state outside the VM too, so
    // the unqualified "no discrepancies" only holds when there is nothing else to
    // cover, or when what there is was checked and came back clean (#458).
    const svcClean = svc.checked && svc.drift === 0 && svc.unknown === 0;
    t.lines.push({
      kind: "info",
      text:
        svc.deps.length === 0 || svcClean
          ? `${GN}VM inspection passed — no discrepancies found${CL}`
          : `${GN}VM inspection passed — no config/VM field discrepancies found${CL}`,
    });
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
  t.lines.push(...serviceSummaryLines(inp.module, svc));
  return {
    lines: t.lines,
    warnings: t.warnings,
    errors: t.errors + svc.drift + svc.unknown,
  };
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
//
// opts.checkServices runs the dependency-service drift check (#458): ON for a
// single `reconcile <module>`, OFF for the fleet rollup / cascade preview, which
// would otherwise pay one firewall round-trip per dependency per module.
export function inspectModule(module: string, opts: InspectOptions = {}): number {
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

  // Dependency-service drift. The CONSUMING module's persisted environment
  // drives provider resolution, exactly as reconcile.ts does (#438) — reconcile
  // is routinely invoked on an already-suffixed module name without
  // --environment, and the persisted field is the authority either way.
  // Deferred so the (slow, network-touching) verifiers run only after the rest
  // of the report's inputs are gathered — i.e. in printed order.
  const deps = dependsOnOf(cfg);
  const moduleEnvironment = getField(cfg, "environment");
  const serviceSection = (): ServiceSection =>
    opts.checkServices && deps.length > 0
      ? checkDependencyServices(configDir, module, deps, moduleEnvironment)
      : buildServiceSection(deps, null);

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
  // This is the policy-only case from #458: the field diff below is a small part
  // of such a module, so the dependency-service section is the substance.
  if (!vmid) {
    const svc = serviceSection();
    emit(buildConfigOnlyReport(module, cfg, git, svc).lines);
    return serviceExitCode(svc);
  }

  const cfgFqdn = `${node}.${mgmtDomain()}`;

  // Cluster resources FIRST (#465). This one query answers two questions — the
  // node the guest actually runs on, and whether it is a QEMU VM or an LXC
  // container (`--type vm` lists both, each tagged type: "qemu" | "lxc") — so
  // it is hoisted above the config fetch that has to know which CLI to shell.
  // Ground truth beats the module's declared dependsOn, which is only the
  // fallback when this query cannot answer. The query is cluster-wide, so any
  // reachable node answers it; we ask config.node.
  let actualNode = "";
  let liveGuest: GuestType | null = null;
  const rRes = ssh("root", cfgFqdn, "pvesh get /cluster/resources --type vm --output-format json");
  const clusterQueryOk = rRes.ran && rRes.rc === 0;
  if (clusterQueryOk) {
    try {
      const arr = JSON.parse(rRes.stdout);
      if (Array.isArray(arr)) {
        for (const e of arr) {
          const o = e as Record<string, unknown>;
          if (Number(o.vmid) !== Number(vmid)) continue;
          if (typeof o.node === "string") actualNode = o.node;
          if (o.type === "qemu" || o.type === "lxc") liveGuest = o.type;
          break;
        }
      }
    } catch {
      actualNode = "";
    }
  }
  const guest = liveGuest ?? guestTypeFromDeps(cfg);
  const cli = guest === "lxc" ? "pct" : "qm";

  // `qm/pct config` is NODE-LOCAL, so it must run on the node the VM actually
  // runs on — which #526 showed can differ from config.node (a migrate / HA
  // failover deliberately leaves .node unchanged). Fetching from config.node
  // would fail for a healthy VM that lives elsewhere and hide the node drift;
  // the node row (buildVmReport) then reports config.node vs actualNode like
  // any other field. Fall back to config.node only when the cluster query could
  // not locate the VM.
  const liveNode = actualNode || node;
  const liveFqdn = `${liveNode}.${mgmtDomain()}`;

  info(
    `${BOLD}TAPPaaS ${guest === "lxc" ? "LXC" : "VM"} Inspection: ` +
      `${BL}${vmname}${CL} (VMID: ${vmid}) on ${liveNode}`,
  );
  console.log("");

  const rCfg = ssh("root", liveFqdn, `${cli} config ${vmid}`);
  if (!rCfg.ran || rCfg.rc !== 0) {
    // Distinguish the three causes the old single "Failed to get VM config"
    // message conflated (#526): a config.node that could not be queried at all,
    // a VM absent from the whole cluster, and a detail fetch that failed on the
    // node the VM demonstrably runs on.
    if (!clusterQueryOk) {
      error(`Could not query the cluster via ${node} to locate VMID ${vmid} — is ${node} reachable?`);
    } else if (!actualNode) {
      error(`VMID ${vmid} is not present on any node in the cluster (config declares ${node}) — is the VM created?`);
    } else {
      error(`Failed to read ${cli} config for VMID ${vmid} on ${liveNode} (where the cluster reports it running)`);
    }
    return 1;
  }
  const actual = parseQmConfig(rCfg.stdout);

  const rStat = ssh("root", liveFqdn, `${cli} status ${vmid}`);
  const vmStatus =
    !rStat.ran || rStat.rc !== 0 ? "unknown" : rStat.stdout.trim().split(/\s+/)[1] ?? "";

  const svc = serviceSection();
  emit(
    buildVmReport({ module, vmid, cfg, git, zones, actual, vmStatus, actualNode, guest, svc })
      .lines,
  );
  return serviceExitCode(svc);
}
