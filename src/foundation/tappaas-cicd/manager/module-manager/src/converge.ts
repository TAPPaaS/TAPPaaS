// converge.ts — the manager side of the ADR-020 converge pipeline.
//
// The manager owns the single drift computation (D7). This file assembles it
// for one `<provider>:<service>` coordinate:
//
//     desired = resolveModule(...)                 [D1, the one resolver]
//     manifest = services/<svc>/fields.json        [D3/D4, the change semantics]
//     actual  = services/<svc>/report-service.sh   [bash, extract only]
//     drift   = computeDrift(desired, actual, …)   [D7, the one differ]
//
// and exposes it as `module-manager module drift <name>`, whose `--json` output
// is exactly the record a service applies with `update-service.sh --apply-drift`.
//
// WHY A VERB AND NOT A LIBRARY CALL. `update-service.sh` is invoked bare —
// `update-service.sh <module>` — by `update-module.sh`, by `reconcile --apply`,
// and by hand. Those callers must keep working, and none of them is going to
// compute a drift record. So the bash side asks for one through this verb
// rather than re-deriving it: there is still exactly one differ, and it is
// still in the manager, but every existing entry point keeps its shape.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import {
  DriftRecord,
  ZonesFile,
  computeDrift,
  hasChanges,
  needsDisruption,
  unitSideEffects,
} from "../../../lib/ts/src/drift";
import {
  ManifestFinding,
  ServiceFieldManifest,
  manifestRelPath,
  parseServiceFieldManifest,
} from "../../../lib/ts/src/service-fields";
import { BL, CL, GN, RD, YW, emitJson, error, info, warn } from "./shlog";
import { getModuleDir, resolveProviderModule } from "./config";
import { parseDependency } from "./services";
import { resolveModuleFromConfig } from "./resolve";
import { runServiceReporter } from "./report";

// Everything that can stop a drift computation, kept apart because the caller
// says something different about each. In particular "this provider has no
// manifest yet" is NOT an error during the ADR-020 rollout — 23 of the 25
// services are still un-migrated (P5) — while a manifest that exists and is
// broken very much is.
export type DriftFailure =
  | { kind: "no-module" }
  | { kind: "no-provider"; provider: string }
  | { kind: "no-manifest"; path: string }
  | { kind: "bad-manifest"; path: string; findings: ManifestFinding[] }
  | { kind: "no-reporter"; path: string }
  | { kind: "cluster-unreachable" }
  | { kind: "not-present" }
  | { kind: "report-failed"; detail: string };

export type DriftResult = { ok: true; record: DriftRecord } | { ok: false; failure: DriftFailure };

// zones.json drives the declared `vlan` and `trunks` normalizers. Absent → null,
// which those normalizers treat as "no zone is defined": a zone NAME then
// resolves to no tag, exactly as the bash did against a missing file.
function loadZones(configDir: string): ZonesFile {
  const path = join(configDir, "zones.json");
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    return raw !== null && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

export function loadServiceManifest(
  dir: string,
  service: string,
): { path: string; manifest: ServiceFieldManifest | null; findings: ManifestFinding[] } {
  const path = join(dir, manifestRelPath(service));
  const findings: ManifestFinding[] = [];
  if (!existsSync(path)) return { path, manifest: null, findings };
  let doc: unknown;
  try {
    doc = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    findings.push({ severity: "error", message: `not valid JSON: ${(e as Error).message}` });
    return { path, manifest: null, findings };
  }
  return { path, manifest: parseServiceFieldManifest(doc, findings), findings };
}

// Compute the drift record for ONE coordinate.
export function driftForService(
  configDir: string,
  module: string,
  coordinate: string,
): DriftResult {
  const desired = resolveModuleFromConfig(module, configDir);
  if (!desired) return { ok: false, failure: { kind: "no-module" } };

  const { provider, service } = parseDependency(coordinate);
  const environment = desired.fields.environment?.value ?? "";
  const providerModule = resolveProviderModule(configDir, provider, environment);
  const providerDir = getModuleDir(configDir, providerModule);
  if (!providerDir) return { ok: false, failure: { kind: "no-provider", provider: providerModule } };

  const { path, manifest, findings } = loadServiceManifest(providerDir, service);
  if (!manifest) {
    return findings.length > 0
      ? { ok: false, failure: { kind: "bad-manifest", path, findings } }
      : { ok: false, failure: { kind: "no-manifest", path } };
  }

  const outcome = runServiceReporter(configDir, module, provider, service, environment);
  switch (outcome.kind) {
    case "ok":
      break;
    case "no-reporter":
      return { ok: false, failure: { kind: "no-reporter", path: outcome.path } };
    case "cluster-unreachable":
      return { ok: false, failure: { kind: "cluster-unreachable" } };
    case "not-present":
      return { ok: false, failure: { kind: "not-present" } };
    case "unreadable":
      return { ok: false, failure: { kind: "report-failed", detail: outcome.detail } };
    default:
      return { ok: false, failure: { kind: "report-failed", detail: outcome.detail } };
  }

  return {
    ok: true,
    record: computeDrift(desired, {
      manifest,
      actual: outcome.actual,
      zones: loadZones(configDir),
    }),
  };
}

// Which of a module's coordinates can produce a drift record at all: those whose
// provider ships a manifest. Used by the bare `drift <module>` view so it
// reports on everything that is on the contract, and says nothing about the
// services that are not (rather than listing 20 "not migrated" lines).
export function coordinatesWithManifests(configDir: string, module: string): string[] {
  const desired = resolveModuleFromConfig(module, configDir);
  if (!desired) return [];
  const environment = desired.fields.environment?.value ?? "";
  const out: string[] = [];
  for (const dep of [...desired.dependsOn, ...desired.integratesWith]) {
    if (!dep.includes(":")) continue;
    const { provider, service } = parseDependency(dep);
    const dir = getModuleDir(configDir, resolveProviderModule(configDir, provider, environment));
    if (!dir) continue;
    if (existsSync(join(dir, manifestRelPath(service)))) out.push(dep);
  }
  return out;
}

// ── rendering ──────────────────────────────────────────────────────────

function failureLines(coordinate: string, f: DriftFailure): string[] {
  switch (f.kind) {
    case "no-module":
      return [`${coordinate}: module config not found`];
    case "no-provider":
      return [`${coordinate}: provider '${f.provider}' is not deployed (or its config has no .location)`];
    case "no-manifest":
      return [`${coordinate}: no field manifest yet (${f.path}) — this service is not on the ADR-020 contract`];
    case "bad-manifest":
      return [
        `${coordinate}: field manifest is unusable (${f.path}):`,
        ...f.findings.map((x) => `    ${x.message}`),
      ];
    case "no-reporter":
      return [`${coordinate}: provider ships no ${f.path} — actual state cannot be read`];
    case "cluster-unreachable":
      return [`${coordinate}: the cluster could not be reached — actual state unknown`];
    case "not-present":
      return [`${coordinate}: the guest is not present on any node`];
    case "report-failed":
      return [`${coordinate}: report-service.sh failed — ${f.detail}`];
  }
}

export function renderDrift(coordinate: string, r: DriftRecord): string[] {
  const out: string[] = [`${GN}${coordinate}${CL}`];
  if (!hasChanges(r)) {
    out.push(
      `  ${GN}✓${CL} in sync (${r.inSync.length} field(s) compared, ${r.skipped.length} not compared)`,
    );
    return out;
  }
  for (const u of r.units) {
    const how = u.apply === "hook" ? `hook ${u.hook}` : u.apply;
    const fx = u.sideEffects.length ? `, side effects: ${u.sideEffects.join("+")}` : "";
    out.push(`  ${BL}${u.name}${CL} [${u.class}, ${how}${fx}]`);
    for (const f of u.fields) {
      out.push(`      ${f.field}: ${f.actual || "-"} → ${f.desired}${f.defaulted ? " (schema default)" : ""}`);
    }
  }
  for (const f of r.unreconciled) {
    out.push(
      `  ${RD}✗${CL} ${f.field} [${f.class}] ${f.actual || "-"} → ${f.desired} — not reconcilable in place`,
    );
  }
  if (needsDisruption(r)) {
    out.push(
      `  ${YW}!${CL} applying this needs disruption authorization (${unitSideEffects(r).join("+") || "downtime"}): ` +
        `'module modify ${r.module} --force', or rebootOk in the scheduled pass`,
    );
  }
  return out;
}

// ── the verb ───────────────────────────────────────────────────────────

export interface DriftOptions {
  configDir: string;
  json?: boolean;
  // One coordinate. Omitted → every coordinate that has a manifest.
  service?: string;
}

export function cmdDrift(module: string, opts: DriftOptions): number {
  const coordinates = opts.service ? [opts.service] : coordinatesWithManifests(opts.configDir, module);

  if (coordinates.length === 0) {
    if (opts.json) {
      emitJson({ module, services: {} });
      return 0;
    }
    info(`(no dependency of '${module}' declares a field manifest yet — nothing to diff)`);
    return 0;
  }

  // --json with ONE service prints the bare record: that is what
  // `update-service.sh --apply-drift` consumes, and wrapping it would make
  // every apply path unwrap it.
  if (opts.json && opts.service) {
    const r = driftForService(opts.configDir, module, opts.service);
    if (!r.ok) {
      for (const l of failureLines(opts.service, r.failure)) error(l);
      // A service that is simply not on the contract yet is not a failure of
      // this command — the caller (a bare update-service.sh) falls back.
      return r.failure.kind === "no-manifest" ? 2 : 1;
    }
    emitJson(r.record);
    return 0;
  }

  let worst = 0;
  const records: Record<string, unknown> = {};
  for (const coordinate of coordinates) {
    const r = driftForService(opts.configDir, module, coordinate);
    if (!r.ok) {
      if (opts.json) {
        records[coordinate] = { error: r.failure };
      } else {
        for (const l of failureLines(coordinate, r.failure)) {
          if (r.failure.kind === "no-manifest") warn(l);
          else error(l);
        }
      }
      if (r.failure.kind !== "no-manifest") worst = 1;
      continue;
    }
    if (opts.json) records[coordinate] = r.record;
    else for (const l of renderDrift(coordinate, r.record)) info(l);
  }
  if (opts.json) emitJson({ module, services: records });
  return worst;
}
