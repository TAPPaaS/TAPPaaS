// RestOfFoundation.tsx — Day 1's "Rest of foundation": backup, identity and
// logging, then the organization and the site owner with their password, as
// one job. rest-of-foundation.sh skips what is installed, so this also finishes
// a site where the modules went in one by one. The password goes to the job's
// stdin through the secrets endpoint: never in a command, never kept.

import { useState } from "react";
import { post } from "../api";
import { JobOutput, JobStatusLine } from "../jobs";
import { useJobRun } from "../run";
import { Job } from "../types";
import { canOperate, useMe } from "../ui";
import { Wizard, jobLabel, jobLive } from "../wizard";
import { runFailure } from "../wizards";

export function ownerName(email: string): string {
  return email.split("@")[0]?.toLowerCase().replace(/[^a-z0-9-]/g, "-").replace(/^-+|-+$/g, "") ?? "";
}

function RestOfFoundationWizard({ email, onClose }: { email: string; onClose: () => void }) {
  const me = useMe();
  const [pw1, setPw1] = useState("");
  const [pw2, setPw2] = useState("");
  const run = useJobRun({});
  const job = run.job;
  const owner = ownerName(email);
  const pwProblem = pw1.length < 8 ? "8 characters or more" : pw1 !== pw2 ? "the two do not match" : !/^[\x20-\x7e]+$/.test(pw1) ? "printable characters only" : null;

  const start = async () => {
    await run.start(() => post<Job>("secrets/rest-of-foundation", { password: pw1 }));
    setPw1("");
    setPw2("");
  };

  return (
    <Wizard title="Rest of foundation" onClose={onClose} running={job && jobLive(job) ? [jobLabel(job)] : []}>
      <p className="small">Installs what is missing of backup, identity and logging, then creates your organization and you as its owner, the account you sign in with.</p>
      {run.id ? (
        !job ? (
          <p className="muted small">starting…</p>
        ) : (
          <>
            {run.ok ? <p className="small">Done. Sign in as <b>{owner}</b> with the password you chose.</p> : null}
            {run.finished && !run.ok ? <p className="readstate readstate-fail">It did not finish: {runFailure(job)}.</p> : null}
            <JobStatusLine job={job} label="rest-of-foundation.sh" />
            <JobOutput job={job} fold="tail" tail={8} />
            {run.finished && !run.ok ? (
              <div className="actions">
                <button className="btn btn-primary" onClick={run.retry}>Try again</button>
                <span className="muted small">the password is asked again</span>
              </div>
            ) : null}
          </>
        )
      ) : (
        <div className="form">
          <label className="form-row">
            <span>you</span>
            <input type="text" value={owner ? `${owner} (${email})` : ""} disabled />
            <small className="muted">From the site's email address.</small>
          </label>
          <label className="form-row">
            <span>password *</span>
            <input type="password" autoComplete="new-password" placeholder="8 characters or more" value={pw1} onChange={(e) => setPw1(e.target.value)} />
          </label>
          <label className="form-row">
            <span>again *</span>
            <input type="password" autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} />
            <small className="muted">{pw1 && pwProblem ? <span className="ff-error">{pwProblem}. </span> : null}Set in Authentik once your account exists: never in a command, never kept by the console.</small>
          </label>
          <div className="actions">
            <button className="btn btn-primary" disabled={pwProblem !== null || !owner || !canOperate(me)} onClick={() => void start()}>Install the rest of the foundation</button>
          </div>
        </div>
      )}
    </Wizard>
  );
}

export function RestOfFoundationButton({ email }: { email: string }) {
  const [open, setOpen] = useState(false);
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Rest of foundation…</button>
      {open ? <RestOfFoundationWizard email={email} onClose={() => setOpen(false)} /> : null}
    </>
  );
}
