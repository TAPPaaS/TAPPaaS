// clients.ts — the real NetworkClient + ModuleClient implementations.
//
// CliNetworkClient shells out to `network-manager` (the network plane owner,
// TS, ADR-007 P4). CliModuleClient enumerates deployed module configs on disk
// and shells out to `module-manager` per module — exactly as people-manager
// shells out to authentik-manager. NO plane/module logic is reimplemented here:
// these are thin FFI boundaries.

import { spawnSync } from "child_process";
import { existsSync, readFileSync, readdirSync } from "fs";
import { basename, join } from "path";
import { ModuleClient, NetworkClient } from "./types";

export class NetworkUnreachable extends Error {}

const NETWORK_MANAGER_BIN = process.env.NETWORK_MANAGER_BIN ?? "network-manager";
const MODULE_MANAGER_BIN = process.env.MODULE_MANAGER_BIN ?? "module-manager";

function run(bin: string, args: string[]): string {
  const r = spawnSync(bin, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) {
    throw new NetworkUnreachable(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
  }
  if (r.status !== 0) {
    const stderr = (r.stderr ?? "").trim();
    throw new Error(`${bin} ${args.join(" ")} failed (exit ${r.status}): ${stderr}`);
  }
  return r.stdout;
}

export class CliNetworkClient implements NetworkClient {
  zoneExists(zone: string): boolean {
    // network-manager zone exists <name> — exit 0 if present, non-zero otherwise.
    const r = spawnSync(NETWORK_MANAGER_BIN, ["zone", "exists", zone], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    if (r.error) throw new NetworkUnreachable(`${NETWORK_MANAGER_BIN} zone exists: ${r.error.message}`);
    return r.status === 0;
  }

  reconcileNetwork(apply: boolean): void {
    // network-manager reconcile [--apply] — converges all planes/zones.
    const args = ["reconcile"];
    if (apply) args.push("--apply");
    run(NETWORK_MANAGER_BIN, args);
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
        // A deployed module config carries `environment`; site.json,
        // configuration.json etc. do not.
        if (typeof o.environment === "string" && o.environment === env) {
          out.push(basename(f, ".json"));
        }
      }
    }
    return out.sort();
  }

  reconcileModule(module: string, apply: boolean): void {
    // TODO(question): module-manager is not yet ported to TS and exposes no
    // `module <name> reconcile` verb today (it still ships install/update/
    // delete-module.sh). The contract assumed here is
    // `module-manager <module> reconcile [--apply]`. Verify the final CLI shape
    // when module-manager is ported (the ADR-007 sequencing ports module BEFORE
    // environment, so this binding should be re-checked then).
    const args = [module, "reconcile"];
    if (apply) args.push("--apply");
    run(MODULE_MANAGER_BIN, args);
  }
}
