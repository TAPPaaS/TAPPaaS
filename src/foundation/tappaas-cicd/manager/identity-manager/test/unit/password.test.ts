// password.test.ts — user reset-password: the link by default, the password
// from stdin on request, and what is refused.

import { passwordProblem, resetModeOf, resetPassword } from "../../src/password";
import { FakeClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}
const fails = (f: () => unknown): string => {
  try { f(); return ""; } catch (e) { return (e as Error).message; }
};

check(resetModeOf([]) === "link", "no flag: a link");
check(resetModeOf(["--link"]) === "link" && resetModeOf(["--password-stdin"]) === "stdin", "each flag its mode");
check(typeof resetModeOf(["--link", "--password-stdin"]) === "object", "both flags is refused");
check((resetModeOf(["--bogus"]) as { error: string }).error.includes("--bogus"), "a stray option is refused by name");
check(passwordProblem("short") !== null && passwordProblem("long-enough-1") === null && passwordProblem("tab\there-ok") !== null, "8 characters or more, printable");

const c = new FakeClient();
c.seedUser({ name: "lars", email: "l@x", displayName: "Lars", groups: [], roles: [], inactive: false } as never);
let r = resetPassword(c, "lars", "link", () => { throw new Error("stdin must not be read in link mode"); });
check(r.link === "https://sso.example/recovery/?flow_token=tok-lars" && r.lines[0] === r.link, "link mode prints the one-time link first");
r = resetPassword(c, "lars", "stdin", () => "Pa55word-here\nignored second line\n");
check(r.link === null && c.log.includes("setPassword lars *************") && !r.lines.join().includes("Pa55word"), "stdin mode sets the first line and never prints it");
check(fails(() => resetPassword(c, "lars", "stdin", () => "short\n")).includes("8 to 1024"), "a short password is refused before Authentik is asked");
c.recoveryFlow = false;
check(fails(() => resetPassword(c, "lars", "link", () => "")).includes("no recovery flow"), "no recovery flow: says so and points at --password-stdin");
check(fails(() => resetPassword(c, "nobody", "stdin", () => "Pa55word-here\n")).includes("not found"), "an unknown user is the client's error");

console.log(`password: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
