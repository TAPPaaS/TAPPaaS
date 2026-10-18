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
  return s.replace(/\s*\((?:#\d+(?:[,;] ?)?)+\)/g, "").replace(/\s*\(ADR-\d+[^)]*\)/g, "");
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
