// fieldsform.tsx — the Modify form of a module's card or a zone: every field
// the object owns with its value, whether that value is configured or the
// default, and its change class. Each input is typed from the field's schema;
// several fields change in one job (one `--set field=value` per changed field);
// a field the class refuses is shown, not offered.

import { useState } from "react";
import { FieldRow, defaultText, initialText, inputKind, plainText, setArgs } from "./forms";
import { Step, Values } from "./operate";

export const CLASS_TEXT: Record<string, string> = {
  "in-place": "applied live, no downtime",
  "grow-only": "a grow applies; a shrink is refused when applied",
  "in-place-reboot": "needs a guest reboot: deferred unless you allow the disruption",
  migrate: "moves the guest: deferred unless you allow the disruption",
  "config-only": "the config is the change",
  manual: "an operator action, or a verb of its own",
  immutable: "cannot change in place",
  recreate: "only by deleting and adding again",
};

export function ClassTag({ c }: { c: string }) {
  return <span className={`class-tag class-${c}`} title={CLASS_TEXT[c]}>{c}</span>;
}

function Input({ r, text, set }: { r: FieldRow; text: string; set: (t: string) => void }) {
  const k = inputKind(r);
  const dflt = `default: ${defaultText(r.default)}`;
  if (k === "enum" || k === "boolean") {
    const opts = k === "enum" ? r.enum! : ["true", "false"];
    return (
      <select value={text} onChange={(e) => set(e.target.value)}>
        {text === "" || !opts.includes(text) ? <option value={text}>{text === "" ? `— (${dflt})` : text}</option> : null}
        {opts.map((o) => (
          <option key={o} value={o}>{o}</option>
        ))}
      </select>
    );
  }
  if (k === "list") return <textarea rows={Math.max(2, Math.min(8, text.split("\n").length + 1))} placeholder={`one per line — ${dflt}`} value={text} onChange={(e) => set(e.target.value)} />;
  if (k === "object") return <textarea className="mono" rows={Math.max(3, Math.min(12, text.split("\n").length + 1))} placeholder={dflt} value={text} onChange={(e) => set(e.target.value)} />;
  return <input type="text" inputMode={k === "integer" ? "numeric" : undefined} placeholder={dflt} value={text} onChange={(e) => set(e.target.value)} />;
}

function Origin({ r }: { r: FieldRow }) {
  if (r.configured) return <span className="origin origin-set">configured</span>;
  if (r.value !== null) return <span className="origin origin-default">default</span>;
  return <span className="origin origin-none">not set</span>;
}

export function FieldsForm({ rows, values, set }: { rows: FieldRow[]; values: Values; set: (v: Values) => void }) {
  const [edits, setEdits] = useState<Record<string, string>>(() => Object.fromEntries(rows.map((r) => [r.field, initialText(r)])));
  const { errors } = setArgs(rows, edits);
  const edit = (field: string, text: string) => {
    const next = { ...edits, [field]: text };
    setEdits(next);
    set({ ...values, "--set": setArgs(rows, next).sets });
  };
  const open = rows.filter((r) => r.settable);
  const shut = rows.filter((r) => !r.settable);
  return (
    <div className="fieldsform">
      {open.length === 0 ? <p className="muted small">None of these fields can change in place.</p> : null}
      {open.map((r) => {
        const changed = edits[r.field] !== initialText(r);
        return (
          <div key={r.field} className={`ff-row${changed ? " ff-changed" : ""}`}>
            <div className="ff-head">
              <span className="mono ff-name">{r.field}</span>
              <ClassTag c={r.class} />
              <Origin r={r} />
              <span className="muted small">{r.enum ? "choice" : r.type}</span>
            </div>
            <Input r={r} text={edits[r.field] ?? ""} set={(t) => edit(r.field, t)} />
            <small className="muted">
              {r.configured || r.value === null ? <>default <span className="mono">{defaultText(r.default)}</span> · </> : null}
              {CLASS_TEXT[r.class] ?? ""}
              {r.description ? <> · {plainText(r.description)}</> : null}
            </small>
            {errors[r.field] ? <small className="ff-error">{errors[r.field]}</small> : null}
          </div>
        );
      })}
      {shut.length ? (
        <details className="ff-shut" open={open.length === 0}>
          <summary>{shut.length} field{shut.length === 1 ? "" : "s"} not editable here</summary>
          <table className="table compact">
            <tbody>
              {shut.map((r) => (
                <tr key={r.field}>
                  <td className="mono">{r.field}</td>
                  <td className="mono wrap">{initialText(r) || "—"}</td>
                  <td><ClassTag c={r.class} /> <Origin r={r} /></td>
                  <td className="small muted">{r.reason ?? CLASS_TEXT[r.class] ?? ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </details>
      ) : null}
    </div>
  );
}

// The Modify step of a module's card or a zone: the form above, then the
// manager's own preview and apply. Only the disruption flags are offered beside it.
export function modifyStep(o: { title: string; bin: string; fixed: string[]; rows: FieldRow[]; note?: string }): Step {
  return {
    title: o.title,
    bin: o.bin,
    verb: "modify",
    fixed: o.fixed,
    only: [],
    note: o.note,
    render: (values, set) => <FieldsForm rows={o.rows} values={values} set={set} />,
  };
}
