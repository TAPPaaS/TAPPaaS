// people-manager — TAPPaaS People → Authentik reconcile manager (ADR-007 P1).
//
// Holds the people→Authentik RECONCILE LOGIC and calls the identity-controller
// PRIMITIVES (the `authentik-manager` CLI, S2b-2) over a thin spawnSync FFI.
// NO Authentik HTTP is reimplemented here — see src/primitives.ts.
//
// Commands:
//   people-manager reconcile [--dry-run] [--config-dir DIR]   (alias: sync, deprecated)
//   people-manager role|org|group|user list|get [<name>] [--config-dir DIR]
//
// Exit codes: ok=0, error=1.

import { defaultConfigDir, loadPeople, validateRefs } from "./config";
import {
  EntityError,
  addEntity,
  deleteEntity,
  modifyEntity,
  parseFieldArgs,
} from "./entity";
import { CliPrimitiveClient, AuthentikUnreachable } from "./primitives";
import { applyPlan, computePlan, snapshot } from "./reconcile";
import { PeopleModel, PrimitiveClient } from "./types";

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
  info(`people-manager ${VERSION} — TAPPaaS People → Authentik manager

Usage:
  people-manager reconcile [--dry-run] [--config-dir DIR]   (alias: sync, deprecated)
  people-manager validate  [--config-dir DIR]
  people-manager <kind> list                       [--config-dir DIR]
  people-manager <kind> show   <name>              [--config-dir DIR]   (alias: get, deprecated)
  people-manager <kind> add    <name> [field flags] [--force]
  people-manager <kind> modify <name> [field flags]
  people-manager <kind> delete <name> [--force]

  where <kind> is one of: role | org (alias organization) | group | user

Field flags (write the validated config; Authentik is NOT touched):
  role:  --displayName V  --description V
  org:   --displayName V  --type V  --owner USER  --parentOrg ORG
  group: --displayName V  --type V  --ownerOrg ORG  --roles "a,b"
         --add-roles R  --remove-roles R
  user:  --displayName V  --email ADDR  --state planned|active|suspended|terminated
         --roles "a,b"  --groups "g1,g2"
         --add-roles R --remove-roles R  --add-groups G --remove-groups G

Options:
  --dry-run        Compute + print the plan; make NO changes to Authentik.
  --force          add: overwrite an existing entity; delete: ignore ref guard.
  --config-dir DIR People directory (default: \$TAPPAAS_CONFIG/people).
  -h, --help       Show this help.

After a successful add/modify/delete, run 'people-manager reconcile' to push
the change to the identity service. Writes never call Authentik directly.`);
}

// Pull --config-dir / --dry-run out of an arg list; return the rest.
interface Opts {
  configDir: string;
  dryRun: boolean;
  rest: string[];
}
function parseOpts(args: string[]): Opts {
  let configDir = defaultConfigDir();
  let dryRun = false;
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--dry-run") {
      dryRun = true;
    } else if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      configDir = v;
      i++;
    } else {
      rest.push(a);
    }
  }
  return { configDir, dryRun, rest };
}

function loadValidated(configDir: string): PeopleModel {
  const model = loadPeople(configDir);
  const errs = validateRefs(model);
  if (errs.length > 0) {
    for (const e of errs) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
    die(`People config has ${errs.length} reference error(s) — refusing to sync`);
  }
  return model;
}

// `validate` — load config/people/ and check reference integrity (the same
// validateRefs gate cmdSync runs), but report-only: no identity service calls.
// Exit 0 = valid, 1 = reference errors. (ADR-007 #4 verb convention.)
function cmdValidate(opts: Opts): number {
  const model = loadPeople(opts.configDir);
  const errs = validateRefs(model);
  if (errs.length > 0) {
    for (const e of errs) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
    console.error(`${RD}[Error]${CL} People config has ${errs.length} reference error(s)`);
    return 1;
  }
  info(
    `People config valid: ${model.roles.size} roles, ${model.organizations.size} orgs, ` +
      `${model.groups.size} groups, ${model.users.size} users (from ${opts.configDir})`,
  );
  return 0;
}

function cmdSync(opts: Opts, client: PrimitiveClient): void {
  const model = loadValidated(opts.configDir);
  info(
    `Loaded people: ${model.roles.size} roles, ${model.organizations.size} orgs, ` +
      `${model.groups.size} groups, ${model.users.size} users (from ${opts.configDir})`,
  );

  let snap;
  try {
    snap = snapshot(client);
  } catch (e) {
    if (e instanceof AuthentikUnreachable) {
      die(`Authentik unreachable: ${e.message}`);
    }
    throw e;
  }

  const plan = computePlan(model, snap);

  // Plan summary
  info("");
  info(`Plan: ${plan.actions.length} action(s), ${plan.warnings.length} warning(s)`);
  for (const w of plan.warnings) warn(w);
  for (const a of plan.actions) {
    info(`  ${opts.dryRun ? "[dry-run] would " : ""}${a.kind}: ${a.target}`);
  }

  if (opts.dryRun) {
    info("");
    info("--dry-run: no changes applied.");
    return;
  }
  if (plan.actions.length === 0) {
    info(`${GN}Nothing to do — Authentik already matches config.${CL}`);
    return;
  }
  const n = applyPlan(client, plan);
  info("");
  info(`${GN}Applied ${n} action(s).${CL}`);
}

// ── read-only CRUD: list / get over the JSON config ───────────────────
function entityMap(model: PeopleModel, kind: string): Map<string, unknown> {
  switch (kind) {
    case "role":
      return model.roles as Map<string, unknown>;
    case "org":
    case "organization":
      return model.organizations as Map<string, unknown>;
    case "group":
      return model.groups as Map<string, unknown>;
    case "user":
      return model.users as Map<string, unknown>;
    default:
      die(`Unknown entity kind: ${kind}`);
  }
}

// Pull --force out of an arg list; return it + the remaining args.
function takeForce(args: string[]): { force: boolean; rest: string[] } {
  let force = false;
  const rest: string[] = [];
  for (const a of args) {
    if (a === "--force") force = true;
    else rest.push(a);
  }
  return { force, rest };
}

function reconcileReminder(): void {
  info("");
  info(`Config written. Run '${GN}people-manager reconcile${CL}' to push to the identity service.`);
}

function cmdEntity(kind: string, opts: Opts): void {
  const sub = opts.rest[0];
  if (!sub) die(`${kind}: expected one of list|show|add|modify|delete`);

  // ── read-only verbs ──────────────────────────────────────────────────
  if (sub === "list" || sub === "show" || sub === "get") {
    const model = loadPeople(opts.configDir);
    const map = entityMap(model, kind);
    if (sub === "list") {
      const names = Array.from(map.keys()).sort();
      info(JSON.stringify(names, null, 2));
      return;
    }
    if (sub === "get") warn("'get' is deprecated — use 'show'");
    const name = opts.rest[1];
    if (!name) die(`${kind} ${sub}: expected <name>`);
    const v = map.get(name);
    if (v === undefined) die(`${kind} '${name}' not found in ${opts.configDir}`);
    info(JSON.stringify(v, null, 2));
    return;
  }

  // ── write verbs (config-only; NEVER call Authentik) ──────────────────
  if (sub === "add" || sub === "modify" || sub === "delete") {
    const name = opts.rest[1];
    if (!name) die(`${kind} ${sub}: expected <name>`);
    const { force, rest } = takeForce(opts.rest.slice(2));
    try {
      if (sub === "add") {
        const fa = parseFieldArgs(rest);
        const r = addEntity(opts.configDir, kind, name, fa, force);
        info(`Added ${kind} '${name}' → ${r.path}`);
        reconcileReminder();
      } else if (sub === "modify") {
        const fa = parseFieldArgs(rest);
        const r = modifyEntity(opts.configDir, kind, name, fa);
        info(`Modified ${kind} '${name}' → ${r.path}`);
        reconcileReminder();
      } else {
        if (rest.length > 0) die(`${kind} delete: unexpected argument '${rest[0]}'`);
        const r = deleteEntity(opts.configDir, kind, name, force);
        info(`Deleted ${kind} '${name}' (${r.path})`);
        reconcileReminder();
      }
    } catch (e) {
      if (e instanceof EntityError) die(e.message);
      throw e;
    }
    return;
  }

  die(`${kind} ${sub}: unknown verb (use list|show|add|modify|delete)`);
}

export function run(argv: string[], client: PrimitiveClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  const cmd = argv[0];
  const opts = parseOpts(argv.slice(1));

  try {
    switch (cmd) {
      case "reconcile":
        cmdSync(opts, client);
        return 0;
      case "sync": // deprecated alias for reconcile (kept for back-compat)
        warn("'people-manager sync' is deprecated — use 'people-manager reconcile'");
        cmdSync(opts, client);
        return 0;
      case "validate":
        return cmdValidate(opts);
      case "role":
      case "org":
      case "organization":
      case "group":
      case "user":
        cmdEntity(cmd, opts);
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
  const client = new CliPrimitiveClient();
  process.exit(run(process.argv.slice(2), client));
}
