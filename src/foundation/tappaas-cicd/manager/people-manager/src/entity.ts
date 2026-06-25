// entity.ts — config-only CRUD for the People domain (ADR-007 #5).
//
// Admins drive verbs; they never hand-edit JSON. `add`/`modify`/`delete` WRITE
// the validated config under config/people/<dir>/<name>.json — they do NOT call
// Authentik. The operator runs `people-manager reconcile` afterwards to push
// config → live. Writes are atomic (mktemp+rename) and gated by validateRefs.

import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { loadPeople, validateRefs } from "./config";
import { Group, Organization, PeopleModel, Role, User } from "./types";

// Raised by the CRUD ops on a user-facing error (bad ref, missing entity, …).
// main.ts maps this to a `die()` (exit 1); tests assert on it.
export class EntityError extends Error {}

// ── kind → on-disk directory ───────────────────────────────────────────
export type Kind = "role" | "org" | "group" | "user";

export function normalizeKind(kind: string): Kind {
  switch (kind) {
    case "role":
      return "role";
    case "org":
    case "organization":
      return "org";
    case "group":
      return "group";
    case "user":
      return "user";
    default:
      throw new EntityError(`Unknown entity kind: ${kind}`);
  }
}

function dirFor(kind: Kind): string {
  switch (kind) {
    case "role":
      return "roles";
    case "org":
      return "organizations";
    case "group":
      return "groups";
    case "user":
      return "users";
  }
}

function pathFor(configDir: string, kind: Kind, name: string): string {
  return join(configDir, dirFor(kind), `${name}.json`);
}

// ── flag parsing ───────────────────────────────────────────────────────
// Field flags come as `--flag value` pairs. List fields additionally support
// `--add-<field> v` / `--remove-<field> v` (repeatable) for modify.
export interface FieldArgs {
  scalars: Map<string, string>; // --field value
  adds: Map<string, string[]>; // --add-field value (repeatable)
  removes: Map<string, string[]>; // --remove-field value (repeatable)
}

export function parseFieldArgs(args: string[]): FieldArgs {
  const scalars = new Map<string, string>();
  const adds = new Map<string, string[]>();
  const removes = new Map<string, string[]>();
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (!a.startsWith("--")) {
      throw new EntityError(`unexpected argument '${a}' (expected --field value)`);
    }
    const key = a.slice(2);
    const val = args[i + 1];
    if (val === undefined || val.startsWith("--")) {
      throw new EntityError(`flag '${a}' requires a value`);
    }
    i++;
    if (key.startsWith("add-")) {
      const f = key.slice(4);
      (adds.get(f) ?? adds.set(f, []).get(f)!).push(val);
    } else if (key.startsWith("remove-")) {
      const f = key.slice(7);
      (removes.get(f) ?? removes.set(f, []).get(f)!).push(val);
    } else {
      if (scalars.has(key)) throw new EntityError(`flag '--${key}' given more than once`);
      scalars.set(key, val);
    }
  }
  return { scalars, adds, removes };
}

// Comma-or-space split for list-valued scalar flags (e.g. --roles "admin,user").
function splitList(v: string): string[] {
  return v
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

// ── per-kind field schema ──────────────────────────────────────────────
// Declares which flags each kind accepts and which are list-valued, so the
// generic builder can validate flag names and apply add/remove correctly.
interface KindSchema {
  scalarFields: string[]; // accepted scalar flags
  listFields: string[]; // accepted list flags (support add/remove)
}

const SCHEMAS: Record<Kind, KindSchema> = {
  role: { scalarFields: ["displayName", "description"], listFields: [] },
  org: { scalarFields: ["type", "displayName", "owner", "parentOrg"], listFields: [] },
  group: { scalarFields: ["type", "displayName", "ownerOrg"], listFields: ["roles"] },
  user: {
    scalarFields: ["displayName", "primaryEmail", "email", "state"],
    listFields: ["memberOf", "groups", "roles"],
  },
};

// Flag aliases → canonical field name (per the prompt: --email, --groups).
function canonicalField(kind: Kind, flag: string): string {
  if (kind === "user") {
    if (flag === "email") return "primaryEmail";
    if (flag === "groups") return "memberOf";
  }
  return flag;
}

function knownFlag(kind: Kind, field: string): boolean {
  const s = SCHEMAS[kind];
  return s.scalarFields.includes(field) || s.listFields.includes(field);
}

function isListField(kind: Kind, field: string): boolean {
  return SCHEMAS[kind].listFields.includes(field);
}

// ── entity (de)serialization ───────────────────────────────────────────
// Read the raw JSON for an entity (preserving unknown fields would be nice but
// the model is fully typed; we round-trip through the typed shape).
function loadRaw(configDir: string, kind: Kind, name: string): Record<string, unknown> {
  const p = pathFor(configDir, kind, name);
  if (!existsSync(p)) throw new EntityError(`${kind} '${name}' not found (${p})`);
  return JSON.parse(readFileSync(p, "utf8")) as Record<string, unknown>;
}

// Build a fresh, well-shaped entity record from defaults + flags (add).
function buildNew(kind: Kind, name: string, fa: FieldArgs): Record<string, unknown> {
  const rec: Record<string, unknown> = { name };
  switch (kind) {
    case "role":
      rec.displayName = name;
      break;
    case "org":
      rec.type = "company";
      rec.displayName = name;
      rec.owner = "";
      break;
    case "group":
      rec.type = "team";
      rec.displayName = name;
      rec.ownerOrg = "";
      rec.roles = [];
      break;
    case "user":
      rec.displayName = name;
      rec.primaryEmail = "";
      rec.state = "active";
      rec.memberOf = [];
      rec.roles = [];
      break;
  }
  applyFields(kind, rec, fa);
  return rec;
}

// Apply flag changes onto a record in place (shared by add + modify).
function applyFields(kind: Kind, rec: Record<string, unknown>, fa: FieldArgs): void {
  // scalar sets
  for (const [flag, val] of fa.scalars) {
    const field = canonicalField(kind, flag);
    if (!knownFlag(kind, field)) {
      throw new EntityError(`${kind}: unknown flag '--${flag}'`);
    }
    if (isListField(kind, field)) {
      rec[field] = splitList(val); // --roles "a,b" replaces the whole list
    } else {
      rec[field] = val;
    }
  }
  // list add
  for (const [flag, vals] of fa.adds) {
    const field = canonicalField(kind, flag);
    if (!isListField(kind, field)) {
      throw new EntityError(`${kind}: '--add-${flag}' is not a list field`);
    }
    const cur = new Set(asArray(rec[field]));
    for (const v of vals) for (const item of splitList(v)) cur.add(item);
    rec[field] = Array.from(cur);
  }
  // list remove
  for (const [flag, vals] of fa.removes) {
    const field = canonicalField(kind, flag);
    if (!isListField(kind, field)) {
      throw new EntityError(`${kind}: '--remove-${flag}' is not a list field`);
    }
    const toRemove = new Set<string>();
    for (const v of vals) for (const item of splitList(v)) toRemove.add(item);
    rec[field] = asArray(rec[field]).filter((x) => !toRemove.has(x));
  }
}

function asArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is string => typeof x === "string");
}

// ── validation: re-load the model WITH the candidate entity merged in ───
// We build the in-memory model from disk, replace/add the candidate, run
// validateRefs, AND verify no other entity is left dangling. Returns errors.
function validateWithCandidate(
  configDir: string,
  kind: Kind,
  name: string,
  rec: Record<string, unknown> | null, // null = candidate is being deleted
): string[] {
  const model = loadPeople(configDir);
  applyCandidateToModel(model, kind, name, rec);
  return validateRefs(model);
}

function applyCandidateToModel(
  model: PeopleModel,
  kind: Kind,
  name: string,
  rec: Record<string, unknown> | null,
): void {
  switch (kind) {
    case "role": {
      if (rec === null) model.roles.delete(name);
      else model.roles.set(name, toRole(rec));
      break;
    }
    case "org": {
      if (rec === null) model.organizations.delete(name);
      else model.organizations.set(name, toOrg(rec));
      break;
    }
    case "group": {
      if (rec === null) model.groups.delete(name);
      else model.groups.set(name, toGroup(rec));
      break;
    }
    case "user": {
      if (rec === null) model.users.delete(name);
      else model.users.set(name, toUser(rec));
      break;
    }
  }
}

function toRole(o: Record<string, unknown>): Role {
  return {
    name: String(o.name ?? ""),
    displayName: String(o.displayName ?? ""),
    description: typeof o.description === "string" ? o.description : "",
  };
}
function toOrg(o: Record<string, unknown>): Organization {
  return {
    name: String(o.name ?? ""),
    type: typeof o.type === "string" ? o.type : "company",
    displayName: String(o.displayName ?? ""),
    owner: typeof o.owner === "string" ? o.owner : "",
    parentOrg: typeof o.parentOrg === "string" ? o.parentOrg : null,
  };
}
function toGroup(o: Record<string, unknown>): Group {
  return {
    name: String(o.name ?? ""),
    type: typeof o.type === "string" ? o.type : "team",
    displayName: String(o.displayName ?? ""),
    ownerOrg: typeof o.ownerOrg === "string" ? o.ownerOrg : "",
    roles: asArray(o.roles),
  };
}
function toUser(o: Record<string, unknown>): User {
  const state = String(o.state ?? "active");
  return {
    name: String(o.name ?? ""),
    displayName: String(o.displayName ?? ""),
    primaryEmail: typeof o.primaryEmail === "string" ? o.primaryEmail : "",
    state: (state === "planned" || state === "suspended" || state === "terminated"
      ? state
      : "active") as User["state"],
    memberOf: asArray(o.memberOf),
    roles: asArray(o.roles),
  };
}

// ── reference guard for delete ─────────────────────────────────────────
// Returns the list of OTHER entities that still reference (configDir, kind,
// name) — non-empty means delete must be refused (unless --force).
export function referencesTo(model: PeopleModel, kind: Kind, name: string): string[] {
  const refs: string[] = [];
  switch (kind) {
    case "role":
      for (const g of model.groups.values()) {
        if ((g.roles ?? []).includes(name)) refs.push(`group '${g.name}' (roles)`);
      }
      for (const u of model.users.values()) {
        if ((u.roles ?? []).includes(name)) refs.push(`user '${u.name}' (roles)`);
      }
      break;
    case "org":
      for (const o of model.organizations.values()) {
        if (o.parentOrg === name) refs.push(`organization '${o.name}' (parentOrg)`);
      }
      for (const g of model.groups.values()) {
        if (g.ownerOrg === name) refs.push(`group '${g.name}' (ownerOrg)`);
      }
      break;
    case "group":
      for (const u of model.users.values()) {
        if ((u.memberOf ?? []).includes(name)) refs.push(`user '${u.name}' (memberOf)`);
      }
      break;
    case "user":
      for (const o of model.organizations.values()) {
        if (o.owner === name) refs.push(`organization '${o.name}' (owner)`);
      }
      break;
  }
  return refs;
}

// ── atomic write ───────────────────────────────────────────────────────
function atomicWrite(path: string, data: string): void {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true });
  const tmp = join(dir, `.${process.pid}.${Date.now()}.tmp`);
  writeFileSync(tmp, data, "utf8");
  renameSync(tmp, path);
}

function serialize(rec: Record<string, unknown>): string {
  return JSON.stringify(rec, null, 2) + "\n";
}

// ── public ops ─────────────────────────────────────────────────────────
export interface OpResult {
  path: string;
  action: "added" | "modified" | "deleted";
}

export function addEntity(
  configDir: string,
  kindRaw: string,
  name: string,
  fa: FieldArgs,
  force: boolean,
): OpResult {
  const kind = normalizeKind(kindRaw);
  if (!name) throw new EntityError(`${kind} add: expected <name>`);
  const path = pathFor(configDir, kind, name);
  if (existsSync(path) && !force) {
    throw new EntityError(`${kind} '${name}' already exists (${path}) — use --force to overwrite`);
  }
  const rec = buildNew(kind, name, fa);
  const errs = validateWithCandidate(configDir, kind, name, rec);
  if (errs.length > 0) throw new EntityError(`validation failed:\n  ${errs.join("\n  ")}`);
  atomicWrite(path, serialize(rec));
  return { path, action: "added" };
}

export function modifyEntity(
  configDir: string,
  kindRaw: string,
  name: string,
  fa: FieldArgs,
): OpResult {
  const kind = normalizeKind(kindRaw);
  if (!name) throw new EntityError(`${kind} modify: expected <name>`);
  const path = pathFor(configDir, kind, name);
  const rec = loadRaw(configDir, kind, name); // throws if absent
  applyFields(kind, rec, fa);
  const errs = validateWithCandidate(configDir, kind, name, rec);
  if (errs.length > 0) throw new EntityError(`validation failed:\n  ${errs.join("\n  ")}`);
  atomicWrite(path, serialize(rec));
  return { path, action: "modified" };
}

export function deleteEntity(
  configDir: string,
  kindRaw: string,
  name: string,
  force: boolean,
): OpResult {
  const kind = normalizeKind(kindRaw);
  if (!name) throw new EntityError(`${kind} delete: expected <name>`);
  const path = pathFor(configDir, kind, name);
  if (!existsSync(path)) throw new EntityError(`${kind} '${name}' not found (${path})`);
  if (!force) {
    const model = loadPeople(configDir);
    const refs = referencesTo(model, kind, name);
    if (refs.length > 0) {
      throw new EntityError(
        `${kind} '${name}' is still referenced by:\n  ${refs.join("\n  ")}\n` +
          `Remove those references first, or pass --force.`,
      );
    }
  }
  unlinkSync(path);
  return { path, action: "deleted" };
}
