// resolve.ts — the `module-manager module resolve <name>` verb (ADR-020 D1).
//
// Prints the module's DESIRED state as one resolved document: the deployed
// `config/<name>.json` (which, after modify's 3-way merge, already IS the true
// desired state) PLUS the `module-fields.json` defaults for fields it does not
// declare, PLUS the `.orig` "not tracking release on purpose" flags.
//
// This is the verb form of the single resolver (lib/ts/src/desired.ts). Its
// reason to exist is that the ACTING side needs the same answer the REPORTING
// side gets: before ADR-020, `cluster:vm/update-service.sh` re-derived defaults
// through its own `cfg()` ladder and could disagree with what `reconcile`
// reported (#550). From P3 the service scripts stop defaulting entirely — the
// manager resolves once, here, and hands each service its owned fields already
// resolved.
//
// What it deliberately does NOT do:
//   - No MERGE. The 3-way release merge is a `modify` step. `resolve` is a pure
//     read+default so `inspect` (pre-merge) and `modify` (post-merge) get the
//     same answer from the same code.
//   - No CLUSTER. Desired state is what the config says. `reconcile <module>`
//     is the verb that compares it with what is running.
//
// NOTE ON THE NAME: `resolve-module.sh` in this same directory answers an
// unrelated question — WHERE a module's source directory is (ADR-004 catalog
// lookup). This verb resolves a module's FIELD VALUES. Different questions,
// unfortunately adjacent names; `list --resolution` is the reporting front door
// for the other one.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { CL, GN, YW, error, info } from "./shlog";
import { loadModuleFields, resolveModule, ResolvedModule } from "../../../lib/ts/src/desired";
import { normalizeModuleConfig } from "./config";

// Read + normalize a module JSON. Absent → null; present-but-malformed → {},
// matching what inspect does, so a broken `.orig` degrades the 3-way note
// rather than failing the whole verb.
function readNormalized(path: string): Record<string, unknown> | null {
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return {};
    return normalizeModuleConfig(raw as Record<string, unknown>);
  } catch {
    return {};
  }
}

export interface ResolveOptions {
  configDir: string;
  json?: boolean;
}

// Gather the inputs and resolve. Separated from the rendering so callers that
// want the document (the P3 converge, `modify`) take this and never parse text.
export function resolveModuleFromConfig(
  module: string,
  configDir: string,
): ResolvedModule | null {
  const cfg = readNormalized(join(configDir, `${module}.json`));
  if (cfg === null) return null;
  const orig = readNormalized(join(configDir, `${module}.json.orig`));
  return resolveModule(module, cfg, orig, loadModuleFields(configDir));
}

// The human table. Three columns, because three facts about a field's desired
// value are worth distinguishing and collapsing them is what #550 was:
//
//   VALUE   what the converge will use
//   SOURCE  config (declared) or default (the schema supplied it)
//   NOTE    off-release-on-purpose, when a .orig pre-image says so
// A container field (dependsOn, egress, backup) resolves to its JSON text,
// which can be hundreds of characters and would set the whole table's column
// width. Truncate it in the HUMAN view only, and say so — a silently clipped
// value would be worse than a wide table. --json always carries the full value.
const MAX_VALUE = 60;
function display(v: string): string {
  return v.length <= MAX_VALUE ? v : `${v.slice(0, MAX_VALUE - 1)}… (${v.length} chars, see --json)`;
}

export function renderResolved(r: ResolvedModule): string[] {
  const names = Object.keys(r.fields);
  const rows = names.map((n) => {
    const f = r.fields[n];
    return [
      n,
      display(f.value),
      f.defaulted ? "default" : "config",
      f.notTracking ? "not tracking release" : "",
    ];
  });
  const headers = ["FIELD", "DESIRED", "SOURCE", "NOTE"];
  const w = headers.map((h, i) => Math.max(h.length, ...rows.map((row) => row[i].length)));
  const line = (cells: string[]): string =>
    cells.map((c, i) => c.padEnd(w[i])).join("  ").trimEnd();

  const out = [
    `${GN}Desired state for ${r.module}${CL} (deployed config + module-fields.json defaults)`,
    "",
    `${GN}${line(headers)}${CL}`,
    line(w.map((n) => "-".repeat(n))),
    ...rows.map(line),
    "",
    `${names.length} field(s); ${rows.filter((row) => row[2] === "default").length} from schema defaults`,
  ];
  if (!r.origAvailable) {
    out.push(
      `${YW}(no <module>.json.orig pre-image — whether a field is deliberately off its release is unknown)${CL}`,
    );
  }
  return out;
}

// The verb. Returns the exit code; errors are returned, never thrown, matching
// the other config-layer verbs.
export function cmdResolve(module: string, opts: ResolveOptions): number {
  const r = resolveModuleFromConfig(module, opts.configDir);
  if (r === null) {
    error(
      `Module config not found: ${join(opts.configDir, `${module}.json`)} — is '${module}' installed?`,
    );
    return 1;
  }
  if (opts.json) {
    info(JSON.stringify(r, null, 2));
    return 0;
  }
  for (const l of renderResolved(r)) info(l);
  return 0;
}
