// jobs.tsx — how a job looks wherever it is shown: its command line (exactly
// what ran, copyable), who ran it from where, its state, and its output.
// Activity lists them beside the sweep; a module's page lists its own.

import { Fragment, useState } from "react";
import { cancelJob, reloadAll, useJob } from "./api";
import { JobSummary } from "./types";
import { Tag, canOperate, useMe, when } from "./ui";

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

export function Command({ argv, label }: { argv: string[]; label?: string }) {
  const text = quote(argv);
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

export function Output({ text, live }: { text: string; live?: boolean }) {
  return <pre className={`output${live ? " output-live" : ""}`}>{stripAnsi(text) || (live ? "…" : "(no output)")}</pre>;
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
          <Output text={phaseOutputs(job).preview ?? ""} live={job.state === "running" && job.previewPhase.exit === null} />
          {job.previewPhase.stopped ? <p className="readstate readstate-warn">{job.previewPhase.stopped}.</p> : null}
          {job.ran && !job.previewPhase.stopped ? (
            <>
              <Command argv={job.ran} label="then ran" />
              <Output text={phaseOutputs(job).apply} live={job.state === "running" && job.previewPhase.exit !== null} />
            </>
          ) : null}
        </>
      ) : (
        <>
          {job.ran ? <Command argv={job.ran} label="ran" /> : <p className="muted small">No dry run: nothing ran for this preview.</p>}
          <Output text={job.output} live={job.state === "running"} />
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
