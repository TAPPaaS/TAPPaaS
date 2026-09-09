"use strict";
// compose-fields.ts — the merged module-field schema (#567).
//
// module-fields.json listed every field any service could ever use, so adding a
// service meant editing a global file, and the file grew a definition for
// something only one provider understood. #567 moves each definition to where
// it is owned; this composes the pieces back into the single view 41 readers
// already expect, so the SOURCE moves without the consumers moving with it.
//
// Three tiers, from the shape of the data rather than an imposed taxonomy —
// of the 74 fields: 19 are owned by no service, 41 by exactly one, and 14 by
// two, where all 14 are the same cluster:vm + cluster:lxc pair (the fields
// common to both guest types):
//
//   schemas/module-fields.json          the 19 generic ones — provenance,
//                                       lifecycle, wiring; no provider needed
//   <module>/fields.json                shared by that module's services
//                                       (cluster/: the 14 guest fields)
//   <module>/services/<svc>/fields.json owned by exactly one service (41)
//
// A field defined in more than one tier is an ERROR, not a merge: two files
// claiming the same definition is the ambiguity this change exists to remove.
Object.defineProperty(exports, "__esModule", { value: true });
exports.composeFields = composeFields;
const fs_1 = require("fs");
const path_1 = require("path");
function readJson(p) {
    try {
        return JSON.parse((0, fs_1.readFileSync)(p, "utf8"));
    }
    catch {
        return null;
    }
}
// A tier file contributes `fields`; a service manifest also carries change
// semantics (class/apply/...), which are NOT part of the schema view and are
// left where they are. `changeNote` is in this set and `note` is NOT: since
// #567 a merged entry holds both, and `note` belongs to the DEFINITION.
const CHANGE_KEYS = new Set([
    "class", "apply", "liveKey", "setFlag", "hook", "composite",
    "normalize", "sideEffects", "changeNote", "inputs",
]);
function definitionOf(entry) {
    const out = {};
    for (const [k, v] of Object.entries(entry)) {
        if (!CHANGE_KEYS.has(k))
            out[k] = v;
    }
    // An entry carrying ONLY change semantics defines nothing — it is a manifest
    // entry for a field defined in another tier, which is the pre-#567 shape.
    return Object.keys(out).length > 0 ? out : null;
}
function composeFields(foundationDir, configDir = "/home/tappaas/config") {
    const findings = [];
    const origin = {};
    const fields = {};
    const base = readJson((0, path_1.join)(foundationDir, "schemas", "module-fields.json"));
    if (!base) {
        return {
            schema: {},
            origin,
            findings: [{ field: "-", detail: "schemas/module-fields.json is missing or unparseable" }],
        };
    }
    const add = (name, def, from) => {
        if (name in fields) {
            findings.push({
                field: name,
                detail: `defined in two places: ${origin[name]} and ${from} — one definition, one home`,
            });
            return;
        }
        fields[name] = def;
        origin[name] = from;
    };
    for (const [k, v] of Object.entries((base.fields ?? {}))) {
        add(k, v, "schemas/module-fields.json");
    }
    // Walk the REGISTERED MODULES, not the filesystem. site.json .repositories is
    // the canonical repo list (ADR-007) and each repo's module-catalog.json is the
    // canonical list of what is a module in it. A stray services/ directory is not
    // a module and an unregistered checkout is not a source of fields — neither
    // can leak into the schema every reader trusts.
    //
    // It also removes the guesswork a filesystem walk needs: no prune list, no
    // depth limit, no rule for telling a module directory from any other. Layout
    // stops mattering — foundation modules sit at src/foundation/<module>/ and
    // community ones at src/<author>/<group>/<module>/, and both are simply
    // dirname(moduleJson).
    const seen = new Set();
    const addFrom = (file) => {
        if (!(0, fs_1.existsSync)(file) || seen.has(file))
            return;
        seen.add(file);
        const doc = readJson(file);
        for (const [k, v] of Object.entries((doc?.fields ?? {}))) {
            const def = definitionOf(v);
            if (def)
                add(k, def, file);
        }
    };
    const scanRepo = (root, catalogRel) => {
        const cat = readJson((0, path_1.join)(root, catalogRel));
        if (!cat)
            return 0;
        const moduleJsons = [];
        const collect = (node) => {
            if (Array.isArray(node)) {
                node.forEach(collect);
            }
            else if (node && typeof node === "object") {
                const o = node;
                if (typeof o.moduleJson === "string")
                    moduleJsons.push(o.moduleJson);
                Object.values(o).forEach(collect);
            }
        };
        collect(cat);
        for (const mj of moduleJsons.sort()) {
            const dir = (0, path_1.join)(root, mj.slice(0, mj.lastIndexOf("/")));
            addFrom((0, path_1.join)(dir, "fields.json"));
            const svcDir = (0, path_1.join)(dir, "services");
            let svcs = [];
            try {
                svcs = (0, fs_1.readdirSync)(svcDir);
            }
            catch {
                continue;
            }
            for (const sname of svcs.sort())
                addFrom((0, path_1.join)(svcDir, sname, "fields.json"));
        }
        return moduleJsons.length;
    };
    const site = readJson((0, path_1.join)(configDir, "site.json"));
    let scanned = 0;
    for (const r of (site?.repositories ?? [])) {
        const rpath = typeof r.path === "string" ? r.path : "";
        const rcat = typeof r.catalog === "string" ? r.catalog : "src/module-catalog.json";
        if (rpath)
            scanned += scanRepo(rpath, rcat);
    }
    // Bootstrap / bare checkout: no site.json yet, or it lists no usable repo.
    // Fall back to the catalogue of the tree this composer ships in.
    if (scanned === 0)
        scanRepo((0, path_1.join)(foundationDir, "..", ".."), "src/module-catalog.json");
    const schema = { ...base, fields };
    return { schema, origin, findings };
}
