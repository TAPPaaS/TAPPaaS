// main.test.ts — unit tests for the environment-manager CLI option parser.
//
// Regression guard for the "misspelled option silently ignored" bug: parseOpts
// must reject ANY dash-prefixed unknown token (single OR double dash), never
// swallow it into `rest` where `modify`/`add`/etc. drop it and still report
// success. Tiny inline assert harness (mirrors reconcile.test.ts).
//   node dist-test/manager/environment-manager/test/unit/main.test.js

import { formatEnvironmentHuman, parseOpts } from "../../src/main";
import { DieError } from "../../../../lib/ts/src/cli";
import { Environment } from "../../src/types";

let passed = 0;
let failed = 0;
function check(cond: boolean, label: string): void {
  if (cond) {
    passed++;
    console.log(`ok - ${label}`);
  } else {
    failed++;
    console.error(`FAIL - ${label}`);
  }
}
function throwsDie(fn: () => void, label: string): void {
  try {
    fn();
    check(false, `${label} (expected DieError, none thrown)`);
  } catch (e) {
    check(e instanceof DieError, label);
  }
}

// A correctly-spelled option is parsed and its value captured.
{
  const o = parseOpts(["makerfloss", "--domain", "example.com"]);
  check(o.domain === "example.com" && o.rest.length === 1 && o.rest[0] === "makerfloss",
    "--domain sets domain and keeps the env positional");
}

// Another valid flag still works (sanity: the guard didn't over-reject).
{
  const o = parseOpts(["makerfloss", "--display", "Maker Floss"]);
  check(o.display === "Maker Floss", "--display still parses");
}

// The reported bug: a dropped dash must ERROR, not be silently ignored.
throwsDie(() => parseOpts(["makerfloss", "-domain", "example.com"]),
  "single-dash typo -domain is rejected");

// A transposed-letter typo (double dash) must also error.
throwsDie(() => parseOpts(["makerfloss", "--domian", "example.com"]),
  "double-dash typo --domian is rejected");

// A bare unknown word is still allowed through as a positional (commands own
// their own arity), but an unknown short flag is not.
throwsDie(() => parseOpts(["-x"]), "unknown short flag -x is rejected");

// `show` default is a human summary, NOT JSON (issue: show only spoke JSON).
{
  const env: Environment = {
    name: "makerfloss",
    displayName: "Maker Floss",
    ownerOrg: "acme",
    network: { zone: "makerfloss" },
    domains: { primary: "mf.example.org", dnsMode: "per-service" },
  };
  const out = formatEnvironmentHuman(env);
  check(
    !out.trimStart().startsWith("{") &&
      out.includes("makerfloss") &&
      out.includes("Maker Floss") &&
      out.includes("mf.example.org") &&
      out.includes("per-service") &&
      out.includes("acme"),
    "show human output is an aligned field summary, not JSON",
  );
}

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
