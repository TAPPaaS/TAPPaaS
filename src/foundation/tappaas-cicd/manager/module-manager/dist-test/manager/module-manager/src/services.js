"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.parseDependency = parseDependency;
exports.realServiceFs = realServiceFs;
exports.planServiceChecks = planServiceChecks;
exports.buildServiceSection = buildServiceSection;
exports.serviceSummaryLines = serviceSummaryLines;
exports.serviceExitCode = serviceExitCode;
exports.runServiceChecks = runServiceChecks;
exports.checkDependencyServices = checkDependencyServices;
const fs_1 = require("fs");
const path_1 = require("path");
const exec_1 = require("../../../lib/ts/src/exec");
const config_1 = require("./config");
const shlog_1 = require("./shlog");
// ── pure: dependency coordinate → provider + service ───────────────────
// Same split the bash and reconcile.ts use: provider is everything before the
// FIRST colon (${dep%%:*}), service everything after the LAST (${dep##*:}). A
// bare "cluster" therefore yields provider=service="cluster", as in the bash.
function parseDependency(dep) {
    const colon = dep.indexOf(":");
    return {
        provider: colon === -1 ? dep : dep.slice(0, colon),
        service: dep.slice(dep.lastIndexOf(":") + 1),
    };
}
function realServiceFs(configDir) {
    return {
        providerDir(provider, environment) {
            const module = (0, config_1.resolveProviderModule)(configDir, provider, environment);
            return { module, dir: (0, config_1.getModuleDir)(configDir, module) };
        },
        exists: (p) => (0, fs_1.existsSync)(p),
        readFile: (p) => {
            try {
                return (0, fs_1.readFileSync)(p, "utf8");
            }
            catch {
                return null;
            }
        },
    };
}
function planServiceChecks(deps, environment, fs) {
    const out = [];
    for (const dep of deps) {
        const { provider, service } = parseDependency(dep);
        const resolved = fs.providerDir(provider, environment);
        if (!resolved.dir) {
            out.push({ dep, provider: resolved.module, service, script: "", kind: "provider-missing" });
            continue;
        }
        const script = (0, path_1.join)(resolved.dir, "services", service, "test-service.sh");
        if (!fs.exists(script)) {
            out.push({ dep, provider: resolved.module, service, script: "", kind: "no-script" });
            continue;
        }
        out.push({ dep, provider: resolved.module, service, script, kind: "checkable" });
    }
    return out;
}
// Cap the surfaced output of a failing check so one chatty verifier cannot
// flood a whole-fleet rollup. What is dropped is always stated (never a silent
// truncation).
const MAX_DETAIL_LINES = 40;
function detailLines(detail) {
    const all = detail.replace(/\s+$/, "").split("\n").filter((l) => l.trim() !== "");
    const shown = all.slice(0, MAX_DETAIL_LINES);
    const out = shown.map((l) => ({ kind: "raw", text: `        ${l}` }));
    if (all.length > shown.length) {
        out.push({
            kind: "raw",
            text: `        … ${all.length - shown.length} more line(s) — rerun 'module-manager test <module>' for the full output`,
        });
    }
    return out;
}
function buildServiceSection(deps, outcomes) {
    if (outcomes === null) {
        return { lines: [], checked: false, deps, drift: 0, unknown: 0, skipped: 0 };
    }
    const lines = [
        {
            kind: "info",
            text: "Dependency-service state (each provider's read-only test-service.sh):",
        },
    ];
    let drift = 0;
    let unknown = 0;
    let skipped = 0;
    for (const o of outcomes) {
        const dep = `${shlog_1.BL}${o.check.dep}${shlog_1.CL}`;
        switch (o.status) {
            case "clean":
                lines.push({ kind: "raw", text: `    ${shlog_1.GN}✓${shlog_1.CL} ${dep} — no drift` });
                break;
            case "drift":
                drift++;
                lines.push({ kind: "raw", text: `    ${shlog_1.RD}✗${shlog_1.CL} ${dep} — DRIFT (test-service.sh exit ${o.rc})` });
                lines.push(...detailLines(o.detail));
                break;
            case "unknown":
                unknown++;
                lines.push({ kind: "raw", text: `    ${shlog_1.YW}?${shlog_1.CL} ${dep} — could not run test-service.sh` });
                lines.push(...detailLines(o.detail));
                break;
            case "skipped":
                skipped++;
                lines.push({ kind: "raw", text: `    ${shlog_1.YW}~${shlog_1.CL} ${dep} — NOT checked (${o.detail})` });
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
function serviceSummaryLines(module, svc) {
    if (!svc.checked) {
        if (svc.deps.length === 0)
            return [];
        return [
            {
                kind: "info",
                text: `dependency-service state NOT checked (${svc.deps.join(", ")}) — ` +
                    `run '${shlog_1.YW}module-manager test ${module}${shlog_1.CL}', or reconcile with --services`,
            },
        ];
    }
    const out = [];
    if (svc.drift > 0) {
        out.push({
            kind: "error",
            text: `${svc.drift} dependency service(s) drifted from the declared config (${shlog_1.RD}✗${shlog_1.CL}) — ` +
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
                text: `${shlog_1.GN}${checked} dependency service(s) report no drift${shlog_1.CL}`,
            });
        }
    }
    return out;
}
// A check that could not be RUN leaves the module's state undetermined, so the
// verb must not exit 0 on it — the same rule inspect already applies to an
// unreachable Proxmox node. Detected DRIFT deliberately stays rc 0: inspect is a
// report, and `list --diff` plus the reconcile --deep cascade propagate its rc.
function serviceExitCode(svc) {
    return svc.unknown > 0 ? 1 : 0;
}
// ── I/O: run the verifiers ─────────────────────────────────────────────
function runServiceChecks(module, checks) {
    const out = [];
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
        const r = (0, exec_1.captureResult)(check.script, [module]);
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
function checkDependencyServices(configDir, module, deps, environment) {
    const checks = planServiceChecks(deps, environment, realServiceFs(configDir));
    return buildServiceSection(deps, runServiceChecks(module, checks));
}
