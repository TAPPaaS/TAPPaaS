// config-io.ts — shared config-root resolution + JSON file I/O for the
// TAPPaaS TypeScript managers (ADR-007 post-implementation refactor, Phase 3).

import { existsSync, mkdtempSync, readFileSync, renameSync, rmdirSync, writeFileSync } from "fs";
import { dirname, join } from "path";

// The ONE canonical config-root rule (documented in tappaas-cicd/README.md,
// "Config root resolution"): TAPPAAS_CONFIG (the TAPPaaS-specific override)
// wins, then CONFIG_DIR (the long-standing bash-layer variable), then the
// standard target path. Never re-implement this with a different precedence.
export function defaultConfigDir(): string {
  return process.env.TAPPAAS_CONFIG ?? process.env.CONFIG_DIR ?? "/home/tappaas/config";
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

// Atomically write a JSON document: write into a fresh temp dir NEXT TO the
// target (same filesystem, so rename is atomic), rename over the target, and
// remove the now-empty temp dir (the old per-manager copies leaked it).
export function writeJsonAtomic(file: string, doc: unknown): void {
  const dir = dirname(file);
  const tmpDir = mkdtempSync(join(dir, ".tmp-"));
  const tmp = join(tmpDir, "out.json");
  writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n", "utf8");
  renameSync(tmp, file);
  rmdirSync(tmpDir);
}
