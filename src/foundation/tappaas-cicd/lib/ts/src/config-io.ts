// config-io.ts — shared config-root resolution + JSON file I/O for the
// TAPPaaS TypeScript managers (ADR-007 post-implementation refactor, Phase 3).

import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, rmdirSync, unlinkSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { dirname, join } from "path";

// The ONE canonical config-root rule (documented in tappaas-cicd/README.md,
// "Config root resolution"): TAPPAAS_CONFIG (the TAPPaaS-specific override)
// wins, then CONFIG_DIR (the long-standing bash-layer variable), then the
// standard target path. Never re-implement this with a different precedence.
export function defaultConfigDir(): string {
  return process.env.TAPPAAS_CONFIG ?? process.env.CONFIG_DIR ?? "/home/tappaas/config";
}

/** The Identity domain's directory under a config root (#628): `identities/`,
 *  or the pre-#628 `people/` when only that exists — a site whose migration
 *  0005 has not run yet, or a config restored from a backup taken before it.
 *  One rule, for every manager that reads the domain. */
export function identityDir(configRoot: string): string {
  const now = join(configRoot, "identities");
  const before = join(configRoot, "people");
  return !existsSync(now) && existsSync(before) ? before : now;
}

export function asString(v: unknown): string {
  return typeof v === "string" ? v : "";
}

export function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is string => typeof x === "string");
}

// Read + parse a JSON object file. An ABSENT file returns null (callers treat
// a missing layer/file as legitimately empty); a PRESENT but unparseable or
// non-object file THROWS naming the file — silent defaulting corrupts state
// invisibly (the F4 policy: parse errors are reported, commands die cleanly).
export function readJsonObject(file: string): Record<string, unknown> | null {
  if (!existsSync(file)) return null;
  let v: unknown;
  try {
    v = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    throw new Error(`malformed JSON in ${file}: ${e instanceof Error ? e.message : String(e)}`);
  }
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    throw new Error(`malformed config in ${file}: expected a JSON object`);
  }
  return v as Record<string, unknown>;
}

// TAPPAAS_SIMULATE=1 (docs/plans/console-gui-pipeline.md §6 layer B): nothing
// changes the site. One rule for the lib, exec.ts builds its gate on it.
export function simulating(): boolean {
  return process.env.TAPPAAS_SIMULATE === "1";
}

// A write under the config root, simulated: logged and skipped. The console's
// own state directory is elsewhere and keeps being written.
function skipConfigWrite(file: string): boolean {
  if (!simulating()) return false;
  const root = defaultConfigDir().replace(/\/$/, "");
  if (file !== root && !file.startsWith(`${root}/`)) return false;
  console.error(`[simulate] write ${file}`);
  return true;
}

// A manager's write, simulated: logged and skipped, wherever it goes. Only its
// own scratch under the temp dir still happens; the config root counts as the
// site even there, which is where a test keeps it.
export function skipWrite(file: string): boolean {
  if (!simulating()) return false;
  const under = (root: string) => file === root || file.startsWith(`${root}/`);
  if (under(tmpdir().replace(/\/$/, "")) && !under(defaultConfigDir().replace(/\/$/, ""))) return false;
  console.error(`[simulate] write ${file}`);
  return true;
}

// The guarded fs: a manager changes files through these, so the one rule above
// holds (scripts/test/test-simulate-coverage.sh fails on a raw call).
export function writeFileGuarded(file: string, text: string, encoding?: "utf8"): void {
  if (!skipWrite(file)) writeFileSync(file, text, encoding);
}

export function renameGuarded(from: string, to: string): void {
  if (!skipWrite(to)) renameSync(from, to);
}

export function unlinkGuarded(file: string): void {
  if (!skipWrite(file)) unlinkSync(file);
}

export function rmGuarded(path: string, opts?: { recursive?: boolean; force?: boolean }): void {
  if (!skipWrite(path)) rmSync(path, opts);
}

export function mkdirGuarded(dir: string, opts?: { recursive?: boolean }): void {
  if (!skipWrite(dir)) mkdirSync(dir, opts);
}

export function rmdirGuarded(dir: string): void {
  if (!skipWrite(dir)) rmdirSync(dir);
}

export function chmodGuarded(path: string, mode: number): void {
  if (!skipWrite(path)) chmodSync(path, mode);
}

// Atomically write a JSON document: write into a fresh temp dir NEXT TO the
// target (same filesystem, so rename is atomic), rename over the target, and
// remove the now-empty temp dir (the old per-manager copies leaked it).
export function writeJsonAtomic(file: string, doc: unknown, indent = 2): void {
  if (skipConfigWrite(file)) return;
  const dir = dirname(file);
  const tmpDir = mkdtempSync(join(dir, ".tmp-"));
  try {
    const tmp = join(tmpDir, "out.json");
    writeFileSync(tmp, JSON.stringify(doc, null, indent) + "\n", "utf8");
    renameSync(tmp, file);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}
