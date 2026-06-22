// reconcile.ts — the people → Authentik reconcile engine.
//
// Implements ADR-007 P1 "Sync semantics" — THREE concerns, each with its own
// rule:
//
//   (1) Entity existence: ADDITIVE. Managed roles/groups/users that are missing
//       in Authentik are created (ensure-*). Existing entities are never
//       deleted implicitly. Attribute drift (displayName / email) on an existing
//       entity is a WARNING, never an overwrite.
//
//   (2) Access reconciliation (managed ACTIVE users): membership + role
//       assignments are AUTHORITATIVE and reconciled bidirectionally — links in
//       the JSON but missing in Authentik are ADDED; managed links in Authentik
//       but no longer in the JSON are REMOVED. Scope guard: removal only touches
//       entities in the MANAGED SET (names present in config/people). A user's
//       membership in a FOREIGN group/role is never removed.
//
//   (3) State lifecycle:
//       planned    → no Authentik presence (not created)
//       active     → present + access reconciled per (2)
//       suspended  → account retained but disabled, and stripped of ALL roles +
//                    role-conferring MANAGED group memberships (no access)
//       terminated → deleted (the single governed deletion)
//
// Foreign entities (not in config/people) are first-class: never created,
// removed, modified, or flagged as drift.
//
// The engine depends only on PrimitiveClient (injected) — pure planning + apply.

import {
  AkUser,
  Action,
  Group,
  PeopleModel,
  Plan,
  PrimitiveClient,
  User,
} from "./types";

// Roles that reach a user: direct (User.roles) ∪ inherited (roles of each
// group in User.memberOf). Scoped to MANAGED roles/groups only.
export function desiredRolesForUser(m: PeopleModel, u: User): Set<string> {
  const roles = new Set<string>();
  for (const r of u.roles ?? []) {
    if (m.roles.has(r)) roles.add(r);
  }
  for (const gname of u.memberOf ?? []) {
    const g: Group | undefined = m.groups.get(gname);
    if (!g) continue; // foreign / dangling group — skip (validateRefs guards real config)
    for (const r of g.roles ?? []) {
      if (m.roles.has(r)) roles.add(r);
    }
  }
  return roles;
}

// Managed groups a user should belong to (the JSON memberOf, scoped to managed).
function desiredGroupsForUser(m: PeopleModel, u: User): Set<string> {
  const groups = new Set<string>();
  for (const gname of u.memberOf ?? []) {
    if (m.groups.has(gname)) groups.add(gname);
  }
  return groups;
}

// Snapshot of the relevant Authentik state, fetched once via the list-* verbs.
export interface AkSnapshot {
  users: AkUser[];
  groupNames: string[]; // from list-groups (excludes role-marked groups)
  roleNames: string[]; // from list-roles
}

export function computePlan(m: PeopleModel, snap: AkSnapshot): Plan {
  const actions: Action[] = [];
  const warnings: string[] = [];
  const current = snap.users;

  const byName = new Map<string, AkUser>();
  for (const u of current) byName.set(u.name, u);

  // The managed set: every name present in config/people.
  const managedGroups = new Set(m.groups.keys());
  const managedRoles = new Set(m.roles.keys());

  // ── (1) Entity existence: roles + groups (additive) ────────────────
  // Roles and groups have no "state"; ensure they exist. ensure-* is
  // create-if-missing, so we only emit an action when truly absent (idempotent).
  const akRoleNames = new Set(snap.roleNames);
  for (const r of m.roles.values()) {
    if (!akRoleNames.has(r.name)) {
      actions.push({
        kind: "ensure-role",
        target: `role ${r.name}`,
        apply: (c) => c.ensureRole(r.name, r.displayName),
      });
    }
  }
  const akGroupNames = new Set(snap.groupNames);
  for (const g of m.groups.values()) {
    if (!akGroupNames.has(g.name)) {
      actions.push({
        kind: "ensure-group",
        target: `group ${g.name}`,
        apply: (c) => c.ensureGroup(g.name, g.displayName),
      });
    }
  }

  // ── Users: existence + state + access ───────────────────────────────
  for (const u of m.users.values()) {
    const ak = byName.get(u.name) ?? null;
    const state = u.state ?? "active";

    if (state === "planned") {
      // No Authentik presence. (We do NOT create; if one already exists from a
      // prior state it is foreign-to-this-state — leave untouched, no delete.)
      continue;
    }

    if (state === "terminated") {
      if (ak) {
        actions.push({
          kind: "delete-user",
          target: `user ${u.name} (terminated)`,
          apply: (c) => c.deleteUser(u.name),
        });
      }
      continue;
    }

    // active | suspended both want the account to EXIST.
    if (!ak) {
      const inactive = state === "suspended";
      actions.push({
        kind: "ensure-user",
        target: `user ${u.name}${inactive ? " (suspended/inactive)" : ""}`,
        apply: (c) => c.ensureUser(u.name, u.primaryEmail, u.displayName, inactive),
      });
    } else {
      // Exists — check attribute drift (warn, never overwrite).
      if (ak.email && u.primaryEmail && ak.email !== u.primaryEmail) {
        warnings.push(
          `user '${u.name}': email drift (config '${u.primaryEmail}' vs Authentik '${ak.email}') — not overwritten`,
        );
      }
      if (ak.displayName && u.displayName && ak.displayName !== u.displayName) {
        warnings.push(
          `user '${u.name}': displayName drift (config '${u.displayName}' vs Authentik '${ak.displayName}') — not overwritten`,
        );
      }
    }

    if (state === "suspended") {
      // Disable + strip ALL roles and role-conferring MANAGED group memberships.
      // "stripped of all roles" — remove every managed role currently assigned,
      // and every managed group membership (groups carry roles). Foreign links
      // are left alone (scope guard).
      if (!ak || ak.active) {
        actions.push({
          kind: "disable-user",
          target: `user ${u.name} (suspend)`,
          apply: (c) => c.disableUser(u.name),
        });
      }
      const curGroups = ak ? ak.groups : [];
      const curRoles = ak ? ak.roles : [];
      for (const g of curGroups) {
        if (managedGroups.has(g)) {
          actions.push({
            kind: "remove-member",
            target: `${u.name} ∉ ${g} (suspend-strip)`,
            apply: (c) => c.removeMember(u.name, g),
          });
        }
      }
      for (const r of curRoles) {
        if (managedRoles.has(r)) {
          actions.push({
            kind: "unassign-role",
            target: `${u.name} ⊘ ${r} (suspend-strip)`,
            apply: (c) => c.unassignRole(u.name, r),
          });
        }
      }
      continue;
    }

    // ── (2) active: reconcile access bidirectionally (managed scope) ──
    const desiredGroups = desiredGroupsForUser(m, u);
    const desiredRoles = desiredRolesForUser(m, u);
    const curGroups = ak ? ak.groups : [];
    const curRoles = ak ? ak.roles : [];

    // Add missing memberships.
    for (const g of desiredGroups) {
      if (!curGroups.includes(g)) {
        actions.push({
          kind: "add-member",
          target: `${u.name} ∈ ${g}`,
          apply: (c) => c.addMember(u.name, g),
        });
      }
    }
    // Remove managed memberships no longer desired. Scope guard: only managed.
    for (const g of curGroups) {
      if (managedGroups.has(g) && !desiredGroups.has(g)) {
        actions.push({
          kind: "remove-member",
          target: `${u.name} ∉ ${g}`,
          apply: (c) => c.removeMember(u.name, g),
        });
      }
      // foreign group membership → never removed (no action)
    }

    // Add missing role assignments.
    for (const r of desiredRoles) {
      if (!curRoles.includes(r)) {
        actions.push({
          kind: "assign-role",
          target: `${u.name} → ${r}`,
          apply: (c) => c.assignRole(u.name, r),
        });
      }
    }
    // Remove managed role assignments no longer desired. Scope guard.
    for (const r of curRoles) {
      if (managedRoles.has(r) && !desiredRoles.has(r)) {
        actions.push({
          kind: "unassign-role",
          target: `${u.name} ⊘ ${r}`,
          apply: (c) => c.unassignRole(u.name, r),
        });
      }
      // foreign role → never removed
    }
  }

  return { actions, warnings };
}

// Fetch the Authentik snapshot the planner needs, via the list-* primitives.
export function snapshot(client: PrimitiveClient): AkSnapshot {
  return {
    users: client.listUsers(),
    groupNames: client.listGroups().map((g) => g.name),
    roleNames: client.listRoles().map((r) => r.name),
  };
}

// Apply a plan via the client. Returns count applied.
export function applyPlan(client: PrimitiveClient, plan: Plan): number {
  for (const a of plan.actions) {
    a.apply(client);
  }
  return plan.actions.length;
}
