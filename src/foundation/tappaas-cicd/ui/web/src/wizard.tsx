// wizard.tsx — the shell every wizard pop-up shares (Add node, Enrol, the
// OperateButton flow, …). A wizard's state lives in it alone, so a click
// beside it does nothing: only its × closes it, and once a job runs in it, or
// a stage past the first is done, the × asks first. The jobs come from the
// steps inside (StepView reports the one it watches, WizardContext); a wizard
// that watches a job of its own (Add node's install, reattached) names it in
// `running`.

import { ReactNode, createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { useRead } from "./api";
import { JobSummary } from "./types";
import { sessionJob } from "./wizards";

interface WizardJobs {
  report: (key: string, label: string | null) => void;
}
export const WizardContext = createContext<WizardJobs | null>(null);

// How a job is named in the question: its verb and object (site-manager node add tappaas4).
export const jobLabel = (j: Pick<JobSummary, "bin" | "verb" | "object">): string => [j.bin, j.verb, j.object].filter(Boolean).join(" ");

export const jobLive = (j: Pick<JobSummary, "state"> | null | undefined): boolean => !!j && (j.state === "queued" || j.state === "running");

// A step's job while it waits or runs, for the wizard around it (none: no wizard).
export function useReportJob(job: (Pick<JobSummary, "state" | "bin" | "verb" | "object">) | null): void {
  const ctx = useContext(WizardContext);
  const key = useRef(`s${Math.random().toString(36).slice(2)}`).current;
  const label = jobLive(job) ? jobLabel(job!) : null;
  useEffect(() => {
    ctx?.report(key, label);
  }, [ctx, label]);
  useEffect(() => () => ctx?.report(key, null), [ctx]);
}

// The job a wizard's session hangs on (wizards.ts sessionJob): one verb's
// jobs, read while the wizard has none of its own attached (`enabled`).
export function useJobSession(bin: string, verb: string, match: (j: JobSummary) => boolean, enabled: boolean, keepMs = 3600_000): JobSummary | null {
  const q = `jobs?bin=${encodeURIComponent(bin)}&verb=${encodeURIComponent(verb)}&limit=20`;
  const jobs = useRead<{ jobs: JobSummary[] }>(enabled ? q : null, 15_000).env?.data?.jobs ?? [];
  return enabled ? sessionJob(jobs, match, Date.now(), keepMs) : null;
}

// The offer on open: "<what> — job … running. Continue".
export function ResumeOffer({ what, job, onContinue, onDecline, decline = "Start a new one" }: { what: ReactNode; job: JobSummary; onContinue: () => void; onDecline: () => void; decline?: string }) {
  return (
    <div className="readstate readstate-warn wizard-resume">
      <span>{what} — job {job.id} {jobLive(job) ? job.state : "finished"}.</span>
      <button className="btn btn-small btn-primary" onClick={onContinue}>Continue</button>
      <button className="btn btn-small" onClick={onDecline}>{decline}</button>
    </div>
  );
}

// `progress`: what closing now leaves behind when no job runs ("Stage 2 is
// done") — null while nothing is done past the first stage. `resumes`: the
// wizard finds its session again when reopened; otherwise a running job is
// followed in Activity.
export function Wizard({ title, wide = true, onClose, running = [], progress = null, resumes = false, children }: { title: string; wide?: boolean; onClose: () => void; running?: string[]; progress?: string | null; resumes?: boolean; children: ReactNode }) {
  const [jobs, setJobs] = useState<Record<string, string>>({});
  const report = useCallback((key: string, label: string | null) => {
    setJobs((m) => {
      if ((m[key] ?? null) === label) return m;
      const { [key]: _old, ...rest } = m;
      return label === null ? rest : { ...rest, [key]: label };
    });
  }, []);
  const [ctx] = useState<WizardJobs>(() => ({ report }));
  const [asking, setAsking] = useState(false);
  const live = [...new Set([...running, ...Object.values(jobs)])];
  const question = live.length
    ? `Close? ${live.join(", ")} ${live.length > 1 ? "keep" : "keeps"} running; ${resumes ? "reopen to continue" : "its output stays in Activity"}.`
    : progress
      ? `Close? ${progress}`
      : null;
  // Nothing left to ask about (the job ended meanwhile): no question pending.
  useEffect(() => {
    if (!question) setAsking(false);
  }, [question]);
  return (
    <div className="modal-back">
      <div className={`modal${wide ? " modal-wide" : ""}`} role="dialog" aria-label={title}>
        <header className="modal-head">
          <h2>{title}</h2>
          <button className="btn-x" onClick={() => (question ? setAsking(true) : onClose())} aria-label="close">×</button>
        </header>
        {asking && question ? (
          <div className="readstate readstate-warn modal-confirm" role="alertdialog">
            <span>{question}</span>{" "}
            <button className="btn btn-small" onClick={onClose}>Close</button>{" "}
            <button className="btn btn-small btn-primary" onClick={() => setAsking(false)}>Stay</button>
          </div>
        ) : null}
        <WizardContext.Provider value={ctx}>{children}</WizardContext.Provider>
      </div>
    </div>
  );
}
