// client.ts — CliModuleClient: the real ModuleClient. Each lifecycle verb shells
// out to the existing on-PATH bash script (install-module.sh, update-module.sh,
// delete-module.sh, test-module.sh, snapshot-vm.sh) and returns its exit code.
//
// This is the FFI boundary, exactly as network-manager's planes.ts shells out to
// the plane controllers and people-manager's primitives.ts shells out to
// authentik-manager. NO cluster logic is reimplemented in TS for this first-pass
// port — the heavy provisioning stays in the live bash scripts (they remain the
// source of truth until a later retire phase).
//
// stdio is inherited so the scripts' step-by-step output streams straight to the
// operator's terminal, identical to running the script directly.

import { spawnSync } from "child_process";
import { defaultConfigDir, siteNodeHostnames } from "./config";
import {
  AddOptions,
  DeleteOptions,
  ModifyOptions,
  ModuleClient,
  ReconcileOptions,
  RunningGuest,
  SnapshotAction,
  TestOptions,
} from "./types";

// Bin names (overridable via env for tests / relocations). NOTE: install-module
// reads the AUTHORED module JSON from the CURRENT directory, so `module add` must
// be run from the module's source directory — same contract as the bash script.
const BIN = {
  install: process.env.MM_INSTALL_BIN ?? "install-module.sh",
  update: process.env.MM_UPDATE_BIN ?? "update-module.sh",
  delete: process.env.MM_DELETE_BIN ?? "delete-module.sh",
  reconcile: process.env.MM_RECONCILE_BIN ?? "reconcile-module.sh",
  inspect: process.env.MM_INSPECT_BIN ?? "inspect-vm.sh",
  test: process.env.MM_TEST_BIN ?? "test-module.sh",
  snapshot: process.env.MM_SNAPSHOT_BIN ?? "snapshot-vm.sh",
};

function run(bin: string, args: string[]): number {
  const r = spawnSync(bin, args, { encoding: "utf8", stdio: "inherit" });
  if (r.error) {
    // Surface a spawn failure (bin not on PATH) as a non-zero rc, like the
    // bash orchestrators do when a child script is missing.
    console.error(`[Error] ${bin}: ${r.error.message}`);
    return 127;
  }
  return r.status ?? 1;
}

// ── LIVE cluster query (best-effort) ────────────────────────────────────
// Ported from health-manager/src/client.ts so the default `module list` can
// fold running-vs-config state into its table. NOTE: unlike the lifecycle
// verbs above, this CAPTURES output (not inherited stdio) and NEVER throws —
// it returns [] on any failure so `list` degrades to a config-only view.
const MGMT = process.env.MM_MGMT_DOMAIN ?? "mgmt.internal";

interface Captured {
  rc: number;
  stdout: string;
  ran: boolean;
}

function capture(cmd: string, args: string[]): Captured {
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) return { rc: -1, stdout: "", ran: false };
  return { rc: r.status ?? -1, stdout: r.stdout ?? "", ran: true };
}

// ssh root@<host> "<remote>" with a short connect timeout + batch mode (no
// interactive prompts) — matches health-manager's ssh helper.
function ssh(user: string, host: string, remote: string): Captured {
  return capture("ssh", [
    "-o",
    "ConnectTimeout=5",
    "-o",
    "BatchMode=yes",
    `${user}@${host}`,
    remote,
  ]);
}

// The reachable Proxmox nodes: site.json .hardware.nodes[].name (bash
// get_all_node_hostnames), else a tappaas1..9 scan — each ping-probed so only
// live nodes are returned (mirrors inspect-cluster.sh / health-manager).
function reachableNodes(): string[] {
  let candidates = siteNodeHostnames(defaultConfigDir());
  if (candidates.length === 0) {
    candidates = Array.from({ length: 9 }, (_, i) => `tappaas${i + 1}`);
  }
  const out: string[] = [];
  for (const node of candidates) {
    const r = capture("ping", ["-c", "1", "-W", "1", `${node}.${MGMT}`]);
    if (r.ran && r.rc === 0) out.push(node);
  }
  return out;
}

export class CliModuleClient implements ModuleClient {
  add(module: string, opts: AddOptions): number {
    const args: string[] = [module];
    if (opts.environment) args.push("--environment", opts.environment);
    if (opts.allowFork) args.push("--allow-fork");
    if (opts.force) args.push("--force");
    if (opts.reinstall) args.push("--reinstall");
    args.push(...opts.passthrough);
    return run(BIN.install, args);
  }

  modify(module: string, opts: ModifyOptions): number {
    const args: string[] = [];
    if (opts.environment) args.push("--environment", opts.environment);
    if (opts.force) args.push("--force");
    if (opts.noSnapshot) args.push("--no-snapshot");
    if (opts.debug) args.push("--debug");
    if (opts.silent) args.push("--silent");
    args.push(module);
    return run(BIN.update, args);
  }

  delete(module: string, opts: DeleteOptions): number {
    const args: string[] = [module];
    if (opts.mode === "archive") args.push("--archive");
    if (opts.mode === "remove") args.push("--remove");
    if (opts.vmid) args.push("--vmid", opts.vmid);
    if (opts.environment) args.push("--environment", opts.environment);
    if (opts.yes) args.push("--yes");
    if (opts.force) args.push("--force");
    return run(BIN.delete, args);
  }

  reconcile(module: string, opts: ReconcileOptions): number {
    const args: string[] = [];
    if (opts.environment) args.push("--environment", opts.environment);
    if (opts.debug) args.push("--debug");
    if (opts.silent) args.push("--silent");
    args.push(module);
    return run(BIN.reconcile, args);
  }

  // Read-only three-way drift inspect (the DEFAULT `reconcile`, no --apply). Runs
  // inspect-vm.sh, which prints the Released/Desired/Actual table for a VM module
  // and a config-only Released/Desired diff for a non-VM module (no vmid).
  inspect(module: string): number {
    return run(BIN.inspect, [module]);
  }

  test(module: string, opts: TestOptions): number {
    const args: string[] = [];
    if (opts.deep) args.push("--deep");
    if (opts.vmid) args.push("--vmid", opts.vmid);
    if (opts.zone0) args.push("--zone0", opts.zone0);
    args.push(module);
    return run(BIN.test, args);
  }

  snapshot(module: string, action: SnapshotAction): number {
    const args: string[] = [module];
    switch (action.kind) {
      case "create":
        break; // no flag = create
      case "list":
        args.push("--list");
        break;
      case "cleanup":
        args.push("--cleanup", String(action.keep));
        break;
      case "restore":
        args.push("--restore", String(action.steps));
        break;
    }
    return run(BIN.snapshot, args);
  }

  // BEST-EFFORT live cluster query — returns [] on ANY failure (no reachable
  // node, ssh/pvesh error, bad JSON) so `module list` degrades to config-only
  // and still exits 0. Ported from health-manager's clusterResources(), but
  // swallows errors here instead of throwing.
  clusterResources(): RunningGuest[] {
    const nodes = reachableNodes();
    if (nodes.length === 0) return [];
    const r = ssh(
      "root",
      `${nodes[0]}.${MGMT}`,
      "pvesh get /cluster/resources --type vm --output-format json",
    );
    if (!r.ran || r.rc !== 0) return [];
    let arr: unknown;
    try {
      arr = JSON.parse(r.stdout);
    } catch {
      return [];
    }
    if (!Array.isArray(arr)) return [];
    const out: RunningGuest[] = [];
    for (const e of arr) {
      const o = e as Record<string, unknown>;
      const type = typeof o.type === "string" ? o.type : "";
      if (type !== "qemu" && type !== "lxc") continue;
      out.push({
        vmid: typeof o.vmid === "number" ? o.vmid : Number(o.vmid),
        name: typeof o.name === "string" ? o.name : "unknown",
        node: typeof o.node === "string" ? o.node : "unknown",
        status: typeof o.status === "string" ? o.status : "unknown",
        type: type as "qemu" | "lxc",
        template: o.template === 1 || o.template === true,
      });
    }
    return out;
  }
}
