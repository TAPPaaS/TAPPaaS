// reconcile.ts — the LEAF re-apply (`module reconcile --apply`), the native TS
// port of the retired reconcile-module.sh (ADR-007 post-implementation
// refactor, Phase 7.3).
//
// Re-applies an already-installed module's CURRENT config to its VM/service,
// idempotently, WITHOUT changing the config. This is the leaf the
// `reconcile --deep` cascade depends on (site → environment → module), so it
// MUST be safe to run anytime and converge to the same state.
//
// It deliberately does LESS than update-module.sh — that distinction is the
// whole point of `reconcile` vs `modify`:
//
//   reconcile (this)               update-module.sh (= `module modify`)
//   ────────────────               ────────────────────────────────────
//   NO snapshot                    pre-update VM snapshot + rollback
//   NO pre/post tests              pre + post test-module.sh
//   NO 3-way merge of config       3-way merge release source into config
//   NO updateTime bump             bumps updateTime
//   re-apply current config only   release update of the module
//
// What it DOES (in order), exactly as the bash did:
//   1. Validate the module config exists (and is well-formed JSON — the full
//      module-fields.json schema lint stays with install/modify; deliberate
//      delta vs the bash check_json call).
//   2. Call each dependsOn provider's install-service.sh <module> — the
//      idempotent ensure/apply scripts (VM present, proxy wired, rules applied,
//      backup registered, …). Re-running them converges the live plane to the
//      module's current config.
//   3. Run the module's own update.sh (preferred) or install.sh as the in-VM
//      converge step, against the existing config, from the module directory.
//
// Exit codes: 0 = converged; 1 = a converge step failed.

import { chmodSync, existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { stream } from "../../../lib/ts/src/exec";
import {
  defaultConfigDir,
  getModuleDir,
  normalizeModuleConfig,
  resolveEffectiveModuleName,
  resolveProviderModule,
} from "./config";
import { ReconcileOptions } from "./types";
import { BL, BOLD, CL, GN, error, info, warn } from "./shlog";

// die-equivalent: thrown to unwind to reconcileModule(), printed once there.
class ReconcileFailure extends Error {}

function fail(msg: string): never {
  throw new ReconcileFailure(msg);
}

// Port of ensure_scripts_executable: chmod +x every root-level *.sh and every
// services/*/*.sh in a module directory (they arrive from git without the
// executable bit on some paths).
function ensureScriptsExecutable(dir: string): void {
  const chmodShFiles = (d: string): void => {
    let entries: string[];
    try {
      entries = readdirSync(d);
    } catch {
      return;
    }
    for (const f of entries) {
      if (!f.endsWith(".sh")) continue;
      const p = join(d, f);
      try {
        if (statSync(p).isFile()) chmodSync(p, 0o755);
      } catch {
        // best-effort, exactly like the bash loop
      }
    }
  };
  let isDir = false;
  try {
    isDir = statSync(dir).isDirectory();
  } catch {
    return;
  }
  if (!isDir) return;
  chmodShFiles(dir);
  const services = join(dir, "services");
  let svcDirs: string[] = [];
  try {
    svcDirs = readdirSync(services);
  } catch {
    return;
  }
  for (const s of svcDirs) chmodShFiles(join(services, s));
}

// Spawn a converge script, streaming its output; a spawn failure (missing /
// non-executable file) is reported like a failed step rather than crashing.
function runScript(bin: string, args: string[], cwd?: string): number {
  try {
    const rc = stream(bin, args, cwd ? { cwd } : undefined);
    return rc === -1 ? 1 : rc;
  } catch (e) {
    error(`${bin}: ${e instanceof Error ? e.message : String(e)}`);
    return 127;
  }
}

export function reconcileModule(moduleArg: string, opts: ReconcileOptions): number {
  // The bash exported these so every child script inherited the verbosity; the
  // TS port does the same (exec.configEnv() spreads process.env), and shlog's
  // own --silent gate reads TAPPAAS_SILENT too.
  if (opts.debug) process.env.TAPPAAS_DEBUG = "1";
  if (opts.silent) process.env.TAPPAAS_SILENT = "1";

  try {
    doReconcile(moduleArg, opts);
    return 0;
  } catch (e) {
    if (e instanceof ReconcileFailure) {
      error(e.message);
      return 1;
    }
    throw e;
  }
}

function doReconcile(moduleArg: string, opts: ReconcileOptions): void {
  const configDir = defaultConfigDir();
  let module = moduleArg;

  // ADR-007 P5: map a base module + --environment to the installed config name
  // (<module>-<env> for a non-default/non-mgmt env), only when the base name is
  // not itself deployed — mirroring the bash resolve_effective_module_name.
  if (opts.environment) {
    const eff = resolveEffectiveModuleName(configDir, module, opts.environment);
    if (eff !== module && !existsSync(join(configDir, `${module}.json`))) {
      module = eff;
    }
  }

  const moduleJson = join(configDir, `${module}.json`);

  info(`${BOLD}╔══════════════════════════════════════════════╗${CL}`);
  info(`${BOLD}║  TAPPaaS Module Reconcile: ${BL}${module}${CL}`);
  info(`${BOLD}╚══════════════════════════════════════════════╝${CL}`);

  // ── Step 1: Validate module config ───────────────────────────────
  console.log("");
  info(`${BOLD}Step 1: Validate module configuration${CL}`);
  if (!existsSync(moduleJson)) {
    fail(
      `Module config not found: ${moduleJson} — is the module installed? ` +
        `(reconcile re-applies an EXISTING module; use install-module.sh to create one)`,
    );
  }
  let raw: Record<string, unknown> | null = null;
  try {
    raw = readJsonObject(moduleJson);
  } catch {
    fail(`JSON validation failed for ${module}`);
  }
  if (!raw) fail(`JSON validation failed for ${module}`);
  info(`  ${GN}✓${CL} ${moduleJson}`);

  // ── Step 2: Re-apply dependency services (idempotent ensure/apply) ──
  console.log("");
  info(`${BOLD}Step 2: Re-apply dependency services${CL}`);

  const cfg = normalizeModuleConfig(raw);
  const dependsOn = Array.isArray(cfg.dependsOn)
    ? cfg.dependsOn.filter((d): d is string => typeof d === "string")
    : [];

  // The CONSUMING module's environment drives provider resolution below (#438).
  // Read it from the DEPLOYED config rather than opts.environment: reconcile is
  // routinely invoked without --environment on an already-suffixed module name,
  // and the persisted field is the authority either way.
  const moduleEnvironment = typeof cfg.environment === "string" ? cfg.environment : "";

  if (dependsOn.length === 0) {
    info("  No dependency services to re-apply");
  } else {
    let failures = 0;
    for (const dep of dependsOn) {
      const colon = dep.indexOf(":");
      const providerName = colon === -1 ? dep : dep.slice(0, colon); // ${dep%%:*}
      const serviceName = dep.slice(dep.lastIndexOf(":") + 1); // ${dep##*:}

      const providerModule = resolveProviderModule(configDir, providerName, moduleEnvironment);
      const providerDir = getModuleDir(configDir, providerModule);
      if (!providerDir) {
        warn(`  Cannot find provider '${providerModule}' location — skipping ${dep}`);
        continue;
      }
      ensureScriptsExecutable(providerDir);

      // install-service.sh is the idempotent ensure/apply entry (the same one
      // install-module.sh calls). Re-running it converges the plane to the
      // module's current config. Skip cleanly when a provider has none.
      const svcScript = join(providerDir, "services", serviceName, "install-service.sh");
      if (!existsSync(svcScript)) {
        info(`  ${dep}: no install-service.sh — skipping`);
        continue;
      }

      info(`  Re-applying ${BL}${dep}${CL} for '${module}'...`);
      if (runScript(svcScript, [module]) === 0) {
        info(`  ${GN}✓${CL} ${dep} converged`);
      } else {
        error(`  ✗ ${dep} re-apply failed`);
        failures++;
      }
    }
    if (failures > 0) {
      fail(
        `${failures} dependency service(s) failed to re-apply — reconcile of '${module}' did not converge`,
      );
    }
  }

  // ── Step 3: Re-apply the module itself (in-VM converge) ───────────
  console.log("");
  info(`${BOLD}Step 3: Re-apply the module${CL}`);

  const moduleDir = getModuleDir(configDir, module);
  if (moduleDir) {
    ensureScriptsExecutable(moduleDir);
    // Prefer update.sh (the steady-state converge) over install.sh. NO
    // updateTime bump, NO snapshot, NO test — that is what makes this a
    // reconcile, not an update. Run from the module directory, as bash did.
    if (existsSync(join(moduleDir, "update.sh"))) {
      info(`  Running ${moduleDir}/update.sh (converge)...`);
      if (runScript("./update.sh", [module], moduleDir) !== 0) {
        fail("Module update.sh failed during reconcile");
      }
      info(`  ${GN}✓${CL} module update.sh converged`);
    } else if (existsSync(join(moduleDir, "install.sh"))) {
      info(`  No update.sh — running ${moduleDir}/install.sh (idempotent re-apply)...`);
      if (runScript("./install.sh", [module], moduleDir) !== 0) {
        fail("Module install.sh failed during reconcile");
      }
      info(`  ${GN}✓${CL} module install.sh converged`);
    } else {
      info("  No update.sh/install.sh in module directory — nothing to re-apply in-VM");
    }
  } else {
    warn("Cannot find module directory (missing .location) — skipping in-VM re-apply");
  }

  console.log("");
  info(`${GN}${BOLD}Module '${module}' reconciled (converged to current config)${CL}`);
}
