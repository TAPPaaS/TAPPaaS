"use strict";
// fake-client.ts — in-memory ModuleClient for offline unit tests.
//
// Records every lifecycle invocation (verb + module + the option flags it would
// forward to the bash script) so tests can assert exactly what `module add` /
// `delete` / etc. would shell out to, WITHOUT running any script or touching the
// cluster. Mirrors people-manager's FakeClient pattern. The configurable `rc`
// lets a test simulate a script failure.
Object.defineProperty(exports, "__esModule", { value: true });
exports.FakeModuleClient = void 0;
class FakeModuleClient {
    log = [];
    rc = 0; // exit code every method returns (set per-test to simulate failure)
    // Live cluster state the default `list` folds in. Default [] = "cluster
    // unreachable" (the config-only graceful-degrade path); a test sets it to
    // exercise the running-vs-config merge + orphan detection.
    guests = [];
    add(module, opts) {
        this.log.push({ verb: "add", module, opts });
        return this.rc;
    }
    modify(module, opts) {
        this.log.push({ verb: "modify", module, opts });
        return this.rc;
    }
    delete(module, opts) {
        this.log.push({ verb: "delete", module, opts });
        return this.rc;
    }
    reconcile(module, opts) {
        this.log.push({ verb: "reconcile", module, opts });
        return this.rc;
    }
    inspect(module, opts = {}) {
        this.log.push({ verb: "inspect", module, opts });
        return this.rc;
    }
    test(module, opts) {
        this.log.push({ verb: "test", module, opts });
        return this.rc;
    }
    migrate(module, opts) {
        this.log.push({ verb: "migrate", module, opts });
        return this.rc;
    }
    snapshot(module, action) {
        this.log.push({ verb: "snapshot", module, opts: action });
        return this.rc;
    }
    clusterResources() {
        return this.guests;
    }
}
exports.FakeModuleClient = FakeModuleClient;
