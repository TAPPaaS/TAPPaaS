// people-manager — TAPPaaS People → Authentik reconcile manager (ADR-007 P1).
//
// Holds the people→Authentik RECONCILE LOGIC and calls the identity-controller
// PRIMITIVES (the `authentik-manager` CLI, S2b-2) over a thin spawnSync FFI.
// NO Authentik HTTP is reimplemented here — see src/primitives.ts.
//
// Commands:
//   people-manager reconcile [--apply] [--config-dir DIR]   (alias: sync, deprecated)
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
  people-manager reconcile [--apply] [--config-dir DIR]   (alias: sync, deprecated)
  people-manager validate  [--config-dir DIR]
  people-manager <kind> list         [--json] [--deep] [--config-dir DIR]
  people-manager <kind> show   <name> [--json]         [--config-dir DIR]   (alias: get, deprecated)
      --json   structured output (default is human-readable)
      --deep   org/group list only: recurse into groups + user membership
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
  --apply          reconcile: push the plan to Authentik (default is PREVIEW).
  --dry-run        reconcile: deprecated no-op (preview is already the default).
  --force          add: overwrite an existing entity; delete: ignore ref guard.
  --config-dir DIR People directory (default: \$TAPPAAS_CONFIG/people).
  -h, --help       Show this help.

After a successful add/modify/delete, run 'people-manager reconcile' to push
the change to the identity service. Writes never call Authentik directly.`);
}

// Pull --config-dir / --apply / --dry-run out of an arg list; return the rest.
interface Opts {
  configDir: string;
  apply: boolean;
  dryRun: boolean;
  json: boolean;
  deep: boolean;
  rest: string[];
}
function parseOpts(args: string[]): Opts {
  let configDir = defaultConfigDir();
  let apply = false;
  let dryRun = false;
  let json = false;
  let deep = false;
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--apply") {
      apply = true;
    } else if (a === "--dry-run") {
      // Back-compat no-op: preview is now the DEFAULT (reconcile applies only
      // with --apply, matching the other managers). --dry-run still forces
      // preview, so an old caller keeps working.
      dryRun = true;
    } else if (a === "--json") {
      json = true;
    } else if (a === "--deep") {
      deep = true;
    } else if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      configDir = v;
      i++;
    } else {
      rest.push(a);
    }
  }
  return { configDir, apply, dryRun, json, deep, rest };
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

  // Preview by default; commit only with --apply (matches site/network/... managers).
  // --dry-run is a back-compat no-op that also forces preview.
  const doApply = opts.apply && !opts.dryRun;

  // ── Readable plan output ──────────────────────────────────────────────
  info("");
  info(`Reconciling config/people → Authentik (identity)${doApply ? "" : " — preview"}:`);
  for (const w of plan.warnings) warn(w);

  if (plan.actions.length === 0) {
    info("");
    info(`${GN}In sync — Authentik already matches config. Nothing to do.${CL}`);
    return;
  }

  // Group the actions by a friendly category (fixed order), each prefixed with a
  // symbol (+ create/grant, - remove, ✗ delete) so the plan reads at a glance
  // instead of a flat list of "ensure-role:"/"assign-role:" jargon.
  const CAT: Record<string, { label: string; sym: string }> = {
    "ensure-role": { label: "Roles", sym: "+" },
    "ensure-group": { label: "Groups", sym: "+" },
    "ensure-user": { label: "Users", sym: "+" },
    "disable-user": { label: "Users", sym: "-" },
    "delete-user": { label: "Users", sym: "✗" },
    "add-member": { label: "Memberships", sym: "+" },
    "remove-member": { label: "Memberships", sym: "-" },
    "assign-role": { label: "Role grants", sym: "+" },
    "unassign-role": { label: "Role grants", sym: "-" },
  };
  const ORDER = ["Roles", "Groups", "Users", "Memberships", "Role grants"];
  const byCat = new Map<string, string[]>();
  for (const a of plan.actions) {
    const c = CAT[a.kind] ?? { label: "Other", sym: "•" };
    if (!byCat.has(c.label)) byCat.set(c.label, []);
    byCat.get(c.label)!.push(`    ${c.sym} ${a.target}`);
  }
  const extra = Array.from(byCat.keys()).filter((l) => !ORDER.includes(l));
  for (const label of [...ORDER, ...extra]) {
    const lines = byCat.get(label);
    if (!lines || lines.length === 0) continue;
    info(`  ${label}`);
    for (const l of lines) info(l);
  }

  info("");
  if (!doApply) {
    info(`${plan.actions.length} change(s) — re-run with --apply to push them to Authentik.`);
    return;
  }
  const n = applyPlan(client, plan);
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

// ── relationship helpers (for --deep) ─────────────────────────────────
// org → its groups (group.ownerOrg == org); group → its users
// (user.memberOf includes group); org → child orgs (o.parentOrg == org).
function groupsOfOrg(model: PeopleModel, org: string): string[] {
  return Array.from(model.groups.values()).filter((g) => g.ownerOrg === org).map((g) => g.name).sort();
}
function usersOfGroup(model: PeopleModel, group: string): string[] {
  return Array.from(model.users.values()).filter((u) => (u.memberOf ?? []).includes(group)).map((u) => u.name).sort();
}
function childOrgs(model: PeopleModel, org: string): string[] {
  return Array.from(model.organizations.values()).filter((o) => o.parentOrg === org).map((o) => o.name).sort();
}
// A top-level org has no parent, or a parent that no longer exists.
function orgRoots(model: PeopleModel, names: string[]): string[] {
  return names.filter((n) => {
    const p = model.organizations.get(n)?.parentOrg;
    return !p || !model.organizations.has(p);
  });
}

// JSON shapes for --deep --json.
function deepGroup(model: PeopleModel, group: string): Record<string, unknown> {
  const g = model.groups.get(group);
  return {
    group,
    ownerOrg: g?.ownerOrg ?? "",
    roles: g?.roles ?? [],
    users: usersOfGroup(model, group).map((u) => ({ user: u, roles: model.users.get(u)?.roles ?? [] })),
  };
}
function deepOrg(model: PeopleModel, org: string): Record<string, unknown> {
  const o = model.organizations.get(org);
  return {
    org,
    owner: o?.owner ?? "",
    groups: groupsOfOrg(model, org).map((g) => deepGroup(model, g)),
    subOrgs: childOrgs(model, org).map((c) => deepOrg(model, c)),
  };
}

// Human tree for --deep.
function printDeepGroup(model: PeopleModel, group: string, indent: string): void {
  const g = model.groups.get(group);
  const roles = (g?.roles ?? []).join(", ");
  info(`${indent}${GN}${group}${CL}  (${g?.type ?? "group"}${g?.ownerOrg ? ", org: " + g.ownerOrg : ""})${roles ? "  [roles: " + roles + "]" : ""}`);
  const users = usersOfGroup(model, group);
  if (users.length === 0) info(`${indent}    (no members)`);
  for (const u of users) {
    const ur = (model.users.get(u)?.roles ?? []).join(", ");
    info(`${indent}    ${u}${ur ? "  [roles: " + ur + "]" : ""}`);
  }
}
function printDeepOrg(model: PeopleModel, org: string, indent: string): void {
  const o = model.organizations.get(org);
  info(`${indent}${GN}${org}${CL}  (${o?.type ?? "org"}${o?.owner ? ", owner: " + o.owner : ""})`);
  for (const g of groupsOfOrg(model, org)) printDeepGroup(model, g, indent + "  ");
  for (const c of childOrgs(model, org)) printDeepOrg(model, c, indent + "  ");
}

// Human key/value for `show` (default; --json prints the raw object).
function printEntity(kind: string, name: string, v: Record<string, unknown>): void {
  info(`${GN}${kind} ${name}${CL}`);
  for (const [k, val] of Object.entries(v)) {
    if (k === "name") continue;
    const s = Array.isArray(val)
      ? val.length ? val.join(", ") : "(none)"
      : val === "" || val == null ? "(unset)" : String(val);
    info(`  ${k}: ${s}`);
  }
}

function cmdEntity(kind: string, opts: Opts): void {
  const sub = opts.rest[0];
  if (!sub) die(`${kind}: expected one of list|show|add|modify|delete`);

  // ── read-only verbs ──────────────────────────────────────────────────
  // Default output is human-readable; --json emits the structured form (was
  // always-JSON — the flag is now meaningful, matching site-manager).
  if (sub === "list" || sub === "show" || sub === "get") {
    const model = loadPeople(opts.configDir);
    const map = entityMap(model, kind);
    const isOrg = kind === "org" || kind === "organization";
    if (sub === "list") {
      const names = Array.from(map.keys()).sort();
      // --deep (org/group only): recurse into groups + user membership.
      if (opts.deep && (isOrg || kind === "group")) {
        if (opts.json) {
          const tree = isOrg
            ? orgRoots(model, names).map((n) => deepOrg(model, n))
            : names.map((n) => deepGroup(model, n));
          info(JSON.stringify(tree, null, 2));
        } else if (names.length === 0) {
          info(`(no ${isOrg ? "org" : "group"}s)`);
        } else if (isOrg) {
          for (const n of orgRoots(model, names)) printDeepOrg(model, n, "");
        } else {
          for (const n of names) printDeepGroup(model, n, "");
        }
        return;
      }
      if (opts.deep) warn(`--deep is only meaningful for 'org'/'group' list — showing a plain list`);
      if (opts.json) info(JSON.stringify(names, null, 2));
      else if (names.length === 0) info(`(no ${kind}s)`);
      else for (const n of names) info(n);
      return;
    }
    if (sub === "get") warn("'get' is deprecated — use 'show'");
    const name = opts.rest[1];
    if (!name) die(`${kind} ${sub}: expected <name>`);
    const v = map.get(name);
    if (v === undefined) die(`${kind} '${name}' not found in ${opts.configDir}`);
    if (opts.json) info(JSON.stringify(v, null, 2));
    else printEntity(kind, name, v as Record<string, unknown>);
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
