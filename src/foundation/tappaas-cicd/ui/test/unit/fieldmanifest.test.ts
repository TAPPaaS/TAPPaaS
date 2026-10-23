// fieldmanifest.test.ts — the field manifest of every add and modify form
// (src/fieldmanifest.ts): one case per kind over the repository's own schema
// files and records shaped like hrossen's, the template rendering of defaults,
// and the one-line descriptions; then the form's argv (web/src/fieldlogic.ts).

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { composeFields } from "../../../lib/ts/src/compose-fields";
import { FieldManifest, RefContext, backupDefs, buildManifest, environmentDefaults, environmentDefs, flattenSchema, moduleAddDefaults, moduleDefs, oneLine, renderDefault, zoneAddDefaults, zoneDefs } from "../../src/fieldmanifest";
import { classSummary, fieldChanges, fieldGroups, placeholderOf, typedVars } from "../../web/src/fieldlogic";
import { formParts } from "../../web/src/argv";
import { nameDescription } from "../../web/src/forms";
import { ManifestVerb } from "../../web/src/types";
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
  devices: ["Nano HD", "USW Pro XG 10 PoE", "tappaas1", "tappaas2"],
  racks: ["rack1"],
  rooms: ["basement"],
  faceplates: ["generic/server-2u", "unifi/usw-pro-xg-10-poe"],
  locations: ["hareskov", "rodovre"],
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
check(field(zadd, "environment")?.arg === "--environment" && field(zadd, "environment")?.choices?.includes("rossen") === true && field(zadd, "environment")?.typeText === "environments", "zone add: the environment(s) it belongs to, a list of environments, passed as --environment");
check(field(zone, "environment")?.editable === false && /verb of its own/.test(field(zone, "environment")?.why ?? ""), "zone modify: the environment link has its verb (bind), not --set");

// ── environment ─────────────────────────────────────────────────────────
const edefs = environmentDefs(schema("environment-fields.json"));
check(!flattenSchema(schema("environment-fields.json")).some((f) => f.name.startsWith("network")), "environment-fields: an environment names no zone");
const env = buildManifest({ kind: "environment", name: "rossen", mode: "modify", defs: edefs, record: { name: "rossen", displayName: "Rossen", ownerOrg: "rossen", zone: "rossen", domains: { primary: "hrossen.dk", dnsMode: "per-service" } }, refs, vars: {} });
check(field(env, "name") === undefined, "environment modify: the name is the verb's positional, not a field");
check(field(env, "ownerOrg")?.typeText === "an organization" && field(env, "ownerOrg")?.arg === "--owner" && field(env, "ownerOrg")?.value === "rossen", "…ownerOrg names an organization, passed as --owner");
check(field(env, "zone")?.choices?.includes("rossen") === true && field(env, "zone")?.arg === "--zone" && field(env, "zone")?.value === "rossen" && field(env, "domains.dnsMode")?.typeText === "one of per-service, wildcard", "…its zone a zone (--zone, the zone naming it); dnsMode one of per-service, wildcard");
check(field(env, "displayName")?.required === true && field(env, "domains.primary")?.required === false, "…required as the schema says");
const eadd = buildManifest({ kind: "environment", name: null, mode: "add", defs: edefs, record: null, defaults: { displayName: "<Name>", ownerOrg: "rossen", zone: "<name>" }, refs, vars: { name: null } });
check(field(eadd, "ownerOrg")?.default === "rossen" && field(eadd, "displayName")?.defaultTemplate === true, "environment add: what the manager uses when a field is left empty");
check(placeholderOf(field(eadd, "displayName")!, typedVars({ "@env": "acme" })) === "default Acme" && placeholderOf(field(eadd, "zone")!, typedVars({ "@env": "acme" })) === "default acme", "…filled from the name as it is typed: default Acme, default acme");

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
const site = buildManifest({ kind: "site", name: null, mode: "modify", defs: flattenSchema(schema("site-fields.json")), record: { name: "rossen", defaultEnvironment: "rossen", channel: "unstable", primaryLocation: "rodovre", keyboard: "dk", updateSchedule: { frequency: "weekly", weekday: "Thursday", hour: 2 } }, refs, vars: {} });
check(field(site, "defaultEnvironment")?.typeText === "an environment" && field(site, "defaultEnvironment")?.editable === false, "site: defaultEnvironment names an environment; site modify has no option for it");
check(field(site, "updateSchedule.frequency")?.arg === "--updateFrequency" && field(site, "updateSchedule.hour")?.type === "integer" && field(site, "updateSchedule.weekday")?.choices?.length === 7, "…the schedule's three fields, with their flags");
const locDefs = flattenSchema((schema("site-fields.json").$defs as Record<string, unknown>).location);
check(locDefs.find((d) => d.name === "latitude")?.type === "number" && field(site, "updateSchedule.hour")?.typeText === "integer", "…a decimal is a number, an integer integer");
check(field(site, "primaryLocation")?.arg === "--primaryLocation" && field(site, "primaryLocation")?.value === "rodovre" && field(site, "keyboard")?.arg === "--keyboard", "…the primary location and the keyboard, passed as their flags");
check(field(site, "diskAutoGrow.threshold")?.class === "in-place", "…a leaf takes its object's class");
check(field(site, "name")?.editable === false && /^immutable: The site's code/.test(field(site, "name")?.why ?? "") && field(site, "name")?.value === "rossen", "…name shown, refused with the schema's reason");
check(/^immutable: Written once/.test(field(site, "version")?.why ?? "") && /^immutable: /.test(field(site, "defaultEnvironment")?.why ?? ""), "…version and defaultEnvironment too");
check(field(site, "dnssec")?.arg === "--dnssec" && field(site, "dnssec")?.type === "boolean" && field(site, "dnsBlocklists.zones")?.type === "list" && field(site, "dnsBlocklists.zones")?.typeText === "zones", "…dnssec a boolean, the blocklist zones a list of zones");
check(field(site, "diskAutoGrow.threshold")?.arg === "--diskAutoGrowThreshold" && field(site, "diskAutoGrow.threshold")?.default === "80" && field(site, "branding.logoDark")?.arg === "--brandingLogoDark", "…disk growth by key, with its defaults; branding's two files");
check(/^manual: Has verbs of its own: site-manager location/.test(field(site, "locations")?.why ?? "") && /^manual: Retired: migration 0022/.test(field(site, "hardware")?.why ?? ""), "…the locations are manual and the retired hardware says why");

check(field(site, "primaryLocation")?.typeText === "a location" && field(site, "primaryLocation")?.choices?.join() === "hareskov,rodovre", "…the primary location is one of the site's locations");

// ── location: site-fields.json's $defs.location, by site-manager location ──
const locDefsAll = flattenSchema((schema("site-fields.json").$defs as Record<string, unknown>).location);
const locAdd = buildManifest({ kind: "location", name: null, mode: "add", defs: locDefsAll, record: null, defaults: { displayName: "<name>", kind: "site" }, refs, vars: {} });
check(locAdd.nameField !== null && !locAdd.fields.some((f) => f.name === "name"), "location add: the name is the verb's positional");
check(field(locAdd, "country")?.required === true && field(locAdd, "country")?.arg === "--country" && field(locAdd, "timezone")?.arg === "--timezone", "…country required, every field its flag");
check(field(locAdd, "kind")?.choices?.join() === "site,remote" && field(locAdd, "kind")?.default === "site", "…kind one of site, remote, site by default");
check(field(locAdd, "latitude")?.typeText === "number", "…a coordinate is labelled number");
const locMod = buildManifest({ kind: "location", name: "rodovre", mode: "modify", defs: locDefsAll, record: { country: "DK", city: "Rodovre", timezone: "Europe/Copenhagen" }, refs, vars: {} });
check(field(locMod, "city")?.value === "Rodovre" && field(locMod, "city")?.editable === true && field(locMod, "address")?.configured === false, "location modify: the record's values, each editable");

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

// ── the form's order: name, the fields as the schema orders them, Options, disruptions ──
const eopen = eadd.fields.filter((f) => f.editable);
check(JSON.stringify(fieldGroups(eopen)) === JSON.stringify([{ parent: "", fields: ["displayName", "ownerOrg", "zone"] }, { parent: "domains", fields: ["domains.primary", "domains.dnsMode"] }]), "environment add: the fields in the schema's order (its zone after its owner), a nested object's under its parent");
check(JSON.stringify(fieldGroups([{ name: "a.x" }, { name: "b" }, { name: "a.y" }, { name: "c" }])) === JSON.stringify([{ parent: "a", fields: ["a.x", "a.y"] }, { parent: "", fields: ["b", "c"] }]), "…a parent's fields stay together where the schema interleaves them");
const envAddVerb = {
  verb: "add", keys: [["add"]], positionals: [{ name: "env", optional: true, repeatable: false }],
  options: ["--name", "--domain", "--owner", "--zone", "--create-zone", "--display", "--dns-mode", "--force", "--json"].map((flag) => ({ flag, takesValue: !["--create-zone", "--force", "--json"].includes(flag), arg: null, choices: null, repeatable: false, description: "" })),
  disruptions: [{ flag: "--force", consequence: "overwrites" }],
} as unknown as ManifestVerb;
const parts = formParts({ bin: "environment-manager", only: ["--create-zone"] }, envAddVerb);
check(parts.names.map((p) => p.name).join() === "env" && parts.options.map((o) => o.flag).join() === "--create-zone" && parts.disruptions.map((d) => d.flag).join() === "--force", "environment add: the name, then --create-zone as the one option the fields leave, then --force as a disruption");
check(formParts({ bin: "environment-manager", fixed: ["rossen"] }, envAddVerb).names.length === 0 && !formParts({ bin: "x" }, envAddVerb).options.some((o) => o.flag === "--json" || o.flag === "--force"), "…a fixed name is no row; --json is never offered, a disruption never as an option");

// ── the name row: the positional as a field, described ───────────────────
check(eadd.nameField?.description === "Slug identifier for the environment (e.g. foo, bar, default, mgmt).", "environment add: the name field's description comes from the schema");
check(nameDescription("environment", eadd.nameField?.description) === "Slug identifier for the environment (e.g. foo, bar, default, mgmt). Also the default of its network zone and, capitalised, of its display name.", "…followed by what the manager derives from the name");
check(zadd.nameField === null && nameDescription("zone", null) === "The zone's name: camelCase, no hyphens (e.g. iotCams); its key in zones.json.", "zone add: no name field in zones-fields, so the kind's own sentence");
check(/^Slug identifier, used as the Authentik user identifier\. Also the default of the display name\.$/.test(nameDescription("user", user.nameField?.description)), "user: the schema's description, then the display name it defaults");
check(org.nameField !== null && role.nameField !== null && group.nameField !== null, "…every identity kind's schema describes its name");

// ── the defaults the managers compute, as the form shows them ────────────
// environment-manager add: the typed name, the first organization, and no domain without --domain
const eadd2 = buildManifest({ kind: "environment", name: null, mode: "add", defs: edefs, record: null, defaults: environmentDefaults("add", { firstOrg: "rossen", siteBackup: { target: "backup.mgmt.internal", defaultSchedule: "weekly" }, record: null }), refs, vars: { name: null } });
check(placeholderOf(field(eadd2, "displayName")!) === "default the name, capitalised" && placeholderOf(field(eadd2, "zone")!) === "default the name", "environment add, nothing typed: the display name and zone say what they will be, never <Name>");
check(placeholderOf(field(eadd2, "domains.primary")!) === "default no public domain (reached only from inside)" && placeholderOf(field(eadd2, "ownerOrg")!) === "default rossen", "…domains.primary: no public domain unless one is given (environment-manager writes no domains block); the owner is the first organization");
check(field(eadd2, "domains.primary")?.required === false, "…so domains.primary is not required");
check(placeholderOf(field(eadd2, "backup.schedule")!) === "default weekly, the site's" && placeholderOf(field(eadd2, "backup.retention")!) === "default 7y, the site's" && placeholderOf(field(eadd2, "backup.residency")!) === "default eu-only, the environment's data residency", "…the backup cascade's fields: the site's schedule and retention, the environment's residency");
const emod = buildManifest({ kind: "environment", name: "test", mode: "modify", defs: edefs, record: { name: "test", displayName: "Test", ownerOrg: "rossen", zone: "test", dataResidency: "global" }, defaults: environmentDefaults("modify", { firstOrg: "rossen", siteBackup: {}, record: { dataResidency: "global" } }), refs, vars: {} });
check(placeholderOf(field(emod, "domains.primary")!) === "default no public domain (reached only from inside)" && placeholderOf(field(emod, "backup.residency")!) === "default global, the environment's data residency" && field(emod, "displayName")?.default === null, "environment modify, no domain: the same words; no add-time default for a field the record has");

// network-manager add over hrossen's zones (fixture): band 2 has 200 and 299
const zfix = (JSON.parse(readFileSync(join(FIX, "zones.json"), "utf8")) as Record<string, unknown>[]).map((z) => [String(z.name), z] as [string, Record<string, unknown>]);
const zcomp = zoneAddDefaults(zfix, ((schema("zones-fields.json").archetypes ?? {}) as { catalog: Record<string, unknown> }).catalog);
const zadd2 = buildManifest({ kind: "zone", name: null, mode: "add", defs: zdefs, record: null, defaults: zcomp.defaults, defaultBy: zcomp.by, refs, vars: {} });
const zph = (n: string, inputs: Record<string, unknown> = {}, vars: Record<string, string> = {}) => placeholderOf(field(zadd2, n)!, vars, inputs);
check(zph("vlantag") === "default 298, the highest free in band 2 (260-299)" && zph("type") === "default Service" && zph("typeId") === "default 2", "zone add: a Service zone, the VLAN the highest free in band 2 (298: 299 is taken)");
check(zph("ip") === "default 10.2.98.0/24" && zph("access-to") === "default internet" && zph("state") === "default Active" && zph("tier") === "default untiered: no archetype", "…its network, access-to, state, and untiered without an archetype");
check(zph("description", {}, typedVars({ "@name": "lab" })) === "default Zone lab", "…its description follows the typed name");
const cams = { "--archetype": "iot-cams" };
check(zph("type", cams) === "default IoT" && zph("tier", cams) === "default 6" && zph("isolated", cams) === "default true" && zph("access-to", cams) === "default empty", "…--archetype iot-cams stamps its type, tier, isolated and access-to seed");
check(zph("vlantag", cams) === "default 499, the highest free in band 4 (460-499)" && zph("ip", cams) === "default 10.4.99.0/24", "…and its VLAN moves to band 4");
check(zph("vlantag", { typeId: "3" }) === "default 399, the highest free in band 3 (360-399)", "…a typed typeId moves the VLAN to its band");
check(zph("type", { "--from-zone": "home" }) === "default Client" && zph("description", { "--from-zone": "home" }, typedVars({ "@name": "kids" })) === "default Zone kids (inherited from home)", "…--from-zone inherits the source zone's type; the description names it");

// module-manager add: the VM's name follows the environment and --instance; a taken VM id the next free
const mcomp = moduleAddDefaults({ module: "vaultwarden", own: vw, defaultEnv: "rossen", envs: [{ name: "mgmt", zone: "mgmt" }, { name: "rossen", zone: "rossen" }, { name: "test", zone: "test" }], firstNode: "tappaas1", usedVmids: [Number(vw.vmid), Number(vw.vmid) + 1] });
const madd = buildManifest({ kind: "module", name: "vaultwarden", mode: "add", defs: moduleDefs(composed), record: null, defaults: { ...vw, ...mcomp.defaults }, defaultBy: mcomp.by, moduleClasses, services: (vw.dependsOn as string[]) ?? [], refs, vars: { name: "vaultwarden", vmname: "vaultwarden", domain: "hrossen.dk" } });
const mph = (n: string, inputs: Record<string, unknown> = {}) => placeholderOf(field(madd, n)!, {}, inputs);
check(mph("vmname") === "default vaultwarden" && mph("vmname", { "--environment": "rossen" }) === "default vaultwarden" && mph("vmname", { "--environment": "test" }) === "default vaultwarden-test", "module add: vmname is the module's name, suffixed in an environment that is not the default");
check(mph("vmname", { "--environment": "test", "--instance": "vault2" }) === "default vault2", "…--instance names it");
check(mph("vmid") === `default ${Number(vw.vmid) + 2}, the next free (${vw.vmid}, the module's own, is taken)`, "…a VM id a config already uses gives way to the next free one");
check(mph("node") === "default tappaas1, the site's first node", "…no node of its own: the site's first node");
check(moduleAddDefaults({ module: "x", own: { vmid: 700 }, defaultEnv: null, envs: [], firstNode: null, usedVmids: [] }).defaults.vmid === undefined, "…a free VM id stays the module's own");

// identity-manager <kind> add: the display name is the name
const uadd = buildManifest({ kind: "user", name: null, mode: "add", defs: flattenSchema(schema("user-fields.json")), record: null, defaults: { displayName: "<name>" }, refs, vars: { name: null } });
check(placeholderOf(field(uadd, "displayName")!, typedVars({ "@name": "anna" })) === "default anna" && field(uadd, "displayName")?.required === false && field(uadd, "primaryEmail")?.required === true, "user add: the display name defaults to the typed name; the e-mail is still required");

// ── positions-fields: a rack and a placement ─────────────────────────────
const rdefs = schema("positions-fields.json").$defs as Record<string, unknown>;
const radd = buildManifest({ kind: "rack", name: null, mode: "add", defs: flattenSchema(rdefs.rack), record: null, refs, vars: {} });
check(radd.nameField !== null && !field(radd, "name"), "rack add: the name is the verb's positional, not a field");
check(field(radd, "units")?.arg === "--units" && field(radd, "units")?.default === "42" && field(radd, "displayName")?.arg === "--display-name", "rack add: each field through its flag, with the schema's default");
check(field(radd, "numbering")?.choices?.join(",") === "bottom-up,top-down", "rack add: numbering is a choice");
const room = buildManifest({ kind: "room", name: null, mode: "add", defs: flattenSchema(rdefs.room), record: null, refs, vars: {} });
check(room.nameField !== null && !field(room, "name") && field(room, "displayName")?.arg === "--display-name" && field(room, "description")?.arg === "--description" && field(room, "location")?.arg === "--location" && room.fields.length === 3, "room add: the name is the positional; display name, description and its location");
const rmod = buildManifest({ kind: "rack", name: "rack1", mode: "modify", defs: flattenSchema(rdefs.rack), record: { units: 42, width: "19in", numbering: "bottom-up" }, refs, vars: {} });
check(field(rmod, "units")?.arg === "--set" && field(rmod, "units")?.class === "in-place" && field(rmod, "units")?.value === 42, "rack modify: --set within the field's class, the value shown");
const mnt = buildManifest({ kind: "placement", name: "tappaas2", mode: "add", defs: flattenSchema(rdefs.placement), record: null, defaults: { faceplate: "generic/server-2u, the catalog's suggestion" }, refs, vars: {} });
check(mnt.nameField !== null && !field(mnt, "device"), "place: the device is the verb's positional");
check(field(mnt, "rack")?.typeText === "a rack" && field(mnt, "rack")?.choices?.join(",") === "rack1", "place: the rack is one of the racks");
check(field(mnt, "faceplate")?.typeText === "a faceplate" && field(mnt, "faceplate")?.choices?.includes("unifi/usw-pro-xg-10-poe") === true && field(mnt, "faceplate")?.default === "generic/server-2u, the catalog's suggestion", "place: the faceplate from the catalog, the suggestion as its default");
check(field(mnt, "u")?.required !== true && field(mnt, "u")?.arg === "--u" && field(mnt, "room")?.typeText === "a room" && field(mnt, "room")?.choices?.join() === "basement" && field(mnt, "room")?.arg === "--room", "place: a rack and its u, or a room (one of the rooms): neither is required alone");
const mmod = buildManifest({ kind: "placement", name: "tappaas1", mode: "modify", defs: flattenSchema(rdefs.placement), record: { rack: "rack1", u: 10, height: 2, width: "full", face: "front" }, refs, vars: {} });
check(field(mmod, "u")?.arg === "--set" && field(mmod, "rack")?.arg === "--set", "place modify: a move is --set rack and u");
check(fieldChanges(mmod.fields, { u: "14" }).tokens.join(" ") === "--set u=14", "place modify: a move is one --set");

done("fieldmanifest");
