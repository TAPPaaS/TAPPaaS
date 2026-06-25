// health-manager — TAPPaaS cluster/VM/disk/OS health manager (ADR-007 P? / #3).
//
// READ-ONLY manager: it surfaces the live cluster against the module config; it
// never writes config and never reconciles (add/modify/delete/reconcile are N/A).
// Holds the inspection + health-gate LOGIC and shells out to ssh/pvesh/qm via a
// thin ClusterClient FFI (src/client.ts) — NO Proxmox logic is reimplemented.
//
// Standardized verbs (ADR-007 §Health):
//   health-manager list vm [--diff] [--json] [--config-dir DIR]  (= inspect-cluster.sh)
//   health-manager show vm <name> [--json] [--config-dir DIR]    (= inspect-vm.sh)
//   health-manager validate [--threshold PCT] [--config-dir DIR]
//                            (special: ASSERTS the live system is healthy —
//                             aggregates the health gates; exit 1 if any fail)
//   health-manager update-os <name> <vmid> <node>        (special action; shells
//                            out to update-os.sh — see the update-os case)
//
// `list vm --diff` runs the per-VM three-way (orig/config/running) rollup for
// every managed module; `--json` makes list/show machine-readable.
//
// Exit codes: ok=0, error / drift / failed-health-gate = 1.

import { spawnSync } from "child_process";
import { defaultConfigDir } from "./config";
import { CliClusterClient } from "./client";
import { clusterDiff, inspectCluster, inspectVm } from "./inspect";
import { runHealthGates } from "./checks";
import { ClusterClient } from "./types";

const VERSION = "0.1.0";

const YW = "\x1b[01;33m";
const RD = "\x1b[01;31m";
const GN = "\x1b[1;92m";
const BL = "\x1b[36m";
const BOLD = "\x1b[1m";
const CL = "\x1b[0m";

const DEFAULT_THRESHOLD = 80; // disk-threshold gate default (check-disk-threshold uses an explicit arg)
const DEFAULT_NODE = "tappaas1";
const UPDATE_OS_BIN = process.env.UPDATE_OS_BIN ?? "update-os.sh"; // the special action verb's driver

function emitJson(value: unknown): void {
  console.log(JSON.stringify(value, null, 2));
}

function info(msg: string): void {
  console.log(msg);
}
function warn(msg: string): void {
  console.log(`${YW}[Warning]${CL} ${msg}`);
}
class DieError extends Error {}
function die(msg: string): never {
  console.error(`${RD}[Error]${CL} ${msg}`);
  throw new DieError(msg);
}

function usage(): void {
  info(`health-manager ${VERSION} — TAPPaaS cluster/VM health manager (read-only)

Usage:
  health-manager list vm [--diff] [--json] [--config-dir DIR]
  health-manager show vm <name> [--json] [--config-dir DIR]
  health-manager validate [--threshold PCT] [--config-dir DIR]
  health-manager update-os <name> <vmid> <node>

Verbs:
  list vm        Cluster overview: every running guest vs config (basics).
  list vm --diff Per-VM three-way (orig/config/running) drift rollup across every
                 managed module — reuses the show-vm comparison.
  show vm <name> Three-way drift table for one module (Released/Desired/Actual).
  validate       ASSERT the live system is healthy (health gates). Exit 1 on fail.
  update-os      OS-patch action (special) — shells out to update-os.sh.

Options:
  --diff           list vm: per-VM orig/config/running drift rollup.
  --json           list/show: machine-readable JSON instead of the table.
  --threshold PCT  validate: disk-usage threshold percent (default ${DEFAULT_THRESHOLD}).
  --config-dir DIR Config root (default: \$CONFIG_DIR or /home/tappaas/config).
  -h, --help       Show this help.`);
}

interface Opts {
  configDir: string;
  diff: boolean;
  json: boolean;
  threshold: number;
  rest: string[];
}
function parseOpts(args: string[]): Opts {
  let configDir = defaultConfigDir();
  let diff = false;
  let json = false;
  let threshold = DEFAULT_THRESHOLD;
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--diff") {
      diff = true;
    } else if (a === "--json") {
      json = true;
    } else if (a === "--config-dir") {
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
    } else {
      rest.push(a);
    }
  }
  return { configDir, diff, json, threshold, rest };
}

// ── list vm --diff (per-VM three-way rollup) ──────────────────────────
function cmdListVmDiff(opts: Opts, client: ClusterClient): number {
  const diff = clusterDiff(client, opts.configDir, DEFAULT_NODE);
  if (opts.json) {
    emitJson(diff);
    return 0;
  }
  info(`${BOLD}Cluster Drift (orig/config/running) — managed VMs:${CL}`);
  info("");
  for (const vm of diff.vms) {
    const flag =
      vm.errors > 0 ? `${RD}${vm.errors} drift${CL}` : vm.warnings > 0 ? `${YW}${vm.warnings} warn${CL}` : `${GN}ok${CL}`;
    info(`  ${vm.module.padEnd(24)} (VMID ${String(vm.vmid).padEnd(6)}) ${flag}`);
    for (const r of vm.rows) {
      if (r.level === "ok") continue; // only surface the drifting fields in the rollup
      const color = r.level === "error" ? RD : YW;
      info(`      ${color}${r.field.padEnd(14)}${CL}  git=${r.released || "-"}  cfg=${r.desired || "-"}  live=${r.actual || "-"}`);
    }
  }
  for (const u of diff.unreachable) {
    warn(`${u.module}: could not inspect (${u.error})`);
  }
  info("");
  if (diff.warnings === 0 && diff.errors === 0 && diff.unreachable.length === 0) {
    info(`${GN}No drift across ${diff.vms.length} managed VM(s).${CL}`);
  } else {
    if (diff.warnings > 0) warn(`${diff.warnings} config-vs-git field(s) drifting`);
    if (diff.errors > 0) console.error(`${RD}[Error]${CL} ${diff.errors} live-vs-config field(s) drifting`);
  }
  return 0; // a report, not an assertion (that's `validate`)
}

// ── list vm ───────────────────────────────────────────────────────────
function cmdListVm(opts: Opts, client: ClusterClient): number {
  if (opts.diff) return cmdListVmDiff(opts, client);

  const insp = inspectCluster(client, opts.configDir, DEFAULT_NODE);
  if (opts.json) {
    emitJson(insp);
    return 0;
  }

  info(`${BOLD}Cluster Guest Status:${CL}`);
  info(`  ${BOLD}${"VMID".padEnd(8)}  ${"Name".padEnd(20)}  ${"Node".padEnd(12)}  ${"Type".padEnd(6)}  ${"Status".padEnd(10)}  Config${CL}`);
  for (const r of insp.rows) {
    let cfg: string;
    if (r.config === "managed") cfg = `${GN}yes${CL}`;
    else if (r.config === "external") cfg = `${BL}[external]${CL}`;
    else cfg = `${YW}NOT IN CONFIG${CL}`;
    info(
      `  ${String(r.vmid).padEnd(8)}  ${r.name.padEnd(20)}  ${r.node.padEnd(12)}  ${r.type.padEnd(6)}  ${r.status.padEnd(10)}  ${cfg}`,
    );
  }
  info("");

  for (const m of insp.missing) {
    if (m.kind === "archived") {
      info(`  ${YW}VMID ${m.vmid}  ${m.module}  [archived]  — VM removed, config + backups retained${CL}`);
    } else if (m.kind === "external") {
      info(`  ${BL}VMID ${m.vmid}  ${m.module}  [external]  — externally managed, not currently running${CL}`);
    } else {
      info(`  ${RD}VMID ${m.vmid}  ${m.module}  (expected on ${m.node})  — NOT RUNNING${CL}`);
    }
  }

  info("");
  if (insp.warnings === 0 && insp.missingCount === 0) {
    info(`${GN}Cluster inspection passed — no discrepancies found${CL}`);
    return 0;
  }
  if (insp.warnings > 0) warn(`${insp.warnings} VM(s) running without a TAPPaaS config`);
  if (insp.missingCount > 0) {
    console.error(`${RD}[Error]${CL} ${insp.missingCount} configured module(s) not running`);
  }
  // inspect-cluster.sh reports discrepancies but still exits 0 (set -e, no final
  // `exit 1`). Preserve that: `list` is a report, not an assertion (that's
  // `validate`). Return 0 here.
  return 0;
}

// ── show vm <name> ────────────────────────────────────────────────────
function cmdShowVm(name: string, opts: Opts, client: ClusterClient): number {
  const insp = inspectVm(client, opts.configDir, name);
  if (opts.json) {
    emitJson(insp);
    return 0;
  }
  info(`${BOLD}TAPPaaS VM Inspection: ${BL}${insp.vmname}${CL} (VMID: ${insp.vmid}) on ${insp.node}`);
  info("");
  info(`  ${BOLD}${"Field".padEnd(18)}  ${"Released (Git)".padEnd(20)}  ${"Desired (~/config)".padEnd(20)}  Actual${CL}`);
  for (const r of insp.rows) {
    const color = r.level === "error" ? RD : r.level === "warn" ? YW : CL;
    info(
      `  ${r.field.padEnd(18)}  ${color}${(r.released || "-").padEnd(20)}${CL}  ${color}${(r.desired || "-").padEnd(20)}${CL}  ${color}${r.actual || "-"}${CL}`,
    );
  }
  info("");
  if (insp.warnings === 0 && insp.errors === 0) {
    info(`${GN}VM inspection passed — no discrepancies found${CL}`);
  } else {
    if (insp.warnings > 0) warn(`${insp.warnings} field(s) differ between config and git`);
    if (insp.errors > 0) console.error(`${RD}[Error]${CL} ${insp.errors} field(s) differ between config and actual VM`);
  }
  return 0; // a report, like inspect-vm.sh (no exit 1 on drift)
}

// ── validate (health gate) ────────────────────────────────────────────
function cmdValidate(opts: Opts, client: ClusterClient): number {
  const report = runHealthGates(client, {
    configDir: opts.configDir,
    defaultNode: DEFAULT_NODE,
    threshold: opts.threshold,
  });
  info(`${BOLD}TAPPaaS Health Validation${CL}`);
  for (const c of report.checks) {
    const tag =
      c.status === "pass" ? `${GN}PASS${CL}` : c.status === "fail" ? `${RD}FAIL${CL}` : `${YW}SKIP${CL}`;
    info(`  [${tag}] ${c.name}: ${c.detail}`);
  }
  info("");
  if (report.failed === 0) {
    info(`${GN}Health validation passed.${CL}`);
    return 0;
  }
  console.error(`${RD}[Error]${CL} ${report.failed} health gate(s) failed`);
  return 1;
}

export function run(argv: string[], client: ClusterClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  const cmd = argv[0];
  const opts = parseOpts(argv.slice(1));

  try {
    switch (cmd) {
      case "list": {
        const entity = opts.rest[0];
        if (entity !== "vm") {
          // TODO(followup #Q6): ADR-007 lists `cluster`/`node` as health entities
          // alongside `vm`. Their entity model (a node/cluster resource summary)
          // is a coordinator-approved DEFERRED follow-up — not built in this pass.
          usage();
          die(`list: only 'vm' is implemented (got '${entity ?? ""}')`);
        }
        return cmdListVm(opts, client);
      }
      case "show": {
        const entity = opts.rest[0];
        if (entity !== "vm") {
          usage();
          die(`show: only 'vm' is implemented (got '${entity ?? ""}')`);
        }
        const name = opts.rest[1];
        if (!name) die("show vm: expected <name>");
        return cmdShowVm(name, opts, client);
      }
      case "validate":
        return cmdValidate(opts, client);
      case "update-os": {
        // update-os STAYS a special action verb (ADR-007). The OS-patch logic
        // (NixOS rebuild / apt, reboot guards, controller-self-reboot protection)
        // lives in update-os.sh and is NOT reimplemented here — this verb is a
        // thin pass-through to the script. TODO(followup #Q7): full TS port later.
        const passthru = opts.rest; // <name> <vmid> <node> (forwarded verbatim)
        if (passthru.length < 3) {
          die("update-os: expected <name> <vmid> <node>");
        }
        const r = spawnSync(UPDATE_OS_BIN, passthru, {
          encoding: "utf8",
          stdio: "inherit",
          maxBuffer: 64 * 1024 * 1024,
        });
        if (r.error) {
          die(`update-os: failed to run ${UPDATE_OS_BIN} (${r.error.message})`);
        }
        return r.status ?? 1;
      }
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  } catch (e) {
    if (e instanceof DieError) return 1;
    if (e instanceof Error) {
      console.error(`${RD}[Error]${CL} ${e.message}`);
      return 1;
    }
    throw e;
  }
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const client = new CliClusterClient();
  process.exit(run(process.argv.slice(2), client));
}
