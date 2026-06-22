// fake-client.ts — in-memory PrimitiveClient for offline reconcile unit tests.
//
// Mirrors the identity-controller's model: groups and roles are disjoint sets
// (roles are role-marked groups inside Authentik; from here they are separate).
// Records mutations so tests can assert exactly what the engine did, and so a
// second sync against the resulting state proves idempotency.

import { AkNamed, AkUser, PrimitiveClient } from "../../src/types";

export class FakeClient implements PrimitiveClient {
  groups = new Set<string>();
  roles = new Set<string>();
  users = new Map<string, AkUser>();
  log: string[] = [];

  // Seed a foreign or pre-existing entity (NOT via the recorded mutators).
  seedGroup(name: string): void {
    this.groups.add(name);
  }
  seedRole(name: string): void {
    this.roles.add(name);
  }
  seedUser(u: AkUser): void {
    this.users.set(u.name, { ...u, groups: [...u.groups], roles: [...u.roles] });
  }

  listUsers(): AkUser[] {
    return Array.from(this.users.values()).map((u) => ({
      ...u,
      groups: [...u.groups],
      roles: [...u.roles],
    }));
  }
  listGroups(): AkNamed[] {
    return Array.from(this.groups).map((n) => ({ name: n, displayName: n }));
  }
  listRoles(): AkNamed[] {
    return Array.from(this.roles).map((n) => ({ name: n, displayName: n }));
  }
  getUser(name: string): AkUser | null {
    const u = this.users.get(name);
    return u ? { ...u, groups: [...u.groups], roles: [...u.roles] } : null;
  }
  ensureUser(name: string, email: string, display: string, inactive: boolean): void {
    this.log.push(`ensure-user ${name} ${inactive ? "inactive" : "active"}`);
    const existing = this.users.get(name);
    if (existing) {
      existing.active = !inactive ? existing.active : false;
      return;
    }
    this.users.set(name, {
      name,
      active: !inactive,
      email,
      displayName: display,
      groups: [],
      roles: [],
    });
  }
  disableUser(name: string): void {
    this.log.push(`disable-user ${name}`);
    const u = this.users.get(name);
    if (u) u.active = false;
  }
  deleteUser(name: string): void {
    this.log.push(`delete-user ${name}`);
    this.users.delete(name);
  }
  ensureGroup(name: string, _display: string): void {
    this.log.push(`ensure-group ${name}`);
    this.groups.add(name);
  }
  ensureRole(name: string, _display: string): void {
    this.log.push(`ensure-role ${name}`);
    this.roles.add(name);
  }
  addMember(user: string, group: string): void {
    this.log.push(`add-member ${user} ${group}`);
    const u = this.users.get(user);
    if (u && !u.groups.includes(group)) u.groups.push(group);
  }
  removeMember(user: string, group: string): void {
    this.log.push(`remove-member ${user} ${group}`);
    const u = this.users.get(user);
    if (u) u.groups = u.groups.filter((g) => g !== group);
  }
  assignRole(user: string, role: string): void {
    this.log.push(`assign-role ${user} ${role}`);
    const u = this.users.get(user);
    if (u && !u.roles.includes(role)) u.roles.push(role);
  }
  unassignRole(user: string, role: string): void {
    this.log.push(`unassign-role ${user} ${role}`);
    const u = this.users.get(user);
    if (u) u.roles = u.roles.filter((r) => r !== role);
  }
}
