// password.ts — `user reset-password <name>`: a user who cannot sign in gets a
// new way in. By default a one-time link (Authentik's recovery flow: the user
// sets a password of their own, the link is the authentication); with
// --password-stdin a password the operator chose, read once from stdin and
// never in a command line. The console's Day 2 "Reset a user's password"
// runs both.

import { PrimitiveClient } from "./types";

export type ResetMode = "link" | "stdin";

export interface ResetResult {
  mode: ResetMode;
  link: string | null; // the link, in link mode
  lines: string[]; // what to print, in the operator's words
}

export function resetModeOf(flags: string[]): ResetMode | { error: string } {
  const link = flags.includes("--link");
  const stdin = flags.includes("--password-stdin");
  if (link && stdin) return { error: "user reset-password: --link or --password-stdin, not both" };
  const stray = flags.filter((f) => f.startsWith("--") && f !== "--link" && f !== "--password-stdin");
  if (stray.length) return { error: `user reset-password: unknown option ${stray[0]}` };
  return stdin ? "stdin" : "link";
}

export function passwordProblem(p: string): string | null {
  if (!p) return "no password on stdin";
  if (p.length < 8 || p.length > 1024) return "the password is 8 to 1024 characters";
  if (!/^[\x20-\x7e]+$/.test(p)) return "printable characters only";
  return null;
}

// readStdin: the first line of stdin, read only in stdin mode.
export function resetPassword(client: PrimitiveClient, user: string, mode: ResetMode, readStdin: () => string): ResetResult {
  if (mode === "stdin") {
    const password = readStdin().split(/\r?\n/)[0] ?? "";
    const problem = passwordProblem(password);
    if (problem) throw new Error(`user reset-password --password-stdin: ${problem}`);
    client.setPassword(user, password);
    return { mode, link: null, lines: [`password set for ${user}: hand it over apart from the sign-in address, and have it changed at the first sign-in`] };
  }
  const link = client.recoveryLink(user);
  if (!link) {
    throw new Error(`user reset-password: Authentik has no recovery flow (identity's update.sh makes one: authentik-controller recovery-flow-ensure) — a password of your own: --password-stdin`);
  }
  return { mode, link, lines: [link, `one-time: ${user} opens it, sets a password of their own, and signs in; it expires unused`] };
}
