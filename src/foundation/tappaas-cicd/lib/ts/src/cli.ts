// cli.ts — shared CLI conventions for the TAPPaaS TypeScript managers: ANSI
// colors, the info/warn/die logging trio, and the standard run() error guard.
// Replaces the per-manager vendored copies (ADR-007 post-implementation
// refactor, Phase 3).

import { existsSync } from "fs";
import { spawnSync } from "child_process";

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

// ── Preflight guard (#533) ─────────────────────────────────────────────
// current process uid, or -1 where unavailable. A separate helper so tests can
// call requireOperator(uid) with a simulated value.
export function currentUid(): number {
  return typeof process.getuid === "function" ? process.getuid() : -1;
}

// TAPPaaS managers must run as the 'tappaas' operator, never root. Under sudo
// (uid 0) OpenSSH resolves its identity from /root/.ssh via getpwuid() and never
// finds the operator key (ADR-018), and any file the manager writes becomes
// root-owned — the trap that makes the next operator reach for sudo. Refuse root
// outright (die() throws DieError → guarded() maps it to exit 1).
export function requireOperator(uid: number = currentUid()): void {
  if (uid === 0) {
    const want = process.env.TAPPAAS_OPERATOR ?? "tappaas";
    die(
      `TAPPaaS managers must run as the '${want}' operator, not root — do not use sudo. ` +
        `If a config or repo file is root-owned, repair it as ${want}: tappaas-repair-ownership.sh`,
    );
  }
}

// preflightGuard — refuse root, then self-heal ownership drift best-effort by
// invoking the shared repair script when present (absent in dev/test → skipped).
export function preflightGuard(uid: number = currentUid()): void {
  requireOperator(uid);
  const repair = "/home/tappaas/bin/tappaas-repair-ownership.sh";
  if (existsSync(repair)) {
    try {
      spawnSync(repair, [], { stdio: "inherit" });
    } catch {
      // best-effort; never block the command
    }
  }
}
