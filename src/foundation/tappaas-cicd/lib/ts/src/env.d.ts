// env.d.ts — shared ambient declarations for the Node globals + built-in
// modules the TAPPaaS managers use, so `tsc` compiles with ZERO npm
// dependencies (no @types/node). This is the UNION of what the managers need;
// it replaces the per-manager vendored copies (ADR-007 post-implementation
// refactor, Phase 3). Everything is typed (no implicit `any`) to satisfy
// strict mode.
//
// NOTE on spawnSync: stdout/stderr are truthfully `string | null` (null when
// stdio is "inherit" — the child wrote straight to the terminal). Prefer the
// lib/ts/src/exec.ts helpers, which normalise, over reading them raw.

declare const console: {
  log(...args: unknown[]): void;
  error(...args: unknown[]): void;
};

declare const process: {
  argv: string[];
  env: Record<string, string | undefined>;
  exit(code?: number): never;
  pid: number;
  stdout: { write(s: string): void };
  stderr: { write(s: string): void };
  // getuid: POSIX-only (undefined on non-POSIX platforms). Used by the #533
  // preflight guard (cli.ts requireOperator) to refuse running as root.
  // Optional to match Node's own typing and the `typeof … === "function"` guard.
  getuid?(): number;
};

// __dirname is available under CommonJS output.
declare const __dirname: string;

// CommonJS require for the Node built-ins below (module: commonjs output).
declare const require: {
  (id: string): unknown;
  main: unknown;
};
// CommonJS module ref (used for the `require.main === module` entry guard).
declare const module: unknown;

// ── node:fs ──────────────────────────────────────────────────────────
// Minimal Buffer surface — only what the managers actually use. There is no
// @types/node here on purpose (the managers build with types: []), so every
// runtime type this code touches is declared explicitly.
interface NodeBuffer {
  subarray(start?: number, end?: number): NodeBuffer;
  toString(encoding?: string): string;
  readonly length: number;
}

declare module "fs" {
  export function existsSync(path: string): boolean;
  export function readFileSync(path: string, encoding: "utf8"): string;
  // No encoding => raw bytes. Used by reconcile.ts hasShebang() to read the
  // first two bytes of a script without decoding a possibly-binary file.
  export function readFileSync(path: string): NodeBuffer;
  export function writeFileSync(path: string, data: string, encoding?: "utf8"): void;
  export function renameSync(oldPath: string, newPath: string): void;
  export function mkdtempSync(prefix: string): string;
  export function readdirSync(path: string): string[];
  export function mkdirSync(path: string, options?: { recursive?: boolean }): void;
  export function unlinkSync(path: string): void;
  export function rmSync(path: string, options?: { recursive?: boolean; force?: boolean }): void;
  export function rmdirSync(path: string): void;
  export function copyFileSync(src: string, dest: string): void;
  // chmodSync: used by module-manager's reconcile (the ensure_scripts_executable
  // port) to mark module/service scripts executable before spawning them.
  export function chmodSync(path: string, mode: number): void;
  export interface StatLike {
    isDirectory(): boolean;
    isFile(): boolean;
  }
  export function statSync(path: string): StatLike;
}

// ── node:path ──────────────────────────────────────────────────────────
declare module "path" {
  export function basename(p: string, ext?: string): string;
  export function dirname(p: string): string;
  export function join(...parts: string[]): string;
}

// ── node:os (unit tests' writable temp trees) ──────────────────────────
declare module "os" {
  export function tmpdir(): string;
}

// ── node:child_process (the manager → controller/bash FFI boundary) ────
declare module "child_process" {
  export interface SpawnSyncReturn {
    status: number | null;
    // null when stdio is "inherit" (the child wrote straight to the terminal).
    stdout: string | null;
    stderr: string | null;
    error?: Error;
  }
  export interface SpawnSyncOptions {
    encoding?: "utf8";
    env?: Record<string, string | undefined>;
    maxBuffer?: number;
    // "inherit" streams the child's stdio to the operator's terminal (used for
    // long-running scripts so their step-by-step output is visible, exactly as
    // the bash orchestrators do).
    stdio?: "inherit" | "pipe" | string | (string | number)[];
    // Working directory for the child (module-manager reconcile runs a module's
    // ./update.sh from the module directory, as the bash orchestrator did).
    cwd?: string;
  }
  export function spawnSync(
    command: string,
    args: string[],
    options: SpawnSyncOptions,
  ): SpawnSyncReturn;
}
