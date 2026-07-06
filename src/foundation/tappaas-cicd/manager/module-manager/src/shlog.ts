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

export const YW = "\x1b[33m"; // Yellow
export const BL = "\x1b[36m"; // Cyan
export const RD = "\x1b[01;31m"; // Red
export const GN = "\x1b[1;92m"; // Green with bold
export const DGN = "\x1b[32m"; // Green
export const CL = "\x1b[m"; // Clear
export const BOLD = "\x1b[1m"; // Bold

function silent(): boolean {
  return (process.env.TAPPAAS_SILENT ?? "0") === "1";
}

export function info(msg: string): void {
  if (silent()) return;
  console.log(`${DGN}[Info]${CL} ${msg}`);
}

export function warn(msg: string): void {
  console.log(`${YW}[Warning]${CL} ${msg}`);
}

export function error(msg: string): void {
  console.error(`${RD}[Error]${CL} ${msg}`);
}
