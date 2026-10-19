// operate.tsx — the one way the console changes the site (ADR-034 D4, spike
// §5.4): Change → Preview → Apply → Result. The form is built from the verb's
// manifest (its positionals and declared options), the command block is exactly
// what will run and can be copied, the preview is the manager's own dry run,
// Apply is enabled by the preview, a disruption (--force, --allow-disruption,
// --yes) is a checkbox that names its consequence, and a destructive verb needs
// the object's name typed and the Installer role. A flow of several steps
// (update-port, then reconcile) runs them in order.

import { ReactNode, createContext, useEffect, useMemo, useState } from "react";
import { applyJob, previewJob, readJob, reloadAll, useJob, useRead, useVerb } from "./api";
import { ArgvStep, Values, buildArgv, prefillValues } from "./argv";
import { useOpenedBy } from "./opener";
import { Command, Output, jobResult } from "./jobs";
import { Job, ManifestVerb, Me } from "./types";
import { Link, Tag, canOperate, useMe } from "./ui";

export type { Values } from "./argv";

export interface Step extends ArgvStep {
  title: string;
  verb: string; // the manifest verb's name
  initial?: Values;
  hide?: string[]; // options not offered here
  only?: string[]; // offer only these options (and the disruptions)
  choices?: Record<string, string[]>; // offered values, by "@name" or flag
  labels?: Record<string, string>;
  placeholders?: Record<string, string>; // an example in place of the help's <arg>, by "@name" or flag
  render?: (values: Values, set: (v: Values) => void) => ReactNode; // a change form of its own
  note?: ReactNode;
  // The head of the Preview: what the change does (fields.tsx: the change
  // classes of the fields being changed, in the operator's words).
  previewNote?: (values: Values) => ReactNode;
  after?: (job: Job) => ReactNode; // shown once the step's job has finished (a config to download)
  // Values the assistant opened the form with (open_console): positionals and
  // options by name, merged in once the verb's manifest is read; a field form
  // takes the fields among them (PrefillContext).
  prefill?: Values;
}

// The assistant's values for the field form of the step that renders it.
export const PrefillContext = createContext<Values | null>(null);

// Never offered in a form: the job model sets the preview and apply flags; the
// console reads the config it reads; output formats are for the CLI.
const ALWAYS_HIDDEN = ["--apply", "--dry-run", "--check", "--diff", "--json", "--config-dir", "--help", "-h", "--debug", "--silent", "--quiet"];

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

// part: "top" is the positionals and options, "bottom" the disruptions; a step
// with a form of its own (fields.tsx) shows that form between the two.
function VerbForm({ step, verb, values, set, part = "all" }: { step: Step; verb: ManifestVerb; values: Values; set: (v: Values) => void; part?: "all" | "top" | "bottom" }) {
  const hidden = new Set([...ALWAYS_HIDDEN, ...(step.hide ?? [])]);
  const disruptive = new Set(verb.disruptions.map((d) => d.flag));
  const label = (k: string, fallback: string) => step.labels?.[k] ?? fallback;
  const pos = verb.positionals.slice(step.fixed?.length ?? 0).filter((p) => !hidden.has(`@${p.name}`));
  const opts = verb.options.filter((o) => !hidden.has(o.flag) && !disruptive.has(o.flag) && (!step.only || step.only.includes(o.flag)));
  const field = (key: string, arg0: string | null, choices: string[] | null, repeatable: boolean) => {
    const offered = step.choices?.[key] ?? choices;
    const arg = step.placeholders?.[key] ?? arg0;
    const v = values[key];
    if (offered) {
      return (
        <select value={typeof v === "string" ? v : ""} onChange={(e) => set({ ...values, [key]: e.target.value })}>
          <option value="">—</option>
          {offered.map((c) => (
            <option key={c} value={c}>{c}</option>
          ))}
        </select>
      );
    }
    if (repeatable) {
      return (
        <textarea rows={2} placeholder={`${arg ?? "value"} — one per line`} value={Array.isArray(v) ? v.join("\n") : ""} onChange={(e) => set({ ...values, [key]: e.target.value.split("\n") })} />
      );
    }
    return <input type="text" placeholder={arg ?? ""} value={typeof v === "string" ? v : ""} onChange={(e) => set({ ...values, [key]: e.target.value })} />;
  };
  const top = part !== "bottom";
  const bottom = part !== "top";
  return (
    <div className="form">
      {top && pos.map((p) => (
        <label key={p.name} className="form-row">
          <span>{label(`@${p.name}`, p.name)}{p.optional ? "" : " *"}</span>
          {field(`@${p.name}`, `<${p.name}>`, null, false)}
        </label>
      ))}
      {top && opts.map((o) =>
        o.takesValue ? (
          <label key={o.flag} className="form-row">
            <span className="mono">{label(o.flag, o.flag)}</span>
            {field(o.flag, o.arg, o.choices, o.repeatable)}
            {o.description ? <small className="muted">{o.description}</small> : null}
          </label>
        ) : (
          <label key={o.flag} className="form-check">
            <input type="checkbox" checked={values[o.flag] === true} onChange={(e) => set({ ...values, [o.flag]: e.target.checked })} />
            <span className="mono">{label(o.flag, o.flag)}</span> <small className="muted">{o.description}</small>
          </label>
        ),
      )}
      {/* A field form (fields.tsx) lists the fields themselves. */}
      {top && verb.open && !step.render ? (
        <label className="form-row">
          <span>more options</span>
          <textarea rows={3} placeholder={"one per line: --flag value\n(see the verb's --help)"} value={Array.isArray(values["@extra"]) ? values["@extra"].join("\n") : ""} onChange={(e) => set({ ...values, "@extra": e.target.value.split("\n") })} />
          {verb.details ? <small className="muted mono wrap">{verb.details}</small> : null}
        </label>
      ) : null}
      {bottom && verb.disruptions.length ? (
        <fieldset className="disruptions">
          <legend>Disruption — only if you mean it</legend>
          {verb.disruptions.map((d) => (
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

function JobView({ id, label }: { id: string; label: string }) {
  const job = useJob(id);
  if (!job) return <p className="muted">starting {label}…</p>;
  return (
    <div className="jobview">
      <p>
        <Tag level={job.state === "refused" ? "fail" : job.state !== "done" ? "skip" : job.exit === 0 ? "pass" : "warn"} /> {label}: {jobResult(job)}
        {job.durationMs !== null ? <span className="muted"> · {Math.round(job.durationMs / 100) / 10} s</span> : null}
        <span className="muted"> · job {job.id}</span>
      </p>
      {job.refused ? <p className="readstate readstate-fail">{job.refused}</p> : null}
      <Output text={job.output} live={job.state === "running" || job.state === "queued"} />
    </div>
  );
}

// One step of a flow; also embedded in a wizard of its own (Add node), which
// learns when the apply starts (onApplied) as well as when it ends (onDone).
export function StepView({ step, me, onDone, onApplied }: { step: Step; me: Me | null; onDone: (ok: boolean) => void; onApplied?: (jobId: string) => void }) {
  const verb = useVerb(step.bin, step.verb);
  const [values, setValues] = useState<Values>(step.initial ?? {});
  const argv = useMemo(() => buildArgv(step, verb, values), [step, verb, values]);
  const [preview, setPreview] = useState<{ id: string; argv: string } | null>(null);
  const [applied, setApplied] = useState<string | null>(null);
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const previewJob_ = useJob(preview?.id ?? null);
  const appliedJob = useJob(applied);
  const stale = preview !== null && preview.argv !== JSON.stringify(argv);

  useEffect(() => {
    if (appliedJob && appliedJob.state === "done") onDone(appliedJob.exit === 0);
  }, [appliedJob?.state, appliedJob?.exit]);

  // The assistant's values, once the manifest says which are positionals and options.
  const [prefilled, setPrefilled] = useState(false);
  useEffect(() => {
    if (!verb || !step.prefill || prefilled) return;
    const pre = prefillValues(step, verb, step.prefill, step.render !== undefined);
    setValues((v) => ({ ...v, ...pre }));
    setPrefilled(true);
  }, [verb]);

  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  const writeMark = writeMarkOf(verb, argv);
  const isRead = !writeMark && (verb.effect === "read" || verb.readWhen.some((w) => argv.includes(w)));
  const previewKind = previewKindOf(verb, argv);
  const destructive = !isRead && (verb.destructive || verb.destructiveWhen.some((w) => argv.includes(w)));
  const pj: Job | null = previewJob_;
  const previewDone = pj !== null && pj.state === "done" && !stale;
  const refusedByDryRun = previewDone && previewKind === "dry-run-flag" && pj!.exit !== 0;
  const object = pj?.object ?? "";
  const label = pj?.objectLabel ?? object;
  const confirmed = confirm !== "" && (confirm === object || confirm === label);
  const canApply = previewDone && !refusedByDryRun && !applied && (!destructive || (confirmed && me?.role === "installer"));
  const phase = applied ? 4 : previewDone ? 3 : preview ? 2 : 1;

  const doPreview = async () => {
    setError(null);
    setApplied(null);
    const r = isRead ? await readJob(argv) : await previewJob(argv);
    if (!r.data) return setError(r.error);
    if (r.error) setError(r.error);
    setPreview({ id: r.data.id, argv: JSON.stringify(argv) });
  };
  const doApply = async () => {
    if (!preview) return;
    setError(null);
    const r = await applyJob(preview.id, destructive ? confirm : undefined);
    if (!r.data || r.status >= 400) return setError(r.error ?? `HTTP ${r.status}`);
    setApplied(r.data.id);
    onApplied?.(r.data.id);
  };

  return (
    <div className="step">
      <h3>{step.title}</h3>
      {!isRead ? (
        <ol className="stepper">
          {["Change", "Preview", "Apply", "Result"].map((s, i) => (
            <li key={s} className={phase === i + 1 ? "on" : phase > i + 1 ? "past" : ""}>{i + 1} {s}</li>
          ))}
        </ol>
      ) : null}
      {step.note ? <div className="note">{step.note}</div> : null}
      {step.render ? (
        <>
          <VerbForm step={step} verb={verb} values={values} set={setValues} part="top" />
          <PrefillContext.Provider value={step.prefill ?? null}>{step.render(values, setValues)}</PrefillContext.Provider>
          <VerbForm step={step} verb={verb} values={values} set={setValues} part="bottom" />
        </>
      ) : (
        <VerbForm step={step} verb={verb} values={values} set={setValues} />
      )}
      <Command argv={isRead ? argv : applyForm(verb, argv)} label={isRead ? "runs" : "apply runs"} />
      {destructive ? <p className="readstate readstate-fail">Destructive: this cannot be undone from the console. It needs the Installer role{me ? ` (you are ${me.role})` : ""} and the object's name typed after the preview.</p> : null}
      <div className="actions">
        <button className="btn" disabled={applied !== null} onClick={() => void doPreview()}>
          {isRead ? "Run" : preview && !stale ? "Preview again" : previewKind === "none" ? "Preview (no dry run)" : "Preview"}
        </button>
        {!isRead ? (
          <button className={`btn ${destructive ? "btn-danger" : "btn-primary"}`} disabled={!canApply} onClick={() => void doApply()}>
            {destructive ? `${verb.verb} ${label || "…"}` : "Apply"}
          </button>
        ) : null}
        {stale ? <span className="muted small">the change differs from the preview: preview again</span> : null}
      </div>
      {error ? <p className="readstate readstate-fail">{error}</p> : null}
      {writeMark ? <p className="readstate readstate-warn">{writeMark.flag} makes this a change: it {writeMark.touches}. It is previewed and queued like any change, never beside the sweep.</p> : null}
      {preview && step.previewNote ? <div className="note preview-head">{step.previewNote(values)}</div> : null}
      {preview ? <JobView id={preview.id} label={isRead ? "result" : previewKind === "none" ? "preview (no dry run)" : "preview"} /> : null}
      {refusedByDryRun ? <p className="readstate readstate-warn">The dry run refuses this change (exit {pj!.exit}): nothing to apply.</p> : null}
      {destructive && previewDone && !applied ? (
        <label className="form-row confirm">
          <span>Type <b className="mono">{object}</b> to confirm{label !== object ? <> — <span className="mono">{label}</span></> : null}</span>
          <input type="text" autoComplete="off" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        </label>
      ) : null}
      {applied ? <JobView id={applied} label="apply" /> : null}
      {applied && appliedJob?.state === "done" ? (
        <>
          {step.after ? step.after(appliedJob) : null}
          <p className="muted small">Recorded in <Link to="/activity">Activity</Link> with the preview and this output.</p>
        </>
      ) : null}
      {isRead && pj?.state === "done" && step.after ? step.after(pj) : null}
    </div>
  );
}

export function Operate({ title, steps, onClose }: { title: string; steps: Step[]; onClose: () => void }) {
  const me = useRead<Me>("me", 300_000).env?.data ?? null;
  const [reached, setReached] = useState(0);
  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={title}>
        <header className="modal-head">
          <h2>{title}</h2>
          <button className="btn-x" onClick={onClose} aria-label="close">×</button>
        </header>
        {steps.slice(0, reached + 1).map((s, i) => (
          <StepView key={i} step={s} me={me} onDone={(ok) => ok && setReached((r) => Math.max(r, i + 1))} />
        ))}
        {reached < steps.length - 1 ? <p className="muted small">Next: {steps[reached + 1].title} — once this step has been applied.</p> : null}
      </div>
    </div>
  );
}

// A button that opens a flow. `opens` names the wizard it is for the
// assistant (open_console): its request opens the flow, the first step filled in.
export function OperateButton({ label, title, steps, kind, disabled, hint, opens }: { label: string; title?: string; steps: Step[] | (() => Step[]); kind?: "danger" | "primary"; disabled?: boolean; hint?: string; opens?: { wizard: string; arg?: string | null } }) {
  const [open, setOpen] = useState(false);
  const [prefill, setPrefill] = useState<Values | null>(null);
  const operator = canOperate(useMe());
  useOpenedBy(opens?.wizard ?? "", opens?.arg, (v) => {
    setPrefill(v);
    setOpen(true);
  }, opens !== undefined && operator);
  // Only an operator sees a control that runs a job.
  if (!operator) return null;
  const list = open ? (typeof steps === "function" ? steps() : steps) : [];
  const shown = prefill && list.length ? [{ ...list[0], prefill }, ...list.slice(1)] : list;
  return (
    <>
      <button className={`btn${kind ? ` btn-${kind}` : ""}`} disabled={disabled} title={hint} onClick={() => setOpen(true)}>
        {label}
      </button>
      {/* Closing it re-reads the page: a job may have changed what it shows (a Test job, a Setup step). */}
      {open ? <Operate title={title ?? label} steps={shown} onClose={() => { setOpen(false); setPrefill(null); reloadAll(); }} /> : null}
    </>
  );
}
