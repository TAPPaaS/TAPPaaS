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
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import { capture as run, captureResult, stream as runStreaming } from "../../../lib/ts/src/exec";
import { SiteClient } from "./types";

// Bin names (overridable via env for tests / relocations).
const GIT = process.env.SITE_GIT_BIN ?? "git";
const VALIDATE_SITE = process.env.SITE_VALIDATE_BIN ?? "validate-site.sh";
const PEOPLE_BIN = process.env.SITE_PEOPLE_BIN ?? "people-manager";
const NETWORK_BIN = process.env.SITE_NETWORK_BIN ?? "network-manager";
// environment-manager exposes `<env> reconcile --deep` (finalized in parallel).
const ENVIRONMENT_BIN = process.env.SITE_ENVIRONMENT_BIN ?? "environment-manager";
// The still-live bash tools `site add` / `repository <verb>` delegate to.
const CREATE_SITE = process.env.SITE_CREATE_BIN ?? "create-site.sh";
const REPOSITORY_SH = process.env.SITE_REPOSITORY_BIN ?? "repository.sh";

export class CliSiteClient implements SiteClient {
  // The schema-dir to pass to validate-site.sh, if known.
  constructor(private schemaDir: string = process.env.SITE_SCHEMA_DIR ?? "") {}

  // ── (1) own concern ─────────────────────────────────────────────────
  repoCloneExists(path: string): boolean {
    return existsSync(path);
  }

  cloneRepo(url: string, path: string, branch: string): void {
    run(GIT, ["clone", `https://${url}`, path]);
    run(GIT, ["-C", path, "checkout", branch]);
  }

  currentBranch(path: string): string | null {
    try {
      const out = run(GIT, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]).trim();
      return out.length > 0 ? out : null;
    } catch {
      return null;
    }
  }

  checkoutRepo(path: string, branch: string): void {
    run(GIT, ["-C", path, "fetch", "origin"]);
    run(GIT, ["-C", path, "checkout", branch]);
  }

  validateSite(siteFile: string): string[] {
    const args = ["--quiet"];
    if (this.schemaDir) args.push("--schema-dir", this.schemaDir);
    args.push(siteFile);
    const r = captureResult(VALIDATE_SITE, args);
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

  // ── (2) --deep cascade ──────────────────────────────────────────────
  cascade(manager: "people" | "network", apply: boolean): void {
    if (manager === "people") {
      // people-manager reconcile: preview by DEFAULT, --apply commits (same as
      // network below and every other manager).
      runStreaming(PEOPLE_BIN, apply ? ["reconcile", "--apply"] : ["reconcile"]);
      return;
    }
    // network
    runStreaming(NETWORK_BIN, apply ? ["reconcile", "--apply"] : ["reconcile"]);
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

  cascadeEnvironment(env: string, apply: boolean): void {
    const args = [env, "reconcile", "--deep"];
    if (apply) args.push("--apply");
    runStreaming(ENVIRONMENT_BIN, args);
  }

  // ── (3) thin delegations to the still-live bash tools ────────────────
  createSite(args: string[]): number {
    return runStreaming(CREATE_SITE, args);
  }

  repositoryAdd(args: string[]): number {
    return runStreaming(REPOSITORY_SH, ["add", ...args]);
  }

  repositoryRemove(name: string, force: boolean): number {
    const args = ["remove", name];
    if (force) args.push("--force");
    return runStreaming(REPOSITORY_SH, args);
  }
}
