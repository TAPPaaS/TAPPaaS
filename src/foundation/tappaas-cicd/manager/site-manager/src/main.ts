// site-manager — TAPPaaS Site manager (ADR-007 P2, all-managers-to-TS #3).
//
// The Site is the umbrella over a whole TAPPaaS installation (site-wide
// identity, location, hardware nodes + storage pools, backup, update schedule,
// module repositories). It is a SINGLETON: exactly one config/site.json.
//
// Entity model (the entity is the first arg — mirrors network-manager's
// `network-manager zone <verb>`):
//   site       (SINGLETON) → show | modify
//   node                   → list | add | delete
//   repository             → list | add | delete | reconcile
// Plus top-level lifecycle verbs:
//   add        create the site singleton (= create-site.sh: cluster discovery)
//   validate   validate site.json well-formed (= validate-site.sh)
//   reconcile  converge config → live (site.json + repositories;
//              with --deep: cascade to people + network + environments)
//
// TS owns config CRUD (site modify, node …) + validate + reconcile; the heavy
// git/cluster I/O stays in the still-live bash tools, invoked as thin
// delegations: `add` → create-site.sh; `repository add`/`delete` →
// repository.sh; `validate` → validate-site.sh. The transitional migration
// scripts (migrate-configuration*) are NOT ported and NOT wired here.
//
// Exit codes: ok=0, error=1.

import { defaultConfigDir, defaultSchemaDir, loadRaw, loadSite, writeSite } from "./config";
import { CliSiteClient } from "./client";
import { applyPlan, computePlan } from "./reconcile";
import { Site, SiteClient, SiteNode } from "./types";

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
  info(`site-manager ${VERSION} — TAPPaaS Site manager (ADR-007 P2)

Usage:
  site-manager site show [--json] [--config-dir DIR]
  site-manager site modify --<field> <value> [...] [--config-dir DIR]
  site-manager node list [--json] [--config-dir DIR]
  site-manager node add --name <N> [--pool <p> ...] [--config-dir DIR]
  site-manager node delete <name> [--config-dir DIR]
  site-manager repository list [--json] [--config-dir DIR]
  site-manager repository add <url> [--branch <b>] [--managed full|tracked] [--catalog <p>]
  site-manager repository delete <name> [--force] [--config-dir DIR]
  site-manager repository reconcile [--apply] [--config-dir DIR]
  site-manager add --name <N> [create-site options]
  site-manager validate [FILE] [--schema-dir PATH] [--config-dir DIR]
  site-manager reconcile [--apply] [--deep] [--config-dir DIR]

Owns config/site.json (the Site singleton). add (create-site.sh), repository
add/delete (repository.sh) are thin delegations to the still-live bash tools;
validate wraps validate-site.sh. TS owns config CRUD + validate + reconcile.

Options:
  --config-dir DIR   Config root (default: \$TAPPAAS_CONFIG or /home/tappaas/config).
  --json             Machine-readable output for list/show.
  --apply            reconcile: commit (default is preview).
  --deep             reconcile: cascade people → network → (every) environment.
  --force            repository delete: forward to repository.sh remove --force.
  -h, --help         Show this help.

site modify fields:
  --displayName --owner --email --automaticReboot --snapshotRetention
  --backupTarget --backupOffsite
  --locationCountry --locationTimezone --locationLocale
  --networkIsp --networkPublicIp`);
}

// ── option parsing ─────────────────────────────────────────────────────
interface Opts {
  configDir: string;
  siteFile?: string;
  schemaDir: string;
  apply: boolean;
  deep: boolean;
  force: boolean;
  json: boolean;
  // generic --key value capture for `site modify` / `node add` / `repository add`.
  flags: Map<string, string>;
  boolFlags: Set<string>;
  rest: string[];
}

// Flags that take NO value (everything else with a value is captured generically).
const NOARG = new Set(["--apply", "--deep", "--force", "--json"]);

function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    schemaDir: defaultSchemaDir(),
    apply: false,
    deep: false,
    force: false,
    json: false,
    flags: new Map(),
    boolFlags: new Set(),
    rest: [],
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      o.configDir = v;
      i++;
    } else if (a === "--schema-dir") {
      const v = args[i + 1];
      if (!v) die("--schema-dir requires a path argument");
      o.schemaDir = v;
      i++;
    } else if (a === "--apply") {
      o.apply = true;
    } else if (a === "--deep") {
      o.deep = true;
    } else if (a === "--force") {
      o.force = true;
    } else if (a === "--json") {
      o.json = true;
    } else if (a.startsWith("--")) {
      // generic flag. If the next token is a value (not another flag), capture it.
      const next = args[i + 1];
      if (NOARG.has(a) || next === undefined || next.startsWith("--")) {
        o.boolFlags.add(a);
      } else {
        // allow repeated --pool: store last; node add reads rest for pools.
        o.flags.set(a, next);
        i++;
      }
    } else {
      o.rest.push(a);
    }
  }
  return o;
}

function siteFileOf(o: Opts): string {
  return o.siteFile ?? `${o.configDir.replace(/\/$/, "")}/site.json`;
}

// ── `site` (singleton) ─────────────────────────────────────────────────
function cmdSite(o: Opts): void {
  const sub = o.rest[0];
  if (!sub) die("site: expected 'show' or 'modify'");
  const siteFile = siteFileOf(o);

  if (sub === "show") {
    // The singleton in detail. Always structured; --json accepted for symmetry
    // (the show output is JSON either way).
    const raw = loadRaw(siteFile);
    if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
    info(JSON.stringify(raw, null, 2));
    return;
  }

  if (sub === "modify") {
    const raw = loadRaw(siteFile);
    if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
    let changed = 0;
    // The approved editable surface: scalar site-wide fields, mapped to schema
    // paths. The discovery-derived hardware.nodes[] and the repositories/
    // environments/organizations lists are NOT modifiable here — each has its
    // own CRUD (node …, repository …) or its own manager.
    const setStr = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      setDeep(raw, path, v);
      changed++;
    };
    const setBool = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      if (v !== "true" && v !== "false") die(`${flag} must be true|false`);
      setDeep(raw, path, v === "true");
      changed++;
    };
    const setInt = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      const n = parseInt(v, 10);
      if (!Number.isInteger(n)) die(`${flag} must be an integer`);
      setDeep(raw, path, n);
      changed++;
    };

    setStr("--displayName", ["displayName"]);
    setStr("--owner", ["owner"]);
    setStr("--email", ["email"]);
    setBool("--automaticReboot", ["automaticReboot"]);
    setInt("--snapshotRetention", ["snapshotRetention"]);
    setStr("--backupTarget", ["backup", "target"]);
    setStr("--backupOffsite", ["backup", "offsite"]);
    setStr("--locationCountry", ["location", "country"]);
    setStr("--locationTimezone", ["location", "timezone"]);
    setStr("--locationLocale", ["location", "locale"]);
    setStr("--networkIsp", ["network", "isp"]);
    setStr("--networkPublicIp", ["network", "publicIp"]);

    if (changed === 0) die("site modify: no recognised --<field> given (see --help)");
    writeSite(siteFile, raw);
    info(`${GN}✓${CL} site.json updated (${changed} field(s)) — run 'validate' to confirm`);
    return;
  }

  die(`site ${sub}: unknown subcommand (expected 'show' | 'modify')`);
}

// Set raw[path...] = value, creating intermediate objects.
function setDeep(obj: Record<string, unknown>, path: string[], value: unknown): void {
  let cur = obj;
  for (let i = 0; i < path.length - 1; i++) {
    const k = path[i];
    if (typeof cur[k] !== "object" || cur[k] === null) cur[k] = {};
    cur = cur[k] as Record<string, unknown>;
  }
  cur[path[path.length - 1]] = value;
}

// ── `node` CRUD (hardware.nodes[]) ─────────────────────────────────────
function cmdNode(o: Opts): void {
  const sub = o.rest[0];
  if (!sub) die("node: expected 'list' | 'add' | 'delete'");
  const siteFile = siteFileOf(o);

  if (sub === "list") {
    const site: Site = loadSite(siteFile);
    if (o.json) {
      info(JSON.stringify(site.hardware.nodes, null, 2));
    } else if (site.hardware.nodes.length === 0) {
      info("(no nodes)");
    } else {
      for (const n of site.hardware.nodes) {
        info(`${n.name}\t[${n.storagePools.join(", ")}]`);
      }
    }
    return;
  }

  if (sub === "add") {
    const name = o.flags.get("--name") ?? o.rest[1];
    if (!name) die("node add: expected --name <N> (or positional name)");
    if (!/^[A-Za-z0-9_-]+$/.test(name)) die(`node add: invalid name '${name}'`);
    // --pool may be given multiple times; parseOpts keeps only the last, so we
    // also accept trailing positionals after the name as pools.
    const pools = collectPools(o, name);
    const raw = loadRaw(siteFile);
    if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
    const hw = (raw.hardware ?? (raw.hardware = {})) as Record<string, unknown>;
    const nodes = (Array.isArray(hw.nodes) ? hw.nodes : (hw.nodes = [])) as SiteNode[];
    if (nodes.some((n) => n.name === name)) die(`node '${name}' already exists`);
    nodes.push({ name, storagePools: pools });
    writeSite(siteFile, raw);
    info(`${GN}✓${CL} node '${name}' added (pools: ${pools.join(", ") || "none"})`);
    return;
  }

  if (sub === "delete") {
    const name = o.rest[1];
    if (!name) die("node delete: expected <name>");
    const raw = loadRaw(siteFile);
    const hw = (raw.hardware ?? {}) as Record<string, unknown>;
    const nodes = (Array.isArray(hw.nodes) ? hw.nodes : []) as SiteNode[];
    const next = nodes.filter((n) => n.name !== name);
    if (next.length === nodes.length) die(`node '${name}' not found`);
    hw.nodes = next;
    raw.hardware = hw;
    writeSite(siteFile, raw);
    info(`${GN}✓${CL} node '${name}' deleted`);
    return;
  }

  die(`node ${sub}: unknown subcommand`);
}

function collectPools(o: Opts, name: string): string[] {
  const pools: string[] = [];
  const single = o.flags.get("--pool");
  if (single) pools.push(single);
  // positionals after the node name (rest[0]=node, rest[1]=name?) are pools.
  for (const r of o.rest.slice(1)) {
    if (r !== name) pools.push(r);
  }
  return Array.from(new Set(pools));
}

// ── `repository` CRUD + reconcile ──────────────────────────────────────
function cmdRepository(o: Opts, client: SiteClient): void {
  const sub = o.rest[0];
  if (!sub) die("repository: expected 'list' | 'add' | 'delete' | 'reconcile'");
  const siteFile = siteFileOf(o);

  if (sub === "list") {
    const site = loadSite(siteFile);
    if (o.json) {
      info(JSON.stringify(site.repositories, null, 2));
    } else if (site.repositories.length === 0) {
      info("(no repositories)");
    } else {
      for (const r of site.repositories) {
        info(`${r.name}\t${r.url}\t${r.branch ?? "stable"}\t${r.managed ?? "full"}`);
      }
    }
    return;
  }

  if (sub === "add") {
    // Thin delegation: repository.sh still owns URL validation, git clone +
    // checkout, catalog validation, and the VMID/name conflict scan, and writes
    // the site.json .repositories entry. We forward the args verbatim
    // (<url> [--branch b] [--managed full|tracked] [--catalog p]).
    const rc = client.repositoryAdd(o.rest.slice(1));
    if (rc !== 0) throw new DieError(`repository.sh add exited ${rc}`);
    return;
  }

  if (sub === "delete") {
    const name = o.rest[1];
    if (!name) die("repository delete: expected <name>");
    // Thin delegation: repository.sh remove checks installed-module dependents,
    // rm -rf's the clone, and edits site.json. --force forwards through.
    const rc = client.repositoryRemove(name, o.force);
    if (rc !== 0) throw new DieError(`repository.sh remove exited ${rc}`);
    return;
  }

  if (sub === "reconcile") {
    // repository reconcile = converge repositories[] to live clones (the (1)
    // own-concern half of `reconcile`, scoped to repos). Reuses the engine with
    // deep=false; we still emit only the repo actions.
    const site = loadSite(siteFile);
    const plan = computePlan(site, client, { deep: false, apply: o.apply, siteFile });
    printPlan(plan, o.apply);
    if (o.apply && plan.actions.length > 0) {
      const n = applyPlan(client, plan);
      info(`${GN}Applied ${n} action(s).${CL}`);
    }
    return;
  }

  die(`repository ${sub}: unknown subcommand`);
}

// ── top-level lifecycle verbs ──────────────────────────────────────────

// `validate` — validate site.json (= validate-site.sh).
function cmdValidate(o: Opts, client: SiteClient): void {
  const siteFile = o.rest[0] ?? siteFileOf(o);
  const errs = client.validateSite(siteFile);
  if (errs.length === 0) {
    info(`${GN}✓${CL} site.json valid: ${siteFile}`);
    return;
  }
  for (const e of errs) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
  die(`site.json has ${errs.length} validation error(s)`);
}

// `reconcile` — converge site config → live (+ --deep cascade).
function cmdReconcile(o: Opts, client: SiteClient): void {
  const siteFile = siteFileOf(o);
  const site = loadSite(siteFile);
  const plan = computePlan(site, client, { deep: o.deep, apply: o.apply, siteFile });
  printPlan(plan, o.apply);
  if (o.apply && plan.actions.length > 0) {
    const n = applyPlan(client, plan);
    info("");
    info(`${GN}Applied ${n} action(s).${CL}`);
  }
}

function printPlan(plan: { actions: { kind: string; target: string }[]; warnings: string[] }, apply: boolean): void {
  info("");
  info(`Plan: ${plan.actions.length} action(s), ${plan.warnings.length} warning(s)`);
  for (const w of plan.warnings) warn(w);
  for (const a of plan.actions) info(`  ${apply ? "" : "[preview] would "}${a.kind}: ${a.target}`);
  if (!apply) {
    info("");
    info("(preview — pass --apply to commit)");
  } else if (plan.actions.length === 0) {
    info(`${GN}Nothing to do — already converged.${CL}`);
  }
}

// `add` — create the site singleton (= create-site.sh). Thin delegation: the
// cluster-discovery write (ssh pvesh node/pool discovery, tz/locale detection,
// version-from-git, Proxmox email discovery, force-preserve-on-rerun) stays in
// create-site.sh. We forward the args verbatim so its full flag set
// (--name/--domain/--branch/--upstream-git/--email/--primary-node/--schedule/
// --weekday/--hour/--config-dir/--force) keeps working unchanged.
function cmdAdd(args: string[], client: SiteClient): void {
  const rc = client.createSite(args);
  if (rc !== 0) throw new DieError(`create-site.sh exited ${rc}`);
}

// ── dispatch ───────────────────────────────────────────────────────────
export function run(argv: string[], client: SiteClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  const cmd = argv[0];
  const o = parseOpts(argv.slice(1));

  try {
    switch (cmd) {
      case "site":
        cmdSite(o);
        return 0;
      case "node":
        cmdNode(o);
        return 0;
      case "repository":
      case "repo":
        cmdRepository(o, client);
        return 0;
      case "add":
        // create-site.sh has its own flag set — forward raw args, not parsed.
        cmdAdd(argv.slice(1), client);
        return 0;
      case "validate":
        cmdValidate(o, client);
        return 0;
      case "reconcile":
        cmdReconcile(o, client);
        return 0;
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  } catch (e) {
    if (e instanceof DieError) return 1;
    if (e instanceof Error) {
      console.error(`${RD}[Error]${CL} ${e.message}`);
      return 1;
    }
    throw e;
  }
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const client = new CliSiteClient();
  process.exit(run(process.argv.slice(2), client));
}
