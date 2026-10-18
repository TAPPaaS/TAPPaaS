// jobs.tsx — how a job looks wherever it is shown: its command line (exactly
// what ran, copyable), who ran it from where, its state, and its output.
// Activity lists them beside the sweep; a module's page lists its own.

import { Fragment, useState } from "react";
import { useJob } from "./api";
import { JobSummary } from "./types";
import { Tag, when } from "./ui";

export function quote(argv: string[]): string {
  return argv.map((a) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)).join(" ");
}

export function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "");
}

export function jobLevel(j: JobSummary): string {
  if (j.state === "refused") return "fail";
  if (j.state !== "done") return "skip";
  return j.exit === 0 ? "pass" : "fail";
}

export function jobResult(j: JobSummary): string {
  if (j.state === "refused") return "refused";
  if (j.state === "queued") return "queued";
  if (j.state === "running") return "running…";
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

export function Output({ text, live }: { text: string; live?: boolean }) {
  return <pre className={`output${live ? " output-live" : ""}`}>{stripAnsi(text) || (live ? "…" : "(no output)")}</pre>;
}

function JobDetail({ id }: { id: string }) {
  const job = useJob(id);
  if (!job) return <p className="muted small">reading the job…</p>;
  return (
    <div className="job-detail">
      {job.ran ? <Command argv={job.ran} label="ran" /> : <p className="muted small">No dry run: nothing ran for this preview.</p>}
      {job.refused ? <p className="readstate readstate-fail">{job.refused}</p> : null}
      <Output text={job.output} live={job.state === "running"} />
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
              <td><span className={`kind kind-${j.kind}`}>{j.kind}</span></td>
              <td className="mono wrap">{quote(j.ran ?? j.argv)}</td>
              <td className="nowrap"><Tag level={jobLevel(j)} /> {jobResult(j)} <span className="muted">{duration(j.durationMs)}</span></td>
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
