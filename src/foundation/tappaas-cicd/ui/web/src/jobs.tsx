// jobs.tsx — how a job looks wherever it is shown: its command line (exactly
// what ran, copyable), who ran it from where, its state, and its output.
// Activity lists them beside the sweep; a module's page lists its own.

import { Fragment, ReactNode, useLayoutEffect, useRef, useState } from "react";
import { cancelJob, reloadAll, useJob, useRead } from "./api";
import { Job, JobSummary } from "./types";
import { Tag, canOperate, useMe, when } from "./ui";
import { jobLive } from "./wizard";
import { lastLines, queuedBehind } from "./wizards";

export function quote(argv: string[]): string {
  return argv.map((a) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)).join(" ");
}

export function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "");
}

export function jobLevel(j: JobSummary): string {
  if (j.state === "refused" || j.interrupted) return "fail";
  if (j.state !== "done") return "skip";
  if (j.previewPhase?.stopped || j.cancelled) return "warn";
  return j.exit === 0 ? "pass" : "fail";
}

export function jobResult(j: JobSummary): string {
  if (j.state === "refused") return "refused";
  if (j.interrupted) return "cut off";
  if (j.cancelled?.was === "queued") return j.state === "done" ? "cancelled" : "cancelling…";
  if (j.cancelled) return j.state === "done" ? `stopped${j.exit !== null ? ` (exit ${j.exit})` : ""}` : `stopping… (${j.cancelled.signals.at(-1) ?? "SIGINT"} sent)`;
  if (j.state === "queued") return "queued";
  if (j.state === "running") return j.previewPhase && j.previewPhase.exit === null ? "previewing…" : "running…";
  if (j.previewPhase?.stopped) return "stopped at the preview";
  return j.exit === 0 ? "ok" : `exit ${j.exit}`;
}

export function duration(ms: number | null): string {
  if (ms === null) return "";
  if (ms < 1000) return `${ms} ms`;
  const s = Math.round(ms / 1000);
  return s < 120 ? `${s} s` : `${Math.round(s / 60)} min`;
}

// A command on a line of its own, with Copy. `line` is shell text as written (a
// pipe, a $(…)), for a command the operator runs themselves; argv is quoted.
export function Command({ argv, line, label }: { argv?: string[]; line?: string; label?: string }) {
  const text = line ?? quote(argv ?? []);
  const [copied, setCopied] = useState(false);
  const copy = () => {
    void navigator.clipboard?.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };
  return (
    <div className="command">
      {label ? <span className="command-label">{label}</span> : null}
      <code className="mono">$ {text}</code>
      <button className="btn btn-small" onClick={copy} title="Copy the command">
        {copied ? "copied" : "Copy"}
      </button>
    </div>
  );
}

// A job's output in its phases: an apply that ran its own dry run first holds
// the dry run's output, then the apply's.
export function phaseOutputs(j: { output: string; previewPhase?: JobSummary["previewPhase"] }): { preview: string | null; apply: string } {
  const pp = j.previewPhase;
  if (!pp) return { preview: null, apply: j.output };
  if (pp.exit === null) return { preview: j.output, apply: "" }; // still in the dry run
  return { preview: j.output.slice(0, pp.outputLength), apply: j.output.slice(pp.outputLength) };
}

// The last line stays in view while output arrives, unless the operator has
// scrolled up to read (then the pane stays where they put it until they
// scroll back down). `collapsed`: output that is over (a preview once the
// apply runs) folds to its last `tail` lines, with the rest a click away.
const FOLD_LINES = 4;
export function Output({ text, live, collapsed, tail = FOLD_LINES }: { text: string; live?: boolean; collapsed?: boolean; tail?: number }) {
  const ref = useRef<HTMLPreElement>(null);
  const stick = useRef(true);
  // Only the operator's own scrolling (wheel, touch, keys) may unstick the
  // view: the browser fires a scroll event for the jump below too, and with
  // lines streaming in that event can land after the next lines and before the
  // next jump, which read as "scrolled up" and froze the pane.
  const byHand = useRef(0);
  const [open, setOpen] = useState(false);
  const shown = stripAnsi(text) || (live ? "…" : "(no output)");
  const lines = shown.split("\n");
  const kept = lastLines(shown, tail);
  const foldable = !!collapsed && lines.length > kept.length;
  const fold = foldable && !open;
  useLayoutEffect(() => {
    const el = ref.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [shown, live, fold]);
  const hand = () => {
    byHand.current = Date.now();
  };
  const onScroll = () => {
    const el = ref.current;
    if (!el || Date.now() - byHand.current > 1000) return;
    stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
  };
  return (
    <div className="output-box">
      {foldable ? (
        <button className="btn btn-small output-fold" onClick={() => setOpen(!open)}>{fold ? `▸ ${lines.length - kept.length} earlier lines` : "▾ fold"}</button>
      ) : null}
      <pre ref={ref} tabIndex={0} onScroll={onScroll} onWheel={hand} onTouchStart={hand} onTouchMove={hand} onKeyDown={hand} className={`output${live ? " output-live" : ""}`}>{fold ? kept.join("\n") : shown}</pre>
    </div>
  );
}

// A job that has not started has no output: what it waits for instead.
function QueuedBehind({ id }: { id: string }) {
  const jobs = useRead<{ jobs: JobSummary[] }>("jobs?limit=20", 5000).env?.data?.jobs;
  return <p className="muted small">{jobs ? queuedBehind(jobs, id) : "Waiting for its turn: changes run one at a time."}</p>;
}

// A job's output, open while it runs. `text`: one phase of it. Once finished,
// `fold` says what becomes of it: "open" stays, "tail" folds to the last
// `tail` lines (a failure's say why), "closed" goes under a `summary`.
export function JobOutput({ job, text, live, fold = "open", tail, summary = "What the job printed" }: { job: Job; text?: string; live?: boolean; fold?: "open" | "tail" | "closed"; tail?: number; summary?: string }) {
  const running = live ?? jobLive(job);
  if (job.state === "queued") return <QueuedBehind id={job.id} />;
  const out = text ?? job.output;
  if (fold === "closed" && !running) {
    return (
      <details className="small">
        <summary>{summary}</summary>
        <Output text={out} />
      </details>
    );
  }
  return <Output text={out} live={running} collapsed={fold === "tail" && !running} tail={tail} />;
}

// The one line that says where a job stands: its state, what it is, how long
// it took, its id, and Stop while it can be stopped. `state`, `level` and `ms`:
// a phase of the job, which has its own; `control` false: not this phase's Stop.
export function JobStatusLine({ job, label, state, level, ms, control = true }: { job: JobSummary; label: ReactNode; state?: string; level?: string; ms?: number | null; control?: boolean }) {
  const took = duration(ms === undefined ? job.durationMs : ms);
  return (
    <p className="job-status">
      <Tag level={level ?? jobLevel(job)} /> {label}
      <span className="muted"> · {state ?? jobResult(job)}{job.simulated ? " (simulated)" : ""}{took ? ` · ${took}` : ""} · job {job.id}</span>
      {control ? <> <JobControl job={job} /></> : null}
    </p>
  );
}

// Cancel (queued: it never runs) or Stop (running: SIGINT to its process
// group, SIGTERM 30 s later), for whoever may change things; each asks once.
// `onDone`: the job's own reads (its watcher) are refreshed after.
export function JobControl({ job, onDone }: { job: JobSummary; onDone?: () => void }) {
  const operator = canOperate(useMe());
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!operator || (job.state !== "queued" && job.state !== "running")) return null;
  if (job.cancelled) return null; // asked: jobResult says it is under way
  const queued = job.state === "queued";
  const go = async () => {
    setAsking(false);
    const r = await cancelJob(job.id);
    setError(r.status >= 400 ? (r.error ?? `HTTP ${r.status}`) : null);
    reloadAll();
    onDone?.();
  };
  return (
    <span className="job-control" onClick={(e) => e.stopPropagation()}>
      {asking ? (
        <>
          <span className="small">{queued ? "Cancel it? It never runs." : "Stop it? Its process group gets SIGINT (it cleans up), SIGTERM 30 s later."}</span>{" "}
          <button className="btn btn-small btn-danger" onClick={() => void go()}>{queued ? "Cancel the job" : "Stop the job"}</button>{" "}
          <button className="btn btn-small" onClick={() => setAsking(false)}>No</button>
        </>
      ) : (
        <button className="btn btn-small" onClick={() => setAsking(true)} title={queued ? "Take it out of the queue: it never runs" : "Stop it: SIGINT to its process group"}>{queued ? "Cancel" : "Stop"}</button>
      )}
      {error ? <span className="small ff-error"> {error}</span> : null}
    </span>
  );
}

function JobDetail({ id }: { id: string }) {
  const job = useJob(id);
  if (!job) return <p className="muted small">reading the job…</p>;
  return (
    <div className="job-detail">
      {job.refused ? <p className="readstate readstate-fail">{job.refused}</p> : null}
      {job.cancelled ? <p className="readstate readstate-warn">{job.cancelled.was === "queued" ? "Cancelled" : "Stopped"} by {job.cancelled.by ?? "?"} at {when(job.cancelled.at)}{job.cancelled.was === "queued" ? ": it never ran." : `: ${job.cancelled.signals.join(", then ")} to its process group.`}</p> : null}
      {job.interrupted ? <p className="readstate readstate-fail">The console stopped while this job {job.started ? "ran" : "waited"}: cut off, no exit code. Check what it left and run it again.</p> : null}
      {job.previewPhase ? (
        <>
          <Command argv={job.previewPhase.ran} label="preview ran" />
          <JobOutput job={job} text={phaseOutputs(job).preview ?? ""} live={jobLive(job) && job.previewPhase.exit === null} fold={job.ran && !job.previewPhase.stopped ? "tail" : "open"} />
          {job.previewPhase.stopped ? <p className="readstate readstate-warn">{job.previewPhase.stopped}.</p> : null}
          {job.ran && !job.previewPhase.stopped && job.state !== "queued" ? (
            <>
              <Command argv={job.ran} label="then ran" />
              <JobOutput job={job} text={phaseOutputs(job).apply} live={jobLive(job) && job.previewPhase.exit !== null} />
            </>
          ) : null}
        </>
      ) : (
        <>
          {job.ran ? <Command argv={job.ran} label="ran" /> : <p className="muted small">No dry run: nothing ran for this preview.</p>}
          <JobOutput job={job} />
        </>
      )}
      {job.truncated ? <p className="muted small">output cut at 1 MiB</p> : null}
    </div>
  );
}

export function JobList({ jobs, empty }: { jobs: JobSummary[]; empty?: string }) {
  const [open, setOpen] = useState<string | null>(null);
  if (jobs.length === 0) return <p className="muted">{empty ?? "No console job yet."}</p>;
  return (
    <table className="table compact jobs">
      <thead>
        <tr><th>when</th><th>who</th><th /><th>command</th><th>result</th><th /></tr>
      </thead>
      <tbody>
        {jobs.map((j) => (
          <Fragment key={j.id}>
            <tr className="job-row" onClick={() => setOpen(open === j.id ? null : j.id)}>
              <td className="nowrap">{when(j.created)}</td>
              <td className="nowrap" title={j.assistant ? `assistant conversation ${j.assistant.conversation}, turn ${j.assistant.turn} (${j.assistant.proposal})` : undefined}>
                {j.who.user ?? "?"} <span className="muted">· {j.origin === "assistant" ? "via assistant" : j.who.via === "gate" ? "UI" : j.who.via}</span>
              </td>
              <td className="nowrap"><span className={`kind kind-${j.kind}`}>{j.kind}</span>{j.previewPhase ? <span className="muted small" title="previewed and applied in one job"> after preview</span> : null}</td>
              <td className="mono wrap">{quote(j.ran ?? j.argv)}</td>
              <td className="nowrap"><Tag level={jobLevel(j)} /> {jobResult(j)} <span className="muted">{duration(j.durationMs)}</span> <JobControl job={j} /></td>
              <td className="muted">{open === j.id ? "▾" : "▸"}</td>
            </tr>
            {open === j.id ? (
              <tr>
                <td colSpan={6}>
                  <JobDetail id={j.id} />
                </td>
              </tr>
            ) : null}
          </Fragment>
        ))}
      </tbody>
    </table>
  );
}
