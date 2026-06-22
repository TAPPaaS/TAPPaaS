// distribute.ts — push the live zones.json to every Proxmox node so node-side
// tooling (Create-TAPPaaS-VM.sh) can resolve a zone's VLAN tag (ADR-007 "S6 N3").
//
// This is the TS port of `distribute_zones_to_nodes()` in
// tappaas-cicd/lib/common-install-routines.sh. That bash scp's
// ${CONFIG_DIR}/zones.json to each node's /root/tappaas/zones.json, enumerating
// nodes from configuration.json's `tappaas-nodes[].hostname` and addressing them
// at <hostname>.mgmt.internal. We replicate the target path, the per-node loop,
// and its non-fatal-per-node error handling (a node being down warns and we move
// on; the op only fails as a whole if NOTHING could be pushed — matching the
// bash's `[[ pushed -gt 0 ]]` return).
//
// Node enumeration: we read configuration.json directly (the same source +
// JSON path the bash uses via jq `."tappaas-nodes"[]?.hostname`). This is the
// least-fragile choice — no shelling out to a bash helper whose CONFIG_DIR/
// PATH we'd have to reproduce — and it keeps distribute self-contained and
// unit-testable from a fixture configuration.json. When site.json's
// `hardware.nodes[].name` becomes canonical (per the prompt's note) this is the
// single place to extend.
//
// Dependency-free TS (strict tsc, ambient src/env.d.ts), mirroring planes.ts's
// spawnSync + CONFIG_DIR handling.

import { spawnSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { join } from "path";

// Where node-side tooling expects the file (mirrors the bash literal).
export const NODE_ZONES_PATH = "/root/tappaas/zones.json";

// SSH options mirroring the bash scp invocation, plus BatchMode so automation
// never blocks on a password/known-hosts prompt (the bash relied on key auth;
// BatchMode makes that explicit and fail-fast rather than hang).
export const SSH_OPTS: string[] = [
  "-o",
  "StrictHostKeyChecking=accept-new",
  "-o",
  "ConnectTimeout=5",
  "-o",
  "BatchMode=yes",
];

// The scp binary (overridable via env for tests / relocations, same idiom as
// planes.ts's PLANE_BIN).
function scpBin(): string {
  return process.env.NM_SCP_BIN ?? "scp";
}

// Resolve CONFIG_DIR the same way planes.ts does so every controller agrees on
// where the live config lives.
export function configDir(): string {
  return (
    process.env.CONFIG_DIR ?? process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config"
  );
}

// Enumerate Proxmox node hostnames from configuration.json's `tappaas-nodes`.
// Mirrors the bash `jq -r '."tappaas-nodes"[]?.hostname // empty'`: skip empty/
// missing entries; a missing file yields an empty list (the caller treats that
// as nothing-to-push, non-fatal). The optional override is for tests.
export function enumerateNodes(cfgDir: string = configDir()): string[] {
  const cfg = join(cfgDir, "configuration.json");
  if (!existsSync(cfg)) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(cfg, "utf8"));
  } catch {
    return [];
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return [];
  }
  const nodes = (parsed as Record<string, unknown>)["tappaas-nodes"];
  if (!Array.isArray(nodes)) return [];
  const out: string[] = [];
  for (const n of nodes) {
    if (n === null || typeof n !== "object" || Array.isArray(n)) continue;
    const h = (n as Record<string, unknown>)["hostname"];
    if (typeof h === "string" && h.length > 0) out.push(h);
  }
  return out;
}

// The mgmt FQDN scp target for a node (mirrors `root@<host>.mgmt.internal`).
export function nodeTarget(hostname: string): string {
  return `root@${hostname}.mgmt.internal:${NODE_ZONES_PATH}`;
}

export interface DistributeOpts {
  // Resolve nodes from this config dir (default: live CONFIG_DIR).
  cfgDir?: string;
  // List targets without scp'ing.
  dryRun?: boolean;
  // Sink for human-readable progress (default: console.log).
  info?: (msg: string) => void;
  warn?: (msg: string) => void;
}

export interface NodeOutcome {
  hostname: string;
  ok: boolean;
  message: string;
}

export interface DistributeResult {
  // Overall rc: 0 if at least one node was pushed (or dry-run, or no nodes
  // configured — nothing to do is not a failure); non-zero only when nodes
  // exist and NONE could be pushed (mirrors the bash `pushed -gt 0`).
  rc: number;
  pushed: number;
  nodes: NodeOutcome[];
  dryRun: boolean;
}

// Run one scp, mapping spawn failure / non-zero exit to a per-node outcome.
function scpOne(zonesFile: string, hostname: string): NodeOutcome {
  const target = nodeTarget(hostname);
  const cfgDir = configDir();
  const env = { ...process.env, CONFIG_DIR: cfgDir, TAPPAAS_CONFIG: cfgDir };
  const r = spawnSync(scpBin(), [...SSH_OPTS, zonesFile, target], {
    encoding: "utf8",
    env,
  });
  if (r.error) {
    return { hostname, ok: false, message: `scp failed to spawn (${r.error.message})` };
  }
  if ((r.status ?? -1) === 0) {
    return { hostname, ok: true, message: `pushed to ${target}` };
  }
  const detail = (r.stderr ?? "").trim() || `rc=${r.status}`;
  return { hostname, ok: false, message: `scp to ${hostname} failed (${detail})` };
}

// Push `zonesFile` to every Proxmox node's /root/tappaas/zones.json. Non-fatal
// per node: a node being down warns and we continue; the op only fails as a
// whole if nodes exist and NONE accepted the push (matching the bash).
export function distributeZones(
  zonesFile: string,
  opts: DistributeOpts = {},
): DistributeResult {
  const log = opts.info ?? ((m: string) => console.log(m));
  const warn = opts.warn ?? ((m: string) => console.log(m));
  const dryRun = opts.dryRun ?? false;

  if (!existsSync(zonesFile)) {
    warn(`distribute: zones.json not found: ${zonesFile} — nothing to distribute`);
    return { rc: 1, pushed: 0, nodes: [], dryRun };
  }

  const hostnames = enumerateNodes(opts.cfgDir);
  if (hostnames.length === 0) {
    log("distribute: no Proxmox nodes configured (tappaas-nodes empty) — nothing to do");
    return { rc: 0, pushed: 0, nodes: [], dryRun };
  }

  if (dryRun) {
    log(`distribute [dry-run]: would push '${zonesFile}' to ${hostnames.length} node(s):`);
    const nodes: NodeOutcome[] = hostnames.map((h) => {
      const target = nodeTarget(h);
      log(`  would scp -> ${target}`);
      return { hostname: h, ok: true, message: `would push to ${target}` };
    });
    return { rc: 0, pushed: 0, nodes, dryRun: true };
  }

  let pushed = 0;
  const nodes: NodeOutcome[] = [];
  for (const h of hostnames) {
    const outcome = scpOne(zonesFile, h);
    nodes.push(outcome);
    if (outcome.ok) {
      pushed++;
    } else {
      warn(`distribute: ${outcome.message} (continuing)`);
    }
  }
  log(`distribute: pushed zones.json to ${pushed}/${hostnames.length} Proxmox node(s)`);
  // Mirror the bash: success iff at least one node was pushed.
  return { rc: pushed > 0 ? 0 : 1, pushed, nodes, dryRun: false };
}

// Decide whether an auto-write should trigger distribution. Skipped when:
//   - NM_NO_DISTRIBUTE=1 (unit tests / opt-out), or
//   - the output path is NOT the live config zones.json (e.g. a temp --out).
// The live path is ${CONFIG_DIR}/zones.json. We compare resolved absolute-ish
// paths via a normalising join so a `--out` under /tmp never SSHes.
export function shouldAutoDistribute(outFile: string, noDistributeFlag: boolean): boolean {
  if (noDistributeFlag) return false;
  if (process.env.NM_NO_DISTRIBUTE === "1") return false;
  const live = join(configDir(), "zones.json");
  return outFile === live;
}
