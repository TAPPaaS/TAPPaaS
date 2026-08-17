// client.ts — CliSiteClient: the real SiteClient implementation.
//
// Thin FFI boundary. Repository clone/checkout shells out to `git`; site.json
// validation shells out to `validate-site.sh` (the existing bash validate, kept
// live until retire); the --deep cascade shells out to the dependent manager
// bins (people-manager / network-manager / environment-manager) — NOT
// reimplemented here, exactly as network-manager shells out to its plane bins
// and people-manager to authentik-manager. The heavy git/cluster I/O of
// `site add` and `repository add`/`delete` stays in the still-live .sh tools
// (create-site.sh / repository.sh), invoked here as thin delegations.

import { existsSync, readdirSync } from "fs";
import { basename, join } from "path";
import {
  defaultNodeCandidates,
  queryClusterNodes,
  queryNodeTankPools,
  reachableNodes,
} from "../../../lib/ts/src/cluster";
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import { capture as run, captureResult, stream as runStreaming } from "../../../lib/ts/src/exec";
import { loadRaw, writeSite } from "./config";
import { SiteClient } from "./types";

// Bin names (overridable via env for tests / relocations). Resolved LAZILY, as
// in environment-manager/src/clients.ts: a module-level const would freeze the
// value at import time, so a test could not point a bin at a stub without
// controlling import order.
const GIT = (): string => process.env.SITE_GIT_BIN ?? "git";
const VALIDATE_SITE = (): string => process.env.SITE_VALIDATE_BIN ?? "validate-site.sh";
const PEOPLE_BIN = (): string => process.env.SITE_PEOPLE_BIN ?? "people-manager";
const NETWORK_BIN = (): string => process.env.SITE_NETWORK_BIN ?? "network-manager";
// environment-manager exposes `reconcile <env> --deep` (verb-first, ADR-007).
const ENVIRONMENT_BIN = (): string => process.env.SITE_ENVIRONMENT_BIN ?? "environment-manager";
// The still-live bash tools `site add` / `repository <verb>` delegate to.
const CREATE_SITE = (): string => process.env.SITE_CREATE_BIN ?? "create-site.sh";
const REPOSITORY_SH = (): string => process.env.SITE_REPOSITORY_BIN ?? "repository.sh";

export class CliSiteClient implements SiteClient {
  // The schema-dir to pass to validate-site.sh, if known.
  constructor(private schemaDir: string = process.env.SITE_SCHEMA_DIR ?? "") {}

  // ── (1) own concern ─────────────────────────────────────────────────
  repoCloneExists(path: string): boolean {
    return existsSync(path);
  }

  cloneRepo(url: string, path: string, branch: string): void {
    run(GIT(), ["clone", `https://${url}`, path]);
    run(GIT(), ["-C", path, "checkout", branch]);
  }

  currentBranch(path: string): string | null {
    try {
      const out = run(GIT(), ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]).trim();
      return out.length > 0 ? out : null;
    } catch {
      return null;
    }
  }

  checkoutRepo(path: string, branch: string): void {
    run(GIT(), ["-C", path, "fetch", "origin"]);
    run(GIT(), ["-C", path, "checkout", branch]);
  }

  validateSite(siteFile: string): string[] {
    const args = ["--quiet"];
    if (this.schemaDir) args.push("--schema-dir", this.schemaDir);
    args.push(siteFile);
    const r = captureResult(VALIDATE_SITE(), args);
    if (!r.ran) return [`validate-site.sh not runnable: ${r.stderr}`];
    if (r.rc === 0) return [];
    // validate-site.sh prints "[Error] VALIDATION: ..." lines to stderr.
    const out = `${r.stdout}\n${r.stderr}`;
    return out
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.includes("VALIDATION:"))
      .map((l) => l.replace(/^.*VALIDATION:\s*/, ""));
  }

  // Live cluster node membership via the F12 read path (lib/ts cluster.ts):
  // ping-probe the site's known node names (tappaas1..9 scan fallback when
  // none), query /cluster/resources --type node through the first reachable.
  clusterNodes(candidates: string[]): string[] | null {
    const reach = reachableNodes(defaultNodeCandidates(candidates));
    if (reach.length === 0) return null;
    return queryClusterNodes(reach[0]);
  }

  // The node's tankXY pools (create-site.sh discovery: zpool list, tank*).
  nodeStoragePools(node: string): string[] | null {
    return queryNodeTankPools(node);
  }

  // Append a discovered node to site.json .hardware.nodes (idempotent).
  registerNode(siteFile: string, name: string, pools: string[]): void {
    const raw = loadRaw(siteFile);
    const hw = (raw.hardware ?? (raw.hardware = {})) as Record<string, unknown>;
    const nodes = (Array.isArray(hw.nodes) ? hw.nodes : (hw.nodes = [])) as unknown[];
    if (nodes.some((n) => (n as Record<string, unknown> | null)?.name === name)) return;
    nodes.push({ name, storagePools: pools });
    writeSite(siteFile, raw);
  }

  // Fill a known node's storagePools (only ever called for empty lists).
  setNodePools(siteFile: string, name: string, pools: string[]): void {
    const raw = loadRaw(siteFile);
    const hw = (raw.hardware ?? {}) as Record<string, unknown>;
    const nodes = (Array.isArray(hw.nodes) ? hw.nodes : []) as Record<string, unknown>[];
    const node = nodes.find((n) => n?.name === name);
    if (!node) return;
    node.storagePools = pools;
    writeSite(siteFile, raw);
  }

  // ── (2) --deep cascade ──────────────────────────────────────────────
  cascade(manager: "people" | "network", apply: boolean): number {
    if (manager === "people") {
      // people-manager reconcile: preview by DEFAULT, --apply commits (same as
      // network below and every other manager).
      return runStreaming(PEOPLE_BIN(), apply ? ["reconcile", "--apply"] : ["reconcile"]);
    }
    // network — system-wide (all zones, all planes). This is THE network pass
    // for the whole cascade; the per-environment legs skip theirs (#461).
    return runStreaming(NETWORK_BIN(), apply ? ["reconcile", "--apply"] : ["reconcile"]);
  }

  listEnvironments(): string[] {
    // Environments registered for this site = config/environments/*.json. The
    // environment NAME is the file basename (sans .json), the arg
    // environment-manager expects.
    const dir = join(defaultConfigDir(), "environments");
    if (!existsSync(dir)) return [];
    return readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => basename(f, ".json"))
      .sort();
  }

  cascadeEnvironment(env: string, apply: boolean): number {
    // VERB FIRST. environment-manager dispatches on argv[0], so the old
    // `<env> reconcile --deep` form died with "Unknown command: <env>" on every
    // environment — the same defect as #454, and silent because nothing looked
    // at the rc. --skip-network: cascade() already ran the one system-wide
    // network pass; repeating it per environment is N identical whole-system
    // runs (#461).
    const args = ["reconcile", env, "--deep", "--skip-network"];
    if (apply) args.push("--apply");
    return runStreaming(ENVIRONMENT_BIN(), args);
  }

  // ── (3) thin delegations to the still-live bash tools ────────────────
  createSite(args: string[]): number {
    return runStreaming(CREATE_SITE(), args);
  }

  repositoryAdd(args: string[]): number {
    return runStreaming(REPOSITORY_SH(), ["add", ...args]);
  }

  repositoryRemove(name: string, force: boolean): number {
    const args = ["remove", name];
    if (force) args.push("--force");
    return runStreaming(REPOSITORY_SH(), args);
  }

  repositoryModify(args: string[]): number {
    // repository.sh modify <name> [--url <u>] [--branch <b>] — re-points origin
    // (forge migration) / switches branch on the live checkout, then edits site.json.
    return runStreaming(REPOSITORY_SH(), ["modify", ...args]);
  }
}
