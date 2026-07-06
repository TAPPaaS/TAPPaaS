// config.ts — load + validate the People domain from config/people/.
//
// "config/" means the TARGET system (~tappaas/config/people), per the ADR-007
// "Convention: config/ means the target system" note. Default path resolves
// from TAPPAAS_CONFIG (or /home/tappaas/config); tests pass an explicit dir
// (the fixture tree under test/fixtures/people/).

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import {
  asString,
  asStringArray,
  defaultConfigDir as configRoot,
} from "../../../lib/ts/src/config-io";
import { Group, Organization, PeopleModel, Role, User } from "./types";

// The People domain lives in the "people" SUBDIR of the shared config root
// (config-io.defaultConfigDir resolves TAPPAAS_CONFIG / CONFIG_DIR / target).
export function defaultConfigDir(): string {
  return join(configRoot(), "people");
}

function readJsonFiles(dir: string): unknown[] {
  if (!existsSync(dir)) return [];
  const out: unknown[] = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    const txt = readFileSync(join(dir, f), "utf8");
    try {
      out.push(JSON.parse(txt));
    } catch (e) {
      // Name the offending file — one malformed entity must fail loudly and
      // precisely, not crash every command with a raw stack trace.
      throw new Error(
        `malformed JSON in ${join(dir, f)}: ${e instanceof Error ? e.message : String(e)}`,
      );
    }
  }
  return out;
}

// ── per-kind decoders: raw JSON object → typed entity ──────────────────
// The ONE place the entity-shape defaults live ("company", "team", state
// fallback "active"). Used by loadPeople below AND by entity.ts's
// validate-with-candidate path, so both decode identically.

export function toRole(o: Record<string, unknown>): Role {
  return {
    name: asString(o.name),
    displayName: asString(o.displayName),
    description: typeof o.description === "string" ? o.description : "",
  };
}

export function toOrg(o: Record<string, unknown>): Organization {
  return {
    name: asString(o.name),
    type: typeof o.type === "string" ? o.type : "company",
    displayName: asString(o.displayName),
    owner: asString(o.owner),
    parentOrg: typeof o.parentOrg === "string" ? o.parentOrg : null,
  };
}

export function toGroup(o: Record<string, unknown>): Group {
  return {
    name: asString(o.name),
    type: typeof o.type === "string" ? o.type : "team",
    displayName: asString(o.displayName),
    ownerOrg: asString(o.ownerOrg),
    roles: asStringArray(o.roles),
  };
}

export function toUser(o: Record<string, unknown>): User {
  const state = asString(o.state);
  return {
    name: asString(o.name),
    displayName: asString(o.displayName),
    primaryEmail: asString(o.primaryEmail),
    state: (state === "planned" || state === "suspended" || state === "terminated"
      ? state
      : "active") as User["state"],
    memberOf: asStringArray(o.memberOf),
    roles: asStringArray(o.roles),
  };
}

export function loadPeople(peopleDir: string): PeopleModel {
  const model: PeopleModel = {
    roles: new Map(),
    organizations: new Map(),
    groups: new Map(),
    users: new Map(),
  };

  for (const raw of readJsonFiles(join(peopleDir, "roles"))) {
    const r = toRole(raw as Record<string, unknown>);
    model.roles.set(r.name, r);
  }

  for (const raw of readJsonFiles(join(peopleDir, "organizations"))) {
    const org = toOrg(raw as Record<string, unknown>);
    model.organizations.set(org.name, org);
  }

  for (const raw of readJsonFiles(join(peopleDir, "groups"))) {
    const g = toGroup(raw as Record<string, unknown>);
    model.groups.set(g.name, g);
  }

  for (const raw of readJsonFiles(join(peopleDir, "users"))) {
    const u = toUser(raw as Record<string, unknown>);
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
