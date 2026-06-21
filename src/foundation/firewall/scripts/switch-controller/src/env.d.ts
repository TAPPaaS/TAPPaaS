// Minimal ambient declarations for the Node globals + built-in modules this
// controller uses, so `tsc` compiles with ZERO npm dependencies (no
// @types/node). A heavier port could swap this for @types/node — recorded as an
// S-TS friction metric in the ADR-007 plan. Only the surface actually used here
// is declared; everything is typed (no `any`) to satisfy strict mode.

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
declare function require(id: string): unknown;

// ── node:fs (sync surface used for atomic JSON state) ────────────────
declare module "fs" {
  export function existsSync(path: string): boolean;
  export function readFileSync(path: string, encoding: "utf8"): string;
  export function writeFileSync(path: string, data: string): void;
  export function renameSync(oldPath: string, newPath: string): void;
  export function unlinkSync(path: string): void;
  export function readdirSync(path: string): string[];
  export function mkdtempSync(prefix: string): string;
}

// ── node:path (basename/join used for plugin selection) ──────────────
declare module "path" {
  export function basename(p: string, ext?: string): string;
  export function join(...parts: string[]): string;
}

// ── node:os (tmpdir for atomic temp files) ───────────────────────────
declare module "os" {
  export function tmpdir(): string;
}

// ── node:child_process (the bash-plugin FFI boundary) ────────────────
declare module "child_process" {
  export interface SpawnSyncReturn {
    status: number | null;
    stdout: string;
    stderr: string;
    error?: Error;
  }
  export interface SpawnSyncOptions {
    encoding?: "utf8";
    env?: Record<string, string | undefined>;
    maxBuffer?: number;
  }
  export function spawnSync(
    command: string,
    args: string[],
    options: SpawnSyncOptions,
  ): SpawnSyncReturn;
}
