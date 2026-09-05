// bootstrap.ts — bootstrap the minimal People domain (the user-setup.sh logic,
// ported — the bash script is retired, ADR-007 refactor Phase 8.2).
//
// Copies the manager's minimal-org/ templates into config/people/, substituting
// the placeholders __ORG__ / __USER__ / __EMAIL__ / __ROOT_EMAIL__ in BOTH
// filenames and file contents, then validates reference integrity (the same
// validateRefs gate `people-manager validate` runs).
//
//   __ORG__        the organization name (= the install/system name)
//   __USER__       the installer's username
//   __EMAIL__      the installer's primary email
//   __ROOT_EMAIL__ root@<domain> where <domain> is the part of the email after '@'
//
// This is a thin bootstrap: it has no entity-creation logic of its own and it
// does NOT push anything to Authentik (that is `people-manager reconcile`).
//
// Result (ADR-007 people model):
//   * 1 organization  <ORG>            owner = <USER>
//   * 2 groups        users (team)             ownerOrg <ORG>, roles [user]
//                     authentik Admins         ownerOrg <ORG>, no roles
//   * 3 roles         admin, user, root
//   * 2 users:
//       root    roles [admin, user, root]   memberOf [users]
//               email root@<domain-of-installer>
//       <USER>  roles [admin, user]         memberOf [users, authentik Admins]
//               email <installer email>
//
// `authentik Admins` is Authentik's OWN built-in superuser group (is_superuser),
// not one TAPPaaS invents — naming it here adopts it, so reconcile puts <USER>
// (the site/default-environment owner) in it and that person can administer
// users in the Authentik UI without the akadmin break-glass login (issue #476).
// root is deliberately NOT a member: it stays a label-only break-glass account.
//
// Guard (matches the retired bash): a non-empty destination is REFUSED unless
// force — the caller-facing idempotency contract is "skip once populated"
// (the installer checks emptiness before calling).

import { existsSync, readFileSync, readdirSync, statSync } from "fs";
import { dirname, join } from "path";
import { loadPeople, validateRefs } from "./config";
import { atomicWrite, serialize } from "./entity";

// Raised on any user-facing bootstrap error (bad args, non-empty destination,
// failed validation). main.ts maps it to a die() (exit 1); tests assert on it.
export class BootstrapError extends Error {}

export interface PeopleBootstrapOptions {
  peopleDir: string; // destination People dir (the manager's --config-dir)
  org: string;
  user: string;
  email: string;
  minimalOrgDir?: string; // template source override (--minimal-org)
  force: boolean; // overwrite a non-empty destination
  skipValidate: boolean; // skip the post-copy reference validation
}

export interface PeopleBootstrapResult {
  written: string[]; // destination paths written (sorted)
  rootEmail: string;
  minimalOrgDir: string; // the template dir actually used
  warnings: string[];
}

const SLUG_RE = /^[A-Za-z0-9_-]+$/;
const EMAIL_RE = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;

// Resolve the minimal-org/ template dir:
//   1. $PM_MINIMAL_ORG_DIR (tests / relocation);
//   2. walk up from the compiled file — in-repo runs (dist/, dist-test/) pass
//      the component dir (manager/people-manager/), which holds minimal-org/;
//   3. the mothership checkout (the nix-store binary contains only lib/ts +
//      this component's compiled dist, so the templates cannot ship inside it —
//      same situation as environment-manager's resolveSchemaDir and the retired
//      bash script, which resolved through its ~/bin symlink into the checkout).
export function resolveMinimalOrgDir(): string {
  const env = process.env.PM_MINIMAL_ORG_DIR;
  if (env) return env;
  let d = __dirname;
  for (;;) {
    // A real template dir, not just any "minimal-org" name: check for a
    // known template file.
    const direct = join(d, "minimal-org");
    if (existsSync(join(direct, "roles", "root.json"))) return direct;
    const viaTree = join(d, "manager", "people-manager", "minimal-org");
    if (existsSync(join(viaTree, "roles", "root.json"))) return viaTree;
    const up = dirname(d);
    if (up === d) break;
    d = up;
  }
  return "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/manager/people-manager/minimal-org";
}

// Substitute the placeholders in a string (used for both paths and contents).
// __ROOT_EMAIL__ must be substituted BEFORE __EMAIL__ (it contains the literal
// token "EMAIL" only as part of "ROOT_EMAIL"; ordering keeps both correct).
function subst(s: string, org: string, user: string, email: string, rootEmail: string): string {
  return s
    .split("__ORG__").join(org)
    .split("__USER__").join(user)
    .split("__ROOT_EMAIL__").join(rootEmail)
    .split("__EMAIL__").join(email);
}

// Recursively collect the *.json template files under dir, as paths relative
// to dir (e.g. "users/__USER__.json").
function templateFiles(dir: string, prefix = ""): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const rel = prefix ? `${prefix}/${name}` : name;
    if (statSync(p).isDirectory()) out.push(...templateFiles(p, rel));
    else if (name.endsWith(".json")) out.push(rel);
  }
  return out.sort();
}

// Run the People bootstrap. Throws BootstrapError on any user-facing problem
// (bad arguments, non-empty destination without force, invalid result).
export function bootstrapPeople(opts: PeopleBootstrapOptions): PeopleBootstrapResult {
  // ── argument validation (messages match the retired user-setup.sh) ────
  if (!opts.org) throw new BootstrapError("--org is required. Use --help for usage.");
  if (!opts.user) throw new BootstrapError("--user is required. Use --help for usage.");
  if (!opts.email) throw new BootstrapError("--email is required. Use --help for usage.");
  if (!SLUG_RE.test(opts.org)) {
    throw new BootstrapError(`--org '${opts.org}' is not a valid slug ([A-Za-z0-9_-]+)`);
  }
  if (!SLUG_RE.test(opts.user)) {
    throw new BootstrapError(`--user '${opts.user}' is not a valid slug ([A-Za-z0-9_-]+)`);
  }
  if (!EMAIL_RE.test(opts.email)) {
    throw new BootstrapError(`--email '${opts.email}' is not a valid email address`);
  }
  // The root user's email: root@<domain-of-installer-email>.
  const rootEmail = `root@${opts.email.slice(opts.email.indexOf("@") + 1)}`;

  const src = opts.minimalOrgDir ?? resolveMinimalOrgDir();
  if (!existsSync(src)) {
    throw new BootstrapError(`minimal-org directory not found: ${src}`);
  }

  const warnings: string[] = [];

  // ── guard: refuse to clobber a non-empty destination unless force ─────
  const dest = opts.peopleDir;
  if (existsSync(dest) && readdirSync(dest).length > 0) {
    if (!opts.force) {
      throw new BootstrapError(
        `Destination ${dest} already exists and is not empty (use --force to overwrite)`,
      );
    }
    warnings.push("Destination is non-empty; --force given, overwriting");
  }

  // ── stage in memory, then write ────────────────────────────────────────
  // Every template is substituted AND parsed before anything is written, so a
  // malformed template aborts with nothing half-copied (the bash staged to a
  // temp dir for the same all-or-nothing property).
  const staged: Array<{ path: string; text: string }> = [];
  for (const rel of templateFiles(src)) {
    const outRel = subst(rel, opts.org, opts.user, opts.email, rootEmail);
    const text = subst(readFileSync(join(src, rel), "utf8"), opts.org, opts.user, opts.email, rootEmail);
    let rec: Record<string, unknown>;
    try {
      rec = JSON.parse(text) as Record<string, unknown>;
    } catch (e) {
      throw new BootstrapError(
        `malformed template ${join(src, rel)}: ${e instanceof Error ? e.message : String(e)}`,
      );
    }
    staged.push({ path: join(dest, outRel), text: serialize(rec) });
  }

  const written: string[] = [];
  for (const f of staged) {
    atomicWrite(f.path, f.text); // atomicWrite mkdirs the parent
    written.push(f.path);
  }

  // ── validate the result (reference integrity) ─────────────────────────
  if (!opts.skipValidate) {
    const errs = validateRefs(loadPeople(dest));
    if (errs.length > 0) {
      throw new BootstrapError(
        `bootstrap result failed validation:\n  ${errs.join("\n  ")}`,
      );
    }
  }

  return { written, rootEmail, minimalOrgDir: src, warnings };
}
