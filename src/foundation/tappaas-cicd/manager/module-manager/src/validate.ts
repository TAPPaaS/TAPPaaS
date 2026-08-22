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
import { ServiceFs, parseDependency } from "./services";
import { ModuleConfig, ValidateFinding, ValidateReport } from "./types";

export const VALID_TIERS = ["foundation", "app"] as const;
export const VALID_SOURCES = ["official", "community", "private", "local"] as const;

export interface ValidateOptions {
  allowFork?: boolean;
  // Filesystem probe for the dependsOn reference-integrity check (#495 follow-up).
  // Omit it and that check is SKIPPED — the tier/source lint stays pure and
  // usable without a tree. main.ts always supplies realServiceFs(configDir).
  fs?: ServiceFs;
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

  // dependsOn reference integrity — see validateDependsOn.
  if (opts.fs) validateDependsOn(m, opts.fs, out);

  // TODO(question): the bash stub also intended a SCHEMA check (every field
  // against module-fields.json). PARKED — see main.ts. The reference-integrity
  // half of that TODO is now implemented above.
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
