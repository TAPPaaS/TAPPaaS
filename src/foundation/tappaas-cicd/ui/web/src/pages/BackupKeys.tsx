// BackupKeys.tsx — Day 2's "Write the backup keys to a USB stick": the backup
// encryption keys are escrowed on the mothership, inside the system a full
// rebuild recreates, so they need a copy that leaves the building (ADR-012
// §2.5.1). 1 the stick: a node and a USB stick in it; 2 the password, typed
// twice, then the write — backup-manager key export --usb, a job the secrets
// endpoint starts with the password on its stdin, never in a command, never
// shown again; its output shows here, with Stop; the stick is erased (a key
// stick written before keeps everything but its keys), the keys read back and
// compared, the stick ejected; 3 what the backup-keys health gate says now.

import { useState } from "react";
import { post, reloadAll, useRead } from "../api";
import { JobOutput, JobStatusLine } from "../jobs";
import { useJobRun } from "../run";
import { Health, Job, SiteRead } from "../types";

// backup-manager key status --json (reads.ts BackupKeyStatus).
interface BackupKeyStatus {
  escrowed: number;
  stick: { keys: number; written: string; label: string } | null;
  current: boolean;
}
import { Dot, ReadState, Tag, canOperate, useMe } from "../ui";
import { DecideStep, StepRow, Wizard, jobLabel, jobLive } from "../wizard";
import { runFailure } from "../wizards";
import { UsbStick, UsbStickPicker } from "../usbsticks";

// What the activity is, on Day 2's card and at the top of the form.
export const BACKUP_KEYS_TEXT = "Writes the backup encryption keys, encrypted with a password of your choice, to a USB stick in a node: the copy of the keys that leaves the building. Without it an encrypted off-site backup cannot be restored after a full loss. Keep two sticks, and the password apart from them.";

export function BackupKeysWizard({ onClose }: { onClose: () => void }) {
  const me = useMe();
  const site = useRead<SiteRead>("site").env?.data;
  const nodes = (site?.nodes ?? []).map((n) => n.name);
  const [node, setNode] = useState(nodes[0] ?? "tappaas1");
  const [device, setDevice] = useState("");
  const [sticks, setSticks] = useState<UsbStick[]>([]);
  const [plan, setPlan] = useState<{ node: string; device: string; keyStick: boolean } | null>(null);
  const [format, setFormat] = useState(false);
  const [pw1, setPw1] = useState("");
  const [pw2, setPw2] = useState("");
  const run = useJobRun({ onDone: (ok) => { if (ok) { keys.reload(); health.reload(); } } });
  const written = run.ok;
  // The record itself, read every few seconds once something was written: it
  // is what the health check reads, so it says at once what health says later.
  const keys = useRead<BackupKeyStatus>("backup/keys", written ? 5_000 : 600_000);
  const rec = keys.env?.data ?? null;
  const health = useRead<Health>("health", 600_000);
  const job = run.job;
  const failed = run.finished && !run.ok;
  const picked = sticks.find((s) => s.device === device) ?? null;
  const pwProblem = pw1.length < 12 ? "12 characters or more" : pw1 !== pw2 ? "the two do not match" : !/^[\x20-\x7e]+$/.test(pw1) ? "printable characters only" : null;

  const write = async () => {
    if (!plan) return;
    await run.start(() => post<Job>("secrets/backup-keys", { node: plan.node, device: plan.device, password: pw1, format: plan.keyStick && format }));
    setPw1("");
    setPw2("");
  };

  const stages = [
    { id: "stick", title: "1 · The stick", required: true, done: plan !== null, detail: "A USB stick in a node. Everything on it is erased — except on a TAPPaaS key stick written before, where only the keys are replaced." },
    { id: "write", title: "2 · The password, then the write", required: true, done: written, detail: "The keys are encrypted with it (AES-256, PBKDF2) onto the stick, read back and compared, and the stick is ejected. The password is never shown again and never in a command." },
    { id: "status", title: "3 · Recorded, and watched from now on", required: false, done: written ? (rec ? rec.current : null) : null, detail: "TAPPaaS records which keys the stick holds. From now on the health check warns whenever a key changes after this stick was written (a new node, a rotation), so you know to write it again." },
  ];
  const current = !plan ? "stick" : !written ? "write" : "status";

  // The write is a job: closing while it runs leaves it running, with its
  // output in Activity, and the key record (stage 3, the health check) says
  // what it wrote. Nothing else to come back to.
  return (
    <Wizard title="Write the backup keys to a USB stick" onClose={onClose} running={job && jobLive(job) ? [jobLabel(job)] : []}>
      <p className="small">{BACKUP_KEYS_TEXT}</p>
      <ol className="setup">
        <StepRow s={stages[0]} open={current === "stick"}>
          <DecideStep decided={plan !== null} locked={run.live || written} ready={!!picked && !picked.inUse} hint={picked ? undefined : "pick the stick"} onChange={() => setPlan(null)} onContinue={() => setPlan({ node, device, keyStick: picked!.keyStick })}>
          <div className="form">
            <UsbStickPicker nodes={nodes.length ? nodes : [node]} node={node} setNode={setNode} device={device} setDevice={setDevice} disabled={plan !== null} onSticks={setSticks} />
          </div>
          {picked?.keyStick ? (
            <p className="small"><Dot level="info" /> {picked.device} is a TAPPaaS key stick: its keys are replaced and everything else on it stays, unless you erase it below.</p>
          ) : picked ? (
            <p className="small"><Dot level="warn" /> Everything on {picked.device} will be erased.</p>
          ) : null}
          </DecideStep>
        </StepRow>
        <StepRow s={stages[1]} open={current === "write"}>
          {!plan ? (
            <p className="muted small">Once the stick is picked.</p>
          ) : run.id ? (
            !job ? (
              <p className="muted small">starting the write…</p>
            ) : failed ? (
              <>
                <p className="readstate readstate-fail">The keys were not written: {runFailure(job)}.</p>
                <JobOutput job={job} fold="tail" tail={8} />
                <div className="actions">
                  <button className="btn btn-primary" onClick={run.retry}>Try again</button>
                  <span className="muted small">the password is asked again</span>
                </div>
              </>
            ) : (
              <>
                {written ? <p className="small"><Tag level="pass" /> The keys are on {plan.device} in {plan.node}: read back, compared, and the stick ejected.</p> : null}
                <JobStatusLine job={job} label={`Writing the keys to ${plan.device} in ${plan.node}`} />
                {run.live ? <p className="muted small">Formatting, encrypting, reading back and ejecting: a minute or two.</p> : null}
                <JobOutput job={job} fold="tail" tail={8} />
              </>
            )
          ) : (
            <div className="form">
              <label className="form-row">
                <span>password *</span>
                <input type="password" autoComplete="new-password" placeholder="12 characters or more" value={pw1} onChange={(e) => setPw1(e.target.value)} />
              </label>
              <label className="form-row">
                <span>again *</span>
                <input type="password" autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} />
                <small className="muted">{pw1 && pwProblem ? <span className="ff-error">{pwProblem}. </span> : null}Keep it apart from the stick: with both, anyone can read every backup. Lose it and the stick is useless.</small>
              </label>
              {plan.keyStick ? (
                <label className="form-check">
                  <input type="checkbox" checked={format} onChange={(e) => setFormat(e.target.checked)} />
                  <span>erase the stick</span> <small className="muted">Unticked, only its keys, restore script and README are replaced (--format erases it anyway).</small>
                </label>
              ) : null}
              <div className="actions">
                <button className="btn btn-primary" disabled={run.live || pwProblem !== null || !canOperate(me)} onClick={() => void write()}>
                  {run.live ? "Starting…" : `Write the keys to ${plan.device} in ${plan.node}`}
                </button>
                <span className="muted small">backup-manager key export --usb --node {plan.node} --device {plan.device} --yes --password-stdin{plan.keyStick && format ? " --format" : ""}</span>
              </div>
              {run.error ? <p className="readstate readstate-fail">{run.error}</p> : null}
            </div>
          )}
        </StepRow>
        <StepRow s={stages[2]} open={current === "status"}>
          {rec ? (
            <p className="small">
              <Tag level={rec.current ? "pass" : rec.stick ? "warn" : "fail"} />{" "}
              {rec.current && rec.stick ? (
                <>The key stick written {rec.stick.written.slice(0, 16).replace("T", " ")} ({rec.stick.label}) holds all {rec.escrowed} key(s) as they are now. The health check says the same at its next run.</>
              ) : rec.stick ? (
                <>The record still shows the stick written {rec.stick.written.slice(0, 10)} with {rec.stick.keys} of {rec.escrowed} key(s): {written ? "this write did not update it — the last lines of stage 2 say why; the stick itself was read back and is good" : "a key changed after it, write the stick again"}.</>
              ) : (
                <>No stick has been recorded yet.</>
              )}
            </p>
          ) : (
            <ReadState env={keys.env} failure={keys.failure} what="the key record" />
          )}
          {written ? <p className="small">Label the stick and keep it off-site; write a second one the same way. The password goes where the stick is not.</p> : null}
        </StepRow>
      </ol>
    </Wizard>
  );
}

export function BackupKeysButton() {
  const [open, setOpen] = useState(false);
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Write the backup keys…</button>
      {open ? <BackupKeysWizard onClose={() => { setOpen(false); reloadAll(); }} /> : null}
    </>
  );
}
