// environment-manager — TAPPaaS Environment manager (ADR-007 P3, #3 port).
//
// Owns config/environments/<env>.json (CRUD + validate) and the reconcile
// cascade. `environment reconcile` triggers a network convergence by shelling
// out to network-manager — a SYSTEM-WIDE pass, not a per-environment one
// (#461); `--deep` additionally reconciles every module that consumes the
// environment (shell out to module-manager). NO plane or module logic is
// reimplemented — it is a thin orchestration boundary, exactly as
// identity-manager shells out to authentik-controller.
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
//   environment reconcile <env> [--deep] [--apply] [--skip-network]
//
// Exit codes: ok=0, error=1.

import {
  defaultConfigDir,
  environmentsDir,
  loadEnvironment,
  loadEnvironments,
  environmentZone,
  sharedZones,
  loadRefSources,
  OWN_ZONE_TYPES,
  ownZones,
  parseEnvironment,
  validateEnvironmentRefs,
  withBinding,
  writeEnvironment,
} from "./config";
import { bootstrap, firstOrg, resolveName } from "./bootstrap";
import { CliDnsTlsClient, CliModuleClient, CliNetworkClient, NetworkUnreachable } from "./clients";
import { applyPlan, computePlan } from "./reconcile";
import { runValidate } from "./validate";
import { DnsTlsClient, Environment, ModuleClient, NetworkClient, RefSources } from "./types";
import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { RD, GN, CL, die, guarded, info, warn } from "../../../lib/ts/src/cli";
import { existsSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";

// The two always-required bootstrap environments are protected from delete:
// 'mgmt' and the default <N> environment (= site.json '.defaultEnvironment'). The `add`
// minimal-set bootstrap (src/bootstrap.ts — the retired
// create-minimal-environments.sh, ported) is their single owner.
const RESERVED_MGMT = "mgmt";

const VERSION = "0.1.0";

export const HELP: HelpSpec = {
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
        "                          [--zone Z] [--create-zone] [--display D]\n" +
        "                          [--dns-mode M] [--force]", effect: { noPreview: "writes config/environments/<env>.json (with --create-zone also a zone); environment-manager reconcile <env> --apply makes it live" },
      name: "add",
      hidden: ["--dnsMode M"],
      options: [
        ["--name N", "Without <env>: the name of the site's default environment to seed (default: site.json .defaultEnvironment)."],
        ["--domain D", "The environment's public primary domain. Left out: no public domain (reached inside only)."],
        ["--owner ORG", "The organization that owns the environment (default: the first organization, by name)."],
        ["--zone Z", "The Service zone its modules run in (default: a zone named like the environment).\n" +
          "                   The zone is linked to the environment (network-manager bind)."],
        ["--create-zone", "Create that zone as a Service zone first if it does not exist, so one\n" +
          "                   command yields the environment and its zone. Off unless asked, so a\n" +
          "                   mistyped --zone cannot create a stray zone."],
        ["--display D", "The name people see (default: the environment's name, capitalised)."],
        [
          "--dns-mode M",
          "How its certificates are issued: per-service (default: Caddy gets one per host)\n" +
            "                   or wildcard (one *.<domain> certificate on the firewall).",
        ],
        ["--force", "Overwrite an environment that already exists."],
      ],
    },
    {
      usage: "modify <env> [--domain D] [--owner ORG] [--zone Z]\n" +
        "                          [--display D] [--dns-mode M]", effect: { noPreview: "writes config/environments/<env>.json; environment-manager reconcile <env> --apply makes it live" },
      name: "modify",
      hidden: ["--dnsMode M"],
      options: [
        ["--domain D", "The environment's public primary domain."],
        ["--owner ORG", "The organization that owns the environment."],
        ["--zone Z", "Move the environment to this Service zone: it is linked to the environment\n" +
          "                   and the old zone's link is cleared (network-manager bind)."],
        ["--display D", "The name people see."],
        [
          "--dns-mode M",
          "How its certificates are issued: per-service (Caddy gets one per host)\n" +
            "                   or wildcard (one *.<domain> certificate on the firewall).",
        ],
      ],
    },
    {
      usage: "delete <env> [--force] [--check]",
      name: "delete",
      options: [
        ["--force", "Delete even mgmt, the default environment, or one modules still use."],
        ["--check", "Show what would be removed; change nothing."],
      ],
    },
    {
      usage: "reconcile <env> [--deep] [--apply] [--skip-network]",
      name: "reconcile",
      options: [
        ["--deep", "Also reconcile every module in this environment."],
        ["--apply", "Make the changes (without it: a preview of what would change)."],
        [
          "--skip-network",
          "Leave out the site-wide network pass (the caller already ran it).",
        ],
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
  // ADR-014 D1: author the environment's Service zone in the same command.
  createZone: boolean;
  display?: string;
  dnsMode?: "per-service" | "wildcard";
  schemaDir?: string;
  zones?: string;
  quiet: boolean;
  deep: boolean;
  apply: boolean;
  skipNetwork: boolean;
  force: boolean;
  check: boolean;
  json: boolean;
  rest: string[];
}

export function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    quiet: false,
    deep: false,
    apply: false,
    skipNetwork: false,
    force: false,
    check: false,
    createZone: false,
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
      case "--create-zone":
        o.createZone = true;
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
      case "--skip-network":
        o.skipNetwork = true;
        break;
      case "--force":
        o.force = true;
        break;
      case "--check":
        o.check = true;
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
  // Human output: one environment name per line (zone in brackets). The zone
  // is the one naming the environment in zones.json (#865).
  const refs = loadRefSources(opts.configDir);
  for (const n of names) {
    const shared = sharedZones(refs.zones, n);
    info(`${n}\t(zone ${environmentZone(refs, n) ?? "?"}${shared.length ? `; shared ${shared.join(", ")}` : ""})`);
  }
}

// Human-readable single-environment summary (default `show` output). An aligned
// label/value block, mirroring `list`'s human default; the raw JSON document is
// available via `--json`. Optional fields are printed only when present.
export function formatEnvironmentHuman(env: Environment, zone?: string, shared: string[] = []): string {
  const lines: string[] = [];
  lines.push(
    env.displayName && env.displayName !== env.name
      ? `${env.name}  —  ${env.displayName}`
      : env.name,
  );
  const row = (label: string, value: string): void =>
    void lines.push(`  ${label.padEnd(9)} ${value}`);
  row("owner", env.ownerOrg || "<unset>");
  row("zone", zone ?? "<unset>");
  // Shared service zones (#876): also a place for its modules, its own zone none.
  if (shared.length) row("shared", shared.join(", "));
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
  const refs = loadRefSources(opts.configDir);
  info(formatEnvironmentHuman(env, environmentZone(refs, name), sharedZones(refs.zones, name)));
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
function assertValid(env: Environment, raw: unknown, refs: RefSources): void {
  const res = validateEnvironmentRefs(env, raw, refs);
  for (const w of res.warnings) warn(`VALIDATION: ${w}`);
  if (res.errors.length > 0) {
    for (const e of res.errors) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
    die(`Refusing to write '${env.name}': ${res.errors.length} validation error(s)`);
  }
}

// The zone an add/modify --zone links the environment to must exist (unless it
// is about to be created), be a Service zone (the Management zone, for mgmt),
// and not already be another environment's zone. Dies otherwise.
function checkTargetZone(refs: RefSources, zone: string, env: string, creating: boolean): void {
  const z = refs.zones.get(zone);
  if (!z) {
    if (creating) return;
    die(
      `zone '${zone}' does not exist — pass --create-zone to author it as the environment's ` +
        `Service zone, or name an existing Service zone with --zone`,
    );
  }
  if (!OWN_ZONE_TYPES.has(z.type ?? "")) {
    die(
      `zone '${zone}' is a ${z.type ?? "untyped"} zone, not a Service zone. An environment's zone is ` +
        `a service segment; a client/IoT zone serves one (\`network-manager bind ${zone} --environment ${env}\`) — pick another --zone.`,
    );
  }
  if (z.environment && z.environment !== env) {
    die(`zone '${zone}' is already environment '${z.environment}''s zone — pick another --zone`);
  }
  if (z.shared) {
    die(
      `zone '${zone}' is a shared service zone (serves ${z.environments.join(", ") || "none"}) — the own zone of ` +
        `no environment; pick another --zone (\`network-manager bind ${zone} --unbind --environment <env> --own\` ` +
        `makes a shared zone with one environment left that environment's own)`,
    );
  }
}

// ── add ───────────────────────────────────────────────────────────────
function cmdAdd(opts: Opts, net: NetworkClient): void {
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
  // --owner default: the first organization under identities/organizations/ (matches
  // the minimal-set bootstrap). Empty only when no org exists,
  // in which case the pre-write validation flags the missing ownerOrg.
  const owner = opts.owner ?? firstOrg(opts.configDir);
  const env: Environment = {
    name,
    displayName: display,
    ownerOrg: owner,
  };
  const zone = opts.zone ?? name;
  if (opts.domain || opts.dnsMode) {
    env.domains = {
      primary: opts.domain ?? "",
      ...(opts.dnsMode ? { dnsMode: opts.dnsMode } : {}),
    };
  }

  // ── The environment's zone (ADR-014 D1, #865) ──
  // The zone names the environment, so the environment file is written first
  // and network-manager then links the zone to it — with --create-zone, by
  // authoring it as a Service zone (opt-in by design, ADR-014 resolved choice
  // #1: default-on would let a typo'd --zone silently mint a stray zone). The
  // checks run before anything is written, against the refs as they will be;
  // if network-manager then fails, the environment file is put back.
  //
  // network-manager stays the sole writer of zones.json — this shells across
  // the existing clients.ts seam rather than editing zones directly.
  const refs = loadRefSources(opts.configDir);
  const creating = opts.createZone && refs.zonesAvailable && !refs.zones.has(zone);
  if (refs.zonesAvailable) {
    checkTargetZone(refs, zone, name, opts.createZone);
    if (opts.createZone && !creating) info(`Zone '${zone}' already exists — left untouched.`);
  }
  assertValid(env, env, refs.zonesAvailable ? withBinding(refs, zone, name) : refs);
  const before = existsSync(path) ? readFileSync(path, "utf8") : null;
  const written = writeEnvironment(opts.configDir, env);
  info(`${GN}Wrote ${written}${CL}`);
  if (refs.zonesAvailable && refs.zones.get(zone)?.environment !== name) {
    try {
      if (creating) {
        net.createServiceZone(zone, name);
        info(`${GN}Authored service zone '${zone}'${CL} (network-manager add --archetype service --environment ${name})`);
      } else {
        net.bindZone(zone, name);
        info(`${GN}Zone '${zone}' is environment '${name}''s zone${CL} (network-manager bind)`);
      }
    } catch (e) {
      if (before === null) unlinkSync(written);
      else writeFileSync(written, before);
      const why = e instanceof Error ? e.message : String(e);
      die(`could not ${creating ? "author" : "link"} zone '${zone}': ${why} — ${written} ${before === null ? "removed" : "restored"}`);
    }
  }
  if (creating) {
    info("");
    info("  To converge the new zone on the planes, run:");
    info("    network-manager reconcile --apply");
  }
}

// ── modify ────────────────────────────────────────────────────────────
function cmdModify(opts: Opts, net: NetworkClient): void {
  const name = opts.rest[0];
  if (!name) die("modify: expected <env>");
  const path = join(environmentsDir(opts.configDir), `${name}.json`);
  if (!existsSync(path)) die(`environment '${name}' not found at ${path}`);
  // Re-parse the RAW file so we preserve fields not modeled by the CLI flags.
  const raw = JSON.parse(readFileSync(path, "utf8"));
  const env = parseEnvironment(raw, name);
  if (opts.display) env.displayName = opts.display;
  if (opts.owner) env.ownerOrg = opts.owner;
  if (opts.domain || opts.dnsMode) {
    env.domains = {
      ...(env.domains ?? { primary: "" }),
      ...(opts.domain ? { primary: opts.domain } : {}),
      ...(opts.dnsMode ? { dnsMode: opts.dnsMode } : {}),
    };
  }
  // --zone moves the environment to another Service zone (#865): the new zone
  // names it and the old one no longer does — both written by network-manager.
  const refs = loadRefSources(opts.configDir);
  const zone = opts.zone;
  const moving = zone !== undefined && refs.zones.get(zone)?.environment !== name;
  if (zone !== undefined) {
    if (!refs.zonesAvailable) die(`modify --zone: zones.json not available under ${opts.configDir}`);
    checkTargetZone(refs, zone, name, false);
  }
  assertValid(env, env, zone !== undefined ? withBinding(refs, zone, name) : refs);
  const written = writeEnvironment(opts.configDir, env);
  info(`${GN}Updated ${written}${CL}`);
  if (moving) {
    const old = ownZones(refs.zones, name);
    try {
      for (const o of old) net.unbindZone(o);
      net.bindZone(zone, name);
    } catch (e) {
      // Put the old link back so the environment is not left without a zone.
      for (const o of old) {
        try {
          net.bindZone(o, name);
        } catch {
          /* reported below */
        }
      }
      die(`could not move environment '${name}' to zone '${zone}': ${e instanceof Error ? e.message : String(e)}`);
    }
    info(`${GN}Zone '${zone}' is environment '${name}''s zone${CL}${old.length ? ` (was ${old.join(", ")})` : ""}`);
    info("  To apply on the planes, run:");
    info("    network-manager reconcile --apply");
  }
}

// ── delete ────────────────────────────────────────────────────────────
// Guard rails: refuse to delete the bootstrap environments ('mgmt' and the
// default <N> environment = site.json '.defaultEnvironment'), and refuse when deployed modules
// still consume the env — UNLESS --force. The `add` minimal-set bootstrap is the
// single owner of the bootstrap files, so they are never casually removed.
function cmdDelete(opts: Opts, net: NetworkClient, mod: ModuleClient, dt: DnsTlsClient): void {
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

  // #790: what add / reconcile / acme-setup created for this environment goes
  // with it — its wildcard override, its cert-refids entry, its ACME certificate
  // and Trust certificate — and nothing another environment still uses.
  let domain: string | undefined;
  try {
    const env = JSON.parse(readFileSync(path, "utf8")) as Environment;
    domain = env.domains?.primary;
  } catch {
    warn(`could not read ${path} — its domain's DNS override and certificate are left for you`);
  }
  const sharedWith = domain
    ? readdirSync(environmentsDir(opts.configDir))
        .filter((f) => f.endsWith(".json") && f !== `${name}.json`)
        .filter((f) => {
          try {
            const o = JSON.parse(readFileSync(join(environmentsDir(opts.configDir), f), "utf8")) as Environment;
            return o.domains?.primary === domain || (o.domains?.aliases ?? []).includes(domain!);
          } catch {
            return false;
          }
        })
        .map((f) => f.replace(/\.json$/, ""))
    : [];
  const ownsDomain = domain !== undefined && sharedWith.length === 0;
  const dry = opts.check;
  const say = (m: string) => info(dry ? `  [check] would ${m}` : `  ${m}`);
  const leftover: string[] = [];

  if (dry) info(`delete '${name}' [check] — nothing is changed`);
  if (!dry) unlinkSync(path);
  say(`remove ${path}`);

  // The zones naming the environment lose that link (#865): its own zone stays
  // as a zone, and the zones that served it stop reaching it.
  const refs = loadRefSources(opts.configDir);
  for (const [z, l] of refs.zones) {
    if (!l.environments.includes(name)) continue;
    try {
      // A zone serving several environments keeps the others.
      if (!dry) net.unbindZone(z, l.environments.length > 1 ? name : undefined);
      say(`clear zone '${z}''s link to '${name}'`);
    } catch (e) {
      leftover.push(`zone '${z}' still names '${name}' (network-manager bind ${z} --unbind): ${(e as Error).message}`);
    }
  }

  if (domain && !ownsDomain) {
    info(`  ${domain} is also used by ${sharedWith.join(", ")} — its DNS override and certificate stay`);
  }
  if (ownsDomain) {
    try {
      const n = dt.removeWildcard(domain!, dry);
      if (n > 0) say(`remove ${n} Unbound override(s) *.${domain}`);
    } catch (e) {
      leftover.push(`Unbound override *.${domain} (unbound-manager delete '*' ${domain}): ${(e as Error).message}`);
    }
    try {
      for (const l of dt.deleteWildcardCert(domain!, dry)) {
        if (!l.startsWith("no certificate")) info(`  ${l}`);
      }
    } catch (e) {
      leftover.push(`ACME certificate *.${domain} (acme-manager delete --domain ${domain}): ${(e as Error).message}`);
    }
  }
  try {
    if (dt.forgetCertRefid(name, dry)) say(`drop '${name}' from cert-refids.json`);
  } catch (e) {
    leftover.push(`cert-refids.json['${name}']: ${(e as Error).message}`);
  }

  for (const l of leftover) warn(`  NOT removed — ${l}`);
  if (domain && ownsDomain) {
    info(`  Yours to remove at your DNS provider: the public records for ${domain} and *.${domain} (#383).`);
  }
  if (!dry) info(`${GN}Deleted environment '${name}'${CL}`);
}

// ── reconcile ─────────────────────────────────────────────────────────
function cmdReconcile(opts: Opts, net: NetworkClient, mod: ModuleClient, dt: DnsTlsClient): number {
  const name = opts.rest[0];
  if (!name) die("reconcile: expected <env>");
  const env = loadEnvironment(opts.configDir, name);
  if (!env) die(`environment '${name}' not found in ${environmentsDir(opts.configDir)}`);

  // Resolve the org to adopt if this environment's ownerOrg is empty. Preference
  // order: an explicit --owner, then site.json '.defaultEnvironment' when an org
  // of that name exists (the ADR-007 convention — the default org and the default
  // environment share a name, #426), then the sole organization if there is only
  // one. With several orgs and no signal we resolve nothing and let computePlan
  // warn, rather than guessing an ownership claim.
  // The default environment (site.json .defaultEnvironment): its domain feeds
  // the identity module's Authentik self-config, so reconcile identity too (#474).
  const defaultEnvName = resolveName(opts.configDir);

  let ownerOrgCandidate: string | undefined;
  if (!env.ownerOrg) {
    const { orgNames } = loadRefSources(opts.configDir);
    if (opts.owner && orgNames.has(opts.owner)) ownerOrgCandidate = opts.owner;
    else if (defaultEnvName && orgNames.has(defaultEnvName)) ownerOrgCandidate = defaultEnvName;
    else if (orgNames.size === 1) ownerOrgCandidate = firstOrg(opts.configDir);
  }

  let plan;
  try {
    plan = computePlan(env, net, mod, {
      deep: opts.deep,
      skipNetwork: opts.skipNetwork,
      ownerOrgCandidate,
      isDefaultEnv: !!defaultEnvName && name === defaultEnvName,
    }, dt);
  } catch (e) {
    // A manager binary missing on PATH (network-manager, unbound-manager,
    // acme-manager) — an environment fault, reported as a clean line.
    if (e instanceof NetworkUnreachable) die(`a manager binary is unreachable: ${e.message}`);
    throw e;
  }

  const planErrors = plan.errors ?? [];
  info(
    `Reconcile environment '${name}' (zone '${net.environmentZones(name).join(", ") || "none"}'${opts.deep ? ", --deep" : ""}): ` +
      `${plan.actions.length} action(s), ${plan.warnings.length} warning(s)` +
      (planErrors.length > 0 ? `, ${RD}${planErrors.length} error(s)${CL}` : ""),
  );
  for (const w of plan.warnings) warn(w);
  // ADR-014 D1: a hard fault in the plan is refused in BOTH preview and apply —
  // an environment with two zones, or none and a name clash, is the operator's
  // to fix, never "fixed" by minting a zone underneath it.
  if (planErrors.length > 0) {
    for (const e of planErrors) warn(e);
    die(
      `environment '${name}' cannot be reconciled: ${planErrors.length} configuration error(s) — ` +
        `fix the environment and re-run`,
    );
  }
  // The scope tag is load-bearing (#461): it is what stops an operator reading
  // the system-wide network pass as an environment-sized one.
  for (const a of plan.actions) {
    info(`  ${opts.apply ? "" : "[preview] "}${a.kind} [${a.scope}]: ${a.target}`);
  }
  for (const n of plan.notes) info(`  note: ${n}`);

  if (!opts.apply) {
    info("");
    info("Preview only (no --apply): no changes made.");
    return 0;
  }
  try {
    const res = applyPlan(env, plan, net, mod, opts.apply, (e) =>
      writeEnvironment(opts.configDir, e), dt
    );
    info("");
    // A module that ran and failed is named here rather than propagated as a
    // raw error (#454); the rest of the cascade already ran.
    for (const f of res.failures) {
      warn(`module '${f.target}' failed to reconcile: ${f.error}`);
    }
    if (res.failures.length > 0) {
      info(
        `${RD}Reconciled ${res.applied} target(s); ${res.failures.length} module(s) failed: ` +
          `${res.failures.map((f) => f.target).join(", ")}.${CL}`,
      );
      return 1;
    }
    info(`${GN}Reconciled ${res.applied} target(s).${CL}`);
    return 0;
  } catch (e) {
    if (e instanceof NetworkUnreachable) die(`reconcile failed: ${e.message}`);
    throw e;
  }
}

export function run(argv: string[], net: NetworkClient, mod: ModuleClient, dt: DnsTlsClient): number {
  if (argv.length === 0) {
    usage();
    return 0;
  }
  // #644: --help in any position prints that verb's help and runs nothing; an
  // option the verb does not take is refused.
  const gate = checkArgs(HELP, argv);
  if (gate !== undefined) return gate;
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
        cmdAdd(opts, net);
        return 0;
      case "modify":
        cmdModify(opts, net);
        return 0;
      case "delete":
        cmdDelete(opts, net, mod, dt);
        return 0;
      case "reconcile":
        return cmdReconcile(opts, net, mod, dt);
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
      // The argument gate first: the early parseOpts below must not see --help.
      const gate = argv.length > 0 ? checkArgs(HELP, argv) : undefined;
      if (gate !== undefined) return gate;
      // Resolve config-dir early for the module client's discovery root.
      const opts = parseOpts(argv.slice(1));
      const net = new CliNetworkClient(opts.configDir);
      const mod = new CliModuleClient(opts.configDir);
      const dt = new CliDnsTlsClient(opts.configDir);
      return run(argv, net, mod, dt);
    }),
  );
}
