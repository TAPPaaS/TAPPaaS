// fieldlogic.ts — the field form's logic apart from React, so the unit tests
// run it: the text an input starts from, its placeholder, and the argv tokens
// a form's edits become (`--set f=v`, `--unset f`, or the verb's own flag and
// its value), with the change classes of the fields being changed for the
// Preview's head. The manifest comes from GET fields/<kind>[/<name>]
// (src/fieldmanifest.ts, whose ManifestField this mirrors).

import { classMeaning } from "./forms";

export interface ManifestField {
  name: string;
  type: "string" | "integer" | "boolean" | "list" | "object";
  typeText: string;
  choices: string[] | null;
  references: string | null;
  default: string | null;
  defaultTemplate: boolean;
  value: unknown;
  configured: boolean;
  required: boolean;
  class: string | null;
  apply: string | null;
  offRelease: boolean;
  description: string;
  editable: boolean;
  why: string | null;
  arg: string | null;
}

export interface FieldManifest {
  kind: string;
  name: string | null;
  mode: "add" | "modify";
  exists: boolean;
  fields: ManifestField[];
}

// What an empty input says: the real default, or that there is none. A
// template the backend could not fill (an add, before the name is typed) is
// filled from `vars` where it can be: <name>, <Name>.
export function placeholderOf(f: ManifestField, vars: Record<string, string> = {}): string {
  if (f.default === null) return "no default";
  const d = f.defaultTemplate ? f.default.replace(/<([A-Za-z][\w.]*)>/g, (m, k: string) => vars[k] || m) : f.default;
  return `default ${d}`;
}

// The template values a form knows from its own inputs: the name being typed.
export function typedVars(values: Record<string, unknown>): Record<string, string> {
  const n = [values["@env"], values["@name"]].find((v): v is string => typeof v === "string" && v.trim() !== "")?.trim() ?? "";
  return n ? { name: n, Name: n.charAt(0).toUpperCase() + n.slice(1) } : {};
}

const itemText = (x: unknown): string => (typeof x === "string" ? x : JSON.stringify(x));

// The text an input starts from: a list one item per line, an object as JSON.
export function initialFieldText(f: ManifestField): string {
  const v = f.value;
  if (v === null || v === undefined) return "";
  if (f.type === "list") return Array.isArray(v) ? v.map(itemText).join("\n") : String(v);
  if (f.type === "object") return typeof v === "object" ? JSON.stringify(v, null, 2) : String(v);
  return typeof v === "string" ? v : JSON.stringify(v);
}

export function listItems(text: string): string[] {
  return text.split("\n").map((x) => x.trim()).filter((x) => x !== "");
}

// The value an edit becomes on the command line, or why it cannot. A list goes
// to --set as JSON and to a flag comma-separated, as the managers take it.
export function encodeField(f: ManifestField, text: string): { ok: true; value: string } | { ok: false; why: string } {
  const t = text.trim();
  if (f.choices && f.type !== "list" && !f.choices.includes(t) && f.references === null) return { ok: false, why: `one of ${f.choices.join(", ")}` };
  switch (f.type) {
    case "integer":
      return /^-?\d+(\.\d+)?$/.test(t) ? { ok: true, value: t } : { ok: false, why: "a number" };
    case "boolean":
      return t === "true" || t === "false" ? { ok: true, value: t } : { ok: false, why: "true or false" };
    case "list": {
      const items = listItems(text).map((x) => (/^[{[]/.test(x) ? safeJson(x) : x));
      if (f.arg === "--set") return { ok: true, value: JSON.stringify(items) };
      if (items.some((x) => typeof x !== "string")) return { ok: false, why: "a list of names" };
      return { ok: true, value: (items as string[]).join(",") };
    }
    case "object":
      try {
        const v = JSON.parse(t) as unknown;
        if (v === null || typeof v !== "object") return { ok: false, why: "a JSON object or list" };
        return { ok: true, value: JSON.stringify(v) };
      } catch {
        return { ok: false, why: "valid JSON" };
      }
    default:
      return { ok: true, value: text.trim() };
  }
}

function safeJson(x: string): unknown {
  try {
    return JSON.parse(x);
  } catch {
    return x;
  }
}

export interface FieldChanges {
  tokens: string[]; // appended to the verb's argv
  errors: Record<string, string>;
  changed: { name: string; class: string | null; apply: string | null }[];
}

// The argv a form's edits become: one token pair per field whose text differs
// from where it started, in the manifest's order. Emptying a configured field
// unsets it where the verb can (`--unset`), and is refused where it cannot.
export function fieldChanges(fields: ManifestField[], edits: Record<string, string>): FieldChanges {
  const out: FieldChanges = { tokens: [], errors: {}, changed: [] };
  for (const f of fields) {
    if (!f.editable || f.arg === null) continue;
    const e = edits[f.name];
    if (e === undefined || e === initialFieldText(f)) continue;
    if (e.trim() === "") {
      if (!f.configured) continue;
      if (f.arg === "--set") {
        out.tokens.push("--unset", f.name);
        out.changed.push({ name: f.name, class: f.class, apply: f.apply });
      } else out.errors[f.name] = `${f.name} cannot be emptied here`;
      continue;
    }
    const v = encodeField(f, e);
    if (!v.ok) {
      out.errors[f.name] = `${f.name} must be ${v.why}`;
      continue;
    }
    if (f.arg === "--set") out.tokens.push("--set", `${f.name}=${v.value}`);
    else out.tokens.push(f.arg, v.value);
    out.changed.push({ name: f.name, class: f.class, apply: f.apply });
  }
  return out;
}

// The Preview's head: what the change does, once per class, in the
// operator's words ("restarts the module: memory, cores").
export function classSummary(changed: { name: string; class: string | null; apply?: string | null }[]): string[] {
  const by = new Map<string, string[]>();
  for (const c of changed) {
    const k = classMeaning(c.class, c.apply) || "changes";
    by.set(k, [...(by.get(k) ?? []), c.name]);
  }
  return [...by.entries()].map(([k, names]) => `${k}: ${names.join(", ")}`);
}
