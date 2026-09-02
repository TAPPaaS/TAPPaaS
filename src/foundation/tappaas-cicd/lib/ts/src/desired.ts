// desired.ts — THE desired-state resolver (ADR-020 D1).
//
// There is exactly ONE function that answers "what is field f's desired value
// for module m?", and validate / drift / reconcile / modify all call it. Before
// ADR-020 there were two, and they disagreed: `inspect.ts` rendered an
// undeclared `cputype` as "-" while `cluster:vm/update-service.sh` defaulted it
// to `host` through its own `cfg()` ladder — the reported desired value and the
// value the update path would actually USE were different (#550). That was
// fixed on the reporting side only; the shared cause was that there was no
// single resolver to fix.
//
// The rule, in one sentence: a field's desired value is its LITERAL value in the
// deployed config, else the `module-fields.json` default — but only when that
// default APPLIES to this module, which the schema's `usedBy` decides.
//
// SHARED via lib/ts (ADR-020 Resolved Question 7): module-manager and
// network-manager resolve the same way. PURE — the resolution functions take
// parsed documents; only loadModuleFields touches the filesystem, and it is at
// the bottom, isolated.
//
// Two things this deliberately does NOT do:
//   - It does not MERGE. The 3-way release merge is a `modify` step; `resolve`
//     is a pure read+default so that `inspect` (which has not merged) and
//     `modify` (which just did) get the same answer from the same code.
//   - It does not read the cluster. Desired state is what the config says,
//     never what the guest happens to be running.

import { existsSync, readFileSync } from "fs";
import { join } from "path";

// ── jq-compatible field access ─────────────────────────────────────────
// `jq -r '.[$k] // empty'` semantics, which the bash readers this replaced all
// used: missing / null / false → "", numbers and true → their string form,
// strings raw, containers as JSON. Keeping the exact semantics matters — the
// whole point is that TS and bash resolve identically.
export function jqStr(v: unknown): string {
  if (v === undefined || v === null || v === false) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return JSON.stringify(v);
}

export function getField(o: Record<string, unknown> | null, key: string): string {
  return o ? jqStr(o[key]) : "";
}

// ── the schema ─────────────────────────────────────────────────────────

// One field's module-fields.json entry (only the parts the resolver reads).
export interface FieldSchema {
  default?: unknown;
  usedBy?: string[];
}
export type ModuleFieldsSchema = Record<string, FieldSchema>;

// The schema default that APPLIES to this module for `field`, or "" if none.
//
// A default applies only when it is a concrete scalar (not empty, not a
// "<computed…>" placeholder the schema uses for install-time-generated values
// like a random MAC) AND the field belongs to a section the module actually
// has: `usedBy` is absent or contains "general", or intersects the module's
// dependsOn. So a proxyPort default only defaults in for a module that declares
// network:proxy, a cputype only for a cluster:vm — never for a module that
// never uses the field.
export function appliedDefault(
  field: string,
  deps: string[],
  schema: ModuleFieldsSchema,
): string {
  const fs = schema[field];
  if (!fs) return "";
  const d = fs.default;
  if (typeof d !== "string" && typeof d !== "number" && typeof d !== "boolean") return "";
  const s = String(d);
  if (s === "" || s.startsWith("<")) return ""; // empty, or a "<computed>" placeholder
  const usedBy = Array.isArray(fs.usedBy) ? fs.usedBy : [];
  const applies = usedBy.length === 0 || usedBy.includes("general") || usedBy.some((u) => deps.includes(u));
  return applies ? s : "";
}

// Resolve a field to {value, defaulted}: the literal JSON value when present,
// else the applied schema default (defaulted=true), else empty/not-defaulted.
export function resolveField(
  o: Record<string, unknown> | null,
  field: string,
  deps: string[],
  schema: ModuleFieldsSchema,
): { value: string; defaulted: boolean } {
  const lit = getField(o, field);
  if (lit !== "") return { value: lit, defaulted: false };
  const def = appliedDefault(field, deps, schema);
  return def !== "" ? { value: def, defaulted: true } : { value: "", defaulted: false };
}

// ── the resolved document (`module-manager module resolve <name>`) ─────

// One field of the resolved desired document.
export interface ResolvedField {
  // The desired value, as a string — the one value both the report and the
  // apply path use. Everything downstream diffs against THIS.
  value: string;
  // True when `value` came from the schema default rather than the config.
  // Rendered with <angle brackets> by inspect; carried into the drift record so
  // an apply can say where the value it is realizing came from.
  defaulted: boolean;
  // The literal config value, "" when the field is undeclared. Kept alongside
  // `value` because "declared as the same thing as the default" and "not
  // declared at all" are different facts, and only the second one changes when
  // the schema default changes.
  literal: string;
  // The deployed value differs from the install-time pre-image (`.orig`), so
  // Desired is off Released ON PURPOSE — the #550 "not tracking release" case.
  // Reported and annotated, never auto-synced back (Resolved Question 3).
  notTracking: boolean;
}

export interface ResolvedModule {
  module: string;
  // The coordinates whose defaults were in scope, i.e. what gated `usedBy`.
  dependsOn: string[];
  integratesWith: string[];
  // Every field the schema declares that resolved to a value for this module,
  // plus every field the config declares (even one the schema does not know —
  // it is still desired state, and hiding it would make `resolve` a filter
  // rather than a resolver).
  fields: Record<string, ResolvedField>;
  // Whether a `.orig` pre-image was available. Without one, `notTracking` is
  // unknowable and is reported false everywhere — so say which it is, rather
  // than letting "no field is off release" mean two different things.
  origAvailable: boolean;
}

export function dependsOnOf(cfg: Record<string, unknown>): string[] {
  const d = cfg.dependsOn;
  return Array.isArray(d) ? d.filter((x): x is string => typeof x === "string") : [];
}

export function integratesWithOf(cfg: Record<string, unknown>): string[] {
  const d = cfg.integratesWith;
  return Array.isArray(d) ? d.filter((x): x is string => typeof x === "string") : [];
}

// Resolve a module's full desired document: the deployed config (which, after
// modify's 3-way merge, already IS the true desired state) PLUS the schema
// defaults for fields it does not declare, PLUS the `.orig` flags.
//
// `cfg` must already be NORMALIZED (Pattern-A config blocks flattened to the
// top level) — the callers' loaders do that, and doing it here would make this
// depend on a manager's config module.
export function resolveModule(
  module: string,
  cfg: Record<string, unknown>,
  orig: Record<string, unknown> | null,
  schema: ModuleFieldsSchema,
): ResolvedModule {
  const deps = dependsOnOf(cfg);
  const integ = integratesWithOf(cfg);
  // The `usedBy` gate reads dependsOn ONLY — not integratesWith. A hard
  // dependency means the module HAS that service and its fields are live; an
  // optional integration (#501) may have no provider installed at all, so
  // defaulting its fields in would invent desired state for a service that is
  // not there. This is also exactly what install/update have always gated on,
  // so the resolver reports what the apply path would use.
  const scope = deps;

  // Every field worth resolving: what the schema declares, plus what the config
  // declares. normalizeModuleConfig already flattens and drops `config`; the
  // delete guards a caller that passed a raw document.
  const names = new Set<string>([...Object.keys(schema), ...Object.keys(cfg)]);
  names.delete("config");

  const fields: Record<string, ResolvedField> = {};
  for (const name of [...names].sort()) {
    const literal = getField(cfg, name);
    const r = resolveField(cfg, name, scope, schema);
    // A field that is neither declared nor defaulted has no desired value at
    // all — emitting it as "" would invent one.
    if (r.value === "") continue;
    fields[name] = {
      value: r.value,
      defaulted: r.defaulted,
      literal,
      notTracking: orig !== null && literal !== getField(orig, name),
    };
  }

  return {
    module,
    dependsOn: deps,
    integratesWith: integ,
    fields,
    origAvailable: orig !== null,
  };
}

// ── I/O: the one place the schema is loaded ────────────────────────────

// Load module-fields.json `.fields` from the config dir (a symlink to the repo
// schema on a deployed cicd). Returns {} when absent/unreadable so a caller in
// a bare checkout resolves LITERAL values rather than failing (#550) — the
// degradation is toward "no defaults", never toward invented ones.
export function loadModuleFields(configDir: string): ModuleFieldsSchema {
  const path = join(configDir, "module-fields.json");
  if (!existsSync(path)) return {};
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    const fields = raw && typeof raw === "object" ? (raw as Record<string, unknown>).fields : null;
    return fields && typeof fields === "object" ? (fields as ModuleFieldsSchema) : {};
  } catch {
    return {};
  }
}
