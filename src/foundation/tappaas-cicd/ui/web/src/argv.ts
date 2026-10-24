// argv.ts — a form's values as the command it runs (operate.tsx's forms, the
// wizards' steps): the verb's words, the positionals the context fixes, then
// each value in the manifest's order. Pure, so the unit tests build the same
// argv the console runs.

import { ManifestOption, ManifestVerb } from "./types";

// Form values: an option by its flag, a positional by "@<name>".
export type Values = Record<string, string | boolean | string[]>;

export interface ArgvStep {
  bin: string;
  words?: string[]; // the words to emit (default: the verb's first key)
  fixed?: string[]; // positional values the context fixes (the module, the switch and port)
}

// Never offered in a form: the job model sets the preview and apply flags; the
// console reads the config it reads; output formats are for the CLI.
export const ALWAYS_HIDDEN = ["--apply", "--dry-run", "--check", "--diff", "--json", "--config-dir", "--help", "-h", "--debug", "--silent", "--quiet"];

// What a form offers, in its order: the positionals the context leaves open
// (the object's name first), the verb's options (a field form's "Options"
// block, after its fields; only those in `only` when it is given), then the
// disruptions, each a checkbox naming its consequence.
export function formParts(step: ArgvStep & { hide?: string[]; only?: string[] }, verb: ManifestVerb): { names: ManifestVerb["positionals"]; options: ManifestOption[]; disruptions: ManifestVerb["disruptions"] } {
  const hidden = new Set([...ALWAYS_HIDDEN, ...(step.hide ?? [])]);
  const disruptive = new Set(verb.disruptions.map((d) => d.flag));
  return {
    names: verb.positionals.slice(step.fixed?.length ?? 0).filter((p) => !hidden.has(`@${p.name}`)),
    options: verb.options.filter((o) => !hidden.has(o.flag) && !disruptive.has(o.flag) && (!step.only || step.only.includes(o.flag))),
    disruptions: verb.disruptions,
  };
}

export function buildArgv(step: ArgvStep, verb: ManifestVerb | null, values: Values): string[] {
  if (!verb) return [step.bin, ...(step.words ?? []), ...(step.fixed ?? [])];
  const words = step.words ?? verb.keys[0] ?? [];
  const out = [step.bin, ...words, ...(step.fixed ?? [])];
  const pos = verb.positionals.slice(step.fixed?.length ?? 0);
  for (const p of pos) {
    const v = values[`@${p.name}`];
    if (typeof v === "string" && v.trim()) out.push(v.trim());
  }
  for (const o of verb.options) {
    const v = values[o.flag];
    if (v === undefined || v === false || v === "") continue;
    if (v === true) out.push(o.flag);
    else if (Array.isArray(v)) for (const x of v.filter((y) => y.trim())) out.push(o.flag, x.trim());
    else out.push(o.flag, v.trim());
  }
  // A field form's tokens (fields.tsx): `--set f=v`, `--unset f`, or the verb's
  // own flag and its value, already in argv order.
  const fieldTokens = values["@fields"];
  if (Array.isArray(fieldTokens)) out.push(...fieldTokens);
  // An open verb's further options (identity's field flags, module add's
  // --<field> <value>): one per line, the flag then its value.
  const extra = values["@extra"];
  if (verb.open && Array.isArray(extra)) {
    for (const line of extra.map((l) => l.trim()).filter((l) => l.startsWith("--"))) {
      const sp = line.indexOf(" ");
      if (sp < 0) out.push(line);
      else out.push(line.slice(0, sp), line.slice(sp + 1).trim());
    }
  }
  return out;
}

// Values the assistant opened a form with (open_console), as this form's
// values: a key that is one of its open positionals becomes "@<name>" ("name"
// is the only one, when there is one), one of its options its flag, and on an
// open verb without a field form any other key a "--key value" line of its
// further options. Keys that fit none are left to a field form (fields.tsx),
// or dropped. With a field form an option is set only when the form offers it
// besides the fields (`keep`): where a field is the verb's own option (place
// --rack), the field form passes it.
export function prefillValues(step: ArgvStep, verb: ManifestVerb, raw: Values, fieldForm = false, keep: string[] = []): Values {
  const out: Values = {};
  const pos = verb.positionals.slice(step.fixed?.length ?? 0);
  const extra: string[] = [];
  for (const [key, v] of Object.entries(raw)) {
    const k = key.replace(/^[@-]+/, "");
    const p = pos.find((x) => x.name === k) ?? (k === "name" && pos.length === 1 ? pos[0] : undefined);
    const o = verb.options.find((x) => x.flag === `--${k}`);
    if (p && typeof v === "string") out[`@${p.name}`] = v;
    else if (o && (!fieldForm || keep.includes(o.flag))) out[o.flag] = o.takesValue ? (typeof v === "boolean" ? String(v) : v) : v === true || v === "true";
    else if (verb.open && !fieldForm && v !== false) extra.push(v === true ? `--${k}` : `--${k} ${Array.isArray(v) ? v.join(",") : v}`);
  }
  if (extra.length) out["@extra"] = extra;
  return out;
}

// What a destructive call's typed confirmation names, before any job exists
// (the console's own rule, manifest.ts): the first positional that is not a
// marker word, else --name's value, else the verb; a verb that declares its
// object (remove-port) is confirmed by that positional, or shown within its
// container ("<switch>:<port>").
export function confirmObject(step: ArgvStep, verb: ManifestVerb, values: Values, argv: string[]): { object: string; label: string } {
  const positionals = [...(step.fixed ?? [])];
  for (const p of verb.positionals.slice(step.fixed?.length ?? 0)) {
    const v = values[`@${p.name}`];
    if (typeof v === "string" && v.trim()) positionals.push(v.trim());
  }
  const marks = new Set([...verb.readWhen, ...verb.destructiveWhen]);
  const n = argv.indexOf("--name");
  let object = positionals.find((p) => !marks.has(p)) ?? (n >= 0 ? argv[n + 1] : undefined) ?? verb.verb;
  let label = object;
  if (verb.object) {
    const at = (name: string): string | undefined => {
      const i = verb.positionals.findIndex((p) => p.name === name);
      return i >= 0 ? positionals[i] : undefined;
    };
    const own = at(verb.object.positional);
    if (own !== undefined) {
      object = own;
      label = [...verb.object.within.map(at).filter((x): x is string => x !== undefined), own].join(":");
    }
  }
  return { object, label };
}
