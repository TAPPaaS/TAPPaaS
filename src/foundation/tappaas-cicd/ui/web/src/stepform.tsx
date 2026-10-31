// stepform.tsx — a step of a flow and its form, built from the verb's manifest
// (its positionals and declared options): what operate.tsx and flows.tsx show
// above the button. A disruption (--force, --allow-disruption, --yes) is a
// checkbox that names its consequence.

import { ReactNode, createContext, useEffect, useMemo, useState } from "react";
import { useVerb } from "./api";
import { ArgvStep, Values, buildArgv, formParts, prefillValues } from "./argv";
import { Job, ManifestVerb } from "./types";

export interface Step extends ArgvStep {
  title: string;
  verb: string; // the manifest verb's name
  initial?: Values;
  hide?: string[]; // options (and disruptions) not offered here
  only?: string[]; // offer only these options (and the disruptions)
  choices?: Record<string, string[]>; // offered values, by "@name" or flag
  suggest?: Record<string, string[]>; // values offered beside free text, by "@name" or flag
  suggestNotes?: Record<string, Record<string, string>>; // a suggested or offered value's note, by "@name" or flag, then value
  labels?: Record<string, string>;
  descriptions?: Record<string, ReactNode>; // an option's text in the wizard's words, in place of the verb's help, by flag
  placeholders?: Record<string, string>; // an example in place of the help's <arg>, by "@name" or flag
  asides?: Record<string, ReactNode>; // shown under an option's input, by "@name" or flag (a link to add what the dropdown lacks)
  render?: (values: Values, set: (v: Values) => void, verb: ManifestVerb) => ReactNode; // a change form of its own, its name rows included
  note?: ReactNode;
  blocked?: string; // why the change cannot run yet (a name still missing): the button waits, and says this
  button?: string; // the button's words, in the wizard's own ("Declare tappaas4")
  failed?: string; // said before why it failed ("tappaas4 was not declared")
  // The head of the Preview: what the change does (fields.tsx: the change
  // classes of the fields being changed, in the operator's words).
  previewNote?: (values: Values) => ReactNode;
  after?: (job: Job) => ReactNode; // shown once the step's job has finished (a config to download)
  // A bar over the apply while it runs, from the job's output so far (the
  // stick write's percent lines): null until the output says where it is.
  progress?: (output: string) => { pct: number; text: string } | null;
  // The applied job's output is shown elsewhere (a wizard's later stage that
  // watches it): here only its state and this line, so it is not shown twice.
  // A refused job is still shown here, where the change was made.
  jobShownIn?: string;
  // Values the assistant opened the form with (open_console): positionals and
  // options by name, merged in once the verb's manifest is read; a field form
  // takes the fields among them (PrefillContext).
  prefill?: Values;
}

// The assistant's values for the field form of the step that renders it.
export const PrefillContext = createContext<Values | null>(null);

// What Apply will run: the argv with the applying flag (or without the dry run).
// A read verb's writeWhen option (test --deep) in argv: the call is a write with no dry run.
export function writeMarkOf(verb: ManifestVerb, argv: string[]): { flag: string; touches: string } | undefined {
  return verb.effect === "read" ? (verb.writeWhen ?? []).find((w) => argv.includes(w.flag)) : undefined;
}

export function previewKindOf(verb: ManifestVerb, argv: string[]): ManifestVerb["preview"]["kind"] {
  return writeMarkOf(verb, argv) ? "none" : verb.preview.kind;
}

export function applyForm(verb: ManifestVerb | null, argv: string[]): string[] {
  if (verb?.preview.kind === "apply-flag" && !writeMarkOf(verb, argv) && !argv.includes(verb.preview.flag)) return [...argv, verb.preview.flag];
  return argv;
}

// part: "all" is the positionals, the options and the disruptions. A step with
// a form of its own (fields.tsx: the name rows, then the fields) shows "bottom"
// below it: the verb's options that are not fields under "Options", then the
// disruptions.
function VerbForm({ step, verb, values, set, part = "all" }: { step: Step; verb: ManifestVerb; values: Values; set: (v: Values) => void; part?: "all" | "bottom" }) {
  const label = (k: string, fallback: string) => step.labels?.[k] ?? fallback;
  const { names: pos, options: opts, disruptions } = formParts(step, verb);
  const field = (key: string, arg0: string | null, choices: string[] | null, repeatable: boolean) => {
    const offered = step.choices?.[key] ?? choices;
    const arg = step.placeholders?.[key] ?? arg0;
    const v = values[key];
    if (offered) {
      return (
        <select value={typeof v === "string" ? v : ""} onChange={(e) => set({ ...values, [key]: e.target.value })}>
          <option value="">{step.placeholders?.[key] ? `— ${step.placeholders[key]}` : "—"}</option>
          {offered.map((c) => (
            <option key={c} value={c}>{step.suggestNotes?.[key]?.[c] ?? c}</option>
          ))}
        </select>
      );
    }
    const hints = step.suggest?.[key];
    if (hints) {
      const id = `suggest-${key.replace(/[^a-z0-9]/gi, "")}`;
      return (
        <>
          <input type="text" list={id} placeholder={arg ? `${arg} — choose or type` : "choose or type"} value={typeof v === "string" ? v : ""} onChange={(e) => set({ ...values, [key]: e.target.value })} />
          <datalist id={id}>
            {hints.map((h) => (
              <option key={h} value={h} label={step.suggestNotes?.[key]?.[h]} />
            ))}
          </datalist>
        </>
      );
    }
    if (repeatable) {
      return (
        <textarea rows={2} placeholder={`${arg ?? "value"} — one per line`} value={Array.isArray(v) ? v.join("\n") : ""} onChange={(e) => set({ ...values, [key]: e.target.value.split("\n") })} />
      );
    }
    return <input type="text" placeholder={arg ?? ""} value={typeof v === "string" ? v : ""} onChange={(e) => set({ ...values, [key]: e.target.value })} />;
  };
  const top = part === "all";
  const optionRows = opts.map((o) =>
    o.takesValue ? (
      <label key={o.flag} className="form-row">
        <span className="mono">{label(o.flag, o.flag)}</span>
        {field(o.flag, o.arg, o.choices, o.repeatable)}
        {(step.descriptions?.[o.flag] ?? o.description) ? <small className="muted">{step.descriptions?.[o.flag] ?? o.description}</small> : null}
        {step.asides?.[o.flag] ? <small>{step.asides[o.flag]}</small> : null}
      </label>
    ) : (
      <label key={o.flag} className="form-check">
        <input type="checkbox" checked={values[o.flag] === true} onChange={(e) => set({ ...values, [o.flag]: e.target.checked })} />
        <span className="mono">{label(o.flag, o.flag)}</span> <small className="muted">{step.descriptions?.[o.flag] ?? o.description}</small>
      </label>
    ),
  );
  return (
    <div className="form">
      {top && pos.map((p) => (
        <label key={p.name} className="form-row">
          <span>{label(`@${p.name}`, p.name)}{p.optional ? "" : " *"}</span>
          {field(`@${p.name}`, `<${p.name}>`, null, false)}
        </label>
      ))}
      {part === "all" ? optionRows : null}
      {part === "bottom" && optionRows.length ? (
        <fieldset className="options">
          <legend>Options</legend>
          {optionRows}
        </fieldset>
      ) : null}
      {/* A field form (fields.tsx) lists the fields themselves. */}
      {part === "all" && verb.open && !step.render ? (
        <label className="form-row">
          <span>more options</span>
          <textarea rows={3} placeholder={"one per line: --flag value\n(see the verb's --help)"} value={Array.isArray(values["@extra"]) ? values["@extra"].join("\n") : ""} onChange={(e) => set({ ...values, "@extra": e.target.value.split("\n") })} />
          {verb.details ? <small className="muted mono wrap">{verb.details}</small> : null}
        </label>
      ) : null}
      {disruptions.length ? (
        <fieldset className="disruptions">
          <legend>Disruption — only if you mean it</legend>
          {disruptions.map((d) => (
            <label key={d.flag} className="form-check">
              <input type="checkbox" checked={values[d.flag] === true} onChange={(e) => set({ ...values, [d.flag]: e.target.checked })} />
              <span className="mono">{d.flag}</span> <small>{d.consequence}</small>
            </label>
          ))}
        </fieldset>
      ) : null}
    </div>
  );
}

// A step's form values: its initial ones, then the assistant's (step.prefill)
// merged in once the verb's manifest says which are positionals and options.
export function useStepValues(step: Step, verb: ManifestVerb | null): [Values, (v: Values) => void] {
  const [values, setValues] = useState<Values>(step.initial ?? {});
  const [prefilled, setPrefilled] = useState(false);
  useEffect(() => {
    if (!verb || !step.prefill || prefilled) return;
    const pre = prefillValues(step, verb, step.prefill, step.render !== undefined, step.only);
    setValues((v) => ({ ...v, ...pre }));
    setPrefilled(true);
  }, [verb]);
  return [values, setValues];
}

// The change form of a step, from the verb's manifest: its own form
// (step.render) with the verb's other options below, or the verb's form.
// StepView's, and a wizard's that runs the step with one button (Add node's declare).
export function StepForm({ step, verb, values, set }: { step: Step; verb: ManifestVerb; values: Values; set: (v: Values) => void }) {
  return step.render ? (
    <>
      <PrefillContext.Provider value={step.prefill ?? null}>{step.render(values, set, verb)}</PrefillContext.Provider>
      <VerbForm step={step} verb={verb} values={values} set={set} part="bottom" />
    </>
  ) : (
    <VerbForm step={step} verb={verb} values={values} set={set} />
  );
}

// What a step's flow needs of its form: the verb's manifest (null until read),
// the values, and the argv they make.
export interface StepFormState {
  step: Step;
  verb: ManifestVerb | null;
  values: Values;
  set: (v: Values) => void;
  argv: string[];
}
export function useStepForm(step: Step): StepFormState {
  const verb = useVerb(step.bin, step.verb);
  const [values, set] = useStepValues(step, verb);
  const argv = useMemo(() => buildArgv(step, verb, values), [step, verb, values]);
  return { step, verb, values, set, argv };
}
