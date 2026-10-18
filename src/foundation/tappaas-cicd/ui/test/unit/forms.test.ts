// forms.test.ts — the Modify form's logic (web/src/forms.ts): the input a
// schema type gets, the text it starts from, and the --set list the edits
// become (only what changed, typed, refused fields never).

import { CLASS_WORDS, FieldRow, capitalised, classMeaning, classTitle, classWords, initialText, inputKind, plainText, setArgs, shortValue, zoneFieldRows } from "../../web/src/forms";
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

// the change classes as their meaning (ADR-020 D3's seven; never "config-only")
check(classWords("in-place") === "applied live" && classMeaning("in-place", "none") === "recorded; shows at the next update", "in-place: applied live; with apply none, recorded and shown at the next update");
check(classWords("in-place-reboot") === "restarts the module" && classWords("grow-only") === "can grow, never shrink" && classWords("migrate") === "moves the module to another node", "restarts the module, can grow never shrink, moves the module");
check(classWords("manual") === "done by hand after the change is recorded" && classWords("immutable") === "not changed by hand" && classWords("recreate") === "not changed by hand", "manual; immutable and recreate: not changed by hand");
check(classWords("config-only") === "" && Object.keys(CLASS_WORDS).length === 7, "config-only has no words: it is a label, not a class; seven classes");
check(classTitle("immutable", "set", null).startsWith("immutable") && /delete \+ reinstall/.test(classTitle("immutable", "set", null)) && classTitle("in-place", "none", null) === "in-place (apply: none)", "the tooltip carries the technical name (and delete + reinstall where that is the way)");

done("forms");
