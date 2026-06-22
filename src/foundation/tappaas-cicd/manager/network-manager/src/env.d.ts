// Minimal ambient declarations for the Node globals + built-in modules this
// manager uses, so `tsc` compiles with ZERO npm dependencies (no @types/node).
// Mirrors the S-TS switch-controller pilot + people-manager. Only the surface
// actually used here is declared; everything is typed (no implicit `any`).

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
  export function writeFileSync(path: string, data: string, encoding: "utf8"): void;
  export function renameSync(oldPath: string, newPath: string): void;
  export function mkdtempSync(prefix: string): string;
  export function copyFileSync(src: string, dest: string): void;
}

// ── node:path ──────────────────────────────────────────────────────────
declare module "path" {
  export function basename(p: string, ext?: string): string;
  export function dirname(p: string): string;
  export function join(...parts: string[]): string;
}

// ── node:os ──────────────────────────────────────────────────────────
declare module "os" {
  export function tmpdir(): string;
}

// ── node:child_process (the plane-controller FFI boundary) ─────────────
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
    stdio?: string | (string | number)[];
  }
  export function spawnSync(
    command: string,
    args: string[],
    options: SpawnSyncOptions,
  ): SpawnSyncReturn;
}
