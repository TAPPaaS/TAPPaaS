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
import { readJsonObject } from "../../../lib/ts/src/config-io";
import {
  ModuleFieldsSchema,
  dependsOnOf,
  getField,
  integratesWithOf,
  loadModuleFields,
  resolveField,
} from "../../../lib/ts/src/desired";
import { ZonesFile, normTags, normTrunks, normVlan } from "../../../lib/ts/src/drift";
import { GuestType, reportGuest } from "./report";
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

// ── the desired-state resolver: NOT here ───────────────────────────────
// jqStr/getField/appliedDefault/resolveField and the ModuleFieldsSchema types
// used to live in this file. ADR-020 D1 lifted them into lib/ts/src/desired.ts
// so that the ACTING path resolves desired state the same way this REPORTING
// path does — the root cause of #550 was that it did not. inspect is now one
// consumer of that resolver, not its home.

// ── the qm-config parsing and the normalizers: NOT here ────────────────
//
// This file used to hold a TypeScript port of cluster/lib/vm-net.sh — a
// `qm config` parser, a netopts splitter, the zone→VLAN and trunk resolvers,
// and the tag canonicaliser. Every one of them had a bash twin doing the same
// job on the acting side, and the twins had already drifted apart: the bash
// netopts parser did not understand a container's `hwaddr=` MAC, and the two
// tag normalizers disagreed about duplicates and whitespace.
//
// ADR-020 D7 splits that work by WHO KNOWS WHAT, not by who happens to need it:
//   - decoding a provider's own spelling  → the provider's report-service.sh
//   - normalizing for comparison          → lib/ts/src/drift.ts, ONE copy,
//                                           applied to both sides of the diff
// inspect is now a consumer of both (Resolved Question 11). fmtVlan stays: it is
// presentation, not comparison — "(untagged)" is how this table renders a 0.

// Proxmox tag=0 means untagged — render 0/""/missing as "(untagged)" so they
// never show up as spurious drift (issue #334).
export function fmtVlan(t: string): string {
  return !t || t === "0" ? "(untagged)" : t;
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

  // configVal/gitVal/actualVal are RAW values (used for the drift comparison);
  // opts carries the display + 3-way flags. Back-compatible: called with no opts
  // it behaves exactly as before (raw values, no brackets, no suppression).
  row(
    field: string,
    configVal: string,
    gitVal: string,
    actualVal: string,
    opts: { cfgDefaulted?: boolean; gitDefaulted?: boolean; notTracking?: boolean } = {},
  ): void {
    let cfgColor = CL;
    let gitColor = CL;
    let actColor = CL;

    // Yellow: Desired differs from Released — UNLESS the field was overwritten at
    // install (Desired ≠ .orig). Then the divergence is intentional and the
    // update path will not reconcile Desired back to Released, so it is annotated
    // rather than flagged as drift (#550, larsrossen's 3-way merge note).
    const wouldYellow = gitVal !== "" && configVal !== gitVal;
    const suppressed = wouldYellow && !!opts.notTracking;
    if (wouldYellow && !suppressed) {
      cfgColor = YW;
      gitColor = YW;
      this.warnings++;
    }
    // Red: Actual differs from Desired (both have real values). Desired may be a
    // schema default — comparing it to the live VM is the whole point of #550.
    if (actualVal !== "" && configVal !== "" && configVal !== "-" && actualVal !== configVal) {
      actColor = RD;
      cfgColor = RD;
      this.errors++;
    }

    // A defaulted value is shown in <angle brackets> so an effective default is
    // visibly distinct from a declared value; the comparison above used the RAW
    // value, so the brackets never read as drift (#550).
    const disp = (v: string, defaulted?: boolean): string =>
      v === "" ? "-" : defaulted ? `<${v}>` : v;
    const note = suppressed ? "  desired state is not tracking release state on purpose" : "";

    this.raw(
      `  ${pad(field, 18)}  ${gitColor}${pad(disp(gitVal, opts.gitDefaulted), 20)}${CL}  ` +
        `${cfgColor}${pad(disp(configVal, opts.cfgDefaulted), 20)}${CL}  ` +
        `${actColor}${pad(actualVal || "-", 20)}${CL}${note}`,
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
  svc: ServiceSection = buildServiceSection(serviceDepsOf(cfg), null),
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

// Every coordinate the dependency-service section reports on: hard deps first,
// then optional integrations. An integration whose provider is not installed
// simply shows as skipped (~ NOT checked), never a failure.
export function serviceDepsOf(cfg: Record<string, unknown>): string[] {
  return [...dependsOnOf(cfg), ...integratesWithOf(cfg)];
}

// ── pure: Proxmox guest type ───────────────────────────────────────────
// GuestType is declared in report.ts, which owns the choice of reporter. It is
// re-exported here because buildVmReport takes it and several callers import it
// alongside the report builders.
export type { GuestType } from "./report";

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
  // module-fields.json `.fields` — the source of the Desired/Released defaults
  // (#550). Omitted = {} → NO defaulting, so the table reads literal values
  // exactly as before (keeps back-compat for callers/tests that don't load it).
  schema?: ModuleFieldsSchema;
  // config/<module>.json.orig — the install-time pre-image. A field whose
  // deployed value differs from it was overwritten on purpose, so Desired is
  // intentionally off Released and that row is annotated, not flagged (#550).
  orig?: Record<string, unknown> | null;
}

export function buildVmReport(inp: VmInspectInputs): InspectReport {
  const { vmid, cfg, git, zones, actual, vmStatus, actualNode } = inp;
  const guest = inp.guest ?? "qemu";
  const isLxc = guest === "lxc";
  const svc = inp.svc ?? buildServiceSection(serviceDepsOf(cfg), null);

  // Desired/Released resolve each field to its literal value, or — when the
  // module does not declare it — its module-fields.json default, marked with
  // <angle brackets> (#550). The schema (`usedBy`) gates which defaults apply,
  // so section fields default in only for a module that has that dependency.
  // Omitting the schema (schema={}) yields NO defaults → literal values exactly
  // as before. The git default only applies when a git source exists.
  const deps = dependsOnOf(cfg);
  const schema = inp.schema ?? {};
  const orig = inp.orig ?? null;
  const rc = (k: string) => resolveField(cfg, k, deps, schema);
  const rg = (k: string) => (git ? resolveField(git, k, deps, schema) : { value: "", defaulted: false });
  // The deployed value overrode the release at install (differs from .orig), so
  // Desired is intentionally off Released for this field (#550).
  const notTrack = (k: string): boolean => orig !== null && getField(cfg, k) !== getField(orig, k);
  // Emit a resolved row: cfg + git defaults + the 3-way flags, for `actualVal`.
  const R = (field: string, key: string, actualVal: string): void => {
    const c = rc(key);
    const g = rg(key);
    t.row(field, c.value, g.value, actualVal, {
      cfgDefaulted: c.defaulted,
      gitDefaulted: g.defaulted,
      notTracking: notTrack(key),
    });
  };

  const t = new Table();
  t.header();

  // VM identity
  R("vmname", "vmname", (isLxc ? actual.hostname : actual.name) ?? "");
  R("vmid", "vmid", vmid);
  R("node", "node", actualNode);
  t.row("status", "-", "-", vmStatus);

  // CPU / memory
  R("cores", "cores", actual.cores ?? "");
  R("memory", "memory", actual.memory ?? "");

  // Storage / disk. Which bus a guest boots from — scsi0/virtio0/ide0/sata0 for
  // a VM, the single `rootfs` for a container (#465) — and how to pull the size
  // out of it is PROVIDER knowledge, so report-service.sh does that and hands
  // over a plain `diskSize`. This file no longer knows what a Proxmox disk
  // string looks like (ADR-020 Resolved Question 11).
  //
  // `storage` keeps its empty Actual cell for now even though the reporter
  // supplies it: surfacing it is a rendering change, and this step is a
  // refactor whose whole point is that the report does not move.
  R("diskSize", "diskSize", actual.diskSize ?? "");
  R("storage", "storage", "");

  // BIOS / CPU type — QEMU-only concepts. A container has neither (their schema
  // usedBy is cluster:vm), so appliedDefault yields nothing for an LXC and the
  // Actual cells stay EMPTY rather than a fabricated "seabios" (#465/#550).
  R("bios", "bios", isLxc ? "" : actual.bios || "seabios");
  R("cputype", "cputype", (isLxc ? "" : actual.cpu) ?? "");

  // Network — net0 and net1 (TAPPaaS allows at most two NICs per VM). For each
  // NIC: bridge, zone (by name AND by VLAN tag — two views of the same thing),
  // the trunk allow-list resolved to VLAN tags, and the MAC (issue #334).
  // The reporter splits each NIC into components ("net0.bridge", "net0.tag",
  // "net0.trunks", "net0.mac") alongside the whole value, so nothing here parses
  // a netopts string. That decoding — and the fact that a container spells its
  // MAC `hwaddr=` where a VM uses the model token — lives once, in the
  // provider's reporter, for every consumer (ADR-020 Resolved Question 11).
  for (const i of [0, 1]) {
    const actualNet = actual[`net${i}`] ?? "";
    const nic = (part: string): string => actual[`net${i}.${part}`] ?? "";
    const cB = rc(`bridge${i}`);
    const gB = rg(`bridge${i}`);
    const cZ = rc(`zone${i}`);
    const gZ = rg(`zone${i}`);
    const cfgZone = cZ.value;

    // NIC absent from config, git, AND the live VM → single "none" line (#334).
    if (!actualNet && !cB.value && !gB.value) {
      t.raw(`  ${pad(`nic${i}`, 18)}  ${pad("none", 20)}  ${pad("none", 20)}  ${pad("none", 20)}`);
      continue;
    }

    t.row(`bridge${i}`, cB.value, gB.value, nic("bridge"), {
      cfgDefaulted: cB.defaulted,
      gitDefaulted: gB.defaulted,
      notTracking: notTrack(`bridge${i}`),
    });

    // Zone shown two ways: the (tag) row carries the zone NAME and catches a
    // config-vs-git name change; the (vlan) row carries the VLAN NUMBER and
    // catches actual-vs-config drift (#334). The (vlan) row is derived, so it is
    // never angle-bracketed.
    const actualTag = nic("tag");
    const cfgVlan = cfgZone ? normVlan(cfgZone, zones) : "";
    t.row(`zone${i} (tag)`, cfgZone, gZ.value, cfgZone, {
      cfgDefaulted: cZ.defaulted,
      gitDefaulted: gZ.defaulted,
      notTracking: notTrack(`zone${i}`),
    });
    t.row(`zone${i} (vlan)`, fmtVlan(cfgVlan), fmtVlan(cfgVlan), fmtVlan(actualTag));

    // Trunks — resolve the zone-name/sentinel config form to VLAN tags so it
    // lines up with the live list, and normalize ordering on both sides. The
    // value shown is the resolved VLAN list, not the raw field, so it is not
    // angle-bracketed.
    const cfgTrunksV = normTrunks(rc(`trunks${i}`).value, zones);
    const gitTrunksV = normTrunks(rg(`trunks${i}`).value, zones);
    const actTrunksV = normTrunks(nic("trunks"), zones);
    t.row(`trunks${i}`, cfgTrunksV, gitTrunksV, actTrunksV, { notTracking: notTrack(`trunks${i}`) });

    R(`mac${i}`, `mac${i}`, nic("mac"));
  }

  // HA
  R("HANode", "HANode", "");

  // Description — Proxmox wraps it in HTML, so only config-vs-git is compared;
  // the Actual cell is info-only.
  const cfgDesc = rc("description").value;
  const gitDesc = rg("description").value;
  const descDrift = gitDesc !== "" && cfgDesc !== gitDesc && !notTrack("description");
  const dColor = descDrift ? YW : CL;
  const descNote = gitDesc !== "" && cfgDesc !== gitDesc && notTrack("description")
    ? "  desired state is not tracking release state on purpose"
    : "";
  t.raw(
    `  ${pad("description", 18)}  ${dColor}${pad(gitDesc || "-", 20)}${CL}  ` +
      `${dColor}${pad(cfgDesc || "-", 20)}${CL}  ${pad("(see Proxmox UI)", 20)}${descNote}`,
  );
  if (descDrift) t.warnings++;

  // Tags — Proxmox stores tags semicolon-separated lowercase sorted; when the
  // normalized forms match, echo the config spelling so it never reads as drift.
  const cTag = rc("vmtag");
  const gTag = rg("vmtag");
  const actualTags = actual.tags ?? "";
  const tagOpts = {
    cfgDefaulted: cTag.defaulted,
    gitDefaulted: gTag.defaulted,
    notTracking: notTrack("vmtag"),
  };
  if (cTag.value && actualTags && normTags(cTag.value) === normTags(actualTags)) {
    t.row("vmtag", cTag.value, gTag.value, cTag.value, tagOpts);
  } else {
    t.row("vmtag", cTag.value, gTag.value, actualTags, tagOpts);
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
  // of the report's inputs are gathered — i.e. in printed order. Optional
  // integrations are reported alongside hard deps (#501).
  const deps = serviceDepsOf(cfg);
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

  // Schema (for Desired/Released defaults) and the install-time pre-image (for
  // the 3-way "not tracking release on purpose" note) — both #550.
  const schema = loadModuleFields(configDir);
  const orig = readNormalized(join(configDir, `${module}.json.orig`));

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

  // ACTUAL state comes from the provider's own reporter (ADR-020 D7). It
  // locates the guest cluster-wide, reads its config on the node it is really
  // on — which #526 showed can differ from config.node, because a migrate or an
  // HA failover deliberately leaves .node unchanged — and returns one flat JSON
  // object. This file no longer runs `qm config` or parses it (Resolved
  // Question 11): the provider knows how it spells its own state, and every
  // consumer of that state now reads the one answer.
  const environment = getField(cfg, "environment");
  const declaredGuest = guestTypeFromDeps(cfg);
  const { outcome, declaredGuest: wrongDeclaration } = reportGuest(
    configDir,
    module,
    declaredGuest,
    environment,
  );

  if (outcome.kind !== "ok") {
    // The three causes the old single "Failed to get VM config" conflated
    // (#526) are now three exit codes from the reporter, so each keeps its own
    // diagnostic — and its own remedy.
    switch (outcome.kind) {
      case "cluster-unreachable":
        error(`Could not query the cluster via ${node} to locate VMID ${vmid} — is ${node} reachable?`);
        break;
      case "not-present":
        // An 'archived' module intends to have NO VM: delete-module.sh --archive
        // removed the guest and kept the config as the archive record (#215). Its
        // absence is the correct state, so report it as informational and stay
        // green — the way vmid-less config-only modules already do (#556). Only
        // 'archived' is exempt: 'external'/'Deprecated' etc. still expect a VM, so
        // for them an absence remains a real error worth surfacing.
        if (cfg.status === "archived") {
          info(
            `${YW}[archived]${CL} VMID ${vmid} not on any node — VM intentionally removed ` +
              `(delete-module.sh --archive); config kept as the archive record, no VM expected.`,
          );
          return 0;
        }
        error(`VMID ${vmid} is not present on any node in the cluster (config declares ${node}) — is the VM created?`);
        break;
      case "unreadable":
        error(`Failed to read the live config for VMID ${vmid} on the node the cluster reports it running`);
        break;
      case "no-reporter":
        error(`No ${outcome.path} — this provider is not on the ADR-020 report contract yet`);
        break;
      default:
        error(`report-service.sh failed for ${module} (rc ${outcome.rc}): ${outcome.detail}`);
    }
    return 1;
  }

  const actual = outcome.actual;
  const guest = outcome.guest;
  const actualNode = actual.node;
  const liveNode = actualNode || node;
  const vmStatus = actual.status || "unknown";

  info(
    `${BOLD}TAPPaaS ${guest === "lxc" ? "LXC" : "VM"} Inspection: ` +
      `${BL}${vmname}${CL} (VMID: ${vmid}) on ${liveNode}`,
  );
  console.log("");

  // The guest is not the kind the module says it is. Worth saying out loud: the
  // report below is correct — it describes the guest that exists — but the
  // module's dependsOn is wrong, and every other path that trusts the
  // declaration (install, converge, backup) will act on the wrong one.
  if (wrongDeclaration) {
    warn(
      `${module} declares cluster:${wrongDeclaration === "lxc" ? "lxc" : "vm"} but VMID ${vmid} is ` +
        `a ${guest === "lxc" ? "container" : "VM"} — reporting the guest that exists; fix dependsOn`,
    );
  }

  const svc = serviceSection();
  emit(
    buildVmReport({ module, vmid, cfg, git, zones, actual, vmStatus, actualNode, guest, svc, schema, orig })
      .lines,
  );
  return serviceExitCode(svc);
}
