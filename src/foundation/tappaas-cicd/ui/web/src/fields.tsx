// fields.tsx — the one field form of every add and modify (ADR-034 D4): the
// object's fields from GET fields/<kind>[/<name>], each labelled
// "<name> · <type>", its input typed from the schema (a dropdown where the value
// must name a defined object, checkboxes for a list of them), "default <value>"
// in an empty input, and the schema's one-line description under it. Nothing
// else per field: what the change does is said once, in the Preview's head. The
// edits become the manager's own verb: `--set f=v` per changed field, or the
// verb's own flags (fieldlogic.ts).

import { useEffect, useState } from "react";
import { useRead } from "./api";
import { ClassTag } from "./fieldsform";
import { FieldManifest, ManifestField, classSummary, fieldChanges, initialFieldText, listItems, placeholderOf, typedVars } from "./fieldlogic";
import { Step, Values } from "./operate";

export function fieldsPath(kind: string, name: string | null, mode: "add" | "modify"): string {
  return `fields/${kind}${name ? `/${encodeURIComponent(name)}` : ""}${mode === "add" && name ? "?mode=add" : ""}`;
}

function Input({ f, text, set, vars }: { f: ManifestField; text: string; set: (t: string) => void; vars: Record<string, string> }) {
  const ph = placeholderOf(f, vars);
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
  const m = only ? { ...all, fields: all.fields.filter((f) => only.includes(f.name)) } : all;
  const [edits, setEdits] = useState<Record<string, string>>(() => Object.fromEntries(m.fields.map((f) => [f.name, initialFieldText(f)])));
  const [q, setQ] = useState("");
  const { errors } = fieldChanges(m.fields, edits);
  const vars = typedVars(values);
  const edit = (name: string, text: string) => {
    const next = { ...edits, [name]: text };
    setEdits(next);
    const c = fieldChanges(m.fields, next);
    set({ ...values, "@fields": c.tokens, "@classes": classSummary(c.changed) });
  };
  const open = m.fields.filter((f) => f.editable);
  const shut = m.fields.filter((f) => !f.editable);
  const match = (f: ManifestField) => !q || `${f.name} ${f.description}`.toLowerCase().includes(q.toLowerCase());
  return (
    <div className="fieldsform">
      {open.length > 12 ? <input className="search" placeholder="Filter the fields" value={q} onChange={(e) => setQ(e.target.value)} /> : null}
      {open.length === 0 ? <p className="muted small">Nothing here can be changed through this verb.</p> : null}
      {open.filter(match).map((f) => {
        const changed = edits[f.name] !== initialFieldText(f);
        return (
          <div key={f.name} className={`ff-row${changed ? " ff-changed" : ""}`}>
            <label className="ff-head">
              <span className="mono ff-name">{f.name}</span> · <span className="muted">{f.typeText}</span>
              {f.required ? <span className="ff-req" title="required"> *</span> : null}
              <span className="spacer" />
              {f.offRelease ? <span className="ff-note" title="the resolver's .orig note">kept off the release on purpose</span> : null}
              <ClassTag c={f.class} apply={f.apply} />
            </label>
            <Input f={f} text={edits[f.name] ?? ""} set={(t) => edit(f.name, t)} vars={vars} />
            {f.description ? <small className="muted">{f.description}</small> : null}
            {errors[f.name] ? <small className="ff-error">{errors[f.name]}</small> : null}
          </div>
        );
      })}
      {shut.length ? (
        <details className="ff-shut">
          <summary>{shut.length} field{shut.length === 1 ? "" : "s"} not changed here</summary>
          <table className="table compact">
            <tbody>
              {shut.filter(match).map((f) => (
                <tr key={f.name}>
                  <td className="mono">{f.name}</td>
                  <td className="mono wrap">{f.configured ? shown(f.value) : f.default !== null ? <span className="muted">{placeholderOf(f)}</span> : "—"}</td>
                  <td className="small muted">{f.why}</td>
                  <td><ClassTag c={f.class} apply={f.apply} why={f.why} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </details>
      ) : null}
    </div>
  );
}

// The form for a kind and object, loaded when the dialog opens.
function ManifestForm({ kind, name, mode, only, values, set }: { kind: string; name: string | null; mode: "add" | "modify"; only?: string[]; values: Values; set: (v: Values) => void }) {
  const r = useRead<FieldManifest>(fieldsPath(kind, name, mode), 3_600_000);
  const m = r.env?.data;
  // A new manifest (another object) starts the form again.
  const [key, setKey] = useState("");
  useEffect(() => {
    if (m) setKey(`${m.kind}/${m.name ?? ""}/${m.mode}`);
  }, [m]);
  if (r.failure) return <p className="readstate readstate-fail">The fields could not be read: {r.failure}</p>;
  if (r.env?.error && !m) return <p className="readstate readstate-fail">The fields could not be read: {r.env.error}</p>;
  if (!m) return <p className="muted">reading the fields…</p>;
  return <FieldsForm key={key} m={m} only={only} values={values} set={set} />;
}

// A step whose form is the object's fields: the manager's own verb, the
// fields' tokens appended, the options in `keep` still offered beside them.
export function fieldsStep(o: {
  title: string;
  bin: string;
  verb: string;
  words?: string[];
  fixed?: string[];
  kind: string;
  name: string | null;
  mode: "add" | "modify";
  keep?: string[]; // the verb's own options still offered beside the fields
  fields?: string[]; // only these fields (a module card's own)
  hide?: string[];
  initial?: Values;
  choices?: Record<string, string[]>;
  note?: Step["note"];
}): Step {
  return {
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
    render: (values, set) => <ManifestForm kind={o.kind} name={o.name} mode={o.mode} only={o.fields} values={values} set={set} />,
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
}
