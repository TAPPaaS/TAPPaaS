// flags.test.ts — the table that maps a schema field to the manager's own flag
// (src/fieldmanifest.ts FLAGS), checked against the managers themselves: every
// field identity-manager's <kind> add/modify can set has a flag in the table
// and every flag there a field (identity-manager src/entity.ts SCHEMAS and its
// aliases --email, --groups); the same for backup-manager modify's options over
// the module's backup block. A field the manager cannot set has no flag: the
// form shows it read-only.

import { readFileSync } from "fs";
import { join } from "path";
import { composeFields } from "../../../lib/ts/src/compose-fields";
import { FLAGS, FieldKind, backupDefs, flattenSchema } from "../../src/fieldmanifest";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const FOUNDATION = join(FIX, "..", "..", "..", "..");
const MANAGERS = join(FOUNDATION, "tappaas-cicd", "manager");
const schema = (f: string) => JSON.parse(readFileSync(join(FOUNDATION, "schemas", f), "utf8")) as Record<string, unknown>;
const list = (s: string): string[] => [...s.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
const same = (a: string[], b: string[]) => JSON.stringify([...new Set(a)].sort()) === JSON.stringify([...new Set(b)].sort());

// ── identity-manager: the fields each kind's add/modify accepts ─────────
const entity = readFileSync(join(MANAGERS, "identity-manager", "src", "entity.ts"), "utf8");
const block = entity.slice(entity.indexOf("const SCHEMAS"), entity.indexOf("\n};", entity.indexOf("const SCHEMAS")));
// --email and --groups name primaryEmail and memberOf (canonicalField)
const aliases = Object.fromEntries([...entity.matchAll(/flag === "(\w+)"\) return "(\w+)"/g)].map((m) => [m[1], m[2]]));
check(aliases.email === "primaryEmail" && aliases.groups === "memberOf", "identity-manager: --email and --groups are aliases of primaryEmail and memberOf");

const SCHEMA_FILE: Record<string, string> = { user: "user-fields.json", group: "group-fields.json", org: "organization-fields.json", role: "role-fields.json" };
for (const kind of ["user", "group", "org", "role"] as FieldKind[]) {
  const m = new RegExp(`\\b${kind}:\\s*\\{\\s*scalarFields:\\s*\\[([^\\]]*)\\],\\s*listFields:\\s*\\[([^\\]]*)\\]`).exec(block);
  check(m !== null, `identity-manager declares the fields of a ${kind}`);
  if (!m) continue;
  const accepted = [...list(m[1]), ...list(m[2])];
  const settable = accepted.map((f) => aliases[f] ?? f);
  const fields = flattenSchema(schema(SCHEMA_FILE[kind])).map((d) => d.name).filter((n) => n !== "name");
  for (const mode of ["add", "modify"] as const) {
    const table = FLAGS[kind]?.[mode] ?? {};
    check(same(Object.keys(table), fields.filter((f) => settable.includes(f))), `${kind} ${mode}: every schema field identity-manager can set has a flag, and only those (${Object.keys(table).join(", ")})`);
    check(Object.entries(table).every(([field, flag]) => accepted.includes(flag.replace(/^--/, "")) && (aliases[flag.replace(/^--/, "")] ?? flag.replace(/^--/, "")) === field), `${kind} ${mode}: each flag is one identity-manager accepts, and names its field (${Object.values(table).join(" ")})`);
  }
  check(settable.filter((f) => !fields.includes(f)).length === 0, `${kind}: everything identity-manager sets is a field of ${SCHEMA_FILE[kind]}`);
}

// ── backup-manager modify: --enabled / --retention / --exclude ──────────
const bm = readFileSync(join(MANAGERS, "backup-manager", "src", "main.ts"), "utf8");
const bflags = Object.fromEntries([...bm.matchAll(/\["(--\w+) [^"]*", "modify: set module backup\.(\w+)/g)].map((m) => [m[2], m[1]]));
const bfields = backupDefs(composeFields(FOUNDATION, "/nonexistent").schema).map((d) => d.name);
const btable = FLAGS.backup?.modify ?? {};
check(Object.keys(bflags).length === 3 && JSON.stringify(btable) === JSON.stringify(bflags), `backup modify: the table is backup-manager modify's options, field for field (${Object.values(btable).join(" ")})`);
check(Object.keys(btable).every((f) => bfields.includes(f)), "…each a field of the module's backup block");
check(bfields.includes("schedule") && btable.schedule === undefined, "…schedule is in the block but backup-manager modify cannot set it: read-only in the form");

// ── rack-manager rack add / mount add: their usage lines' options ───────
const rm = readFileSync(join(MANAGERS, "rack-manager", "src", "main.ts"), "utf8");
const racks = schema("racks-fields.json").$defs as Record<string, unknown>;
for (const kind of ["rack", "mount"] as FieldKind[]) {
  const usage = new RegExp(`"(${kind} add [^"]*)"`).exec(rm)?.[1] ?? "";
  const opts = [...usage.matchAll(/(--[a-z-]+)/g)].map((m) => m[1]).filter((f) => !["--check", "--topology"].includes(f));
  const table = FLAGS[kind]?.add ?? {};
  const fields = flattenSchema(racks[kind]).map((d) => d.name).filter((n) => n !== "name" && n !== "device");
  check(usage !== "" && same(Object.values(table), opts), `${kind} add: the table is rack-manager ${kind} add's options (${Object.values(table).join(" ")})`);
  check(same(Object.keys(table), fields), `${kind} add: every field of racks-fields' ${kind} has its flag`);
}

// ── site-manager site modify: its options over site-fields.json ─────────
const sm = readFileSync(join(MANAGERS, "site-manager", "src", "main.ts"), "utf8");
const smBlock = sm.slice(sm.indexOf("options: [", sm.indexOf('name: "site modify')), sm.indexOf('{ usage: "node list'));
const smOpts = [...smBlock.matchAll(/\["(--\w+)[ "]/g)].map((m) => m[1]).filter((f) => f !== "--force");
const stable = FLAGS.site?.modify ?? {};
const sdefs = flattenSchema(schema("site-fields.json"));
check(same(Object.values(stable), [...smOpts, "--channel"]) && smOpts.length > 30, `site modify: the table is site-manager site modify's options, flag for flag (${smOpts.filter((f) => !Object.values(stable).includes(f)).join(" ")})`);
check(Object.keys(stable).every((f) => sdefs.some((d) => d.name === f && d.changeClass === "in-place")), "…each a field site-fields.json classes in-place");
check(["dnssec", "dnsBlocklists.lists", "diskAutoGrow.threshold", "branding.logo"].every((f) => stable[f]), "…dnssec, the blocklists, disk growth and branding among them");
check(["name", "version", "defaultEnvironment"].every((f) => !stable[f] && sdefs.find((d) => d.name === f)?.changeClass === "immutable"), "…name, version and defaultEnvironment immutable, with no flag");

done("flags");
