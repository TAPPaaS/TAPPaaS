"use strict";
// config.ts — load the deployed module domain from config/ (the TARGET system
// directory, NOT the repo), plus the environment/effective-name resolution
// helpers ported from install-module.sh / update-module.sh.
//
// "config/" means the target system (~tappaas/config), per the ADR-007
// convention. Default path resolves from TAPPAAS_CONFIG (or /home/tappaas/config);
// tests pass an explicit dir (a fixture tree).
Object.defineProperty(exports, "__esModule", { value: true });
exports.isModuleConfig = exports.defaultConfigDir = void 0;
exports.siteNodeHostnames = siteNodeHostnames;
exports.loadModule = loadModule;
exports.listModules = listModules;
exports.resolveDefaultEnvironment = resolveDefaultEnvironment;
exports.resolveEffectiveModuleName = resolveEffectiveModuleName;
exports.normalizeModuleConfig = normalizeModuleConfig;
exports.getModuleDirResult = getModuleDirResult;
exports.getModuleDir = getModuleDir;
exports.resolveProviderModule = resolveProviderModule;
exports.siteRepositories = siteRepositories;
exports.repoCatalogFile = repoCatalogFile;
exports.resolveViaCatalog = resolveViaCatalog;
exports.classifyModuleResolution = classifyModuleResolution;
const fs_1 = require("fs");
const path_1 = require("path");
const config_io_1 = require("../../../lib/ts/src/config-io");
Object.defineProperty(exports, "defaultConfigDir", { enumerable: true, get: function () { return config_io_1.defaultConfigDir; } });
const module_discovery_1 = require("../../../lib/ts/src/module-discovery");
Object.defineProperty(exports, "isModuleConfig", { enumerable: true, get: function () { return module_discovery_1.isModuleConfig; } });
// Node hostnames from site.json (.hardware.nodes[].name) — the bash
// `get_all_node_hostnames` equivalent (ported from health-manager). Authoritative
// source for the cluster node list; an empty array means "fall back to the
// tappaas1..9 scan" (the CliModuleClient does that for its live cluster query).
function siteNodeHostnames(configDir) {
    const siteFile = (0, path_1.join)(configDir, "site.json");
    if (!(0, fs_1.existsSync)(siteFile))
        return [];
    let raw;
    try {
        raw = JSON.parse((0, fs_1.readFileSync)(siteFile, "utf8"));
    }
    catch {
        return [];
    }
    const hw = raw.hardware;
    if (!hw || typeof hw !== "object")
        return [];
    const nodes = hw.nodes;
    if (!Array.isArray(nodes))
        return [];
    const out = [];
    for (const n of nodes) {
        if (n && typeof n === "object") {
            const name = n.name;
            if (typeof name === "string" && name)
                out.push(name);
        }
    }
    return out;
}
// Non-module config files that also live in config/ and must NOT be enumerated
// as modules (network/site/zone state, the schema copy, switch desired/actual).
// NOTE: `templates` is NOT here — it IS a module (a provider-only module:
// provides ["nixos","debian"], no vmid/vmname). Provider-only modules are kept
// by the heuristic via their `provides`/`location`.
function asString(v) {
    return typeof v === "string" ? v : undefined;
}
function asStringArray(v) {
    if (!Array.isArray(v))
        return undefined;
    return v.filter((x) => typeof x === "string");
}
function asNumberOrNull(v) {
    return typeof v === "number" ? v : null;
}
function toModuleConfig(name, raw) {
    return {
        name,
        kind: asString(raw.kind),
        description: asString(raw.description),
        vmname: asString(raw.vmname),
        vmid: asNumberOrNull(raw.vmid),
        node: asString(raw.node) ?? null,
        zone0: asString(raw.zone0) ?? null,
        zone1: asString(raw.zone1) ?? null,
        tier: asString(raw.tier) ?? null,
        source: asString(raw.source) ?? null,
        // Kept as-loaded (round-trips any value); validate.ts warns on one outside
        // MODULE_STATUS_VALUES rather than dropping it here.
        status: (asString(raw.status) ?? null),
        environment: asString(raw.environment) ?? null,
        location: asString(raw.location) ?? null,
        installTime: asString(raw.installTime) ?? null,
        updateTime: asString(raw.updateTime) ?? null,
        dependsOn: asStringArray(raw.dependsOn),
        integratesWith: asStringArray(raw.integratesWith),
        provides: asStringArray(raw.provides),
        raw,
    };
}
// Load one deployed module config by (effective) name. Returns null if absent.
function loadModule(configDir, name) {
    const file = (0, path_1.join)(configDir, `${name}.json`);
    if (!(0, fs_1.existsSync)(file))
        return null;
    const raw = JSON.parse((0, fs_1.readFileSync)(file, "utf8"));
    return toModuleConfig(name, raw);
}
// Enumerate every deployed module config in configDir (sorted by name).
// Skips *.orig backups, the explicit non-module deny-list, and anything that is
// not a module (no kind=="module" tag and no module-shaped field).
function listModules(configDir) {
    return (0, module_discovery_1.discoverModules)(configDir).map((m) => toModuleConfig(m.name, m.raw));
}
// ── Environment / effective-name resolution (ported from install/update) ─
//
// The default environment is the single non-mgmt environment / site name <N>.
// resolve_default_environment() in install-module.sh: site.json '.name' wins;
// else the single non-mgmt environments/<env>.json basename.
function resolveDefaultEnvironment(configDir) {
    const siteFile = (0, path_1.join)(configDir, "site.json");
    if ((0, fs_1.existsSync)(siteFile)) {
        try {
            const site = JSON.parse((0, fs_1.readFileSync)(siteFile, "utf8"));
            const siteName = asString(site.name);
            if (siteName && siteName !== "mgmt")
                return siteName;
        }
        catch {
            // fall through to environments scan
        }
    }
    const envDir = (0, path_1.join)(configDir, "environments");
    if ((0, fs_1.existsSync)(envDir)) {
        const envs = [];
        for (const f of (0, fs_1.readdirSync)(envDir)) {
            if (!f.endsWith(".json"))
                continue;
            const base = (0, path_1.basename)(f, ".json");
            if (base === "mgmt")
                continue;
            envs.push(base);
        }
        if (envs.length === 1)
            return envs[0];
    }
    return "";
}
// Compute the installed (effective) module name from a base module +
// environment (ADR-007 P5). No suffix for an empty env, 'mgmt', or the default
// environment; otherwise <module>-<env>. Mirrors install/update/delete.
function resolveEffectiveModuleName(configDir, module, environment) {
    if (!environment)
        return module;
    if (environment === "mgmt")
        return module;
    const defaultEnv = resolveDefaultEnvironment(configDir);
    if (defaultEnv && environment === defaultEnv)
        return module;
    return `${module}-${environment}`;
}
// ── Pattern-A → flat normalization (#161/#207) ─────────────────────────
// Port of the bash `normalize_module_config` (common-install-routines.sh): a
// module JSON may group per-service configuration under a `config` block keyed
// by the "<module>:<service>" dependency coordinate. Flatten every config block
// up to the top level (jq `. * $s.value` = recursive object merge, later blocks
// win) and drop `config`. Already-flat ("Pattern C") docs pass through
// unchanged. Used by the native reconcile + inspect (Phase 7.3 ports).
function deepMergeObjects(a, b) {
    const out = { ...a };
    for (const [k, v] of Object.entries(b)) {
        const cur = out[k];
        if (cur !== null && typeof cur === "object" && !Array.isArray(cur) &&
            v !== null && typeof v === "object" && !Array.isArray(v)) {
            out[k] = deepMergeObjects(cur, v);
        }
        else {
            out[k] = v;
        }
    }
    return out;
}
function normalizeModuleConfig(raw) {
    const cfg = raw.config;
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg))
        return raw;
    let out = { ...raw };
    for (const block of Object.values(cfg)) {
        // (jq would ERROR on a non-object block; we skip it — forgiving delta.)
        if (block !== null && typeof block === "object" && !Array.isArray(block)) {
            out = deepMergeObjects(out, block);
        }
    }
    delete out.config;
    return out;
}
// ── Module source-directory resolution (bash get_module_dir port) ──────
// Reads .location from the deployed config. ADR-007 P8: a not-yet-migrated
// firewall.json may record .location=.../firewall while the source dir was
// renamed to .../network — follow the rename when the recorded dir is gone.
// Returns null when the config or its .location is absent (bash `return 1`).
function isDirectory(p) {
    try {
        return (0, fs_1.statSync)(p).isDirectory();
    }
    catch {
        return false;
    }
}
function getModuleDirResult(configDir, module) {
    const file = (0, path_1.join)(configDir, `${module}.json`);
    if (!(0, fs_1.existsSync)(file))
        return { kind: "not-installed" };
    let raw;
    try {
        raw = JSON.parse((0, fs_1.readFileSync)(file, "utf8"));
    }
    catch {
        return { kind: "not-installed" };
    }
    let location = typeof raw.location === "string" ? raw.location : "";
    if (!location)
        return { kind: "no-location" };
    if (!isDirectory(location) && location.endsWith("/firewall")) {
        const renamed = location.slice(0, -"/firewall".length) + "/network";
        if (isDirectory(renamed))
            location = renamed;
    }
    return isDirectory(location) ? { kind: "found", dir: location } : { kind: "missing-dir", dir: location };
}
// Legacy signature, unchanged in behaviour: the recorded .location is returned
// whether or not the directory still exists (bash `get_module_dir` likewise
// still ECHOES the path when it exits 2). Callers that need to tell the two
// apart use getModuleDirResult; the rest keep working untouched.
function getModuleDir(configDir, module) {
    const r = getModuleDirResult(configDir, module);
    return r.kind === "found" || r.kind === "missing-dir" ? r.dir : null;
}
// ── Provider-name resolution (bash resolve_provider_module port). Prefer the
// provider serving the CONSUMING module's environment; else the named
// provider's own deployed config; else its legacy firewall<->network
// counterpart if THAT is the one actually deployed; else echo the name back
// (the caller handles the miss).
//
// #438: this was ported in the "no-variant form" — it took no environment at
// all, so `module-manager reconcile` re-applied every consumer against the
// SHARED provider even when a dedicated one served its environment. Keep the
// signature aligned with the bash: environment last, optional, file-existence
// guarded (so mgmt / the default environment, whose configs are unsuffixed by
// design, correctly fall through to the base name).
function resolveProviderModule(configDir, provider, environment = "") {
    if (environment && (0, fs_1.existsSync)((0, path_1.join)(configDir, `${provider}-${environment}.json`))) {
        return `${provider}-${environment}`;
    }
    if ((0, fs_1.existsSync)((0, path_1.join)(configDir, `${provider}.json`)))
        return provider;
    const alias = provider === "network" ? "firewall" : provider === "firewall" ? "network" : "";
    if (alias && (0, fs_1.existsSync)((0, path_1.join)(configDir, `${alias}.json`)))
        return alias;
    return provider;
}
// site.json .repositories[], normalized. Entries with no .path are kept: they
// are a misconfiguration worth reporting, not worth hiding.
function siteRepositories(configDir) {
    const siteFile = (0, path_1.join)(configDir, "site.json");
    if (!(0, fs_1.existsSync)(siteFile))
        return [];
    let raw;
    try {
        raw = JSON.parse((0, fs_1.readFileSync)(siteFile, "utf8"));
    }
    catch {
        return [];
    }
    const repos = raw.repositories;
    if (!Array.isArray(repos))
        return [];
    const out = [];
    for (const r of repos) {
        if (!r || typeof r !== "object")
            continue;
        const o = r;
        out.push({
            name: asString(o.name) ?? "",
            path: asString(o.path) ?? "",
            catalog: asString(o.catalog) ?? "",
            managed: asString(o.managed) ?? "full",
        });
    }
    return out;
}
// Port of repo_catalog_file (lib/module-catalog-lib.sh): the DECLARED catalog
// path wins, then the current convention, then the legacy name (#305, #459).
function repoCatalogFile(repoPath, declared) {
    const root = repoPath.replace(/\/+$/, "");
    const declaredAbs = declared ? (0, path_1.join)(root, declared) : "";
    if (declaredAbs && (0, fs_1.existsSync)(declaredAbs))
        return declaredAbs;
    const current = (0, path_1.join)(root, "src", "module-catalog.json");
    if ((0, fs_1.existsSync)(current))
        return current;
    const legacy = (0, path_1.join)(root, "src", "modules.json");
    if ((0, fs_1.existsSync)(legacy))
        return legacy;
    return current;
}
// Port of resolve-module.sh's catalog scan: first repository in site.json order
// carrying the module (by moduleName OR legacyName) wins.
function resolveViaCatalog(configDir, module) {
    for (const repo of siteRepositories(configDir)) {
        if (!repo.path)
            continue;
        const catalogFile = repoCatalogFile(repo.path, repo.catalog);
        if (!(0, fs_1.existsSync)(catalogFile))
            continue;
        let cat;
        try {
            cat = JSON.parse((0, fs_1.readFileSync)(catalogFile, "utf8"));
        }
        catch {
            continue;
        }
        const entries = [
            ...(Array.isArray(cat.foundationModules) ? cat.foundationModules : []),
            ...(Array.isArray(cat.applicationModules) ? cat.applicationModules : []),
        ];
        for (const e of entries) {
            if (!e || typeof e !== "object")
                continue;
            const o = e;
            if (o.moduleName !== module && o.legacyName !== module)
                continue;
            const moduleJson = asString(o.moduleJson) ?? "";
            return {
                repo: repo.name,
                moduleJson: moduleJson ? (0, path_1.join)(repo.path.replace(/\/+$/, ""), moduleJson) : "",
                tier: asString(o.tier) ?? "app",
            };
        }
    }
    return null;
}
function classifyModuleResolution(configDir, module) {
    const dirResult = getModuleDirResult(configDir, module);
    const hit = resolveViaCatalog(configDir, module);
    const cfg = loadModule(configDir, module);
    let path;
    let dir = null;
    if (dirResult.kind === "found") {
        path = "location";
        dir = dirResult.dir;
    }
    else if (hit) {
        path = "catalog";
        dir = hit.moduleJson ? (0, path_1.dirname)(hit.moduleJson) : null;
    }
    else if (dirResult.kind === "missing-dir") {
        path = "broken-location";
        dir = dirResult.dir;
    }
    else {
        path = "unresolvable";
    }
    const configTier = cfg?.tier ?? null;
    return {
        module,
        path,
        dir,
        catalogRepo: hit ? hit.repo : null,
        tier: configTier ?? hit?.tier ?? null,
        tierSource: configTier ? "config" : hit ? "catalog" : null,
    };
}
