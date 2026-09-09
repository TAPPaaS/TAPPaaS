"use strict";
// manifest.test.ts — offline unit tests for the ADR-020 service field manifest
// (P0: the vocabulary, the document lint, and the `validate` coverage check).
//
// Three things are asserted here, in increasing scope:
//
//   1. The VOCABULARY has one home. schemas/service-fields.json and
//      lib/ts/src/service-fields.ts both name the change classes, apply modes,
//      normalizers and side effects — one for humans and editors, one for the
//      code. A test that they are identical is what makes "one taxonomy" true
//      rather than a comment; without it the schema quietly documents a class
//      the lint would reject.
//   2. The REAL cluster:vm manifest lints clean against the REAL
//      module-fields.json. That is the P0 exit criterion: the reference
//      manifest classifies every field the schema says cluster:vm owns.
//   3. Each lint rule REFUSES the thing it exists to refuse — one mutation per
//      rule, asserted to produce that rule's finding and no other.
//
// No cluster, no bash, no config tree: the two JSON documents are read straight
// from the repo, everything else is built inline.
Object.defineProperty(exports, "__esModule", { value: true });
const fs_1 = require("fs");
const path_1 = require("path");
const compose_fields_1 = require("../../../../lib/ts/src/compose-fields");
const service_fields_1 = require("../../../../lib/ts/src/service-fields");
const validate_1 = require("../../src/validate");
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
// The compiled tests live at dist-test/manager/module-manager/test/unit/, so
// five ".." reach module-manager/ — the same hop module.test.ts makes for its
// fixtures. From there, up to src/foundation/ for the two real documents.
const MODULE_MANAGER = (0, path_1.join)(__dirname, "..", "..", "..", "..", "..");
const FOUNDATION = (0, path_1.join)(MODULE_MANAGER, "..", "..", "..");
// COMPOSED, not the raw file. Since #567 schemas/module-fields.json holds only
// the 19 fields no service owns; linting a service manifest against it would
// report every field it classifies as undeclared. The runtime composes too —
// this is the same view module-manager sees.
const COMPOSED = (0, compose_fields_1.composeFields)(FOUNDATION).schema;
const MANIFEST_SCHEMA_FILE = (0, path_1.join)(FOUNDATION, "schemas", "service-fields.json");
const VM_MANIFEST_FILE = (0, path_1.join)(FOUNDATION, "cluster", "services", "vm", "fields.json");
const MODULE_MANIFEST_FILE = (0, path_1.join)(FOUNDATION, "schemas", "fields.json");
function readJson(path) {
    return JSON.parse((0, fs_1.readFileSync)(path, "utf8"));
}
// ── 1. the vocabulary has ONE home ─────────────────────────────────────
{
    const doc = readJson(MANIFEST_SCHEMA_FILE);
    const defs = doc.$defs;
    const same = (a, b) => Array.isArray(b) && a.length === b.length && [...a].sort().join(",") === [...b].sort().join(",");
    check(same(service_fields_1.CHANGE_CLASS_NAMES, defs.changeClass?.enum), "service-fields.json and service-fields.ts declare the SAME change classes");
    check(same(service_fields_1.APPLY_MODES, defs.applyMode?.enum), "service-fields.json and service-fields.ts declare the SAME apply modes");
    check(same(service_fields_1.NORMALIZERS, defs.normalizer?.enum), "service-fields.json and service-fields.ts declare the SAME normalizers");
    check(same(service_fields_1.SIDE_EFFECTS, defs.sideEffect?.enum), "service-fields.json and service-fields.ts declare the SAME side effects");
    // The ADR names exactly seven classes (D3). Pin the count so adding an
    // eighth is a deliberate act that updates the ADR, not a drive-by.
    check(service_fields_1.CHANGE_CLASS_NAMES.length === 7, "the taxonomy has the seven classes ADR-020 D3 defines");
    // Only immutable and recreate are statically pre-gated (Resolved Question 4):
    // every other refusal needs live state, so it must happen in the converge.
    const preGated = service_fields_1.CHANGE_CLASS_NAMES.filter((c) => service_fields_1.CHANGE_CLASSES[c].preGate).sort();
    check(preGated.join(",") === "immutable,recreate", "only immutable and recreate are pre-gated — every other refusal needs live state");
    const disruptive = service_fields_1.CHANGE_CLASS_NAMES.filter((c) => service_fields_1.CHANGE_CLASSES[c].disruptive).sort();
    check(disruptive.join(",") === "in-place-reboot,migrate", "only in-place-reboot and migrate can require disruption authorization (D8)");
}
// ── 2. the REAL cluster:vm manifest, against the REAL schema ───────────
const schemaFields = (COMPOSED.fields ?? {});
const declaredFields = Object.keys(schemaFields);
{
    check(declaredFields.length > 0, "module-fields.json declares fields (the lint has something to check)");
    check(Object.prototype.hasOwnProperty.call(schemaFields, "rebootOk"), "module-fields.json declares rebootOk — the per-module disruption authorization (D8)");
    const findings = [];
    const manifest = (0, service_fields_1.parseServiceFieldManifest)(readJson(VM_MANIFEST_FILE), findings);
    check(manifest !== null, "the cluster:vm manifest parses");
    if (manifest) {
        (0, service_fields_1.lintServiceFieldManifest)(manifest, {
            coordinate: "cluster:vm",
            ownedFields: (0, service_fields_1.ownedFieldsFor)("cluster:vm", schemaFields),
            declaredFields,
        }, findings);
    }
    check(findings.length === 0, `the cluster:vm reference manifest lints clean${findings.length ? " — " + findings.map((f) => f.message).join(" | ") : ""}`);
    // The coverage claim, stated positively as well as by absence of findings.
    const owned = (0, service_fields_1.ownedFieldsFor)("cluster:vm", schemaFields);
    check(owned.length > 20, `module-fields.json says cluster:vm owns ${owned.length} fields`);
    check(manifest !== null && owned.every((f) => manifest.fields[f] !== undefined), "every field cluster:vm owns has a change class");
    // Ownership is by usedBy, not by "everything": a proxy field must NOT be in
    // the vm manifest, or coverage would be meaningless.
    check(manifest !== null && manifest.fields.proxyPort === undefined, "a field cluster:vm does not own is absent from its manifest");
    // The schema-vs-converge default agreements ADR-020 D1 requires to be STATED.
    // Each of these was a live disagreement between module-fields.json and
    // cluster:vm/update-service.sh before P1; the assertions pin the resolution so
    // a future schema edit cannot quietly reintroduce one.
    //
    // bridge1: the schema said 'lan' while BOTH acting paths (Create-TAPPaaS-VM.sh
    // and update-service.sh) read an absent bridge1 as 'NONE' — no second NIC. The
    // drift report therefore showed a desired NIC nothing would ever create.
    check(schemaFields.bridge1.default === "NONE", "bridge1's schema default is the 'NONE' sentinel both acting paths already used");
    // The four `__none__` sentinels this manifest was ported from are all gone
    // (ADR-020 D9). Each was removed only after the question was actually asked of
    // it — does the schema default differ from what install applies? — and for all
    // four the answer was no: TAPPaaS's own creators build with exactly the schema
    // default, so an undeclared guest is in sync from install and there was nothing
    // for an opt-out to protect.
    //
    //   vmtag     "TAPPaaS" is what both create paths apply.
    //   diskSize  8G likewise; the real hazard was config falling BEHIND a later
    //             grow, which is now an adoption rather than a permanent refusal.
    //   storage   "tanka1" likewise; nothing in TAPPaaS moves a disk, so
    //             suppressing the manual-class report was the opposite of correct.
    //   bios      "ovmf" likewise; the residual case — a guest built elsewhere on
    //             seabios, declaring nothing — is closed by install-service.sh
    //             recording the observed firmware at install.
    //
    // The whole vocabulary is gone with them, so the assertion is now structural:
    // no manifest may reintroduce the key.
    const reintroduced = manifest
        ? Object.keys(manifest.fields).filter((f) => Object.prototype.hasOwnProperty.call(manifest.fields[f], "defaultIsDesired"))
        : [];
    check(reintroduced.length === 0, `no field carries defaultIsDesired — the flag is retired (found: ${reintroduced.join(",") || "none"})`);
}
// ── 3. one mutation per lint rule ──────────────────────────────────────
//
// The discipline ADR-019 set and ADR-020 carries over: strip one guarantee and
// exactly one assertion goes red. Each case below is a MINIMAL valid manifest
// with a single fault injected, asserted to produce a finding naming that fault.
const OWNED = ["cores", "memory"];
const DECLARED = ["cores", "memory", "node", "diskSize", "bridge0", "zone0", "proxyPort"];
function lint(doc, ownedFields = OWNED) {
    const findings = [];
    const m = (0, service_fields_1.parseServiceFieldManifest)(doc, findings);
    if (m) {
        (0, service_fields_1.lintServiceFieldManifest)(m, { coordinate: "cluster:vm", ownedFields, declaredFields: DECLARED }, findings);
    }
    return findings;
}
const says = (fs, needle) => fs.some((f) => f.message.includes(needle));
// Baseline: a minimal, complete, correct manifest lints clean. Every case below
// is this document with ONE thing changed, so a finding can only come from that.
const BASE = {
    service: "cluster:vm",
    fields: {
        cores: { class: "in-place", apply: "set", setFlag: "--cores", normalize: "integer" },
        memory: { class: "in-place", apply: "set", setFlag: "--memory", normalize: "integer" },
    },
};
{
    check(lint(BASE).length === 0, "a minimal complete manifest lints clean (the baseline)");
}
// Rule: coverage — a usedBy field with no entry is an ERROR (the P0 headline).
{
    const f = lint(BASE, ["cores", "memory", "node"]);
    check(f.length === 1 && says(f, "does not classify 1 field") && says(f, "node"), "coverage: a usedBy field with no manifest entry is an error, and is named");
}
// Rule: the class must be one the taxonomy defines.
{
    const f = lint({ ...BASE, fields: { ...BASE.fields, cores: { class: "sometimes" } } });
    check(f.length === 1 && says(f, "unknown change class 'sometimes'"), "vocabulary: a class the taxonomy does not define is an error");
}
// Rule: a class that never applies must not declare a way to apply it.
{
    const f = lint({
        ...BASE,
        fields: { ...BASE.fields, cores: { class: "immutable", apply: "hook", hook: "update-cores.sh" } },
    });
    check(f.length === 1 && says(f, "is never applied by the converge"), "coherence: an immutable field with an apply hook is an error");
}
// Rule: apply:"hook" without a hook script.
{
    const f = lint({ ...BASE, fields: { ...BASE.fields, cores: { class: "migrate", apply: "hook" } } });
    check(f.length === 1 && says(f, "requires a 'hook' script name"), "coherence: apply:'hook' with no hook script is an error");
}
// Rule: a manifest may only classify fields module-fields.json declares.
{
    const f = lint({
        ...BASE,
        fields: { ...BASE.fields, coress: { class: "in-place", apply: "set" } },
    });
    check(f.length === 1 && says(f, "not declared by any field tier"), "scope: a manifest entry naming an undeclared field is an error (a typo, not a field)");
}
// Rule: a composite's inputs must point back at it.
{
    const f = lint({
        service: "cluster:vm",
        fields: {
            cores: { class: "in-place", apply: "set" },
            memory: { class: "in-place", apply: "set" },
            bridge0: { class: "in-place", apply: "composite", composite: "net0" },
            zone0: { class: "in-place", apply: "set" },
        },
        composites: {
            net0: { class: "in-place", apply: "hook", hook: "update-net.sh", inputs: ["bridge0", "zone0"] },
        },
    });
    check(f.length === 1 && says(f, "does not point back at it"), "composite: an input that does not name its composite is an error");
}
// Rule: a composite's class is the ceiling of its inputs' classes.
{
    const f = lint({
        service: "cluster:vm",
        fields: {
            cores: { class: "in-place", apply: "set" },
            memory: { class: "in-place", apply: "set" },
            bridge0: { class: "in-place-reboot", apply: "composite", composite: "net0" },
            zone0: { class: "in-place", apply: "composite", composite: "net0" },
        },
        composites: {
            net0: { class: "in-place", apply: "hook", hook: "update-net.sh", inputs: ["bridge0", "zone0"] },
        },
    });
    check(f.length === 1 && says(f, "the most-escalated input class is 'in-place-reboot'"), "composite: a class below its worst input is an error (the ceiling rule)");
    check((0, service_fields_1.worstClass)(["in-place", "in-place-reboot", "grow-only"]) === "in-place-reboot", "worstClass picks the most-escalated class");
}
// Rule: side effects belong on the composite, not on an input.
{
    const f = lint({
        service: "cluster:vm",
        fields: {
            cores: { class: "in-place", apply: "set" },
            memory: { class: "in-place", apply: "set" },
            bridge0: {
                class: "in-place-reboot",
                apply: "composite",
                composite: "net0",
                sideEffects: ["reboot"],
            },
        },
        composites: {
            net0: { class: "in-place-reboot", apply: "hook", hook: "update-net.sh", inputs: ["bridge0"] },
        },
    });
    check(f.length === 1 && says(f, "side effects belong on composite"), "composite: an input declaring its own side effects is an error (one reboot, one home)");
}
// Rule: a reboot side effect on a class that declares no disruption.
{
    const f = lint({
        ...BASE,
        fields: { ...BASE.fields, cores: { class: "in-place", apply: "set", sideEffects: ["reboot"] } },
    });
    check(f.length === 1 && says(f, "declares no disruption, but lists the 'reboot' side effect"), "disruption: a reboot on a non-disruptive class is an error (D8 would never be consulted)");
}
// Rule: apply:"reconcile" — the service converges the field itself. Valid on an
// applicable class, meaningless on one that is never applied.
{
    const f = lint({
        ...BASE,
        fields: { ...BASE.fields, cores: { class: "in-place", apply: "reconcile" } },
    });
    check(f.length === 0, "apply:'reconcile' is valid on an applicable class");
    const g = lint({
        ...BASE,
        fields: { ...BASE.fields, cores: { class: "immutable", apply: "reconcile" } },
    });
    check(g.length === 1 && says(g, "is never applied by the converge"), "…but not on a class the converge never applies — one error, naming the remedy");
}
// needsActualState: does converging this manifest require reading the provider?
// Only a per-field apply does. This is what lets a policy service — a firewall
// rule set, a Caddy handler — carry a manifest without being asked for a
// report-service.sh that could only flatten its state and lose fidelity.
{
    const selfReconciling = (0, service_fields_1.parseServiceFieldManifest)({
        service: "network:rules",
        fields: {
            cores: { class: "in-place", apply: "reconcile" },
            memory: { class: "in-place", apply: "reconcile" },
        },
    }, []);
    check(!(0, service_fields_1.needsActualState)(selfReconciling), "an all-reconcile manifest needs no actual state");
    const withSet = (0, service_fields_1.parseServiceFieldManifest)({
        service: "cluster:vm",
        fields: {
            cores: { class: "in-place", apply: "set" },
            memory: { class: "in-place", apply: "reconcile" },
        },
    }, []);
    check((0, service_fields_1.needsActualState)(withSet), "one `set` field is enough to need a reporter");
    const nothingApplies = (0, service_fields_1.parseServiceFieldManifest)({ service: "cluster:vm", fields: { vmid: { class: "immutable", apply: "none" } } }, []);
    check(!(0, service_fields_1.needsActualState)(nothingApplies), "a manifest that applies nothing needs no reporter either");
}
// Rule: unknown normalizer / side effect.
{
    const f = lint({ ...BASE, fields: { ...BASE.fields, cores: { class: "in-place", normalize: "hex" } } });
    check(f.length === 1 && says(f, "unknown normalize 'hex'"), "vocabulary: an unknown normalizer is an error");
    const g = lint({
        ...BASE,
        fields: { ...BASE.fields, cores: { class: "migrate", apply: "hook", hook: "x.sh", sideEffects: ["email"] } },
    });
    check(g.length === 1 && says(g, "unknown side effect 'email'"), "vocabulary: an unknown side effect is an error");
}
// Rule: the manifest names the coordinate it lives under.
{
    const f = lint({ ...BASE, service: "cluster:lxc" });
    check(f.length === 1 && says(f, "declares service 'cluster:lxc' but lives under 'cluster:vm'"), "identity: a manifest whose service disagrees with its directory is an error");
}
// effectiveApply: the inference the manifests rely on to stay terse.
{
    check((0, service_fields_1.effectiveApply)({ class: "immutable" }) === "none", "an immutable field defaults to apply:'none'");
    check((0, service_fields_1.effectiveApply)({ class: "in-place" }) === "set", "an in-place field defaults to apply:'set'");
    check((0, service_fields_1.effectiveApply)({ class: "in-place", apply: "hook", hook: "x.sh" }) === "hook", "an explicit apply wins over the inference");
}
// ── 4. validate's use of it: skip the un-migrated, refuse the broken ───
//
// The rollout property that matters most in P0: 24 of the 25 services have no
// fields.json yet, and `validate` must stay usable for the whole transition.
{
    const mkFs = (files) => ({
        providerDir: (provider) => ({ module: provider, dir: `/src/${provider}` }),
        exists: (p) => p in files,
        readFile: (p) => files[p] ?? null,
    });
    const run = (fs, deps = ["cluster:vm"]) => {
        const out = [];
        (0, validate_1.validateFieldManifests)({ name: "app", dependsOn: deps }, fs, { cores: { usedBy: ["cluster:vm"] }, memory: { usedBy: ["cluster:vm"] } }, out);
        return out;
    };
    const VM = "/src/cluster/services/vm/fields.json";
    // P5 changed this: silence is correct only where there is nothing to declare.
    check(run(mkFs({}), ["cluster:vm"]).length === 1 &&
        run(mkFs({}), ["cluster:vm"])[0].message.includes("ships no"), "a service that OWNS fields but ships no manifest is an error (ADR-020 P5's exit criterion)");
    check(run(mkFs({ [VM]: JSON.stringify(BASE) })).length === 0, "a complete fields.json produces no finding");
    // A service that owns NO declared field needs no manifest, and none is
    // expected: 14 of the 25 services do registration and wiring, which is not
    // field drift. Reported as a gap it would be pure noise.
    {
        const out = [];
        (0, validate_1.validateFieldManifests)({ name: "app", dependsOn: ["cluster:vm"] }, mkFs({}), { proxyPort: { usedBy: ["network:proxy"] } }, out);
        check(out.length === 0, "a service that owns nothing needs no manifest and is not reported");
    }
    {
        const f = run(mkFs({ [VM]: "{ not json" }));
        check(f.length === 1 && f[0].severity === "error" && f[0].message.includes("not valid JSON"), "a malformed fields.json is an error, not a silent skip");
    }
    {
        const f = run(mkFs({ [VM]: JSON.stringify({ service: "cluster:vm", fields: { cores: { class: "in-place" } } }) }));
        check(f.length === 1 && f[0].severity === "error" && f[0].message.includes("memory"), "an incomplete fields.json errors and names the unclassified field");
        check(f[0].message.startsWith("cluster:vm field manifest ("), "the finding names the coordinate and the file, so the fix is one file away");
    }
    // Two dependencies on the SAME provider service must not report the fault
    // twice — a manifest is a property of the provider, checked once.
    {
        const f = run(mkFs({ [VM]: "{ not json" }), ["cluster:vm", "cluster:vm"]);
        check(f.length === 1, "the same coordinate is linted once per module, not once per declaration");
    }
}
// ── 5. every field-owning service in the TREE ships a clean manifest ───
//
// ADR-020 P5's exit criterion, asserted against the repository rather than a
// fixture: if module-fields.json says a coordinate owns a field, that service
// must classify it. A service owning nothing needs no manifest — 14 of the 25
// do registration and wiring, which is not field drift — so absence is only a
// fault where ownership exists.
{
    // Every services/<svc>/update-service.sh under foundation/ and apps/ — the
    // definition of "a provider service" the contract test already uses.
    const services = [];
    const walk = (dir, depth) => {
        if (depth > 6)
            return;
        let entries;
        try {
            entries = (0, fs_1.readdirSync)(dir);
        }
        catch {
            return;
        }
        for (const e of entries) {
            if (e === "node_modules" || e === ".git" || e.includes("fixture"))
                continue;
            const p = (0, path_1.join)(dir, e);
            let isDir = false;
            try {
                isDir = (0, fs_1.statSync)(p).isDirectory();
            }
            catch {
                continue;
            }
            if (isDir)
                walk(p, depth + 1);
            else if (e === "update-service.sh")
                services.push(p);
        }
    };
    walk(FOUNDATION, 0);
    walk((0, path_1.join)(FOUNDATION, "..", "apps"), 0);
    const missing = [];
    const broken = [];
    for (const script of services) {
        const dir = (0, path_1.dirname)(script);
        const coordinate = `${(0, path_1.basename)((0, path_1.dirname)((0, path_1.dirname)(dir)))}:${(0, path_1.basename)(dir)}`;
        const owned = (0, service_fields_1.ownedFieldsFor)(coordinate, schemaFields);
        const manifestPath = (0, path_1.join)(dir, "fields.json");
        if (!(0, fs_1.existsSync)(manifestPath)) {
            if (owned.length > 0)
                missing.push(`${coordinate} (owns ${owned.join(", ")})`);
            continue;
        }
        const f = [];
        const m = (0, service_fields_1.parseServiceFieldManifest)(JSON.parse((0, fs_1.readFileSync)(manifestPath, "utf8")), f);
        if (m)
            (0, service_fields_1.lintServiceFieldManifest)(m, { coordinate, ownedFields: owned, declaredFields }, f);
        if (f.length > 0)
            broken.push(`${coordinate}: ${f.map((x) => x.message).join("; ")}`);
    }
    check(missing.length === 0, `every service that owns declared fields ships a manifest${missing.length ? " — missing: " + missing.join(" | ") : ""}`);
    check(broken.length === 0, `every manifest in the tree lints clean${broken.length ? " — " + broken.join(" | ") : ""}`);
}
// ── 4. the MODULE-LEVEL manifest (schemas/fields.json) ─────────────────
//
// The 19 fields no provider service owns. This manifest is declaration only —
// nothing consumes it at runtime yet (#567) — which is exactly why it needs a
// test: an unread document rots silently, and the whole point of writing it
// down was to stop these fields being the undeclared corner of the schema.
{
    const doc = readJson(MODULE_MANIFEST_FILE);
    const schema = COMPOSED;
    const schemaFields = schema.fields;
    const entries = doc.fields;
    check(doc.scope === "module", "schemas/fields.json is scoped 'module' (it has no service coordinate)");
    check(doc.service === undefined, "schemas/fields.json declares no 'service' — scope and service are exclusive");
    // COVERAGE, both ways. The set it must cover is derivable from
    // module-fields.json alone: a field whose usedBy names no service.
    const unowned = Object.keys(schemaFields)
        .filter((f) => {
        const u = schemaFields[f].usedBy;
        return !Array.isArray(u) || u.length === 0 || (u.length === 1 && u[0] === "general");
    })
        .sort();
    const declared = Object.keys(entries).sort();
    const missing = unowned.filter((f) => !declared.includes(f));
    const extra = declared.filter((f) => !unowned.includes(f));
    check(missing.length === 0, `every module-level field is classified (missing: ${missing.join(", ") || "none"})`);
    check(extra.length === 0, `no entry classifies a SERVICE-owned field (extra: ${extra.join(", ") || "none"})`);
    // Same vocabulary as the service manifests — the point of one taxonomy.
    const badClass = declared.filter((f) => !(String(entries[f].class) in service_fields_1.CHANGE_CLASSES));
    check(badClass.length === 0, `every class is in the shared taxonomy (bad: ${badClass.join(", ") || "none"})`);
    // A module-level field has no provider, so it can have no reporter and
    // nothing to apply. These two assertions stop the file drifting into
    // claiming a liveKey or a set-flag that could never exist.
    const notNone = declared.filter((f) => entries[f].apply !== "none");
    check(notNone.length === 0, `apply is 'none' for every module-level field (offenders: ${notNone.join(", ") || "none"})`);
    const withLiveKey = declared.filter((f) => entries[f].liveKey !== undefined);
    check(withLiveKey.length === 0, `no module-level field claims a liveKey (offenders: ${withLiveKey.join(", ") || "none"})`);
    // Rationale is the reason this document is worth having at all.
    const noNote = declared.filter((f) => typeof entries[f].changeNote !== "string" || !entries[f].changeNote);
    check(noNote.length === 0, `every module-level field carries a rationale (missing: ${noNote.join(", ") || "none"})`);
}
console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
