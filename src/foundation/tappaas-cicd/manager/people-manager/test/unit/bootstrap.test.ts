// bootstrap.test.ts — offline unit tests for the People bootstrap (the retired
// user-setup.sh, ported — ADR-007 refactor Phase 8.2).
//
// No Authentik, no cluster: bootstraps into a temp config/people/ tree from the
// REAL minimal-org/ templates (via PM_MINIMAL_ORG_DIR). Covers: the produced
// shape (1 org / 1 group / 3 roles / 2 users, fully substituted), validateRefs
// on the result, the non-empty-destination guard (+ --force), bad-args
// rejection, and the template-dir resolution. Tiny assert harness (no test
// framework).

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { loadPeople, validateRefs } from "../../src/config";
import { BootstrapError, bootstrapPeople, resolveMinimalOrgDir } from "../../src/bootstrap";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}
function expectThrows(fn: () => void, msg: string): void {
  let threw = false;
  try {
    fn();
  } catch (e) {
    threw = e instanceof BootstrapError;
  }
  check(threw, msg);
}

// The real minimal-org fixtures: compiled test lives at
// dist-test/manager/people-manager/test/unit/, the component dir is 5 up.
const MINIMAL_ORG = join(__dirname, "..", "..", "..", "..", "..", "minimal-org");
check(existsSync(join(MINIMAL_ORG, "roles", "root.json")), "real minimal-org fixture dir found");
process.env.PM_MINIMAL_ORG_DIR = MINIMAL_ORG;

const trees: string[] = [];
function tmpPeople(): string {
  const parent = mkdtempSync(join(tmpdir(), "pm-bootstrap-"));
  trees.push(parent);
  return join(parent, "people");
}

const OPTS = {
  org: "acme-site",
  user: "lars",
  email: "lars@example.com",
  force: false,
  skipValidate: false,
};

// ── 1. fresh bootstrap: shape + substitution + validateRefs ────────────
{
  const d = tmpPeople();
  const res = bootstrapPeople({ peopleDir: d, ...OPTS });
  check(res.written.length === 7, `writes the 7 template files (got ${res.written.length})`);
  check(res.rootEmail === "root@example.com", "derives root email from the installer domain");
  check(res.minimalOrgDir === MINIMAL_ORG, "PM_MINIMAL_ORG_DIR override is honoured");
  check(existsSync(join(d, "organizations", "acme-site.json")), "org file named after --org");
  check(existsSync(join(d, "users", "lars.json")), "installer user file named after --user");
  check(existsSync(join(d, "users", "root.json")), "root user file present");
  check(existsSync(join(d, "groups", "users.json")), "the single 'users' group present");
  for (const r of ["admin", "user", "root"]) {
    check(existsSync(join(d, "roles", `${r}.json`)), `role '${r}' present`);
  }

  // No placeholder tokens remain in any written file.
  let residue = false;
  for (const p of res.written) {
    if (/__(ORG|USER|EMAIL|ROOT_EMAIL)__/.test(readFileSync(p, "utf8"))) residue = true;
  }
  check(!residue, "no placeholder tokens remain after substitution");

  const org = JSON.parse(readFileSync(join(d, "organizations", "acme-site.json"), "utf8"));
  check(org.name === "acme-site" && org.owner === "lars", "org: name=acme-site, owner=lars");
  const grp = JSON.parse(readFileSync(join(d, "groups", "users.json"), "utf8"));
  check(
    grp.ownerOrg === "acme-site" && Array.isArray(grp.roles) && grp.roles.includes("user"),
    "group 'users': ownerOrg acme-site, roles include 'user'",
  );
  const root = JSON.parse(readFileSync(join(d, "users", "root.json"), "utf8"));
  check(
    root.primaryEmail === "root@example.com" &&
      [...root.roles].sort().join(",") === "admin,root,user" &&
      root.memberOf.includes("users"),
    "root user: roles [admin,user,root], root@ email, memberOf [users]",
  );
  const lars = JSON.parse(readFileSync(join(d, "users", "lars.json"), "utf8"));
  check(
    lars.primaryEmail === "lars@example.com" &&
      [...lars.roles].sort().join(",") === "admin,user" &&
      lars.memberOf.includes("users"),
    "installer user: roles [admin,user], installer email, memberOf [users]",
  );

  check(validateRefs(loadPeople(d)).length === 0, "bootstrap result passes validateRefs");

  // ── 2. idempotency contract: a re-run REFUSES the populated dest ──────
  const before = readFileSync(join(d, "organizations", "acme-site.json"), "utf8");
  expectThrows(
    () => bootstrapPeople({ peopleDir: d, ...OPTS }),
    "re-run without --force refuses the non-empty destination",
  );
  const after = readFileSync(join(d, "organizations", "acme-site.json"), "utf8");
  check(before === after, "refused re-run leaves the destination untouched");

  // ── 3. --force overwrites (and still validates) ────────────────────────
  const res2 = bootstrapPeople({ peopleDir: d, ...OPTS, force: true });
  check(res2.written.length === 7, "--force re-run overwrites");
  check(
    res2.warnings.some((w) => w.includes("--force")),
    "--force re-run warns about the non-empty destination",
  );
  check(validateRefs(loadPeople(d)).length === 0, "--force re-run result still validates");
}

// ── 4. bad args die ─────────────────────────────────────────────────────
{
  const d = tmpPeople();
  expectThrows(() => bootstrapPeople({ peopleDir: d, ...OPTS, org: "" }), "missing --org rejected");
  expectThrows(() => bootstrapPeople({ peopleDir: d, ...OPTS, user: "" }), "missing --user rejected");
  expectThrows(() => bootstrapPeople({ peopleDir: d, ...OPTS, email: "" }), "missing --email rejected");
  expectThrows(
    () => bootstrapPeople({ peopleDir: d, ...OPTS, org: "bad slug!" }),
    "non-slug --org rejected",
  );
  expectThrows(
    () => bootstrapPeople({ peopleDir: d, ...OPTS, user: "no/slash" }),
    "non-slug --user rejected",
  );
  expectThrows(
    () => bootstrapPeople({ peopleDir: d, ...OPTS, email: "not-an-email" }),
    "invalid --email rejected",
  );
  expectThrows(
    () => bootstrapPeople({ peopleDir: d, ...OPTS, minimalOrgDir: join(d, "no-such-dir") }),
    "missing minimal-org dir rejected",
  );
  check(!existsSync(d), "bad-args runs write nothing");
}

// ── 5. malformed template aborts before ANY write ───────────────────────
{
  const badSrc = mkdtempSync(join(tmpdir(), "pm-badtpl-"));
  trees.push(badSrc);
  mkdirSync(join(badSrc, "roles"), { recursive: true });
  writeFileSync(join(badSrc, "roles", "broken.json"), "{ not json", "utf8");
  const d = tmpPeople();
  expectThrows(
    () => bootstrapPeople({ peopleDir: d, ...OPTS, minimalOrgDir: badSrc }),
    "malformed template is rejected",
  );
  check(!existsSync(d), "nothing written when a template is malformed");
}

// ── 6. resolveMinimalOrgDir: env override + __dirname walk ──────────────
{
  check(resolveMinimalOrgDir() === MINIMAL_ORG, "resolveMinimalOrgDir honours PM_MINIMAL_ORG_DIR");
  delete process.env.PM_MINIMAL_ORG_DIR;
  const walked = resolveMinimalOrgDir();
  check(
    existsSync(join(walked, "roles", "root.json")),
    `resolveMinimalOrgDir walk finds a real template dir (${walked})`,
  );
  process.env.PM_MINIMAL_ORG_DIR = MINIMAL_ORG;
}

for (const d of trees) rmSync(d, { recursive: true, force: true });

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
