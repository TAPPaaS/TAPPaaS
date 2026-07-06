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
// Node enumeration: site.json's `hardware.nodes[].name` is canonical (ADR-007
// P2); the legacy configuration.json `."tappaas-nodes"[].hostname` is the
// fallback while both files coexist — the same canonical-then-legacy shape
// update-tappaas uses for foundation module configs. Both are read directly
// (no shelling out to a bash helper whose CONFIG_DIR/PATH we'd have to
// reproduce), keeping distribute self-contained and unit-testable from
// fixture files.
//
// Dependency-free TS (strict tsc, ambient lib/ts/src/env.d.ts); the scp spawn
// + CONFIG_DIR env handling is the shared lib exec helpers.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import { captureResult } from "../../../lib/ts/src/exec";

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

// Read a JSON object file; null when absent / unparseable / not an object (a
// bad file yields an empty node list — the caller treats that as
// nothing-to-push, non-fatal). Deliberately NOT the lib config-io
// readJsonObject, which THROWS on a malformed file — here a bad
// site/configuration.json must stay non-fatal (nothing to push).
function readJsonObject(file: string): Record<string, unknown> | null {
  if (!existsSync(file)) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }
  return parsed as Record<string, unknown>;
}

// Collect a string field from every object entry of a node array.
function nodeField(nodes: unknown, field: string): string[] {
  if (!Array.isArray(nodes)) return [];
  const out: string[] = [];
  for (const n of nodes) {
    if (n === null || typeof n !== "object" || Array.isArray(n)) continue;
    const v = (n as Record<string, unknown>)[field];
    if (typeof v === "string" && v.length > 0) out.push(v);
  }
  return out;
}

// Enumerate Proxmox node hostnames: site.json `.hardware.nodes[].name`
// (canonical) first; legacy configuration.json `."tappaas-nodes"[].hostname`
// as fallback while both files coexist. A missing/empty canonical list falls
// through to legacy so a not-yet-migrated system keeps distributing. The
// optional override is for tests.
export function enumerateNodes(cfgDir: string = defaultConfigDir()): string[] {
  const site = readJsonObject(join(cfgDir, "site.json"));
  if (site !== null) {
    const hw = site["hardware"];
    if (hw !== null && typeof hw === "object" && !Array.isArray(hw)) {
      const names = nodeField((hw as Record<string, unknown>)["nodes"], "name");
      if (names.length > 0) return names;
    }
  }
  const legacy = readJsonObject(join(cfgDir, "configuration.json"));
  return nodeField(legacy?.["tappaas-nodes"], "hostname");
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
// captureResult injects the same CONFIG_DIR/TAPPAAS_CONFIG env this file used
// to build by hand, and never throws (per-node failures stay non-fatal).
function scpOne(zonesFile: string, hostname: string): NodeOutcome {
  const target = nodeTarget(hostname);
  const r = captureResult(scpBin(), [...SSH_OPTS, zonesFile, target]);
  if (!r.ran) {
    return { hostname, ok: false, message: `scp failed to spawn (${r.stderr})` };
  }
  if (r.rc === 0) {
    return { hostname, ok: true, message: `pushed to ${target}` };
  }
  const detail = r.stderr.trim() || `rc=${r.rc}`;
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
  const live = join(defaultConfigDir(), "zones.json");
  return outFile === live;
}
