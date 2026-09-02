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
  CHANGE_CLASSES,
  ManifestFinding,
  ServiceFieldManifest,
  manifestRelPath,
  needsActualState,
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

  // A manifest whose fields are all apply:"reconcile" has nothing for the
  // generic differ to compare, and demanding a report-service.sh from that
  // provider would be asking it to re-express a firewall rule set as flat
  // strings for no one's benefit. Diff what there is — which is nothing — and
  // say so, rather than failing on a reporter that should not exist.
  if (!needsActualState(manifest)) {
    return {
      ok: true,
      record: computeDrift(desired, { manifest, actual: {}, zones: loadZones(configDir) }),
    };
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

// ── the static pre-gate (ADR-020 D2 step 0) ────────────────────────────
//
// `modify --set field=value` writes into the deployed config and lets the
// normal converge realize it. Before it writes ANYTHING it checks each field's
// change class, and rejects the WHOLE command if any of them can never be
// applied in place.
//
// WHY REJECT UP FRONT, and why only these. A refusal that needs live state — a
// disk shrink, a migrate that would need downtime — can only be found at apply
// time, and the snapshot wrapper rolls that back. But `immutable` and
// `recreate` are knowable from the schema alone, and letting them through would
// leave config claiming something reality can never match: every later
// reconcile would report drift that nothing can fix. So they are refused before
// the write (Resolved Question 4), and a mixed `--set` is rejected whole
// (Resolved Question 5) so config and cluster always move together.

export interface SetRequest {
  field: string;
  value: string;
}

export interface SetPlanEntry extends SetRequest {
  // The coordinate whose manifest classified this field, "" for a field no
  // provider service owns (a policy-only change — the #557 case).
  coordinate: string;
  class: string;
}

export interface SetRejection {
  field: string;
  reason: string;
}

export type PreGateResult =
  | { ok: true; plan: SetPlanEntry[]; warnings: string[] }
  | { ok: false; rejections: SetRejection[]; warnings: string[] };

// Parse `field=value`. The value may contain '=' (a netopts string, a URL), so
// only the FIRST separator splits.
export function parseSetArg(arg: string): SetRequest | null {
  const eq = arg.indexOf("=");
  if (eq <= 0) return null;
  return { field: arg.slice(0, eq), value: arg.slice(eq + 1) };
}

export function preGateSet(
  configDir: string,
  module: string,
  requests: SetRequest[],
  schema: Record<string, { usedBy?: string[] } | undefined>,
): PreGateResult {
  const rejections: SetRejection[] = [];
  const warnings: string[] = [];
  const plan: SetPlanEntry[] = [];

  // Without the schema the gate knows nothing: not which fields exist, not
  // which service owns them, not what changing one costs. Refusing is the safe
  // answer, but it must say WHY — blaming each field name for a missing file
  // sends the operator hunting for a typo that is not there.
  if (Object.keys(schema).length === 0) {
    return {
      ok: false,
      warnings,
      rejections: [
        {
          field: requests.map((r) => r.field).join(", "),
          reason:
            `module-fields.json is not readable from ${configDir} — without it no field can be ` +
            `validated or classified, so nothing is written`,
        },
      ],
    };
  }

  const desired = resolveModuleFromConfig(module, configDir);
  if (!desired) {
    return {
      ok: false,
      warnings,
      rejections: requests.map((r) => ({ field: r.field, reason: `module '${module}' is not deployed` })),
    };
  }
  const environment = desired.fields.environment?.value ?? "";
  const declared = new Set([...desired.dependsOn, ...desired.integratesWith]);

  // Manifests are loaded once per coordinate, not once per field.
  const manifests = new Map<string, ServiceFieldManifest | null>();
  const manifestFor = (coordinate: string): ServiceFieldManifest | null => {
    if (manifests.has(coordinate)) return manifests.get(coordinate) ?? null;
    const { provider, service } = parseDependency(coordinate);
    const dir = getModuleDir(configDir, resolveProviderModule(configDir, provider, environment));
    const m = dir ? loadServiceManifest(dir, service).manifest : null;
    manifests.set(coordinate, m);
    return m;
  };

  for (const req of requests) {
    const spec = schema[req.field];
    if (!spec) {
      rejections.push({
        field: req.field,
        reason: `not a field module-fields.json declares — check the spelling`,
      });
      continue;
    }

    const usedBy = Array.isArray(spec.usedBy) ? spec.usedBy : [];
    // A 'general' field (or one with no usedBy at all) belongs to the module
    // itself, not to a provider service: no manifest classifies it, and the
    // converge has nothing to apply. That is the plain #557 case — correcting a
    // policy field without a reinstall — so it is allowed, not rejected.
    if (usedBy.length === 0 || usedBy.includes("general")) {
      plan.push({ ...req, coordinate: "", class: "config-only" });
      continue;
    }

    const owners = usedBy.filter((u) => declared.has(u));
    if (owners.length === 0) {
      // Writing it would be a silent no-op: no service the module declares uses
      // this field, so nothing would ever apply it. Saying so is the point of
      // having the ownership data at all.
      rejections.push({
        field: req.field,
        reason:
          `'${module}' declares none of the services that use it (${usedBy.join(", ")}) — ` +
          `setting it would change the config and nothing else`,
      });
      continue;
    }

    let rejected = false;
    for (const coordinate of owners) {
      const manifest = manifestFor(coordinate);
      if (!manifest) {
        warnings.push(
          `${req.field}: ${coordinate} has no field manifest yet, so its change class is unknown — ` +
            `the converge may refuse this change at apply time`,
        );
        continue;
      }
      const entry = manifest.fields[req.field];
      if (!entry) {
        warnings.push(`${req.field}: ${coordinate}'s manifest does not classify it`);
        continue;
      }
      const spec2 = CHANGE_CLASSES[entry.class];
      if (spec2?.preGate) {
        rejections.push({
          field: req.field,
          reason:
            `${entry.class} under ${coordinate} — ${spec2.summary}. ` +
            `Use 'module-manager module delete ${module}' then 'add' to change it.`,
        });
        rejected = true;
        break;
      }
      if (!rejected) plan.push({ ...req, coordinate, class: entry.class });
    }
  }

  // Reject the WHOLE command: no partial write across one modify, so config and
  // cluster never move independently (Resolved Question 5).
  if (rejections.length > 0) return { ok: false, rejections, warnings };
  return { ok: true, plan, warnings };
}

// ── rendering ──────────────────────────────────────────────────────────

// Every reason a field was not compared, in words an operator can act on. The
// differ records the reason precisely so this can be said instead of nothing.
const SKIP_REASON_TEXT: Record<string, string> = {
  "self-reconciling": "converged by the service itself, not diffed here",
  "no-desired-value": "this module declares no value, and no schema default applies",
  "seed-only": "the schema default is an install-time seed, not desired state",
  "not-reported": "the service's reporter does not observe it",
};

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
    // "Nothing compared" is NOT "in sync" — the same confusion #458 had to fix
    // on the dependency-service side. A clean verdict is only honest when
    // something was actually compared; otherwise say what was skipped and why,
    // and name the check that DOES cover it.
    if (r.inSync.length > 0) {
      out.push(
        `  ${GN}✓${CL} in sync (${r.inSync.length} field(s) compared, ${r.skipped.length} not compared)`,
      );
      return out;
    }
    const byReason = new Map<string, string[]>();
    for (const s of r.skipped) {
      const list = byReason.get(s.reason);
      if (list) list.push(s.field);
      else byReason.set(s.reason, [s.field]);
    }
    if (byReason.size === 0) {
      out.push(`  ${GN}✓${CL} nothing to compare — this service owns no field of this module`);
      return out;
    }
    out.push(`  ${YW}~${CL} nothing was compared here:`);
    for (const [reason, fields] of byReason) {
      out.push(`      ${SKIP_REASON_TEXT[reason] ?? reason}: ${fields.join(", ")}`);
    }
    if (byReason.has("self-reconciling")) {
      out.push(`      → 'module-manager test ${r.module}' runs the verifier that does cover them`);
    }
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
