// environment-manager — TAPPaaS Environment manager (ADR-007 P3, #3 port).
//
// Owns config/environments/<env>.json (CRUD + validate) and the reconcile
// cascade. `environment reconcile` converges the environment's associated zone
// by shelling out to network-manager; `--deep` additionally reconciles every
// module that consumes the environment (shell out to module-manager). NO plane
// or module logic is reimplemented — it is a thin orchestration boundary,
// exactly as people-manager shells out to authentik-manager.
//
// Entity: `environment`. Verbs:
//   environment list
//   environment show <env>
//   environment validate [<file|dir>]
//   environment add [<env>] [--name <N>] [--domain <d>] [--owner <org>]
//                   [--zone <z>] [--display <d>] [--force]   (no <env>+no --name ⇒ seed minimal set)
//   environment modify <env> [--domain <d>] [--owner <org>] [--zone <z>] [--display <d>]
//   environment delete <env>
//   environment reconcile <env> [--deep] [--apply]
//
// Exit codes: ok=0, error=1.

import {
  defaultConfigDir,
  environmentsDir,
  loadEnvironment,
  loadEnvironments,
  loadRefSources,
  parseEnvironment,
  serializeEnvironment,
  validateEnvironmentRefs,
  writeEnvironment,
} from "./config";
import { bootstrap, firstOrg, resolveName } from "./bootstrap";
import { CliModuleClient, CliNetworkClient, NetworkUnreachable } from "./clients";
import { applyPlan, computePlan } from "./reconcile";
import { runValidate } from "./validate";
import { Environment, ModuleClient, NetworkClient } from "./types";
import { existsSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";

// The two always-required bootstrap environments are protected from delete:
// 'mgmt' and the default <N> environment (= site.json '.name'). create-minimal-
// environments is their single owner.
const RESERVED_MGMT = "mgmt";

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
  info(`environment-manager ${VERSION} — TAPPaaS Environment manager

Usage:
  environment-manager list [--json] [--config-dir DIR]
  environment-manager show <env> [--json] [--config-dir DIR]
  environment-manager validate [<file|dir>] [--config-dir DIR]
  environment-manager add [<env>] [--name N] [--domain D] [--owner ORG]
                          [--zone Z] [--display D] [--dns-mode M] [--force] [--config-dir DIR]
  environment-manager modify <env> [--domain D] [--owner ORG] [--zone Z]
                          [--display D] [--dns-mode M] [--config-dir DIR]
  environment-manager delete <env> [--force] [--config-dir DIR]
  environment-manager reconcile <env> [--deep] [--apply] [--config-dir DIR]

Notes:
  add with no <env> and no --name seeds the minimal environment set
  (mgmt + the default <N> environment) via the create-minimal-environments
  bootstrap. With <env> (or --name) it creates that single environment.
  delete refuses to remove 'mgmt', the default <N> environment, or an env still
  consumed by deployed modules — unless --force.

Options:
  --config-dir DIR Config root (default: \$TAPPAAS_CONFIG or /home/tappaas/config).
  --json           Machine-readable output (list/show).
  --domain D       Public primary domain (add/modify).
  --owner ORG      Owning organization (add/modify; default = first org).
  --zone Z         network.zone reference (add/modify; default = <env>).
  --display D      displayName (add/modify).
  --dns-mode M     domains.dnsMode: per-service (default, Caddy HTTP-01 per host)
                   or wildcard (one *.<primary> ACME cert) (add/modify).
  --deep           reconcile: also reconcile every module consuming this env.
  --apply          reconcile: commit (default = preview / dry-run).
  --force          add: overwrite existing; delete: override guard rails.
  -h, --help       Show this help.`);
}

interface Opts {
  configDir: string;
  name?: string;
  domain?: string;
  owner?: string;
  zone?: string;
  display?: string;
  dnsMode?: "per-service" | "wildcard";
  deep: boolean;
  apply: boolean;
  force: boolean;
  json: boolean;
  rest: string[];
}

function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    deep: false,
    apply: false,
    force: false,
    json: false,
    rest: [],
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const need = (label: string): string => {
      const v = args[i + 1];
      if (!v) die(`${label} requires a value`);
      i++;
      return v;
    };
    switch (a) {
      case "--config-dir":
        o.configDir = need("--config-dir");
        break;
      case "--name":
        o.name = need("--name");
        break;
      case "--domain":
        o.domain = need("--domain");
        break;
      case "--owner":
        o.owner = need("--owner");
        break;
      case "--zone":
        o.zone = need("--zone");
        break;
      case "--display":
        o.display = need("--display");
        break;
      case "--dns-mode":
      case "--dnsMode": {
        const v = need("--dns-mode");
        if (v !== "per-service" && v !== "wildcard") {
          die(`--dns-mode must be 'per-service' or 'wildcard' (got '${v}')`);
        }
        o.dnsMode = v;
        break;
      }
      case "--deep":
        o.deep = true;
        break;
      case "--apply":
        o.apply = true;
        break;
      case "--force":
        o.force = true;
        break;
      case "--json":
        o.json = true;
        break;
      default:
        if (a.startsWith("--")) die(`Unknown option: ${a}`);
        o.rest.push(a);
    }
  }
  return o;
}

// ── list / show ───────────────────────────────────────────────────────
function cmdList(opts: Opts): void {
  const model = loadEnvironments(opts.configDir);
  const names = Array.from(model.environments.keys()).sort();
  if (opts.json) {
    // Machine output: array of the full environment objects.
    const envs = names.map((n) => model.environments.get(n));
    info(JSON.stringify(envs, null, 2));
    return;
  }
  // Human output: one environment name per line (zone in brackets).
  for (const n of names) {
    const e = model.environments.get(n);
    info(`${n}\t(zone ${e?.network.zone ?? "?"})`);
  }
}

function cmdShow(opts: Opts): void {
  const name = opts.rest[0];
  if (!name) die("show: expected <env>");
  const env = loadEnvironment(opts.configDir, name);
  if (!env) die(`environment '${name}' not found in ${environmentsDir(opts.configDir)}`);
  if (opts.json) {
    // Machine output: compact single-line JSON.
    info(JSON.stringify(env));
    return;
  }
  // Human output: the canonical pretty-printed environment document.
  info(serializeEnvironment(env).trimEnd());
}

// ── validate ──────────────────────────────────────────────────────────
// Thin wrapper: delegate to validate-environment.sh (the canonical schema gate)
// and relay its output + exit status.
function cmdValidate(opts: Opts): void {
  const target = opts.rest[0];
  const res = runValidate(opts.configDir, target);
  if (res.stdout) process.stdout.write(res.stdout);
  if (res.stderr) process.stderr.write(res.stderr);
  if (res.status !== 0) {
    die(`Environment validation failed (validate-environment.sh exit ${res.status})`);
  }
}

// Validate one in-memory env against the ref sources; die on errors.
function assertValid(opts: Opts, env: Environment, raw: unknown): void {
  const refs = loadRefSources(opts.configDir);
  const res = validateEnvironmentRefs(env, raw, refs);
  for (const w of res.warnings) warn(`VALIDATION: ${w}`);
  if (res.errors.length > 0) {
    for (const e of res.errors) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
    die(`Refusing to write '${env.name}': ${res.errors.length} validation error(s)`);
  }
}

// ── add ───────────────────────────────────────────────────────────────
function cmdAdd(opts: Opts): void {
  const single = opts.rest[0];
  // No positional env AND no --name ⇒ seed the minimal set (bootstrap).
  if (!single && !opts.name) {
    const res = bootstrap({
      configDir: opts.configDir,
      domain: opts.domain,
      force: opts.force,
    });
    for (const w of res.warnings) warn(w);
    for (const p of res.skipped) info(`${p} already exists — left untouched (use --force).`);
    for (const p of res.wrote) info(`${GN}Wrote ${p}${CL}`);
    info(
      `Minimal environments bootstrap complete (name=${res.name}, ownerOrg=${res.owner || "<unset>"}).`,
    );
    return;
  }

  // Single-environment create.
  const name = single ?? opts.name;
  if (!name) die("add: expected <env> or --name");
  const path = join(environmentsDir(opts.configDir), `${name}.json`);
  if (existsSync(path) && !opts.force) {
    die(`environment '${name}' already exists at ${path} (use --force to overwrite)`);
  }
  const display = opts.display ?? name.charAt(0).toUpperCase() + name.slice(1);
  // --owner default: the first organization under people/organizations/ (matches
  // the create-minimal-environments bootstrap). Empty only when no org exists,
  // in which case the pre-write validation flags the missing ownerOrg.
  const owner = opts.owner ?? firstOrg(opts.configDir);
  const env: Environment = {
    name,
    displayName: display,
    ownerOrg: owner,
    network: { zone: opts.zone ?? name },
  };
  if (opts.domain || opts.dnsMode) {
    env.domains = {
      primary: opts.domain ?? "",
      ...(opts.dnsMode ? { dnsMode: opts.dnsMode } : {}),
    };
  }
  assertValid(opts, env, env);
  const written = writeEnvironment(opts.configDir, env);
  info(`${GN}Wrote ${written}${CL}`);
}

// ── modify ────────────────────────────────────────────────────────────
function cmdModify(opts: Opts): void {
  const name = opts.rest[0];
  if (!name) die("modify: expected <env>");
  const path = join(environmentsDir(opts.configDir), `${name}.json`);
  if (!existsSync(path)) die(`environment '${name}' not found at ${path}`);
  // Re-parse the RAW file so we preserve fields not modeled by the CLI flags.
  const raw = JSON.parse(readFileSync(path, "utf8"));
  const env = parseEnvironment(raw, name);
  if (opts.display) env.displayName = opts.display;
  if (opts.owner) env.ownerOrg = opts.owner;
  if (opts.zone) env.network.zone = opts.zone;
  if (opts.domain || opts.dnsMode) {
    env.domains = {
      ...(env.domains ?? { primary: "" }),
      ...(opts.domain ? { primary: opts.domain } : {}),
      ...(opts.dnsMode ? { dnsMode: opts.dnsMode } : {}),
    };
  }
  assertValid(opts, env, env);
  const written = writeEnvironment(opts.configDir, env);
  info(`${GN}Updated ${written}${CL}`);
}

// ── delete ────────────────────────────────────────────────────────────
// Guard rails: refuse to delete the bootstrap environments ('mgmt' and the
// default <N> environment = site.json '.name'), and refuse when deployed modules
// still consume the env — UNLESS --force. create-minimal-environments is the
// single owner of the bootstrap files, so they are never casually removed.
function cmdDelete(opts: Opts, mod: ModuleClient): void {
  const name = opts.rest[0];
  if (!name) die("delete: expected <env>");
  const path = join(environmentsDir(opts.configDir), `${name}.json`);
  if (!existsSync(path)) die(`environment '${name}' not found at ${path}`);

  if (!opts.force) {
    // Reserved bootstrap environments.
    const defaultEnv = resolveName(opts.configDir);
    if (name === RESERVED_MGMT) {
      die(
        `Refusing to delete the reserved management environment '${RESERVED_MGMT}' (use --force to override).`,
      );
    }
    if (defaultEnv && name === defaultEnv) {
      die(
        `Refusing to delete the default environment '${name}' (= site.json '.name'; use --force to override).`,
      );
    }
    // Dependent-module check.
    const consumers = mod.modulesForEnvironment(name);
    if (consumers.length > 0) {
      die(
        `Refusing to delete environment '${name}': still consumed by ${consumers.length} ` +
          `deployed module(s): ${consumers.join(", ")} (use --force to override).`,
      );
    }
  }

  unlinkSync(path);
  info(`${GN}Deleted ${path}${CL}`);
}

// ── reconcile ─────────────────────────────────────────────────────────
function cmdReconcile(opts: Opts, net: NetworkClient, mod: ModuleClient): void {
  const name = opts.rest[0];
  if (!name) die("reconcile: expected <env>");
  const env = loadEnvironment(opts.configDir, name);
  if (!env) die(`environment '${name}' not found in ${environmentsDir(opts.configDir)}`);

  let plan;
  try {
    plan = computePlan(env, net, mod, opts.deep);
  } catch (e) {
    if (e instanceof NetworkUnreachable) die(`network-manager unreachable: ${e.message}`);
    throw e;
  }

  info(
    `Reconcile environment '${name}' (zone '${env.network.zone}'${opts.deep ? ", --deep" : ""}): ` +
      `${plan.actions.length} action(s), ${plan.warnings.length} warning(s)`,
  );
  for (const w of plan.warnings) warn(w);
  for (const a of plan.actions) {
    info(`  ${opts.apply ? "" : "[preview] "}${a.kind}: ${a.target}`);
  }

  if (!opts.apply) {
    info("");
    info("Preview only (no --apply): no changes made.");
    return;
  }
  try {
    const n = applyPlan(env, plan, net, mod, opts.apply);
    info("");
    info(`${GN}Reconciled ${n} target(s).${CL}`);
  } catch (e) {
    if (e instanceof NetworkUnreachable) die(`reconcile failed: ${e.message}`);
    throw e;
  }
}

export function run(argv: string[], net: NetworkClient, mod: ModuleClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  const cmd = argv[0];
  const opts = parseOpts(argv.slice(1));

  try {
    switch (cmd) {
      case "list":
        cmdList(opts);
        return 0;
      case "show":
        cmdShow(opts);
        return 0;
      case "validate":
        cmdValidate(opts);
        return 0;
      case "add":
        cmdAdd(opts);
        return 0;
      case "modify":
        cmdModify(opts);
        return 0;
      case "delete":
        cmdDelete(opts, mod);
        return 0;
      case "reconcile":
        cmdReconcile(opts, net, mod);
        return 0;
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  } catch (e) {
    if (e instanceof DieError) return 1;
    throw e;
  }
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const argv = process.argv.slice(2);
  // Resolve config-dir early for the module client's discovery root.
  const opts = parseOpts(argv.slice(1));
  const net = new CliNetworkClient();
  const mod = new CliModuleClient(opts.configDir);
  process.exit(run(argv, net, mod));
}
