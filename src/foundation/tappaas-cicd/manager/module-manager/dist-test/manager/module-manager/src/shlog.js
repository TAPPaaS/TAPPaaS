"use strict";
// shlog.ts — bash-compatible logging for the verbs ported from bash (ADR-007
// post-implementation refactor, Phase 7.3: reconcile-module.sh / inspect-vm.sh).
//
// The retired scripts sourced common-install-routines.sh, whose logging trio
// differs from lib/ts/src/cli.ts in two ways this port preserves so the
// operator-facing output stays byte-comparable:
//   - info() carries a green "[Info] " prefix (lib info() is prefix-less), and
//     is suppressed when TAPPAAS_SILENT=1 (the bash OPT_SILENT gate);
//   - the colors are the common-install-routines palette (YW=\e[33m, CL=\e[m),
//     not the lib palette (YW=\e[01;33m, CL=\e[0m).
// warn/error keep the bash [Warning]/[Error] prefixes; error goes to stderr.
Object.defineProperty(exports, "__esModule", { value: true });
exports.BOLD = exports.CL = exports.DGN = exports.GN = exports.RD = exports.BL = exports.YW = void 0;
exports.info = info;
exports.warn = warn;
exports.error = error;
exports.emitJson = emitJson;
exports.YW = "\x1b[33m"; // Yellow
exports.BL = "\x1b[36m"; // Cyan
exports.RD = "\x1b[01;31m"; // Red
exports.GN = "\x1b[1;92m"; // Green with bold
exports.DGN = "\x1b[32m"; // Green
exports.CL = "\x1b[m"; // Clear
exports.BOLD = "\x1b[1m"; // Bold
function silent() {
    return (process.env.TAPPAAS_SILENT ?? "0") === "1";
}
function info(msg) {
    if (silent())
        return;
    console.log(`${exports.DGN}[Info]${exports.CL} ${msg}`);
}
function warn(msg) {
    console.log(`${exports.YW}[Warning]${exports.CL} ${msg}`);
}
function error(msg) {
    console.error(`${exports.RD}[Error]${exports.CL} ${msg}`);
}
// MACHINE output: the bytes a caller parses, never a log line. info() here
// carries a green "[Info] " prefix for bash parity, which silently corrupts any
// --json payload routed through it (it did, for `resolve --json`, until the
// ADR-020 drift record needed to be piped into `update-service.sh`). Anything a
// program reads goes through this, and is exempt from TAPPAAS_SILENT: a caller
// that asked for data must get data or an error, never silence.
function emitJson(value) {
    process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}
