// validate.ts — the backup-manager `validate` verb (port of validate-backup.sh).
//
// Validates the Site → Environment → Module backup hierarchy is consistent.
// Read-only, pure (no PBS). Returns a result so main can print + set exit code,
// and so tests can assert against fixtures. Checks (verbatim from the bash):
//   1. site backup.defaultRetention parses (^[0-9]+[dwmy]$)
//   2. environment backup.residency is a valid enum (eu-only|global)
//   3. an eu-only environment is NOT targeted at a non-EU offsite
//   4. module backup.enabled:false is honoured (resolves to disabled — reported)
//   5. no dangling target: if any module has backup enabled AND is wired into
//      the PBS job, site.backup.target must be set.

import {
  environmentRaw,
  listEnvironments,
  listModules,
  moduleInPbsJob,
  resolvePolicy,
  siteBackup,
} from "./config";

export interface ValidateResult {
  oks: string[];
  errors: string[];
}

// A retention string is N followed by a unit d/w/m/y (PBS-style shorthand).
export function retentionValid(s: string): boolean {
  return /^[0-9]+[dwmy]$/.test(s);
}

function asString(v: unknown): string | null {
  return typeof v === "string" && v !== "" ? v : null;
}

export function validate(configDir: string): ValidateResult {
  const oks: string[] = [];
  const errors: string[] = [];
  const ok = (m: string): void => void oks.push(m);
  const err = (m: string): void => void errors.push(m);

  const site = siteBackup(configDir);

  // ── 1. site defaultRetention parses ──────────────────────────────
  const sret = asString(site.defaultRetention) ?? "7y";
  if (retentionValid(sret)) ok(`site defaultRetention '${sret}' parses`);
  else
    err(
      `site backup.defaultRetention '${sret}' is not a valid retention (expected e.g. 7y, 14d)`,
    );

  // ── 2/3. environment residency enum + eu-only vs offsite residency ─
  const offsite = asString(site.offsite);
  const offsiteRes = asString(site.offsiteResidency) ?? "eu-only";
  const target = asString(site.target);

  for (const ename of listEnvironments(configDir)) {
    const e = environmentRaw(configDir, ename);
    const eBackup =
      e.backup && typeof e.backup === "object" ? (e.backup as Record<string, unknown>) : {};
    const eres = asString(eBackup.residency) ?? asString(e.dataResidency) ?? "eu-only";
    if (eres === "eu-only" || eres === "global")
      ok(`environment '${ename}' residency '${eres}' valid`);
    else err(`environment '${ename}' residency '${eres}' is not a valid enum (eu-only|global)`);

    if (eres === "eu-only" && offsite && offsiteRes !== "eu-only") {
      err(
        `environment '${ename}' is eu-only but site offsite '${offsite}' is residency ` +
          `'${offsiteRes}' (non-EU)`,
      );
    }

    const eret = asString(eBackup.retention);
    if (eret && !retentionValid(eret)) {
      err(`environment '${ename}' backup.retention '${eret}' is not a valid retention`);
    }
  }

  // ── 4/5. per-module: enabled honoured, retention parses, dangling target ─
  let anyEnabledInJob = false;
  for (const module of listModules(configDir)) {
    const pol = resolvePolicy(configDir, module);
    if (!retentionValid(pol.retention)) {
      err(`module '${module}' resolves to invalid retention '${pol.retention}'`);
    }
    // ADR-012 §3.2: once a day is the maximum frequency the platform backs
    // anything up, and the vocabulary is daily|weekly|monthly|HH:MM. An
    // unsupported spec is an ERROR, not a silent fall back to daily — a module
    // that asked for hourly must be told it cannot have it.
    if (!pol.scheduleBucket) {
      err(
        `module '${module}' resolves to unsupported backup schedule '${pol.schedule}' — ` +
          `use daily | weekly | monthly | HH:MM (never more often than once a day)`,
      );
    }
    if (!pol.enabled) {
      ok(`module '${module}' backup disabled (honoured)`);
    }
    if (pol.enabled && moduleInPbsJob(configDir, module)) {
      anyEnabledInJob = true;
    }
  }

  if (anyEnabledInJob && !target) {
    err(
      "modules have backup enabled and are wired into the PBS job, but " +
        "site.backup.target is not set (dangling)",
    );
  } else if (target) {
    ok(`site backup target '${target}' set`);
  }

  return { oks, errors };
}
