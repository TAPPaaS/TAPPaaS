// health-manager — TAPPaaS cluster/disk/OS health manager (ADR-007 P? / #3).
//
// READ-ONLY manager: it asserts the live cluster is healthy and drives OS
// patching; it never writes module config and never reconciles.
//
// NOTE (ADR-007 move): the per-VM three-way drift INSPECT (`show vm` / `list vm
// [--diff]`, backed by inspect-vm.sh) MOVED to module-manager — it is now
// `module-manager reconcile <m>` (read-only) and `module-manager list --diff`
// (the rollup). health-manager keeps only the cluster-wide health assertion and
// the OS-patch action.
//
// Standardized verbs (ADR-007 §Health):
//   health-manager validate [--live] [--threshold PCT] [--memory-threshold PCT] [--config-dir DIR]
//                            (special: ASSERTS the system is healthy — reads the
//                             conditions; exit 1 on one that counts, ADR-041 D2)
//   health-manager assess [--only <ci>] [--json] [--dry-run]
//                            (writes the conditions; the only writer, ADR-041)
//   health-manager rules list|check [--file F]
//   health-manager update-os <name> <vmid> <node>        (special action; shells
//                            out to update-os.sh — see the update-os case)
//   health-manager reboot <module>                       (special action; the
//                            same reboot + readiness wait, via reboot-guest.sh)
//   health-manager scan security [--if-new-sweep] [--notify]
//                            (ADR-011: inventory + CVE match of every target;
//                             writes ~/config/sbom/, run by tappaas-security-scan)
//   health-manager report security [--all] [--json]      (prints the last scan)
//   health-manager scan nix-list --components <file> [--nixpkgs <path>] [--no-db-update] [--no-vex]
//   health-manager scan images --refs <file> [--no-db-update] [--no-vex]
//                            (#788: container images by registry reference; JSON on stdout)
//                            (#788: match a name/version list as if it ran — the
//                             release train's pin preview; JSON on stdout)
//
// Exit codes: ok=0, error / failed-health-gate = 1.

import { spawnSync } from "child_process";
import { readFileSync } from "fs";
import { hostname } from "os";
import { join } from "path";
import { defaultConfigDir, loadConfigModules, readModuleJson } from "./config";
import { CliClusterClient } from "./client";
import { checkUpdateCapacity, probeTarget, runHealthGates } from "./checks";
import { ALERTS_LOG, alertLine, fetchGrafanaAlerts, filterAlerts, openAlerts, recentEvents } from "./alerts";
import { checkRoom } from "./room";
import { nodeGuests } from "./guests";
import {
  CliSecurityIO, loadVex, scanComponentList, scanImageRefs, PREVIOUS_FILE, SITE_CDX_FILE, STATUS_FILE, notify, readStatus, renderReport, runScan, sbomDir,
  sweepIsNewer, writeScan,
} from "./security";
import { CheckResult, CheckStatus, ClusterClient, HealthReport } from "./types";
import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { CL, GN, RD, YW, die, guarded, info, preflightGuard, warn } from "../../../lib/ts/src/cli";
import { CmdbRefused, CmdbReport, CmdbUnavailable, cmdbQuery, cmdbRelations, cmdbRequest } from "../../../lib/ts/src/cmdb";
import { pruneRefused } from "../../../lib/ts/src/cmdb-reporter";
import { AssessIO, AssessResult, assess } from "./assess";
import { CmdbItem, CmdbRel, SiteIndex } from "./assess-model";
import { assessmentOf, readValidate } from "./assess-validate";
import { readLastSweep } from "./cmdbsweep";
import { cmdRules, readRules } from "./rules";
// ── ADR-041 emit half ──
import { EMIT_HELP, liveEmitContext, runEmitVerb } from "./emit-verbs";
// ── end ADR-041 emit half ──

const VERSION = "0.1.0";

// BOLD is not part of the shared color set (lib/ts/src/cli) — kept local for
// the validation report heading.
const BOLD = "\x1b[1m";

const DEFAULT_THRESHOLD = 80; // disk-threshold gate default (check-disk-threshold uses an explicit arg)
// 100%: a node may commit every byte it has, but not one more. Lower it to see
// the headroom shrink before it runs out (#569).
const DEFAULT_MEMORY_THRESHOLD = 100;
const DEFAULT_NODE = "tappaas1";
const UPDATE_OS_BIN = (): string => process.env.UPDATE_OS_BIN ?? "update-os.sh"; // the special action verb's driver
const REBOOT_BIN = (): string => process.env.REBOOT_BIN ?? "reboot-guest.sh"; // `reboot`'s driver (#730)

export const HELP: HelpSpec = {
  name: "health-manager",
  version: VERSION,
  tagline: "TAPPaaS cluster health manager (read-only)",
  verbs: [
    {
      usage: "validate [--live] [--threshold PCT] [--memory-threshold PCT] [--json] [--config-dir DIR]",
      details:
        "Reads the conditions the last assess wrote (ADR-041): the gates' table, and exit 1 on any critical\n" +
        "condition that is neither derived, acknowledged nor in maintenance. With no recent assess, or a\n" +
        "threshold given, it assesses first; with no CMDB it runs the gates itself.",
      options: [
        ["--live", "Run assess first: the planes as they are now, not as of the last run."],
        ["--threshold PCT", `Disk-usage threshold percent (default ${DEFAULT_THRESHOLD}).`],
        ["--memory-threshold PCT", `Committed-memory percent of a node's physical RAM before the gate fails (default ${DEFAULT_MEMORY_THRESHOLD}).`],
        ["--json", "Print every gate as JSON: status, detail and its findings, each with the module, node, pool, disk or peer it is about."],
      ],
    },
    {
      usage: "capacity [--install <instance> | --room-for <module> | --drain <node>] [--memory-threshold PCT] [--json] [--config-dir DIR]",
      details: "What each node commits once the update has converged every guest: a VM at its configured memory, a container at its highest use of the last week plus 25% (at least 512 MB, at most its limit). Growth that does not fit under the threshold is held: named, and the update keeps that module at its current memory; everything else goes ahead. A node already over that nothing grows, and growth that fits, warn. Exit 1 only when the module being installed would take its node to the threshold. The update sweep's and install-module's pre-flight.",
      options: [
        ["--json", "Print the result as JSON, with `held`: the modules whose growth does not fit (module, node, from, to in bytes)."],
        ["--room-for <module>", "Instead: would starting this suspended module fit on its node, and which pauseOk modules there — lowest pausePriority first — would make it fit (#891). Exit 1 when even that does not."],
        ["--drain <node>", "Instead: would this node's HA guests fit on the other nodes for its reboot, and which pauseOk modules would make them fit. Exit 1 when even that does not."],
        ["--install <instance>", "Count this deployed config's memory as new on its node (install-module, before the guest exists)."],
        ["--memory-threshold PCT", `Percent of a node's RAM the projected commitment must stay under (default ${DEFAULT_MEMORY_THRESHOLD}).`],
      ],
    },
    {
      usage: "guests [<node>] [--json] [--config-dir DIR]",
      details: "Each guest's memory, declared and used as the balloon reports it, and the ZFS volumes behind it, by module. One node, or every node.",
      options: [["--json", "Print the node's document, or { nodes: [...] } for every node."]],
    },
    {
      usage: "update-os <name> <vmid> <node>", effect: { noPreview: "patches the guest's OS packages and reboots it if they need it" },
      details: "Patches the VM's OS (NixOS rebuild / apt) through update-os.sh; may reboot it.",
    },
    {
      usage: "scan security [--if-new-sweep] [--notify]", effect: { noPreview: "runs the security scan and writes config/sbom" },
      options: [
        ["--if-new-sweep", "Scan only when a sweep has written a result since the last scan (the unit's mode)."],
        ["--notify", "Mail the site owner when a fixable CVE or a failed scan is new since the last scan."],
      ],
      details:
        "Inventories every target — the mothership, each module's VM or container, the containers\n" +
        "running inside them (by registry digest), the nodes and the firewall — and matches each\n" +
        "against its layer's CVE source (ADR-011 v0.3). Read-only on every target. Writes\n" +
        "~/config/sbom/site.cdx.json (CycloneDX) and ~/config/sbom/cve-status.json; the previous\n" +
        "status is kept as cve-status.previous.json. Runs after every sweep (tappaas-security-scan).",
    },
    {
      usage: "scan nix-list --components <file> [--nixpkgs <path>] [--no-db-update] [--no-vex]", effect: { noPreview: "scans a component list" },
      options: [
        ["--components <file>", "JSON array of {name, version} — the packages to match (required)."],
        ["--nixpkgs <path>", "The nixpkgs whose CPE vendors to use: the pin being previewed (default: the installed one)."],
        ["--no-db-update", "Match against the grype database as it is, without refreshing it first."],
        ["--no-vex", "Apply no VEX statement (by default the ones `scan security` applies: <module>-vex.json)."],
      ],
      details:
        "Matches a package list against the CVE database as if it ran (#788): the release train's\n" +
        "`tappaas-train preview` uses it for the packages the NEXT nixpkgs pin would bring, which\n" +
        "nothing runs yet. Same CPE rule, matcher and VEX as `scan security`; writes nothing.\n" +
        "Prints {\"findings\": [{id, severity, pkg, installed, fixed, purl}], \"suppressed\": [...], \"error\": \"\"}:\n" +
        "`suppressed` holds what a VEX statement decided.",
    },
    {
      usage: "scan images --refs <file> [--no-db-update] [--no-vex]", effect: { noPreview: "scans container images" },
      options: [
        ["--refs <file>", "JSON array of image references (`<image>:<tag>` or `<image>@sha256:…`) (required)."],
        ["--no-db-update", "Match against the trivy database as it is, without refreshing it first."],
        ["--no-vex", "Apply no VEX statement (by default the ones `scan security` applies)."],
      ],
      details:
        "Scans container images by registry reference, none of which has to run here (#788): the\n" +
        "release preview compares a past release's images with the next one's. trivy fetches each\n" +
        "image (layers are cached). Same VEX as `scan security`. Writes nothing. Prints\n" +
        "{\"<ref>\": {\"findings\": [...], \"suppressed\": [...], \"error\": \"\"}}.",
    },
    {
      usage: "report [--json] [--from <file>] [--discover]", effect: "read",
      name: "report (assess, for the CMDB's rescan and sweep)",
      options: [
        ["--json", "Print the report instead of sending it."],
        ["--from <file>", "Take the gates from this `validate --json` output instead of running them."],
        ["--discover", "Accepted for the CMDB's sweep (ADR-040 D15); the report is already its full depth."],
      ],
      details: "`assess` under the name every cmdbSource answers to.",
    },
    // ── ADR-041 D2, D3: the assessing half ──
    {
      usage: "assess [--only <ci>] [--json] [--dry-run] [--threshold PCT] [--memory-threshold PCT] [--config-dir DIR]", effect: "read",
      options: [
        ["--only <ci>", "One object, by id or name: alerts, sweep, thresholds and the scan speak for it and no gate runs; impact and root causes are worked out again. The alert receiver's call."],
        ["--json", "Print the objects' conditions, the root causes and the transitions."],
        ["--dry-run", "Work it all out and write nothing."],
        ["--threshold PCT", `Disk-usage threshold percent (default ${DEFAULT_THRESHOLD}).`],
        ["--memory-threshold PCT", `Committed-memory percent of a node's physical RAM (default ${DEFAULT_MEMORY_THRESHOLD}).`],
      ],
      details:
        "Gathers what the gates, Grafana's open alerts, the last sweep, thresholds over the CMDB's\n" +
        "observations and the CVE scan say, derives impact and root causes along the relations, and\n" +
        "writes conditions on every object in one report. The only writer of conditions. Each failure\n" +
        "stands until the source that raised it has looked again.",
    },
    {
      usage: "rules list|check [--file F] [--json]", effect: "read",
      options: [
        ["--file F", "check: this candidate file instead of the rules in use."],
        ["--json", "Print the rules, or the problems."],
      ],
      details: "The correlation rules of metamodel/health-rules.json (ADR-041 D3). check exits 1 on a rule it cannot place.",
    },
    // ── end ADR-041 assess ──
    {
      usage: "report security [--all] [--json]", effect: "read",
      options: [
        ["--all", "List every finding to act on, not the first ten per target."],
        ["--json", "Print cve-status.json as it is."],
      ],
      details: "Prints the last scan: per target its coverage, counts and verdict — ACT, SCAN FAILED,\ntriage (Nix), watch — then what to act on.",
    },
    {
      usage: "reboot <module>", effect: { noPreview: "reboots the module's guest" },
      details:
        "Reboots the module's VM (or restarts its container) and waits until the module can serve —\n" +
        "the reboot update-os takes after a rebuild, on demand, without updating. For a guest validate\n" +
        "reports as pending-reboot.",
    },
    {
      usage: "alerts [--module M] [--host H] [--node N] [--json]", effect: "read",
      options: [
        ["--module M", "Only what is about this module: its rules' alerts and its instances' hosts."],
        ["--host H", "Only alerts on this host (a vmname)."],
        ["--node N", "Only alerts on this node (a pvehost instance)."],
        ["--json", "Print the alerts as JSON, each with the object it is about."],
      ],
      details:
        "The site's alerts (ADR-039): open — state alerts firing now, from Grafana on the logging VM;\n" +
        "recent — event alerts of the last 24 hours, from the mothership's alert receiver. Each is\n" +
        "placed on the module, machine or node it is about. The heartbeat is never listed.",
    },
    // ── ADR-041 emit half ──
    ...EMIT_HELP,
    // ── end ADR-041 emit half ──
  ],
  common: [["--config-dir DIR", "Config root (default: $CONFIG_DIR or /home/tappaas/config)."]],
  notes: [
    "validate ASSERTS the live system is healthy (health gates); exit 1 on fail.\n" +
      "Its cve-status gate only ever WARNs: a CVE published upstream never fails a sweep.\n" +
      "update-os is the OS-patch action (special) — shells out to update-os.sh.\n" +
      "reboot takes a pending reboot (special) — shells out to reboot-guest.sh.",
    "Note: the per-VM three-way drift inspect (formerly 'show vm' / 'list vm --diff')\n" +
      "moved to module-manager: 'module-manager reconcile <m>' (read-only report) and\n" +
      "'module-manager list --diff' (per-module rollup).",
  ],
};

function usage(): void {
  info(renderHelp(HELP));
}

export interface Opts {
  configDir: string;
  threshold: number;
  memoryThreshold: number;
  rest: string[];
}
export function parseOpts(args: string[]): Opts {
  let configDir = defaultConfigDir();
  let threshold = DEFAULT_THRESHOLD;
  let memoryThreshold = DEFAULT_MEMORY_THRESHOLD;
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      configDir = v;
      i++;
    } else if (a === "--threshold") {
      const v = args[i + 1];
      if (!v) die("--threshold requires a percentage argument");
      const n = Number(v);
      if (!Number.isInteger(n) || n < 1 || n > 99) die(`--threshold must be 1..99, got '${v}'`);
      threshold = n;
      i++;
    } else if (a === "--memory-threshold") {
      const v = args[i + 1];
      if (!v) die("--memory-threshold requires a percentage argument");
      const n = Number(v);
      if (!Number.isInteger(n) || n < 1 || n > 500) die(`--memory-threshold must be 1..500, got '${v}'`);
      memoryThreshold = n;
      i++;
    } else {
      rest.push(a);
    }
  }
  return { configDir, threshold, memoryThreshold, rest };
}

// ── validate (health gate) ────────────────────────────────────────────
// validate --json: every gate, typed, with the objects its findings are about —
// what the console's strip, Attention list and badges are built from (ADR-034).
// A gate's findings are its rows, or the per-object findings of a gate whose
// text carries them in its detail line.
export function validateDoc(report: HealthReport, now: Date): Record<string, unknown> {
  const rank: Record<CheckStatus, number> = { skip: 0, pass: 0, warn: 1, fail: 2 };
  let worst: CheckStatus = "pass";
  for (const c of report.checks) if (rank[c.status] > rank[worst]) worst = c.status;
  return {
    version: 1,
    generated: now.toISOString(),
    status: worst,
    failed: report.failed,
    warned: report.checks.filter((c) => c.status === "warn").length,
    gates: report.checks.map((c) => ({
      name: c.name,
      status: c.status,
      detail: c.detail,
      findings: (c.findings ?? c.rows ?? []).map((r) => ({ status: r.status, text: r.text, subject: r.subject ?? null })),
    })),
  };
}

const gates = (opts: Opts, client: ClusterClient): HealthReport =>
  runHealthGates(client, {
    configDir: opts.configDir,
    defaultNode: DEFAULT_NODE,
    threshold: opts.threshold,
    memoryThreshold: opts.memoryThreshold,
  });

// ── ADR-041 D2, D3: assess, rules, validate as a read ─────────────────
const cmdbOff = (): boolean => (process.env.TAPPAAS_CMDB ?? "").toLowerCase() === "off";

// A report that is not worth keeping: conditions are now, and a spooled one would
// land stale, so an outage just fails this run and the next one writes.
function writeAssessment(report: CmdbReport): void {
  let r = report;
  for (let round = 0; round < 5; round++) {
    try {
      cmdbRequest("POST", "/v1/report", r);
      return;
    } catch (e) {
      if (!(e instanceof CmdbRefused)) throw e;
      const pruned = pruneRefused(r, e.body.problems);
      if (!pruned) throw e;
      for (const d of pruned.dropped) warn(`assess: left out (refused): ${d}`);
      r = pruned.report;
    }
  }
}

function assessIO(opts: Opts, client: ClusterClient): AssessIO {
  return {
    objects: () => cmdbQuery({ class: "object", limit: 100000 }) as unknown as CmdbItem[],
    relations: () => cmdbRelations({}) as unknown as CmdbRel[],
    rules: readRules,
    sweep: readLastSweep,
    gates: () => gates(opts, client).checks,
    alerts: () => {
      const raw = fetchGrafanaAlerts(opts.configDir);
      return { open: raw ? openAlerts(raw, opts.configDir) : null, recent: recentEvents(ALERTS_LOG, opts.configDir, Date.now()) };
    },
    cve: () => readStatus(join(sbomDir(opts.configDir), STATUS_FILE)),
    write: writeAssessment,
  };
}

function assessLine(r: AssessResult): string {
  const failing = r.objects.filter((o) => o.conditions.some((c) => c.status === "critical" || c.status === "warning")).length;
  return `assessed ${r.objects.length} object(s): ${failing} failing, ${r.rootCauses.length} root cause(s), ${r.transitions.length} transition(s)`;
}

function cmdAssess(opts: Opts, client: ClusterClient): number {
  const val = (flag: string): string | undefined => {
    const i = opts.rest.indexOf(flag);
    return i < 0 ? undefined : opts.rest[i + 1];
  };
  if (opts.rest.includes("--only") && !val("--only")) die("assess: --only needs an object");
  if (cmdbOff()) {
    info("assess: the CMDB is off here (TAPPAAS_CMDB=off) — nothing to write");
    return 0;
  }
  const r = assess(assessIO(opts, client), { only: val("--only"), dryRun: opts.rest.includes("--dry-run") }, new Date());
  if (opts.rest.includes("--json")) {
    process.stdout.write(JSON.stringify({ time: r.time, objects: r.objects, rootCauses: r.rootCauses, transitions: r.transitions }, null, 1) + "\n");
    return 0;
  }
  for (const t of r.transitions) info(`  ${t.class}/${t.name} ${t.type}: ${t.from ?? "new"} → ${t.to}${t.reason === "ok" ? "" : ` (${t.reason})`}`);
  info(assessLine(r));
  return 0;
}

// `report`: assess, for the sources' verb; --from takes the gates of a saved run.
function cmdReportHealth(opts: Opts, client: ClusterClient): number {
  const fi = opts.rest.indexOf("--from");
  const extra = opts.rest.filter((a, i) => a !== "--json" && a !== "--discover" && i !== fi && (fi < 0 || i !== fi + 1));
  if (extra.length) die(`report: unexpected argument ${extra[0]}`);
  if (cmdbOff()) return 0;
  let from: CheckResult[] | undefined;
  if (fi >= 0) {
    const f = opts.rest[fi + 1];
    if (!f) die("report: --from needs a file");
    try {
      from = (JSON.parse(readFileSync(f, "utf8")) as { gates: CheckResult[] }).gates;
    } catch (e) {
      die(`report: --from ${f}: ${(e as Error).message}`);
    }
  }
  const json = opts.rest.includes("--json");
  try {
    const r = assess(assessIO(opts, client), { dryRun: json }, new Date(), from);
    if (json) process.stdout.write(JSON.stringify(r.report, null, 1) + "\n");
    else info(`health-manager: ${assessLine(r)}`);
  } catch (e) {
    if (!(e instanceof CmdbUnavailable || e instanceof CmdbRefused)) throw e;
    warn(`cmdb: conditions not recorded: ${e.message}`);
  }
  return 0;
}

// How old an assessment may be and still be read: the timer has missed a few.
function assessMaxAgeMs(configDir: string): number {
  const site = readModuleJson(join(configDir, "site.json"));
  const minutes = Number((site?.health as { assessInterval?: unknown } | undefined)?.assessInterval ?? 5);
  return Math.max(3 * (Number.isFinite(minutes) && minutes > 0 ? minutes : 5), 30) * 60_000;
}

// The verdict from the CMDB; null when it cannot give one (then the gates do).
function readVerdict(opts: Opts, client: ClusterClient): HealthReport | null {
  if (cmdbOff()) return null;
  const nowMs = Date.now();
  const given = opts.threshold !== DEFAULT_THRESHOLD || opts.memoryThreshold !== DEFAULT_MEMORY_THRESHOLD;
  try {
    const io = assessIO(opts, client);
    let objects = io.objects();
    const last = assessmentOf(objects);
    if (opts.rest.includes("--live") || given || !last || !(nowMs - Date.parse(last.time) <= assessMaxAgeMs(opts.configDir))) {
      assess(io, {}, new Date());
      objects = io.objects();
    }
    const a = assessmentOf(objects);
    return a ? readValidate(new SiteIndex(objects, io.relations()), a, nowMs) : null;
  } catch (e) {
    if (e instanceof CmdbUnavailable || e instanceof CmdbRefused) {
      warn(`cmdb: ${e.message} — running the gates instead`);
      return null;
    }
    throw e;
  }
}

function cmdValidate(opts: Opts, client: ClusterClient): number {
  const report = readVerdict(opts, client) ?? gates(opts, client);
  if (opts.rest.includes("--json")) {
    process.stdout.write(JSON.stringify(validateDoc(report, new Date()), null, 1) + "\n");
    return report.failed === 0 ? 0 : 1;
  }
  info(`${BOLD}TAPPaaS Health Validation${CL}`);
  const tagOf = (s: string): string =>
    s === "pass"
      ? `${GN}PASS${CL}`
      : s === "fail"
        ? `${RD}FAIL${CL}`
        : s === "warn"
          ? `${YW}WARN${CL}`
          : `${YW}SKIP${CL}`;
  for (const c of report.checks) {
    info(`  [${tagOf(c.status)}] ${c.name}: ${c.detail}`);
    // A per-subject gate prints one row per subject beneath its own line, so a
    // long detail string does not have to carry a table.
    for (const r of c.rows ?? []) info(`      [${tagOf(r.status)}] ${r.text}`);
  }
  info("");
  if (report.failed === 0) {
    info(`${GN}Health validation passed.${CL}`);
    return 0;
  }
  console.error(`${RD}[Error]${CL} ${report.failed} health gate(s) failed`);
  return 1;
}
// ── end ADR-041 assess ────────────────────────────────────────────────

// The VEX the nightly scan applies (loadVex: <module>-vex.json in every registered
// module directory), so a triage decision counts the same in both (#788).
function verbVex(opts: Opts, off: boolean): ReturnType<typeof loadVex>["statements"] {
  if (off) return [];
  const v = loadVex(opts.configDir, process.env.TAPPAAS_REPO ?? "/home/tappaas/TAPPaaS");
  for (const u of v.unreadable) process.stderr.write(`[Warning] VEX file not parseable, decides nothing: ${u}\n`);
  return v.statements;
}

// ── scan nix-list (#788) ──────────────────────────────────────────────
function cmdScanNixList(opts: Opts): number {
  let file = "";
  let nixpkgs = "";
  let dbUpdate = true;
  let noVex = false;
  for (let i = 0; i < opts.rest.length; i++) {
    const a = opts.rest[i];
    if (a === "--components") file = opts.rest[++i] ?? "";
    else if (a === "--nixpkgs") nixpkgs = opts.rest[++i] ?? "";
    else if (a === "--no-db-update") dbUpdate = false;
    else if (a === "--no-vex") noVex = true;
    else die(`scan nix-list: unexpected argument ${a}`);
  }
  if (!file) die("scan nix-list: --components <file> is required");
  let list: { name: string; version: string }[];
  try {
    list = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    die(`scan nix-list: ${file} is not a JSON array of {name, version}`);
  }
  if (nixpkgs) process.env.TAPPAAS_NIXPKGS = nixpkgs;
  const io = new CliSecurityIO();
  if (dbUpdate) for (const n of io.dbUpdate()) process.stderr.write(`[Warning] ${n}\n`);
  const r = scanComponentList(list!, io, verbVex(opts, noVex));
  process.stdout.write(JSON.stringify(r) + "\n");
  return r.error ? 1 : 0;
}

// ── scan images (#788) ────────────────────────────────────────────────
function cmdScanImages(opts: Opts): number {
  let file = "";
  let dbUpdate = true;
  let noVex = false;
  for (let i = 0; i < opts.rest.length; i++) {
    const a = opts.rest[i];
    if (a === "--refs") file = opts.rest[++i] ?? "";
    else if (a === "--no-db-update") dbUpdate = false;
    else if (a === "--no-vex") noVex = true;
    else die(`scan images: unexpected argument ${a}`);
  }
  if (!file) die("scan images: --refs <file> is required");
  let refs: string[];
  try {
    refs = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    die(`scan images: ${file} is not a JSON array of image references`);
  }
  const io = new CliSecurityIO();
  if (dbUpdate) for (const n of io.dbUpdate()) process.stderr.write(`[Warning] ${n}\n`);
  process.stdout.write(JSON.stringify(scanImageRefs(refs!, io, verbVex(opts, noVex))) + "\n");
  return 0;
}

// ── scan security / report security (ADR-011 v0.3) ────────────────────
const SITE_NOTIFY_BIN = (): string => process.env.SITE_NOTIFY_BIN ?? "site-notify.sh";

function cmdScanSecurity(opts: Opts, client: ClusterClient): number {
  const ifNew = opts.rest.includes("--if-new-sweep");
  const doNotify = opts.rest.includes("--notify");
  if (opts.rest.some((a) => a !== "--if-new-sweep" && a !== "--notify")) die("scan security: unexpected argument");
  if (ifNew && !sweepIsNewer(opts.configDir)) {
    info("no sweep since the last security scan — nothing to do");
    return 0;
  }
  const repoDir = process.env.TAPPAAS_REPO ?? "/home/tappaas/TAPPaaS";
  const { status, cdx } = runScan(
    { configDir: opts.configDir, defaultNode: DEFAULT_NODE, repoDir, log: (m) => info(`  ${m}`) },
    client,
    new CliSecurityIO(),
  );
  const diff = writeScan(opts.configDir, status, cdx);
  info("");
  for (const l of renderReport(status, false, Date.now())) info(l);
  info("");
  info(`written: ${join(sbomDir(opts.configDir), SITE_CDX_FILE)}, ${STATUS_FILE} (previous: ${PREVIOUS_FILE})`);
  if (doNotify) {
    const n = notify(status, diff, SITE_NOTIFY_BIN());
    info(n.sent ? `notice sent: ${n.message}` : n.message);
  }
  // The scan ran: findings are its RESULT, not its failure. Exit non-zero only
  // when the scan itself could do nothing at all.
  return status.targets.length > 0 && status.targets.every((t) => t.verdict === "failed") ? 1 : 0;
}

function cmdReportSecurity(opts: Opts): number {
  const s = readStatus(join(sbomDir(opts.configDir), STATUS_FILE));
  if (!s) die("no security scan yet — run: health-manager scan security");
  if (opts.rest.includes("--json")) {
    console.log(JSON.stringify(s, null, 1));
    return 0;
  }
  info(`${BOLD}TAPPaaS Security Report${CL}`);
  const tag = (l: string): string => l.replace(/ACT\b/, `${RD}ACT${CL}`).replace(/SCAN FAILED/, `${YW}SCAN FAILED${CL}`);
  for (const l of renderReport(s, opts.rest.includes("--all"), Date.now())) info(tag(l));
  return 0;
}

// ── alerts (ADR-039 D8) ───────────────────────────────────────────────
function cmdAlerts(opts: Opts): number {
  const val = (flag: string): string | undefined => {
    const i = opts.rest.indexOf(flag);
    if (i < 0) return undefined;
    const v = opts.rest[i + 1];
    if (!v || v.startsWith("--")) die(`alerts: ${flag} needs a value`);
    return v;
  };
  const f = { module: val("--module"), host: val("--host"), node: val("--node") };
  const raw = fetchGrafanaAlerts(opts.configDir);
  const items = filterAlerts([
    ...(raw ? openAlerts(raw, opts.configDir) : []),
    ...recentEvents(ALERTS_LOG, opts.configDir, Date.now()),
  ], f);
  if (opts.rest.includes("--json")) {
    info(JSON.stringify({ grafana: raw !== null, alerts: items }, null, 2));
    return 0;
  }
  if (raw === null) warn("Grafana's open alerts could not be read (logging VM not reachable?) — only recent events are shown");
  if (items.length === 0) info("no open or recent alerts");
  for (const a of items) info(alertLine(a));
  return 0;
}

// ── reboot (#730) ─────────────────────────────────────────────────────
// Resolves the module to its VM where it RUNS (HA may have moved it), then
// hands the reboot to reboot-guest.sh — update-os.sh's own reboot path, so the
// two cannot drift apart. The pending state is read before and after, so the
// operator sees what the reboot took and whether it took it.
function cmdReboot(opts: Opts, client: ClusterClient): number {
  if (opts.rest.length !== 1) die("reboot: expected <module>");
  const module = opts.rest[0];
  const raw = readModuleJson(join(opts.configDir, `${module}.json`));
  if (!raw) die(`reboot: no deployed module '${module}' (${opts.configDir}/${module}.json)`);
  const cfg = raw as Record<string, unknown>;
  const vmid = Number(cfg.vmid);
  if (!Number.isInteger(vmid) || vmid <= 0) die(`reboot: '${module}' has no VM to reboot`);
  const vmname = typeof cfg.vmname === "string" && cfg.vmname ? cfg.vmname : module;
  const declared = typeof cfg.node === "string" && cfg.node ? cfg.node : DEFAULT_NODE;
  const node = client.actualNode(declared, vmid) || declared;
  if (vmname === hostname()) {
    die(
      `reboot: '${module}' is this controller — reboot it from a node, under supervision:\n` +
        `  ssh root@${node}.mgmt.internal 'qm reboot ${vmid}'`,
    );
  }

  // A container is probed and restarted through pct on its node (#901).
  const target = probeTarget(client, opts.configDir, { module, vmid, node: declared, status: "" });
  const before = target ? client.pendingReboot(target) : null;
  if (before?.pending) info(`  pending: booted ${before.booted || "?"}, next boot ${before.next || "?"}`);
  else if (before) info("  no reboot was pending — rebooting anyway");

  const r = spawnSync(REBOOT_BIN(), [vmname, String(vmid), node], { encoding: "utf8", stdio: "inherit" });
  if (r.error) die(`reboot: failed to run ${REBOOT_BIN()} (${r.error.message})`);
  if (r.status !== 0) return r.status ?? 1;

  const after = target ? client.pendingReboot(target) : null;
  if (after?.pending) {
    console.error(
      `${YW}[Warning]${CL} ${module} rebooted but still boots ${after.booted || "?"}, not ${after.next || "?"} — ` +
        "check its boot loader",
    );
    return 1;
  }
  if (after?.booted) info(`${GN}✓${CL} ${module} runs ${after.booted}`);
  return 0;
}

function cmdGuests(opts: Opts, client: ClusterClient): number {
  const node = opts.rest.find((a) => !a.startsWith("-"));
  // Every node's guests, even for one node: a replica's home is on another.
  const caps = client.nodeCapacity();
  if (node && !caps.some((c) => c.node === node)) die(`guests: no node '${node}'`);
  const shown = caps.filter((c) => !node || c.node === node);
  const modules = new Map(loadConfigModules(opts.configDir, DEFAULT_NODE).map((m) => [m.vmid, m.module]));
  const volumes = new Map(shown.map((c) => [c.node, client.nodeVolumes(c.node)]));
  const docs = nodeGuests(caps, volumes, modules).filter((d) => !node || d.node === node);
  if (opts.rest.includes("--json")) {
    info(JSON.stringify(node ? docs[0] : { nodes: docs }, null, 2));
    return 0;
  }
  const gib = (b: number): string => (b / 1024 ** 3).toFixed(1);
  for (const d of docs) {
    info(`${d.node}: ${gib(d.usedMem)} of ${gib(d.physicalMem)} GiB in use`);
    for (const g of d.guests) info(`  ${g.module ?? g.name} (${g.vmid}) ${g.status}: ${gib(g.usedMem)} of ${gib(g.declaredMem)} GiB`);
    for (const v of d.volumes) info(`  ${v.module ?? v.vmid} ${v.pool}/${v.volume}: ${gib(v.used)} GiB${v.replica ? " (replica)" : ""}`);
  }
  return 0;
}

export function run(argv: string[], client: ClusterClient): number {
  if (argv.length === 0) {
    usage();
    return 0;
  }
  // #644: --help in any position prints that verb's help and runs nothing
  // (`update-os <name> <vmid> <node> --help` used to patch the VM); an option
  // the verb does not take is refused.
  const gate = checkArgs(HELP, argv);
  if (gate !== undefined) return gate;
  const cmd = argv[0];
  const opts = parseOpts(argv.slice(1));

  return guarded(() => {
    preflightGuard(); // #533: refuse root; self-heal config/repo ownership
    // ── ADR-041 emit half ──
    const emitted = runEmitVerb(cmd, opts.rest, liveEmitContext(opts.configDir));
    if (emitted !== undefined) return emitted;
    // ── end ADR-041 emit half ──
    switch (cmd) {
      case "validate":
        return cmdValidate(opts, client);
      case "capacity": {
        // #891: room for one thing the update needs for a while — a suspended
        // module started to be patched, or a node's HA guests moved for its reboot.
        const rf = opts.rest.indexOf("--room-for");
        const dr = opts.rest.indexOf("--drain");
        if (rf >= 0 || dr >= 0) {
          const arg = opts.rest[(rf >= 0 ? rf : dr) + 1];
          if (!arg) die(`capacity: ${rf >= 0 ? "--room-for needs a module" : "--drain needs a node"}`);
          const r = checkRoom(client, opts.configDir, DEFAULT_NODE, opts.memoryThreshold,
            rf >= 0 ? { kind: "resume", module: arg } : { kind: "drain", node: arg });
          if (opts.rest.includes("--json")) info(JSON.stringify(r, null, 2));
          else (r.fits ? info : warn)(`${r.target}: ${r.detail}`);
          return r.possible ? 0 : 1;
        }
        const at = opts.rest.indexOf("--install");
        const adding = at >= 0 ? opts.rest[at + 1] : undefined;
        if (at >= 0 && !adding) die("capacity: --install needs an instance name");
        const r = checkUpdateCapacity(client, opts.configDir, DEFAULT_NODE, opts.memoryThreshold, adding);
        if (opts.rest.includes("--json")) {
          info(JSON.stringify({ status: r.status, detail: r.detail, rows: r.rows ?? [], held: r.held }, null, 2));
          return r.status === "fail" ? 1 : 0;
        }
        if (r.status === "warn") warn(`${r.name}: ${r.detail}`);
        else {
          const tag = r.status === "fail" ? `${RD}FAIL${CL}` : r.status === "skip" ? `${YW}SKIP${CL}` : `${GN}PASS${CL}`;
          info(`[${tag}] ${r.name}: ${r.detail}`);
        }
        for (const row of r.rows ?? []) info(`    ${row.text}`);
        return r.status === "fail" ? 1 : 0;
      }
      case "guests":
        return cmdGuests(opts, client);
      case "update-os": {
        // update-os STAYS a special action verb (ADR-007). The OS-patch logic
        // (NixOS rebuild / apt, reboot guards, controller-self-reboot protection)
        // lives in update-os.sh and is NOT reimplemented here — this verb is a
        // thin pass-through to the script. TODO(followup #Q7): full TS port later.
        const passthru = opts.rest; // <name> <vmid> <node> (forwarded verbatim)
        if (passthru.length < 3) {
          die("update-os: expected <name> <vmid> <node>");
        }
        const r = spawnSync(UPDATE_OS_BIN(), passthru, {
          encoding: "utf8",
          stdio: "inherit",
          maxBuffer: 64 * 1024 * 1024,
        });
        if (r.error) {
          die(`update-os: failed to run ${UPDATE_OS_BIN()} (${r.error.message})`);
        }
        return r.status ?? 1;
      }
      case "reboot":
        return cmdReboot(opts, client);
      case "alerts":
        return cmdAlerts(opts);
      case "scan":
        if (opts.rest[0] === "nix-list") return cmdScanNixList({ ...opts, rest: opts.rest.slice(1) });
        if (opts.rest[0] === "images") return cmdScanImages({ ...opts, rest: opts.rest.slice(1) });
        if (opts.rest[0] !== "security") die("scan: expected 'security' or 'nix-list'");
        return cmdScanSecurity({ ...opts, rest: opts.rest.slice(1) }, client);
      case "report":
        if (opts.rest[0] === "security") return cmdReportSecurity({ ...opts, rest: opts.rest.slice(1) });
        return cmdReportHealth(opts, client);
      // ADR-041 assess verbs
      case "assess":
        return cmdAssess(opts, client);
      case "rules":
        return cmdRules(opts.rest, readRules(), info);
      // end ADR-041 assess verbs
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  });
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const client = new CliClusterClient();
  // exitCode, not exit(): exit() ends the process before a large write to a PIPE
  // has drained, so `scan images` reached the release preview cut at 65536 bytes
  // (hrossen, 2026-10-08). Nothing else keeps the loop alive: it exits right after.
  process.exitCode = run(process.argv.slice(2), client);
}
