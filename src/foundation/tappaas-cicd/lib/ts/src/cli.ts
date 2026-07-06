// cli.ts — shared CLI conventions for the TAPPaaS TypeScript managers: ANSI
// colors, the info/warn/die logging trio, and the standard run() error guard.
// Replaces the per-manager vendored copies (ADR-007 post-implementation
// refactor, Phase 3).

export const YW = "\x1b[01;33m";
export const RD = "\x1b[01;31m";
export const GN = "\x1b[1;92m";
export const CL = "\x1b[0m";

export function info(msg: string): void {
  console.log(msg);
}

export function warn(msg: string): void {
  console.log(`${YW}[Warning]${CL} ${msg}`);
}

// die() prints the [Error] line and throws DieError; guarded() (the standard
// run() wrapper) maps it to exit code 1 without a second print.
export class DieError extends Error {}

export function die(msg: string): never {
  console.error(`${RD}[Error]${CL} ${msg}`);
  throw new DieError(msg);
}

// The standard dispatch guard: wrap a manager's run() switch in guarded() so
// every manager maps errors the same way — DieError → 1 (already printed);
// any other Error (config/controller failures: malformed JSON, unreachable
// service) → a clean `[Error] <message>` line + 1, never a raw stack trace;
// non-Error throws propagate (they are bugs and should crash loudly).
export function guarded(fn: () => number): number {
  try {
    return fn();
  } catch (e) {
    if (e instanceof DieError) return 1;
    if (e instanceof Error) {
      console.error(`${RD}[Error]${CL} ${e.message}`);
      return 1;
    }
    throw e;
  }
}
