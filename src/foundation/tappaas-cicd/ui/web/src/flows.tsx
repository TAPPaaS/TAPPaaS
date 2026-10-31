// flows.tsx — how a step runs, one for each kind of verb (argv.ts stepFlow).
// ActStep: the form, one button, the job's status line and its output in
// place, Try again on a failure. CheckStep: the dry run as the step opens, what
// it found, then one button. PlanFlow: the preview as the step opens, to read,
// and one Apply under it. ReadFlow: one Run, or the read at once.

import { ReactNode, useEffect, useRef, useState } from "react";
import { confirmMatches, confirmObject, isDestructiveCall } from "./argv";
import { Command, JobOutput, JobStatusLine } from "./jobs";
import { useJobRun } from "./run";
import { Step, StepForm, StepFormState, applyForm, useStepForm } from "./stepform";
import { Job, Me } from "./types";
import { Finding } from "./noderemove";
import { FindingList, Link, Tag, TypedConfirm, canOperate, useMe } from "./ui";
import { previewRefuses, refusalLines, runFailure } from "./wizards";

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

// The typed name of a destructive call, and what it says of it.
function useConfirm(form: StepFormState) {
  const { step, verb, values, argv } = form;
  const [typed, set] = useState("");
  const named = verb ? confirmObject(step, verb, values, argv) : { object: "", label: "" };
  const destructive = !!verb && isDestructiveCall(verb, argv);
  return {
    destructive,
    typed,
    label: named.label,
    confirmed: !destructive || confirmMatches(typed, named.object, named.label),
    hint: destructive && !confirmMatches(typed, named.object, named.label) ? `type ${named.object} to enable the button` : null,
    field: destructive ? (
      <>
        <p className="readstate readstate-fail">Destructive: this cannot be undone from the console. It needs the object's name typed first.</p>
        <TypedConfirm object={named.object} label={named.label} value={typed} set={set} />
      </>
    ) : null,
  };
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
  titled?: boolean; // the step's title over it, where a stage holds more than one
}

export function ActFlow({ form, me, onDone, onApplied, line, command = true }: ActProps & { form: StepFormState; me: Me | null }) {
  const { step, verb, values, argv } = form;
  const run = useJobRun({ onApplied, onDone: (ok) => onDone?.(ok) });
  const confirm = useConfirm(form);
  const { job } = run;
  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  if (run.id) {
    if (!job) return <p className="muted"><Tag level="skip" /> Starting…</p>;
    if (line && run.inApply) return <>{line(job)}</>;
    if (run.finished && !run.ok) {
      const found = refusalLines(job.output).map((text) => ({ text }));
      return (
        <>
          <p className="readstate readstate-fail">{step.failed ?? (run.inApply ? "It did not finish" : "Nothing was applied")}: {runFailure(job)}.</p>
          {job.previewPhase?.stopped ? <FindingList items={found} /> : null}
          <JobOutput job={job} fold="tail" tail={8} />
          <div className="actions">
            <button className="btn btn-primary" onClick={run.retry}>Try again</button>
            <span className="muted small">back to the form, as filled in</span>
          </div>
        </>
      );
    }
    return (
      <>
        <JobStatusLine job={job} label={step.title} />
        {step.progress && run.inApply ? <ProgressBar at={step.progress(job.output)} done={run.ok} /> : null}
        <JobOutput job={job} fold="tail" />
        {run.ok ? <Applied step={step} job={job} /> : null}
      </>
    );
  }
  const hint = !canOperate(me) ? "only an operator can do this" : form.waits ?? confirm.hint;
  const starting = run.state === "starting";
  return (
    <>
      <Fields form={form} />
      {command ? <Command argv={applyForm(verb, argv)} label="runs" /> : null}
      {step.previewNote ? <div className="note preview-head">{step.previewNote(values)}</div> : null}
      {confirm.field}
      {run.error ? <p className="readstate readstate-fail">{step.failed ?? "It was not started"}: {run.error}</p> : null}
      <div className="actions">
        <button className={`btn ${confirm.destructive ? "btn-danger" : "btn-primary"}`} disabled={!!hint || starting} onClick={() => void run.apply(argv, confirm.destructive ? confirm.typed : undefined)}>{starting ? "Starting…" : step.button ?? (confirm.destructive ? `${verb.verb} ${confirm.label || "…"}` : "Apply")}</button>
        {hint ? <span className="muted small">{hint}</span> : null}
      </div>
    </>
  );
}

// A form and one button, in a wizard's stage. Failing, it goes back to the
// form as filled in; the form is the verb's, or the step's own (step.render).
export function ActStep({ step, titled, ...props }: ActProps & { step: Step }) {
  const me = useMe();
  const form = useStepForm(step);
  return (
    <div className="step">
      {titled ? <h3>{step.title}</h3> : null}
      <ActFlow form={form} me={me} {...props} />
    </div>
  );
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
  blocked?: string | null; // why neither can run yet
  form?: ReactNode; // above the check, until the change runs
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

export function CheckStep<R extends CheckResult = CheckResult>({ argv, applyArgv, auto = true, blocked, form, parse, title, applying, okLine, blockedLine, lossesLine, choices, confirm, typed, confirmed = true, button, danger, hint, me, attach = null, onStarted, onDone, result, failed, summary, checkSummary = "What the check printed" }: CheckProps<R>) {
  const check = useJobRun();
  const run = useJobRun({ attach, onDone });
  const [round, setRound] = useState(0);
  const [checked, setChecked] = useState<string | null>(null);
  const stale = checked !== null && checked !== JSON.stringify(argv); // Check again before the button
  const operator = canOperate(me);
  const asked = useRef(-1);
  const wanted = (auto || round > 0) && operator && !blocked && !attach && !run.id;
  useEffect(() => {
    if (!wanted || asked.current === round) return;
    asked.current = round;
    check.retry();
    setChecked(JSON.stringify(argv));
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
      <div>
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
    <div>
      {form}
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

// A destructive call with a dry run: CheckStep over the step's form.
export function CheckFlow({ form, me, onDone, onApplied }: Pick<ActProps, "onDone" | "onApplied"> & { form: StepFormState; me: Me | null }) {
  const { step, verb, argv } = form;
  const confirm = useConfirm(form);
  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  return (
    <CheckStep
      argv={argv}
      auto={form.fresh && !form.waits}
      blocked={form.waits}
      form={<><Fields form={form} /><Command argv={applyForm(verb, argv)} label="runs" /></>}
      title={`Checking ${step.title}`}
      applying={step.title}
      confirm={confirm.field}
      typed={confirm.typed}
      confirmed={confirm.confirmed}
      button={step.button ?? `${verb.verb} ${confirm.label || "…"}`}
      danger
      hint={confirm.hint}
      me={me}
      onStarted={(id) => id && onApplied?.(id)}
      onDone={(ok) => onDone?.(ok)}
      result={(j) => <><JobStatusLine job={j} label={step.title} /><Applied step={step} job={j} /></>}
      failed={(j) => `${step.failed ?? "It did not go through"}: ${runFailure(j)}.`}
    />
  );
}

// A plan to read: its preview runs as the step opens (a form still to fill in
// first: on the button), Apply applies that preview. The form changed, it is
// previewed again before anything can apply.
export function PlanFlow({ form, me, onDone, onApplied }: Pick<ActProps, "onDone" | "onApplied"> & { form: StepFormState; me: Me | null }) {
  const { step, verb, values, argv } = form;
  const preview = useJobRun();
  const apply = useJobRun({ onApplied, onDone: (ok) => onDone?.(ok) });
  const confirm = useConfirm(form);
  const [ranFor, setRanFor] = useState<string | null>(null);
  const operator = canOperate(me);
  const asked = useRef(false);
  const doPreview = () => {
    apply.retry();
    setRanFor(JSON.stringify(argv));
    void preview.preview(argv);
  };
  const auto = !!verb && operator && form.fresh && !form.waits && step.previewOnOpen !== false;
  useEffect(() => {
    if (!auto || asked.current) return;
    asked.current = true;
    doPreview();
  }, [auto]);
  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;

  const pj = preview.job;
  const previewed = pj !== null && preview.finished && ranFor === JSON.stringify(argv);
  const refused = previewed && pj!.state === "done" && previewRefuses(pj!);
  const applying = apply.id !== null && !(apply.finished && !apply.ok);
  const canApply = previewed && pj!.state === "done" && !refused;
  const hint = !operator ? "only an operator can do this" : form.waits ?? (preview.live ? null : canApply ? confirm.hint : null);
  const starting = apply.state === "starting";
  return (
    <>
      {!applying ? <Fields form={form} /> : null}
      <Command argv={applyForm(verb, argv)} label="apply runs" />
      {step.previewNote && preview.id ? <div className="note preview-head">{step.previewNote(values)}</div> : null}
      {preview.error ? <p className="readstate readstate-fail">The preview was not started: {preview.error}</p> : null}
      {pj ? (
        <div className="jobview">
          <JobStatusLine job={pj} label="preview" />
          {pj.refused ? <p className="readstate readstate-fail">{pj.refused}</p> : null}
          <JobOutput job={pj} live={preview.live} fold={apply.id ? "tail" : "open"} />
        </div>
      ) : preview.id ? <p className="muted">starting the preview…</p> : null}
      {refused ? <p className="readstate readstate-warn">The dry run refuses this change (exit {pj!.exit}): nothing to apply.</p> : null}
      {!applying ? (
        <>
          {canApply ? confirm.field : null}
          {apply.error ? <p className="readstate readstate-fail">It was not applied: {apply.error}</p> : null}
          <div className="actions">
            {canApply ? (
              <>
                <button className={`btn ${confirm.destructive ? "btn-danger" : "btn-primary"}`} disabled={!!hint || starting} onClick={() => void apply.applyPreview(pj!.id, confirm.destructive ? confirm.typed : undefined)}>{starting ? "Starting…" : step.button ?? (confirm.destructive ? `${verb.verb} ${confirm.label || "…"}` : "Apply")}</button>
                <button className="btn btn-small" onClick={doPreview}>Preview again</button>
              </>
            ) : (
              <button className="btn btn-primary" disabled={!!hint || preview.live} onClick={doPreview}>{preview.live ? "Previewing…" : preview.id ? "Preview again" : "Preview"}</button>
            )}
            {hint ? <span className="muted small">{hint}</span> : null}
            {preview.id && !previewed && !preview.live ? <span className="muted small">the form differs from the preview</span> : null}
          </div>
        </>
      ) : null}
      {apply.job ? (
        <div className="jobview">
          <JobStatusLine job={apply.job} label="apply" />
          {apply.finished && !apply.ok ? <p className="readstate readstate-fail">{step.failed ?? "It did not finish"}: {runFailure(apply.job)}.</p> : null}
          <JobOutput job={apply.job} fold={apply.finished && !apply.ok ? "tail" : "open"} tail={8} />
          {apply.ok ? <Applied step={step} job={apply.job} /> : null}
        </div>
      ) : null}
    </>
  );
}

// A read: one Run, or at once for one that is its stage's result. Changes
// nothing, so it runs beside everything else, and again when asked.
export function ReadFlow({ form, me }: { form: StepFormState; me: Me | null }) {
  const { step, verb, argv } = form;
  const run = useJobRun();
  const operator = canOperate(me);
  const asked = useRef(false);
  const auto = !!verb && operator && form.fresh && !form.waits && !!step.runOnOpen;
  useEffect(() => {
    if (!auto || asked.current) return;
    asked.current = true;
    void run.read(argv);
  }, [auto]);
  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  const hint = !operator ? "only an operator can do this" : form.waits;
  return (
    <>
      <Fields form={form} />
      <Command argv={argv} label="runs" />
      <div className="actions">
        <button className="btn" disabled={!!hint || run.live} onClick={() => void run.read(argv)}>{run.id ? "Run again" : "Run"}</button>
        {hint ? <span className="muted small">{hint}</span> : null}
      </div>
      {run.error ? <p className="readstate readstate-fail">{run.error}</p> : null}
      {run.job ? (
        <div className="jobview">
          <JobStatusLine job={run.job} label="result" />
          {run.job.refused ? <p className="readstate readstate-fail">{run.job.refused}</p> : null}
          <JobOutput job={run.job} />
        </div>
      ) : run.id ? <p className="muted">starting…</p> : null}
      {run.job?.state === "done" && step.after ? step.after(run.job) : null}
    </>
  );
}
