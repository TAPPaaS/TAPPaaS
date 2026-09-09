"use strict";
// cli.ts — shared CLI conventions for the TAPPaaS TypeScript managers: ANSI
// colors, the info/warn/die logging trio, and the standard run() error guard.
// Replaces the per-manager vendored copies (ADR-007 post-implementation
// refactor, Phase 3).
Object.defineProperty(exports, "__esModule", { value: true });
exports.DieError = exports.CL = exports.GN = exports.RD = exports.YW = void 0;
exports.info = info;
exports.warn = warn;
exports.die = die;
exports.guarded = guarded;
exports.currentUid = currentUid;
exports.requireOperator = requireOperator;
exports.preflightGuard = preflightGuard;
const fs_1 = require("fs");
const child_process_1 = require("child_process");
exports.YW = "\x1b[01;33m";
exports.RD = "\x1b[01;31m";
exports.GN = "\x1b[1;92m";
exports.CL = "\x1b[0m";
function info(msg) {
    console.log(msg);
}
function warn(msg) {
    console.log(`${exports.YW}[Warning]${exports.CL} ${msg}`);
}
// die() prints the [Error] line and throws DieError; guarded() (the standard
// run() wrapper) maps it to exit code 1 without a second print.
class DieError extends Error {
}
exports.DieError = DieError;
function die(msg) {
    console.error(`${exports.RD}[Error]${exports.CL} ${msg}`);
    throw new DieError(msg);
}
// The standard dispatch guard: wrap a manager's run() switch in guarded() so
// every manager maps errors the same way — DieError → 1 (already printed);
// any other Error (config/controller failures: malformed JSON, unreachable
// service) → a clean `[Error] <message>` line + 1, never a raw stack trace;
// non-Error throws propagate (they are bugs and should crash loudly).
function guarded(fn) {
    try {
        return fn();
    }
    catch (e) {
        if (e instanceof DieError)
            return 1;
        if (e instanceof Error) {
            console.error(`${exports.RD}[Error]${exports.CL} ${e.message}`);
            return 1;
        }
        throw e;
    }
}
// ── Preflight guard (#533) ─────────────────────────────────────────────
// current process uid, or -1 where unavailable. A separate helper so tests can
// call requireOperator(uid) with a simulated value.
function currentUid() {
    return typeof process.getuid === "function" ? process.getuid() : -1;
}
// TAPPaaS managers must run as the 'tappaas' operator, never root. Under sudo
// (uid 0) OpenSSH resolves its identity from /root/.ssh via getpwuid() and never
// finds the operator key (ADR-018), and any file the manager writes becomes
// root-owned — the trap that makes the next operator reach for sudo. Refuse root
// outright (die() throws DieError → guarded() maps it to exit 1).
function requireOperator(uid = currentUid()) {
    if (uid === 0) {
        const want = process.env.TAPPAAS_OPERATOR ?? "tappaas";
        die(`TAPPaaS managers must run as the '${want}' operator, not root — do not use sudo. ` +
            `If a config or repo file is root-owned, repair it as ${want}: tappaas-repair-ownership.sh`);
    }
}
// preflightGuard — refuse root, then self-heal ownership drift best-effort by
// invoking the shared repair script when present (absent in dev/test → skipped).
function preflightGuard(uid = currentUid()) {
    requireOperator(uid);
    const repair = "/home/tappaas/bin/tappaas-repair-ownership.sh";
    if ((0, fs_1.existsSync)(repair)) {
        try {
            (0, child_process_1.spawnSync)(repair, [], { stdio: "inherit" });
        }
        catch {
            // best-effort; never block the command
        }
    }
}
