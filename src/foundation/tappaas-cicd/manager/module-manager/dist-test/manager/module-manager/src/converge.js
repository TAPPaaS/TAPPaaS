"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.loadServiceManifest = loadServiceManifest;
exports.driftForService = driftForService;
exports.coordinatesWithManifests = coordinatesWithManifests;
exports.parseSetArg = parseSetArg;
exports.preGateSet = preGateSet;
exports.renderDrift = renderDrift;
exports.cmdDrift = cmdDrift;
const fs_1 = require("fs");
const path_1 = require("path");
const drift_1 = require("../../../lib/ts/src/drift");
const service_fields_1 = require("../../../lib/ts/src/service-fields");
const shlog_1 = require("./shlog");
const config_1 = require("./config");
const services_1 = require("./services");
const resolve_1 = require("./resolve");
const report_1 = require("./report");
// zones.json drives the declared `vlan` and `trunks` normalizers. Absent → null,
// which those normalizers treat as "no zone is defined": a zone NAME then
// resolves to no tag, exactly as the bash did against a missing file.
function loadZones(configDir) {
    const path = (0, path_1.join)(configDir, "zones.json");
    if (!(0, fs_1.existsSync)(path))
        return null;
    try {
        const raw = JSON.parse((0, fs_1.readFileSync)(path, "utf8"));
        return raw !== null && typeof raw === "object" && !Array.isArray(raw)
            ? raw
            : null;
    }
    catch {
        return null;
    }
}
function loadServiceManifest(dir, service) {
    const path = (0, path_1.join)(dir, (0, service_fields_1.manifestRelPath)(service));
    const findings = [];
    if (!(0, fs_1.existsSync)(path))
        return { path, manifest: null, findings };
    let doc;
    try {
        doc = JSON.parse((0, fs_1.readFileSync)(path, "utf8"));
    }
    catch (e) {
        findings.push({ severity: "error", message: `not valid JSON: ${e.message}` });
        return { path, manifest: null, findings };
    }
    return { path, manifest: (0, service_fields_1.parseServiceFieldManifest)(doc, findings), findings };
}
// Compute the drift record for ONE coordinate.
function driftForService(configDir, module, coordinate) {
    const desired = (0, resolve_1.resolveModuleFromConfig)(module, configDir);
    if (!desired)
        return { ok: false, failure: { kind: "no-module" } };
    const { provider, service } = (0, services_1.parseDependency)(coordinate);
    const environment = desired.fields.environment?.value ?? "";
    const providerModule = (0, config_1.resolveProviderModule)(configDir, provider, environment);
    const providerDir = (0, config_1.getModuleDir)(configDir, providerModule);
    if (!providerDir)
        return { ok: false, failure: { kind: "no-provider", provider: providerModule } };
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
    if (!(0, service_fields_1.needsActualState)(manifest)) {
        return {
            ok: true,
            record: (0, drift_1.computeDrift)(desired, { manifest, actual: {}, zones: loadZones(configDir) }),
        };
    }
    const outcome = (0, report_1.runServiceReporter)(configDir, module, provider, service, environment);
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
        record: (0, drift_1.computeDrift)(desired, {
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
function coordinatesWithManifests(configDir, module) {
    const desired = (0, resolve_1.resolveModuleFromConfig)(module, configDir);
    if (!desired)
        return [];
    const environment = desired.fields.environment?.value ?? "";
    const out = [];
    for (const dep of [...desired.dependsOn, ...desired.integratesWith]) {
        if (!dep.includes(":"))
            continue;
        const { provider, service } = (0, services_1.parseDependency)(dep);
        const dir = (0, config_1.getModuleDir)(configDir, (0, config_1.resolveProviderModule)(configDir, provider, environment));
        if (!dir)
            continue;
        if ((0, fs_1.existsSync)((0, path_1.join)(dir, (0, service_fields_1.manifestRelPath)(service))))
            out.push(dep);
    }
    return out;
}
// Parse `field=value`. The value may contain '=' (a netopts string, a URL), so
// only the FIRST separator splits.
function parseSetArg(arg) {
    const eq = arg.indexOf("=");
    if (eq <= 0)
        return null;
    return { field: arg.slice(0, eq), value: arg.slice(eq + 1) };
}
function preGateSet(configDir, module, requests, schema) {
    const rejections = [];
    const warnings = [];
    const plan = [];
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
                    reason: `module-fields.json is not readable from ${configDir} — without it no field can be ` +
                        `validated or classified, so nothing is written`,
                },
            ],
        };
    }
    const desired = (0, resolve_1.resolveModuleFromConfig)(module, configDir);
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
    const manifests = new Map();
    const manifestFor = (coordinate) => {
        if (manifests.has(coordinate))
            return manifests.get(coordinate) ?? null;
        const { provider, service } = (0, services_1.parseDependency)(coordinate);
        const dir = (0, config_1.getModuleDir)(configDir, (0, config_1.resolveProviderModule)(configDir, provider, environment));
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
                reason: `'${module}' declares none of the services that use it (${usedBy.join(", ")}) — ` +
                    `setting it would change the config and nothing else`,
            });
            continue;
        }
        let rejected = false;
        for (const coordinate of owners) {
            const manifest = manifestFor(coordinate);
            if (!manifest) {
                warnings.push(`${req.field}: ${coordinate} has no field manifest yet, so its change class is unknown — ` +
                    `the converge may refuse this change at apply time`);
                continue;
            }
            const entry = manifest.fields[req.field];
            if (!entry) {
                warnings.push(`${req.field}: ${coordinate}'s manifest does not classify it`);
                continue;
            }
            const spec2 = service_fields_1.CHANGE_CLASSES[entry.class];
            if (spec2?.preGate) {
                rejections.push({
                    field: req.field,
                    reason: `${entry.class} under ${coordinate} — ${spec2.summary}. ` +
                        `Use 'module-manager module delete ${module}' then 'add' to change it.`,
                });
                rejected = true;
                break;
            }
            if (!rejected)
                plan.push({ ...req, coordinate, class: entry.class });
        }
    }
    // Reject the WHOLE command: no partial write across one modify, so config and
    // cluster never move independently (Resolved Question 5).
    if (rejections.length > 0)
        return { ok: false, rejections, warnings };
    return { ok: true, plan, warnings };
}
// ── rendering ──────────────────────────────────────────────────────────
// Every reason a field was not compared, in words an operator can act on. The
// differ records the reason precisely so this can be said instead of nothing.
const SKIP_REASON_TEXT = {
    "self-reconciling": "converged by the service itself, not diffed here",
    "no-desired-value": "this module declares no value, and no schema default applies",
    "not-reported": "the service's reporter does not observe it",
};
function failureLines(coordinate, f) {
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
function renderDrift(coordinate, r) {
    const out = [`${shlog_1.GN}${coordinate}${shlog_1.CL}`];
    if (!(0, drift_1.hasChanges)(r)) {
        // "Nothing compared" is NOT "in sync" — the same confusion #458 had to fix
        // on the dependency-service side. A clean verdict is only honest when
        // something was actually compared; otherwise say what was skipped and why,
        // and name the check that DOES cover it.
        if (r.inSync.length > 0) {
            out.push(`  ${shlog_1.GN}✓${shlog_1.CL} in sync (${r.inSync.length} field(s) compared, ${r.skipped.length} not compared)`);
            return out;
        }
        const byReason = new Map();
        for (const s of r.skipped) {
            const list = byReason.get(s.reason);
            if (list)
                list.push(s.field);
            else
                byReason.set(s.reason, [s.field]);
        }
        if (byReason.size === 0) {
            out.push(`  ${shlog_1.GN}✓${shlog_1.CL} nothing to compare — this service owns no field of this module`);
            return out;
        }
        out.push(`  ${shlog_1.YW}~${shlog_1.CL} nothing was compared here:`);
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
        out.push(`  ${shlog_1.BL}${u.name}${shlog_1.CL} [${u.class}, ${how}${fx}]`);
        for (const f of u.fields) {
            out.push(`      ${f.field}: ${f.actual || "-"} → ${f.desired}${f.defaulted ? " (schema default)" : ""}`);
        }
    }
    for (const f of r.unreconciled) {
        out.push(`  ${shlog_1.RD}✗${shlog_1.CL} ${f.field} [${f.class}] ${f.actual || "-"} → ${f.desired} — not reconcilable in place`);
    }
    // Deliberately not an ✗: the guest is fine and bigger than asked for. What
    // is wrong is the config, and the converge fixes that rather than failing.
    for (const f of r.adopt) {
        out.push(`  ${shlog_1.YW}~${shlog_1.CL} ${f.field} [${f.class}] config says ${f.desired}, guest already has ${f.actual} — ` +
            `config adopts ${f.actual} (nothing on the cluster changes)`);
    }
    if ((0, drift_1.needsDisruption)(r)) {
        out.push(`  ${shlog_1.YW}!${shlog_1.CL} applying this needs disruption authorization (${(0, drift_1.unitSideEffects)(r).join("+") || "downtime"}): ` +
            `'module modify ${r.module} --force', or rebootOk in the scheduled pass`);
    }
    return out;
}
function cmdDrift(module, opts) {
    const coordinates = opts.service ? [opts.service] : coordinatesWithManifests(opts.configDir, module);
    if (coordinates.length === 0) {
        if (opts.json) {
            (0, shlog_1.emitJson)({ module, services: {} });
            return 0;
        }
        (0, shlog_1.info)(`(no dependency of '${module}' declares a field manifest yet — nothing to diff)`);
        return 0;
    }
    // --json with ONE service prints the bare record: that is what
    // `update-service.sh --apply-drift` consumes, and wrapping it would make
    // every apply path unwrap it.
    if (opts.json && opts.service) {
        const r = driftForService(opts.configDir, module, opts.service);
        if (!r.ok) {
            for (const l of failureLines(opts.service, r.failure))
                (0, shlog_1.error)(l);
            // A service that is simply not on the contract yet is not a failure of
            // this command — the caller (a bare update-service.sh) falls back.
            return r.failure.kind === "no-manifest" ? 2 : 1;
        }
        (0, shlog_1.emitJson)(r.record);
        return 0;
    }
    let worst = 0;
    const records = {};
    for (const coordinate of coordinates) {
        const r = driftForService(opts.configDir, module, coordinate);
        if (!r.ok) {
            if (opts.json) {
                records[coordinate] = { error: r.failure };
            }
            else {
                for (const l of failureLines(coordinate, r.failure)) {
                    if (r.failure.kind === "no-manifest")
                        (0, shlog_1.warn)(l);
                    else
                        (0, shlog_1.error)(l);
                }
            }
            if (r.failure.kind !== "no-manifest")
                worst = 1;
            continue;
        }
        if (opts.json)
            records[coordinate] = r.record;
        else
            for (const l of renderDrift(coordinate, r.record))
                (0, shlog_1.info)(l);
    }
    if (opts.json)
        (0, shlog_1.emitJson)({ module, services: records });
    return worst;
}
