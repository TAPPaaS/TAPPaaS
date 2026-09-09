"use strict";
// module.test.ts — offline unit tests for the module-manager.
//
// No cluster, no bash scripts: a FakeModuleClient records the lifecycle
// invocations, and the CONFIG-layer verbs (list/show/validate) read a fixture
// config tree. Tiny assert harness (no test framework). Run via the test/unit
// tsconfig (see test.sh).
Object.defineProperty(exports, "__esModule", { value: true });
const fs_1 = require("fs");
const os_1 = require("os");
const path_1 = require("path");
const config_1 = require("../../src/config");
const validate_1 = require("../../src/validate");
const fake_client_1 = require("./fake-client");
const main_1 = require("../../src/main");
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
// Fixtures live in the SOURCE tree (not copied into dist-test). The test
// tsconfig extends lib/ts/tsconfig.base.json (rootDir = tappaas-cicd/), so the
// compiled location is dist-test/manager/module-manager/test/unit/ — five ".."
// resolve back to module-manager/, then test/fixtures/config. test.sh may
// override via MM_FIXTURES_CONFIG.
const CONFIG = process.env.MM_FIXTURES_CONFIG ??
    (0, path_1.join)(__dirname, "..", "..", "..", "..", "..", "test", "fixtures", "config");
// ── 1. listModules enumerates ONLY module configs (filters state files) ──
{
    const mods = (0, config_1.listModules)(CONFIG);
    const names = mods.map((m) => m.name);
    check(names.includes("nextcloud") && names.includes("identity") && names.includes("legacyapp"), "list includes deployed module configs");
    check(!names.includes("zones"), "list EXCLUDES zones.json (non-module state file)");
    check(!names.includes("site"), "list EXCLUDES site.json (non-module state file)");
    check(names[0] <= names[names.length - 1] && JSON.stringify(names) === JSON.stringify([...names].sort()), "list is sorted by name");
    // Provider-only module: `templates` has NO vmid/vmname but IS a module — it
    // must be enumerated (selected by its provides/location), not filtered out.
    const templates = mods.find((m) => m.name === "templates");
    check(templates !== undefined, "list INCLUDES provider-only module 'templates' (no vmid/vmname)");
    check(templates !== undefined && templates.vmid == null && templates.provides.includes("nixos"), "vmid-less module is kept with vmid=null and its provides[]");
    // The kind=="module" tag is the authoritative selector (nextcloud carries it).
    check(mods.find((m) => m.name === "nextcloud")?.kind === "module", "kind=module tag is read");
}
// ── 2. loadModule returns the parsed config; missing → null ─────────────
{
    const nc = (0, config_1.loadModule)(CONFIG, "nextcloud");
    check(nc !== null && nc.vmid === 340 && nc.zone0 === "srvWork", "show/load reads vmid + zone0");
    check(nc !== null && nc.provides.includes("fileservice"), "show/load reads provides[]");
    check((0, config_1.loadModule)(CONFIG, "does-not-exist") === null, "load of a missing module → null");
}
// ── 3. validate: foundation+official passes, foundation+community fails ──
{
    const all = (0, config_1.listModules)(CONFIG);
    const report = (0, validate_1.validateModules)(all, {});
    // badfork = foundation + community → error
    check(report.findings.some((f) => f.module === "badfork" && f.severity === "error" && /requires source:official/.test(f.message)), "foundation+community is a lint ERROR");
    check(report.errors >= 1, "validate reports at least one error (badfork)");
    // identity = foundation + official → no error
    check(!report.findings.some((f) => f.module === "identity" && f.severity === "error"), "foundation+official passes (no error)");
    // legacyapp = no tier → warning, no error
    check(report.findings.some((f) => f.module === "legacyapp" && f.severity === "warning" && /defaulting to 'app'/.test(f.message)), "tier-less legacy app WARNS (defaults to app)");
}
// ── 4. validate --allow-fork downgrades the foundation-fork error → warn ─
{
    const all = (0, config_1.listModules)(CONFIG);
    const report = (0, validate_1.validateModules)(all, { allowFork: true });
    check(!report.findings.some((f) => f.module === "badfork" && f.severity === "error"), "--allow-fork removes the foundation-fork error");
    check(report.findings.some((f) => f.module === "badfork" && f.severity === "warning"), "--allow-fork turns the foundation fork into a warning");
}
// ── 4b. validate: status value is checked against MODULE_STATUS_VALUES (#556)
{
    const mk = (status) => ({ name: "s", tier: "app", source: "official", status });
    const rep = (status) => (0, validate_1.validateModules)([mk(status)], {});
    // A permitted value (archived) produces no status finding.
    check(!rep("archived").findings.some((f) => /unknown status/.test(f.message)), "known status 'archived' is not flagged");
    // A value outside the set WARNS (not an error — status is descriptive metadata).
    const bad = rep("Archived"); // wrong casing → unknown
    check(bad.findings.some((f) => f.severity === "warning" && /unknown status 'Archived'/.test(f.message)), "unknown status value WARNS");
    check(bad.errors === 0, "unknown status is a warning, never an error");
}
// ── 5. effective-name resolution (env suffix rules) ─────────────────────
{
    // fixture site.json.name = 'acme' → default env is 'acme'.
    check((0, config_1.resolveDefaultEnvironment)(CONFIG) === "acme", "default environment = site.json.name");
    check((0, config_1.resolveEffectiveModuleName)(CONFIG, "myapp", undefined) === "myapp", "no env → plain name");
    check((0, config_1.resolveEffectiveModuleName)(CONFIG, "myapp", "mgmt") === "myapp", "mgmt env → no suffix");
    check((0, config_1.resolveEffectiveModuleName)(CONFIG, "myapp", "acme") === "myapp", "default env → no suffix");
    check((0, config_1.resolveEffectiveModuleName)(CONFIG, "myapp", "dev") === "myapp-dev", "non-default env → <module>-<env>");
}
// ── 6. add forwards flags to install-module via the client ──────────────
{
    const c = new fake_client_1.FakeModuleClient();
    const rc = (0, main_1.run)(["module", "add", "nextcloud", "--environment", "dev", "--allow-fork", "--node", "tappaas2"], c);
    check(rc === 0, "add returns the client rc (0)");
    check(c.log.length === 1 && c.log[0].verb === "add" && c.log[0].module === "nextcloud", "add invoked once for nextcloud");
    const a = c.log[0].opts;
    check(a.environment === "dev" && a.allowFork === true, "add forwards --environment + --allow-fork");
    check(a.passthrough.join(" ") === "--node tappaas2", "add captures unknown --field/value as passthrough to copy-update-json");
}
// ── 7. delete maps --remove/--force/--yes; mutual-exclusion guard ───────
{
    const c = new fake_client_1.FakeModuleClient();
    (0, main_1.run)(["module", "delete", "nextcloud", "--remove", "--yes"], c);
    const d = c.log[0].opts;
    check(d.mode === "remove" && d.yes === true, "delete maps --remove + --yes");
    const c2 = new fake_client_1.FakeModuleClient();
    const rc = (0, main_1.run)(["module", "delete", "nextcloud", "--archive", "--remove"], c2);
    check(rc === 1 && c2.log.length === 0, "delete --archive + --remove is rejected (no invocation)");
}
// ── 8. reconcile: DEFAULT = read-only inspect; --apply = leaf converge ──────
{
    // DEFAULT (no --apply) is the read-only three-way drift inspect (src/inspect.ts).
    const ci = new fake_client_1.FakeModuleClient();
    (0, main_1.run)(["module", "reconcile", "nextcloud"], ci);
    check(ci.log.length === 1 && ci.log[0].verb === "inspect" && ci.log[0].module === "nextcloud", "reconcile (no --apply) runs the read-only inspect (NOT reconcile-module)");
    // --apply delegates to the native reconcile (its OWN leaf converge, NOT modify).
    const c = new fake_client_1.FakeModuleClient();
    (0, main_1.run)(["module", "reconcile", "nextcloud", "--apply", "--environment", "foo"], c);
    check(c.log.length === 1 && c.log[0].verb === "reconcile", "reconcile --apply delegates to reconcile-module (NOT update/modify)");
    check(c.log[0].opts.environment === "foo", "reconcile --apply forwards --environment");
}
// ── 8b. list --diff runs the per-module inspect rollup ──────────────────────
{
    const c = new fake_client_1.FakeModuleClient();
    const rc = (0, main_1.run)(["module", "list", "--diff", "--config-dir", CONFIG], c);
    check(rc === 0, "list --diff returns 0 when every module inspect passes");
    check(c.log.length > 0 && c.log.every((l) => l.verb === "inspect"), "list --diff runs an inspect per deployed module");
    const modsInDiff = c.log.map((l) => l.module);
    check(modsInDiff.includes("nextcloud") && modsInDiff.includes("templates"), "list --diff covers VM and provider-only modules alike");
}
// ── 9. snapshot-vm sub-actions map to the right flag ────────────────────
{
    const c = new fake_client_1.FakeModuleClient();
    (0, main_1.run)(["module", "snapshot-vm", "nextcloud", "--cleanup", "3"], c);
    check(c.log[0].verb === "snapshot", "snapshot-vm delegates to the snapshot client");
    const act = c.log[0].opts;
    check(act.kind === "cleanup" && act.keep === 3, "snapshot-vm --cleanup 3 → cleanup action keep=3");
    const c2 = new fake_client_1.FakeModuleClient();
    (0, main_1.run)(["module", "snapshot-vm", "nextcloud"], c2);
    check(c2.log[0].opts.kind === "create", "bare snapshot-vm → create action");
}
// ── 10. the leading `module` entity keyword is optional ─────────────────
{
    const c = new fake_client_1.FakeModuleClient();
    const rc = (0, main_1.run)(["test", "nextcloud", "--deep"], c); // no `module` prefix
    check(rc === 0 && c.log[0].verb === "test", "verbs work without the `module` entity keyword");
    check(c.log[0].opts.deep === true, "test forwards --deep");
}
// ── 11. a client failure rc propagates as the process exit code ─────────
{
    const c = new fake_client_1.FakeModuleClient();
    c.rc = 2; // simulate install-module.sh failing
    const rc = (0, main_1.run)(["module", "add", "nextcloud"], c);
    check(rc === 2, "a non-zero script rc propagates back out of run()");
}
// ── 12. list --json emits a machine-readable summary the cascade parses ─
{
    // Capture stdout for the duration of the call.
    const real = console.log;
    let captured = "";
    console.log = (...a) => {
        captured += a.map(String).join(" ") + "\n";
    };
    let rc;
    try {
        rc = (0, main_1.run)(["module", "list", "--json", "--config-dir", CONFIG], new fake_client_1.FakeModuleClient());
    }
    finally {
        console.log = real;
    }
    check(rc === 0, "list --json returns 0");
    let parsed = [];
    let ok = true;
    try {
        parsed = JSON.parse(captured);
    }
    catch {
        ok = false;
    }
    check(ok && Array.isArray(parsed), "list --json output is a JSON array");
    check(parsed.some((m) => m.name === "nextcloud" && m.vmid === 340), "list --json carries name + vmid per module");
    check(parsed.some((m) => m.name === "templates" && m.vmid === null), "list --json includes vmid-less provider modules (vmid:null)");
}
// ── 13. default list folds LIVE running-vs-config state (superset view) ──
// The default `list` merges config with the live cluster: columns
// NAME ENV ZONE NODE VMID "RUN STATE" "DEV STATUS", the ACTUAL node for running
// guests, running TEMPLATES folded into the table with RUN STATE "template",
// genuine orphans in an "Unexpected VMs" note, and a graceful config-only
// fallback when the cluster is unreachable.
function captureList(client, extraArgs = []) {
    const real = console.log;
    let out = "";
    console.log = (...a) => {
        out += a.map(String).join(" ") + "\n";
    };
    try {
        (0, main_1.run)(["module", "list", "--config-dir", CONFIG, ...extraArgs], client);
    }
    finally {
        console.log = real;
    }
    return out;
}
{
    // Live cluster: nextcloud(340) running on tappaas2 (migrated from config
    // tappaas1), identity(140) running, a running TEMPLATE (8080), plus a genuine
    // ORPHAN guest 999 in no config.
    const c = new fake_client_1.FakeModuleClient();
    c.guests = [
        { vmid: 340, name: "nextcloud", node: "tappaas2", status: "running", type: "qemu" },
        { vmid: 140, name: "identity", node: "tappaas1", status: "running", type: "qemu" },
        { vmid: 8080, name: "tappaas-nixos", node: "tappaas1", status: "stopped", type: "qemu", template: true },
        { vmid: 999, name: "mystery", node: "tappaas3", status: "running", type: "qemu" },
    ];
    const out = captureList(c);
    check(/RUN STATE/.test(out) && /DEV STATUS/.test(out), "default list has RUN STATE + DEV STATUS columns");
    // Column order NAME ENV ZONE NODE VMID RUN STATE: node tappaas2 then vmid 340 then running.
    check(/nextcloud(\s+\S+){2}\s+tappaas2\s+340\s+running/.test(out), "running guest shows live status + ACTUAL node (tappaas2, not config tappaas1)");
    // legacyapp(250) has a vmid but is NOT in the live set → configured-but-not-running.
    check(/legacyapp[\s\S]*not running/.test(out) || /not running[\s\S]*250/.test(out), "a configured VM absent from the live set is noted as not running");
    // templates has no vmid → VMID + RUN STATE "-".
    check(/templates(\s+\S+){2}\s+-\s+-\s+-/.test(out), "vmid-less module shows VMID + RUN STATE '-'");
    // Running template folds INTO the table with RUN STATE "template" (not an orphan note).
    check(/tappaas-nixos(\s+\S+){2}\s+tappaas1\s+8080\s+template/.test(out), "running template folded into table as 'template'");
    // Genuine (non-template) orphan → Unexpected VMs note.
    check(/Unexpected VMs/.test(out) && /999\s+mystery\s+tappaas3/.test(out), "genuine orphan listed under Unexpected VMs");
}
{
    // Cluster unreachable (guests = []): config-only fallback, RUN STATE '-', warn.
    const c = new fake_client_1.FakeModuleClient(); // guests defaults to []
    const out = captureList(c);
    check(/live cluster query unavailable/.test(out), "unreachable cluster → single graceful-degrade warning");
    check(/nextcloud(\s+\S+){2}\s+\S+\s+340/.test(out), "config-only fallback still lists modules");
    check(!/Unexpected VMs/.test(out), "no orphan section when there is no live data");
}
// ── Module resolution: the three tracking paths (#459, #460) ────────────
// Self-contained temp tree so the shared fixtures stay untouched.
{
    const tmp = (0, fs_1.mkdtempSync)((0, path_1.join)((0, os_1.tmpdir)(), "mm-resolution-"));
    const cfg = (0, path_1.join)(tmp, "config");
    const legacyRepo = (0, path_1.join)(tmp, "legacyrepo");
    const elsewhere = (0, path_1.join)(tmp, "elsewhere", "thermostat");
    (0, fs_1.mkdirSync)(cfg, { recursive: true });
    (0, fs_1.mkdirSync)((0, path_1.join)(legacyRepo, "src", "apps", "catmod"), { recursive: true });
    (0, fs_1.mkdirSync)(elsewhere, { recursive: true });
    // A repository whose catalog carries the LEGACY name. `repository add`
    // records catalog="src/modules.json"; before #459 nothing read that back.
    (0, fs_1.writeFileSync)((0, path_1.join)(legacyRepo, "src", "modules.json"), JSON.stringify({
        applicationModules: [
            { moduleName: "catmod", moduleJson: "src/apps/catmod/catmod.json", tier: "app" },
        ],
    }));
    (0, fs_1.writeFileSync)((0, path_1.join)(legacyRepo, "src", "apps", "catmod", "catmod.json"), "{}");
    (0, fs_1.writeFileSync)((0, path_1.join)(cfg, "site.json"), JSON.stringify({
        repositories: [
            { name: "Legacy", url: "x", path: legacyRepo, managed: "full", catalog: "src/modules.json" },
        ],
    }));
    // One deployed config per tracking path.
    (0, fs_1.writeFileSync)((0, path_1.join)(cfg, "thermostat.json"), JSON.stringify({ kind: "module", tier: "app", location: elsewhere }));
    (0, fs_1.writeFileSync)((0, path_1.join)(cfg, "catmod.json"), JSON.stringify({ kind: "module", dependsOn: ["network:rules"] }));
    (0, fs_1.writeFileSync)((0, path_1.join)(cfg, "stale.json"), JSON.stringify({ kind: "module", tier: "app", location: "/gone/moved-away" }));
    (0, fs_1.writeFileSync)((0, path_1.join)(cfg, "shelly-fleet.json"), JSON.stringify({ kind: "module", installTime: "20260101-10:00:00", dependsOn: ["network:rules"] }));
    // getModuleDirResult keeps the three failures apart.
    check((0, config_1.getModuleDirResult)(cfg, "thermostat").kind === "found", "getModuleDirResult: existing .location → found");
    check((0, config_1.getModuleDirResult)(cfg, "shelly-fleet").kind === "no-location", "getModuleDirResult: no .location recorded → no-location");
    check((0, config_1.getModuleDirResult)(cfg, "nosuchmodule").kind === "not-installed", "getModuleDirResult: no deployed config → not-installed");
    const stale = (0, config_1.getModuleDirResult)(cfg, "stale");
    check(stale.kind === "missing-dir" && stale.dir === "/gone/moved-away", "getModuleDirResult: recorded directory gone → missing-dir, carrying the path");
    // The legacy string|null wrapper is unchanged for every existing caller.
    check((0, config_1.getModuleDir)(cfg, "stale") === "/gone/moved-away", "getModuleDir: still returns the recorded path when the directory is gone (back-compat)");
    check((0, config_1.getModuleDir)(cfg, "shelly-fleet") === null, "getModuleDir: still null with no .location");
    // repoCatalogFile precedence: declared > convention > legacy.
    check((0, config_1.repoCatalogFile)(legacyRepo, "src/modules.json") === (0, path_1.join)(legacyRepo, "src", "modules.json"), "repoCatalogFile: a declared catalog path is used");
    check((0, config_1.repoCatalogFile)(legacyRepo, "") === (0, path_1.join)(legacyRepo, "src", "modules.json"), "repoCatalogFile: falls back to the legacy name when the conventional one is absent");
    check((0, config_1.repoCatalogFile)(legacyRepo, "does/not/exist.json") === (0, path_1.join)(legacyRepo, "src", "modules.json"), "repoCatalogFile: a declared-but-absent catalog falls through, it does not dead-end");
    const hit = (0, config_1.resolveViaCatalog)(cfg, "catmod");
    check(hit !== null && hit.repo === "Legacy" && hit.tier === "app", "resolveViaCatalog: a legacy-named catalog resolves (#459)");
    check((0, config_1.resolveViaCatalog)(cfg, "shelly-fleet") === null, "resolveViaCatalog: absent module → null");
    // The four verdicts.
    check((0, config_1.classifyModuleResolution)(cfg, "thermostat").path === "location", "classify: .location outside any repo → location");
    check((0, config_1.classifyModuleResolution)(cfg, "catmod").path === "catalog", "classify: no .location but catalogued → catalog");
    check((0, config_1.classifyModuleResolution)(cfg, "stale").path === "broken-location", "classify: recorded directory gone → broken-location");
    check((0, config_1.classifyModuleResolution)(cfg, "shelly-fleet").path === "unresolvable", "classify: neither path → unresolvable");
    // Tier: the deployed config outranks the catalog, and is the ONLY source for
    // a module located via .location (#460).
    check((0, config_1.classifyModuleResolution)(cfg, "thermostat").tierSource === "config", "classify: tier comes from the deployed config when set");
    const catmodRes = (0, config_1.classifyModuleResolution)(cfg, "catmod");
    check(catmodRes.tier === "app" && catmodRes.tierSource === "catalog", "classify: tier falls back to the catalog when the config declares none");
    check((0, config_1.classifyModuleResolution)(cfg, "shelly-fleet").tier === null, "classify: an unresolvable module reports no tier rather than a wrong one");
    (0, fs_1.rmSync)(tmp, { recursive: true, force: true });
}
// ── source-ref derivability ─────────────────────────────────────────────
// .location records WHERE a module's source is, never WHICH REF it came from.
// A ref exists one level up, on site.json .repositories[].branch, so it is
// derivable only while .location resolves inside a declared repository. When it
// does not, an absent ref means two opposite things -- deliberately deployed
// from a branch, or left on a stale checkout -- and nothing tells them apart.
// Invisible in a single-environment estate where path and ref coincide.
{
    const REPOS = [
        { name: "TAPPaaS", path: "/home/tappaas/TAPPaaS", branch: "main" },
        { name: "Community", path: "/home/tappaas/Community", branch: "main" },
    ];
    const locFindings = (m) => {
        const out = [];
        (0, validate_1.validateSourceLocation)(m, REPOS, out);
        return out;
    };
    {
        const f = locFindings({ name: "in", raw: { location: "/home/tappaas/TAPPaaS/src/apps/x" } });
        check(f.length === 0, "source-ref: a location inside a declared repository produces no finding");
    }
    {
        const f = locFindings({ name: "out", raw: { location: "/home/tappaas/repos/other/src/apps/x" } });
        check(f.length === 1, "source-ref: a location outside every declared repository is reported");
        check(f[0].severity === "warning", "source-ref: it is a WARNING — the module still resolves and works");
        check(f[0].message.includes("/home/tappaas/repos/other/src/apps/x"), "source-ref: the finding names the offending path, not just the module");
    }
    {
        const f = locFindings({ name: "nocatalog", raw: {} });
        check(f.length === 0, "source-ref: a module with no .location is catalog-resolved, not a finding");
    }
    {
        const f = locFindings({ name: "exact", raw: { location: "/home/tappaas/TAPPaaS" } });
        check(f.length === 0, "source-ref: a location equal to the repository root is inside it");
    }
    {
        // The prefix trap: TAPPaaSX is not inside TAPPaaS.
        const f = locFindings({ name: "prefix", raw: { location: "/home/tappaas/TAPPaaSX/src/apps/x" } });
        check(f.length === 1, "source-ref: a sibling path sharing a prefix is NOT inside the repository");
    }
}
// ── dependsOn reference integrity (#495 follow-up) ──────────────────────
// reconcile/modify SKIP an unservable dependency at runtime, so validate is the
// only place a dangling declaration is reported. Fake ServiceFs — no real tree.
{
    const mkFs = (providers, files) => ({
        providerDir(provider, environment) {
            // Mirror the environment-aware resolution: <provider>-<env> wins if known.
            const scoped = environment ? `${provider}-${environment}` : "";
            const name = scoped && scoped in providers ? scoped : provider;
            return { module: name, dir: providers[name] ?? null };
        },
        exists: (p) => files.has(p),
        readFile: () => null,
    });
    const findings = (m, fs) => {
        const out = [];
        (0, validate_1.validateDependsOn)(m, fs, out);
        return out;
    };
    // 1. Fully satisfied dependency — no finding.
    {
        const fs = mkFs({ cluster: "/src/cluster" }, new Set(["/src/cluster/services/vm/update-service.sh"]));
        const f = findings({ name: "app", dependsOn: ["cluster:vm"] }, fs);
        check(f.length === 0, "validate: a satisfiable dependsOn produces no finding");
    }
    // 2. Provider deployed but ships no update-service.sh — the sonos/alfen case.
    {
        const fs = mkFs({ sonos: "/src/sonos" }, new Set());
        const f = findings({ name: "app", dependsOn: ["sonos:audio"] }, fs);
        check(f.length === 1 && f[0].severity === "error", "validate: provider with no update-service.sh is an error");
        check(f[0].message.includes("audio/update-service.sh") && f[0].message.includes("SKIP"), "validate: the finding names the missing script and says it is skipped silently");
    }
    // 3. Provider not deployed at all.
    {
        const fs = mkFs({}, new Set());
        const f = findings({ name: "app", dependsOn: ["ghost:thing"] }, fs);
        check(f.length === 1 && f[0].message.includes("not deployed"), "validate: undeployed provider is an error");
    }
    // 4. Malformed entry with no ':service'.
    {
        const fs = mkFs({ cluster: "/src/cluster" }, new Set());
        const f = findings({ name: "app", dependsOn: ["cluster"] }, fs);
        check(f.length === 1 && f[0].message.includes("no ':<service>'"), "validate: a bare provider with no service is an error");
    }
    // 5. Environment-aware resolution: a consumer in 'test' pairs with <provider>-test.
    {
        const fs = mkFs({ nextcloud: "/src/nc", "nextcloud-test": "/src/nc" }, new Set(["/src/nc/services/fileservice/update-service.sh"]));
        const f = findings({ name: "euro-office-test", environment: "test", dependsOn: ["nextcloud:fileservice"] }, fs);
        check(f.length === 0, "validate: provider resolution is environment-aware");
    }
    // 6. Every dependency is reported, not just the first.
    {
        const fs = mkFs({ a: "/src/a", b: "/src/b" }, new Set());
        const f = findings({ name: "app", dependsOn: ["a:one", "b:two"] }, fs);
        check(f.length === 2, "validate: each unsatisfiable dependency is reported");
    }
    // 7. Omitting fs skips the check entirely (tier/source lint stays pure).
    {
        const report = (0, validate_1.validateModules)([{ name: "app", tier: "app", source: "official", dependsOn: ["ghost:thing"] }], {});
        check(report.errors === 0, "validate: without an fs probe, reference integrity is skipped");
    }
}
// ── validateIntegratesWith: the SOFT counterpart to dependsOn (#501) ────
{
    const mkFs = (providers, files) => ({
        providerDir(provider, environment) {
            const scoped = environment ? `${provider}-${environment}` : "";
            const name = scoped && scoped in providers ? scoped : provider;
            return { module: name, dir: providers[name] ?? null };
        },
        exists: (p) => files.has(p),
        readFile: () => null,
    });
    const findings = (m, fs) => {
        const out = [];
        (0, validate_1.validateIntegratesWith)(m, fs, out);
        return out;
    };
    // 1. Provider NOT installed → the whole point: silent, no finding.
    {
        const f = findings({ name: "litellm", integratesWith: ["vllm-amd:inference"] }, mkFs({}, new Set()));
        check(f.length === 0, "validate: integratesWith with an absent provider is silent (no finding)");
    }
    // 2. Provider installed but ships no update-service.sh → soft WARNING, not error.
    {
        const fs = mkFs({ "vllm-amd": "/src/vllm" }, new Set());
        const f = findings({ name: "litellm", integratesWith: ["vllm-amd:inference"] }, fs);
        check(f.length === 1 && f[0].severity === "warning", "validate: installed integrator with no update-service.sh WARNS (soft)");
    }
    // 3. Provider installed and wireable → no finding.
    {
        const fs = mkFs({ "vllm-amd": "/src/vllm" }, new Set(["/src/vllm/services/inference/update-service.sh"]));
        const f = findings({ name: "litellm", integratesWith: ["vllm-amd:inference"] }, fs);
        check(f.length === 0, "validate: a wireable integration produces no finding");
    }
    // 4. Same coordinate in BOTH dependsOn and integratesWith → error.
    {
        const f = findings({ name: "x", dependsOn: ["vllm-amd:inference"], integratesWith: ["vllm-amd:inference"] }, mkFs({}, new Set()));
        check(f.length === 1 && f[0].severity === "error" && /both dependsOn and integratesWith/.test(f[0].message), "validate: a coordinate in both lists is an error");
    }
    // 5. Malformed (no ':service') → error.
    {
        const f = findings({ name: "x", integratesWith: ["vllm-amd"] }, mkFs({}, new Set()));
        check(f.length === 1 && f[0].message.includes("no ':<service>'"), "validate: a bare integratesWith coordinate is an error");
    }
}
// ── validateConfigBlock: the config ↔ dependsOn schema rules (#549) ─────
// module-fields.json declares these rules and common-install-routines.sh (hence
// reconcile) enforced them, but validate did not; now both agree.
{
    const findings = (raw) => {
        const out = [];
        const m = {
            name: typeof raw.name === "string" ? raw.name : "app",
            dependsOn: Array.isArray(raw.dependsOn) ? raw.dependsOn : [],
            raw,
        };
        (0, validate_1.validateConfigBlock)(m, out);
        return out;
    };
    // Rule 1: a config block for a provider not in dependsOn is an error — the
    // exact defect #549 measured (validate passed it, reconcile failed it).
    {
        const f = findings({ dependsOn: ["cluster:vm"], config: { "cluster:lxc": { cores: 4 } } });
        check(f.length === 1 &&
            f[0].severity === "error" &&
            f[0].message.includes("cluster:lxc") &&
            f[0].message.includes("not a declared dependency"), "validate: a config block for an undeclared dependency is an error (#549)");
    }
    // Rule 1: a config block for a declared dependency passes.
    {
        const f = findings({ dependsOn: ["cluster:vm"], config: { "cluster:vm": { cores: 4 } } });
        check(f.length === 0, "validate: a config block for a declared dependency passes");
    }
    // Rule 2: a field in both the header and a config block is ambiguous.
    {
        const f = findings({ dependsOn: ["cluster:vm"], cores: 2, config: { "cluster:vm": { cores: 4 } } });
        check(f.some((x) => x.message.includes("cores") && x.message.includes("ambiguous")), "validate: a field set in both header and a config block is ambiguous (#549)");
    }
    // Rule 2: the same field in two config blocks is ambiguous.
    {
        const f = findings({
            dependsOn: ["a:one", "b:two"],
            config: { "a:one": { memory: 1 }, "b:two": { memory: 2 } },
        });
        check(f.some((x) => x.message.includes("memory") && x.message.includes("ambiguous")), "validate: a field set in two config blocks is ambiguous (#549)");
    }
    // No config block → the rule is inapplicable (no finding), and a hand-built
    // config without `raw` must not crash.
    {
        check(findings({ dependsOn: ["cluster:vm"], cores: 2 }).length === 0, "validate: a module with no config block is unaffected");
        const out = [];
        (0, validate_1.validateConfigBlock)({ name: "x", dependsOn: [] }, out);
        check(out.length === 0, "validate: a ModuleConfig without raw is a safe no-op");
    }
    // End-to-end: validateModules now surfaces the config-block error.
    {
        const report = (0, validate_1.validateModules)([
            {
                name: "bad",
                tier: "app",
                source: "official",
                dependsOn: ["cluster:vm"],
                raw: { dependsOn: ["cluster:vm"], config: { "network:rules": {} } },
            },
        ], {});
        check(report.errors >= 1, "validate: validateModules surfaces the config-block error (#549)");
    }
}
// ── add: --vmid / --zone0 reach install-module.sh as field overrides ────
// These two are the ONLY schema fields that are also recognised flags, so the
// parser used to swallow them on `add` and the override vanished with no error
// (#495 follow-up — it cost two failed nextcloud installs).
{
    const addOpts = (argv) => {
        const fake = new fake_client_1.FakeModuleClient();
        (0, main_1.run)(argv, fake);
        const entry = fake.log.find((l) => l.verb === "add");
        return entry.opts;
    };
    {
        const p = addOpts(["add", "nextcloud", "--zone0", "rossen"]).passthrough;
        check(p.includes("--zone0") && p[p.indexOf("--zone0") + 1] === "rossen", "add: --zone0 reaches install-module.sh as a field override");
    }
    {
        const p = addOpts(["add", "demo", "--vmid", "412"]).passthrough;
        check(p.includes("--vmid") && p[p.indexOf("--vmid") + 1] === "412", "add: --vmid reaches install-module.sh as a field override");
    }
    {
        // Ordinary (non-colliding) overrides must still work, and coexist.
        const p = addOpts(["add", "demo", "--memory", "16384", "--zone0", "srvHome"]).passthrough;
        check(p.includes("--memory") && p[p.indexOf("--memory") + 1] === "16384" &&
            p.includes("--zone0") && p[p.indexOf("--zone0") + 1] === "srvHome", "add: a colliding and a non-colliding override coexist");
    }
    {
        // Absent flags must not inject empty overrides.
        const p = addOpts(["add", "demo"]).passthrough;
        check(!p.includes("--zone0") && !p.includes("--vmid"), "add: no spurious overrides when the flags are absent");
    }
}
// ── 15. --help/-h in ANY position prints usage and NEVER writes (#534) ──
// The flag used to be swallowed by parseOpts once a verb occupied argv[0], so a
// help probe ran the verb as a real write. Every mutating verb must now short-
// circuit to help (rc 0) with ZERO client invocations, for both spellings and
// with the flag before OR after the module positional.
{
    const captureRun = (argv) => {
        const real = console.log;
        let out = "";
        console.log = (...a) => {
            out += a.map(String).join(" ") + "\n";
        };
        const c = new fake_client_1.FakeModuleClient();
        let rc;
        try {
            rc = (0, main_1.run)(argv, c);
        }
        finally {
            console.log = real;
        }
        return { rc, out, log: c.log.length };
    };
    // Every mutating verb × both spellings × flag after the module positional.
    const mutating = ["modify", "delete", "reconcile", "test", "snapshot-vm", "add"];
    for (const verb of mutating) {
        for (const flag of ["--help", "-h"]) {
            const r = captureRun([verb, "nextcloud", flag]);
            check(r.rc === 0 && r.log === 0, `${verb} nextcloud ${flag}: exits 0 and performs NO client invocation (no write)`);
            check(r.out.includes(verb), `${verb} ${flag}: prints ${verb}'s usage`);
        }
    }
    // Flag BEFORE the module positional must be honoured too (`-h` would otherwise
    // become the module name).
    {
        const r = captureRun(["modify", "--help", "nextcloud"]);
        check(r.rc === 0 && r.log === 0, "modify --help <module> (flag first): exits 0, no write");
    }
    {
        const r = captureRun(["modify", "-h"]);
        check(r.rc === 0 && r.log === 0, "modify -h with NO module: exits 0, no write (not a module named -h)");
    }
    // The optional `module` entity keyword must not defeat the guard.
    {
        const r = captureRun(["module", "delete", "nextcloud", "--remove", "--help"]);
        check(r.rc === 0 && r.log === 0, "module delete <m> --remove --help: help wins over the destructive verb");
    }
    // A bare help token with no verb still prints the full help, rc 0.
    {
        const r = captureRun(["--help"]);
        check(r.rc === 0 && r.log === 0 && r.out.includes("Usage:"), "bare --help prints full help, no write");
    }
    // Verb-specific help shows THAT verb's options, not another verb's.
    {
        const r = captureRun(["modify", "nextcloud", "--help"]);
        check(r.out.includes("--no-snapshot") && !r.out.includes("--reinstall"), "modify --help renders modify's options (not add's)");
    }
}
console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
