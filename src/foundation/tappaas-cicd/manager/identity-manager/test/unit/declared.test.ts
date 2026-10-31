// declared.test.ts — groups a module or Authentik declares, and the users
// Authentik's bootstrap creates (no config file): the report gives them the
// declaration as their desired record, `list` and `show` name them with their
// origin, `modify/delete` refuse.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { run } from "../../src/main";
import { declaredGroups, declaredUser, declaredUsers } from "../../src/declared";
import { FakeClient } from "./fake-client";
import { cmdbProblems } from "../../../../lib/ts/test/cmdb-check";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

function capture(f: () => unknown): { out: string[]; rc: number } {
  const out: string[] = [];
  const log = console.log;
  const err = console.error;
  console.log = (m: string) => void out.push(String(m));
  console.error = (m: string) => void out.push(String(m));
  let rc = -1;
  try {
    rc = f() as number;
  } finally {
    console.log = log;
    console.error = err;
  }
  return { out, rc };
}

type Obj = Record<string, any>;

// config/ with the identity module, forgejo (an admin role), jellyfin in an
// environment (its group is the base name's), immich (no admin role), and
// config/identities with one model group and the adopted "authentik Admins".
function seed(): { root: string; dir: string } {
  const root = mkdtempSync(join(tmpdir(), "id-declared-"));
  const dir = join(root, "identities");
  for (const sub of ["roles", "organizations", "groups", "users"]) mkdirSync(join(dir, sub), { recursive: true });
  const cfg = (name: string, o: unknown): void => writeFileSync(join(root, `${name}.json`), JSON.stringify(o, null, 2));
  cfg("identity", { kind: "vm", vmname: "identity" });
  cfg("forgejo", { kind: "vm", dependsOn: ["identity:identity"], identity: { providesAdminRole: true } });
  cfg("jellyfin-test", { kind: "vm", environment: "test", dependsOn: ["identity:identity"], identity: { providesAdminRole: true } });
  cfg("immich", { kind: "vm", dependsOn: ["identity:identity"], identity: { launchPath: "/auth/login" } });
  cfg("zones", { lan: { vlan: 10 } });
  const w = (sub: string, name: string, o: unknown): void => writeFileSync(join(dir, sub, `${name}.json`), JSON.stringify(o, null, 2));
  w("roles", "user", { name: "user", displayName: "User" });
  w("organizations", "acme", { name: "acme", type: "company", displayName: "Acme" });
  w("groups", "users", { name: "users", type: "team", displayName: "Users", ownerOrg: "acme", roles: ["user"] });
  w("groups", "authentik Admins", { name: "authentik Admins", type: "access-set", displayName: "Authentik Admins", ownerOrg: "acme" });
  return { root, dir };
}

function live(): FakeClient {
  const c = new FakeClient();
  c.roles.add("user");
  for (const g of ["users", "forgejo-admins", "jellyfin-admins", "authentik Admins", "authentik Read-only", "stray"]) c.groups.add(g);
  return c;
}

// ── what declares a group ───────────────────────────────────────────────
{
  const { root } = seed();
  const d = declaredGroups(root);
  check(d.get("forgejo-admins")?.origin === "module forgejo" && d.get("forgejo-admins")?.declaredBy.file === "forgejo.json", "a module's admin role group, by its module");
  check(d.get("jellyfin-admins")?.declaredBy.file === "jellyfin-test.json" && d.get("jellyfin-admins")?.module === "jellyfin", "an environment's install: the base name's group");
  check(!d.has("immich-admins"), "a module without providesAdminRole declares none");
  check(d.get("authentik Read-only")?.origin === "Authentik built-in" && d.get("authentik Read-only")?.declaredBy.file === "identity.json", "Authentik's own groups, with the identity module");
  const bare = mkdtempSync(join(tmpdir(), "id-declared-bare-"));
  check(declaredGroups(bare).size === 0, "no modules, no identity module: nothing declared");
}

// ── the report: desired from what declares it ──────────────────────────
{
  const { dir } = seed();
  const { out, rc } = capture(() => run(["report", "--json", "--config-dir", dir], live()));
  check(rc === 0, `report --json exits 0 (${out.join("\n").slice(0, 300)})`);
  const r = JSON.parse(out.join("\n")) as Obj;
  const g = (name: string): Obj | undefined => r.objects.find((o: Obj) => o.class === "group" && o.name === name);
  check(g("forgejo-admins")?.attributes?.desired?.file === "forgejo.json" && g("forgejo-admins")?.attributes?.desired?.key === "identity", "a module's group: desired names the module's identity block");
  check(g("authentik Read-only")?.attributes?.desired?.file === "identity.json" && g("authentik Read-only")?.attributes?.desired?.key === "bootstrap", "a built-in: desired names the identity module's bootstrap");
  check(g("authentik Admins")?.attributes?.desired?.file === "identities/groups/authentik Admins.json", "a built-in the model has a file for stays the model's");
  check(g("users")?.attributes?.desired?.file === "identities/groups/users.json", "a model group as before");
  check(g("stray") !== undefined && g("stray")?.attributes?.desired === undefined, "a group nothing declares has no desired: unmanaged");
  check(cmdbProblems(r).length === 0, `the metamodel takes it: ${cmdbProblems(r).join("; ")}`);
}

// ── group list / show ──────────────────────────────────────────────────
{
  const { dir } = seed();
  const json = capture(() => run(["group", "list", "--json", "--config-dir", dir], live()));
  const names = JSON.parse(json.out.join("\n")) as string[];
  check(
    names.join(",") === ["authentik Admins", "authentik Agent-Users", "authentik Read-only", "forgejo-admins", "jellyfin-admins", "users"].join(","),
    `list --json: the model's and the declared, by name (${names.join(",")})`,
  );
  const human = capture(() => run(["group", "list", "--config-dir", dir], live())).out;
  check(human.includes("forgejo-admins  (module forgejo)") && human.includes("authentik Read-only  (Authentik built-in)"), "list: a declared group is marked by its origin");
  check(human.includes("users") && human.includes("authentik Admins"), "list: a model group is plain");
  const decl = JSON.parse(capture(() => run(["group", "list", "--declared", "--json", "--config-dir", dir], live())).out.join("\n")) as Obj[];
  check(decl.length === 4 && decl.every((d) => typeof d.origin === "string" && d.declaredBy?.file), "list --declared --json: the declared ones, with origin and declaredBy");
  const show = capture(() => run(["group", "show", "forgejo-admins", "--json", "--config-dir", dir], live()));
  const rec = JSON.parse(show.out.join("\n")) as Obj;
  check(show.rc === 0 && rec.origin === "module forgejo" && rec.editable === false && rec.declaredBy?.key === "identity", "show --json: origin, declaredBy, not editable");
  const model = JSON.parse(capture(() => run(["group", "show", "users", "--json", "--config-dir", dir], live())).out.join("\n")) as Obj;
  check(model.origin === undefined && model.ownerOrg === "acme", "show of a model group: its config record");
}

// ── modify / delete refuse a declared group ─────────────────────────────
{
  const { dir } = seed();
  for (const verb of ["modify", "delete"]) {
    const c = live();
    const args = verb === "modify" ? ["group", "modify", "forgejo-admins", "--displayName", "X", "--config-dir", dir] : ["group", "delete", "authentik Read-only", "--config-dir", dir];
    const r = capture(() => run(args, c));
    check(r.rc !== 0 && r.out.some((l) => l.includes("not a config group") && l.includes(verb === "modify" ? "module forgejo" : "Authentik built-in")), `group ${verb} refuses a declared group, naming its origin (${r.out.join(" | ").slice(0, 200)})`);
    check(c.groups.has(verb === "modify" ? "forgejo-admins" : "authentik Read-only"), `group ${verb}: Authentik untouched`);
  }
}

// ── Authentik's own users: akadmin and an outpost's account ─────────────
const OUTPOST = "ak-outpost-0f3c9a2be41d4c7b8e5a6d1f2c3b4a59";
function liveUsers(): FakeClient {
  const c = live();
  for (const name of ["akadmin", OUTPOST, "lars", "mallory"]) c.seedUser({ name, email: `${name}@x`, displayName: name, active: true, groups: [], roles: [] });
  return c;
}
function seedUsers(): { root: string; dir: string } {
  const s = seed();
  writeFileSync(join(s.dir, "users", "lars.json"), JSON.stringify({ name: "lars", displayName: "Lars", primaryEmail: "lars@x", memberOf: ["users"], roles: ["user"] }, null, 2));
  return s;
}
{
  const { root } = seedUsers();
  check(declaredUser(root, "akadmin")?.origin === "Authentik built-in" && declaredUser(root, "akadmin")?.declaredBy.key === "bootstrap", "akadmin: the identity module's bootstrap");
  check(declaredUser(root, OUTPOST)?.declaredBy.file === "identity.json", "an outpost's account: the same");
  check(declaredUser(root, "ak-outpost-") === undefined && declaredUser(root, "ak-outposted") === undefined && declaredUser(root, "mallory") === undefined, "other names: nothing declares them");
  check(declaredUsers(root).size === 1 && declaredUsers(root, [OUTPOST, "mallory"]).size === 2, "declaredUsers: akadmin, and the outpost accounts Authentik names");
  const bare = mkdtempSync(join(tmpdir(), "id-declared-bare-"));
  check(declaredUser(bare, "akadmin") === undefined && declaredUsers(bare).size === 0, "no identity module: no built-in users");
}
{
  const { dir } = seedUsers();
  const { out, rc } = capture(() => run(["report", "--json", "--config-dir", dir], liveUsers()));
  check(rc === 0, `report --json exits 0 (${out.join("\n").slice(0, 300)})`);
  const r = JSON.parse(out.join("\n")) as Obj;
  const u = (name: string): Obj | undefined => r.objects.find((o: Obj) => o.class === "user" && o.name === name);
  check(u("akadmin")?.attributes?.desired?.file === "identity.json" && u("akadmin")?.attributes?.desired?.key === "bootstrap", "report: akadmin's desired is the identity module's bootstrap");
  check(u(OUTPOST)?.attributes?.desired?.key === "bootstrap", "report: an outpost's account likewise");
  check(u("lars")?.attributes?.desired?.file === "identities/users/lars.json", "report: a model user as before");
  check(u("mallory") !== undefined && u("mallory")?.attributes?.desired === undefined, "report: a user nothing declares is unmanaged");
  check(cmdbProblems(r).length === 0, `the metamodel takes it: ${cmdbProblems(r).join("; ")}`);
}
{
  const { dir } = seedUsers();
  const names = JSON.parse(capture(() => run(["user", "list", "--json", "--config-dir", dir], liveUsers())).out.join("\n")) as string[];
  check(names.join(",") === [OUTPOST, "akadmin", "lars"].join(","), `user list --json: the model's and the built-ins (${names.join(",")})`);
  const human = capture(() => run(["user", "list", "--config-dir", dir], liveUsers())).out;
  check(human.includes("akadmin  (Authentik built-in)") && human.includes(`${OUTPOST}  (Authentik built-in)`) && human.includes("lars"), "user list: a built-in marked by its origin");
  const off = new (class extends FakeClient {
    listUsers(): never {
      throw new Error("Authentik unreachable");
    }
  })();
  const offNames = JSON.parse(capture(() => run(["user", "list", "--json", "--config-dir", dir], off)).out.join("\n")) as string[];
  check(offNames.join(",") === "akadmin,lars", `user list without Authentik: akadmin still (${offNames.join(",")})`);
  const decl = JSON.parse(capture(() => run(["user", "list", "--declared", "--json", "--config-dir", dir], liveUsers())).out.join("\n")) as Obj[];
  check(decl.length === 2 && decl.every((d) => d.origin === "Authentik built-in"), "user list --declared --json: the built-ins with their origin");
  const show = capture(() => run(["user", "show", OUTPOST, "--json", "--config-dir", dir], liveUsers()));
  const rec = JSON.parse(show.out.join("\n")) as Obj;
  check(show.rc === 0 && rec.origin === "Authentik built-in" && rec.editable === false, "user show of an outpost's account: origin, not editable");
  for (const verb of ["modify", "delete"]) {
    const c = liveUsers();
    const args = verb === "modify" ? ["user", "modify", "akadmin", "--displayName", "X", "--config-dir", dir] : ["user", "delete", OUTPOST, "--config-dir", dir];
    const r2 = capture(() => run(args, c));
    check(r2.rc !== 0 && r2.out.some((l) => l.includes("not a config user") && l.includes("Authentik built-in")), `user ${verb} refuses a built-in (${r2.out.join(" | ").slice(0, 200)})`);
    check(c.users.has(verb === "modify" ? "akadmin" : OUTPOST) && !c.log.some((l) => l.startsWith("delete") || l.startsWith("disable")), `user ${verb}: Authentik untouched`);
  }
}

console.log(`declared: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
