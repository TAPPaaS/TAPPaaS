// cmdb-report.test.ts — `identity-manager report --json` (ADR-040 D3, D4):
// organizations and roles by name, groups and users by their Authentik uuid,
// member-of; reconcile's side-effect observation; a write verb's change, with
// its job; a delete's end.

import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { run } from "../../src/main";
import { AuthentikUnreachable } from "../../src/primitives";
import { AkUser } from "../../src/types";
import { FakeClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

function capture(f: () => unknown): string[] {
  const out: string[] = [];
  const log = console.log;
  const err = console.error;
  console.log = (m: string) => void out.push(String(m));
  console.error = (m: string) => void out.push(String(m));
  try {
    f();
  } finally {
    console.log = log;
    console.error = err;
  }
  return out;
}

type Obj = Record<string, any>;

// config/identities under a root of its own: the spool is config/.cmdb-spool.
function seed(): { root: string; dir: string } {
  const root = mkdtempSync(join(tmpdir(), "id-cmdb-"));
  const dir = join(root, "identities");
  for (const sub of ["roles", "organizations", "groups", "users"]) mkdirSync(join(dir, sub), { recursive: true });
  const w = (sub: string, name: string, o: unknown): void => writeFileSync(join(dir, sub, `${name}.json`), JSON.stringify(o, null, 2));
  w("roles", "admin", { name: "admin", displayName: "Administrator" });
  w("roles", "user", { name: "user", displayName: "User" });
  w("organizations", "acme", { name: "acme", type: "company", displayName: "Acme", owner: "ann" });
  w("groups", "acme__users", { name: "acme__users", type: "team", displayName: "Acme users", ownerOrg: "acme", roles: ["user"] });
  w("users", "ann", { name: "ann", displayName: "Ann", primaryEmail: "ann@acme.test", state: "active", memberOf: ["acme__users"], roles: ["admin"] });
  return { root, dir };
}

function liveClient(): FakeClient {
  const c = new FakeClient();
  c.roles.add("admin");
  c.roles.add("user");
  c.groups.add("acme__users");
  const ann: AkUser = { name: "ann", active: true, email: "ann@acme.test", displayName: "Ann", groups: ["acme__users"], roles: ["admin", "user"] };
  c.users.set("ann", ann);
  return c;
}

const spooled = (root: string): Obj[] => {
  const d = join(root, ".cmdb-spool");
  try {
    return readdirSync(d).filter((f) => f.endsWith(".json")).sort().map((f) => JSON.parse(readFileSync(join(d, f), "utf8")));
  } catch {
    return [];
  }
};

// ── report --json ──────────────────────────────────────────────────────
{
  const { dir } = seed();
  let rc = -1;
  const out = capture(() => (rc = run(["report", "--json", "--config-dir", dir], liveClient())));
  check(rc === 0, `report --json exits 0 (${out.join("\n").slice(0, 300)})`);
  const r = JSON.parse(out.join("\n")) as Obj;
  const one = (cls: string, name: string): Obj | undefined => r.objects.find((o: Obj) => o.class === cls && o.name === name);
  check(r.source === "identity-manager" && r.kind === "observation", "an observation by identity-manager");
  check(one("organization", "acme")?.attributes?.displayName === "Acme", "the organization, by name");
  check(one("organization", "acme")?.attributes?.desired?.file === "identities/organizations/acme.json", "its desired record");
  check(!!one("role", "admin") && one("role", "user")?.attributes?.stage === "operational", "the roles");
  const g = one("group", "acme__users");
  check(g?.attributes?.uuid === "uuid-group-acme__users" && g?.attributes?.roles?.[0] === "user", "the group, by its uuid, with its roles");
  const u = one("user", "ann");
  check(u?.attributes?.uuid === "uuid-user-ann" && u?.attributes?.username === "ann" && u?.attributes?.enabled === true, "the user: uuid, username, enabled");
  check(u?.attributes?.email === "ann@acme.test", "the user's email");
  check(r.relations?.some((x: Obj) => x.type === "member-of" && x.from?.ref === u?.ref && x.to?.ref === g?.ref), "user member-of group");
}

// ── Authentik down: organizations and roles only ───────────────────────
{
  const { dir } = seed();
  class Down extends FakeClient {
    listUsers(): AkUser[] {
      throw new AuthentikUnreachable("no answer");
    }
  }
  let rc = -1;
  const out = capture(() => (rc = run(["report", "--json", "--config-dir", dir], new Down())));
  const r = JSON.parse(out.filter((l) => !l.includes("[Warning]")).join("\n")) as Obj;
  check(rc === 0 && out.some((l) => l.includes("Authentik unreachable")), "an unreachable Authentik warns");
  check(r.objects.some((o: Obj) => o.class === "organization") && !r.objects.some((o: Obj) => o.class === "user" || o.class === "group"), "and reports organizations and roles only");
}

// ── a write verb's change, with the console job ────────────────────────
{
  const { root, dir } = seed();
  const saved = { ...process.env };
  process.env.TAPPAAS_CMDB = "";
  process.env.CMDB_SOCKET = join(root, "no.sock");
  delete process.env.TAPPAAS_JOB_ID;
  process.env.TAPPAAS_JOB = "20261030120000-ffeedd"; // asset-reports' spelling, read too
  try {
    const c = liveClient();
    capture(() => run(["user", "add", "bob", "--email", "bob@acme.test", "--groups", "acme__users", "--config-dir", dir], c));
    capture(() => run(["user", "delete", "bob", "--config-dir", dir], c));
  } finally {
    for (const k of ["TAPPAAS_CMDB", "CMDB_SOCKET", "TAPPAAS_JOB", "TAPPAAS_JOB_ID"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
  const reports = spooled(root);
  const changes = reports.filter((r) => r.kind === "change");
  check(reports.some((r) => r.kind === "observation"), "the reconcile a write pushes with reports what it read");
  check(changes.length === 2, `two changes (${changes.length})`);
  const add = changes[0];
  check(add?.verb === "user add bob" && add?.job === "20261030120000-ffeedd", `the change carries its verb and job (${add?.verb}, ${add?.job})`);
  const bob = add?.objects?.find((o: Obj) => o.class === "user" && o.name === "bob");
  check(bob?.attributes?.uuid === "uuid-user-bob", "the added user, with the uuid Authentik gave it");
  check(add?.relations?.some((x: Obj) => x.type === "member-of" && x.from?.ref === bob?.ref), "and its membership");
  const del = changes[1]?.objects?.find((o: Obj) => o.class === "user" && o.name === "bob");
  check(del?.end === true && del?.attributes?.uuid === "uuid-user-bob", "a deleted user ends, by its uuid");
}

console.log(`cmdb-report: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
