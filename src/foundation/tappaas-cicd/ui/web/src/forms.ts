// forms.ts — the Modify forms' logic, apart from React so the unit tests run
// it: which input a field gets from its schema type, the text an input starts
// from, and the `--set field=value` list a form's edits become. A module's rows
// come from the backend (GET modules/<m>/fields); a zone's are built here from
// zones.json and zones-fields.json.

export interface FieldRow {
  field: string;
  service: string; // "<module>:<service>" that owns it, "" for the object itself
  class: string;
  settable: boolean;
  reason: string | null;
  type: string;
  enum: string[] | null;
  description: string;
  example: unknown;
  value: string | null; // the value in effect; JSON text for a list or an object
  configured: boolean;
  default: unknown;
}

export type InputKind = "string" | "integer" | "boolean" | "enum" | "list" | "object";

export function inputKind(r: Pick<FieldRow, "type" | "enum">): InputKind {
  if (r.enum && r.enum.length) return "enum";
  switch (r.type) {
    case "integer":
    case "number":
      return "integer";
    case "boolean":
      return "boolean";
    case "array":
      return "list";
    case "object":
      return "object";
    default:
      return "string";
  }
}

function parsed(v: string | null): unknown {
  if (v === null) return null;
  try {
    return JSON.parse(v);
  } catch {
    return v;
  }
}

// The text an input starts from: a list one item per line, an object as JSON.
export function initialText(r: FieldRow): string {
  const k = inputKind(r);
  if (r.value === null || r.value === "null") return "";
  if (k === "list") {
    const v = parsed(r.value);
    return Array.isArray(v) ? v.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join("\n") : r.value;
  }
  if (k === "object") {
    const v = parsed(r.value);
    return v !== null && typeof v === "object" ? JSON.stringify(v, null, 2) : r.value;
  }
  return r.value;
}

// A schema description as the form shows it: without the issue numbers
// ("(#692)") that tell a developer where it came from.
export function plainText(s: string): string {
  return s.replace(/\s*\((?:(?:#\d+|CR-\d+)(?:[,;] ?)?)+\)/g, "").replace(/\s*\(ADR-\d+[^)]*\)/g, "");
}

// A value as one short line, for a card.
export function shortValue(v: string | null, max = 40): string {
  if (v === null || v === "null") return "—";
  const p = parsed(v);
  const s = Array.isArray(p) ? (p.length ? p.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(", ") : "[]") : typeof p === "string" ? (p === "" ? '""' : p) : JSON.stringify(p);
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

export function defaultText(d: unknown): string {
  if (d === null || d === undefined) return "none";
  if (typeof d === "string") return d === "" ? '""' : d;
  return JSON.stringify(d);
}

// The value an edit becomes on the command line, or why it cannot.
export function setValue(r: FieldRow, text: string): { ok: true; value: string } | { ok: false; why: string } {
  const k = inputKind(r);
  const t = text.trim();
  if (k === "integer") {
    return /^-?\d+$/.test(t) ? { ok: true, value: t } : { ok: false, why: "a whole number" };
  }
  if (k === "boolean") return t === "true" || t === "false" ? { ok: true, value: t } : { ok: false, why: "true or false" };
  if (k === "enum") return r.enum!.includes(t) ? { ok: true, value: t } : { ok: false, why: `one of ${r.enum!.join(", ")}` };
  if (k === "list") {
    const items = text.split("\n").map((x) => x.trim()).filter((x) => x !== "");
    return { ok: true, value: JSON.stringify(items.map((x) => (/^[{[]/.test(x) ? safeJson(x) : x))) };
  }
  if (k === "object") {
    try {
      const v = JSON.parse(t) as unknown;
      if (v === null || typeof v !== "object" || Array.isArray(v)) return { ok: false, why: "a JSON object" };
      return { ok: true, value: JSON.stringify(v) };
    } catch {
      return { ok: false, why: "valid JSON" };
    }
  }
  return { ok: true, value: text };
}

function safeJson(x: string): unknown {
  try {
    return JSON.parse(x);
  } catch {
    return x;
  }
}

// The --set list of a form: one per field whose text differs from where it
// started, in the rows' order; the fields that cannot be set as typed, why.
export function setArgs(rows: FieldRow[], edits: Record<string, string>): { sets: string[]; errors: Record<string, string> } {
  const sets: string[] = [];
  const errors: Record<string, string> = {};
  for (const r of rows) {
    const e = edits[r.field];
    if (e === undefined || !r.settable) continue;
    if (e === initialText(r)) continue;
    const v = setValue(r, e);
    if (v.ok) sets.push(`${r.field}=${v.value}`);
    else errors[r.field] = `${r.field} must be ${v.why}`;
  }
  return { sets, errors };
}

// ── adding an environment ───────────────────────────────────────────────

// One input of the add form: the value the operator must give, or what
// environment-manager uses when it is left empty.
export interface EnvAddRow {
  key: string; // "@env" or the option's flag
  field: string; // where it lands in the environment's record
  required: boolean;
  whenEmpty: string | null;
  description: string;
  choices: string[] | null;
  kind: "string" | "enum" | "boolean";
}

type Props = Record<string, { description?: string; default?: unknown; enum?: unknown; properties?: Props }>;

function prop(schema: Record<string, unknown>, path: string): { description?: string; default?: unknown; enum?: unknown } {
  let p: Props = (schema.properties ?? {}) as Props;
  const parts = path.split(".");
  for (let i = 0; i < parts.length - 1; i++) p = p[parts[i]]?.properties ?? {};
  return p[parts[parts.length - 1]] ?? {};
}

export function capitalised(name: string): string {
  return name ? name.charAt(0).toUpperCase() + name.slice(1) : "";
}

// The add form from environment-fields.json and the manager's own defaults
// (cmdAdd): the owner is the first organization by name, the zone is named
// like the environment, the display name is the name capitalised, the DNS mode
// is the schema's default. `help` is the verb's option text by flag.
export function envAddRows(schema: Record<string, unknown>, ctx: { name: string; orgs: string[]; zones: string[]; help: Record<string, string> }): EnvAddRow[] {
  const d = (path: string, flag: string): string => ctx.help[flag] || plainText(prop(schema, path).description ?? "");
  const firstOrg = [...ctx.orgs].sort()[0] ?? null;
  const dns = prop(schema, "domains.dnsMode");
  const dnsModes = Array.isArray(dns.enum) ? dns.enum.map(String) : ["per-service", "wildcard"];
  const named = (v: string | null, why: string) => (v ? v : why);
  return [
    { key: "@env", field: "name", required: true, whenEmpty: null, description: plainText(prop(schema, "name").description ?? ""), choices: null, kind: "string" },
    { key: "--display", field: "displayName", required: false, whenEmpty: named(capitalised(ctx.name), "the name, capitalised"), description: d("displayName", "--display"), choices: null, kind: "string" },
    { key: "--owner", field: "ownerOrg", required: false, whenEmpty: firstOrg ?? "none: there is no organization yet, so the record is refused", description: d("ownerOrg", "--owner"), choices: [...ctx.orgs].sort(), kind: "enum" },
    { key: "--zone", field: "network.zone", required: false, whenEmpty: named(ctx.name, "a zone named like the environment"), description: d("network.zone", "--zone"), choices: [...ctx.zones].sort(), kind: "string" },
    { key: "--create-zone", field: "zones.json", required: false, whenEmpty: "off: the zone must exist already", description: ctx.help["--create-zone"] ?? "", choices: null, kind: "boolean" },
    { key: "--domain", field: "domains.primary", required: false, whenEmpty: "no public domain: the environment is reached inside only", description: d("domains.primary", "--domain"), choices: null, kind: "string" },
    { key: "--dns-mode", field: "domains.dnsMode", required: false, whenEmpty: typeof dns.default === "string" ? dns.default : "per-service", description: d("domains.dnsMode", "--dns-mode"), choices: dnsModes, kind: "enum" },
  ];
}

// ── zones ───────────────────────────────────────────────────────────────

export interface ZoneFieldSpec {
  type?: unknown;
  enum?: unknown;
  default?: unknown;
  description?: string;
  changeClass?: string;
  changeNote?: string;
  example?: unknown;
}

// The classes a --set refuses before anything is written; `manual` has a verb of its own.
const ZONE_REFUSED: Record<string, string> = {
  immutable: "cannot change in place: delete the zone and add it again",
  recreate: "only by deleting the zone and adding it again",
  manual: "has a verb of its own",
};

function zoneType(t: unknown): string {
  const words = (Array.isArray(t) ? t : typeof t === "string" ? t.split("|") : []).filter((x): x is string => typeof x === "string" && x !== "null");
  if (words.length === 1) return words[0];
  return words.includes("array") ? "array" : "string";
}

// Every field of zones-fields.json with the zone's value, its default and its class.
export function zoneFieldRows(zone: Record<string, unknown>, schema: Record<string, ZoneFieldSpec>): FieldRow[] {
  return Object.entries(schema).map(([field, spec]) => {
    const cls = spec.changeClass ?? "";
    const has = Object.prototype.hasOwnProperty.call(zone, field);
    const v = has ? zone[field] : spec.default;
    const refused = cls === "" ? "has no change class: it cannot be set through a verb" : ZONE_REFUSED[cls] ?? null;
    return {
      field,
      service: "",
      class: cls || "unclassified",
      settable: refused === null,
      reason: refused === null ? null : cls === "manual" && spec.changeNote ? spec.changeNote : refused,
      type: zoneType(spec.type),
      enum: Array.isArray(spec.enum) ? spec.enum.map(String) : null,
      description: spec.description ?? "",
      example: spec.example ?? null,
      value: v === undefined || v === null ? null : typeof v === "string" ? v : JSON.stringify(v),
      configured: has,
      default: spec.default ?? null,
    };
  });
}
