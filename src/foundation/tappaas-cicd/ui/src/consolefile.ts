// consolefile.ts — a module's console.json (ADR-034 D11): what it adds to its
// page. Read each time a page is, checked against schemas/console-fields.json,
// and taken apart entry by entry: a bad entry is an error in its place and the
// good ones stand. The console has no npm dependencies, so the few JSON-Schema
// keywords that file uses are checked here.

import { existsSync, readFileSync, statSync } from "fs";
import { join } from "path";

type Obj = Record<string, unknown>;

export const CONSOLE_FILE = "console.json";
export const CONSOLE_SCHEMA = "console-fields.json";
const MAX_FILE = 256 * 1024;

export interface SchemaError {
  path: string; // /sections/2/render; "" the document itself
  message: string;
}

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const typeOf = (v: unknown): string => (v === null ? "null" : Array.isArray(v) ? "array" : typeof v);

// One JSON-Schema document's verdict on a value: every error, with where.
export function schemaErrors(schema: unknown, value: unknown, root: unknown = schema, path = ""): SchemaError[] {
  if (schema === true) return [];
  if (schema === false) return [{ path, message: "is not allowed here" }];
  if (!isObj(schema)) return [];
  const s = schema;
  if (typeof s.$ref === "string") {
    const target = s.$ref.replace(/^#\//, "").split("/").reduce<unknown>((o, k) => (isObj(o) ? o[k] : undefined), root);
    return schemaErrors(target, value, root, path);
  }
  const out: SchemaError[] = [];
  const say = (message: string, at = path): void => void out.push({ path: at, message });
  if (typeof s.type === "string" && typeOf(value) !== s.type) {
    say(`must be ${s.type === "array" || s.type === "object" ? `an ${s.type}` : `a ${s.type}`}, not ${typeOf(value)}`);
    return out;
  }
  if ("const" in s && value !== s.const) say(`must be ${JSON.stringify(s.const)}`);
  if (Array.isArray(s.enum) && !s.enum.includes(value)) say(`must be one of ${s.enum.join(", ")}`);
  if (typeof value === "string") {
    if (typeof s.minLength === "number" && value.length < s.minLength) say("must not be empty");
    if (typeof s.pattern === "string" && !new RegExp(s.pattern).test(value)) say(`'${value}' is not a valid value`);
  }
  if (Array.isArray(value)) {
    if (typeof s.minItems === "number" && value.length < s.minItems) say(`needs at least ${s.minItems}`);
    if (s.items !== undefined) value.forEach((v, i) => out.push(...schemaErrors(s.items, v, root, `${path}/${i}`)));
  }
  if (isObj(value)) {
    for (const k of Array.isArray(s.required) ? (s.required as string[]) : []) if (!(k in value)) say(`needs ${k}`);
    const props = isObj(s.properties) ? s.properties : {};
    for (const [k, v] of Object.entries(value)) {
      if (k in props) out.push(...schemaErrors(props[k], v, root, `${path}/${k}`));
      else if (s.additionalProperties === false) say(`has an unknown key '${k}'`);
    }
  }
  if (Array.isArray(s.allOf)) for (const x of s.allOf) out.push(...schemaErrors(x, value, root, path));
  if (Array.isArray(s.anyOf) && !s.anyOf.some((x) => schemaErrors(x, value, root, path).length === 0)) {
    say(`needs one of: ${s.anyOf.map((x) => (x as { required?: string[] }).required?.join(" and ") ?? "?").join(", ")}`);
  }
  if (s.if !== undefined) {
    const branch = schemaErrors(s.if, value, root, path).length === 0 ? s.then : s.else;
    if (branch !== undefined) out.push(...schemaErrors(branch, value, root, path));
  }
  return out;
}

export interface DeclaredRead {
  bin: string;
  verb: string;
  args?: string[];
}
export interface DeclaredColumn {
  path: string;
  label: string;
  format?: string;
}
export interface DeclaredField {
  label?: string;
  labelPath?: string;
  path?: string;
  value?: string;
  max?: string;
  format?: string;
}
export interface DeclaredSection {
  id: string;
  title?: string;
  read?: DeclaredRead;
  render?: "kv" | "table" | "gauges";
  rows?: string;
  columns?: DeclaredColumn[];
  fields?: DeclaredField[];
  summary?: DeclaredField;
  before?: string;
  after?: string;
}
export interface DeclaredOperation {
  label: string;
  bin: string;
  verb: string;
  args?: string[];
  note?: string;
  kind?: "danger";
}

export interface ConsoleFile {
  sections: (DeclaredSection | { bad: string; id: string })[];
  operations: DeclaredOperation[];
  badOperations: string[];
  error: string | null; // the file as a whole cannot be used
}

export const NO_FILE: ConsoleFile = { sections: [], operations: [], badOperations: [], error: null };

const say = (errors: SchemaError[]): string => errors.map((e) => `${e.path.replace(/^\/(sections|operations)\/\d+\/?/, "") || "this entry"} ${e.message}`).join("; ");

// A document against the schema, entry by entry.
export function parseConsole(doc: unknown, schema: Obj): ConsoleFile {
  if (!isObj(schema.$defs)) return { ...NO_FILE, error: `${CONSOLE_SCHEMA} could not be read` };
  const errors = schemaErrors(schema, doc);
  const at = (list: string, i: number): SchemaError[] => errors.filter((e) => e.path === `/${list}/${i}` || e.path.startsWith(`/${list}/${i}/`));
  const whole = errors.filter((e) => !/^\/(sections|operations)\/\d+(\/|$)/.test(e.path));
  if (whole.length) return { ...NO_FILE, error: whole.map((e) => `${e.path.slice(1) || CONSOLE_FILE} ${e.message}`).join("; ") };
  const d = doc as { sections?: unknown[]; operations?: unknown[] };
  return {
    sections: (d.sections ?? []).map((s, i) => {
      const bad = at("sections", i);
      if (!bad.length) return s as DeclaredSection;
      const id = isObj(s) && typeof s.id === "string" && /^[a-z][a-z0-9-]{0,62}$/.test(s.id) ? s.id : `bad-section-${i + 1}`;
      return { bad: say(bad), id };
    }),
    operations: (d.operations ?? []).filter((_, i) => at("operations", i).length === 0) as DeclaredOperation[],
    badOperations: (d.operations ?? []).flatMap((o, i) => {
      const bad = at("operations", i);
      return bad.length ? [`${isObj(o) && typeof o.label === "string" ? o.label : `operation ${i + 1}`}: ${say(bad)}`] : [];
    }),
    error: null,
  };
}

// The module's file, beside its module JSON; none: nothing declared.
export function readConsoleFile(moduleSource: string | null, schema: Obj): ConsoleFile {
  if (!moduleSource) return NO_FILE;
  const file = join(moduleSource, CONSOLE_FILE);
  if (!existsSync(file)) return NO_FILE;
  try {
    if (statSync(file).size > MAX_FILE) return { ...NO_FILE, error: `${CONSOLE_FILE} is over ${MAX_FILE / 1024} KiB` };
    return parseConsole(JSON.parse(readFileSync(file, "utf8")), schema);
  } catch (e) {
    return { ...NO_FILE, error: `${CONSOLE_FILE}: ${(e as Error).message}` };
  }
}
