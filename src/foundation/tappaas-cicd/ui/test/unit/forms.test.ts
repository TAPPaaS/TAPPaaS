// forms.test.ts — the Modify form's logic (web/src/forms.ts): the input a
// schema type gets, the text it starts from, and the --set list the edits
// become (only what changed, typed, refused fields never).

import { FieldRow, initialText, inputKind, plainText, setArgs, shortValue } from "../../web/src/forms";
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

done("forms");
