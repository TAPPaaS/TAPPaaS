// clients.ts — the real NetworkClient + ModuleClient implementations.
//
// CliNetworkClient shells out to `network-manager` (the network plane owner,
// TS, ADR-007 P4). CliModuleClient enumerates deployed module configs on disk
// and shells out to `module-manager` per module — exactly as people-manager
// shells out to authentik-manager. NO plane/module logic is reimplemented here:
// these are thin FFI boundaries.

import { existsSync, readFileSync, readdirSync } from "fs";
import { basename, join } from "path";
import { captureResult } from "../../../lib/ts/src/exec";
import { ModuleClient, NetworkClient, NetworkUnreachable } from "./types";

// Re-exported: NetworkUnreachable now lives in types.ts (the client boundary
// contract) so the pure reconcile engine can distinguish "binary missing" from
// "target ran and failed" — see #454.
export { NetworkUnreachable };

// Resolved per call, not at import time, so a test can point either binary at a
// stub after this module is loaded.
const NETWORK_MANAGER_BIN = (): string => process.env.NETWORK_MANAGER_BIN ?? "network-manager";
const MODULE_MANAGER_BIN = (): string => process.env.MODULE_MANAGER_BIN ?? "module-manager";

// Run + capture via the shared exec helper, mapping a spawn failure (binary
// missing on PATH) to the manager-specific NetworkUnreachable so the reconcile
// verb can die with its "unreachable" message.
function run(bin: string, args: string[]): string {
  const r = captureResult(bin, args);
  if (!r.ran) {
    throw new NetworkUnreachable(`${bin} ${args[0] ?? ""}: ${r.stderr}`);
  }
  if (r.rc !== 0) {
    throw new Error(`${bin} ${args.join(" ")} failed (exit ${r.rc}): ${r.stderr.trim()}`);
  }
  return r.stdout;
}

export class CliNetworkClient implements NetworkClient {
  zoneExists(zone: string): boolean {
    // network-manager exists <name> — exit 0 if present, non-zero otherwise.
    const r = captureResult(NETWORK_MANAGER_BIN(), ["exists", zone]);
    if (!r.ran) throw new NetworkUnreachable(`${NETWORK_MANAGER_BIN()} exists: ${r.stderr}`);
    return r.rc === 0;
  }

  reconcileNetwork(apply: boolean): void {
    // network-manager reconcile [--apply] — converges all planes/zones.
    const args = ["reconcile"];
    if (apply) args.push("--apply");
    run(NETWORK_MANAGER_BIN(), args);
  }
}

// CONFIG_DIR root for deployed module config discovery (the flat
// <config>/<module>.json files, each carrying an `environment` field — see
// module-fields.json). Tests inject a fixture dir.
export class CliModuleClient implements ModuleClient {
  constructor(private configDir: string) {}

  modulesForEnvironment(env: string): string[] {
    const out: string[] = [];
    if (!existsSync(this.configDir)) return out;
    for (const f of readdirSync(this.configDir)) {
      if (!f.endsWith(".json")) continue;
      const path = join(this.configDir, f);
      let raw: unknown;
      try {
        raw = JSON.parse(readFileSync(path, "utf8"));
      } catch {
        continue; // skip non-module / malformed JSON at the config root
      }
      if (raw && typeof raw === "object") {
        const o = raw as Record<string, unknown>;
        // A deployed module config carries an AUTHORITATIVE `environment` field,
        // set at install time (foundation → mgmt, apps → the default env) and
        // backfilled by migrate-to-adr007.sh on migrated systems. site.json,
        // zones.json etc. do not have it.
        if (typeof o.environment === "string" && o.environment === env) {
          out.push(basename(f, ".json"));
        }
      }
    }
    return out.sort();
  }

  reconcileModule(module: string, apply: boolean): void {
    // module-manager reconcile <module> [--apply] — VERB FIRST (#454). The
    // module-first form this used to build was an assumption made before
    // module-manager was ported; the shipped CLI dispatches on argv[0], so it
    // exited 1 with "Unknown verb: <module>" and stalled the --deep cascade at
    // its first module. The unit test below pins the argument vector.
    const args = ["reconcile", module];
    if (apply) args.push("--apply");
    run(MODULE_MANAGER_BIN(), args);
  }
}
