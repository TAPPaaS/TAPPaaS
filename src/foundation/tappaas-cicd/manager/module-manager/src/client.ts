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
import {
  AddOptions,
  DeleteOptions,
  ModifyOptions,
  ModuleClient,
  ReconcileOptions,
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
}
