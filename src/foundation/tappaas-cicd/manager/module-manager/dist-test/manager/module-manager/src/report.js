"use strict";
// report.ts — the manager's client for `services/<svc>/report-service.sh`
// (ADR-020 D7, the actual-state read).
//
// One read, several consumers. `inspect` (report), `modify` (apply) and the
// health checks all take their idea of ACTUAL state from the provider's own
// reporter rather than each shelling their own `qm config` and parsing it.
// Before ADR-020 the parsing existed twice — in `cluster:vm/update-service.sh`
// and (in TypeScript) in `inspect.ts` — and the two had already drifted: the
// bash one could not read a container's `hwaddr=` MAC (#465, #550).
//
// What this file adds over "run a script and parse JSON" is the ERROR MODEL.
// The reporter's exit codes name distinct operator actions, and the caller has
// distinct things to say about each: an unreachable cluster is not the same as
// a guest that is intentionally absent (an archived module), which is not the
// same as a guest that is there but unreadable (#526). Collapsing them into one
// "failed to get VM config" is exactly what #526 had to undo.
Object.defineProperty(exports, "__esModule", { value: true });
exports.reporterPath = reporterPath;
exports.runServiceReporter = runServiceReporter;
exports.runReporter = runReporter;
exports.reportGuest = reportGuest;
const fs_1 = require("fs");
const path_1 = require("path");
const exec_1 = require("../../../lib/ts/src/exec");
const config_1 = require("./config");
// The service directory each guest type's reporter lives in, under the
// `cluster` provider module.
const SERVICE_FOR = { qemu: "vm", lxc: "lxc" };
// Locate a provider service's report-service.sh. Environment-aware, exactly as
// the dependency-service checks resolve a provider (#438).
function reporterPath(configDir, provider, service, environment) {
    const module = (0, config_1.resolveProviderModule)(configDir, provider, environment);
    const dir = (0, config_1.getModuleDir)(configDir, module);
    if (!dir)
        return null;
    const path = (0, path_1.join)(dir, "services", service, "report-service.sh");
    return (0, fs_1.existsSync)(path) ? path : null;
}
// Run ANY provider service's reporter and classify the result. The guest-typed
// wrapper below is the cluster-specific case; every other provider that grows a
// reporter (P5) is reached through this one.
function runServiceReporter(configDir, module, provider, service, environment, guest = "qemu") {
    const path = reporterPath(configDir, provider, service, environment);
    if (!path)
        return { kind: "no-reporter", path: `${provider}/services/${service}/report-service.sh` };
    const r = (0, exec_1.captureResult)(path, [module]);
    if (!r.ran)
        return { kind: "error", rc: -1, detail: r.stderr.trim() || "spawn failed" };
    switch (r.rc) {
        case 0:
            break;
        case 4:
            return { kind: "cluster-unreachable" };
        case 5:
            return { kind: "not-present" };
        case 6:
            return { kind: "unreadable", detail: r.stderr.trim() };
        default:
            return { kind: "error", rc: r.rc, detail: [r.stdout, r.stderr].filter((s) => s.trim()).join("\n") };
    }
    // A zero exit must carry one JSON object. Anything else is a broken reporter,
    // reported as such rather than degraded into an empty actual state — "we did
    // not look" must never render as "the guest has nothing set".
    let parsed;
    try {
        parsed = JSON.parse(r.stdout);
    }
    catch (e) {
        return { kind: "error", rc: 0, detail: `report-service.sh emitted invalid JSON: ${e.message}` };
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        return { kind: "error", rc: 0, detail: "report-service.sh did not emit a JSON object" };
    }
    const actual = {};
    for (const [k, v] of Object.entries(parsed)) {
        actual[k] = typeof v === "string" ? v : v === null || v === undefined ? "" : String(v);
    }
    return { kind: "ok", actual, guest };
}
// The cluster case: pick the reporter by guest type.
function runReporter(configDir, module, guest, environment) {
    return runServiceReporter(configDir, module, "cluster", SERVICE_FOR[guest], environment, guest);
}
function reportGuest(configDir, module, declared, environment) {
    const first = runReporter(configDir, module, declared, environment);
    if (first.kind !== "not-present")
        return { outcome: first };
    const other = declared === "qemu" ? "lxc" : "qemu";
    const second = runReporter(configDir, module, other, environment);
    if (second.kind === "ok")
        return { outcome: second, declaredGuest: declared };
    // The other type has nothing either: the guest really is absent. Report the
    // FIRST answer, which is the one phrased in terms of what the module declares.
    return { outcome: first };
}
