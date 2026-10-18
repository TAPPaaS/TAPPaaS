// fields.test.ts — the Modify form's read of a module (fields.ts): each field
// with its owner, class, type, value in effect and whether that value is
// configured or the default; and the schema files a zone or an environment
// form reads, by name only.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { moduleFieldRows, moduleSchema, schemaDoc, typeWord } from "../../src/fields";
import { check, done } from "./check";

const fieldsDoc = {
  module: "immich",
  fields: [
    { field: "memory", coordinate: "cluster:vm", class: "in-place", settable: true, reason: null, value: "8192" },
    { field: "bios", coordinate: "", class: "recreate", settable: false, reason: "recreate under cluster:vm", value: "ovmf" },
    { field: "proxyPort", coordinate: "network:proxy", class: "in-place", settable: true, reason: null, value: null },
    { field: "description", coordinate: "", class: "config-only", settable: true, reason: null, value: "Photos" },
    { field: "aliasType", coordinate: "network:rules", class: "in-place", settable: true, reason: null, value: "host" },
  ],
  warnings: ["w1"],
};
const resolveDoc = {
  module: "immich",
  dependsOn: ["cluster:vm", "network:proxy", "network:rules"],
  integratesWith: ["logging:logs"],
  fields: {
    memory: { value: "8192", defaulted: false },
    bios: { value: "ovmf", defaulted: false },
    description: { value: "Photos", defaulted: false },
    aliasType: { value: "host", defaulted: true },
  },
};
const schema = {
  memory: { type: "integer", default: 2048, usedBy: ["cluster:vm", "cluster:lxc"], description: "MiB" },
  bios: { type: "string", enum: ["seabios", "ovmf"], usedBy: ["cluster:lxc", "cluster:vm"] },
  proxyPort: { type: "integer|string", usedBy: ["network:proxy"] },
  description: { type: "string", usedBy: ["general"] },
  aliasType: { type: "string", enum: ["host", "network"], default: "host", usedBy: ["network:rules"] },
};

const m = moduleFieldRows(fieldsDoc, resolveDoc, schema);
const row = (f: string) => m.fields.find((r) => r.field === f)!;
check(m.module === "immich" && m.fields.length === 5, "every row of module-manager fields is kept");
check(m.dependsOn.join() === "cluster:vm,network:proxy,network:rules" && m.integratesWith.join() === "logging:logs", "the services come from resolve");
check(m.warnings.join() === "w1", "the manager's warnings pass through");
check(row("memory").service === "cluster:vm" && row("memory").type === "integer" && row("memory").configured && row("memory").default === 2048, "a configured field: its owner, type and the schema default");
check(row("bios").service === "cluster:vm" && !row("bios").settable && row("bios").enum?.join() === "seabios,ovmf", "a refused field's owner is the service of this module its schema names");
check(row("aliasType").configured === false && row("aliasType").value === "host", "a defaulted value is in effect but not configured");
check(row("proxyPort").value === null && row("proxyPort").configured === false, "a field with no value is neither configured nor defaulted");
check(row("proxyPort").type === "string", "integer|string is offered as a string");
check(row("description").service === "", "a general field belongs to the module itself");
check(typeWord(["string", "array"]) === "array" && typeWord(["string", "null"]) === "string" && typeWord(undefined) === "string", "a schema type becomes one word a form can offer");
check(moduleFieldRows(null, null, {}).fields.length === 0, "nothing read: no rows, no throw");

// The schema files, by name only.
const repo = mkdtempSync(join(tmpdir(), "fields-"));
mkdirSync(join(repo, "src", "foundation", "schemas"), { recursive: true });
writeFileSync(join(repo, "src", "foundation", "schemas", "zones-fields.json"), JSON.stringify({ fields: { tier: { type: "integer", changeClass: "in-place" } } }));
check((schemaDoc(repo, "zones").fields as Record<string, unknown>).tier !== undefined, "schemas/zones reads zones-fields.json");
let threw = "";
try {
  schemaDoc(repo, "../../etc/passwd");
} catch (e) {
  threw = (e as Error).message;
}
check(/no schema/.test(threw), "a name outside the list reads nothing");
threw = "";
try {
  schemaDoc(repo, "environment");
} catch (e) {
  threw = (e as Error).message;
}
check(/not found/.test(threw), "a missing schema file is an error, not an empty form");

const cfg = mkdtempSync(join(tmpdir(), "fields-cfg-"));
check(Object.keys(moduleSchema(cfg)).length === 0, "no composed schema: no types, the form offers text");
writeFileSync(join(cfg, "module-fields.json"), JSON.stringify({ fields: schema }));
check(Object.keys(moduleSchema(cfg)).length === 5, "the composed schema's fields are read from the config dir");

done("fields");
