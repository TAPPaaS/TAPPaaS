// cmdb-report.ts — what identity-manager reports to the CMDB (ADR-040 D3, D4):
// the organizations, roles, groups and users of config/identities, as the
// identity service has them.
//
// A user and a group are known by their Authentik UUID (D5), so only the ones
// Authentik answers for are reported; organizations and roles are known by
// their name and are reported from config/ even when it does not answer. A
// user is a member-of the groups Authentik has them in. A group with no config
// file that a module or Authentik itself declares (declared.ts) has that
// declaration as its desired record: it is not unmanaged. So has a user the
// identity module's bootstrap declares (akadmin, an outpost's account).
//
// Not reported: a group's owning organization and an organization's parent —
// the metamodel has no relation for either yet (owned-by joins an environment
// to its organization).

import { CmdbObject, CmdbRelation, CmdbReport } from "../../../lib/ts/src/cmdb";
import { compact } from "../../../lib/ts/src/cmdb-source";
import { AkDiscovery, AkNamed, AkUser, Action, PeopleModel } from "./types";
import { DeclaredGroup } from "./declared";

export const SOURCE = "identity-manager";

export interface IdentityRead {
  users: AkUser[];
  groups: AkNamed[];
  roles: AkNamed[];
}

const desired = (dir: string, name: string): { file: string } => ({ file: `identities/${dir}/${name}.json` });

/** Which of the plane's objects the given names select (all when absent). */
export interface Only {
  organizations?: Set<string>;
  roles?: Set<string>;
  groups?: Set<string>;
  users?: Set<string>;
}

/** config/identities and what Authentik says (null: it did not answer). */
export function identityObservation(model: PeopleModel, live: IdentityRead | null, only?: Only, declared?: Map<string, DeclaredGroup>, declaredUser?: (name: string) => DeclaredGroup | undefined): CmdbReport {
  const objects: CmdbObject[] = [];
  const relations: CmdbRelation[] = [];
  const want = (set: Set<string> | undefined, name: string): boolean => !only || (set?.has(name) ?? false);

  for (const o of model.organizations.values()) {
    if (!want(only?.organizations, o.name)) continue;
    objects.push({ class: "organization", name: o.name, attributes: compact({ displayName: o.displayName, desired: desired("organizations", o.name), stage: "operational" }) });
  }
  const liveRoles = new Map((live?.roles ?? []).map((r) => [r.name, r]));
  for (const r of model.roles.values()) {
    if (!want(only?.roles, r.name)) continue;
    objects.push({
      class: "role",
      name: r.name,
      attributes: compact({ displayName: r.displayName, description: r.description, desired: desired("roles", r.name), stage: live ? (liveRoles.has(r.name) ? "operational" : "created") : undefined }),
    });
  }
  if (!live) return { source: SOURCE, kind: "observation", objects, relations };

  const groupRef = new Map<string, string>();
  for (const g of live.groups) {
    if (!g.uuid || !want(only?.groups, g.name)) continue;
    const cfg = model.groups.get(g.name);
    objects.push({
      ref: `group/${g.name}`,
      class: "group",
      name: g.name,
      attributes: compact({
        uuid: g.uuid,
        displayName: cfg?.displayName ?? g.displayName,
        roles: cfg?.roles?.length ? cfg.roles : undefined,
        desired: cfg ? desired("groups", g.name) : declared?.get(g.name)?.declaredBy,
        stage: "operational",
      }),
    });
    groupRef.set(g.name, `group/${g.name}`);
  }
  for (const u of live.users) {
    if (!u.uuid || !want(only?.users, u.name)) continue;
    const cfg = model.users.get(u.name);
    objects.push({
      ref: `user/${u.name}`,
      class: "user",
      name: u.name,
      attributes: compact({
        uuid: u.uuid,
        username: u.name,
        email: u.email || cfg?.primaryEmail,
        enabled: u.active,
        displayName: u.displayName || cfg?.displayName,
        desired: cfg ? desired("users", u.name) : declaredUser?.(u.name)?.declaredBy,
        stage: "operational",
      }),
    });
    for (const g of u.groups) {
      const ref = groupRef.get(g);
      if (ref) relations.push({ type: "member-of", from: { ref: `user/${u.name}` }, to: { ref } });
      else if (only && model.groups.has(g)) {
        // the group is not in this change's batch: name it by its key
        const lg = live.groups.find((x) => x.name === g);
        if (lg?.uuid) {
          objects.push({ ref: `group/${g}`, class: "group", name: g, attributes: { uuid: lg.uuid } });
          groupRef.set(g, `group/${g}`);
          relations.push({ type: "member-of", from: { ref: `user/${u.name}` }, to: { ref: `group/${g}` } });
        }
      }
    }
  }
  return { source: SOURCE, kind: "observation", objects, relations };
}

/** The names a reconcile's actions touch, by kind (the actions name them in
 *  their target: "user jan", "jan ∈ g", "jan → r"). */
export function touchedBy(actions: Action[]): Required<Only> {
  const t: Required<Only> = { organizations: new Set(), roles: new Set(), groups: new Set(), users: new Set() };
  for (const a of actions) {
    const words = a.target.split(" ");
    if (a.kind === "ensure-role") t.roles.add(words[1]);
    else if (a.kind === "ensure-group") t.groups.add(words[1]);
    else if (a.kind === "ensure-user" || a.kind === "delete-user" || (a.kind === "disable-user" && words[0] === "user")) t.users.add(words[1]);
    else if (a.kind === "add-member" || a.kind === "remove-member") {
      t.users.add(words[0]);
      t.groups.add(words[2]);
    } else if (a.kind === "assign-role" || a.kind === "unassign-role") {
      t.users.add(words[0]);
      t.roles.add(words[2]);
    }
  }
  return t;
}

/** The ends a change makes: a deleted user or group (by its uuid, from the
 *  read before), a deleted organization or role (by name). */
export function endsOf(deleted: { kind: string; name: string }[], before: IdentityRead | null): CmdbObject[] {
  const out: CmdbObject[] = [];
  for (const d of deleted) {
    if (d.kind === "org" || d.kind === "organization") out.push({ class: "organization", name: d.name, end: true });
    else if (d.kind === "role") out.push({ class: "role", name: d.name, end: true });
    else {
      const list: { name: string; uuid?: string }[] = d.kind === "user" ? before?.users ?? [] : before?.groups ?? [];
      const uuid = list.find((x) => x.name === d.name)?.uuid;
      if (uuid) out.push({ class: d.kind === "user" ? "user" : "group", name: d.name, attributes: { uuid }, end: true });
    }
  }
  return out;
}

/** `report --discover` (D15): what Authentik holds beyond people, on the CI of
 *  the identity module — keep classes to the metamodel. The vm is named by
 *  its instance, as module-manager and site-manager report it. */
export function identityDiscovery(report: CmdbReport, d: AkDiscovery, instance = "identity"): CmdbReport {
  const authentik = { providers: d.providers, applications: d.applications, outposts: d.outposts, flows: d.flows };
  return { ...report, objects: [...(report.objects ?? []), { class: "vm", name: instance, attributes: { authentik } }] };
}
