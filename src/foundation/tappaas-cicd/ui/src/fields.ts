// fields.ts — what a Modify form needs to know about each field, read-only.
// For a module: `module-manager fields` (the change class, whether --set may
// change it, the service that owns it), `module-manager resolve` (the value in
// effect, configured or the schema's default) and the composed field schema
// config/module-fields.json (type, enum, default, description). For a zone or
// an environment the form reads the schema file itself (schemaDoc), from the
// repository the managers run from.

import { existsSync, readFileSync } from "fs";
import { oneLine } from "./fieldmanifest";
import { join } from "path";

export interface FieldRow {
  field: string;
  // The `<module>:<service>` that owns the field, or "" for the module itself.
  service: string;
  class: string;
  settable: boolean;
  reason: string | null;
  type: string;
  enum: string[] | null;
  description: string;
  example: unknown;
  // The value in effect as resolve prints it (a string; JSON for a list or an object).
  value: string | null;
  configured: boolean;
  default: unknown;
}

export interface ModuleFields {
  module: string;
  dependsOn: string[];
  integratesWith: string[];
  fields: FieldRow[];
  warnings: string[];
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const strs = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

// A schema type as one word: "integer|string" and ["string","array"] become
// the most permissive of them that a form can offer.
export function typeWord(t: unknown): string {
  const words = (Array.isArray(t) ? t : typeof t === "string" ? t.split("|") : []).filter((x): x is string => typeof x === "string" && x !== "null");
  if (words.length === 0) return "string";
  if (words.length === 1) return words[0];
  if (words.includes("array")) return "array";
  if (words.includes("object")) return "object";
  return "string";
}

// moduleClasses: schemas/fields.json — the declared class of a field no service
// owns, shown instead of module-manager's "config-only" label.
export function moduleFieldRows(fieldsDoc: unknown, resolveDoc: unknown, schema: Obj, moduleClasses: Record<string, { class?: string; changeNote?: string }> = {}): ModuleFields {
  const f = obj(fieldsDoc);
  const r = obj(resolveDoc);
  const resolved = obj(r.fields);
  const dependsOn = strs(r.dependsOn);
  const integratesWith = strs(r.integratesWith);
  const rows: FieldRow[] = [];
  for (const raw of Array.isArray(f.fields) ? f.fields : []) {
    const x = obj(raw);
    const field = typeof x.field === "string" ? x.field : "";
    if (!field) continue;
    const spec = obj(schema[field]);
    const res = obj(resolved[field]);
    // A refused field names no coordinate: its owner is the service of this
    // module its schema entry says uses it.
    const coordinate = typeof x.coordinate === "string" ? x.coordinate : "";
    const service = coordinate || strs(spec.usedBy).find((u) => dependsOn.includes(u)) || "";
    const value = typeof res.value === "string" ? res.value : x.value === null || x.value === undefined ? null : String(x.value);
    const own = moduleClasses[field]?.class;
    const declared = !coordinate && own ? own : undefined;
    const notByHand = declared === "immutable" || declared === "recreate" || declared === "manual";
    rows.push({
      field,
      service,
      class: declared ?? (typeof x.class === "string" ? x.class : ""),
      settable: x.settable === true && !notByHand,
      reason: notByHand ? oneLine(moduleClasses[field]?.changeNote) || (declared === "manual" ? "changed in the module's own JSON, then an update" : "the release or the install writes it") : typeof x.reason === "string" ? x.reason : null,
      type: typeWord(spec.type),
      enum: Array.isArray(spec.enum) ? spec.enum.map(String) : null,
      description: typeof spec.description === "string" ? spec.description : "",
      example: spec.example ?? null,
      value,
      // Not in resolve at all: neither configured nor defaulted.
      configured: res.defaulted === false && value !== null,
      default: spec.default ?? null,
    });
  }
  return { module: typeof f.module === "string" ? f.module : "", dependsOn, integratesWith, fields: rows, warnings: strs(f.warnings) };
}

// The schema documents a form may read, by name.
export const SCHEMAS: Record<string, string> = {
  zones: "zones-fields.json",
  environment: "environment-fields.json",
};

export function schemaDoc(repoRoot: string, name: string): Obj {
  const file = SCHEMAS[name];
  if (!file) throw new Error(`no schema '${name}' (one of: ${Object.keys(SCHEMAS).join(", ")})`);
  const p = join(repoRoot, "src", "foundation", "schemas", file);
  if (!existsSync(p)) throw new Error(`${file} not found under ${repoRoot}`);
  return JSON.parse(readFileSync(p, "utf8")) as Obj;
}

// The composed module field schema (`.fields` of config/module-fields.json).
export function moduleSchema(configDir: string): Obj {
  const p = join(configDir, "module-fields.json");
  if (!existsSync(p)) return {};
  try {
    return obj(obj(JSON.parse(readFileSync(p, "utf8"))).fields);
  } catch {
    return {};
  }
}
