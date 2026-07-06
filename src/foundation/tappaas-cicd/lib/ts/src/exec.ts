// exec.ts — shared spawnSync plumbing for the manager → controller/bash FFI
// boundary (ADR-007 post-implementation refactor, Phase 3). Always argv
// arrays, never a shell; the env always carries the resolved config root in
// BOTH spellings so bash children (CONFIG_DIR) and TS children
// (TAPPAAS_CONFIG) agree on where the live config lives.

import { spawnSync } from "child_process";
import { defaultConfigDir } from "./config-io";

// Capped, generous buffer for captured child output (the historical value
// every manager used).
const MAX_BUFFER = 64 * 1024 * 1024;

export function configEnv(): Record<string, string | undefined> {
  const cd = defaultConfigDir();
  return { ...process.env, CONFIG_DIR: cd, TAPPAAS_CONFIG: cd };
}

export interface ExecResult {
  rc: number;
  stdout: string;
  stderr: string;
  // false when the binary could not be spawned at all (missing on PATH).
  ran: boolean;
}

// Run + capture, never throwing on non-zero exit: callers that need the rc /
// output triple (e.g. scraping a validator's stderr) use this.
export function captureResult(bin: string, args: string[]): ExecResult {
  const r = spawnSync(bin, args, {
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
export function capture(bin: string, args: string[]): string {
  const r = spawnSync(bin, args, {
    encoding: "utf8",
    env: configEnv(),
    maxBuffer: MAX_BUFFER,
  });
  if (r.error) throw new Error(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
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
export function stream(bin: string, args: string[], opts?: { cwd?: string }): number {
  const r = spawnSync(bin, args, {
    encoding: "utf8",
    stdio: "inherit",
    env: configEnv(),
    ...(opts?.cwd ? { cwd: opts.cwd } : {}),
  });
  if (r.error) throw new Error(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
  return r.status ?? -1;
}
