// types.ts — the People entity model (mirrors src/foundation/schemas/*-fields.json)
// plus the PrimitiveClient interface (the identity-controller boundary) and the
// reconcile plan shapes.

// ── People config entities ───────────────────────────────────────────
export interface Role {
  name: string;
  displayName: string;
  description?: string;
}

export interface Organization {
  name: string;
  type?: string;
  displayName: string;
  owner: string;
  parentOrg?: string | null;
}

export interface Group {
  name: string;
  type?: string;
  displayName: string;
  ownerOrg: string;
  roles?: string[];
}

export type UserState = "planned" | "active" | "suspended" | "terminated";

export interface User {
  name: string;
  displayName: string;
  primaryEmail: string;
  state?: UserState;
  memberOf?: string[];
  roles?: string[];
}

// The loaded + indexed people domain.
export interface PeopleModel {
  roles: Map<string, Role>;
  organizations: Map<string, Organization>;
  groups: Map<string, Group>;
  users: Map<string, User>;
}

// ── identity-controller primitive views ──────────────────────────────
// Shape returned by `authentik-manager list-users`.
export interface AkUser {
  name: string;
  active: boolean;
  email: string;
  displayName: string;
  groups: string[]; // non-role group memberships
  roles: string[]; // role-marked group memberships
}

// Shape returned by list-groups / list-roles.
export interface AkNamed {
  name: string;
  displayName: string;
}

// ── PrimitiveClient — one method per identity-controller verb ─────────
// The reconcile engine depends ONLY on this interface; tests inject an
// in-memory fake, production uses CliPrimitiveClient (spawnSync).
export interface PrimitiveClient {
  listUsers(): AkUser[];
  listGroups(): AkNamed[];
  listRoles(): AkNamed[];
  getUser(name: string): AkUser | null;
  ensureUser(name: string, email: string, display: string, inactive: boolean): void;
  disableUser(name: string): void;
  deleteUser(name: string): void;
  ensureGroup(name: string, display: string): void;
  ensureRole(name: string, display: string): void;
  addMember(user: string, group: string): void;
  removeMember(user: string, group: string): void;
  assignRole(user: string, role: string): void;
  unassignRole(user: string, role: string): void;
}

// ── Reconcile plan ────────────────────────────────────────────────────
export type ActionKind =
  | "ensure-role"
  | "ensure-group"
  | "ensure-user"
  | "disable-user"
  | "delete-user"
  | "add-member"
  | "remove-member"
  | "assign-role"
  | "unassign-role";

export interface Action {
  kind: ActionKind;
  // Human-readable target description for the plan summary.
  target: string;
  // Primitive invocation, applied via the client.
  apply(client: PrimitiveClient): void;
}

export interface Plan {
  actions: Action[];
  warnings: string[]; // attribute drift etc. — never auto-fixed
}
