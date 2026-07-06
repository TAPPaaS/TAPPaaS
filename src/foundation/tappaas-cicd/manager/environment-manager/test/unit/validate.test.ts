// validate.test.ts — unit tests for the native `validate` verb (the schema
// interpreter + reference checks in src/validate.ts, which replaced
// validate-environment.sh). Tiny inline assert harness (zero-dep, mirrors
// config.test.ts). Run after compiling via the test/unit tsconfig:
//   node dist-test/manager/environment-manager/test/unit/validate.test.js
//
// Uses the REAL src/foundation/schemas/environment-fields.json (resolved by
// resolveSchemaDir's walk-up) against a throwaway config tree in the OS temp
// dir — so these tests break when the schema and the interpreter drift apart.

import { existsSync, mkdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { resolveSchemaDir, runValidate, ValidateReport } from "../../src/validate";

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

const root = join(tmpdir(), `envmgr-validate-test-${Date.now()}`);
const envDir = join(root, "environments");
mkdirSync(envDir, { recursive: true });
mkdirSync(join(root, "people", "organizations"), { recursive: true });
writeFileSync(join(root, "people", "organizations", "test2.json"), `{ "name": "test2" }\n`);
writeFileSync(join(root, "zones.json"), JSON.stringify({ mgmt: {}, home: {} }));

const schemaDir = resolveSchemaDir();

// Write an environment doc and validate ONLY that file (isolated per test).
function vFile(name: string, doc: unknown): ValidateReport {
  const p = join(envDir, `${name}.json`);
  writeFileSync(p, typeof doc === "string" ? doc : JSON.stringify(doc, null, 2));
  return runValidate({ configDir: root, target: p, schemaDir });
}
function hasErr(r: ValidateReport, frag: string): boolean {
  return r.errors.some((e) => e.includes(frag));
}

try {
  check(existsSync(join(schemaDir, "environment-fields.json")), "resolveSchemaDir finds the real schema");

  // ── valid documents ─────────────────────────────────────────────────
  const minimal = vFile("mgmt", {
    name: "mgmt",
    displayName: "Management",
    ownerOrg: "test2",
    network: { zone: "mgmt" },
  });
  check(minimal.errors.length === 0 && minimal.warnings.length === 0, "minimal (mgmt-style) env is valid");

  const full = vFile("full", {
    name: "full",
    displayName: "Full",
    ownerOrg: "test2",
    domains: {
      primary: "full.example",
      aliases: ["alias.example"],
      aliasMode: "redirect",
      dnsMode: "wildcard",
    },
    network: { zone: "home" },
    dataResidency: "eu-only",
    backup: { retention: "7y", residency: "eu-only", schedule: null },
    legal: { processor: "Acme BV" },
  });
  check(full.errors.length === 0, "full-featured env is valid");

  const nulls = vFile("nulls", {
    name: "nulls",
    displayName: "Nulls",
    ownerOrg: "test2",
    network: { zone: "home" },
    backup: null,
    legal: null,
  });
  check(nulls.errors.length === 0, "backup:null / legal:null accepted (union types)");

  // ── schema conformance errors ───────────────────────────────────────
  const miss = vFile("miss", { name: "miss", ownerOrg: "test2", network: { zone: "home" } });
  check(hasErr(miss, "'displayName' is a required property"), "missing required field reported");
  check(hasErr(miss, "(root):"), "required-field error is located at (root)");

  const evil = vFile("evil", {
    name: "evil",
    displayName: "Evil",
    ownerOrg: "test2",
    domains: { primary: "evil.example", tlsCertRefid: "abc123" },
    network: { zone: "home" },
  });
  check(
    hasErr(evil, "Additional properties are not allowed ('tlsCertRefid' was unexpected)"),
    "nested tlsCertRefid rejected by additionalProperties:false",
  );
  check(
    hasErr(evil, "authored 'tlsCertRefid' is not allowed"),
    "nested tlsCertRefid also rejected by the belt-and-braces scan",
  );

  const evil2 = vFile("evil2", {
    name: "evil2",
    displayName: "Evil2",
    ownerOrg: "test2",
    tlsCertRefid: "topbeef",
    network: { zone: "home" },
  });
  check(
    hasErr(evil2, "'tlsCertRefid' was unexpected") && hasErr(evil2, "authored 'tlsCertRefid'"),
    "top-level tlsCertRefid rejected (schema + scan)",
  );

  const badname = vFile("badname", {
    name: "bad name!",
    displayName: "Bad",
    ownerOrg: "test2",
    network: { zone: "home" },
  });
  check(hasErr(badname, "does not match"), "name pattern violation reported");

  const short = vFile("short", {
    name: "short",
    displayName: "",
    ownerOrg: "test2",
    network: { zone: "home" },
  });
  check(hasErr(short, "is too short"), "displayName minLength violation reported");

  const badenum = vFile("badenum", {
    name: "badenum",
    displayName: "Bad Enum",
    ownerOrg: "test2",
    domains: { primary: "x.example", aliasMode: "banana" },
    network: { zone: "home" },
  });
  check(hasErr(badenum, "is not one of ['redirect', 'mirror']"), "enum violation reported");
  check(hasErr(badenum, "domains/aliasMode:"), "enum error carries the instance path");

  const badtype = vFile("badtype", {
    name: "badtype",
    displayName: "Bad Type",
    ownerOrg: "test2",
    network: { zone: "home" },
    backup: "often",
  });
  check(hasErr(badtype, "is not of type 'object', 'null'"), "union type violation reported");

  const dup = vFile("dup", {
    name: "dup",
    displayName: "Dup",
    ownerOrg: "test2",
    domains: { primary: "d.example", aliases: ["a.example", "a.example"] },
    network: { zone: "home" },
  });
  check(hasErr(dup, "has non-unique elements"), "duplicate aliases (uniqueItems) reported");

  const notObj = vFile("notobj", [1, 2, 3]);
  check(hasErr(notObj, "is not of type 'object'"), "non-object top level reported");

  // ── reference integrity ─────────────────────────────────────────────
  const badzone = vFile("badzone", {
    name: "badzone",
    displayName: "Bad Zone",
    ownerOrg: "test2",
    network: { zone: "no-such-zone" },
  });
  check(hasErr(badzone, "references unknown zone 'no-such-zone'"), "dangling network.zone reported");

  const badorg = vFile("badorg", {
    name: "badorg",
    displayName: "Bad Org",
    ownerOrg: "no-such-org",
    network: { zone: "home" },
  });
  check(hasErr(badorg, "references unknown organization 'no-such-org'"), "dangling ownerOrg reported");

  const badjson = vFile("badjson", "{ not json");
  check(hasErr(badjson, "not valid JSON"), "malformed JSON reported");

  // ── directory scan + zones.json availability ────────────────────────
  const root2 = join(root, "no-zones");
  mkdirSync(join(root2, "environments"), { recursive: true });
  mkdirSync(join(root2, "people", "organizations"), { recursive: true });
  writeFileSync(join(root2, "people", "organizations", "test2.json"), `{ "name": "test2" }\n`);
  writeFileSync(
    join(root2, "environments", "solo.json"),
    JSON.stringify({ name: "solo", displayName: "Solo", ownerOrg: "test2", network: { zone: "home" } }),
  );
  const noZones = runValidate({ configDir: root2, schemaDir });
  check(
    noZones.errors.length === 0 &&
      noZones.warnings.some((w) => w.includes("skipping zone reference check")),
    "missing zones.json downgrades the zone check to a warning",
  );

  const emptyDir = join(root, "empty");
  mkdirSync(emptyDir, { recursive: true });
  const empty = runValidate({ configDir: root, target: emptyDir, schemaDir });
  check(
    empty.errors.length === 0 && empty.warnings.some((w) => w.includes("no environment .json files")),
    "empty target directory produces a warning, not an error",
  );

  let threw = false;
  try {
    runValidate({ configDir: root, target: join(root, "nope.json"), schemaDir });
  } catch (e) {
    threw = e instanceof Error && e.message.includes("Environment target not found");
  }
  check(threw, "missing target throws (maps to exit 1)");

  // ── the no-silent-under-validation guarantee ────────────────────────
  // A schema using a keyword outside the implemented subset must FAIL LOUDLY,
  // not be silently skipped.
  const altSchemaDir = join(root, "alt-schemas");
  mkdirSync(altSchemaDir, { recursive: true });
  writeFileSync(
    join(altSchemaDir, "environment-fields.json"),
    JSON.stringify({ type: "object", oneOf: [{ required: ["name"] }] }),
  );
  let loud = false;
  try {
    runValidate({ configDir: root, target: join(envDir, "mgmt.json"), schemaDir: altSchemaDir });
  } catch (e) {
    loud = e instanceof Error && e.message.includes("unsupported schema keyword 'oneOf'");
  }
  check(loud, "unsupported schema keyword throws instead of under-validating");
} finally {
  rmSync(root, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) process.exit(1);
