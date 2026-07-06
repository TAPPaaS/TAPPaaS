// validate.ts — the `environment validate` verb, implemented natively in TS.
//
// This retires validate-environment.sh (ADR-007 post-implementation refactor):
// the schema + reference gate now runs in-process, no shell-out, no Python
// jsonschema, no jq. src/foundation/schemas/environment-fields.json stays the
// single source of truth — this file INTERPRETS the schema at runtime rather
// than hard-coding its rules.
//
// Why no npm dependency is needed: the schema uses only a small, closed
// draft-2020-12 subset — `type` (incl. union types), `required`, `properties`,
// `additionalProperties:false`, `pattern`, `minLength`, `enum`, `items`,
// `uniqueItems` — all implemented below. To guarantee this port never checks
// LESS than the schema demands, the interpreter THROWS on any schema keyword it
// does not implement: schema evolution beyond the subset fails the gate loudly
// instead of silently under-validating. (The retired bash script was actually
// weaker in two ways: without python3-jsonschema it fell back to a
// required-fields-only jq check, and its belt-and-braces tlsCertRefid scan used
// `jq -e '.. | objects | has("tlsCertRefid")'`, whose exit code reflects only
// the LAST object visited.)
//
// Reference-integrity checks (ported 1:1 from the bash):
//   - network.zone must exist in zones.json (warning when zones.json absent)
//   - ownerOrg (when present) must reference an existing Organization
//     (config/people/organizations/<ownerOrg>.json)
//   - an authored tlsCertRefid ANYWHERE is REJECTED — it is runtime state, not
//     authored config (belt-and-braces over additionalProperties:false)
//
// Message shapes ("VALIDATION: <file>: <loc>: <message>", the summary lines)
// and exit semantics (0 = valid, warnings allowed; 1 = errors) match
// validate-environment.sh; error text mirrors Python jsonschema's phrasing.

import { existsSync, readFileSync, readdirSync, statSync } from "fs";
import { basename, dirname, join } from "path";
import { hasTlsCertRefid } from "./config";

// ── schema interpreter (draft-2020-12 subset) ─────────────────────────

// Keywords the interpreter understands. Annotation keywords are accepted and
// ignored; everything else is validated. An unknown keyword throws (see the
// header comment — that is the no-silent-under-validation guarantee).
const ANNOTATION_KEYWORDS = new Set(["$schema", "$id", "title", "description", "default"]);
const VALIDATION_KEYWORDS = new Set([
  "type",
  "required",
  "properties",
  "additionalProperties",
  "pattern",
  "minLength",
  "enum",
  "items",
  "uniqueItems",
]);

interface SchemaError {
  path: string[];
  message: string;
}

function locOf(path: string[]): string {
  return path.length > 0 ? path.join("/") : "(root)";
}

// Python-jsonschema-flavoured value rendering for error messages.
function repr(v: unknown): string {
  return typeof v === "string" ? `'${v}'` : JSON.stringify(v);
}

function typeMatches(t: string, v: unknown): boolean {
  switch (t) {
    case "object":
      return typeof v === "object" && v !== null && !Array.isArray(v);
    case "array":
      return Array.isArray(v);
    case "string":
      return typeof v === "string";
    case "number":
      return typeof v === "number";
    case "integer":
      return typeof v === "number" && Number.isInteger(v);
    case "boolean":
      return typeof v === "boolean";
    case "null":
      return v === null;
    default:
      throw new Error(`environment-fields.json: unsupported schema type '${t}'`);
  }
}

function asPlainObject(node: unknown, at: string, what: string): Record<string, unknown> {
  if (typeof node !== "object" || node === null || Array.isArray(node)) {
    throw new Error(`environment-fields.json: ${what} at ${at} is not an object`);
  }
  return node as Record<string, unknown>;
}

function asSchemaObject(node: unknown, at: string): Record<string, unknown> {
  const schema = asPlainObject(node, at, "schema node");
  for (const k of Object.keys(schema)) {
    if (!ANNOTATION_KEYWORDS.has(k) && !VALIDATION_KEYWORDS.has(k)) {
      throw new Error(
        `environment-fields.json: unsupported schema keyword '${k}' at ${at} — ` +
          `extend the interpreter in src/validate.ts before using it`,
      );
    }
  }
  return schema;
}

// Validate `value` against a schema node; append findings to `errs`.
function validateNode(node: unknown, value: unknown, path: string[], errs: SchemaError[]): void {
  const schema = asSchemaObject(node, locOf(path));

  // type — string or union array. A type mismatch stops deeper checks (they
  // would only be noise on a wrong-typed value).
  const typeSpec = schema.type;
  if (typeSpec !== undefined) {
    const types = (Array.isArray(typeSpec) ? typeSpec : [typeSpec]).map(String);
    if (!types.some((t) => typeMatches(t, value))) {
      errs.push({
        path,
        message: `${repr(value)} is not of type ${types.map((t) => `'${t}'`).join(", ")}`,
      });
      return;
    }
  }

  // enum — applies to any type.
  const enumSpec = schema.enum;
  if (enumSpec !== undefined) {
    if (!Array.isArray(enumSpec)) {
      throw new Error(`environment-fields.json: 'enum' at ${locOf(path)} is not an array`);
    }
    if (!enumSpec.some((e) => JSON.stringify(e) === JSON.stringify(value))) {
      errs.push({
        path,
        message: `${repr(value)} is not one of [${enumSpec.map(repr).join(", ")}]`,
      });
    }
  }

  // string keywords (per spec they only constrain string instances).
  if (typeof value === "string") {
    const pattern = schema.pattern;
    if (typeof pattern === "string" && !new RegExp(pattern).test(value)) {
      errs.push({ path, message: `${repr(value)} does not match '${pattern}'` });
    }
    const minLength = schema.minLength;
    if (typeof minLength === "number" && value.length < minLength) {
      errs.push({ path, message: `${repr(value)} is too short` });
    }
  }

  // array keywords.
  if (Array.isArray(value)) {
    const items = schema.items;
    if (items !== undefined) {
      value.forEach((item: unknown, i: number) =>
        validateNode(items, item, [...path, String(i)], errs),
      );
    }
    if (schema.uniqueItems === true) {
      const seen = new Set(value.map((v: unknown) => JSON.stringify(v)));
      if (seen.size !== value.length) {
        errs.push({ path, message: `${JSON.stringify(value)} has non-unique elements` });
      }
    }
  }

  // object keywords.
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    const obj = value as Record<string, unknown>;
    // NB: `properties` is a MAP of property name → subschema, not a schema
    // node itself — each subschema gets keyword-checked when it is visited.
    const props: Record<string, unknown> =
      schema.properties !== undefined
        ? asPlainObject(schema.properties, `${locOf(path)}.properties`, "'properties'")
        : {};

    const required = schema.required;
    if (required !== undefined) {
      if (!Array.isArray(required)) {
        throw new Error(`environment-fields.json: 'required' at ${locOf(path)} is not an array`);
      }
      for (const f of required.map(String)) {
        if (!Object.prototype.hasOwnProperty.call(obj, f)) {
          errs.push({ path, message: `'${f}' is a required property` });
        }
      }
    }

    if (schema.additionalProperties === false) {
      const extra = Object.keys(obj).filter(
        (k) => !Object.prototype.hasOwnProperty.call(props, k),
      );
      if (extra.length > 0) {
        const names = extra.map((k) => `'${k}'`).join(", ");
        errs.push({
          path,
          message: `Additional properties are not allowed (${names} ${
            extra.length === 1 ? "was" : "were"
          } unexpected)`,
        });
      }
    } else if (schema.additionalProperties !== undefined && schema.additionalProperties !== true) {
      throw new Error(
        `environment-fields.json: schema-valued 'additionalProperties' at ${locOf(path)} ` +
          `is not implemented in src/validate.ts`,
      );
    }

    for (const [k, sub] of Object.entries(props)) {
      if (Object.prototype.hasOwnProperty.call(obj, k)) {
        validateNode(sub, obj[k], [...path, k], errs);
      }
    }
  }
}

// Sort findings by instance path (mirrors the Python validator's ordering, so
// error output stays stable and diff-friendly).
function byPath(a: SchemaError, b: SchemaError): number {
  const n = Math.min(a.path.length, b.path.length);
  for (let i = 0; i < n; i++) {
    if (a.path[i] !== b.path[i]) return a.path[i] < b.path[i] ? -1 : 1;
  }
  return a.path.length - b.path.length;
}

// Validate one parsed instance against the parsed schema; returns the
// "<loc>: <message>" strings. Exported for the unit tests.
export function schemaErrors(schema: unknown, instance: unknown): string[] {
  const errs: SchemaError[] = [];
  validateNode(schema, instance, [], errs);
  errs.sort(byPath);
  return errs.map((e) => `${locOf(e.path)}: ${e.message}`);
}

// ── schema location ───────────────────────────────────────────────────

// Resolve the directory holding environment-fields.json:
//   1. $SCHEMA_DIR (same override the bash script honoured);
//   2. walk up from the compiled file — in-repo runs (dist/, dist-test/) reach
//      src/foundation/, which holds schemas/;
//   3. the mothership checkout (the nix-store binary contains only lib/ts +
//      this component, so the schema cannot ship inside it — same situation as
//      the retired bash script, which resolved through its ~/bin symlink into
//      the checkout).
export function resolveSchemaDir(): string {
  const env = process.env.SCHEMA_DIR;
  if (env) return env;
  let d = __dirname;
  for (;;) {
    if (existsSync(join(d, "schemas", "environment-fields.json"))) return join(d, "schemas");
    const up = dirname(d);
    if (up === d) break;
    d = up;
  }
  return "/home/tappaas/TAPPaaS/src/foundation/schemas";
}

// ── reference integrity (ported from validate_references) ─────────────

function validateReferences(
  instance: unknown,
  base: string,
  configDir: string,
  zonesFile: string,
  errors: string[],
  warnings: string[],
): void {
  // Reject an authored tlsCertRefid ANYWHERE (belt-and-braces over the schema,
  // which already rejects it via additionalProperties:false).
  if (hasTlsCertRefid(instance)) {
    errors.push(
      `${base}: authored 'tlsCertRefid' is not allowed (it is runtime state, not config)`,
    );
  }

  const obj =
    typeof instance === "object" && instance !== null && !Array.isArray(instance)
      ? (instance as Record<string, unknown>)
      : {};

  // network.zone must exist in zones.json (when zones.json is available).
  const net =
    typeof obj.network === "object" && obj.network !== null && !Array.isArray(obj.network)
      ? (obj.network as Record<string, unknown>)
      : {};
  const zone = typeof net.zone === "string" ? net.zone : "";
  if (zone) {
    if (existsSync(zonesFile)) {
      let known = false;
      try {
        const zones = JSON.parse(readFileSync(zonesFile, "utf8")) as unknown;
        known =
          typeof zones === "object" &&
          zones !== null &&
          Object.prototype.hasOwnProperty.call(zones, zone);
      } catch {
        known = false; // malformed zones.json — same outcome as the jq check
      }
      if (!known) {
        errors.push(
          `${base}: network.zone references unknown zone '${zone}' (not in ${zonesFile})`,
        );
      }
    } else {
      warnings.push(`${base}: zones.json not found at ${zonesFile} — skipping zone reference check`);
    }
  }

  // ownerOrg (when non-empty) must reference an existing organization.
  const owner = typeof obj.ownerOrg === "string" ? obj.ownerOrg : "";
  if (owner) {
    const orgfile = join(configDir, "people", "organizations", `${owner}.json`);
    if (!existsSync(orgfile)) {
      errors.push(`${base}: ownerOrg references unknown organization '${owner}' (no ${orgfile})`);
    }
  }
}

// ── the verb ──────────────────────────────────────────────────────────

export interface ValidateOptions {
  configDir: string;
  target?: string; // environment .json file OR a directory of them
  schemaDir?: string; // directory holding environment-fields.json
  zonesFile?: string; // path to zones.json
}

export interface ValidateReport {
  target: string;
  schemaPath: string;
  errors: string[]; // "VALIDATION: " message bodies (file-prefixed)
  warnings: string[];
}

// Validate a file/dir of environment documents. Throws on a missing target or
// schema (the caller's guarded() maps that to the clean `[Error]` + exit 1).
export function runValidate(opts: ValidateOptions): ValidateReport {
  const configDir = opts.configDir.replace(/\/+$/, "");
  const target = opts.target ?? join(configDir, "environments");
  const zonesFile = opts.zonesFile ?? join(configDir, "zones.json");
  const schemaPath = join(opts.schemaDir ?? resolveSchemaDir(), "environment-fields.json");
  if (!existsSync(schemaPath)) throw new Error(`Schema not found: ${schemaPath}`);
  const schema = JSON.parse(readFileSync(schemaPath, "utf8")) as unknown;

  const errors: string[] = [];
  const warnings: string[] = [];

  // Collect target files.
  let files: string[];
  const st = existsSync(target) ? statSync(target) : null;
  if (st?.isDirectory()) {
    files = readdirSync(target)
      .filter((f) => f.endsWith(".json"))
      .sort()
      .map((f) => join(target, f));
    if (files.length === 0) warnings.push(`no environment .json files found in ${target}`);
  } else if (st?.isFile()) {
    files = [target];
  } else {
    throw new Error(`Environment target not found: ${target}`);
  }

  for (const file of files) {
    const base = basename(file);
    let instance: unknown;
    try {
      instance = JSON.parse(readFileSync(file, "utf8"));
    } catch {
      errors.push(`${base}: not valid JSON`);
      continue;
    }
    for (const e of schemaErrors(schema, instance)) errors.push(`${base}: ${e}`);
    validateReferences(instance, base, configDir, zonesFile, errors, warnings);
  }

  return { target, schemaPath, errors, warnings };
}
