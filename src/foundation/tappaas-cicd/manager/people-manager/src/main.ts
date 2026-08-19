// people-manager — TAPPaaS People → Authentik reconcile manager (ADR-007 P1).
//
// Holds the people→Authentik RECONCILE LOGIC and calls the identity-controller
// PRIMITIVES (the `authentik-manager` CLI, S2b-2) over a thin spawnSync FFI.
// NO Authentik HTTP is reimplemented here — see src/primitives.ts.
//
// Commands:
//   people-manager bootstrap --org O --user U --email E [--config-dir DIR]
//                            (the retired user-setup.sh — Phase 8.2)
//   people-manager reconcile [--apply] [--config-dir DIR]   (alias: sync, deprecated)
//   people-manager role|org|group|user list|get [<name>] [--config-dir DIR]
//
// Exit codes: ok=0, error=1.

import { BootstrapError, bootstrapPeople } from "./bootstrap";
import { defaultConfigDir, loadPeople, validateRefs } from "./config";
import {
  EntityError,
  addEntity,
  deleteEntity,
  modifyEntity,
  parseFieldArgs,
} from "./entity";
import { CliPrimitiveClient, AuthentikUnreachable } from "./primitives";
import { childOrgs, deepGroup, deepOrg, groupsOfOrg, orgRoots, usersOfGroup } from "./queries";
import { applyPlan, computePlan, pushEntityDeletion, snapshot } from "./reconcile";
import { PeopleModel, PrimitiveClient } from "./types";
import { HelpSpec, renderHelp } from "../../../lib/ts/src/help";
import { CL, DieError, GN, RD, die, guarded, info, warn } from "../../../lib/ts/src/cli";

const VERSION = "0.1.0";

const HELP: HelpSpec = {
  name: "people-manager",
  version: VERSION,
  tagline: "TAPPaaS People → Authentik manager",
  verbs: [
    {
      usage: "bootstrap --org O --user U --email E [--minimal-org DIR]\n" +
        "                        [--force] [--skip-validate]",
      name: "bootstrap",
      options: [
        ["--org O", "organization slug (= the TAPPaaS installation name)"],
        ["--user U", "the installer's username (slug)"],
        ["--email E", "the installer's primary email address"],
        ["--minimal-org DIR", "template source (default: the component's minimal-org/)"],
        ["--force", "overwrite a non-empty destination"],
        ["--skip-validate", "skip the post-copy reference validation"],
      ],
      note: "(seeds config/people from minimal-org/ — the retired user-setup.sh)",
    },
    {
      usage: "reconcile [--apply]",
      note: "(alias: sync, deprecated)",
      options: [
        ["--apply", "push the plan to Authentik (default is PREVIEW)"],
        ["--dry-run", "deprecated no-op (preview is already the default)"],
      ],
    },
    { usage: "validate" },
    {
      usage: "<kind> list [--json] [--deep]",
      name: "<kind> list",
      options: [
        ["--json", "structured output (default is human-readable)"],
        ["--deep", "org/group only: recurse into groups + user membership"],
      ],
    },
    {
      usage: "<kind> show <name> [--json]",
      name: "<kind> show",
      note: "(alias: get, deprecated)",
      options: [["--json", "structured output (default is human-readable)"]],
    },
    {
      usage: "<kind> add <name> [field flags] [--force] [--no-reconcile]",
      name: "<kind> add",
      options: [["--force", "overwrite an existing entity"]],
    },
    { usage: "<kind> modify <name> [field flags] [--no-reconcile]" },
    {
      usage: "<kind> delete <name> [--force] [--no-reconcile]",
      name: "<kind> delete",
      options: [["--force", "delete despite the reference guard"]],
    },
  ],
  common: [
    ["--config-dir DIR", "People directory (default: $TAPPAAS_CONFIG/people)"],
    ["--no-reconcile", "add/modify/delete: write config only, do NOT push to identity"],
  ],
  notes: [
    "where <kind> is one of: role | org (alias organization) | group | user",
    `Field flags (write the validated config, then push it to the identity service):
  role:  --displayName V  --description V
  org:   --displayName V  --type V  --owner USER  --parentOrg ORG
  group: --displayName V  --type V  --ownerOrg ORG  --roles "a,b"  --add-roles R  --remove-roles R
  user:  --displayName V  --email ADDR  --state planned|active|suspended|terminated
         --roles "a,b"  --groups "g1,g2"  --add-roles R  --remove-roles R  --add-groups G  --remove-groups G`,
    "add/modify/delete RECONCILE by default — the change is live in the identity service when the command returns. Pass --no-reconcile to stage config only (then push with 'people-manager reconcile --apply').",
  ],
};

function usage(): void {
  info(renderHelp(HELP));
}

// Pull --config-dir / --apply / --dry-run out of an arg list; return the rest.
interface Opts {
  configDir: string;
  apply: boolean;
  dryRun: boolean;
  json: boolean;
  deep: boolean;
  noReconcile: boolean;
  rest: string[];
}
function parseOpts(args: string[]): Opts {
  let configDir = defaultConfigDir();
  let apply = false;
  let dryRun = false;
  let json = false;
  let deep = false;
  let noReconcile = false;
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
    } else if (a === "--no-reconcile") {
      noReconcile = true;
    } else if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      configDir = v;
      i++;
    } else {
      rest.push(a);
    }
  }
  return { configDir, apply, dryRun, json, deep, noReconcile, rest };
}

// `bootstrap` — seed the minimal People domain from the minimal-org/ templates
// (the retired user-setup.sh, native — ADR-007 refactor Phase 8.2). Config-only:
// run `people-manager reconcile --apply` afterwards to push to the identity
// service. Refuses a non-empty destination unless --force (callers guard on
// emptiness, so re-runs never disturb operator-added people). Exit 0 = success,
// 1 = error (matching the bash).
function cmdBootstrap(opts: Opts): void {
  let org = "";
  let user = "";
  let email = "";
  let minimalOrg: string | undefined;
  let force = false;
  let skipValidate = false;
  const args = opts.rest;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const need = (label: string): string => {
      const v = args[i + 1];
      if (!v) die(`${label} requires an argument`);
      i++;
      return v;
    };
    switch (a) {
      case "--org":
        org = need("--org");
        break;
      case "--user":
        user = need("--user");
        break;
      case "--email":
        email = need("--email");
        break;
      case "--minimal-org":
        minimalOrg = need("--minimal-org");
        break;
      case "--force":
        force = true;
        break;
      case "--skip-validate":
        skipValidate = true;
        break;
      default:
        die(`bootstrap: unknown argument '${a}'. Use --help for usage.`);
    }
  }

  try {
    // Announce first (mirrors the bash), resolving the template dir the same
    // way bootstrapPeople will.
    info("Bootstrapping People domain");
    info(`  org        = ${org}`);
    info(`  user       = ${user}`);
    info(`  email      = ${email}`);
    info(`  to         = ${opts.configDir}`);
    const res = bootstrapPeople({
      peopleDir: opts.configDir,
      org,
      user,
      email,
      minimalOrgDir: minimalOrg,
      force,
      skipValidate,
    });
    for (const w of res.warnings) warn(w);
    info(`Copied minimal-org (${res.minimalOrgDir}) into ${opts.configDir}`);
    info(`  root email = ${res.rootEmail}`);
    if (!skipValidate) info("Validated result (reference integrity)");
    info(`${GN}People bootstrap complete${CL}`);
  } catch (e) {
    if (e instanceof BootstrapError) die(e.message);
    throw e;
  }
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
  const res = applyPlan(client, plan);
  if (res.failures.length > 0) {
    for (const f of res.failures) warn(`failed ${f.target} — ${f.message}`);
    die(`applied ${res.applied} of ${res.total} action(s); ${res.failures.length} failed`);
  }
  info(`${GN}Applied ${res.applied} action(s).${CL}`);
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

// A write verb pushes to the identity service by DEFAULT (issue #482): a change
// an operator has made should be live, not staged behind a second command they
// have to remember. --no-reconcile keeps the old config-only behaviour for
// staging several edits, or for editing while Authentik is down.
//
// The push is a full reconcile, not just this entity's actions: config/people is
// the desired state, so the one moment we are already talking to Authentik is
// the right moment to converge all of it.
//
// Ordering matters for delete. computePlan only knows what config CONTAINS, so
// the just-deleted entity is invisible to it — `push` removes that entity
// explicitly first, then the reconcile converges everything else.
function pushAfterWrite(
  opts: Opts,
  client: PrimitiveClient,
  push?: { kind: string; name: string },
): void {
  info("");
  if (opts.noReconcile) {
    info(
      `Config written (--no-reconcile). Run '${GN}people-manager reconcile --apply${CL}' ` +
        `to push to the identity service.`,
    );
    return;
  }

  try {
    if (push) {
      const res = pushEntityDeletion(client, push.kind, push.name);
      if (res.pushed) info(`Removed ${push.kind} '${push.name}' from the identity service.`);
      else info(`Not removed from the identity service: ${res.reason}.`);
    }
    cmdSync({ ...opts, apply: true, dryRun: false }, client);
  } catch (e) {
    // The config write already succeeded and is on disk — say so plainly, so the
    // operator knows the fix is to re-run the push, NOT to redo the edit.
    // cmdSync already printed its own [Error] line before throwing DieError;
    // anything else (a failing delete primitive) has not been reported yet.
    if (e instanceof AuthentikUnreachable) {
      warn(`identity service unreachable — ${e.message}`);
    } else if (e instanceof Error && !(e instanceof DieError)) {
      warn(e.message);
    }
    die(
      `config was written, but pushing it to the identity service failed. ` +
        `Re-run '${GN}people-manager reconcile --apply${CL}' once the identity service is reachable.`,
    );
  }
}

// ── --deep output ──────────────────────────────────────────────────────
// The pure relationship queries (groupsOfOrg, usersOfGroup, childOrgs,
// orgRoots, deepGroup, deepOrg) live in queries.ts. Here: the human tree.
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

function cmdEntity(kind: string, opts: Opts, client: PrimitiveClient): void {
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

  // ── write verbs: write the config, then push it (issue #482) ─────────
  // The write itself is transactional (validate-then-atomic-write); the push
  // happens only after it succeeds, so a rejected edit never reaches Authentik.
  if (sub === "add" || sub === "modify" || sub === "delete") {
    const name = opts.rest[1];
    if (!name) die(`${kind} ${sub}: expected <name>`);
    const { force, rest } = takeForce(opts.rest.slice(2));
    let deleted = false;
    try {
      if (sub === "add") {
        const fa = parseFieldArgs(rest);
        const r = addEntity(opts.configDir, kind, name, fa, force);
        info(`Added ${kind} '${name}' → ${r.path}`);
      } else if (sub === "modify") {
        const fa = parseFieldArgs(rest);
        const r = modifyEntity(opts.configDir, kind, name, fa);
        info(`Modified ${kind} '${name}' → ${r.path}`);
      } else {
        if (rest.length > 0) die(`${kind} delete: unexpected argument '${rest[0]}'`);
        const r = deleteEntity(opts.configDir, kind, name, force);
        info(`Deleted ${kind} '${name}' (${r.path})`);
        deleted = true;
      }
    } catch (e) {
      if (e instanceof EntityError) die(e.message);
      throw e;
    }
    pushAfterWrite(opts, client, deleted ? { kind, name } : undefined);
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

  return guarded(() => {
    switch (cmd) {
      case "bootstrap":
        cmdBootstrap(opts);
        return 0;
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
        cmdEntity(cmd, opts, client);
        return 0;
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  });
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const client = new CliPrimitiveClient();
  process.exit(run(process.argv.slice(2), client));
}
