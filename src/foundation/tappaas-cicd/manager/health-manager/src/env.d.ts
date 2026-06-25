// Minimal ambient declarations for the Node globals + built-in modules this
// manager uses, so `tsc` compiles with ZERO npm dependencies (no @types/node).
// Mirrors people-manager/src/env.d.ts (the S-TS pilot pattern). Only the surface
// actually used here is declared; everything is typed (no implicit `any`) to
// satisfy strict mode.

declare const console: {
  log(...args: unknown[]): void;
  error(...args: unknown[]): void;
};

declare const process: {
  argv: string[];
  env: Record<string, string | undefined>;
  exit(code?: number): never;
  stdout: { write(s: string): void };
  stderr: { write(s: string): void };
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
declare module "fs" {
  export function existsSync(path: string): boolean;
  export function readFileSync(path: string, encoding: "utf8"): string;
  export function readdirSync(path: string): string[];
  // Used by the unit tests (test/unit/*.test.ts) to stage a temp config dir.
  export function writeFileSync(path: string, data: string): void;
  export function mkdtempSync(prefix: string): string;
}

// ── node:path ──────────────────────────────────────────────────────────
declare module "path" {
  export function basename(p: string, ext?: string): string;
  export function join(...parts: string[]): string;
}

// ── node:child_process (the ssh / pvesh / qm FFI boundary) ─────────────
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
    // "inherit" → stream the child's stdio to this process (update-os.sh).
    stdio?: "inherit" | "pipe";
  }
  export function spawnSync(
    command: string,
    args: string[],
    options: SpawnSyncOptions,
  ): SpawnSyncReturn;
}
