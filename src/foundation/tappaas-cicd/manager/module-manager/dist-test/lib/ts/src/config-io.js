"use strict";
// config-io.ts — shared config-root resolution + JSON file I/O for the
// TAPPaaS TypeScript managers (ADR-007 post-implementation refactor, Phase 3).
Object.defineProperty(exports, "__esModule", { value: true });
exports.defaultConfigDir = defaultConfigDir;
exports.asString = asString;
exports.asStringArray = asStringArray;
exports.readJsonObject = readJsonObject;
exports.writeJsonAtomic = writeJsonAtomic;
const fs_1 = require("fs");
const path_1 = require("path");
// The ONE canonical config-root rule (documented in tappaas-cicd/README.md,
// "Config root resolution"): TAPPAAS_CONFIG (the TAPPaaS-specific override)
// wins, then CONFIG_DIR (the long-standing bash-layer variable), then the
// standard target path. Never re-implement this with a different precedence.
function defaultConfigDir() {
    return process.env.TAPPAAS_CONFIG ?? process.env.CONFIG_DIR ?? "/home/tappaas/config";
}
function asString(v) {
    return typeof v === "string" ? v : "";
}
function asStringArray(v) {
    if (!Array.isArray(v))
        return [];
    return v.filter((x) => typeof x === "string");
}
// Read + parse a JSON object file. An ABSENT file returns null (callers treat
// a missing layer/file as legitimately empty); a PRESENT but unparseable or
// non-object file THROWS naming the file — silent defaulting corrupts state
// invisibly (the F4 policy: parse errors are reported, commands die cleanly).
function readJsonObject(file) {
    if (!(0, fs_1.existsSync)(file))
        return null;
    let v;
    try {
        v = JSON.parse((0, fs_1.readFileSync)(file, "utf8"));
    }
    catch (e) {
        throw new Error(`malformed JSON in ${file}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (v === null || typeof v !== "object" || Array.isArray(v)) {
        throw new Error(`malformed config in ${file}: expected a JSON object`);
    }
    return v;
}
// Atomically write a JSON document: write into a fresh temp dir NEXT TO the
// target (same filesystem, so rename is atomic), rename over the target, and
// remove the now-empty temp dir (the old per-manager copies leaked it).
function writeJsonAtomic(file, doc) {
    const dir = (0, path_1.dirname)(file);
    const tmpDir = (0, fs_1.mkdtempSync)((0, path_1.join)(dir, ".tmp-"));
    const tmp = (0, path_1.join)(tmpDir, "out.json");
    (0, fs_1.writeFileSync)(tmp, JSON.stringify(doc, null, 2) + "\n", "utf8");
    (0, fs_1.renameSync)(tmp, file);
    (0, fs_1.rmdirSync)(tmpDir);
}
