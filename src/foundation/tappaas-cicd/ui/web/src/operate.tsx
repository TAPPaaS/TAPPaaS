// operate.tsx — the one way the console changes the site (ADR-034 D4, spike
// §5.4). A step's form is built from the verb's manifest, the command block is
// exactly what will run and can be copied, and how the step runs follows from
// how the verb previews (argv.ts stepFlow, flows.tsx): no dry run, or a dry run
// that only says yes or no: one button, the job in place, a refusal shown
// there; a destructive call with a dry run: the check at once, then the typed
// name; a plan: the preview at once, one Apply under it. A disruption (--force,
// --allow-disruption, --yes) is a checkbox that names its consequence. A flow
// of several steps (update-port, then reconcile) runs them in order.

import { useState } from "react";
import { reloadAll, useJob, useRead } from "./api";
import { Values, stepFlow, writeMarkOf } from "./argv";
import { ActFlow, CheckFlow, PlanFlow, ReadFlow } from "./flows";
import { JobOutput, JobStatusLine } from "./jobs";
import { useOpenedBy } from "./opener";
import { Step, useStepForm } from "./stepform";
import { Me } from "./types";
import { canOperate, useMe } from "./ui";
import { Wizard } from "./wizard";

export type { Step } from "./stepform";
export type { Values } from "./argv";
export { PrefillContext, StepForm, useStepValues } from "./stepform";

// Also a continued wizard's view of the job it found again (wizard.tsx useJobSession).
export function JobView({ id, label, collapsed }: { id: string; label: string; collapsed?: boolean }) {
  const job = useJob(id);
  if (!job) return <p className="muted">starting {label}…</p>;
  return (
    <div className="jobview">
      <JobStatusLine job={job} label={label} />
      {job.refused ? <p className="readstate readstate-fail">{job.refused}</p> : null}
      <JobOutput job={job} fold={collapsed ? "tail" : "open"} />
    </div>
  );
}

// One step of a flow; also embedded in a wizard of its own, which learns when
// the change starts (onApplied) as well as when it ends (onDone).
export function StepView({ step, me, onDone, onApplied }: { step: Step; me: Me | null; onDone: (ok: boolean) => void; onApplied?: (jobId: string) => void }) {
  const form = useStepForm(step);
  const { verb, argv } = form;
  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  const writeMark = writeMarkOf(verb, argv);
  const flow = stepFlow(step.bin, verb, argv, step.flow);
  return (
    <div className="step">
      <h3>{step.title}</h3>
      {writeMark ? <p className="readstate readstate-warn">{writeMark.flag} makes this a change: it {writeMark.touches}. It is queued like any change, never beside the sweep.</p> : null}
      {flow === "read" ? (
        <ReadFlow form={form} me={me} />
      ) : flow === "plan" ? (
        <PlanFlow form={form} me={me} onDone={onDone} onApplied={onApplied} />
      ) : flow === "check" ? (
        <CheckFlow form={form} me={me} onDone={onDone} onApplied={onApplied} />
      ) : (
        <ActFlow form={form} me={me} onDone={onDone} onApplied={onApplied} />
      )}
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
