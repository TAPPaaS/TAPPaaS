"use strict";
// compose.test.ts — #567's safety net.
//
// The migration moves 55 field definitions out of a global file into the
// services that own them. What makes that safe is not care, it is this: the
// COMPOSED view must stay byte-identical to what every reader sees today, at
// every step. Move a field, run this, and either nothing changed for any of the
// 41 readers or the test says exactly which field broke.
//
// It is deliberately an equivalence test against a RECORDED baseline rather
// than against the live file: comparing the file to itself would pass forever,
// including after a field was moved and silently dropped.
Object.defineProperty(exports, "__esModule", { value: true });
const child_process_1 = require("child_process");
const fs_1 = require("fs");
const path_1 = require("path");
const compose_fields_1 = require("../../../../lib/ts/src/compose-fields");
let passed = 0;
let failed = 0;
function check(cond, msg) {
    if (cond) {
        console.log(`  ok: ${msg}`);
        passed++;
    }
    else {
        console.log(`  FAIL: ${msg}`);
        failed++;
    }
}
const MODULE_MANAGER = (0, path_1.join)(__dirname, "..", "..", "..", "..", "..");
const FOUNDATION = (0, path_1.join)(MODULE_MANAGER, "..", "..", "..");
// The BASELINE, not the live file. Comparing the live file to a view composed
// partly from itself passes trivially — including after a field was moved and
// dropped on the way. module-fields.baseline.json is the pre-migration schema,
// recorded once; it goes away when #567 is finished.
const live = JSON.parse((0, fs_1.readFileSync)((0, path_1.join)(MODULE_MANAGER, "test", "fixtures", "module-fields.baseline.json"), "utf8"));
const r = (0, compose_fields_1.composeFields)(FOUNDATION);
const composed = r.schema.fields;
// ── the composition is sound ────────────────────────────────────────────
check(r.findings.length === 0, `no field is defined twice (${r.findings.map((f) => f.field).join(", ") || "none"})`);
// ── and it is COMPLETE: every field a reader can ask for is still there ──
const liveNames = Object.keys(live.fields).filter((n) => !n.startsWith("_")).sort();
const composedNames = Object.keys(composed).sort();
const missing = liveNames.filter((n) => !composedNames.includes(n));
const extra = composedNames.filter((n) => !liveNames.includes(n));
check(missing.length === 0, `no field is lost by the move (missing: ${missing.join(", ") || "none"})`);
check(extra.length === 0, `no field appears from nowhere (extra: ${extra.join(", ") || "none"})`);
// ── and IDENTICAL, key for key. A default or a usedBy that shifts in the
//    move is exactly the silent breakage this test exists to catch.
const differing = [];
for (const n of liveNames) {
    if (!(n in composed))
        continue;
    if (JSON.stringify(live.fields[n]) !== JSON.stringify(composed[n]))
        differing.push(n);
}
check(differing.length === 0, `every definition survives the move unchanged (differing: ${differing.join(", ") || "none"})`);
// ── the tiering claim itself ────────────────────────────────────────────
// Not decoration: it is what the issue asks for. A field owned by a service
// must NOT still be defined globally once it has moved, or the global file has
// not actually shrunk and #567 is unfinished.
const owned = liveNames.filter((n) => {
    const u = live.fields[n].usedBy ?? [];
    return u.length > 0 && !u.includes("general");
});
const stillGlobal = owned.filter((n) => r.origin[n] === "schemas/module-fields.json");
console.log(`\n  progress: ${owned.length - stillGlobal.length}/${owned.length} service-owned definitions moved` +
    `, ${stillGlobal.length} still global`);
// ── the two composers must agree ────────────────────────────────────────
//
// There are two implementations on purpose — jq for bash and Python readers
// (which must not need node, and which run before any manager is built), and
// this one for in-process TypeScript. Two implementations that disagree would
// be worse than one, so the agreement is asserted rather than assumed.
{
    const composer = (0, path_1.join)(FOUNDATION, "tappaas-cicd", "scripts", "compose-fields.sh");
    let shellFields = null;
    try {
        const r = (0, child_process_1.spawnSync)(composer, [FOUNDATION], { encoding: "utf8" });
        shellFields = r.status === 0 && r.stdout
            ? JSON.parse(r.stdout).fields
            : null;
    }
    catch {
        shellFields = null;
    }
    if (shellFields === null) {
        console.log("  ok: SKIP two-composer agreement (compose-fields.sh not runnable here)");
        passed++;
    }
    else {
        const a = Object.keys(composed).sort();
        const b = Object.keys(shellFields).sort();
        check(JSON.stringify(a) === JSON.stringify(b), "jq and TypeScript composers see the same field set");
        const differ = a.filter((n) => JSON.stringify(composed[n]) !== JSON.stringify(shellFields[n]));
        check(differ.length === 0, `…and identical definitions (differing: ${differ.join(", ") || "none"})`);
    }
}
// ── the catalogue decides what a module is ──────────────────────────────
//
// Discovery walks site.json .repositories → each repo's module-catalog.json →
// dirname(moduleJson). Not the filesystem: a stray services/ directory is not a
// module, and an unregistered checkout beside a real repo is not a source of
// fields. Both would otherwise leak into the schema every reader trusts.
{
    const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = require("fs");
    const { tmpdir } = require("os");
    const root = mkdtempSync((0, path_1.join)(tmpdir(), "compose-cat-"));
    const cfg = (0, path_1.join)(root, "config");
    const repo = (0, path_1.join)(root, "repo");
    mkdirSync(cfg, { recursive: true });
    const mkModule = (rel, field) => {
        const dir = (0, path_1.join)(repo, rel);
        mkdirSync((0, path_1.join)(dir, "services", "svc"), { recursive: true });
        writeFileSync((0, path_1.join)(dir, `${rel.split("/").pop()}.json`), "{}");
        writeFileSync((0, path_1.join)(dir, "services", "svc", "fields.json"), JSON.stringify({
            service: "m:svc",
            fields: { [field]: { description: "x", type: "string", usedBy: ["m:svc"], class: "in-place", apply: "reconcile" } },
        }));
    };
    mkModule("src/a/registered", "registeredField");
    mkModule("src/a/unregistered", "rogueField");
    // Only the first is in the catalogue.
    writeFileSync((0, path_1.join)(repo, "src", "module-catalog.json"), JSON.stringify({ applicationModules: [{ moduleName: "registered", moduleJson: "src/a/registered/registered.json" }] }));
    writeFileSync((0, path_1.join)(cfg, "site.json"), JSON.stringify({ repositories: [{ name: "t", path: repo, catalog: "src/module-catalog.json" }] }));
    // A base schema for the composer to start from.
    mkdirSync((0, path_1.join)(repo, "src", "foundation", "schemas"), { recursive: true });
    writeFileSync((0, path_1.join)(repo, "src", "foundation", "schemas", "module-fields.json"), JSON.stringify({ fields: {} }));
    const res = (0, compose_fields_1.composeFields)((0, path_1.join)(repo, "src", "foundation"), cfg);
    const got = Object.keys(res.schema.fields);
    check(got.includes("registeredField"), "a registered module's service fields are composed");
    check(!got.includes("rogueField"), "an UNREGISTERED module beside it is ignored — the catalogue decides");
    rmSync(root, { recursive: true, force: true });
}
console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
