// write-push.test.ts — issue #482: a write verb PUSHES to the identity service.
//
// Drives the real CLI entry point (run()) against a FakeClient and a temp
// config/people tree, so it asserts the end-to-end behaviour an operator sees:
// `people-manager user add …` must leave the user present in Authentik, with no
// second command. Also pins the escape hatch (--no-reconcile) and the delete
// path, which reconcile alone cannot cover (a removed config file is invisible
// to computePlan).

import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { run } from "../../src/main";
import { FakeClient } from "./fake-client";

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

// A minimal valid people tree: 2 roles, 1 org, 1 group, 1 user (the org owner).
function seed(): string {
  const dir = mkdtempSync(join(tmpdir(), "people-push-"));
  for (const sub of ["roles", "organizations", "groups", "users"]) {
    mkdirSync(join(dir, sub), { recursive: true });
  }
  const w = (sub: string, name: string, o: unknown): void =>
    writeFileSync(join(dir, sub, `${name}.json`), JSON.stringify(o, null, 2), "utf8");
  w("roles", "admin", { name: "admin", displayName: "Administrator" });
  w("roles", "user", { name: "user", displayName: "User" });
  w("organizations", "acme", { name: "acme", type: "company", displayName: "Acme", owner: "ann" });
  w("groups", "acme__users", {
    name: "acme__users",
    type: "team",
    displayName: "Acme users",
    ownerOrg: "acme",
    roles: ["user"],
  });
  w("users", "ann", {
    name: "ann",
    displayName: "Ann",
    primaryEmail: "ann@acme.test",
    state: "active",
    memberOf: ["acme__users"],
    roles: ["admin"],
  });
  return dir;
}

// Silence the manager's console output — these tests assert on client state.
function quiet<T>(fn: () => T): T {
  const log = console.log;
  const err = console.error;
  console.log = (): void => {};
  console.error = (): void => {};
  try {
    return fn();
  } finally {
    console.log = log;
    console.error = err;
  }
}

// ── 1. add pushes without a separate reconcile ─────────────────────────
{
  const d = seed();
  const c = new FakeClient();
  const rc = quiet(() =>
    run(["user", "add", "bob", "--email", "bob@acme.test", "--groups", "acme__users",
      "--config-dir", d], c),
  );
  check(rc === 0, "user add exits 0");
  check(existsSync(join(d, "users", "bob.json")), "user add wrote the config file");
  check(c.users.has("bob"), "user add PUSHED the new user to the identity service (#482)");
  check(
    (c.users.get("bob")?.groups ?? []).includes("acme__users"),
    "the pushed user carries the membership from the same command",
  );
  // The push is a full reconcile: the pre-existing config reaches Authentik too.
  check(c.users.has("ann"), "the push reconciles the rest of config/people as well");
  check(c.groups.has("acme__users") && c.roles.has("admin"), "groups and roles were ensured");
}

// ── 2. modify pushes ───────────────────────────────────────────────────
{
  const d = seed();
  const c = new FakeClient();
  quiet(() => run(["user", "add", "bob", "--email", "bob@acme.test", "--config-dir", d], c));
  const rc = quiet(() =>
    run(["user", "modify", "bob", "--add-roles", "admin", "--config-dir", d], c),
  );
  check(rc === 0, "user modify exits 0");
  check(
    (c.users.get("bob")?.roles ?? []).includes("admin"),
    "user modify PUSHED the role grant (#482)",
  );
}

// ── 3. delete pushes the removal ───────────────────────────────────────
// The regression this guards: reconcile is driven by what config CONTAINS, so
// without an explicit push a deleted user simply stays in Authentik.
{
  const d = seed();
  const c = new FakeClient();
  quiet(() => run(["user", "add", "bob", "--email", "bob@acme.test", "--config-dir", d], c));
  check(c.users.has("bob"), "precondition: bob exists in the identity service");
  const rc = quiet(() => run(["user", "delete", "bob", "--config-dir", d], c));
  check(rc === 0, "user delete exits 0");
  check(!existsSync(join(d, "users", "bob.json")), "user delete removed the config file");
  check(!c.users.has("bob"), "user delete PUSHED the removal to the identity service (#482)");
}

// ── 4. group + role delete push their removal too ──────────────────────
{
  const d = seed();
  const c = new FakeClient();
  quiet(() => run(["group", "add", "acme__extra", "--ownerOrg", "acme", "--config-dir", d], c));
  check(c.groups.has("acme__extra"), "group add pushed the group");
  quiet(() => run(["group", "delete", "acme__extra", "--config-dir", d], c));
  check(!c.groups.has("acme__extra"), "group delete pushed the removal (#482)");

  quiet(() => run(["role", "add", "editor", "--config-dir", d], c));
  check(c.roles.has("editor"), "role add pushed the role");
  quiet(() => run(["role", "delete", "editor", "--config-dir", d], c));
  check(!c.roles.has("editor"), "role delete pushed the removal (#482)");
}

// ── 5. --no-reconcile stages config only ───────────────────────────────
{
  const d = seed();
  const c = new FakeClient();
  const rc = quiet(() =>
    run(["user", "add", "carl", "--email", "carl@acme.test", "--no-reconcile", "--config-dir", d], c),
  );
  check(rc === 0, "--no-reconcile exits 0");
  check(existsSync(join(d, "users", "carl.json")), "--no-reconcile still wrote the config");
  check(c.log.length === 0, "--no-reconcile made NO identity-service calls");
}

// ── 6. a rejected write never reaches the identity service ─────────────
{
  const d = seed();
  const c = new FakeClient();
  const rc = quiet(() =>
    run(["user", "add", "dana", "--email", "dana@acme.test", "--roles", "nonesuch",
      "--config-dir", d], c),
  );
  check(rc === 1, "an invalid write exits 1");
  check(!existsSync(join(d, "users", "dana.json")), "the rejected write left no config file");
  check(c.log.length === 0, "the rejected write made NO identity-service calls");
}

// ── 7. a failing push reports failure (config stays written) ───────────
{
  const d = seed();
  const c = new FakeClient();
  c.failOn.add("ensureGroup"); // the identity service rejects part of the plan
  const rc = quiet(() =>
    run(["user", "add", "erin", "--email", "erin@acme.test", "--config-dir", d], c),
  );
  check(rc === 1, "a failing push exits 1 (the operator must know it did not land)");
  check(
    existsSync(join(d, "users", "erin.json")),
    "a failing push leaves the written config in place — re-run reconcile, do not redo the edit",
  );
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
