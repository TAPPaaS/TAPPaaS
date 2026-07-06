// queries.test.ts — offline unit tests for the pure --deep relationship
// queries in src/queries.ts (groupsOfOrg, usersOfGroup, childOrgs, orgRoots,
// deepGroup, deepOrg). No Authentik, no disk: the model is built in memory.
// Tiny assert harness (no test framework), matching entity.test.ts.

import { PeopleModel } from "../../src/types";
import {
  childOrgs,
  deepGroup,
  deepOrg,
  groupsOfOrg,
  orgRoots,
  usersOfGroup,
} from "../../src/queries";

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
function eq(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

// ── in-memory model: acme (root) ← acme-eu (child); dangling-parent org ──
// acme owns groups zteam + admins (insertion order deliberately unsorted);
// acme-eu owns eu-staff. alice ∈ admins+eu-staff, bob ∈ admins, carol ∈ none.
function model(): PeopleModel {
  const m: PeopleModel = {
    roles: new Map(),
    organizations: new Map(),
    groups: new Map(),
    users: new Map(),
  };
  m.roles.set("admin", { name: "admin", displayName: "Admin" });
  m.organizations.set("acme", { name: "acme", displayName: "Acme", owner: "alice" });
  m.organizations.set("acme-eu", {
    name: "acme-eu",
    displayName: "Acme EU",
    owner: "bob",
    parentOrg: "acme",
  });
  m.organizations.set("orphan", {
    name: "orphan",
    displayName: "Orphan",
    owner: "",
    parentOrg: "no-such-org", // dangling parent → treated as a root
  });
  m.groups.set("zteam", { name: "zteam", displayName: "Z Team", ownerOrg: "acme" });
  m.groups.set("admins", {
    name: "admins",
    displayName: "Admins",
    ownerOrg: "acme",
    roles: ["admin"],
  });
  m.groups.set("eu-staff", { name: "eu-staff", displayName: "EU Staff", ownerOrg: "acme-eu" });
  m.users.set("alice", {
    name: "alice",
    displayName: "Alice",
    primaryEmail: "alice@acme.test",
    memberOf: ["admins", "eu-staff"],
    roles: ["admin"],
  });
  m.users.set("bob", {
    name: "bob",
    displayName: "Bob",
    primaryEmail: "bob@acme.test",
    memberOf: ["admins"],
  });
  m.users.set("carol", {
    name: "carol",
    displayName: "Carol",
    primaryEmail: "carol@acme.test",
  });
  return m;
}

const m = model();

// ── groupsOfOrg ─────────────────────────────────────────────────────────
check(eq(groupsOfOrg(m, "acme"), ["admins", "zteam"]), "groupsOfOrg returns the org's groups sorted");
check(eq(groupsOfOrg(m, "acme-eu"), ["eu-staff"]), "groupsOfOrg matches ownerOrg exactly");
check(eq(groupsOfOrg(m, "no-such-org"), []), "groupsOfOrg → [] for unknown org");

// ── usersOfGroup ────────────────────────────────────────────────────────
check(eq(usersOfGroup(m, "admins"), ["alice", "bob"]), "usersOfGroup returns members sorted");
check(eq(usersOfGroup(m, "eu-staff"), ["alice"]), "usersOfGroup checks memberOf inclusion");
check(eq(usersOfGroup(m, "zteam"), []), "usersOfGroup → [] for a memberless group");
check(eq(usersOfGroup(m, "no-such-group"), []), "usersOfGroup → [] for unknown group");

// ── childOrgs ───────────────────────────────────────────────────────────
check(eq(childOrgs(m, "acme"), ["acme-eu"]), "childOrgs returns orgs whose parentOrg matches");
check(eq(childOrgs(m, "acme-eu"), []), "childOrgs → [] for a leaf org");

// ── orgRoots ────────────────────────────────────────────────────────────
const allOrgs = Array.from(m.organizations.keys()).sort();
check(
  eq(orgRoots(m, allOrgs), ["acme", "orphan"]),
  "orgRoots keeps parentless orgs AND orgs with a dangling parent",
);
check(eq(orgRoots(m, ["acme-eu"]), []), "orgRoots drops an org whose parent exists");

// ── deepGroup ───────────────────────────────────────────────────────────
check(
  eq(deepGroup(m, "admins"), {
    group: "admins",
    ownerOrg: "acme",
    roles: ["admin"],
    users: [
      { user: "alice", roles: ["admin"] },
      { user: "bob", roles: [] },
    ],
  }),
  "deepGroup shape: ownerOrg + roles + sorted users with their roles",
);
check(
  eq(deepGroup(m, "no-such-group"), { group: "no-such-group", ownerOrg: "", roles: [], users: [] }),
  "deepGroup on an unknown group falls back to empty fields",
);

// ── deepOrg ─────────────────────────────────────────────────────────────
check(
  eq(deepOrg(m, "acme"), {
    org: "acme",
    owner: "alice",
    groups: [deepGroup(m, "admins"), deepGroup(m, "zteam")],
    subOrgs: [
      {
        org: "acme-eu",
        owner: "bob",
        groups: [deepGroup(m, "eu-staff")],
        subOrgs: [],
      },
    ],
  }),
  "deepOrg recurses into groups and child orgs",
);
check(
  // NOTE: "no-such-org" is NOT a fully-unknown name here — the fixture's
  // "orphan" org dangles its parentOrg at it, so deepOrg would (correctly)
  // list orphan as a child. Probe with a name nothing references at all.
  eq(deepOrg(m, "ghost-org"), { org: "ghost-org", owner: "", groups: [], subOrgs: [] }),
  "deepOrg on an unknown org falls back to empty fields",
);

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
