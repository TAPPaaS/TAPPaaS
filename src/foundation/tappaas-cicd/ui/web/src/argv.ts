// argv.ts — a form's values as the command it runs (operate.tsx's forms, the
// wizards' steps): the verb's words, the positionals the context fixes, then
// each value in the manifest's order. Pure, so the unit tests build the same
// argv the console runs.

import { ManifestVerb } from "./types";

// Form values: an option by its flag, a positional by "@<name>".
export type Values = Record<string, string | boolean | string[]>;

export interface ArgvStep {
  bin: string;
  words?: string[]; // the words to emit (default: the verb's first key)
  fixed?: string[]; // positional values the context fixes (the module, the switch and port)
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

