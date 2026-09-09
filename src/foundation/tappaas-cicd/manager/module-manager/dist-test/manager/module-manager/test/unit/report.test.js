"use strict";
// report.test.ts — the manager's client for report-service.sh (ADR-020 D7, P2).
//
// The thing worth testing here is the ERROR MODEL, not the happy path. #526 was
// caused by one message — "Failed to get VM config" — standing for three
// different situations with three different remedies: the cluster was
// unreachable, the guest was absent (possibly correctly, for an archived
// module), or the guest was there but unreadable. The reporter now returns a
// distinct exit code for each, and this file pins that mapping: if a code is
// ever renumbered on one side only, these go red rather than the fleet quietly
// collapsing back to one message.
//
// Throwaway scripts in a temp tree stand in for the real reporters, so the
// mapping is exercised end to end (spawn, exit code, stdout parse) with no
// cluster.
Object.defineProperty(exports, "__esModule", { value: true });
const fs_1 = require("fs");
const os_1 = require("os");
const path_1 = require("path");
const report_1 = require("../../src/report");
let passed = 0;
let failed = 0;
function check(cond, msg) {
    if (cond) {
        passed++;
        console.log(`  ok: ${msg}`);
    }
    else {
        failed++;
        console.log(`  FAIL: ${msg}`);
    }
}
// A config dir with a deployed `cluster` provider whose source tree holds
// stub reporters we control.
const root = (0, fs_1.mkdtempSync)((0, path_1.join)((0, os_1.tmpdir)(), "mm-report-"));
const configDir = (0, path_1.join)(root, "config");
const srcDir = (0, path_1.join)(root, "src", "cluster");
(0, fs_1.mkdirSync)(configDir, { recursive: true });
(0, fs_1.mkdirSync)((0, path_1.join)(srcDir, "services", "vm"), { recursive: true });
(0, fs_1.mkdirSync)((0, path_1.join)(srcDir, "services", "lxc"), { recursive: true });
(0, fs_1.writeFileSync)((0, path_1.join)(configDir, "cluster.json"), JSON.stringify({ vmname: "cluster", location: srcDir, kind: "module" }));
// Install a stub reporter for one guest type. `body` is the script body after
// the shebang; omit to REMOVE the reporter entirely.
function stub(service, body) {
    const p = (0, path_1.join)(srcDir, "services", service, "report-service.sh");
    if (body === null) {
        (0, fs_1.rmSync)(p, { force: true });
        return;
    }
    (0, fs_1.writeFileSync)(p, `#!/usr/bin/env bash\n${body}\n`);
    (0, fs_1.chmodSync)(p, 0o755);
}
const OK_VM = `echo '{"vmid":"340","node":"tappaas1","status":"running","name":"demo","cores":4}'`;
try {
    // ── the happy path, and the string coercion the differ relies on ──────
    {
        stub("vm", OK_VM);
        const r = (0, report_1.runReporter)(configDir, "demo", "qemu", "");
        check(r.kind === "ok", "a reporter exiting 0 with a JSON object is an ok outcome");
        if (r.kind === "ok") {
            check(r.actual.node === "tappaas1", "…and its keys reach the caller");
            check(r.actual.cores === "4", "a non-string value is coerced to a string — the differ compares strings, always");
        }
    }
    // ── each exit code keeps its own meaning (the #526 lesson) ────────────
    {
        stub("vm", "exit 4");
        check((0, report_1.runReporter)(configDir, "demo", "qemu", "").kind === "cluster-unreachable", "exit 4 means the CLUSTER could not be reached — an infrastructure problem");
        stub("vm", "exit 5");
        check((0, report_1.runReporter)(configDir, "demo", "qemu", "").kind === "not-present", "exit 5 means the guest is ABSENT — which for an archived module is correct state");
        stub("vm", "exit 6");
        check((0, report_1.runReporter)(configDir, "demo", "qemu", "").kind === "unreadable", "exit 6 means the guest was found but its config could not be read");
        stub("vm", "exit 3");
        const other = (0, report_1.runReporter)(configDir, "demo", "qemu", "");
        check(other.kind === "error" && other.rc === 3, "any other non-zero code surfaces as an error carrying the code, not a guess");
    }
    // ── a broken reporter must not degrade into "the guest has nothing" ───
    {
        stub("vm", "echo 'not json'");
        const r = (0, report_1.runReporter)(configDir, "demo", "qemu", "");
        check(r.kind === "error" && r.detail.includes("invalid JSON"), "a zero exit with unparseable output is an error, never an empty actual state");
        stub("vm", "echo '[1,2]'");
        check((0, report_1.runReporter)(configDir, "demo", "qemu", "").kind === "error", "a JSON array is not a state object — also an error");
    }
    // ── a provider not yet on the contract is distinguishable ────────────
    {
        stub("vm", null);
        const r = (0, report_1.runReporter)(configDir, "demo", "qemu", "");
        check(r.kind === "no-reporter", "a provider shipping no report-service.sh is 'no-reporter', not a failure (P5 is still in progress)");
    }
    // ── the declared guest type is intent; the cluster holds the truth ────
    {
        // Declares a VM, but only the LXC reporter finds it.
        stub("vm", "exit 5");
        stub("lxc", `echo '{"vmid":"312","node":"tappaas2","status":"running","hostname":"c"}'`);
        const r = (0, report_1.reportGuest)(configDir, "demo", "qemu", "");
        check(r.outcome.kind === "ok" && r.outcome.guest === "lxc", "a module declaring the wrong guest type is still reported — from the type that has it");
        check(r.declaredGuest === "qemu", "…and the caller is told the declaration was wrong, rather than being handed a bare 'not found'");
        // Genuinely absent under BOTH types: report the declared type's answer, so
        // the message is phrased in terms of what the module says it is.
        stub("lxc", "exit 5");
        const gone = (0, report_1.reportGuest)(configDir, "demo", "qemu", "");
        check(gone.outcome.kind === "not-present" && gone.declaredGuest === undefined, "a guest absent under both types is simply not present — no spurious type warning");
    }
    // ── an unlocatable provider is not a crash ───────────────────────────
    {
        const empty = (0, fs_1.mkdtempSync)((0, path_1.join)((0, os_1.tmpdir)(), "mm-report-empty-"));
        try {
            check((0, report_1.runReporter)(empty, "demo", "qemu", "").kind === "no-reporter", "a config dir with no cluster provider yields 'no-reporter', not a throw");
        }
        finally {
            (0, fs_1.rmSync)(empty, { recursive: true, force: true });
        }
    }
}
finally {
    (0, fs_1.rmSync)(root, { recursive: true, force: true });
}
console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
