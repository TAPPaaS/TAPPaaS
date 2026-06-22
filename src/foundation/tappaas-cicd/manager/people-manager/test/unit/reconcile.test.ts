// reconcile.test.ts — offline unit tests for the people→Authentik reconcile
// engine. No Authentik, no cluster; a FakeClient holds in-memory state.
//
// Covers every ADR-007 P1 "Test Criteria" reconcile bullet. Tiny assert
// harness (no test framework). Run via the test/unit tsconfig (see test.sh).

import {
  Group,
  Organization,
  PeopleModel,
  Role,
  User,
} from "../../src/types";
import {
  applyPlan,
  computePlan,
  desiredRolesForUser,
  snapshot,
} from "../../src/reconcile";
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

// ── model builders ────────────────────────────────────────────────────
function model(parts: {
  roles?: Role[];
  orgs?: Organization[];
  groups?: Group[];
  users?: User[];
}): PeopleModel {
  const m: PeopleModel = {
    roles: new Map(),
    organizations: new Map(),
    groups: new Map(),
    users: new Map(),
  };
  for (const r of parts.roles ?? []) m.roles.set(r.name, r);
  for (const o of parts.orgs ?? []) m.organizations.set(o.name, o);
  for (const g of parts.groups ?? []) m.groups.set(g.name, g);
  for (const u of parts.users ?? []) m.users.set(u.name, u);
  return m;
}

const ROLES: Role[] = [
  { name: "root", displayName: "Root" },
  { name: "admin", displayName: "Admin" },
  { name: "user", displayName: "User" },
];

function syncOnce(m: PeopleModel, c: FakeClient): number {
  const plan = computePlan(m, snapshot(c));
  return applyPlan(c, plan);
}

// ── 1. ensure-exists creates missing entities ──────────────────────────
{
  const m = model({
    roles: ROLES,
    orgs: [{ name: "orgA", displayName: "A", owner: "alice" }],
    groups: [{ name: "orgA__admins", displayName: "A admins", ownerOrg: "orgA", roles: ["admin"] }],
    users: [
      {
        name: "alice",
        displayName: "Alice",
        primaryEmail: "alice@x.io",
        state: "active",
        memberOf: ["orgA__admins"],
        roles: ["root"],
      },
    ],
  });
  const c = new FakeClient();
  syncOnce(m, c);
  check(c.roles.has("admin") && c.roles.has("root"), "ensure-exists creates missing roles");
  check(c.groups.has("orgA__admins"), "ensure-exists creates missing group");
  check(c.users.has("alice") && c.users.get("alice")!.active, "active user created");
  const alice = c.users.get("alice")!;
  check(alice.groups.includes("orgA__admins"), "active user membership reconciled (added)");
  // root = direct; admin = inherited via orgA__admins
  check(
    alice.roles.includes("root") && alice.roles.includes("admin"),
    "active user roles reconciled (direct + inherited)",
  );

  // 2. idempotent re-run → empty plan
  const plan2 = computePlan(m, snapshot(c));
  check(plan2.actions.length === 0, "idempotent: second sync produces an empty plan");
}

// ── 3. membership add then remove-from-json removes ─────────────────────
{
  const base = (member: string[]): PeopleModel =>
    model({
      roles: ROLES,
      orgs: [{ name: "orgA", displayName: "A", owner: "bob" }],
      groups: [
        { name: "orgA__admins", displayName: "A admins", ownerOrg: "orgA", roles: ["admin"] },
        { name: "orgA__users", displayName: "A users", ownerOrg: "orgA", roles: ["user"] },
      ],
      users: [
        {
          name: "bob",
          displayName: "Bob",
          primaryEmail: "bob@x.io",
          state: "active",
          memberOf: member,
        },
      ],
    });
  const c = new FakeClient();
  syncOnce(base(["orgA__admins", "orgA__users"]), c);
  check(c.users.get("bob")!.groups.length === 2, "membership added for both groups");
  // remove orgA__users from JSON
  syncOnce(base(["orgA__admins"]), c);
  const bob = c.users.get("bob")!;
  check(
    bob.groups.includes("orgA__admins") && !bob.groups.includes("orgA__users"),
    "membership removed when dropped from JSON (bidirectional)",
  );
  check(
    !bob.roles.includes("user") && bob.roles.includes("admin"),
    "inherited role recomputed after membership removal",
  );
}

// ── 4. managed role removed; FOREIGN group membership NOT removed ───────
{
  const m = model({
    roles: ROLES,
    orgs: [{ name: "orgA", displayName: "A", owner: "carol" }],
    groups: [{ name: "orgA__users", displayName: "A users", ownerOrg: "orgA", roles: ["user"] }],
    users: [
      {
        name: "carol",
        displayName: "Carol",
        primaryEmail: "carol@x.io",
        state: "active",
        memberOf: ["orgA__users"],
        roles: [], // no direct role
      },
    ],
  });
  const c = new FakeClient();
  // Pre-existing state: carol has a MANAGED direct role she shouldn't, plus a
  // FOREIGN group + FOREIGN role the engine must never touch.
  c.seedRole("admin");
  c.seedRole("user");
  c.seedGroup("orgA__users");
  c.seedGroup("external-vendor-grp"); // foreign
  c.seedRole("vendor-role"); // foreign
  c.seedUser({
    name: "carol",
    active: true,
    email: "carol@x.io",
    displayName: "Carol",
    groups: ["orgA__users", "external-vendor-grp"],
    roles: ["admin", "vendor-role"],
  });
  syncOnce(m, c);
  const carol = c.users.get("carol")!;
  check(!carol.roles.includes("admin"), "managed role no longer in JSON is removed");
  check(carol.roles.includes("vendor-role"), "FOREIGN role assignment NOT removed");
  check(carol.groups.includes("external-vendor-grp"), "FOREIGN group membership NOT removed");
  check(carol.groups.includes("orgA__users"), "managed-and-desired membership retained");
  check(carol.roles.includes("user"), "inherited role from managed group present");
}

// ── 5. attribute drift warns, never overwrites ──────────────────────────
{
  const m = model({
    roles: ROLES,
    orgs: [{ name: "orgA", displayName: "A", owner: "dave" }],
    groups: [],
    users: [
      {
        name: "dave",
        displayName: "Dave New",
        primaryEmail: "new@x.io",
        state: "active",
      },
    ],
  });
  const c = new FakeClient();
  c.seedUser({
    name: "dave",
    active: true,
    email: "old@x.io",
    displayName: "Dave Old",
    groups: [],
    roles: [],
  });
  const plan = computePlan(m, snapshot(c));
  applyPlan(c, plan);
  check(plan.warnings.length === 2, "attribute drift (email + displayName) produces warnings");
  check(
    c.users.get("dave")!.email === "old@x.io" && c.users.get("dave")!.displayName === "Dave Old",
    "attributes NOT overwritten",
  );
  check(
    !plan.actions.some((a) => a.kind === "ensure-user"),
    "no ensure-user emitted for an existing user (no overwrite action)",
  );
}

// ── 6. planned not created ──────────────────────────────────────────────
{
  const m = model({
    roles: ROLES,
    orgs: [{ name: "orgA", displayName: "A", owner: "eve" }],
    users: [
      { name: "eve", displayName: "Eve", primaryEmail: "eve@x.io", state: "planned" },
    ],
  });
  const c = new FakeClient();
  syncOnce(m, c);
  check(!c.users.has("eve"), "planned user is NOT created in Authentik");
}

// ── 7. suspended: disabled + stripped of roles & role-conferring groups ─
{
  const m = model({
    roles: ROLES,
    orgs: [{ name: "orgA", displayName: "A", owner: "frank" }],
    groups: [{ name: "orgA__admins", displayName: "A admins", ownerOrg: "orgA", roles: ["admin"] }],
    users: [
      {
        name: "frank",
        displayName: "Frank",
        primaryEmail: "frank@x.io",
        state: "suspended",
        memberOf: ["orgA__admins"],
        roles: ["root"],
      },
    ],
  });
  const c = new FakeClient();
  c.seedRole("admin");
  c.seedRole("root");
  c.seedGroup("orgA__admins");
  c.seedGroup("external-grp"); // foreign — must survive
  c.seedUser({
    name: "frank",
    active: true,
    email: "frank@x.io",
    displayName: "Frank",
    groups: ["orgA__admins", "external-grp"],
    roles: ["admin", "root"],
  });
  syncOnce(m, c);
  const frank = c.users.get("frank")!;
  check(!frank.active, "suspended user disabled");
  check(frank.roles.length === 0, "suspended user stripped of ALL managed roles");
  check(!frank.groups.includes("orgA__admins"), "suspended: role-conferring managed group removed");
  check(frank.groups.includes("external-grp"), "suspended: FOREIGN group membership retained");
}

// ── 8. terminated deleted; foreign user untouched + not flagged ─────────
{
  const m = model({
    roles: ROLES,
    orgs: [{ name: "orgA", displayName: "A", owner: "grace" }],
    users: [
      { name: "grace", displayName: "Grace", primaryEmail: "grace@x.io", state: "terminated" },
    ],
  });
  const c = new FakeClient();
  c.seedUser({
    name: "grace",
    active: true,
    email: "grace@x.io",
    displayName: "Grace",
    groups: [],
    roles: [],
  });
  // A purely foreign user that is NOT in config at all.
  c.seedUser({
    name: "stranger",
    active: true,
    email: "s@x.io",
    displayName: "Stranger",
    groups: ["external-grp"],
    roles: [],
  });
  const plan = computePlan(m, snapshot(c));
  applyPlan(c, plan);
  check(!c.users.has("grace"), "terminated user deleted from Authentik");
  check(c.users.has("stranger"), "foreign user left untouched");
  check(
    !plan.warnings.some((w) => w.includes("stranger")) &&
      !plan.actions.some((a) => a.target.includes("stranger")),
    "foreign user not flagged as drift and not acted on",
  );
}

// ── 9. multi-role / multi-org user ──────────────────────────────────────
{
  const m = model({
    roles: ROLES,
    orgs: [
      { name: "orgA", displayName: "A", owner: "heidi" },
      { name: "orgB", displayName: "B", owner: "heidi", parentOrg: "orgA" },
    ],
    groups: [
      { name: "orgA__admins", displayName: "A admins", ownerOrg: "orgA", roles: ["admin"] },
      { name: "orgB__users", displayName: "B users", ownerOrg: "orgB", roles: ["user"] },
    ],
    users: [
      {
        name: "heidi",
        displayName: "Heidi",
        primaryEmail: "heidi@x.io",
        state: "active",
        memberOf: ["orgA__admins", "orgB__users"],
        roles: ["root"],
      },
    ],
  });
  // desiredRolesForUser should union direct(root) + inherited(admin,user)
  const dr = desiredRolesForUser(m, m.users.get("heidi")!);
  check(
    dr.has("root") && dr.has("admin") && dr.has("user") && dr.size === 3,
    "multi-org/multi-role: desired roles = direct ∪ inherited across orgs",
  );
  const c = new FakeClient();
  syncOnce(m, c);
  const h = c.users.get("heidi")!;
  check(h.groups.length === 2, "multi-org user joined groups across both orgs");
  check(h.roles.length === 3, "multi-org user assigned all 3 roles");
  check(computePlan(m, snapshot(c)).actions.length === 0, "multi-org user is idempotent");
}

// ── 10. --dry-run changes nothing (plan computed, not applied) ──────────
{
  const m = model({
    roles: ROLES,
    orgs: [{ name: "orgA", displayName: "A", owner: "ivan" }],
    groups: [{ name: "orgA__users", displayName: "A users", ownerOrg: "orgA", roles: ["user"] }],
    users: [
      {
        name: "ivan",
        displayName: "Ivan",
        primaryEmail: "ivan@x.io",
        state: "active",
        memberOf: ["orgA__users"],
      },
    ],
  });
  const c = new FakeClient();
  const plan = computePlan(m, snapshot(c)); // compute only — DO NOT apply (dry-run)
  check(plan.actions.length > 0, "dry-run computed a non-empty plan");
  check(c.log.length === 0, "dry-run applied NO mutations (log empty)");
  check(!c.users.has("ivan"), "dry-run did not create the user");
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
