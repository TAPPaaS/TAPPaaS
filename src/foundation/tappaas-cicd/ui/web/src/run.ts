// run.ts — one job from a step's point of view: started (with its dry run
// first, as a preview, or as a read), streamed, reported to the wizard around
// it, and read as one state (wizards.ts jobRunState). What a step does with
// it is the step's: flows.tsx, the assistant's card, Remove a node.

import { useEffect, useRef, useState } from "react";
import { CardRef, Posted, applyJob, applyNowJob, previewJob, readJob, useJob } from "./api";
import { Job } from "./types";
import { jobLive, useReportJob } from "./wizard";
import { RunState, jobInApply, jobRunState } from "./wizards";

export interface JobRun {
  id: string | null;
  job: Job | null; // null until it is read
  state: "starting" | RunState;
  live: boolean; // queued or running
  inApply: boolean; // past its dry run, if it has one
  finished: boolean; // ended, however it ended
  ok: boolean; // ended clean
  output: string;
  error: string | null; // it could not be started
  apply: (argv: string[], confirm?: string) => Promise<void>; // one job: the dry run, then the apply on a clean one
  preview: (argv: string[], from?: CardRef) => Promise<void>;
  read: (argv: string[], from?: CardRef) => Promise<void>;
  applyPreview: (previewId: string, confirm?: string) => Promise<void>;
  attach: (id: string) => void; // a job found again, or started elsewhere
  retry: () => void; // back to idle
}

// `onApplied`: once per job, when the change starts (past its dry run).
// `onDone`: once per job, when it ends, whatever way.
export function useJobRun({ attach: found = null, onApplied, onDone }: { attach?: string | null; onApplied?: (id: string) => void; onDone?: (ok: boolean, job: Job) => void } = {}): JobRun {
  const [id, setId] = useState<string | null>(found);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const seq = useRef(0); // the latest start: an older answer is dropped
  const read = useJob(id);
  const job = read && read.id === id ? read : null;
  useReportJob(jobLive(job) ? job : null);

  const state = jobRunState(job);
  const inApply = job !== null && jobInApply(job);
  const finished = job !== null && !jobLive(job);
  const latest = useRef({ onApplied, onDone });
  latest.current = { onApplied, onDone };
  const applied = useRef<string | null>(null);
  useEffect(() => {
    if (id && inApply && applied.current !== id) {
      applied.current = id;
      latest.current.onApplied?.(id);
    }
  }, [id, inApply]);
  const ended = useRef<string | null>(null);
  useEffect(() => {
    if (job && finished && ended.current !== job.id) {
      ended.current = job.id;
      latest.current.onDone?.(state === "done", job);
    }
  }, [job?.id, finished]);

  const launch = async (call: () => Promise<Posted<Job>>): Promise<void> => {
    const n = ++seq.current;
    setError(null);
    setStarting(true);
    try {
      const r = await call();
      if (n !== seq.current) return;
      // A job the sweep refused comes back with the refusal in it.
      if (r.data) setId(r.data.id);
      else setError(r.error ?? `HTTP ${r.status}`);
    } catch (e) {
      if (n === seq.current) setError((e as Error).message);
    } finally {
      if (n === seq.current) setStarting(false);
    }
  };
  return {
    id,
    job,
    state: starting ? "starting" : state,
    live: starting || jobLive(job) || (id !== null && job === null),
    inApply,
    finished,
    ok: state === "done",
    output: job?.output ?? "",
    error,
    apply: (argv, confirm) => launch(() => applyNowJob(argv, confirm)),
    preview: (argv, from) => launch(() => previewJob(argv, from)),
    read: (argv, from) => launch(() => readJob(argv, from)),
    applyPreview: (previewId, confirm) => launch(() => applyJob(previewId, confirm)),
    attach: (j) => {
      seq.current++;
      setId(j);
    },
    retry: () => {
      seq.current++;
      setStarting(false);
      setError(null);
      setId(null);
    },
  };
}
