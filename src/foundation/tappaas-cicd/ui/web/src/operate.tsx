// operate.tsx — the one way the console changes the site (ADR-034 D4, spike
// §5.4): Change → Preview → Apply → Result. The form is built from the verb's
// manifest (its positionals and declared options), the command block is exactly
// what will run and can be copied, the preview is the manager's own dry run.
// Apply needs no preview click: it runs the dry run first in the same job and
// goes on only on a clean one (a refusal stops it there, its output shown as a
// preview's); after a preview of its own, Apply applies that. A disruption (--force, --allow-disruption,
// --yes) is a checkbox that names its consequence, and a destructive verb needs
// the object's name typed. A flow of several steps
// (update-port, then reconcile) runs them in order.

import { useMemo, useState } from "react";
import { reloadAll, useJob, useRead, useVerb } from "./api";
import { Values, buildArgv, confirmMatches, confirmObject } from "./argv";
import { useOpenedBy } from "./opener";
import { Command, JobControl, JobOutput, JobStatusLine, jobResult, phaseOutputs } from "./jobs";
import { Job, Me } from "./types";
import { Step, StepForm, applyForm, previewKindOf, useStepValues, writeMarkOf } from "./stepform";
import { Link, Tag, TypedConfirm, canOperate, useMe } from "./ui";
import { useJobRun } from "./run";
import { Wizard } from "./wizard";

export type { Step } from "./stepform";
export type { Values } from "./argv";
export { PrefillContext, StepForm, applyForm, previewKindOf, useStepValues, writeMarkOf } from "./stepform";

// Also a continued wizard's view of the job it found again (wizard.tsx useJobSession).
export function JobView({ id, label, collapsed }: { id: string; label: string; collapsed?: boolean }) {
  const job = useJob(id);
  if (!job) return <p className="muted">starting {label}…</p>;
  return <JobPart job={job} label={label} fold={collapsed} />;
}

function JobPart({ job, label, state, level, ms, text, live, fold, control }: { job: Job; label: string; state?: string; level?: string; ms?: number | null; text?: string; live?: boolean; fold?: boolean; control?: boolean }) {
  return (
    <div className="jobview">
      <JobStatusLine job={job} label={label} state={state} level={level} ms={ms} control={control} />
      {job.refused ? <p className="readstate readstate-fail">{job.refused}</p> : null}
      <JobOutput job={job} text={text} live={live} fold={fold ? "tail" : "open"} />
    </div>
  );
}

// An Apply that ran its own dry run first: the dry run shown as a preview is,
// then (when it was clean) the apply.
function TwoPhaseView({ job }: { job: Job }) {
  const pp = job.previewPhase!;
  const out = phaseOutputs(job);
  const inPreview = pp.exit === null;
  const pState = job.state === "queued" ? "queued" : job.state === "refused" ? "refused" : inPreview ? "running…" : pp.exit === 0 && !pp.stopped ? "ok" : pp.stopped && pp.exit === 0 ? "refused" : `exit ${pp.exit}`;
  const pLevel = job.state === "refused" ? "fail" : inPreview ? "skip" : pp.stopped ? "warn" : "pass";
  return (
    <>
      <JobPart job={job} label="preview" state={pState} level={pLevel} ms={pp.durationMs} text={out.preview ?? ""} live={inPreview && job.state !== "refused" && job.state !== "done"} fold={!inPreview && !pp.stopped} control={inPreview} />
      {pp.stopped ? <p className="readstate readstate-warn">{pp.stopped[0].toUpperCase() + pp.stopped.slice(1)}.</p> : null}
      {!inPreview && !pp.stopped ? (
        <JobPart job={{ ...job, refused: null }} label="apply" ms={job.durationMs !== null && pp.durationMs !== null ? job.durationMs - pp.durationMs : null} text={out.apply} live={job.state === "running"} />
      ) : null}
    </>
  );
}

// One step of a flow; also embedded in a wizard of its own (Add node), which
// learns when the apply starts (onApplied) as well as when it ends (onDone).
// The bar: what the output says so far; full once the job is done.
function ProgressBar({ at, done }: { at: { pct: number; text: string } | null; done: boolean }) {
  const pct = done ? 100 : at ? Math.max(0, Math.min(100, at.pct)) : 0;
  return (
    <div className="progress" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
      <div className="progress-bar" style={{ width: `${pct}%` }} />
      <span className="progress-text">{done ? "done" : at ? at.text : "starting…"}</span>
    </div>
  );
}

export function StepView({ step, me, onDone, onApplied }: { step: Step; me: Me | null; onDone: (ok: boolean) => void; onApplied?: (jobId: string) => void }) {
  const verb = useVerb(step.bin, step.verb);
  const [values, setValues] = useStepValues(step, verb);
  const argv = useMemo(() => buildArgv(step, verb, values), [step, verb, values]);
  const [previewOf, setPreviewOf] = useState<string | null>(null); // the argv the preview ran
  const [confirm, setConfirm] = useState("");
  const previewRun = useJobRun();
  const applyRun = useJobRun({ onApplied, onDone: (ok) => onDone(ok) });
  const preview = previewRun.id ? { id: previewRun.id, argv: previewOf } : null;
  const applied = applyRun.id;
  const appliedJob = applyRun.job;
  const error = applyRun.error ?? previewRun.error;
  const previewJob_ = previewRun.job;
  const stale = preview !== null && preview.argv !== JSON.stringify(argv);
  // An Apply whose own dry run refused the change: nothing was applied, the
  // form is open again as after a refusing preview.
  const stopped = !!appliedJob?.previewPhase?.stopped;
  const inApply = applyRun.inApply;

  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  const writeMark = writeMarkOf(verb, argv);
  const isRead = !writeMark && (verb.effect === "read" || verb.readWhen.some((w) => argv.includes(w)));
  const previewKind = previewKindOf(verb, argv);
  const destructive = !isRead && (verb.destructive || verb.destructiveWhen.some((w) => argv.includes(w)));
  const pj: Job | null = previewJob_;
  const previewDone = pj !== null && pj.state === "done" && !stale;
  const previewRunning = pj !== null && !stale && (pj.state === "running" || pj.state === "queued");
  const refusedByDryRun = previewDone && previewKind === "dry-run-flag" && pj!.exit !== 0;
  const named = confirmObject(step, verb, values, argv);
  const object = named.object;
  const label = named.label;
  const confirmed = confirmMatches(confirm, object, label);
  const busy = applied !== null && !stopped; // an Apply runs or ran: the form is done
  const canApply = !step.blocked && !busy && !previewRunning && !refusedByDryRun && (!destructive || (confirmed && canOperate(me)));
  const phase = busy ? (inApply ? (appliedJob?.state === "done" ? 4 : 3) : 2) : stopped ? 2 : previewDone ? 3 : preview ? 2 : 1;

  const doPreview = async () => {
    applyRun.retry();
    setPreviewOf(JSON.stringify(argv));
    await (isRead ? previewRun.read(argv) : previewRun.preview(argv));
  };
  // After a clean preview of this very change, Apply applies that preview;
  // otherwise it is one job that runs the dry run first.
  const doApply = async () => {
    const fresh = previewDone && pj !== null && pj.kind === "preview";
    if (!fresh) previewRun.retry();
    await (fresh ? applyRun.applyPreview(preview!.id, destructive ? confirm : undefined) : applyRun.apply(argv, destructive ? confirm : undefined));
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
      <StepForm step={step} verb={verb} values={values} set={setValues} />
      <Command argv={isRead ? argv : applyForm(verb, argv)} label={isRead ? "runs" : "apply runs"} />
      {destructive ? <p className="readstate readstate-fail">Destructive: this cannot be undone from the console. It needs the object's name typed before Apply.</p> : null}
      {destructive && !busy ? (
        <TypedConfirm object={object} label={label} value={confirm} set={setConfirm} />
      ) : null}
      <div className="actions">
        <button className="btn" disabled={busy || !!step.blocked} onClick={() => void doPreview()}>
          {isRead ? "Run" : preview && !stale ? "Preview again" : previewKind === "none" ? "Preview (no dry run)" : "Preview"}
        </button>
        {!isRead ? (
          <button className={`btn ${destructive ? "btn-danger" : "btn-primary"}`} disabled={!canApply} onClick={() => void doApply()}>
            {destructive ? `${verb.verb} ${label || "…"}` : "Apply"}
          </button>
        ) : null}
        {step.blocked ? <span className="muted small">{step.blocked}</span> : null}
        {stale ? <span className="muted small">the change differs from the preview: Apply previews it again</span> : null}
      </div>
      {error ? <p className="readstate readstate-fail">{error}</p> : null}
      {writeMark ? <p className="readstate readstate-warn">{writeMark.flag} makes this a change: it {writeMark.touches}. It is previewed and queued like any change, never beside the sweep.</p> : null}
      {preview && step.previewNote ? <div className="note preview-head">{step.previewNote(values)}</div> : null}
      {preview ? <JobView id={preview.id} label={isRead ? "result" : previewKind === "none" ? "preview (no dry run)" : "preview"} collapsed={applied !== null} /> : null}
      {refusedByDryRun ? <p className="readstate readstate-warn">The dry run refuses this change (exit {pj!.exit}): nothing to apply.</p> : null}
      {step.progress && appliedJob && inApply ? <ProgressBar at={step.progress(appliedJob.output)} done={appliedJob.state === "done"} /> : null}
      {step.jobShownIn && appliedJob && appliedJob.state !== "refused" && !stopped ? (
        <p className="small">
          <Tag level={appliedJob.state !== "done" ? "skip" : appliedJob.exit === 0 ? "pass" : "warn"} /> apply: {jobResult(appliedJob)} <span className="muted">· job {appliedJob.id}</span> — its output is in {step.jobShownIn} <JobControl job={appliedJob} />
        </p>
      ) : appliedJob?.previewPhase ? <TwoPhaseView job={appliedJob} /> : applied ? <JobView id={applied} label="apply" /> : null}
      {applied && appliedJob?.state === "done" && !stopped ? (
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
  // A flow of several steps, part applied: closing leaves the rest undone, and
  // reopening starts at its first step (a flow keeps no session of its own).
  const left = reached > 0 && reached < steps.length ? `${steps[reached].title} is not applied yet; reopening starts again at the first step.` : null;
  return (
    <Wizard title={title} wide={false} onClose={onClose} progress={left}>
      {steps.slice(0, reached + 1).map((s, i) => (
        <StepView key={i} step={s} me={me} onDone={(ok) => ok && setReached((r) => Math.max(r, i + 1))} />
      ))}
      {reached < steps.length - 1 ? <p className="muted small">Next: {steps[reached + 1].title} — once this step has been applied.</p> : null}
    </Wizard>
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
