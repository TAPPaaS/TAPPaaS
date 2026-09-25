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
//   health-manager validate [--threshold PCT] [--memory-threshold PCT] [--config-dir DIR]
//                            (special: ASSERTS the live system is healthy —
//                             aggregates the health gates; exit 1 if any fail)
//   health-manager update-os <name> <vmid> <node>        (special action; shells
//                            out to update-os.sh — see the update-os case)
//   health-manager reboot <module>                       (special action; the
//                            same reboot + readiness wait, via reboot-guest.sh)
//
// Exit codes: ok=0, error / failed-health-gate = 1.

import { spawnSync } from "child_process";
import { hostname } from "os";
import { join } from "path";
import { defaultConfigDir, readModuleJson } from "./config";
import { CliClusterClient } from "./client";
import { guestTarget, runHealthGates } from "./checks";
import { ClusterClient } from "./types";
import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { CL, GN, RD, YW, die, guarded, info, preflightGuard } from "../../../lib/ts/src/cli";

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
      usage: "validate [--threshold PCT] [--memory-threshold PCT] [--config-dir DIR]",
      options: [
        ["--threshold PCT", `Disk-usage threshold percent (default ${DEFAULT_THRESHOLD}).`],
        ["--memory-threshold PCT", `Committed-memory percent of a node's physical RAM before the gate fails (default ${DEFAULT_MEMORY_THRESHOLD}).`],
      ],
    },
    {
      usage: "update-os <name> <vmid> <node>",
      details: "Patches the VM's OS (NixOS rebuild / apt) through update-os.sh; may reboot it.",
    },
    {
      usage: "reboot <module>",
      details:
        "Reboots the module's VM and waits until the module can serve — the reboot update-os takes\n" +
        "after a rebuild, on demand, without updating. For a guest validate reports as pending-reboot.",
    },
  ],
  common: [["--config-dir DIR", "Config root (default: $CONFIG_DIR or /home/tappaas/config)."]],
  notes: [
    "validate ASSERTS the live system is healthy (health gates); exit 1 on fail.\n" +
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
function cmdValidate(opts: Opts, client: ClusterClient): number {
  const report = runHealthGates(client, {
    configDir: opts.configDir,
    defaultNode: DEFAULT_NODE,
    threshold: opts.threshold,
    memoryThreshold: opts.memoryThreshold,
  });
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
  if (cfg.kind === "lxc") die(`reboot: '${module}' is a container — not supported, use: pct reboot ${vmid}`);
  const vmname = typeof cfg.vmname === "string" && cfg.vmname ? cfg.vmname : module;
  const declared = typeof cfg.node === "string" && cfg.node ? cfg.node : DEFAULT_NODE;
  const node = client.actualNode(declared, vmid) || declared;
  if (vmname === hostname()) {
    die(
      `reboot: '${module}' is this controller — reboot it from a node, under supervision:\n` +
        `  ssh root@${node}.mgmt.internal 'qm reboot ${vmid}'`,
    );
  }

  const target = guestTarget(opts.configDir, module);
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
    switch (cmd) {
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
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  });
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const client = new CliClusterClient();
  process.exit(run(process.argv.slice(2), client));
}
