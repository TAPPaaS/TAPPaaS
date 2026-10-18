// sessions.ts — end a person's sessions in the apps that keep their own
// (ADR-032 P4).
//
// Removing someone in Authentik stops their NEXT sign-in, but an app that issued
// its own session token (Jellyfin's apps and TVs) keeps honouring it. A module
// whose app does that ships `revoke-sessions.sh <username>` in its source
// directory; after a plan that takes access away is applied, identity-manager
// runs it in every deployed module that has one, for every user who lost
// access. It ends more than strictly needed — losing any group ends the
// person's sessions everywhere — which costs them one sign-in, never access.

import { existsSync } from "fs";
import { join } from "path";
import { defaultConfigDir as moduleConfigDir } from "../../../lib/ts/src/config-io";
import { stream } from "../../../lib/ts/src/exec";
import { discoverModules } from "../../../lib/ts/src/module-discovery";
import { Action } from "./types";

export const REVOKE_HOOK = "revoke-sessions.sh";

export interface Revoker {
  module: string;
  dir: string;
}

// The deployed modules whose source directory ships the hook.
export function sessionRevokers(configDir: string = moduleConfigDir()): Revoker[] {
  const out: Revoker[] = [];
  for (const m of discoverModules(configDir)) {
    const src = m.raw.moduleSource ?? m.raw.location;
    if (typeof src !== "string" || src === "") continue;
    if (existsSync(join(src, REVOKE_HOOK))) out.push({ module: m.name, dir: src });
  }
  return out;
}

// Who an applied plan took access from, once each, in order.
export function usersLosingAccess(actions: Action[]): string[] {
  const seen = new Set<string>();
  for (const a of actions) if (a.losesAccess) seen.add(a.losesAccess);
  return [...seen];
}

export type HookRunner = (dir: string, user: string) => number;

// Run the hook from its module directory, as module scripts are run.
export const runHook: HookRunner = (dir, user) => stream("bash", [`./${REVOKE_HOOK}`, user], { cwd: dir });

export interface RevokeOutcome {
  done: string[]; // "<module>: <user>"
  failed: string[];
}

export function revokeSessions(users: string[], revokers: Revoker[], run: HookRunner = runHook): RevokeOutcome {
  const out: RevokeOutcome = { done: [], failed: [] };
  for (const user of users) {
    for (const r of revokers) {
      let rc: number;
      try {
        rc = run(r.dir, user);
      } catch {
        rc = -1;
      }
      (rc === 0 ? out.done : out.failed).push(`${r.module}: ${user}`);
    }
  }
  return out;
}
