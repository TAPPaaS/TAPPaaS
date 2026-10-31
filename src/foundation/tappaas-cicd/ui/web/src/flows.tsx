// flows.tsx — how a step runs. ActStep: the form, one button, the job's status
// line and its output in place, Try again on a failure. CheckStep: the dry run
// as the step opens, what it found, then one button.

import { ReactNode, useEffect, useRef, useState } from "react";
import { Command, JobOutput, JobStatusLine } from "./jobs";
import { useJobRun } from "./run";
import { Step, StepForm, StepFormState, applyForm, useStepForm } from "./stepform";
import { Job, Me } from "./types";
import { Finding } from "./noderemove";
import { FindingList, Link, Tag, canOperate, useMe } from "./ui";
import { refusalLines, runFailure } from "./wizards";

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

// What a check found. `state`: running, ok (the change can go on), blocked (it
// says what stops it) or failed (it did not finish); `losses`: what the change
// takes with it, however it stands.
export interface CheckResult {
  state: "running" | "ok" | "blocked" | "failed";
  blockers: Finding[];
  losses: Finding[];
}

// Exit 0 and no refusal: ok; else what it refused, in its own words.
export function defaultCheck(job: Job): CheckResult {
  const found = refusalLines(job.output).map((text): Finding => ({ text }));
  if (job.state === "refused") return { state: "failed", blockers: [], losses: [] };
  if (job.state !== "done") return { state: "running", blockers: [], losses: [] };
  if (job.exit === 0 && !found.length) return { state: "ok", blockers: [], losses: [] };
  return { state: found.length ? "blocked" : "failed", blockers: found, losses: [] };
}

export interface CheckProps<R extends CheckResult> {
  argv: string[]; // the dry run: what is checked
  applyArgv?: string[]; // what the button runs (default: the same argv); a job that runs its own dry run first
  // Run the check as the step opens; false: the form still lacks something, or
  // an operator should fill it in first (a Check button then).
  auto?: boolean;
  stale?: boolean; // the form differs from what was checked: Check again before the button
  blocked?: string | null; // why neither can run yet
  parse?: (job: Job) => R;
  title: string; // the running line's words ("Checking whether tappaas3 can be removed")
  applying: string; // the status line while the change runs
  okLine?: (r: R) => ReactNode;
  blockedLine?: ReactNode;
  lossesLine?: ReactNode;
  choices?: (r: R) => ReactNode; // a choice between the check and the button
  confirm?: ReactNode; // the typed-name field
  typed?: string; // what was typed in it
  confirmed?: boolean; // and it matches
  button: string;
  danger?: boolean;
  hint?: string | null; // why the button waits, past the check
  me: Me | null;
  attach?: string | null; // the change's job found again: no check, its result
  onStarted?: (id: string | null) => void; // the change's job, and when Check again drops it
  onDone?: (ok: boolean, job: Job) => void;
  result?: (job: Job) => ReactNode; // what the change left, once it ended clean
  failed: (job: Job) => string; // what is said when it did not
  summary?: string; // over the finished output
  checkSummary?: string;
}

export function CheckStep<R extends CheckResult = CheckResult>({ argv, applyArgv, auto = true, stale, blocked, parse, title, applying, okLine, blockedLine, lossesLine, choices, confirm, typed, confirmed = true, button, danger, hint, me, attach = null, onStarted, onDone, result, failed, summary, checkSummary = "What the check printed" }: CheckProps<R>) {
  const check = useJobRun();
  const run = useJobRun({ attach, onDone });
  const [round, setRound] = useState(0);
  const operator = canOperate(me);
  const asked = useRef(-1);
  const wanted = (auto || round > 0) && operator && !blocked && !attach && !run.id;
  useEffect(() => {
    if (!wanted || asked.current === round) return;
    asked.current = round;
    check.retry();
    void check.preview(argv);
  }, [wanted, round]);
  useEffect(() => {
    if (attach && attach !== run.id) run.attach(attach);
  }, [attach]);
  useEffect(() => {
    if (run.id) onStarted?.(run.id);
  }, [run.id]);

  const job = run.job;
  if (run.id) {
    if (!job) return <p className="muted"><Tag level="skip" /> Starting…</p>;
    return (
      <div className="step">
        {!run.finished ? (
          <JobStatusLine job={job} label={applying} />
        ) : run.ok ? (
          result?.(job)
        ) : (
          <>
            <p className="readstate readstate-fail">{failed(job)}</p>
            <JobOutput job={job} fold="tail" tail={8} />
            <div className="actions">
              <button className="btn btn-primary" onClick={() => { run.retry(); onStarted?.(null); setRound((n) => n + 1); }}>Check again</button>
            </div>
          </>
        )}
        {!run.finished || run.ok ? <JobOutput job={job} fold="closed" summary={summary} /> : null}
      </div>
    );
  }

  const checkJob = check.job;
  const outcome: R | null = checkJob ? (parse ? parse(checkJob) : (defaultCheck(checkJob) as R)) : null;
  const again = <button className="btn" disabled={!!blocked || !operator} onClick={() => setRound((n) => n + 1)}>{outcome ? "Check again" : "Check"}</button>;
  const can = outcome?.state === "ok" && !stale;
  return (
    <div className="step">
      {check.error ? <p className="readstate readstate-fail">The check was not started: {check.error}</p> : null}
      {!check.id && !check.error && !wanted ? (
        <div className="actions">{again}{blocked ? <span className="muted small">{blocked}</span> : null}</div>
      ) : !outcome || outcome.state === "running" ? (
        <JobLine job={checkJob} label={title} />
      ) : outcome.state === "ok" ? (
        <p><Tag level="pass" /> {okLine ? okLine(outcome) : "The check found nothing against this change."}</p>
      ) : outcome.state === "blocked" ? (
        <>
          <p><Tag level="fail" /> {blockedLine ?? "This cannot go through yet:"}</p>
          <FindingList items={outcome.blockers} />
        </>
      ) : (
        <p className="readstate readstate-fail">The check did not finish{checkJob?.refused ? `: ${checkJob.refused}` : "."}</p>
      )}
      {outcome && outcome.losses.length ? (
        <>
          {lossesLine ?? null}
          <FindingList items={outcome.losses} />
        </>
      ) : null}
      {outcome && outcome.state !== "running" && (outcome.state !== "ok" || stale) ? (
        <div className="actions">
          {again}
          {stale ? <span className="muted small">the form differs from what was checked</span> : null}
        </div>
      ) : null}
      {checkJob ? <JobOutput job={checkJob} fold={outcome?.state === "failed" ? "tail" : "closed"} tail={8} summary={checkSummary} /> : null}
      {can ? (
        <div className="form">
          {choices ? choices(outcome!) : null}
          {confirm}
          {run.error ? <p className="readstate readstate-fail">It was not started: {run.error}</p> : null}
          <div className="actions">
            <button className={`btn ${danger ? "btn-danger" : "btn-primary"}`} disabled={!operator || !confirmed || !!hint || run.state === "starting"} onClick={() => void run.apply(applyArgv ?? argv, typed)}>{run.state === "starting" ? "Starting…" : button}</button>
            {!operator ? <span className="muted small">only an operator can do this</span> : hint ? <span className="muted small">{hint}</span> : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}

// The running check: its status line with Stop, once the job exists.
function JobLine({ job, label }: { job: Job | null; label: string }) {
  return job ? <JobStatusLine job={job} label={label} /> : <p className="muted">{label}…</p>;
}
