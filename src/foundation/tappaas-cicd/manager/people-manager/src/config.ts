// config.ts — load + validate the People domain from config/people/.
//
// "config/" means the TARGET system (~tappaas/config/people), per the ADR-007
// "Convention: config/ means the target system" note. Default path resolves
// from TAPPAAS_CONFIG (or /home/tappaas/config); tests pass an explicit dir
// (the fixture tree under test/fixtures/people/).

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { Group, Organization, PeopleModel, Role, User } from "./types";

export function defaultConfigDir(): string {
  const base = process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
  return join(base, "people");
}

function readJsonFiles(dir: string): unknown[] {
  if (!existsSync(dir)) return [];
  const out: unknown[] = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    const txt = readFileSync(join(dir, f), "utf8");
    out.push(JSON.parse(txt));
  }
  return out;
}

function asString(v: unknown): string {
  return typeof v === "string" ? v : "";
}
function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is string => typeof x === "string");
}

export function loadPeople(peopleDir: string): PeopleModel {
  const model: PeopleModel = {
    roles: new Map(),
    organizations: new Map(),
    groups: new Map(),
    users: new Map(),
  };

  for (const raw of readJsonFiles(join(peopleDir, "roles"))) {
    const o = raw as Record<string, unknown>;
    const r: Role = {
      name: asString(o.name),
      displayName: asString(o.displayName),
      description: typeof o.description === "string" ? o.description : "",
    };
    model.roles.set(r.name, r);
  }

  for (const raw of readJsonFiles(join(peopleDir, "organizations"))) {
    const o = raw as Record<string, unknown>;
    const org: Organization = {
      name: asString(o.name),
      type: typeof o.type === "string" ? o.type : "company",
      displayName: asString(o.displayName),
      owner: asString(o.owner),
      parentOrg: typeof o.parentOrg === "string" ? o.parentOrg : null,
    };
    model.organizations.set(org.name, org);
  }

  for (const raw of readJsonFiles(join(peopleDir, "groups"))) {
    const o = raw as Record<string, unknown>;
    const g: Group = {
      name: asString(o.name),
      type: typeof o.type === "string" ? o.type : "team",
      displayName: asString(o.displayName),
      ownerOrg: asString(o.ownerOrg),
      roles: asStringArray(o.roles),
    };
    model.groups.set(g.name, g);
  }

  for (const raw of readJsonFiles(join(peopleDir, "users"))) {
    const o = raw as Record<string, unknown>;
    const state = asString(o.state);
    const u: User = {
      name: asString(o.name),
      displayName: asString(o.displayName),
      primaryEmail: asString(o.primaryEmail),
      state: (state === "planned" || state === "suspended" || state === "terminated"
        ? state
        : "active") as User["state"],
      memberOf: asStringArray(o.memberOf),
      roles: asStringArray(o.roles),
    };
    model.users.set(u.name, u);
  }

  return model;
}

// Reference-integrity validation (mirrors validate-people.sh, but in-process so
// `sync` can refuse to run against a broken tree). Returns a list of errors;
// empty = valid.
export function validateRefs(m: PeopleModel): string[] {
  const errs: string[] = [];

  for (const org of m.organizations.values()) {
    if (org.owner && !m.users.has(org.owner)) {
      errs.push(`organization '${org.name}': owner references unknown user '${org.owner}'`);
    }
    if (org.parentOrg && !m.organizations.has(org.parentOrg)) {
      errs.push(
        `organization '${org.name}': parentOrg references unknown organization '${org.parentOrg}'`,
      );
    }
  }

  for (const g of m.groups.values()) {
    if (g.ownerOrg && !m.organizations.has(g.ownerOrg)) {
      errs.push(`group '${g.name}': ownerOrg references unknown organization '${g.ownerOrg}'`);
    }
    for (const role of g.roles ?? []) {
      if (!m.roles.has(role)) {
        errs.push(`group '${g.name}': roles[] references unknown role '${role}'`);
      }
    }
  }

  for (const u of m.users.values()) {
    for (const grp of u.memberOf ?? []) {
      if (!m.groups.has(grp)) {
        errs.push(`user '${u.name}': memberOf references unknown group '${grp}'`);
      }
    }
    for (const role of u.roles ?? []) {
      if (!m.roles.has(role)) {
        errs.push(`user '${u.name}': roles[] references unknown role '${role}'`);
      }
    }
  }

  return errs;
}
