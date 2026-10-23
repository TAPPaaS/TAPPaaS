// fields.tsx — the one field form of every add and modify (ADR-034 D4): an
// add's name first, a row like a field's (the verb's positional), then the
// object's fields from GET fields/<kind>[/<name>], each labelled
// "<name> · <type>", its input typed from the schema (a dropdown where the value
// must name a defined object, checkboxes for a list of them), "default <value>"
// in an empty input, and the schema's one-line description under it. Nothing
// else per field: what the change does is said once, in the Preview's head. The
// edits become the manager's own verb: `--set f=v` per changed field, or the
// verb's own flags (fieldlogic.ts).

import { useContext, useEffect, useState } from "react";
import { useRead } from "./api";
import { formParts } from "./argv";
import { nameDescription } from "./forms";
import { ManifestVerb } from "./types";
import { ClassTag } from "./fieldsform";
import { FieldManifest, ManifestField, classSummary, fieldChanges, fieldGroups, initialFieldText, listItems, placeholderOf, typedVars } from "./fieldlogic";
import { PrefillContext, Step, Values } from "./operate";
import { AddLocationHint } from "./locations";

export function fieldsPath(kind: string, name: string | null, mode: "add" | "modify"): string {
  return `fields/${kind}${name ? `/${encodeURIComponent(name)}` : ""}${mode === "add" && name ? "?mode=add" : ""}`;
}

function Input({ f, text, set, vars, inputs }: { f: ManifestField; text: string; set: (t: string) => void; vars: Record<string, string>; inputs: Record<string, unknown> }) {
  const ph = placeholderOf(f, vars, inputs);
  if (f.type === "list" && f.choices) {
    // A list of defined objects: one box each, and a line for any other value
    // the field allows (proxyAllowedZones: internet, a network).
    const items = listItems(text);
    const others = items.filter((x) => !f.choices!.includes(x));
    const toggle = (c: string, on: boolean) => set([...f.choices!.filter((x) => (x === c ? on : items.includes(x))), ...others].join("\n"));
    return (
      <div className="ff-checks">
        {f.choices.map((c) => (
          <label key={c} className="ff-check">
            <input type="checkbox" checked={items.includes(c)} onChange={(e) => toggle(c, e.target.checked)} /> {c}
          </label>
        ))}
        <input type="text" className="ff-others" placeholder={items.length ? "others, comma-separated" : `${ph} — others, comma-separated`} value={others.join(", ")} onChange={(e) => set([...f.choices!.filter((x) => items.includes(x)), ...e.target.value.split(",").map((x) => x.trim()).filter(Boolean)].join("\n"))} />
      </div>
    );
  }
  if (f.choices || f.type === "boolean") {
    const opts = f.choices ?? ["true", "false"];
    return (
      <select value={text} onChange={(e) => set(e.target.value)}>
        <option value="">{ph}</option>
        {text !== "" && !opts.includes(text) ? <option value={text}>{text}</option> : null}
        {opts.map((o) => (
          <option key={o} value={o}>{o}</option>
        ))}
      </select>
    );
  }
  if (f.type === "list") return <textarea rows={Math.max(2, Math.min(8, text.split("\n").length + 1))} placeholder={`${ph} — one per line`} value={text} onChange={(e) => set(e.target.value)} />;
  if (f.type === "object") return <textarea className="mono" rows={Math.max(3, Math.min(12, text.split("\n").length + 1))} placeholder={ph} value={text} onChange={(e) => set(e.target.value)} />;
  return <input type="text" inputMode={f.type === "integer" ? "numeric" : undefined} placeholder={ph} value={text} onChange={(e) => set(e.target.value)} />;
}

function shown(v: unknown): string {
  if (v === null || v === undefined) return "—";
  if (Array.isArray(v)) return v.length ? v.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(", ") : "empty";
  return typeof v === "string" ? v : JSON.stringify(v);
}

export function FieldsForm({ m: all, only, values, set }: { m: FieldManifest; only?: string[]; values: Values; set: (v: Values) => void }) {
  // A name or a block: "location" is every location.* field.
  const m = only ? { ...all, fields: all.fields.filter((f) => only.some((o) => f.name === o || f.name.startsWith(`${o}.`))) } : all;
  // The assistant's values (open_console), as the field's text: a list one per line.
  const prefill = useContext(PrefillContext);
  const pre = (f: ManifestField): string | null => {
    const v = f.editable ? prefill?.[f.name] : undefined;
    return v === undefined ? null : Array.isArray(v) ? v.join("\n") : String(v);
  };
  const [edits, setEdits] = useState<Record<string, string>>(() => Object.fromEntries(m.fields.map((f) => [f.name, pre(f) ?? initialFieldText(f)])));
  useEffect(() => {
    if (!m.fields.some((f) => pre(f) !== null)) return;
    const c = fieldChanges(m.fields, edits);
    set({ ...values, "@fields": c.tokens, "@classes": classSummary(c.changed) });
  }, []);
  const [q, setQ] = useState("");
  const { errors } = fieldChanges(m.fields, edits);
  const vars = typedVars(values);
  // What a computed default follows: the verb's options as set, the fields as typed.
  const inputs: Record<string, unknown> = { ...values, ...edits };
  const edit = (name: string, text: string) => {
    const next = { ...edits, [name]: text };
    setEdits(next);
    const c = fieldChanges(m.fields, next);
    set({ ...values, "@fields": c.tokens, "@classes": classSummary(c.changed) });
  };
  const open = m.fields.filter((f) => f.editable);
  const shut = m.fields.filter((f) => !f.editable);
  const match = (f: ManifestField) => !q || `${f.name} ${f.description}`.toLowerCase().includes(q.toLowerCase());
  const row = (f: ManifestField) => {
    const changed = edits[f.name] !== initialFieldText(f);
    return (
      <div key={f.name} className={`ff-row${changed ? " ff-changed" : ""}`}>
        <label className="ff-head">
          <span className="mono ff-name">{f.name}</span> · <span className="muted">{f.typeText}</span>
          {f.required ? <span className="ff-req" title="required"> *</span> : null}
          <span className="spacer" />
          {f.offRelease ? <span className="ff-note" title="the resolver's .orig note">kept off the release on purpose</span> : null}
          {/* What a change does is a modify's: an add sets the field for the first time. */}
          {m.mode === "modify" ? <ClassTag c={f.class} apply={f.apply} /> : null}
        </label>
        <Input f={f} text={edits[f.name] ?? ""} set={(t) => edit(f.name, t)} vars={vars} inputs={inputs} />
        {f.description ? <small className="muted">{f.description}</small> : null}
        {/* A location the site lacks is added on the Site page first. */}
        {f.references === "locations" ? <small><AddLocationHint /></small> : null}
        {errors[f.name] ? <small className="ff-error">{errors[f.name]}</small> : null}
      </div>
    );
  };
  return (
    <div className="fieldsform">
      {open.length > 12 ? <input className="search" placeholder="Filter the fields" value={q} onChange={(e) => setQ(e.target.value)} /> : null}
      {open.length === 0 ? <p className="muted small">Nothing here can be changed through this verb.</p> : null}
      {fieldGroups(open.filter(match)).map((g, i) => (
        <div key={`${g.parent}-${i}`} className={g.parent && g.fields.length > 1 ? "ff-group" : "ff-top"}>
          {g.parent && g.fields.length > 1 ? <div className="ff-group-head mono">{g.parent}</div> : null}
          {g.fields.map((n) => row(open.find((f) => f.name === n)!))}
        </div>
      ))}
      {shut.length ? (
        <details className="ff-shut">
          <summary>{shut.length} field{shut.length === 1 ? "" : "s"} not changed here</summary>
          <table className="table compact">
            <tbody>
              {shut.filter(match).map((f) => (
                <tr key={f.name}>
                  <td className="mono">{f.name}</td>
                  <td className="mono wrap">{f.configured ? shown(f.value) : f.default !== null || f.defaultBy.length ? <span className="muted">{placeholderOf(f, vars, inputs)}</span> : "—"}</td>
                  <td className="small muted">{f.why}</td>
                  <td>{m.mode === "modify" ? <ClassTag c={f.class} apply={f.apply} why={f.why} /> : null}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </details>
      ) : null}
    </div>
  );
}

// The object's name, the verb's open positional, as a field of its own: the
// first row of an add form, "name · string" with its description (the
// schema's, else the kind's sentence: forms.ts), and "no default" in grey.
function NameRows({ kind, mode, verb, step, values, set, m }: { kind: string; mode: "add" | "modify"; verb: ManifestVerb; step: Pick<Step, "bin" | "fixed" | "hide" | "labels" | "placeholders">; values: Values; set: (v: Values) => void; m: FieldManifest | undefined }) {
  const names = formParts(step, verb).names;
  if (!names.length) return null;
  return (
    <div className="fieldsform ff-names">
      {names.map((p, i) => {
        const key = `@${p.name}`;
        const v = values[key];
        return (
          <div key={key} className="ff-row">
            <label className="ff-head">
              <span className="mono ff-name">{step.labels?.[key] ?? (i === 0 ? "name" : p.name)}</span> · <span className="muted">string</span>
              {!p.optional || (i === 0 && mode === "add") ? <span className="ff-req" title="required"> *</span> : null}
            </label>
            <input type="text" placeholder={step.placeholders?.[key] ?? "no default"} value={typeof v === "string" ? v : ""} onChange={(e) => set({ ...values, [key]: e.target.value })} />
            {i === 0 ? <small className="muted">{nameDescription(kind, m?.nameField?.description)}</small> : null}
          </div>
        );
      })}
    </div>
  );
}

// The form for a kind and object, loaded when the dialog opens: the name
// rows, then the fields.
function ManifestForm({ kind, name, mode, only, values, set, verb, step }: { kind: string; name: string | null; mode: "add" | "modify"; only?: string[]; values: Values; set: (v: Values) => void; verb: ManifestVerb; step: Step }) {
  const r = useRead<FieldManifest>(fieldsPath(kind, name, mode), 3_600_000);
  const m = r.env?.data;
  // A new manifest (another object) starts the form again.
  const [key, setKey] = useState("");
  useEffect(() => {
    if (m) setKey(`${m.kind}/${m.name ?? ""}/${m.mode}`);
  }, [m]);
  const names = <NameRows kind={kind} mode={mode} verb={verb} step={step} values={values} set={set} m={m ?? undefined} />;
  if (r.failure) return <>{names}<p className="readstate readstate-fail">The fields could not be read: {r.failure}</p></>;
  if (r.env?.error && !m) return <>{names}<p className="readstate readstate-fail">The fields could not be read: {r.env.error}</p></>;
  if (!m) return <>{names}<p className="muted">reading the fields…</p></>;
  return (
    <>
      {names}
      <FieldsForm key={key} m={m} only={only} values={values} set={set} />
    </>
  );
}

// A step whose form is the object's fields: the manager's own verb, the
// fields' tokens appended, the options in `keep` offered below the fields
// under "Options" (operate.tsx).
export function fieldsStep(o: {
  title: string;
  bin: string;
  verb: string;
  words?: string[];
  fixed?: string[];
  kind: string;
  name: string | null;
  mode: "add" | "modify";
  keep?: string[]; // the verb's own options that are not fields, offered under "Options"
  fields?: string[]; // only these fields, or blocks of them ("location": location.*) — a card's own
  hide?: string[];
  initial?: Values;
  choices?: Record<string, string[]>;
  note?: Step["note"];
}): Step {
  const step: Step = {
    title: o.title,
    bin: o.bin,
    verb: o.verb,
    words: o.words,
    fixed: o.fixed ?? [],
    only: o.keep ?? [],
    hide: o.hide,
    initial: o.initial,
    choices: o.choices,
    note: o.note,
    render: (values, set, verb) => <ManifestForm kind={o.kind} name={o.name} mode={o.mode} only={o.fields} values={values} set={set} verb={verb} step={step} />,
    previewNote: (values) => {
      const lines = Array.isArray(values["@classes"]) ? values["@classes"] : [];
      return lines.length ? (
        <>
          <b>What this change does</b>
          <ul className="preview-classes">
            {lines.map((l) => (
              <li key={l}>{l}</li>
            ))}
          </ul>
        </>
      ) : (
        <>No field changed in the form.</>
      );
    },
  };
  return step;
}
