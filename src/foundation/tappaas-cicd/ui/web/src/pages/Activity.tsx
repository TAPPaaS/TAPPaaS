// Activity — what was done to the site: the console's own jobs (who, from
// where, the command, the preview and the output; jobs.jsonl) beside the
// sweep's runs of update-tappaas.service with the errors and warnings they
// logged, the failures ledger, and the last run's result.

import { useState } from "react";
import { useRead } from "../api";
import { JobList } from "../jobs";
import { Activity as ActivityDoc, Envelope, JobSummary, SweepRun } from "../types";
import { Badge, ReadState, Section, Tag, levelOf, since, when } from "../ui";

function duration(r: SweepRun): string {
  if (!r.end) return "";
  const m = Math.round((Date.parse(r.end) - Date.parse(r.start)) / 60000);
  return `${m} min`;
}

function Run({ r }: { r: SweepRun }) {
  const [open, setOpen] = useState(r.result === "failed");
  const errors = r.lines.filter((l) => l.level === "error").length;
  const warnings = r.lines.length - errors;
  return (
    <li className={`run run-${levelOf(r.result === "ok" ? "pass" : r.result === "failed" ? "fail" : "skip")}`}>
      <button className="run-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <Tag level={r.result === "ok" ? "pass" : r.result === "failed" ? "fail" : r.result} />
        <span className="nowrap">{when(r.start)}</span>
        <span className="muted">{duration(r)}</span>
        <span className="muted">sweep · update-tappaas</span>
        <span className="spacer" />
        {errors ? <Badge level="fail">{errors} error(s)</Badge> : null}
        {warnings ? <Badge level="warn">{warnings} warning(s)</Badge> : null}
        <span className="muted">{open ? "▾" : "▸"}</span>
      </button>
      {open ? (
        <table className="table compact">
          <tbody>
            {r.lines.map((l, i) => (
              <tr key={i}>
                <td className="nowrap muted">{since(l.at)}</td>
                <td><Tag level={l.level === "error" ? "fail" : "warn"} /></td>
                <td className="mono wrap">{l.text}</td>
              </tr>
            ))}
            {r.lines.length === 0 ? (
              <tr><td className="muted">no errors or warnings logged</td></tr>
            ) : null}
            {r.truncated ? (
              <tr><td className="muted" colSpan={3}>… {r.truncated} more lines (journalctl -u update-tappaas)</td></tr>
            ) : null}
          </tbody>
        </table>
      ) : null}
    </li>
  );
}

export function Activity() {
  const a = useRead<ActivityDoc>("activity", 15_000);
  const d = a.env?.data;
  const jobs = (a.env as (Envelope<ActivityDoc> & { jobs?: JobSummary[] }) | null)?.jobs ?? [];
  const last = d?.lastResult as { ok?: boolean; total?: number; succeeded?: number; failed?: number; failed_modules?: string[]; end_time?: string; control_plane?: string; reboot?: string } | null | undefined;
  return (
    <div className="page">
      <div className="page-head">
        <h1>Activity</h1>
        <span className="muted">the console's jobs, the sweep's journal (7 days) and failures ledger · read {since(a.env?.at)}</span>
      </div>
      <ReadState env={a.env} failure={a.failure} what="activity" />
      {d?.sweepActive ? <div className="readstate readstate-warn">A sweep is running now (update-tappaas.service is active).</div> : null}
      <Section title="Console jobs" aside={`${jobs.length} job(s) · state dir jobs.jsonl`}>
        <JobList jobs={jobs.slice(0, 100)} />
      </Section>
      {last ? (
        <Section title="Last sweep" aside="config/last-update-result.json">
          <p>
            <Tag level={last.ok ? "pass" : "fail"} /> {last.end_time ?? "?"} · {last.succeeded ?? "?"} of {last.total ?? "?"} modules
            {last.failed ? ` · failed: ${(last.failed_modules ?? []).join(", ")}` : ""} · control plane {last.control_plane ?? "?"} · reboot {last.reboot ?? "?"}
          </p>
        </Section>
      ) : null}
      <Section title="Sweep runs" aside={d ? `${d.runs.length} run(s)` : undefined}>
        <ul className="runs">
          {(d?.runs ?? []).map((r) => (
            <Run key={r.start} r={r} />
          ))}
        </ul>
      </Section>
      <Section title="Failures ledger" aside="config/update-tappaas.failures">
        <table className="table compact">
          <tbody>
            {(d?.ledger ?? []).slice(0, 40).map((l, i) => (
              <tr key={i}>
                <td className="nowrap">{when(l.at)}</td>
                <td className="wrap">{l.text}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
    </div>
  );
}
