// main.test.ts — unit tests for the environment-manager CLI option parser.
//
// Regression guard for the "misspelled option silently ignored" bug: parseOpts
// must reject ANY dash-prefixed unknown token (single OR double dash), never
// swallow it into `rest` where `modify`/`add`/etc. drop it and still report
// success. Tiny inline assert harness (mirrors reconcile.test.ts).
//   node dist-test/manager/environment-manager/test/unit/main.test.js

import { HELP, formatEnvironmentHuman, parseOpts, run } from "../../src/main";
import { undocumentedOptions } from "../../../../lib/ts/src/help";
import { FakeDnsTlsClient, FakeModuleClient, FakeNetworkClient } from "./fake-clients";
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
    domains: { primary: "mf.example.org", dnsMode: "per-service" },
  };
  const out = formatEnvironmentHuman(env, "mfZone");
  check(
    !out.trimStart().startsWith("{") &&
      out.includes("makerfloss") &&
      out.includes("Maker Floss") &&
      out.includes("mf.example.org") &&
      out.includes("per-service") &&
      out.includes("acme") &&
      out.includes("mfZone"),
    "show human output is an aligned field summary, not JSON (zone from zones.json)",
  );
}

// ── #644: --help after a verb prints its help; unknown options are refused ──
// `reconcile <env> --apply --help` used to die on "Unknown option: --help"
// instead of printing help.
{
  const call = (argv: string[]): { rc: number; out: string; err: string; calls: number } => {
    const log = console.log;
    const error = console.error;
    let out = "";
    let err = "";
    console.log = (...a: unknown[]): void => {
      out += a.map(String).join(" ") + "\n";
    };
    console.error = (...a: unknown[]): void => {
      err += a.map(String).join(" ") + "\n";
    };
    const net = new FakeNetworkClient();
    const mod = new FakeModuleClient();
    const dt = new FakeDnsTlsClient();
    try {
      const rc = run(argv, net, mod, dt);
      return { rc, out, err, calls: net.log.length + mod.log.length + dt.log.length };
    } finally {
      console.log = log;
      console.error = error;
    }
  };
  for (const argv of [["reconcile", "home", "--apply", "--help"], ["delete", "home", "--force", "-h"], ["add", "lab", "--help"]]) {
    const r = call(argv);
    check(r.rc === 0 && r.out.includes("Usage:") && r.calls === 0, `${argv.join(" ")}: help, rc 0, nothing run`);
  }
  check(call(["reconcile", "--help"]).out.includes("--skip-network") && !call(["reconcile", "--help"]).out.includes("--create-zone"),
    "reconcile --help prints reconcile's options only");
  for (const argv of [["reconcile", "home", "--create-zone"], ["modify", "home", "--force"], ["list", "--domian", "x"]]) {
    const r = call(argv);
    check(r.rc === 1 && r.err.includes("unknown option") && r.calls === 0, `${argv.join(" ")}: refused, nothing run`);
  }
  check(undocumentedOptions(HELP).length === 0, `every usage option is described (${undocumentedOptions(HELP).join(", ")})`);
}

// ── #790: delete removes what TAPPaaS created for the environment ──────
{
  const { mkdtempSync, mkdirSync, writeFileSync, existsSync } = require("fs") as typeof import("fs");
  const { join } = require("path") as typeof import("path");
  const { tmpdir } = require("os") as typeof import("os");
  const setup = (envs: Record<string, string>) => {
    const d = mkdtempSync(join(tmpdir(), "envdel-"));
    mkdirSync(join(d, "environments"));
    for (const [n, dom] of Object.entries(envs)) {
      writeFileSync(join(d, "environments", `${n}.json`), JSON.stringify({
        name: n, displayName: n, ownerOrg: "o",
        domains: { primary: dom, dnsMode: "wildcard" } }));
    }
    return d;
  };
  const quiet = <T>(f: () => T): T => {
    const l = console.log, e = console.error;
    console.log = () => {}; console.error = () => {};
    try { return f(); } finally { console.log = l; console.error = e; }
  };
  const seeded = () => {
    const dt = new FakeDnsTlsClient();
    dt.seedWildcard("t1.example", "10.6.0.1");
    dt.seedIssuedCert("t1.example", "REF-T1");
    dt.seedRecordedRefid("tenant1", "REF-T1");
    return dt;
  };

  // --check: plans, changes nothing
  let d = setup({ tenant1: "t1.example" });
  let dt = seeded();
  quiet(() => run(["delete", "tenant1", "--check", "--config-dir", d], new FakeNetworkClient(), new FakeModuleClient(), dt));
  check(existsSync(join(d, "environments", "tenant1.json")), "delete --check keeps the environment file");
  check(dt.log.length === 0 && dt.refids.has("tenant1") && dt.issuedRefids.has("t1.example"),
    "delete --check removes no override, refid or certificate");

  // delete: the env's override, refid and certificate go
  dt = seeded();
  const rc = quiet(() => run(["delete", "tenant1", "--config-dir", d], new FakeNetworkClient(), new FakeModuleClient(), dt));
  check(rc === 0 && !existsSync(join(d, "environments", "tenant1.json")), "delete removes the environment file");
  check(dt.log.includes("removeWildcard t1.example 1"), "delete removes the *.<domain> Unbound override");
  check(dt.deletedCerts.includes("t1.example"), "delete deletes the ACME certificate (and its Trust cert)");
  check(!dt.refids.has("tenant1"), "delete drops the cert-refids.json entry");

  // a domain another environment still uses: its DNS and certificate stay
  d = setup({ tenant1: "shared.example", tenant2: "shared.example" });
  dt = new FakeDnsTlsClient();
  dt.seedWildcard("shared.example", "10.6.0.1");
  dt.seedIssuedCert("shared.example", "REF-S");
  dt.seedRecordedRefid("tenant1", "REF-S");
  quiet(() => run(["delete", "tenant1", "--config-dir", d], new FakeNetworkClient(), new FakeModuleClient(), dt));
  check(dt.issuedRefids.has("shared.example") && !dt.log.some((l) => l.startsWith("removeWildcard")),
    "a domain still used by another environment keeps its override and certificate");
  check(!dt.refids.has("tenant1"), "…but the deleted environment's own refid entry goes");
}

// ── #865: add / modify / delete link the zone through network-manager ──
{
  const { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync } = require("fs") as typeof import("fs");
  const { join } = require("path") as typeof import("path");
  const { tmpdir } = require("os") as typeof import("os");
  const setup = (zones: Record<string, unknown>) => {
    const d = mkdtempSync(join(tmpdir(), "envzone-"));
    mkdirSync(join(d, "environments"));
    mkdirSync(join(d, "identities", "organizations"), { recursive: true });
    writeFileSync(join(d, "identities", "organizations", "o.json"), JSON.stringify({ name: "o" }));
    writeFileSync(join(d, "zones.json"), JSON.stringify(zones));
    return d;
  };
  const quiet = <T>(f: () => T): T => {
    const l = console.log, e = console.error;
    console.log = () => {}; console.error = () => {};
    try { return f(); } finally { console.log = l; console.error = e; }
  };
  const go = (d: string, argv: string[]) => {
    const net = new FakeNetworkClient();
    const rc = quiet(() => run([...argv, "--config-dir", d], net, new FakeModuleClient(), new FakeDnsTlsClient()));
    return { rc, log: net.log };
  };

  // add: the env file names no zone; the zone is linked to it
  let d = setup({ acme: { type: "Service", state: "Active" }, home: { type: "Client", state: "Active" } });
  let r = go(d, ["add", "acme", "--owner", "o"]);
  const f = join(d, "environments", "acme.json");
  check(r.rc === 0 && existsSync(f) && !("network" in JSON.parse(readFileSync(f, "utf8"))),
    "#865 add: the environment file names no zone");
  check(JSON.stringify(r.log) === JSON.stringify(["bind acme acme"]), "#865 add: the default zone (its own name) is bound to it");

  // add --zone <a Client zone>: refused, nothing written
  r = go(d, ["add", "lab", "--owner", "o", "--zone", "home"]);
  check(r.rc === 1 && !existsSync(join(d, "environments", "lab.json")) && r.log.length === 0,
    "#865 add: a Client zone is not an environment's zone — refused before anything is written");

  // add --zone <missing>: refused without --create-zone, authored with it
  r = go(d, ["add", "lab", "--owner", "o", "--zone", "labZone"]);
  check(r.rc === 1 && !existsSync(join(d, "environments", "lab.json")), "#865 add: a missing zone needs --create-zone");
  r = go(d, ["add", "lab", "--owner", "o", "--zone", "labZone", "--create-zone"]);
  check(r.rc === 0 && JSON.stringify(r.log) === JSON.stringify(["create-service-zone labZone"]),
    "#865 add --create-zone: the zone is authored naming the environment");

  // add onto another environment's zone: refused
  d = setup({ acme: { type: "Service", state: "Active", environment: "acme" } });
  writeFileSync(join(d, "environments", "acme.json"), JSON.stringify({ name: "acme", displayName: "Acme", ownerOrg: "o" }));
  r = go(d, ["add", "lab", "--owner", "o", "--zone", "acme"]);
  check(r.rc === 1 && r.log.length === 0, "#865 add: another environment's zone is refused");

  // modify --zone: the new zone is bound, the old one unbound — in that order
  d = setup({ acme: { type: "Service", state: "Active", environment: "acme" }, acme2: { type: "Service", state: "Active" } });
  writeFileSync(join(d, "environments", "acme.json"), JSON.stringify({ name: "acme", displayName: "Acme", ownerOrg: "o" }));
  r = go(d, ["modify", "acme", "--zone", "acme2"]);
  check(r.rc === 0 && JSON.stringify(r.log) === JSON.stringify(["unbind acme", "bind acme2 acme"]),
    "#865 modify --zone: the old zone is unbound and the new one bound");
  r = go(d, ["modify", "acme", "--zone", "acme"]);
  check(r.rc === 0 && r.log.length === 0, "#865 modify --zone onto the zone it already has: no change");

  // delete: every zone naming the environment loses the link
  d = setup({ acme: { type: "Service", state: "Active", environment: "acme" }, home: { type: "Client", state: "Active", environment: "acme" }, guest: { type: "Guest", state: "Active" } });
  writeFileSync(join(d, "environments", "acme.json"), JSON.stringify({ name: "acme", displayName: "Acme", ownerOrg: "o" }));
  r = go(d, ["delete", "acme", "--force"]);
  check(r.rc === 0 && JSON.stringify(r.log) === JSON.stringify(["unbind acme", "unbind home"]),
    "#865 delete: the zones naming the environment are unbound");
}

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
