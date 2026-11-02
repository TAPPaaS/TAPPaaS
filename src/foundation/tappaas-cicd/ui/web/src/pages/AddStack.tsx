// AddStack.tsx — Day 2's "Add a stack". 1 the stack and its environment; 2 the
// modules, from add-stack's own plan: what is installed is marked, the rest is
// ticked and may be unticked; 3 the plan for that choice (add-stack --skip …
// --dry-run), then the install.

import { useMemo, useState } from "react";
import { reloadAll, useRead } from "../api";
import { TargetValues } from "../consoletargets";
import { useOpenedBy } from "../opener";
import { Step, StepView } from "../operate";
import { EnvironmentRow, SiteRead } from "../types";
import { Badge, ReadState, canOperate, useMe } from "../ui";
import { DecideStep, StepRow, Wizard } from "../wizard";
import { StackPlan, stackModuleOrigin, stackSkips, stacksOf } from "../wizards";

interface Choice {
  stack: string;
  environment: string;
}

function AddStackWizard({ onClose, prefill }: { onClose: () => void; prefill?: TargetValues | null }) {
  const me = useMe();
  const cats = useRead<{ modules: { name: string; stack: string | null }[] }[]>("catalogs", 600_000).env?.data ?? [];
  const envs = (useRead<EnvironmentRow[]>("environments").env?.data ?? []).map((e) => e.name);
  const site = useRead<SiteRead>("site").env?.data?.site;
  const defaultEnv = typeof site?.defaultEnvironment === "string" ? site.defaultEnvironment : "";
  const { stacks, notes } = stacksOf(cats);
  const [p, setP] = useState<Choice>({ stack: typeof prefill?.stack === "string" ? prefill.stack : "", environment: "" });
  const environment = p.environment || defaultEnv;
  const [chosen, setChosen] = useState<Choice | null>(null);
  const [off, setOff] = useState<string[]>([]);
  const [skips, setSkips] = useState<string[] | null>(null);
  const [applied, setApplied] = useState(false);
  const read = useRead<StackPlan>(chosen ? `stack-plan/${encodeURIComponent(chosen.stack)}?environment=${encodeURIComponent(chosen.environment)}` : null, 600_000);
  const plan = read.env?.data ?? null;
  const toInstall = plan ? plan.steps.filter((s) => s.action === "install" && !off.includes(s.module)) : [];

  const step = useMemo((): Step | null => {
    if (!chosen || !skips) return null;
    return {
      title: `module-manager add-stack ${chosen.stack}`,
      bin: "module-manager",
      verb: "add-stack",
      fixed: [chosen.stack],
      initial: { "--environment": chosen.environment, "--skip": skips },
      only: [],
      button: "Install the modules",
      note: "The plan for what you chose: the modules in dependency order. They install one by one; the first failure stops it, and running it again resumes.",
    };
  }, [chosen, skips]);

  const stages = [
    { id: "what", title: "1 · The stack", required: true, done: chosen !== null, detail: "Which stack, into which environment." },
    { id: "modules", title: "2 · The modules", required: true, done: skips !== null, detail: "What is already installed, and what to install." },
    { id: "install", title: "3 · Preview and install", required: true, done: applied, detail: "The plan, then the install; it takes minutes per module, and its output shows here." },
  ];
  const current = !chosen ? "what" : skips === null ? "modules" : "install";

  return (
    <Wizard title="Add a stack" onClose={onClose}>
      <ol className="setup">
        <StepRow s={stages[0]} open={current === "what"}>
          <DecideStep decided={chosen !== null} locked={applied} ready={p.stack !== "" && environment !== ""} hint="Choose a stack and an environment." onChange={() => { setChosen(null); setSkips(null); setOff([]); }} onContinue={() => setChosen({ stack: p.stack, environment })}>
            <div className="form">
              <label className="form-row">
                <span>stack *</span>
                <select value={p.stack} onChange={(e) => setP({ ...p, stack: e.target.value })}>
                  <option value="">— pick a stack</option>
                  {stacks.map((s) => <option key={s} value={s}>{notes[s]}</option>)}
                </select>
              </label>
              <label className="form-row">
                <span>environment *</span>
                <select value={environment} onChange={(e) => setP({ ...p, environment: e.target.value })}>
                  <option value="">—</option>
                  {envs.map((e) => <option key={e} value={e}>{e === defaultEnv ? `${e} — the default environment` : e}</option>)}
                </select>
              </label>
            </div>
          </DecideStep>
        </StepRow>
        <StepRow s={stages[1]} open={current === "modules"}>
          {chosen ? <ReadState env={read.env} failure={read.failure} what="the stack's modules" /> : null}
          {plan ? (
            <DecideStep decided={skips !== null} locked={applied} ready={toInstall.length > 0} hint={plan.steps.some((s) => s.action === "install") ? "Tick at least one module." : `Every module of ${plan.stack} is installed in ${chosen?.environment}.`} onChange={() => setSkips(null)} onContinue={() => setSkips(stackSkips(plan, off))}>
              <ul className="stack-modules">
                {plan.steps.map((s) => {
                  const installed = s.action === "skip";
                  return (
                    <li key={s.module}>
                      <label className="stack-module">
                        <input type="checkbox" checked={installed || !off.includes(s.module)} disabled={installed} onChange={(e) => setOff(e.target.checked ? off.filter((m) => m !== s.module) : [...off, s.module])} />
                        <span><span className="mono">{s.module}</span>{stackModuleOrigin(s) ? <> <span className="muted">{stackModuleOrigin(s)}</span></> : null}{installed ? <> <Badge level="pass">installed</Badge></> : null}</span>
                        {s.description ? <small className="muted">{s.description}</small> : null}
                      </label>
                    </li>
                  );
                })}
              </ul>
            </DecideStep>
          ) : null}
        </StepRow>
        <StepRow s={stages[2]} open={current === "install"}>
          {step ? <StepView key={skips?.join(" ")} step={step} me={me} onDone={(ok) => ok && setApplied(true)} /> : null}
        </StepRow>
      </ol>
    </Wizard>
  );
}

// The Add a stack button; on Day 2 the assistant's open_console opens it too.
export function AddStackButton({ opens = true }: { opens?: boolean }) {
  const [open, setOpen] = useState(false);
  const [prefill, setPrefill] = useState<TargetValues | null>(null);
  const operator = canOperate(useMe());
  useOpenedBy("add-stack", undefined, (v) => {
    setPrefill(v);
    setOpen(true);
  }, opens && operator);
  if (!operator) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Add a stack…</button>
      {open ? <AddStackWizard prefill={prefill} onClose={() => { setOpen(false); setPrefill(null); reloadAll(); }} /> : null}
    </>
  );
}
