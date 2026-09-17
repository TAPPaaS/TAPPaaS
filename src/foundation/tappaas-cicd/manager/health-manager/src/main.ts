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
//
// Exit codes: ok=0, error / failed-health-gate = 1.

import { spawnSync } from "child_process";
import { defaultConfigDir } from "./config";
import { CliClusterClient } from "./client";
import { runHealthGates } from "./checks";
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
  ],
  common: [["--config-dir DIR", "Config root (default: $CONFIG_DIR or /home/tappaas/config)."]],
  notes: [
    "validate ASSERTS the live system is healthy (health gates); exit 1 on fail.\n" +
      "update-os is the OS-patch action (special) — shells out to update-os.sh.",
    "Note: the per-VM three-way drift inspect (formerly 'show vm' / 'list vm --diff')\n" +
      "moved to module-manager: 'module-manager reconcile <m>' (read-only report) and\n" +
      "'module-manager list --diff' (per-module rollup).",
  ],
};

function usage(): void {
  info(renderHelp(HELP));
}

interface Opts {
  configDir: string;
  threshold: number;
  memoryThreshold: number;
  rest: string[];
}
function parseOpts(args: string[]): Opts {
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
    } else if (a === "--memory-threshold") {
      const v = args[i + 1];
      if (!v) die("--memory-threshold requires a percentage argument");
      const n = Number(v);
      if (!Number.isInteger(n) || n < 1 || n > 500) die(`--memory-threshold must be 1..500, got '${v}'`);
      memoryThreshold = n;
      i++;
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
