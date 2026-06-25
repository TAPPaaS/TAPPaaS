// entity.test.ts — offline unit tests for config-only entity CRUD (ADR-007 #5).
//
// No Authentik, no cluster: everything operates on a temp config/people/ tree.
// Covers: add (create + read-back), validation-reject, ref-guard on delete,
// modify list add/remove. Tiny assert harness (no test framework).

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { loadPeople } from "../../src/config";
import {
  EntityError,
  addEntity,
  deleteEntity,
  modifyEntity,
  parseFieldArgs,
  referencesTo,
} from "../../src/entity";

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
    threw = e instanceof EntityError;
  }
  check(threw, msg);
}

// ── seed a small, valid people tree under a temp dir ────────────────────
function seed(): string {
  const dir = mkdtempSync(join(tmpdir(), "people-entity-"));
  for (const sub of ["roles", "organizations", "groups", "users"]) {
    mkdirSync(join(dir, sub), { recursive: true });
  }
  const w = (sub: string, name: string, o: unknown): void =>
    writeFileSync(join(dir, sub, `${name}.json`), JSON.stringify(o, null, 2), "utf8");

  w("roles", "admin", { name: "admin", displayName: "Administrator", description: "admin" });
  w("roles", "user", { name: "user", displayName: "User" });
  w("organizations", "acme", { name: "acme", type: "company", displayName: "Acme", owner: "alice" });
  w("groups", "acme__admins", {
    name: "acme__admins",
    type: "team",
    displayName: "Acme Admins",
    ownerOrg: "acme",
    roles: ["admin"],
  });
  w("users", "alice", {
    name: "alice",
    displayName: "Alice",
    primaryEmail: "alice@acme.test",
    state: "active",
    memberOf: ["acme__admins"],
    roles: ["user"],
  });
  return dir;
}

const trees: string[] = [];
function newTree(): string {
  const d = seed();
  trees.push(d);
  return d;
}

// ── 1. add: create + read-back ──────────────────────────────────────────
{
  const d = newTree();
  addEntity(d, "role", "editor", parseFieldArgs(["--displayName", "Editor"]), false);
  const p = join(d, "roles", "editor.json");
  check(existsSync(p), "add role writes the JSON file");
  const raw = JSON.parse(readFileSync(p, "utf8"));
  check(raw.name === "editor" && raw.displayName === "Editor", "added role round-trips fields");

  // a user with valid refs
  addEntity(
    d,
    "user",
    "bob",
    parseFieldArgs([
      "--email",
      "bob@acme.test",
      "--displayName",
      "Bob",
      "--roles",
      "user,editor",
      "--groups",
      "acme__admins",
    ]),
    false,
  );
  const m = loadPeople(d);
  const bob = m.users.get("bob")!;
  check(!!bob, "added user is loadable");
  check(
    bob.primaryEmail === "bob@acme.test" &&
      bob.roles!.includes("user") &&
      bob.roles!.includes("editor") &&
      bob.memberOf!.includes("acme__admins"),
    "user --email/--roles/--groups aliases map to primaryEmail/roles/memberOf",
  );
}

// ── 2. add: refuse duplicate without --force; allow with --force ────────
{
  const d = newTree();
  expectThrows(
    () => addEntity(d, "role", "admin", parseFieldArgs([]), false),
    "add refuses an existing entity without --force",
  );
  addEntity(d, "role", "admin", parseFieldArgs(["--displayName", "Changed"]), true);
  check(
    JSON.parse(readFileSync(join(d, "roles", "admin.json"), "utf8")).displayName === "Changed",
    "add --force overwrites",
  );
}

// ── 3. add: validation-reject on unknown ref ────────────────────────────
{
  const d = newTree();
  expectThrows(
    () =>
      addEntity(
        d,
        "user",
        "carol",
        parseFieldArgs(["--email", "c@acme.test", "--roles", "nonesuch"]),
        false,
      ),
    "add rejects a user with an unknown role ref",
  );
  check(!existsSync(join(d, "users", "carol.json")), "rejected add wrote NO file (atomic)");

  expectThrows(
    () =>
      addEntity(d, "group", "ghost__team", parseFieldArgs(["--ownerOrg", "no-such-org"]), false),
    "add rejects a group with an unknown ownerOrg",
  );
}

// ── 4. modify: scalar set + list add/remove ─────────────────────────────
{
  const d = newTree();
  // scalar set
  modifyEntity(d, "user", "alice", parseFieldArgs(["--displayName", "Alice A."]));
  check(
    loadPeople(d).users.get("alice")!.displayName === "Alice A.",
    "modify sets a scalar field",
  );

  // list add (roles): alice currently has [user]; add admin (a known role)
  modifyEntity(d, "user", "alice", parseFieldArgs(["--add-roles", "admin"]));
  let alice = loadPeople(d).users.get("alice")!;
  check(
    alice.roles!.includes("user") && alice.roles!.includes("admin"),
    "modify --add-roles appends without dropping existing",
  );

  // add is idempotent (set semantics — no duplicate)
  modifyEntity(d, "user", "alice", parseFieldArgs(["--add-roles", "admin"]));
  alice = loadPeople(d).users.get("alice")!;
  check(alice.roles!.filter((r) => r === "admin").length === 1, "modify --add-roles dedupes");

  // list remove
  modifyEntity(d, "user", "alice", parseFieldArgs(["--remove-roles", "user"]));
  alice = loadPeople(d).users.get("alice")!;
  check(
    !alice.roles!.includes("user") && alice.roles!.includes("admin"),
    "modify --remove-roles drops the named item",
  );

  // group membership add/remove
  addEntity(d, "group", "acme__users", parseFieldArgs(["--ownerOrg", "acme", "--roles", "user"]), false);
  modifyEntity(d, "user", "alice", parseFieldArgs(["--add-groups", "acme__users"]));
  check(
    loadPeople(d).users.get("alice")!.memberOf!.includes("acme__users"),
    "modify --add-groups adds a membership (alias → memberOf)",
  );
  modifyEntity(d, "user", "alice", parseFieldArgs(["--remove-groups", "acme__admins"]));
  check(
    !loadPeople(d).users.get("alice")!.memberOf!.includes("acme__admins"),
    "modify --remove-groups removes a membership",
  );
}

// ── 5. modify: errors on absent, and validation-reject ──────────────────
{
  const d = newTree();
  expectThrows(
    () => modifyEntity(d, "user", "nobody", parseFieldArgs(["--displayName", "X"])),
    "modify errors when the entity is absent",
  );
  expectThrows(
    () => modifyEntity(d, "user", "alice", parseFieldArgs(["--add-roles", "nonesuch"])),
    "modify rejects adding an unknown role ref",
  );
}

// ── 6. delete: ref-guard refuses; --force overrides ─────────────────────
{
  const d = newTree();
  // admin role is referenced by acme__admins (roles) and alice (roles → no,
  // alice has [user]); group references it.
  const refs = referencesTo(loadPeople(d), "role", "admin");
  check(refs.length > 0, "referencesTo finds the group referencing role 'admin'");
  expectThrows(
    () => deleteEntity(d, "role", "admin", false),
    "delete refuses a role still referenced by a group",
  );
  check(existsSync(join(d, "roles", "admin.json")), "guarded delete left the file in place");

  // org 'acme' is referenced (group ownerOrg + user owner) → guarded
  expectThrows(
    () => deleteEntity(d, "org", "acme", false),
    "delete refuses an org still referenced (ownerOrg/owner)",
  );

  // --force overrides the guard
  deleteEntity(d, "role", "admin", true);
  check(!existsSync(join(d, "roles", "admin.json")), "delete --force removes despite references");
}

// ── 7. delete: succeeds when unreferenced; errors when absent ───────────
{
  const d = newTree();
  // 'user' role: referenced by alice.roles → guarded. Remove that ref first.
  modifyEntity(d, "user", "alice", parseFieldArgs(["--remove-roles", "user"]));
  // also referenced by no group in this tree; safe to delete now
  deleteEntity(d, "role", "user", false);
  check(!existsSync(join(d, "roles", "user.json")), "delete removes an unreferenced entity");
  expectThrows(
    () => deleteEntity(d, "role", "user", false),
    "delete errors when the entity is absent",
  );
}

// ── 8. org alias + parentOrg ref guard ──────────────────────────────────
{
  const d = newTree();
  addEntity(d, "organization", "sub", parseFieldArgs(["--owner", "alice", "--parentOrg", "acme"]), false);
  check(loadPeople(d).organizations.get("sub")!.parentOrg === "acme", "org alias + parentOrg set");
  expectThrows(
    () => deleteEntity(d, "org", "acme", false),
    "delete org refuses while a child org references it via parentOrg",
  );
}

for (const d of trees) rmSync(d, { recursive: true, force: true });

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
