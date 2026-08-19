// primitives.ts — CliPrimitiveClient: the real PrimitiveClient implementation.
//
// Each method spawnSyncs `authentik-manager <verb> ...` (the identity-controller
// CLI on PATH, S2b-2) and parses its JSON stdout. NO Authentik HTTP is
// reimplemented here — this is a thin FFI boundary, exactly as switch-controller
// shells out to its bash plugins.
//
// list-* verbs emit JSON to stdout (NO --json flag); mutating verbs emit a
// status line we ignore. A non-zero exit (or unreachable Authentik) throws.

import { captureResult } from "../../../lib/ts/src/exec";
import { AkNamed, AkUser, PrimitiveClient } from "./types";

export class AuthentikUnreachable extends Error {}

const BIN = process.env.AUTHENTIK_MANAGER_BIN ?? "authentik-manager";

// Thin wrapper over the shared exec helper: a spawn FAILURE (binary missing /
// not executable) must throw AuthentikUnreachable (cmdSync catches it and
// die()s with "Authentik unreachable: …"), while a non-zero EXIT stays a
// generic Error — captureResult's ran/rc split preserves that distinction.
function run(args: string[]): string {
  const r = captureResult(BIN, args);
  if (!r.ran) {
    throw new AuthentikUnreachable(`${BIN} ${args[0]}: ${r.stderr}`);
  }
  if (r.rc !== 0) {
    throw new Error(`${BIN} ${args.join(" ")} failed (exit ${r.rc}): ${r.stderr.trim()}`);
  }
  return r.stdout;
}

function runJson(args: string[]): unknown {
  const out = run(args);
  return JSON.parse(out);
}

export class CliPrimitiveClient implements PrimitiveClient {
  listUsers(): AkUser[] {
    const v = runJson(["list-users"]);
    if (!Array.isArray(v)) return [];
    return v.map((x) => normalizeUser(x as Record<string, unknown>));
  }

  listGroups(): AkNamed[] {
    return normalizeNamed(runJson(["list-groups"]));
  }

  listRoles(): AkNamed[] {
    return normalizeNamed(runJson(["list-roles"]));
  }

  ensureUser(name: string, email: string, display: string, inactive: boolean): void {
    const args = ["ensure-user", "--name", name, "--email", email, "--display", display];
    if (inactive) args.push("--inactive");
    run(args);
  }

  disableUser(name: string): void {
    run(["disable-user", "--name", name]);
  }

  deleteUser(name: string): void {
    run(["delete-user", "--name", name]);
  }

  ensureGroup(name: string, display: string): void {
    run(["ensure-group", "--name", name, "--display", display]);
  }

  ensureRole(name: string, display: string): void {
    run(["ensure-role", "--name", name, "--display", display]);
  }

  deleteGroup(name: string): void {
    run(["delete-group", "--name", name]);
  }

  deleteRole(name: string): void {
    run(["delete-role", "--name", name]);
  }

  addMember(user: string, group: string): void {
    run(["add-member", "--user", user, "--group", group]);
  }

  removeMember(user: string, group: string): void {
    run(["remove-member", "--user", user, "--group", group]);
  }

  assignRole(user: string, role: string): void {
    run(["assign-role", "--user", user, "--role", role]);
  }

  unassignRole(user: string, role: string): void {
    run(["unassign-role", "--user", user, "--role", role]);
  }
}

function normalizeUser(o: Record<string, unknown>): AkUser {
  const toNames = (v: unknown): string[] =>
    Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
  return {
    name: typeof o.name === "string" ? o.name : "",
    active: o.active === true,
    email: typeof o.email === "string" ? o.email : "",
    displayName: typeof o.displayName === "string" ? o.displayName : "",
    groups: toNames(o.groups),
    roles: toNames(o.roles),
  };
}

function normalizeNamed(v: unknown): AkNamed[] {
  if (!Array.isArray(v)) return [];
  return v.map((x) => {
    const o = x as Record<string, unknown>;
    return {
      name: typeof o.name === "string" ? o.name : "",
      displayName: typeof o.displayName === "string" ? o.displayName : "",
    };
  });
}
