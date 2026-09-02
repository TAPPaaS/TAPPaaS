// validate.ts — the module-manager `validate` verb engine.
//
// Ports the ADR-007b tier/source lint (validate-module-tier-source.sh) into
// pure, in-process TS so `module validate` can lint a single module config or
// EVERY deployed module config without shelling out. This is the real validator
// the bash `validate-module.sh` stub never filled in (see DESIGN.md "Pending").
//
// Lint rules (per validate-module-tier-source.sh):
//   - tier   : default 'app' when absent (back-compat → warning). Explicit value
//              must be one of: foundation | app.
//   - source : default 'official' when absent. Must be one of:
//              official | community | private | local.
//   - RULE   : tier:foundation REQUIRES source:official, unless allowFork.
//   - WARN   : source:community is valid but unsupported (🟡).
//
// Pure: depends only on the loaded ModuleConfig(s).

import { join } from "path";
import {
  ManifestFinding,
  lintServiceFieldManifest,
  ownedFieldsFor,
  parseServiceFieldManifest,
} from "../../../lib/ts/src/service-fields";
import { ServiceFs, parseDependency } from "./services";
import { MODULE_STATUS_VALUES, ModuleConfig, ValidateFinding, ValidateReport } from "./types";

export const VALID_TIERS = ["foundation", "app"] as const;
export const VALID_SOURCES = ["official", "community", "private", "local"] as const;

export interface ValidateOptions {
  allowFork?: boolean;
  // Filesystem probe for the dependsOn reference-integrity check (#495 follow-up).
  // Omit it and that check is SKIPPED — the tier/source lint stays pure and
  // usable without a tree. main.ts always supplies realServiceFs(configDir).
  fs?: ServiceFs;
  // Declared repositories from site.json. Optional so a hand-built call still
  // works; main.ts supplies them, and without them the source-ref check is a
  // no-op rather than a false pass.
  repos?: readonly { name: string; path: string; branch: string }[];
  // module-fields.json `.fields` — needed by the ADR-020 service field-manifest
  // lint, which checks a manifest against the schema's `usedBy` ownership.
  // Omitted (or empty) and that check is SKIPPED: without the schema there is
  // no ownership to check coverage against, and inventing one would report
  // every field as unowned.
  schema?: Record<string, { usedBy?: string[] } | undefined>;
}

// Lint one module config; append findings to `out`.
export function validateModule(
  m: ModuleConfig,
  opts: ValidateOptions,
  out: ValidateFinding[],
): void {
  const err = (message: string): void =>
    void out.push({ module: m.name, severity: "error", message });
  const warn = (message: string): void =>
    void out.push({ module: m.name, severity: "warning", message });

  // tier — default 'app' when absent (warn), explicit out-of-range is an error.
  let tier = m.tier ?? "";
  if (!tier) {
    warn(`no 'tier' field — defaulting to 'app' (back-compat; set tier: foundation|app explicitly)`);
    tier = "app";
  } else if (!(VALID_TIERS as readonly string[]).includes(tier)) {
    err(`invalid tier '${tier}' (must be one of: ${VALID_TIERS.join(" ")})`);
  }

  // source — default 'official' when absent (always valid).
  const source = m.source ?? "official";
  if (!(VALID_SOURCES as readonly string[]).includes(source)) {
    err(`invalid source '${source}' (must be one of: ${VALID_SOURCES.join(" ")})`);
  }

  // RULE: tier:foundation requires source:official (unless --allow-fork).
  if (tier === "foundation" && source !== "official") {
    if (opts.allowFork) {
      warn(`tier:foundation with source:'${source}' permitted by --allow-fork (foundation fork)`);
    } else {
      err(
        `tier:foundation requires source:official (got '${source}'). Pass --allow-fork to permit a foundation fork.`,
      );
    }
  }

  // community is valid but unsupported — surface a warning.
  if (source === "community") {
    warn(`source:community — peer-reviewed but not officially supported (🟡)`);
  }

  // status — descriptive, so an out-of-range value is a WARNING (not an error
  // like tier/source): erroring would fail-validate legacy fleets with variant
  // casing. Before #556 the permitted set lived only in a code comment, so no
  // check on the VALUE was possible; MODULE_STATUS_VALUES now makes it one.
  const status = m.status ?? "";
  if (status && !(MODULE_STATUS_VALUES as readonly string[]).includes(status)) {
    warn(`unknown status '${status}' — expected one of: ${MODULE_STATUS_VALUES.join(" ")}`);
  }

  // config-block structural rules (#161/#549) — pure, no fs needed.
  validateConfigBlock(m, out);

  // dependsOn / integratesWith reference integrity — see the two functions.
  if (opts.fs) validateDependsOn(m, opts.fs, out);
  if (opts.fs) validateIntegratesWith(m, opts.fs, out);

  // source-ref derivability — see validateSourceLocation.
  if (opts.repos) validateSourceLocation(m, opts.repos, out);

  // ADR-020 service field manifests — see validateFieldManifests.
  if (opts.fs && opts.schema) validateFieldManifests(m, opts.fs, opts.schema, out);

  // TODO(question): the bash stub also intended a SCHEMA check (every field
  // against module-fields.json). PARKED — see main.ts. The reference-integrity
  // half of that TODO is now implemented above.
}

// A module's source REF, derived rather than stored.
//
// `.location` is set automatically by copy-update-json.sh and records WHERE the
// module directory is — an absolute path, never which ref it came from. A ref
// exists one level up, on site.json `.repositories[].branch`, so it is
// derivable exactly while `.location` resolves inside a declared repository,
// and unknowable when it does not.
//
// That distinction is invisible in a single-environment estate: one repository,
// one branch, so path and ref coincide and the omission costs nothing. It
// surfaces the moment a site runs dev or test alongside production, because a
// module deployed from a feature branch into a test environment is CORRECT
// behaviour that the model cannot express. The absent ref then carries two
// opposite meanings — deliberately on a branch, or left on a stale checkout —
// and nothing distinguishes them. Same shape as an absent `tier` meaning both
// "deliberately app" and "never considered" (#561).
//
// Severity follows validate-module-tier-source.sh's rule — "can the tool
// proceed correctly?". It can: the module resolves through `.location` and
// works. So this is a WARNING, and the error level stays reserved for a
// location that resolves to nothing at all.
export function validateSourceLocation(
  m: ModuleConfig,
  repos: readonly { name: string; path: string; branch: string }[],
  out: ValidateFinding[],
): void {
  const raw = m.raw as Record<string, unknown> | undefined;
  const loc = typeof raw?.location === "string" ? raw.location : "";
  // No .location at all: the module resolved through a repository catalog, and
  // the catalog entry's repository supplies the ref. Not a finding.
  if (!loc) return;

  const inside = repos.some((r) => {
    if (!r.path) return false;
    const root = r.path.replace(/\/+$/, "");
    // Equality OR a path SEPARATOR boundary: "/x/TAPPaaSX" must not count as
    // inside "/x/TAPPaaS". A bare startsWith would say it does.
    return loc === root || loc.startsWith(root + "/");
  });
  if (inside) return;

  void out.push({
    module: m.name,
    severity: "warning",
    message:
      `source at '${loc}' is outside every repository declared in site.json — ` +
      `its ref cannot be derived, so a deliberate deploy-from-a-branch is ` +
      `indistinguishable from a checkout left behind. Declare the repository ` +
      `(site-manager repository add) or redeploy the module from a declared path.`,
  });
}

// config-block structural rules (#549). module-fields.json declares these as
// schema rules for the `config` field and common-install-routines.sh enforces
// them (so `reconcile` reports them), but `validate` did not — a module could
// violate a documented schema rule and still pass validation, the weaker of the
// two enforcing the same file (#549). The same missing declaration also gated
// update-module.sh's pre-update snapshot (dependsOn must contain cluster:vm), so
// one undeclared config block silently skipped snapshots for weeks. These two
// checks mirror common-install-routines.sh's Pattern-C validation exactly, so
// validate and reconcile now agree.
export function validateConfigBlock(m: ModuleConfig, out: ValidateFinding[]): void {
  // `raw` is the full parsed JSON on every loaded module; guard the field so a
  // hand-built ModuleConfig (tests, callers that skip the loader) is a no-op
  // rather than a crash.
  const raw = m.raw as Record<string, unknown> | undefined;
  if (!raw || typeof raw !== "object") return;
  const config = raw.config;
  if (config === null || typeof config !== "object" || Array.isArray(config)) return;
  const blocks = config as Record<string, unknown>;
  // A config block may key off a hard dependency OR an optional integration
  // (#501) — both are "declared" for the purpose of Rule 1.
  const deps = new Set([
    ...(Array.isArray(m.dependsOn) ? m.dependsOn : []),
    ...(Array.isArray(m.integratesWith) ? m.integratesWith : []),
  ]);

  // Rule 1: every config-block key must be a declared dependency. A config block
  // for a provider not in dependsOn is dropped on flatten and never applied.
  for (const key of Object.keys(blocks)) {
    if (!deps.has(key)) {
      out.push({
        module: m.name,
        severity: "error",
        message: `config block '${key}' is not a declared dependency — add it to dependsOn (#161)`,
      });
    }
  }

  // Rule 2: no field may appear in both the header and a config block, nor in
  // two config blocks — it is ambiguous once flattened to the top level. Count
  // every header key (except `config`) plus every field across all config
  // blocks; any name seen more than once collides.
  const counts = new Map<string, number>();
  for (const k of Object.keys(raw)) {
    if (k !== "config") counts.set(k, (counts.get(k) ?? 0) + 1);
  }
  for (const block of Object.values(blocks)) {
    if (block === null || typeof block !== "object" || Array.isArray(block)) continue;
    for (const f of Object.keys(block as Record<string, unknown>)) {
      counts.set(f, (counts.get(f) ?? 0) + 1);
    }
  }
  for (const [field, n] of counts) {
    if (n > 1) {
      out.push({
        module: m.name,
        severity: "error",
        message: `field '${field}' is set in both the header and a config block (or in two config blocks) — ambiguous (#161)`,
      });
    }
  }
}

// dependsOn reference integrity (#495 follow-up).
//
// Both `reconcile --apply` and `modify` SKIP a dependency whose provider ships no
// services/<service>/update-service.sh, rather than aborting. That skip is the
// right runtime behaviour — one module's broken declaration must not block a
// converge — but it means a dependency that can never be satisfied produces no
// runtime signal at all. Several deployed modules declare providers that have no
// services/ directory whatsoever (sonos:audio, sonos:airplay, reolink:rtsp,
// alfen:ui, alfen:modbus, alfen:discovery), so the declaration silently does
// nothing. `validate` is where that belongs: a dependsOn naming a provider that
// cannot serve it is a CONFIG error, reported once, at the time you ask.
//
// Provider resolution is environment-aware, exactly as reconcile does it, so a
// consumer in environment 'test' pairs with <provider>-test when that exists.
export function validateDependsOn(
  m: ModuleConfig,
  fs: ServiceFs,
  out: ValidateFinding[],
): void {
  const deps = Array.isArray(m.dependsOn) ? m.dependsOn : [];
  const environment = typeof m.environment === "string" ? m.environment : "";

  for (const dep of deps) {
    if (typeof dep !== "string" || dep === "") continue;
    const { provider, service } = parseDependency(dep);

    // A bare "provider" with no ":service" cannot name a service script at all.
    if (!dep.includes(":")) {
      out.push({
        module: m.name,
        severity: "error",
        message: `dependsOn '${dep}' has no ':<service>' — a dependency must name a provider AND a service (e.g. '${provider}:vm')`,
      });
      continue;
    }

    const { module: providerModule, dir } = fs.providerDir(provider, environment);
    if (!dir) {
      out.push({
        module: m.name,
        severity: "error",
        message: `dependsOn '${dep}' names provider '${providerModule}', which is not deployed (or its config has no .location) — this dependency is never applied`,
      });
      continue;
    }

    const svcScript = join(dir, "services", service, "update-service.sh");
    if (!fs.exists(svcScript)) {
      out.push({
        module: m.name,
        severity: "error",
        message: `dependsOn '${dep}' cannot be converged: provider '${providerModule}' ships no ${service}/update-service.sh (${svcScript}) — reconcile and modify SKIP it silently`,
      });
    }
  }
}

// integratesWith reference integrity (#501) — the SOFT counterpart to
// validateDependsOn. The defining difference: a provider that is NOT installed
// is expected and produces NO finding (that is the whole point of an optional
// integration). Only genuine misconfigurations are reported: a malformed
// coordinate, a coordinate that also appears in dependsOn (a coordinate is hard
// OR soft, never both), and — when the provider IS installed — a missing
// update-service.sh, which is a soft warning rather than the hard error
// dependsOn raises.
export function validateIntegratesWith(
  m: ModuleConfig,
  fs: ServiceFs,
  out: ValidateFinding[],
): void {
  const integ = Array.isArray(m.integratesWith) ? m.integratesWith : [];
  if (integ.length === 0) return;
  const hard = new Set(
    (Array.isArray(m.dependsOn) ? m.dependsOn : []).filter((d): d is string => typeof d === "string"),
  );
  const environment = typeof m.environment === "string" ? m.environment : "";

  for (const dep of integ) {
    if (typeof dep !== "string" || dep === "") continue;
    const { provider, service } = parseDependency(dep);

    if (!dep.includes(":")) {
      out.push({
        module: m.name,
        severity: "error",
        message: `integratesWith '${dep}' has no ':<service>' — an integration must name a provider AND a service (e.g. '${provider}:inference')`,
      });
      continue;
    }
    if (hard.has(dep)) {
      out.push({
        module: m.name,
        severity: "error",
        message: `'${dep}' is listed in both dependsOn and integratesWith — a coordinate is hard OR optional, not both`,
      });
      continue;
    }

    const { module: providerModule, dir } = fs.providerDir(provider, environment);
    // A provider that is not installed is the expected optional case — no finding.
    if (!dir) continue;

    // Installed but unable to wire the integration is worth a soft heads-up.
    const svcScript = join(dir, "services", service, "update-service.sh");
    if (!fs.exists(svcScript)) {
      out.push({
        module: m.name,
        severity: "warning",
        message: `integratesWith '${dep}': provider '${providerModule}' is installed but ships no ${service}/update-service.sh — the integration cannot converge`,
      });
    }
  }
}

// ADR-020 service field manifests — the P0 coverage lint.
//
// A provider service declares the change semantics of every field it owns in
// `services/<service>/fields.json` (ADR-020 D3/D4). That file is the ONLY home
// for "what does changing field X cost", so a gap in it is a gap nothing else
// can report: before this ADR the same knowledge lived inside one imperative
// drift loop, where a field nobody had thought about simply fell through.
//
// WHAT IS CHECKED, and what deliberately is not:
//
//   - A provider service with NO fields.json is SKIPPED, silently. During the
//     ADR-020 rollout most of the 25 services have not been migrated yet
//     (P5), and erroring on the un-migrated majority would make `validate`
//     useless for the whole transition. Absence means "not yet on the
//     contract", not "broken".
//   - A fields.json that EXISTS must be complete and well-formed: every field
//     module-fields.json says the coordinate owns must be classified, every
//     class must be one the taxonomy defines, and the apply wiring must be
//     coherent. Those are ERRORS. Opting in is opting in fully.
//
// Reported once per (module, coordinate): a manifest is a property of the
// PROVIDER, so the same fault surfaces on every consumer that declares the
// dependency. That is intentional — a broken cluster:vm manifest genuinely
// affects every module on cluster:vm — but the message names the provider, so
// the repeated lines point at one file to fix.
export function validateFieldManifests(
  m: ModuleConfig,
  fs: ServiceFs,
  schema: Record<string, { usedBy?: string[] } | undefined>,
  out: ValidateFinding[],
): void {
  const declaredFields = Object.keys(schema);
  // Nothing to check ownership against — see ValidateOptions.schema.
  if (declaredFields.length === 0) return;

  const environment = typeof m.environment === "string" ? m.environment : "";
  const deps = [
    ...(Array.isArray(m.dependsOn) ? m.dependsOn : []),
    ...(Array.isArray(m.integratesWith) ? m.integratesWith : []),
  ];

  const seen = new Set<string>();
  for (const dep of deps) {
    if (typeof dep !== "string" || !dep.includes(":")) continue;
    const { provider, service } = parseDependency(dep);
    const { module: providerModule, dir } = fs.providerDir(provider, environment);
    // A provider that cannot be located is already reported by
    // validateDependsOn; do not report the same absence twice in two voices.
    if (!dir) continue;

    // The manifest is keyed by the coordinate as the SCHEMA spells it — the
    // canonical provider name, not the environment-scoped deployment. A
    // 'network-test:proxy' consumer and a 'network:proxy' one share one
    // manifest and one ownership set.
    const coordinate = `${provider}:${service}`;
    if (seen.has(coordinate)) continue;
    seen.add(coordinate);

    const path = join(dir, "services", service, "fields.json");
    const text = fs.readFile(path);
    if (text === null) continue; // not migrated to the contract yet — see above

    const findings: ManifestFinding[] = [];
    let doc: unknown;
    try {
      doc = JSON.parse(text);
    } catch (e) {
      out.push({
        module: m.name,
        severity: "error",
        message: `${providerModule} '${path}' is not valid JSON: ${(e as Error).message}`,
      });
      continue;
    }
    const manifest = parseServiceFieldManifest(doc, findings);
    if (manifest) {
      lintServiceFieldManifest(
        manifest,
        {
          coordinate,
          ownedFields: ownedFieldsFor(coordinate, schema),
          declaredFields,
        },
        findings,
      );
    }
    for (const f of findings) {
      out.push({
        module: m.name,
        severity: f.severity,
        message: `${coordinate} field manifest (${path}): ${f.message}`,
      });
    }
  }
}

// Validate a set of module configs; returns the aggregated report.
export function validateModules(
  modules: ModuleConfig[],
  opts: ValidateOptions,
): ValidateReport {
  const findings: ValidateFinding[] = [];
  for (const m of modules) validateModule(m, opts, findings);
  const errors = findings.filter((f) => f.severity === "error").length;
  const warnings = findings.filter((f) => f.severity === "warning").length;
  return { findings, errors, warnings };
}
