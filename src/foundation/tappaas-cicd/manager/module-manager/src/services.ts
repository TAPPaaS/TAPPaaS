// services.ts — the dependency-service drift check the read-only inspect
// delegates to (#458).
//
// `reconcile <module>` without --apply compared CONFIG FIELDS only (git ↔
// ~/config, plus the live VM when the module has one). For a POLICY-ONLY module
// — no VM, every bit of its state provisioned by its dependsOn providers
// (firewall rules, NAT rules, discovery relays) — that reported "no
// discrepancies" while declared rules were missing from the firewall; only
// `module test` caught it.
//
// Rather than reimplement each plane's comparison here, this delegates to the
// SAME read-only verifier test-module.sh Step 3 runs: each provider's
// services/<service>/test-service.sh <module> (network:rules → `rules-manager
// verify-rules`, network:nat → a `nat-manager list-rules` compare, …). Exit 0 =
// no drift, non-zero = drift. Nothing is mutated.
//
// COST: one child process — typically one firewall API round-trip — per
// dependsOn entry, so the CALLER decides when to pay it: ON for a single
// `reconcile <module>`, OFF for the `list --diff` fleet rollup and the
// site/environment reconcile PREVIEW cascade (see main.ts and
// environment-manager/src/clients.ts).
//
// STRUCTURE, as in inspect.ts: everything above the I/O line is PURE (the two
// filesystem lookups arrive through an injectable ServiceFs) so the planning and
// rendering logic is unit-testable offline (test/unit/inspect.test.ts).

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { captureResult } from "../../../lib/ts/src/exec";
import { getModuleDir, resolveProviderModule } from "./config";
import type { OutLine } from "./inspect";
import { BL, CL, GN, RD, YW } from "./shlog";

// ── pure: dependency coordinate → provider + service ───────────────────

// Same split the bash and reconcile.ts use: provider is everything before the
// FIRST colon (${dep%%:*}), service everything after the LAST (${dep##*:}). A
// bare "cluster" therefore yields provider=service="cluster", as in the bash.
export function parseDependency(dep: string): { provider: string; service: string } {
  const colon = dep.indexOf(":");
  return {
    provider: colon === -1 ? dep : dep.slice(0, colon),
    service: dep.slice(dep.lastIndexOf(":") + 1),
  };
}

// ── pure: the plan (which deps can actually be checked) ────────────────

export type ServiceCheckKind = "checkable" | "no-script" | "provider-missing";

export interface ServiceCheck {
  dep: string; // the dependsOn coordinate as written, e.g. "network:rules"
  provider: string; // RESOLVED provider module name (environment-aware)
  service: string;
  script: string; // path to test-service.sh ("" unless kind === "checkable")
  kind: ServiceCheckKind;
}

// The filesystem facts planning needs, injectable so tests need no real tree.
export interface ServiceFs {
  // Resolve a dependsOn provider name to its deployed module name + source dir
  // (the same resolution reconcile.ts does: environment-aware provider, then
  // .location from the deployed config). dir === null = provider not locatable.
  providerDir(provider: string, environment: string): { module: string; dir: string | null };
  exists(path: string): boolean;
  // Read a file, or null when it is absent/unreadable. Added for the ADR-020
  // service field-manifest lint, which must PARSE services/<svc>/fields.json —
  // knowing that it exists is not enough. Injectable for the same reason the
  // other two are: validate stays offline and testable with no tree.
  readFile(path: string): string | null;
}

export function realServiceFs(configDir: string): ServiceFs {
  return {
    providerDir(provider, environment) {
      const module = resolveProviderModule(configDir, provider, environment);
      return { module, dir: getModuleDir(configDir, module) };
    },
    exists: (p) => existsSync(p),
    readFile: (p) => {
      try {
        return readFileSync(p, "utf8");
      } catch {
        return null;
      }
    },
  };
}

export function planServiceChecks(
  deps: string[],
  environment: string,
  fs: ServiceFs,
): ServiceCheck[] {
  const out: ServiceCheck[] = [];
  for (const dep of deps) {
    const { provider, service } = parseDependency(dep);
    const resolved = fs.providerDir(provider, environment);
    if (!resolved.dir) {
      out.push({ dep, provider: resolved.module, service, script: "", kind: "provider-missing" });
      continue;
    }
    const script = join(resolved.dir, "services", service, "test-service.sh");
    if (!fs.exists(script)) {
      out.push({ dep, provider: resolved.module, service, script: "", kind: "no-script" });
      continue;
    }
    out.push({ dep, provider: resolved.module, service, script, kind: "checkable" });
  }
  return out;
}

// ── pure: outcomes + rendering ─────────────────────────────────────────

// clean   — test-service.sh exited 0 (no drift)
// drift   — it RAN and exited non-zero: either drift or its own die(); the
//           captured output is surfaced so the operator sees which
// unknown   — it could not be run at all (missing / non-executable) → the one
//           condition that makes inspect exit 1: unknown state is not "clean"
// skipped — nothing to run (no test-service.sh, or provider not locatable)
export type ServiceCheckStatus = "clean" | "drift" | "unknown" | "skipped";

export interface ServiceCheckOutcome {
  check: ServiceCheck;
  status: ServiceCheckStatus;
  rc: number | null; // null when no script was run
  detail: string; // captured output (drift/unknown) or the skip reason
}

export interface ServiceSection {
  lines: OutLine[];
  checked: boolean; // false = the checks were not run at all (opt-out / rollup)
  deps: string[]; // every dependsOn coordinate considered
  drift: number;
  unknown: number;
  skipped: number;
}

// Cap the surfaced output of a failing check so one chatty verifier cannot
// flood a whole-fleet rollup. What is dropped is always stated (never a silent
// truncation).
const MAX_DETAIL_LINES = 40;

function detailLines(detail: string): OutLine[] {
  const all = detail.replace(/\s+$/, "").split("\n").filter((l) => l.trim() !== "");
  const shown = all.slice(0, MAX_DETAIL_LINES);
  const out: OutLine[] = shown.map((l) => ({ kind: "raw" as const, text: `        ${l}` }));
  if (all.length > shown.length) {
    out.push({
      kind: "raw",
      text: `        … ${all.length - shown.length} more line(s) — rerun 'module-manager test <module>' for the full output`,
    });
  }
  return out;
}

export function buildServiceSection(
  deps: string[],
  outcomes: ServiceCheckOutcome[] | null,
): ServiceSection {
  if (outcomes === null) {
    return { lines: [], checked: false, deps, drift: 0, unknown: 0, skipped: 0 };
  }
  const lines: OutLine[] = [
    {
      kind: "info",
      text: "Dependency-service state (each provider's read-only test-service.sh):",
    },
  ];
  let drift = 0;
  let unknown = 0;
  let skipped = 0;
  for (const o of outcomes) {
    const dep = `${BL}${o.check.dep}${CL}`;
    switch (o.status) {
      case "clean":
        lines.push({ kind: "raw", text: `    ${GN}✓${CL} ${dep} — no drift` });
        break;
      case "drift":
        drift++;
        lines.push({ kind: "raw", text: `    ${RD}✗${CL} ${dep} — DRIFT (test-service.sh exit ${o.rc})` });
        lines.push(...detailLines(o.detail));
        break;
      case "unknown":
        unknown++;
        lines.push({ kind: "raw", text: `    ${YW}?${CL} ${dep} — could not run test-service.sh` });
        lines.push(...detailLines(o.detail));
        break;
      case "skipped":
        skipped++;
        lines.push({ kind: "raw", text: `    ${YW}~${CL} ${dep} — NOT checked (${o.detail})` });
        break;
    }
  }
  lines.push({ kind: "raw", text: "" });
  return { lines, checked: true, deps, drift, unknown, skipped };
}

// The summary lines the inspect report appends after its field summary. When the
// checks did NOT run, this is the line that keeps a field-clean report honest
// (#458): it names the dependency state that was left uncovered instead of
// reporting a bare "no discrepancies found".
export function serviceSummaryLines(module: string, svc: ServiceSection): OutLine[] {
  if (!svc.checked) {
    if (svc.deps.length === 0) return [];
    return [
      {
        kind: "info",
        text:
          `dependency-service state NOT checked (${svc.deps.join(", ")}) — ` +
          `run '${YW}module-manager test ${module}${CL}', or reconcile with --services`,
      },
    ];
  }
  const out: OutLine[] = [];
  if (svc.drift > 0) {
    out.push({
      kind: "error",
      text:
        `${svc.drift} dependency service(s) drifted from the declared config (${RD}✗${CL}) — ` +
        `'module-manager reconcile ${module} --apply' re-applies them`,
    });
  }
  if (svc.unknown > 0) {
    out.push({
      kind: "error",
      text: `${svc.unknown} dependency service check(s) could not run — state unknown`,
    });
  }
  if (svc.skipped > 0) {
    out.push({
      kind: "warn",
      text: `${svc.skipped} dependency service(s) have no test-service.sh — their state is NOT covered by this report`,
    });
  }
  if (svc.drift === 0 && svc.unknown === 0) {
    const checked = svc.deps.length - svc.skipped;
    if (checked > 0) {
      out.push({
        kind: "info",
        text: `${GN}${checked} dependency service(s) report no drift${CL}`,
      });
    }
  }
  return out;
}

// A check that could not be RUN leaves the module's state undetermined, so the
// verb must not exit 0 on it — the same rule inspect already applies to an
// unreachable Proxmox node. Detected DRIFT deliberately stays rc 0: inspect is a
// report, and `list --diff` plus the reconcile --deep cascade propagate its rc.
export function serviceExitCode(svc: ServiceSection): number {
  return svc.unknown > 0 ? 1 : 0;
}

// ── I/O: run the verifiers ─────────────────────────────────────────────

export function runServiceChecks(module: string, checks: ServiceCheck[]): ServiceCheckOutcome[] {
  const out: ServiceCheckOutcome[] = [];
  for (const check of checks) {
    if (check.kind === "provider-missing") {
      out.push({
        check,
        status: "skipped",
        rc: null,
        detail: `provider '${check.provider}' location unknown`,
      });
      continue;
    }
    if (check.kind === "no-script") {
      out.push({ check, status: "skipped", rc: null, detail: "no test-service.sh" });
      continue;
    }
    // Captured, not streamed: green checks stay quiet, and a failing check's
    // output is surfaced under its own line (what test-module.sh Step 3 does).
    const r = captureResult(check.script, [module]);
    if (!r.ran) {
      out.push({ check, status: "unknown", rc: null, detail: r.stderr.trim() || "spawn failed" });
      continue;
    }
    if (r.rc === 0) {
      out.push({ check, status: "clean", rc: 0, detail: "" });
      continue;
    }
    out.push({
      check,
      status: "drift",
      rc: r.rc,
      detail: [r.stdout, r.stderr].filter((s) => s.trim() !== "").join("\n"),
    });
  }
  return out;
}

// Plan + run in one call, for the inspect I/O layer.
export function checkDependencyServices(
  configDir: string,
  module: string,
  deps: string[],
  environment: string,
): ServiceSection {
  const checks = planServiceChecks(deps, environment, realServiceFs(configDir));
  return buildServiceSection(deps, runServiceChecks(module, checks));
}
