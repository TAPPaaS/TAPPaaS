// forms.test.ts — the Modify form's logic (web/src/forms.ts): the input a
// schema type gets, the text it starts from, and the --set list the edits
// become (only what changed, typed, refused fields never).

import { FieldRow, capitalised, envAddRows, initialText, inputKind, plainText, setArgs, shortValue, zoneFieldRows } from "../../web/src/forms";
import { check, done } from "./check";

const base: FieldRow = { field: "x", service: "", class: "in-place", settable: true, reason: null, type: "string", enum: null, description: "", example: null, value: null, configured: false, default: null };
const r = (o: Partial<FieldRow>): FieldRow => ({ ...base, ...o });

check(inputKind(r({ type: "integer" })) === "integer" && inputKind(r({ type: "boolean" })) === "boolean", "integer and boolean inputs");
check(inputKind(r({ type: "string", enum: ["a", "b"] })) === "enum", "an enum is a dropdown");
check(inputKind(r({ type: "array" })) === "list" && inputKind(r({ type: "object" })) === "object", "lists and objects");

const memory = r({ field: "memory", type: "integer", value: "8192", configured: true });
const zones = r({ field: "proxyAllowedZones", type: "array", value: '["home","guest"]', configured: true });
const backup = r({ field: "backup", type: "object", value: '{"enabled":true}', configured: true });
const bios = r({ field: "bios", class: "recreate", settable: false, value: "ovmf" });
const mode = r({ field: "aliasType", enum: ["host", "network"], value: "host" });

check(initialText(zones) === "home\nguest", "a list starts one item per line");
check(initialText(backup) === '{\n  "enabled": true\n}', "an object starts as JSON");
check(initialText(r({ value: null })) === "" && initialText(r({ value: "null" })) === "", "no value: empty");

const start = Object.fromEntries([memory, zones, backup, bios, mode].map((x) => [x.field, initialText(x)]));
check(setArgs([memory, zones, backup, bios, mode], start).sets.length === 0, "nothing edited: nothing to set");

const e1 = setArgs([memory, zones, backup, bios, mode], { ...start, memory: "10240", proxyAllowedZones: "home\n\niotLocal ", aliasType: "network" });
check(e1.sets.join(" ") === 'memory=10240 proxyAllowedZones=["home","iotLocal"] aliasType=network', "several fields in one job, typed (a list as JSON)");
check(Object.keys(e1.errors).length === 0, "no errors for valid edits");

const e2 = setArgs([memory, backup, mode], { memory: "ten", backup: "{nope", aliasType: "bridge" });
check(e2.sets.length === 0 && Object.keys(e2.errors).sort().join() === "aliasType,backup,memory", "an invalid edit is not set and says why");

const e3 = setArgs([bios], { bios: "seabios" });
check(e3.sets.length === 0, "a refused field is never set");

const flag = r({ field: "isolated", type: "boolean", value: "false" });
check(setArgs([flag], { isolated: "true" }).sets.join() === "isolated=true", "a boolean is set as true/false");

check(shortValue('["a","b"]') === "a, b" && shortValue(null) === "—" && shortValue("x".repeat(60), 10).length === 10, "a card's one-line value");

check(plainText("the node's first ZFS pool (#692). Thin disks (#773, #774): opt-in (ADR-020 D3).") === "the node's first ZFS pool. Thin disks: opt-in.", "a description loses its issue and ADR numbers");

// ── the add-environment form ─────────────────────────────────────────────
const envSchema = {
  required: ["name", "displayName", "ownerOrg", "network"],
  properties: {
    name: { type: "string", description: "Slug identifier for the environment." },
    displayName: { type: "string", description: "Human-readable environment name." },
    ownerOrg: { type: "string", description: "Reference to the owning Organization.name." },
    domains: { type: "object", properties: { primary: { type: "string", description: "Primary public domain." }, dnsMode: { type: "string", enum: ["per-service", "wildcard"], default: "per-service" } } },
    network: { type: "object", description: "Network placement. NO vlan here (CR-09).", properties: { zone: { type: "string", description: "Reference to a zone key in zones.json (validated)." } } },
  },
};
const help = { "--owner": "The organization that owns the environment (default: the first organization, by name)." };
const rows = envAddRows(envSchema, { name: "acme", orgs: ["zeta", "rossen"], zones: ["rossen", "home"], help });
const by = (k: string) => rows.find((x) => x.key === k)!;
check(rows.filter((x) => x.required).map((x) => x.key).join() === "@env", "only the name must be given");
check(by("--owner").whenEmpty === "rossen" && by("--owner").choices?.join() === "rossen,zeta", "left empty, the owner is the first organization by name");
check(by("--zone").whenEmpty === "acme" && by("--display").whenEmpty === "Acme", "the zone is named like the environment, the display name is it capitalised");
check(by("--dns-mode").whenEmpty === "per-service" && by("--dns-mode").choices?.join() === "per-service,wildcard", "the DNS mode's default and choices come from the schema");
check(/inside only/.test(by("--domain").whenEmpty ?? ""), "no domain: says what that means");
check(by("--owner").description === help["--owner"] && by("--domain").description === "Primary public domain.", "the verb's help first, else the schema's description");
const none = envAddRows(envSchema, { name: "", orgs: [], zones: [], help: {} });
check(/no organization/.test(none.find((x) => x.key === "--owner")!.whenEmpty ?? "") && none.find((x) => x.key === "--zone")!.whenEmpty === "a zone named like the environment", "before a name or an organization exists: said in words, no placeholder");
check(rows.every((x) => !/<env>|\bN\b|\bD\b|\bZ\b/.test(`${x.whenEmpty ?? ""}`)), "no placeholder in a default");
check(capitalised("rossen") === "Rossen" && capitalised("") === "", "capitalised");

// ── a zone's fields ────────────────────────────────────────────────────
const zschema = {
  vlantag: { type: "integer", changeClass: "immutable" },
  state: { type: "string", default: "Inactive", changeClass: "manual", changeNote: "use network-manager enable|disable|manual" },
  "access-to": { type: "array", default: [], changeClass: "in-place" },
  "pinhole-allowed-from": { type: "array", default: [], changeClass: "in-place" },
  mdns: { type: "boolean", default: false, changeClass: "in-place" },
  serves: { type: ["string", "array"], changeClass: "manual" },
  odd: { type: "string" },
};
const zrows = zoneFieldRows({ name: "home", vlantag: 310, state: "Active", "access-to": ["internet"] }, zschema);
const z = (f: string) => zrows.find((x) => x.field === f)!;
check(zrows.length === 7, "every field of zones-fields.json, set or not");
check(!z("vlantag").settable && z("vlantag").class === "immutable" && z("vlantag").value === "310", "an immutable field is shown with its value, not offered");
check(!z("state").settable && z("state").reason === "use network-manager enable|disable|manual", "a manual field names its verb");
check(z("access-to").settable && z("access-to").configured && initialText(z("access-to")) === "internet", "a configured list");
check(!z("mdns").configured && z("mdns").value === "false" && z("mdns").default === false, "an unset field shows its default as the value in effect");
check(z("serves").type === "array" && !z("odd").settable, "string-or-list is a list; no change class: not settable");
const zset = setArgs(zrows, { "access-to": "internet\nmgmt", "pinhole-allowed-from": "dmz", mdns: "true", vlantag: "999" });
check(zset.sets.join(" ") === 'access-to=["internet","mgmt"] pinhole-allowed-from=["dmz"] mdns=true', "several zone fields in one modify; the immutable one is not sent");

done("forms");
