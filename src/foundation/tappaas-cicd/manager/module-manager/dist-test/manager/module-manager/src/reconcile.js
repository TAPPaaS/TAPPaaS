"use strict";
// reconcile.ts — the LEAF re-apply (`module reconcile --apply`), the native TS
// port of the retired reconcile-module.sh (ADR-007 post-implementation
// refactor, Phase 7.3).
//
// Re-applies an already-installed module's CURRENT config to its VM/service,
// idempotently, WITHOUT changing the config. This is the leaf the
// `reconcile --deep` cascade depends on (site → environment → module), so it
// MUST be safe to run anytime and converge to the same state.
//
// Since #495 this IS the apply for both verbs: update-module.sh (= `module
// modify`) merges the release source into the config, then calls
// `module-manager reconcile --apply` for the apply itself, wrapped in the
// safety machinery a config CHANGE needs and a re-apply does not:
//
//   reconcile (this)               update-module.sh (= `module modify`)
//   ────────────────               ────────────────────────────────────
//   NO snapshot                    pre-update VM snapshot + rollback
//   NO pre/post tests              pre + post test-module.sh
//   NO 3-way merge of config       3-way merge release source into config
//   NO updateTime bump             bumps updateTime
//   re-apply current config only   release update, then delegates here
//
// What it DOES (in order), exactly as the bash did:
//   1. Validate the module config exists (and is well-formed JSON — the full
//      module-fields.json schema lint stays with install/modify; deliberate
//      delta vs the bash check_json call).
//   2. Call each dependsOn provider's update-service.sh <module> — the converge
//      scripts (VM hardware reconciled, proxy wired, rules swept, backup
//      registered, …), run FROM the module directory. Re-running them converges
//      the live plane to the module's current config. This is the SAME entry
//      point update-module.sh uses, so `modify` and `reconcile --apply` apply
//      identically (#495).
//   3. Run the module's own update.sh (preferred) or install.sh as the in-VM
//      converge step, against the existing config, from the module directory.
//      Step 3 runs even when Step 2 reported failures — some providers perform
//      destructive re-applies (a NixOS rebuild) that only the module's own
//      update.sh repairs, so skipping it left instances WORSE than before (#495).
//
// Exit codes: 0 = converged; 1 = a converge step failed.
Object.defineProperty(exports, "__esModule", { value: true });
exports.reconcileModule = reconcileModule;
const fs_1 = require("fs");
const path_1 = require("path");
const config_io_1 = require("../../../lib/ts/src/config-io");
const exec_1 = require("../../../lib/ts/src/exec");
const config_1 = require("./config");
const services_1 = require("./services");
const shlog_1 = require("./shlog");
// die-equivalent: thrown to unwind to reconcileModule(), printed once there.
class ReconcileFailure extends Error {
}
function fail(msg) {
    throw new ReconcileFailure(msg);
}
// The tracked-100755 .sh basenames directly in `d` (git pathspec is scoped to
// `d`, and the no-slash filter keeps only its immediate children). Returns null
// when `d` is not a git checkout, so the caller falls back to shebang-presence
// — mirroring the bash tappaas_should_be_executable (#565).
function trackedExecutables(d) {
    const r = (0, exec_1.captureResult)("git", ["-C", d, "ls-files", "-s", "--", "*.sh"]);
    if (!r.ran || r.rc !== 0)
        return null;
    const out = new Set();
    for (const line of r.stdout.split("\n")) {
        if (!line.startsWith("100755 "))
            continue; // tracked executable only
        const tab = line.indexOf("\t");
        if (tab === -1)
            continue;
        const path = line.slice(tab + 1);
        if (path.includes("/"))
            continue; // immediate children of `d` only
        out.add(path);
    }
    return out;
}
function hasShebang(p) {
    try {
        return (0, fs_1.readFileSync)(p).subarray(0, 2).toString() === "#!";
    }
    catch {
        return false;
    }
}
// Port of ensure_scripts_executable: set +x on the root-level *.sh and every
// services/*/*.sh a module directory tracks as executable. #565: honour the
// tracked git mode — a sourced library committed 100644 must NOT be widened,
// or it shows as spurious mode drift on the control-plane checkout (the bash
// path gates the same way). Falls back to shebang-presence for a non-repo dir.
function ensureScriptsExecutable(dir) {
    const chmodShFiles = (d) => {
        let entries;
        try {
            entries = (0, fs_1.readdirSync)(d);
        }
        catch {
            return;
        }
        const tracked = trackedExecutables(d); // null = not a git checkout
        for (const f of entries) {
            if (!f.endsWith(".sh"))
                continue;
            const p = (0, path_1.join)(d, f);
            try {
                if (!(0, fs_1.statSync)(p).isFile())
                    continue;
                const wants = tracked ? tracked.has(f) : hasShebang(p);
                if (wants)
                    (0, fs_1.chmodSync)(p, 0o755);
            }
            catch {
                // best-effort, exactly like the bash loop
            }
        }
    };
    let isDir = false;
    try {
        isDir = (0, fs_1.statSync)(dir).isDirectory();
    }
    catch {
        return;
    }
    if (!isDir)
        return;
    chmodShFiles(dir);
    const services = (0, path_1.join)(dir, "services");
    let svcDirs = [];
    try {
        svcDirs = (0, fs_1.readdirSync)(services);
    }
    catch {
        return;
    }
    for (const s of svcDirs)
        chmodShFiles((0, path_1.join)(services, s));
}
// Spawn a converge script, streaming its output; a spawn failure (missing /
// non-executable file) is reported like a failed step rather than crashing.
function runScript(bin, args, cwd) {
    try {
        const rc = (0, exec_1.stream)(bin, args, cwd ? { cwd } : undefined);
        return rc === -1 ? 1 : rc;
    }
    catch (e) {
        (0, shlog_1.error)(`${bin}: ${e instanceof Error ? e.message : String(e)}`);
        return 127;
    }
}
function reconcileModule(moduleArg, opts) {
    // The bash exported these so every child script inherited the verbosity; the
    // TS port does the same (exec.configEnv() spreads process.env), and shlog's
    // own --silent gate reads TAPPAAS_SILENT too.
    if (opts.debug)
        process.env.TAPPAAS_DEBUG = "1";
    if (opts.silent)
        process.env.TAPPAAS_SILENT = "1";
    try {
        doReconcile(moduleArg, opts);
        return 0;
    }
    catch (e) {
        if (e instanceof ReconcileFailure) {
            (0, shlog_1.error)(e.message);
            return 1;
        }
        throw e;
    }
}
function doReconcile(moduleArg, opts) {
    const configDir = (0, config_1.defaultConfigDir)();
    let module = moduleArg;
    // ADR-007 P5: map a base module + --environment to the installed config name
    // (<module>-<env> for a non-default/non-mgmt env), only when the base name is
    // not itself deployed — mirroring the bash resolve_effective_module_name.
    if (opts.environment) {
        const eff = (0, config_1.resolveEffectiveModuleName)(configDir, module, opts.environment);
        if (eff !== module && !(0, fs_1.existsSync)((0, path_1.join)(configDir, `${module}.json`))) {
            module = eff;
        }
    }
    const moduleJson = (0, path_1.join)(configDir, `${module}.json`);
    (0, shlog_1.info)(`${shlog_1.BOLD}╔══════════════════════════════════════════════╗${shlog_1.CL}`);
    (0, shlog_1.info)(`${shlog_1.BOLD}║  TAPPaaS Module Reconcile: ${shlog_1.BL}${module}${shlog_1.CL}`);
    (0, shlog_1.info)(`${shlog_1.BOLD}╚══════════════════════════════════════════════╝${shlog_1.CL}`);
    // ── Step 1: Validate module config ───────────────────────────────
    console.log("");
    (0, shlog_1.info)(`${shlog_1.BOLD}Step 1: Validate module configuration${shlog_1.CL}`);
    if (!(0, fs_1.existsSync)(moduleJson)) {
        fail(`Module config not found: ${moduleJson} — is the module installed? ` +
            `(reconcile re-applies an EXISTING module; use install-module.sh to create one)`);
    }
    let raw = null;
    try {
        raw = (0, config_io_1.readJsonObject)(moduleJson);
    }
    catch {
        fail(`JSON validation failed for ${module}`);
    }
    if (!raw)
        fail(`JSON validation failed for ${module}`);
    (0, shlog_1.info)(`  ${shlog_1.GN}✓${shlog_1.CL} ${moduleJson}`);
    // The module directory is resolved BEFORE Step 2, not just for Step 3: the
    // dependency service scripts must run FROM it (#495). update-module.sh has
    // always cd'd there first ("so service scripts can find module files"), and
    // the TS port dropped that, which is why templates:nixos could not find the
    // module's .nix unless reconcile happened to be invoked from the module's own
    // directory. The underlying resolver is fixed too (update-os.sh
    // resolve_nixos_config now searches .location), but a converge must not depend
    // on the caller's cwd in the first place.
    const moduleDirResult = (0, config_1.getModuleDirResult)(configDir, module);
    const moduleDir = moduleDirResult.kind === "found" ? moduleDirResult.dir : null;
    // ── Step 2: Re-apply dependency services (idempotent ensure/apply) ──
    console.log("");
    (0, shlog_1.info)(`${shlog_1.BOLD}Step 2: Re-apply dependency services${shlog_1.CL}`);
    const cfg = (0, config_1.normalizeModuleConfig)(raw);
    const asStrings = (v) => Array.isArray(v) ? v.filter((d) => typeof d === "string") : [];
    const dependsOn = asStrings(cfg.dependsOn);
    // Optional integrations (#501): same converge path as dependsOn, but a provider
    // that is not installed is skipped silently rather than warned about.
    const integratesWith = asStrings(cfg.integratesWith);
    // The CONSUMING module's environment drives provider resolution below (#438).
    // Read it from the DEPLOYED config rather than opts.environment: reconcile is
    // routinely invoked without --environment on an already-suffixed module name,
    // and the persisted field is the authority either way.
    const moduleEnvironment = typeof cfg.environment === "string" ? cfg.environment : "";
    // Step 2 failures are ACCUMULATED, not thrown (#495). Aborting here used to
    // skip Step 3 entirely, and that is actively destructive: a provider such as
    // templates:nixos performs a rebuild that rewrites in-VM state which only the
    // module's own update.sh restores. Bailing out after the rebuild left the
    // instance LESS converged than before the command ran. A re-apply must never
    // do that, so Step 3 always gets its chance and the failure is reported after.
    const depFailures = [];
    // Coordinates whose apply script exited 0 — the ones Step 4 must then VERIFY.
    const applied = [];
    // Converge one coordinate via its provider's update-service.sh. `optional`
    // (integratesWith) downgrades a not-installed provider from a warning to an
    // info line and never records it as a failure — the whole point of the soft
    // guard (#501). update-service.sh is THE converge entry point for an
    // already-installed module — the same one update-module.sh (`module modify`)
    // calls (#495). reconcile used to call install-service.sh instead, which has
    // CREATE semantics: cluster:vm's went straight to Create-TAPPaaS-VM.sh, which
    // exits 1 on an existing VMID, so reconcile failed on every VM-backed module.
    // There is deliberately NO fallback to install-service.sh: a service that
    // cannot converge is a contract violation caught by test.sh. Skip cleanly when
    // a provider ships no service script at all.
    const applyConverge = (dep, optional) => {
        const colon = dep.indexOf(":");
        const providerName = colon === -1 ? dep : dep.slice(0, colon); // ${dep%%:*}
        const serviceName = dep.slice(dep.lastIndexOf(":") + 1); // ${dep##*:}
        const providerModule = (0, config_1.resolveProviderModule)(configDir, providerName, moduleEnvironment);
        const providerDir = (0, config_1.getModuleDir)(configDir, providerModule);
        if (!providerDir) {
            if (optional)
                (0, shlog_1.info)(`  ${dep}: provider '${providerModule}' not installed — skipping optional integration`);
            else
                (0, shlog_1.warn)(`  Cannot find provider '${providerModule}' location — skipping ${dep}`);
            return;
        }
        ensureScriptsExecutable(providerDir);
        const svcScript = (0, path_1.join)(providerDir, "services", serviceName, "update-service.sh");
        if (!(0, fs_1.existsSync)(svcScript)) {
            (0, shlog_1.info)(`  ${dep}: no update-service.sh — skipping`);
            return;
        }
        (0, shlog_1.info)(`  Re-applying ${shlog_1.BL}${dep}${shlog_1.CL} for '${module}'...`);
        // --force is DISRUPTION AUTHORIZATION (ADR-020 D8), not "ignore errors":
        // without it a change that needs a reboot or an offline migrate is deferred
        // rather than applied. Forwarded verbatim so the decision is made once, by
        // the operator, and every provider sees the same answer.
        const svcArgs = opts.force ? [module, "--force"] : [module];
        // Run from the module directory (#495) — same cwd update-module.sh uses.
        if (runScript(svcScript, svcArgs, moduleDir ?? undefined) === 0) {
            // "re-applied", NOT "converged" (#583). All this measures is that the
            // apply script exited 0. Whether the live plane actually reached the
            // declared state is what the provider's test-service.sh answers, and that
            // runs in Step 4 — alfen:nat printed "converged" here while its own
            // verifier reported both rules MISSING in the same run.
            (0, shlog_1.info)(`  ${shlog_1.GN}✓${shlog_1.CL} ${dep} re-applied`);
            applied.push(dep);
        }
        else {
            (0, shlog_1.error)(`  ✗ ${dep} re-apply failed`);
            depFailures.push(dep);
        }
    };
    if (dependsOn.length === 0) {
        (0, shlog_1.info)("  No dependency services to re-apply");
    }
    else {
        for (const dep of dependsOn)
            applyConverge(dep, false);
    }
    // Optional integrations converge with the same code path (#501); a provider
    // that is simply not installed is expected here, not an error.
    if (integratesWith.length > 0) {
        (0, shlog_1.info)("  Optional integrations (integratesWith):");
        for (const dep of integratesWith)
            applyConverge(dep, true);
    }
    // ── Step 3: Re-apply the module itself (in-VM converge) ───────────
    console.log("");
    (0, shlog_1.info)(`${shlog_1.BOLD}Step 3: Re-apply the module${shlog_1.CL}`);
    if (moduleDir) {
        ensureScriptsExecutable(moduleDir);
        // Prefer update.sh (the steady-state converge) over install.sh. NO
        // updateTime bump, NO snapshot, NO test — that is what makes this a
        // reconcile, not an update. Run from the module directory, as bash did.
        if ((0, fs_1.existsSync)((0, path_1.join)(moduleDir, "update.sh"))) {
            (0, shlog_1.info)(`  Running ${moduleDir}/update.sh (converge)...`);
            if (runScript("./update.sh", [module], moduleDir) !== 0) {
                fail(stepFailure("Module update.sh failed during reconcile", depFailures));
            }
            (0, shlog_1.info)(`  ${shlog_1.GN}✓${shlog_1.CL} module update.sh converged`);
        }
        else if ((0, fs_1.existsSync)((0, path_1.join)(moduleDir, "install.sh"))) {
            (0, shlog_1.info)(`  No update.sh — running ${moduleDir}/install.sh (idempotent re-apply)...`);
            if (runScript("./install.sh", [module], moduleDir) !== 0) {
                fail(stepFailure("Module install.sh failed during reconcile", depFailures));
            }
            (0, shlog_1.info)(`  ${shlog_1.GN}✓${shlog_1.CL} module install.sh converged`);
        }
        else {
            (0, shlog_1.info)("  No update.sh/install.sh in module directory — nothing to re-apply in-VM");
        }
    }
    else if (moduleDirResult.kind === "missing-dir") {
        // #460: recorded but gone — a moved/removed checkout, not a module that
        // never had a directory. Naming the path is the difference between a
        // fixable report and a shrug.
        (0, shlog_1.warn)(`Module directory recorded but missing: ${moduleDirResult.dir} — skipping in-VM re-apply`);
    }
    else {
        (0, shlog_1.warn)("Cannot find module directory (no .location in config) — skipping in-VM re-apply");
    }
    // ── Step 4: Verify the planes that were re-applied (#583) ─────────
    //
    // A converge that is not measured is a claim, not a result. `--apply` used to
    // print "converged" off the apply script's exit code alone and never run the
    // provider's verifier at all, so `reconcile <m> --apply` said converged and
    // `reconcile <m>` immediately after said DRIFT — for the same coordinate, from
    // the same state. Two services showed that shape (alfen:nat, network:proxy),
    // which makes it a reconcile-level defect rather than a per-service one.
    //
    // Deliberately AFTER Step 3, not inside Step 2: several verifiers legitimately
    // need the module itself to be up (network:proxy curls its endpoint), so
    // checking between the service apply and the in-VM converge would fail modules
    // that are converging correctly.
    //
    // Same verifier inspect uses — checkDependencyServices — so a coordinate
    // cannot be clean under one verb and drifted under the other.
    let verifyDrift = 0;
    let verifyUnknown = 0;
    if (applied.length > 0) {
        console.log("");
        (0, shlog_1.info)(`${shlog_1.BOLD}Step 4: Verify the re-applied services${shlog_1.CL}`);
        const svc = (0, services_1.checkDependencyServices)(configDir, module, applied, moduleEnvironment);
        for (const l of svc.lines) {
            if (l.kind === "raw")
                console.log(l.text);
            else if (l.kind === "info")
                (0, shlog_1.info)(l.text);
            else if (l.kind === "warn")
                (0, shlog_1.warn)(l.text);
            else
                (0, shlog_1.error)(l.text);
        }
        for (const l of (0, services_1.serviceSummaryLines)(module, svc)) {
            if (l.kind === "warn")
                (0, shlog_1.warn)(l.text);
            else if (l.kind === "error")
                (0, shlog_1.error)(l.text);
            else
                (0, shlog_1.info)(l.text);
        }
        verifyDrift = svc.drift;
        verifyUnknown = svc.unknown;
    }
    console.log("");
    if (verifyDrift > 0 || verifyUnknown > 0) {
        // The apply ran and returned 0; the plane still does not match. Reporting
        // this as success is the whole of #583, so it is a failure — and it names
        // the drift rather than the apply, because the apply is not what went wrong.
        const parts = [];
        if (verifyDrift > 0)
            parts.push(`${verifyDrift} drifted`);
        if (verifyUnknown > 0)
            parts.push(`${verifyUnknown} unverifiable`);
        fail(`re-applied, but ${parts.join(" and ")} after the fact — reconcile of ` +
            `'${module}' did NOT converge. The apply scripts returned success; the ` +
            `providers' own test-service.sh disagree. A known cause for a NAT/proxy ` +
            `plane is a firewall-wide precondition the apply cannot see (ADR-016: ` +
            `source-NAT rules are inert while OPNsense snat_mode is 'automatic').`);
    }
    if (depFailures.length > 0) {
        // Step 3 ran regardless, so the module's own converge has had its chance —
        // but the dependency planes did not converge, so this is still a failure.
        fail(`${depFailures.length} dependency service(s) failed to re-apply ` +
            `(${depFailures.join(", ")}) — reconcile of '${module}' did not converge. ` +
            `The module's own re-apply (Step 3) was still run.`);
    }
    (0, shlog_1.info)(`${shlog_1.GN}${shlog_1.BOLD}Module '${module}' reconciled (converged to current config)${shlog_1.CL}`);
}
// Compose a Step 3 failure message that does not hide Step 2 failures behind it.
function stepFailure(msg, depFailures) {
    if (depFailures.length === 0)
        return msg;
    return `${msg} (and ${depFailures.length} dependency service(s) had already failed: ${depFailures.join(", ")})`;
}
