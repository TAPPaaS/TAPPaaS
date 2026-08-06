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
//   environment validate [<file|dir>] [--schema-dir P] [--zones F] [--quiet]
//   environment add [<env>] [--name <N>] [--domain <d>] [--owner <org>]
//                   [--zone <z>] [--display <d>] [--force]
//                   (no positional <env> ⇒ seed the minimal set; --name <N> gives
//                   the system name explicitly, else it derives from site.json)
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
  validateEnvironmentRefs,
  writeEnvironment,
} from "./config";
import { bootstrap, firstOrg, resolveName } from "./bootstrap";
import { CliModuleClient, CliNetworkClient, NetworkUnreachable } from "./clients";
import { applyPlan, computePlan } from "./reconcile";
import { runValidate } from "./validate";
import { Environment, ModuleClient, NetworkClient } from "./types";
import { HelpSpec, renderHelp } from "../../../lib/ts/src/help";
import { RD, GN, CL, die, guarded, info, warn } from "../../../lib/ts/src/cli";
import { existsSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";

// The two always-required bootstrap environments are protected from delete:
// 'mgmt' and the default <N> environment (= site.json '.defaultEnvironment'). The `add`
// minimal-set bootstrap (src/bootstrap.ts — the retired
// create-minimal-environments.sh, ported) is their single owner.
const RESERVED_MGMT = "mgmt";

const VERSION = "0.1.0";

const HELP: HelpSpec = {
  name: "environment-manager",
  version: VERSION,
  tagline: "TAPPaaS Environment manager",
  verbs: [
    { usage: "list [--json]" },
    { usage: "show <env> [--json]" },
    {
      usage: "validate [<file|dir>] [--schema-dir P] [--zones F] [--quiet]",
      name: "validate",
      options: [
        ["--schema-dir P", "Directory holding environment-fields.json (default: derived)."],
        ["--zones F", "Path to zones.json (default: <config-dir>/zones.json)."],
        ["--quiet", "Only output errors/warnings."],
      ],
    },
    {
      usage: "add [<env>] [--name N] [--domain D] [--owner ORG]\n" +
        "                          [--zone Z] [--display D] [--dns-mode M] [--force]",
      name: "add",
      options: [
        ["--domain D", "Public primary domain (add/modify)."],
        ["--owner ORG", "Owning organization (add/modify; default = first org)."],
        ["--zone Z", "network.zone reference (add/modify; default = <env>)."],
        ["--display D", "displayName (add/modify)."],
        [
          "--dns-mode M",
          "domains.dnsMode: per-service (default, Caddy HTTP-01 per host)\n" +
            "                   or wildcard (one *.<primary> ACME cert) (add/modify).",
        ],
        ["--force", "add: overwrite existing; delete: override guard rails."],
      ],
    },
    {
      usage: "modify <env> [--domain D] [--owner ORG] [--zone Z]\n" +
        "                          [--display D] [--dns-mode M]",
      name: "modify",
      options: [
        ["--domain D", "Public primary domain (add/modify)."],
        ["--owner ORG", "Owning organization (add/modify; default = first org)."],
        ["--zone Z", "network.zone reference (add/modify; default = <env>)."],
        ["--display D", "displayName (add/modify)."],
        [
          "--dns-mode M",
          "domains.dnsMode: per-service (default, Caddy HTTP-01 per host)\n" +
            "                   or wildcard (one *.<primary> ACME cert) (add/modify).",
        ],
      ],
    },
    {
      usage: "delete <env> [--force]",
      name: "delete",
      options: [["--force", "add: overwrite existing; delete: override guard rails."]],
    },
    {
      usage: "reconcile <env> [--deep] [--apply]",
      name: "reconcile",
      options: [
        ["--deep", "reconcile: also reconcile every module consuming this env."],
        ["--apply", "reconcile: commit (default = preview / dry-run)."],
      ],
    },
  ],
  common: [
    ["--config-dir DIR", "Config root (default: $TAPPAAS_CONFIG or /home/tappaas/config)."],
    ["--json", "Machine-readable output (list/show)."],
  ],
  notes: [
    "Notes:\n" +
      "  add with no positional <env> seeds the minimal environment set (mgmt +\n" +
      "  the default <N> environment). --name <N> gives the default-env name explicitly\n" +
      "  (else it derives from site.json '.defaultEnvironment'); --domain sets the default env's\n" +
      "  domains.primary. With a positional <env> it creates that single environment.\n" +
      "  delete refuses to remove 'mgmt', the default <N> environment, or an env still\n" +
      "  consumed by deployed modules — unless --force.",
  ],
};
function usage(): void {
  info(renderHelp(HELP));
}

interface Opts {
  configDir: string;
  name?: string;
  domain?: string;
  owner?: string;
  zone?: string;
  display?: string;
  dnsMode?: "per-service" | "wildcard";
  schemaDir?: string;
  zones?: string;
  quiet: boolean;
  deep: boolean;
  apply: boolean;
  force: boolean;
  json: boolean;
  rest: string[];
}

export function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    quiet: false,
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
      case "--schema-dir":
        o.schemaDir = need("--schema-dir");
        break;
      case "--zones":
        o.zones = need("--zones");
        break;
      case "--quiet":
        o.quiet = true;
        break;
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
        // Reject ANY dash-prefixed unknown token, not just `--`. A misspelled
        // option (e.g. `-domain`, `--domian`) must error — never be silently
        // swallowed into `rest` and ignored (which made `modify --<typo>` report
        // "Updated" while dropping the flag). No single-dash short flags exist,
        // and option values are consumed by need() so they never reach here.
        if (a.startsWith("-")) die(`Unknown option: ${a}`);
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

// Human-readable single-environment summary (default `show` output). An aligned
// label/value block, mirroring `list`'s human default; the raw JSON document is
// available via `--json`. Optional fields are printed only when present.
export function formatEnvironmentHuman(env: Environment): string {
  const lines: string[] = [];
  lines.push(
    env.displayName && env.displayName !== env.name
      ? `${env.name}  —  ${env.displayName}`
      : env.name,
  );
  const row = (label: string, value: string): void =>
    void lines.push(`  ${label.padEnd(9)} ${value}`);
  row("owner", env.ownerOrg || "<unset>");
  row("zone", env.network?.zone ?? "<unset>");
  if (env.domains) {
    const d = env.domains;
    row("domain", (d.primary || "<unset>") + (d.dnsMode ? `  (dnsMode: ${d.dnsMode})` : ""));
    if (d.aliases && d.aliases.length) {
      row("aliases", d.aliases.join(", ") + (d.aliasMode ? `  (${d.aliasMode})` : ""));
    }
  }
  if (env.dataResidency) row("residency", env.dataResidency);
  if (env.backup) {
    const b = env.backup;
    const parts: string[] = [];
    if (b.retention) parts.push(`retention=${b.retention}`);
    if (b.residency) parts.push(`residency=${b.residency}`);
    if (b.schedule !== undefined && b.schedule !== null) parts.push(`schedule=${b.schedule}`);
    row("backup", parts.length ? parts.join(" ") : "(set)");
  }
  if (env.legal && env.legal.processor) row("legal", `processor=${env.legal.processor}`);
  return lines.join("\n");
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
  // Human output: an aligned field summary (raw JSON doc via --json).
  info(formatEnvironmentHuman(env));
}

// ── validate ──────────────────────────────────────────────────────────
// Native schema + reference gate (src/validate.ts interprets
// environment-fields.json in-process; validate-environment.sh is retired).
// Output shapes and exit semantics match the retired script.
function cmdValidate(opts: Opts): void {
  const report = runValidate({
    configDir: opts.configDir,
    target: opts.rest[0],
    schemaDir: opts.schemaDir,
    zonesFile: opts.zones,
  });
  if (!opts.quiet) {
    info(`Validating environments: ${report.target}`);
    info(`Using schema: ${report.schemaPath}`);
  }
  for (const w of report.warnings) warn(`VALIDATION: ${w}`);
  for (const e of report.errors) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
  info("");
  if (report.errors.length > 0) {
    die(
      `Environment validation failed: ${report.errors.length} error(s), ` +
        `${report.warnings.length} warning(s)`,
    );
  } else if (report.warnings.length > 0) {
    warn(`Environment validation passed with ${report.warnings.length} warning(s)`);
  } else if (!opts.quiet) {
    info(`${GN}Environment validation passed: all checks OK${CL}`);
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
  // No positional env ⇒ seed the minimal set (the create-minimal-environments.sh
  // bootstrap, now native — ADR-007 refactor Phase 8.1). --name passes the
  // default-env name <N> explicitly (the install.sh / migrate path, where site.json
  // may not carry it yet); without it the name derives from site.json '.defaultEnvironment'.
  if (!single) {
    const res = bootstrap({
      configDir: opts.configDir,
      name: opts.name,
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
  const name = single;
  const path = join(environmentsDir(opts.configDir), `${name}.json`);
  if (existsSync(path) && !opts.force) {
    die(`environment '${name}' already exists at ${path} (use --force to overwrite)`);
  }
  const display = opts.display ?? name.charAt(0).toUpperCase() + name.slice(1);
  // --owner default: the first organization under people/organizations/ (matches
  // the minimal-set bootstrap). Empty only when no org exists,
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
// default <N> environment = site.json '.defaultEnvironment'), and refuse when deployed modules
// still consume the env — UNLESS --force. The `add` minimal-set bootstrap is the
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
        `Refusing to delete the default environment '${name}' (= site.json '.defaultEnvironment'; use --force to override).`,
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

  return guarded(() => {
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
  });
}

// Entry point (only when run directly, not when imported by tests). The early
// parseOpts (config-dir for the module client's discovery root) can die() on a
// bad flag, so the WHOLE entry runs under guarded() — otherwise that die
// escapes as a raw DieError stack trace instead of the clean [Error] line
// (found by the deep gate of the ADR-007 post-implementation refactor).
if (require.main === module) {
  process.exit(
    guarded(() => {
      const argv = process.argv.slice(2);
      // Resolve config-dir early for the module client's discovery root.
      const opts = parseOpts(argv.slice(1));
      const net = new CliNetworkClient();
      const mod = new CliModuleClient(opts.configDir);
      return run(argv, net, mod);
    }),
  );
}
