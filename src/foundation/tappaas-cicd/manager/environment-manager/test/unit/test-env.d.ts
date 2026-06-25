// test-env.d.ts — extra zero-dependency ambient declarations the UNIT TESTS use
// beyond the production src/env.d.ts surface (temp-dir fixture setup/teardown).
// Test-only; never imported by the shipped CLI.

declare module "fs" {
  export function mkdirSync(path: string, opts: { recursive: boolean }): void;
  export function rmSync(path: string, opts: { recursive: boolean; force: boolean }): void;
}

declare module "os" {
  export function tmpdir(): string;
}
