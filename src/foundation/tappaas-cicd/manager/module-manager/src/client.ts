// client.ts — CliModuleClient: the real ModuleClient. Each lifecycle verb shells
// out to the existing on-PATH bash script (install-module.sh, update-module.sh,
// delete-module.sh, test-module.sh, snapshot-vm.sh) and returns its exit code.
//
// This is the FFI boundary, exactly as network-manager's planes.ts shells out to
// the plane controllers and people-manager's primitives.ts shells out to
// authentik-manager. The heavy provisioning stays in the live bash scripts
// (they remain the source of truth until their own retire step) — EXCEPT
// `reconcile` and `inspect`, which are NATIVE TS since the ADR-007
// post-implementation refactor Phase 7.3 (src/reconcile.ts / src/inspect.ts;
// the single-caller reconcile-module.sh / inspect-vm.sh scripts are retired).
//
// stdio is inherited so the scripts' step-by-step output streams straight to the
// operator's terminal, identical to running the script directly.

import {
  defaultNodeCandidates,
  queryClusterGuests,
  reachableNodes,
} from "../../../lib/ts/src/cluster";
import { stream } from "../../../lib/ts/src/exec";
import { defaultConfigDir, siteNodeHostnames } from "./config";
import { inspectModule } from "./inspect";
import { reconcileModule } from "./reconcile";
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
  test: process.env.MM_TEST_BIN ?? "test-module.sh",
  snapshot: process.env.MM_SNAPSHOT_BIN ?? "snapshot-vm.sh",
};

// Streaming runner for the lifecycle verbs (lib/ts exec.stream: stdio inherit).
// exec.stream THROWS when the binary cannot be spawned; the historical contract
// here is to print `[Error] <bin>: <cause>` and return 127 (like the bash
// orchestrators when a child script is missing), so re-shape it. A null exit
// status (child killed by a signal) maps to 1, as before.
function run(bin: string, args: string[]): number {
  try {
    const rc = stream(bin, args);
    return rc === -1 ? 1 : rc;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // stream() throws "<bin> <arg0>: <cause>" — strip its prefix to keep the
    // historical error line byte-identical.
    const cause = msg.startsWith(`${bin} ${args[0] ?? ""}: `)
      ? msg.slice(`${bin} ${args[0] ?? ""}: `.length)
      : msg;
    console.error(`[Error] ${bin}: ${cause}`);
    return 127;
  }
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

  // NATIVE TS (Phase 7.3): the leaf converge, ported from the retired
  // reconcile-module.sh. It still shells out to the KEPT scripts underneath
  // (each dependency's install-service.sh + the module's update.sh/install.sh).
  reconcile(module: string, opts: ReconcileOptions): number {
    return reconcileModule(module, opts);
  }

  // NATIVE TS (Phase 7.3): the read-only three-way drift inspect (the DEFAULT
  // `reconcile`, no --apply), ported from the retired inspect-vm.sh. Prints the
  // Released/Desired/Actual table for a VM module (reading the live VM over
  // ssh/qm via lib/ts cluster helpers) and a config-only Released/Desired diff
  // for a non-VM module (no vmid).
  inspect(module: string): number {
    return inspectModule(module);
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
  // and still exits 0. Uses the shared lib/ts cluster helpers (candidates from
  // site.json .hardware.nodes[].name, else the tappaas1..9 scan; each
  // ping-probed; then pvesh via the first reachable node). queryClusterGuests
  // returns null on failure — mapped to [] here (degrade, never throw). The
  // mgmt-zone DNS suffix is overridable via TAPPAAS_MGMT_DOMAIN (lib cluster.ts;
  // replaces the old MM_MGMT_DOMAIN).
  clusterResources(): RunningGuest[] {
    const candidates = defaultNodeCandidates(siteNodeHostnames(defaultConfigDir()));
    const nodes = reachableNodes(candidates);
    if (nodes.length === 0) return [];
    const guests = queryClusterGuests(nodes[0]);
    return guests ?? [];
  }
}
