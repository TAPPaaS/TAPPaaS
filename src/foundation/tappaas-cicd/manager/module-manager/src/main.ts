// module-manager — TAPPaaS module lifecycle manager (ADR-007 #3 verb alignment).
//
// Presents the STANDARDIZED verbs on entity `module`:
//
//   module add <module>      = install-module.sh   (create + provision)
//   module modify <module>   = update-module.sh    (change config + re-apply)
//   module delete <module>   = delete-module.sh    (archive/remove)
//   module list              = enumerate deployed module configs    [NEW, TS]
//   module show <module>     = one deployed module config in detail [NEW, TS]
//   module validate [<m>]    = tier/source lint (all, or one)        [TS port]
//   module reconcile <m>     = re-apply this module's config → VM/service [leaf]
//   module test <module>     = test-module.sh
//   module snapshot-vm <m>   = snapshot-vm.sh  (special VM op — stays)
//
// CONFIG-layer verbs (list/show/validate) are pure TS reading config/*.json.
// LIFECYCLE verbs (add/modify/delete/reconcile/test/snapshot-vm) delegate to the
// existing bash scripts via the injected ModuleClient (the heavy cluster logic
// stays in bash for this first-pass port — module-manager is a thin orchestrator
// like network-manager).
//
// Exit codes: ok=0, error / non-zero child rc = that rc (1 for config errors).

import { CliModuleClient } from "./client";
import {
  defaultConfigDir,
  listModules,
  loadModule,
} from "./config";
import {
  AddOptions,
  DeleteOptions,
  ModifyOptions,
  ModuleClient,
  ReconcileOptions,
  SnapshotAction,
  TestOptions,
} from "./types";
import { validateModules } from "./validate";

const VERSION = "0.1.0";

const YW = "\x1b[01;33m";
const RD = "\x1b[01;31m";
const GN = "\x1b[1;92m";
const CL = "\x1b[0m";

function info(msg: string): void {
  console.log(msg);
}
function warn(msg: string): void {
  console.log(`${YW}[Warning]${CL} ${msg}`);
}
class DieError extends Error {}
function die(msg: string): never {
  console.error(`${RD}[Error]${CL} ${msg}`);
  throw new DieError(msg);
}

function usage(): void {
  info(`module-manager ${VERSION} — TAPPaaS module lifecycle manager (ADR-007 #3)

Usage:
  module-manager module list [--config-dir DIR] [--json]
  module-manager module show <module> [--config-dir DIR] [--json]
  module-manager module validate [<module>] [--allow-fork] [--config-dir DIR] [--json]
  module-manager module add <module> [--environment ENV] [--allow-fork]
                                      [--force] [--reinstall] [--<field> <value>]...
  module-manager module modify <module> [--environment ENV] [--force]
                                         [--no-snapshot] [--debug] [--silent]
  module-manager module delete <module> [--archive|--remove] [--vmid ID]
                                         [--environment ENV] [--yes] [--force]
  module-manager module reconcile <module> [--environment ENV] [--no-snapshot]
  module-manager module test <module> [--deep] [--vmid ID] [--zone0 ZONE]
  module-manager module snapshot-vm <module> [--list|--cleanup N|--restore N]

Common options:
  --config-dir DIR  Config root (default: \$TAPPAAS_CONFIG or /home/tappaas/config).
  --json            Machine-readable output (list / show / validate).
  -h, --help        Show this help.

Verbs map (ADR-007 verb alignment):
  add=install-module  modify=update-module  delete=delete-module
  test=test-module    validate=tier/source lint  reconcile=leaf re-apply
  list/show are new (TS, read config/*.json).  snapshot-vm stays a special verb.`);
}

// ── option parsing ─────────────────────────────────────────────────────
interface Opts {
  configDir: string;
  json: boolean;
  // lifecycle flags
  environment?: string;
  allowFork: boolean;
  force: boolean;
  reinstall: boolean;
  noSnapshot: boolean;
  debug: boolean;
  silent: boolean;
  yes: boolean;
  deep: boolean;
  vmid?: string;
  zone0?: string;
  archive: boolean;
  remove: boolean;
  // snapshot-vm sub-action
  snapList: boolean;
  snapCleanup?: number;
  snapRestore?: number;
  // positionals + unrecognised --field/value pairs (passthrough to add)
  rest: string[];
  passthrough: string[];
}

function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    json: false,
    allowFork: false,
    force: false,
    reinstall: false,
    noSnapshot: false,
    debug: false,
    silent: false,
    yes: false,
    deep: false,
    archive: false,
    remove: false,
    snapList: false,
    rest: [],
    passthrough: [],
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = (): string => {
      const v = args[i + 1];
      if (v === undefined) die(`${a} requires an argument`);
      i++;
      return v;
    };
    if (a === "--config-dir") {
      o.configDir = next();
    } else if (a === "--environment" || a === "--variant") {
      if (a === "--variant") warn(`--variant is deprecated; treating as --environment (ADR-007 P5)`);
      o.environment = next();
    } else if (a === "--vmid") {
      o.vmid = next();
    } else if (a === "--zone0") {
      o.zone0 = next();
    } else if (a === "--cleanup") {
      o.snapCleanup = parseIntStrict(next(), "--cleanup");
    } else if (a === "--restore") {
      o.snapRestore = parseIntStrict(next(), "--restore");
    } else if (a === "--json") {
      o.json = true;
    } else if (a === "--allow-fork") {
      o.allowFork = true;
    } else if (a === "--force") {
      o.force = true;
    } else if (a === "--reinstall") {
      o.reinstall = true;
    } else if (a === "--no-snapshot") {
      o.noSnapshot = true;
    } else if (a === "--debug") {
      o.debug = true;
    } else if (a === "--silent") {
      o.silent = true;
    } else if (a === "--yes" || a === "-y") {
      o.yes = true;
    } else if (a === "--deep") {
      o.deep = true;
    } else if (a === "--archive") {
      o.archive = true;
    } else if (a === "--remove") {
      o.remove = true;
    } else if (a === "--list") {
      o.snapList = true;
    } else if (a.startsWith("--")) {
      // An unrecognised --<field>; for `add` these are JSON-field overrides that
      // pass straight through to install-module.sh / copy-update-json.sh. Capture
      // it AND its following value (when the next token is not another flag).
      o.passthrough.push(a);
      const v = args[i + 1];
      if (v !== undefined && !v.startsWith("-")) {
        o.passthrough.push(v);
        i++;
      }
    } else {
      o.rest.push(a);
    }
  }
  return o;
}

function parseIntStrict(s: string, flag: string): number {
  const n = parseInt(s, 10);
  if (!Number.isInteger(n)) die(`${flag} requires an integer (got '${s}')`);
  return n;
}

// ── CONFIG-layer verbs (pure TS over config/*.json) ────────────────────
function cmdList(opts: Opts): number {
  const mods = listModules(opts.configDir);
  if (opts.json) {
    // Machine-readable: emit a stable summary object per module (the cascade
    // parses these fields). The full config is available via `show --json`.
    const summary = mods.map((m) => ({
      name: m.name,
      vmname: m.vmname ?? null,
      vmid: m.vmid ?? null,
      node: m.node ?? null,
      zone0: m.zone0 ?? null,
      tier: m.tier ?? null,
      status: m.status ?? null,
      environment: m.environment ?? null,
    }));
    info(JSON.stringify(summary, null, 2));
    return 0;
  }
  if (mods.length === 0) {
    info(`(no deployed modules in ${opts.configDir})`);
    return 0;
  }
  // Tabular human view: name, vmid, node, zone0, status.
  for (const m of mods) {
    const vmid = m.vmid != null ? String(m.vmid) : "-";
    const node = m.node ?? "-";
    const zone = m.zone0 ?? "-";
    const status = m.status ?? "active";
    info(`${m.name}\tvmid=${vmid}\tnode=${node}\tzone0=${zone}\t[${status}]`);
  }
  return 0;
}

function cmdShow(opts: Opts): number {
  const name = opts.rest[0];
  if (!name) die("show: expected <module>");
  const m = loadModule(opts.configDir, name);
  if (!m) die(`module '${name}' not found in ${opts.configDir}`);
  // The full deployed config IS the JSON, so --json and the human view share the
  // same (pretty-printed, authoritative, machine-parseable) body.
  info(JSON.stringify(m.raw, null, 2));
  return 0;
}

function cmdValidate(opts: Opts): number {
  const name = opts.rest[0];
  let mods;
  if (name) {
    const m = loadModule(opts.configDir, name);
    if (!m) die(`module '${name}' not found in ${opts.configDir}`);
    mods = [m];
  } else {
    mods = listModules(opts.configDir);
  }
  const report = validateModules(mods, { allowFork: opts.allowFork });
  if (opts.json) {
    info(JSON.stringify(report, null, 2));
    return report.errors > 0 ? 1 : 0;
  }
  for (const f of report.findings) {
    if (f.severity === "error") {
      console.error(`${RD}[Error]${CL} ${f.module}: ${f.message}`);
    } else {
      warn(`${f.module}: ${f.message}`);
    }
  }
  if (report.errors > 0) {
    die(`validate FAILED: ${report.errors} error(s), ${report.warnings} warning(s) across ${mods.length} module(s)`);
  }
  info(`${GN}validate ok${CL} (${mods.length} module(s), ${report.warnings} warning(s))`);
  return 0;
}

// ── LIFECYCLE verbs (delegate to bash via the ModuleClient) ────────────
function cmdAdd(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("add: expected <module>");
  const a: AddOptions = {
    environment: opts.environment,
    allowFork: opts.allowFork,
    force: opts.force,
    reinstall: opts.reinstall,
    passthrough: opts.passthrough,
  };
  return client.add(module, a);
}

function cmdModify(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("modify: expected <module>");
  const m: ModifyOptions = {
    environment: opts.environment,
    force: opts.force,
    noSnapshot: opts.noSnapshot,
    debug: opts.debug,
    silent: opts.silent,
  };
  return client.modify(module, m);
}

function cmdDelete(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("delete: expected <module>");
  if (opts.archive && opts.remove) die("delete: --archive and --remove are mutually exclusive");
  const d: DeleteOptions = {
    environment: opts.environment,
    mode: opts.remove ? "remove" : opts.archive ? "archive" : undefined,
    vmid: opts.vmid,
    yes: opts.yes,
    force: opts.force,
  };
  return client.delete(module, d);
}

function cmdTest(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("test: expected <module>");
  const t: TestOptions = { deep: opts.deep, vmid: opts.vmid, zone0: opts.zone0 };
  return client.test(module, t);
}

// reconcile = the LEAF re-apply (current config → VM/service). Per ADR-007 it is
// distinct from `modify`: reconcile re-applies the EXISTING config (idempotent
// converge), while modify CHANGES the config first then applies. This is the
// leaf the `reconcile --deep` cascade (site → environment → module) depends on,
// so it must be idempotent.
//
// Wired to reconcile-module.sh — a purpose-built lighter converge that re-runs
// the module's dependency *-service.sh applies + the module's own update.sh/
// install.sh ONLY: NO snapshot, NO pre/post tests, NO 3-way merge, NO updateTime
// bump. (update-module.sh / `module modify` does all of those — that is the
// difference between the two verbs.)
function cmdReconcile(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("reconcile: expected <module>");
  const r: ReconcileOptions = {
    environment: opts.environment,
    debug: opts.debug,
    silent: opts.silent,
  };
  return client.reconcile(module, r);
}

function cmdSnapshot(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("snapshot-vm: expected <module>");
  let action: SnapshotAction;
  if (opts.snapList) {
    action = { kind: "list" };
  } else if (opts.snapCleanup !== undefined) {
    action = { kind: "cleanup", keep: opts.snapCleanup };
  } else if (opts.snapRestore !== undefined) {
    action = { kind: "restore", steps: opts.snapRestore };
  } else {
    action = { kind: "create" };
  }
  return client.snapshot(module, action);
}

// ── dispatch ───────────────────────────────────────────────────────────
// Entity-first form: `module-manager module <verb> ...`. The `module` entity
// keyword is optional (it is the only entity) so `module-manager list` also
// works — matching how people-manager/network-manager keep the common verbs
// reachable.
function dispatch(verb: string, opts: Opts, client: ModuleClient): number {
  switch (verb) {
    case "list":
      return cmdList(opts);
    case "show":
      return cmdShow(opts);
    case "validate":
      return cmdValidate(opts);
    case "add":
      return cmdAdd(opts, client);
    case "modify":
      return cmdModify(opts, client);
    case "delete":
      return cmdDelete(opts, client);
    case "reconcile":
      return cmdReconcile(opts, client);
    case "test":
      return cmdTest(opts, client);
    case "snapshot-vm":
      return cmdSnapshot(opts, client);
    default:
      usage();
      die(`Unknown verb: ${verb}`);
  }
}

export function run(argv: string[], client: ModuleClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  // Allow an optional leading `module` entity keyword.
  let rest = argv;
  if (rest[0] === "module") rest = rest.slice(1);
  if (rest.length === 0) {
    usage();
    return 0;
  }
  const verb = rest[0];
  const opts = parseOpts(rest.slice(1));
  try {
    return dispatch(verb, opts, client);
  } catch (e) {
    if (e instanceof DieError) return 1;
    throw e;
  }
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  process.exit(run(process.argv.slice(2), new CliModuleClient()));
}

// Re-export for tests.
export { warn };
