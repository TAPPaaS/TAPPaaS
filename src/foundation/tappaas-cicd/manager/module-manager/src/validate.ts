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

import { ModuleConfig, ValidateFinding, ValidateReport } from "./types";

export const VALID_TIERS = ["foundation", "app"] as const;
export const VALID_SOURCES = ["official", "community", "private", "local"] as const;

export interface ValidateOptions {
  allowFork?: boolean;
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

  // TODO(question): the bash stub also intended a SCHEMA check (every field
  // against module-fields.json) and reference-integrity (dependsOn providers
  // exist among deployed modules), mirroring people-manager's validateRefs.
  // PARKED — see main.ts. This first pass ports only the tier/source lint, which
  // is the only validator that actually exists in bash today.
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
