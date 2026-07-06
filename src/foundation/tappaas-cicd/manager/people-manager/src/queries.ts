// queries.ts — pure relationship queries over the People model, used by the
// `--deep` list views in main.ts. No I/O, no CLI concerns: kept out of main.ts
// so unit tests can import them directly.

import { PeopleModel } from "./types";

// org → its groups (group.ownerOrg == org); group → its users
// (user.memberOf includes group); org → child orgs (o.parentOrg == org).
export function groupsOfOrg(model: PeopleModel, org: string): string[] {
  return Array.from(model.groups.values()).filter((g) => g.ownerOrg === org).map((g) => g.name).sort();
}

export function usersOfGroup(model: PeopleModel, group: string): string[] {
  return Array.from(model.users.values()).filter((u) => (u.memberOf ?? []).includes(group)).map((u) => u.name).sort();
}

export function childOrgs(model: PeopleModel, org: string): string[] {
  return Array.from(model.organizations.values()).filter((o) => o.parentOrg === org).map((o) => o.name).sort();
}

// A top-level org has no parent, or a parent that no longer exists.
export function orgRoots(model: PeopleModel, names: string[]): string[] {
  return names.filter((n) => {
    const p = model.organizations.get(n)?.parentOrg;
    return !p || !model.organizations.has(p);
  });
}

// JSON shapes for --deep --json.
export function deepGroup(model: PeopleModel, group: string): Record<string, unknown> {
  const g = model.groups.get(group);
  return {
    group,
    ownerOrg: g?.ownerOrg ?? "",
    roles: g?.roles ?? [],
    users: usersOfGroup(model, group).map((u) => ({ user: u, roles: model.users.get(u)?.roles ?? [] })),
  };
}

export function deepOrg(model: PeopleModel, org: string): Record<string, unknown> {
  const o = model.organizations.get(org);
  return {
    org,
    owner: o?.owner ?? "",
    groups: groupsOfOrg(model, org).map((g) => deepGroup(model, g)),
    subOrgs: childOrgs(model, org).map((c) => deepOrg(model, c)),
  };
}
