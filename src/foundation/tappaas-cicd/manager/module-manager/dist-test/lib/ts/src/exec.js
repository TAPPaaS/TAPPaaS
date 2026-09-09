"use strict";
// exec.ts — shared spawnSync plumbing for the manager → controller/bash FFI
// boundary (ADR-007 post-implementation refactor, Phase 3). Always argv
// arrays, never a shell; the env always carries the resolved config root in
// BOTH spellings so bash children (CONFIG_DIR) and TS children
// (TAPPAAS_CONFIG) agree on where the live config lives.
Object.defineProperty(exports, "__esModule", { value: true });
exports.configEnv = configEnv;
exports.captureResult = captureResult;
exports.capture = capture;
exports.stream = stream;
const child_process_1 = require("child_process");
const config_io_1 = require("./config-io");
// Capped, generous buffer for captured child output (the historical value
// every manager used).
const MAX_BUFFER = 64 * 1024 * 1024;
function configEnv() {
    const cd = (0, config_io_1.defaultConfigDir)();
    return { ...process.env, CONFIG_DIR: cd, TAPPAAS_CONFIG: cd };
}
// Run + capture, never throwing on non-zero exit: callers that need the rc /
// output triple (e.g. scraping a validator's stderr) use this.
function captureResult(bin, args) {
    const r = (0, child_process_1.spawnSync)(bin, args, {
        encoding: "utf8",
        env: configEnv(),
        maxBuffer: MAX_BUFFER,
    });
    if (r.error) {
        return { rc: -1, stdout: "", stderr: r.error.message, ran: false };
    }
    return { rc: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "", ran: true };
}
// Run + capture stdout; THROW on spawn failure or non-zero exit with the
// unified message every manager used to hand-roll.
function capture(bin, args) {
    const r = (0, child_process_1.spawnSync)(bin, args, {
        encoding: "utf8",
        env: configEnv(),
        maxBuffer: MAX_BUFFER,
    });
    if (r.error)
        throw new Error(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
    if (r.status !== 0) {
        const stderr = (r.stderr ?? "").trim();
        throw new Error(`${bin} ${args.join(" ")} failed (exit ${r.status}): ${stderr}`);
    }
    return r.stdout ?? "";
}
// Run streaming the child's output to the operator's terminal (stdio inherit)
// — for long-running delegations whose own progress should be visible.
// Returns the exit code; throws only when the binary cannot be spawned.
// opts.cwd runs the child from a specific directory (module-manager reconcile
// runs a module's ./update.sh from the module directory, like the bash did).
// opts.env is merged OVER configEnv() — for delegations that must plumb extra
// environment down to the child (e.g. site-manager update forwarding
// TAPPAAS_MODULE_FORCE / TAPPAAS_NO_GIT_PULL to the update sweep).
function stream(bin, args, opts) {
    const r = (0, child_process_1.spawnSync)(bin, args, {
        encoding: "utf8",
        stdio: "inherit",
        env: { ...configEnv(), ...(opts?.env ?? {}) },
        ...(opts?.cwd ? { cwd: opts.cwd } : {}),
    });
    if (r.error)
        throw new Error(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
    return r.status ?? -1;
}
