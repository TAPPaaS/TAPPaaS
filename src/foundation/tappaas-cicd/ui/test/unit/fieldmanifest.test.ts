// fieldmanifest.test.ts — the field manifest of every add and modify form
// (src/fieldmanifest.ts): one case per kind over the repository's own schema
// files and records shaped like hrossen's, the template rendering of defaults,
// and the one-line descriptions; then the form's argv (web/src/fieldlogic.ts).

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { composeFields } from "../../../lib/ts/src/compose-fields";
import { FieldManifest, RefContext, backupDefs, buildManifest, flattenSchema, moduleDefs, oneLine, renderDefault, zoneDefs } from "../../src/fieldmanifest";
import { classSummary, fieldChanges, placeholderOf, typedVars } from "../../web/src/fieldlogic";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const FOUNDATION = join(FIX, "..", "..", "..", "..");
const schema = (f: string) => JSON.parse(readFileSync(join(FOUNDATION, "schemas", f), "utf8")) as Record<string, unknown>;
const refs: RefContext = {
  zones: ["dmz", "home", "mgmt", "rossen", "test"],
  environments: ["mgmt", "rossen", "test"],
  nodes: [{ name: "tappaas1", pools: ["tanka1", "tankb1"] }, { name: "tappaas2", pools: ["tanka1"] }],
  organizations: ["rossen"],
  users: ["lars", "root"],
  groups: ["authentik Admins", "installer", "users"],
  roles: ["admin", "root", "user"],
};
const field = (m: FieldManifest, n: string) => m.fields.find((f) => f.name === n);

// ── defaults: templates, placeholders in words, literals ────────────────
check(renderDefault("<vmname>.<tappaas.domain>", { vmname: "immich", domain: "hrossen.dk" })?.text === "immich.hrossen.dk", "a template default is rendered when its values are known: <vmname>.<tappaas.domain> → immich.hrossen.dk");
const half = renderDefault("<vmname>.<tappaas.domain>", { vmname: "immich" });
check(half?.text === "immich.<domain>" && half.template, "…and stays a template, marked, where one is not");
check(renderDefault("<internal default: every Active 'Service' zone plus home>", {})?.text === "every Active 'Service' zone plus home", "a placeholder in words reads as its words");
check(renderDefault(null, {}) === null && renderDefault(undefined, {}) === null, "no default is null — the form says \"no default\", never none or null");
check(renderDefault([], {})?.text === "empty" && renderDefault(4096, {})?.text === "4096" && renderDefault(false, {})?.text === "false", "an empty list reads empty; a number and a boolean as themselves");
check(oneLine("Whether this module is backed up (#123). false disables it. More text.") === "Whether this module is backed up.", "the description is its first sentence, without issue references");
check(oneLine("Retention period (e.g. 1y). Overrides the site.") === "Retention period (e.g. 1y).", "…an abbreviation's full stop is not a sentence end");

// ── module: modify ──────────────────────────────────────────────────────
const composed = composeFields(FOUNDATION, "/nonexistent").schema;
const moduleClasses = (schema("fields.json").fields ?? {}) as Record<string, { class?: string; apply?: string }>;
const mod = buildManifest({
  kind: "module", name: "vaultwarden", mode: "modify", defs: moduleDefs(composed),
  record: { memory: 1536, zone0: "dmz", status: "Development" },
  defaults: { cores: 2 },
  classes: { memory: { class: "in-place-reboot", settable: true, reason: null, offRelease: true }, cores: { class: "in-place", settable: true, reason: null }, zone0: { class: "in-place-reboot", settable: true, reason: null }, proxyDomain: { class: "in-place", settable: true, reason: null }, status: { class: "config-only", coordinate: "", settable: true, reason: null }, displayName: { class: "config-only", coordinate: "", settable: true, reason: null }, vmid: { class: "immutable", settable: false, reason: "immutable under cluster:vm" }, node: { class: "migrate", settable: true, reason: null } },
  moduleClasses,
  refs, vars: { name: "vaultwarden", vmname: "vaultwarden", domain: "hrossen.dk" },
});
check(mod.fields.length === 8, "module modify: the fields module-manager fields lists, and only those");
check(field(mod, "memory")?.value === 1536 && field(mod, "memory")?.arg === "--set" && field(mod, "memory")?.class === "in-place-reboot", "…a configured field: its value, --set, its class");
check(field(mod, "cores")?.default === "2" && !field(mod, "cores")?.configured, "…an unset field's default is the value in effect");
check(field(mod, "proxyDomain")?.default === "vaultwarden.hrossen.dk", "…proxyDomain's default rendered for this module: vaultwarden.hrossen.dk");
check(field(mod, "zone0")?.typeText === "a zone" && field(mod, "zone0")?.choices?.join() === refs.zones.join(), "…zone0 names a zone: its choices are the zones");
check(field(mod, "node")?.references === "nodes" && field(mod, "node")?.choices?.join() === "tappaas1,tappaas2", "…node names a node");
check(field(mod, "status")?.class === "immutable" && field(mod, "status")?.editable === false && /Written by the release/.test(field(mod, "status")?.why ?? ""), "…status: module-manager's config-only label gives way to the declared class, immutable, read-only");
check(field(mod, "displayName")?.class === "in-place" && field(mod, "displayName")?.apply === "none" && field(mod, "displayName")?.editable === true, "…displayName: in-place, apply none (recorded, shows at the next update)");
check(field(mod, "memory")?.offRelease === true && field(mod, "cores")?.offRelease === false, "…resolve's .orig note marks a field kept off its release");
check(field(mod, "vmid")?.editable === false && /immutable/.test(field(mod, "vmid")?.why ?? ""), "…a field the pre-gate refuses is read-only, with its reason");

// ── module: add, from the catalogue module's own JSON ───────────────────
const vwFile = join(FOUNDATION, "..", "security", "vaultwarden", "vaultwarden.json");
const vw = existsSync(vwFile) ? (JSON.parse(readFileSync(vwFile, "utf8")) as Record<string, unknown>) : {};
const add = buildManifest({
  kind: "module", name: "vaultwarden", mode: "add", defs: moduleDefs(composed), record: null, defaults: vw, moduleClasses,
  services: (vw.dependsOn as string[]) ?? [], refs, vars: { name: "vaultwarden", vmname: "vaultwarden", domain: "hrossen.dk" },
});
check(field(add, "vmid")?.default === String(vw.vmid) && field(add, "vmid")?.arg === "--vmid", "module add: the module's own JSON is the default (vmid 610), passed as --vmid");
check(field(add, "memory")?.arg === "--memory" && field(add, "storage")?.typeText === "a storage pool", "…the fields its services use are offered (memory; storage, a pool)");
check(field(add, "version") === undefined && field(add, "status") === undefined, "…a field the release or the install writes is never offered");
check(field(add, "config") === undefined, "…the services' nesting block is not a field");

// ── zone ────────────────────────────────────────────────────────────────
const zdefs = zoneDefs(schema("zones-fields.json"));
const zone = buildManifest({ kind: "zone", name: "home", mode: "modify", defs: zdefs, record: { type: "Client", vlantag: 210, "access-to": ["internet"], description: "Home" }, refs, vars: {} });
check(field(zone, "access-to")?.typeText === "zones" && field(zone, "access-to")?.choices?.includes("dmz") === true && field(zone, "access-to")?.arg === "--set", "zone modify: access-to is a list of zones, set with --set");
check(field(zone, "vlantag")?.editable === false && /delete the zone/.test(field(zone, "vlantag")?.why ?? ""), "…vlantag cannot change in place");
const zadd = buildManifest({ kind: "zone", name: null, mode: "add", defs: zdefs, record: null, refs, vars: {} });
check(field(zadd, "type")?.arg === "--type" && field(zadd, "vlantag")?.arg === "--vlan" && field(zadd, "access-to")?.editable === false, "zone add: the add verb's own flags (--type, --vlan); the rest after the add");

// ── environment ─────────────────────────────────────────────────────────
const edefs = flattenSchema(schema("environment-fields.json"));
const env = buildManifest({ kind: "environment", name: "rossen", mode: "modify", defs: edefs, record: { name: "rossen", displayName: "Rossen", ownerOrg: "rossen", network: { zone: "rossen" }, domains: { primary: "hrossen.dk", dnsMode: "per-service" } }, refs, vars: {} });
check(field(env, "name") === undefined, "environment modify: the name is the verb's positional, not a field");
check(field(env, "ownerOrg")?.typeText === "an organization" && field(env, "ownerOrg")?.arg === "--owner" && field(env, "ownerOrg")?.value === "rossen", "…ownerOrg names an organization, passed as --owner");
check(field(env, "network.zone")?.choices?.includes("rossen") === true && field(env, "network.zone")?.arg === "--zone" && field(env, "domains.dnsMode")?.typeText === "one of per-service, wildcard", "…network.zone a zone (--zone); dnsMode one of per-service, wildcard");
check(field(env, "displayName")?.required === true && field(env, "domains.primary")?.required === false, "…required as the schema says");
const eadd = buildManifest({ kind: "environment", name: null, mode: "add", defs: edefs, record: null, defaults: { displayName: "<Name>", ownerOrg: "rossen", "network.zone": "<name>" }, refs, vars: { name: null } });
check(field(eadd, "ownerOrg")?.default === "rossen" && field(eadd, "displayName")?.defaultTemplate === true, "environment add: what the manager uses when a field is left empty");
check(placeholderOf(field(eadd, "displayName")!, typedVars({ "@env": "acme" })) === "default Acme" && placeholderOf(field(eadd, "network.zone")!, typedVars({ "@env": "acme" })) === "default acme", "…filled from the name as it is typed: default Acme, default acme");

// ── identity ────────────────────────────────────────────────────────────
const user = buildManifest({ kind: "user", name: "lars", mode: "modify", defs: flattenSchema(schema("user-fields.json")), record: { name: "lars", displayName: "lars", primaryEmail: "lars@hrossen.dk", state: "active", memberOf: ["users", "installer"], roles: ["admin"] }, refs, vars: {} });
check(field(user, "memberOf")?.typeText === "groups" && field(user, "memberOf")?.arg === "--groups" && field(user, "memberOf")?.choices?.includes("authentik Admins") === true, "user: memberOf is a list of groups, passed as --groups");
check(field(user, "primaryEmail")?.arg === "--email" && field(user, "roles")?.typeText === "roles" && field(user, "state")?.default === "active", "…primaryEmail as --email; roles; state's default");
const group = buildManifest({ kind: "group", name: "users", mode: "modify", defs: flattenSchema(schema("group-fields.json")), record: { name: "users", displayName: "Users", ownerOrg: "rossen", roles: ["user"] }, refs, vars: {} });
check(field(group, "ownerOrg")?.typeText === "an organization" && field(group, "roles")?.arg === "--roles", "group: ownerOrg an organization; roles as --roles");
const org = buildManifest({ kind: "org", name: null, mode: "add", defs: flattenSchema(schema("organization-fields.json")), record: null, refs, vars: {} });
check(field(org, "owner")?.typeText === "a user" && field(org, "parentOrg")?.typeText === "an organization" && field(org, "type")?.default === "company", "org add: owner a user, parentOrg an organization, type's default");
const role = buildManifest({ kind: "role", name: "admin", mode: "modify", defs: flattenSchema(schema("role-fields.json")), record: { name: "admin", displayName: "Administrator" }, refs, vars: {} });
check(role.fields.map((f) => f.arg).join() === "--displayName,--description", "role: displayName and description");

// ── site ────────────────────────────────────────────────────────────────
const site = buildManifest({ kind: "site", name: null, mode: "modify", defs: flattenSchema(schema("site-fields.json")), record: { name: "rossen", defaultEnvironment: "rossen", channel: "unstable", location: { country: "DK" }, updateSchedule: { frequency: "weekly", weekday: "Thursday", hour: 2 } }, refs, vars: {} });
check(field(site, "defaultEnvironment")?.typeText === "an environment" && field(site, "defaultEnvironment")?.editable === false, "site: defaultEnvironment names an environment; site modify has no option for it");
check(field(site, "updateSchedule.frequency")?.arg === "--updateFrequency" && field(site, "updateSchedule.hour")?.type === "integer" && field(site, "updateSchedule.weekday")?.choices?.length === 7, "…the schedule's three fields, with their flags");
check(field(site, "location.country")?.arg === "--locationCountry" && field(site, "location.country")?.value === "DK", "…a nested field by its path, passed as its flag");

// ── backup: the module's leaf of the cascade ────────────────────────────
const bk = buildManifest({ kind: "backup", name: "vaultwarden", mode: "modify", defs: backupDefs(composed), record: {}, defaults: { enabled: true, retention: "7y", exclude: [], schedule: "daily" }, refs, vars: {} });
check(field(bk, "retention")?.default === "7y" && field(bk, "retention")?.arg === "--retention", "backup: an unset retention reads the cascade's 7y");
check(field(bk, "exclude")?.arg === "--exclude" && field(bk, "schedule")?.editable === false, "…exclude as --exclude; schedule has no option in backup-manager modify");

// ── the form's argv (fieldlogic.ts) ─────────────────────────────────────
const c1 = fieldChanges(mod.fields, { memory: "2048", proxyDomain: "vault.hrossen.dk", zone0: "" });
check(c1.tokens.join(" ") === "--set memory=2048 --unset zone0 --set proxyDomain=vault.hrossen.dk", "module modify: --set per changed field, in the schema's order; an emptied configured field is unset");
check(classSummary(c1.changed).join(" | ") === "restarts the module: memory, zone0 | applied live: proxyDomain", "…the Preview's head groups them by class, in words");
const c2 = fieldChanges(user.fields, { memberOf: "users\ninstaller\nauthentik Admins", primaryEmail: "lars@example.org" });
check(c2.tokens.join("|") === "--email|lars@example.org|--groups|users,installer,authentik Admins", "user modify: the verb's own flags; a list comma-separated");
const c3 = fieldChanges(zone.fields, { "access-to": "internet\nmgmt" });
check(c3.tokens.join(" ") === '--set access-to=["internet","mgmt"]', "zone modify: a list goes to --set as JSON");
check(fieldChanges(mod.fields, { memory: "lots" }).errors.memory === "memory must be a number", "a value of the wrong type is refused in the form");
check(fieldChanges(env.fields, { displayName: "" }).errors.displayName !== undefined, "emptying a field a verb cannot unset is refused, not sent");
check(placeholderOf(field(user, "displayName")!) === "no default", "an empty input with no default says so");

done("fieldmanifest");
