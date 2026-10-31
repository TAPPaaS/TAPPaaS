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
    disruptions: verb.disruptions.filter((d) => !hidden.has(d.flag)),
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

// The typed confirmation's one rule, the server's too (src/jobs.ts createApply):
// the object's name, or the object as the manifest shows it within its container.
export const confirmMatches = (typed: string, object: string, label: string): boolean => typed !== "" && (typed === object || typed === label);

// A read verb's writeWhen option (test --deep) in argv: the call is a write with no dry run.
export function writeMarkOf(verb: ManifestVerb, argv: string[]): { flag: string; touches: string } | undefined {
  return verb.effect === "read" ? (verb.writeWhen ?? []).find((w) => argv.includes(w.flag)) : undefined;
}

export function previewKindOf(verb: ManifestVerb, argv: string[]): ManifestVerb["preview"]["kind"] {
  return writeMarkOf(verb, argv) ? "none" : verb.preview.kind;
}

export const isReadCall = (verb: ManifestVerb, argv: string[]): boolean => !writeMarkOf(verb, argv) && (verb.effect === "read" || verb.readWhen.some((w) => argv.includes(w)));
export const isDestructiveCall = (verb: ManifestVerb, argv: string[]): boolean => !isReadCall(verb, argv) && (verb.destructive || verb.destructiveWhen.some((w) => argv.includes(w)));

// How a step runs (flows.tsx), from how its verb previews.
//   read   nothing changes: one Run, or at once
//   act    a form and one button: no dry run at all, or a dry run that only
//          says yes or no, which runs first in the same job (a refusal comes back there)
//   check  the same dry run, but a destructive call: it runs as the step opens,
//          and the typed name comes after its answer
//   plan   the preview is something to read before deciding (more than this
//          change, or the drain ahead): it runs as the step opens, Apply applies it
export type Flow = "read" | "act" | "check" | "plan";

// Every apply-flag verb's preview is a plan; these are the dry runs that are too.
const PLAN_DRY_RUNS = new Set(["module-manager add-stack", "site-manager update", "site-manager repository sync", "network-manager merge", "network-manager distribute"]);

export function stepFlow(bin: string, verb: ManifestVerb, argv: string[], override?: Flow): Flow {
  if (override) return override;
  if (isReadCall(verb, argv)) return "read";
  const kind = previewKindOf(verb, argv);
  if (kind === "none") return "act";
  if (kind === "apply-flag" || PLAN_DRY_RUNS.has(`${bin} ${verb.verb}`)) return "plan";
  return isDestructiveCall(verb, argv) ? "check" : "act";
}

// The options a verb's usage cannot do without: outside its [groups] and
// (alternatives). A usage of several forms says nothing for certain.
export function requiredOptions(verb: Pick<ManifestVerb, "usage">): string[] {
  if (/\s\|\s/.test(verb.usage)) return [];
  let u = verb.usage;
  for (let prev = ""; prev !== u; ) {
    prev = u;
    u = u.replace(/\[[^[\]]*\]|\([^()]*\)/g, " ");
  }
  return u.match(/--[a-z0-9][a-z0-9-]*/g) ?? [];
}

// What the verb's form still lacks, by the name it shows there. A step with a
// form of its own (step.render) says so itself, through step.blocked.
export function missingFields(step: ArgvStep & { hide?: string[]; only?: string[]; labels?: Record<string, string> }, verb: ManifestVerb, values: Values, argv: string[]): string[] {
  const { names, options } = formParts(step, verb);
  const required = requiredOptions(verb);
  const blank = (v: Values[string] | undefined): boolean => typeof v !== "string" || v.trim() === "";
  return [
    ...names.filter((p) => !p.optional && blank(values[`@${p.name}`])).map((p) => step.labels?.[`@${p.name}`] ?? p.name),
    ...options.filter((o) => required.includes(o.flag) && !argv.includes(o.flag)).map((o) => step.labels?.[o.flag] ?? o.flag),
  ];
}
