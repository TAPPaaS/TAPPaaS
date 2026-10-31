// flows.tsx — how a step runs. ActStep: the form, one button, the job's status
// line and its output in place, Try again on a failure.

import { ReactNode } from "react";
import { Command, JobOutput, JobStatusLine } from "./jobs";
import { useJobRun } from "./run";
import { Step, StepForm, StepFormState, applyForm, useStepForm } from "./stepform";
import { Job, Me } from "./types";
import { Link, Tag, canOperate, useMe } from "./ui";
import { runFailure } from "./wizards";

// What is said above the button: the step's note, then its form.
function Fields({ form }: { form: StepFormState }) {
  const { step, verb, values, set } = form;
  return (
    <>
      {step.note ? <div className="note">{step.note}</div> : null}
      {verb ? <StepForm step={step} verb={verb} values={values} set={set} /> : null}
    </>
  );
}

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

// Once the change ended clean: what it left (a file, a link), and where it is kept.
function Applied({ step, job }: { step: Step; job: Job }) {
  return (
    <>
      {step.after ? step.after(job) : null}
      <p className="muted small">Recorded in <Link to="/activity">Activity</Link> with this output.</p>
    </>
  );
}

export interface ActProps {
  onDone?: (ok: boolean) => void;
  onApplied?: (jobId: string) => void; // the change has started (past its dry run)
  // Its job is followed elsewhere (a wizard's later stage): once the change
  // applies, this one line stands for it here, in place of the status and output.
  line?: (job: Job) => ReactNode;
  command?: boolean; // the command is shown under the form (the default)
}

function ActFlow({ form, me, onDone, onApplied, line, command = true }: ActProps & { form: StepFormState; me: Me | null }) {
  const { step, verb, argv } = form;
  const run = useJobRun({ onApplied, onDone: (ok) => onDone?.(ok) });
  const { job } = run;
  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  if (run.id) {
    if (!job) return <p className="muted"><Tag level="skip" /> Starting…</p>;
    if (line && run.inApply) return <div className="step">{line(job)}</div>;
    if (run.finished && !run.ok) {
      return (
        <div className="step">
          <p className="readstate readstate-fail">{step.failed ?? (run.inApply ? "It did not finish" : "Nothing was applied")}: {runFailure(job)}.</p>
          <JobOutput job={job} fold="tail" tail={8} />
          <div className="actions">
            <button className="btn btn-primary" onClick={run.retry}>Try again</button>
            <span className="muted small">back to the form, as filled in</span>
          </div>
        </div>
      );
    }
    return (
      <div className="step">
        <JobStatusLine job={job} label={step.title} />
        {step.progress && run.inApply ? <ProgressBar at={step.progress(job.output)} done={run.ok} /> : null}
        <JobOutput job={job} fold="tail" />
        {run.ok ? <Applied step={step} job={job} /> : null}
      </div>
    );
  }
  const hint = !canOperate(me) ? "only an operator can do this" : step.blocked ?? null;
  return (
    <div className="step">
      <Fields form={form} />
      {command ? <Command argv={applyForm(verb, argv)} label="runs" /> : null}
      {run.error ? <p className="readstate readstate-fail">{step.failed ?? "It was not started"}: {run.error}</p> : null}
      <div className="actions">
        <button className="btn btn-primary" disabled={!!hint || run.state === "starting"} onClick={() => void run.apply(argv)}>{run.state === "starting" ? "Starting…" : step.button ?? "Apply"}</button>
        {hint ? <span className="muted small">{hint}</span> : null}
      </div>
    </div>
  );
}

// A form and one button, in a wizard's stage. Failing, it goes back to the
// form as filled in; the form is the verb's, or the step's own (step.render).
export function ActStep({ step, ...props }: ActProps & { step: Step }) {
  const me = useMe();
  const form = useStepForm(step);
  return <ActFlow form={form} me={me} {...props} />;
}
