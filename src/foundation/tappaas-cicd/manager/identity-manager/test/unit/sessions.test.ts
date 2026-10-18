// sessions.test.ts — ending a person's app sessions when they lose access
// (ADR-032 P4). Offline: a FakeClient for the plan, a temp config tree for
// module discovery, a fake hook runner.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { PeopleModel, User } from "../../src/types";
import { computePlan, snapshot } from "../../src/reconcile";
import { REVOKE_HOOK, revokeSessions, sessionRevokers, usersLosingAccess } from "../../src/sessions";
import { FakeClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) { passed++; console.log(`  ok: ${msg}`); } else { failed++; console.log(`  FAIL: ${msg}`); }
}
function model(users: User[], groups: string[] = []): PeopleModel {
  const m: PeopleModel = { roles: new Map(), organizations: new Map(), groups: new Map(), users: new Map() };
  m.organizations.set("orgA", { name: "orgA", displayName: "A", owner: "owner" } as never);
  for (const g of groups) m.groups.set(g, { name: g, displayName: g, ownerOrg: "orgA", roles: [] } as never);
  for (const u of users) m.users.set(u.name, u);
  return m;
}
const seed = (c: FakeClient, name: string, groups: string[]) =>
  c.seedUser({ name, active: true, email: `${name}@x.io`, displayName: name, groups, roles: [] });

// ── who loses access, from the plan ────────────────────────────────────
{
  // removed from a managed group (still active)
  const c = new FakeClient(); c.seedGroup("users"); seed(c, "ann", ["users"]);
  const p = computePlan(model([{ name: "ann", displayName: "ann", primaryEmail: "ann@x.io", state: "active", memberOf: [] } as User], ["users"]), snapshot(c));
  check(JSON.stringify(usersLosingAccess(p.actions)) === '["ann"]', "a user removed from a managed group loses access");
}
{
  // suspended: disabled + groups stripped — named once
  const c = new FakeClient(); c.seedGroup("users"); seed(c, "bob", ["users"]);
  const p = computePlan(model([{ name: "bob", displayName: "bob", primaryEmail: "bob@x.io", state: "suspended", memberOf: ["users"] } as User], ["users"]), snapshot(c));
  check(JSON.stringify(usersLosingAccess(p.actions)) === '["bob"]', "a suspended user loses access, named once for the disable and the group removal");
}
{
  // terminated: deleted
  const c = new FakeClient(); seed(c, "cy", []);
  const p = computePlan(model([{ name: "cy", displayName: "cy", primaryEmail: "cy@x.io", state: "terminated" } as User]), snapshot(c));
  check(JSON.stringify(usersLosingAccess(p.actions)) === '["cy"]', "a terminated user loses access");
}
{
  // gains access only: nobody
  const c = new FakeClient(); c.seedGroup("users");
  const p = computePlan(model([{ name: "dee", displayName: "dee", primaryEmail: "dee@x.io", state: "active", memberOf: ["users"] } as User], ["users"]), snapshot(c));
  check(usersLosingAccess(p.actions).length === 0, "a user who only gains access ends no sessions");
}

// ── which modules end sessions ────────────────────────────────────────
const root = mkdtempSync(join(tmpdir(), "im-sessions-"));
try {
  const cfg = join(root, "config"); mkdirSync(cfg);
  const withHook = join(root, "src", "jellyfin"); mkdirSync(withHook, { recursive: true });
  writeFileSync(join(withHook, REVOKE_HOOK), "#!/usr/bin/env bash\n");
  const without = join(root, "src", "forgejo"); mkdirSync(without, { recursive: true });
  writeFileSync(join(cfg, "jellyfin.json"), JSON.stringify({ vmname: "jellyfin", vmid: 360, moduleSource: withHook }));
  writeFileSync(join(cfg, "forgejo.json"), JSON.stringify({ vmname: "forgejo", vmid: 330, moduleSource: without }));
  const oldDir = join(root, "src", "old"); mkdirSync(oldDir, { recursive: true });
  writeFileSync(join(oldDir, REVOKE_HOOK), "#!/usr/bin/env bash\n");
  writeFileSync(join(cfg, "old.json"), JSON.stringify({ vmname: "old", vmid: 331, location: oldDir }));
  writeFileSync(join(cfg, "site.json"), JSON.stringify({ name: "site" }));
  const r = sessionRevokers(cfg);
  check(JSON.stringify(r.map((x) => x.module)) === '["jellyfin","old"]',
    "the deployed modules whose source ships revoke-sessions.sh (moduleSource, or location before #609)");

  // ── running the hooks ──────────────────────────────────────────────
  const calls: string[] = [];
  const out = revokeSessions(["ann", "bob"], r, (dir, user) => { calls.push(`${dir.split("/").pop()}:${user}`); return user === "bob" && dir === withHook ? 1 : 0; });
  check(calls.length === 4, "every user, every module with the hook");
  check(out.failed.length === 1 && out.failed[0] === "jellyfin: bob", "a failing hook is reported, not thrown");
  check(out.done.length === 3, "…and the rest still run");
  const thrown = revokeSessions(["ann"], r.slice(0, 1), () => { throw new Error("no bash"); });
  check(thrown.failed.length === 1, "a hook that cannot start counts as failed");
} finally {
  rmSync(root, { recursive: true, force: true });
}

console.log(`\nsessions: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
