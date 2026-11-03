// RestOfFoundation.tsx — Day 1's "Rest of foundation": network and
// tappaas-cicd moved to their pool, backup, identity and logging installed where
// placed, then the organization and the site owner with their password, as one
// job. The placement is the proposal rest-of-foundation.sh --proposal reads
// from the machines; the operator may change a row within its choices. rest-of-foundation.sh skips what is installed, so this also finishes
// a site where the modules went in one by one. The password goes to the job's
// stdin through the secrets endpoint: never in a command, never kept.

import { useEffect, useState } from "react";
import { post, useRead } from "../api";
import { JobOutput, JobStatusLine } from "../jobs";
import { useJobRun } from "../run";
import { ACTION_LABEL, Place, Placement, PlacementRow, follow, placeArgs, rowAction, rowProblem } from "../placement";
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
  const read = useRead<Placement>("foundation-placement", 600_000);
  const placement = read.env?.data ?? null;
  const [places, setPlaces] = useState<Record<string, Place> | null>(null);
  const [changed, setChanged] = useState<Record<string, string[]>>({});
  useEffect(() => {
    if (placement && !places) setPlaces(Object.fromEntries(placement.rows.map((r) => [r.module, r.proposal])));
  }, [placement, places]);
  const choose = (r: PlacementRow, p: Place) => {
    const f = follow(r, p);
    setPlaces((cur) => ({ ...(cur ?? {}), [r.module]: f.place }));
    setChanged((cur) => ({ ...cur, [r.module]: f.changed }));
  };
  const problem = placement && places ? placement.rows.map((r) => rowProblem(r, places[r.module])).find((x) => x) ?? null : null;
  const pwProblem = pw1.length < 8 ? "8 characters or more" : pw1 !== pw2 ? "the two do not match" : !/^[\x20-\x7e]+$/.test(pw1) ? "printable characters only" : null;

  const start = async () => {
    const place = placement && places ? placeArgs(placement.rows, places) : undefined;
    await run.start(() => post<Job>("secrets/rest-of-foundation", { password: pw1, ...(place ? { place } : {}) }));
    setPw1("");
    setPw2("");
  };

  return (
    <Wizard title="Rest of foundation" onClose={onClose} running={job && jobLive(job) ? [jobLabel(job)] : []}>
      <p className="small">One job: first network and tappaas-cicd move to the pool shown below (live, no restart), then backup, identity and logging are installed where shown, then your organization and you as its owner, the account you sign in with. It keeps running on the mothership if this browser is cut off.</p>
      {!run.id ? <PlacementPanel read={read.failure ?? read.env?.error ?? null} placement={placement} places={places} changed={changed} choose={choose} /> : null}
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
            <button className="btn btn-primary" disabled={pwProblem !== null || problem !== null || !owner || !canOperate(me)} onClick={() => void start()}>Install the rest of the foundation</button>
            {problem ? <span className="muted small">{problem}</span> : null}
          </div>
        </div>
      )}
    </Wizard>
  );
}

const gib = (n: number): string => (n >= 1024 ? `${(n / 1024).toFixed(1)} TiB` : `${n} GiB`);

function PlacementPanel({ read, placement, places, changed, choose }: {
  read: string | null;
  placement: Placement | null;
  places: Record<string, Place> | null;
  changed: Record<string, string[]>;
  choose: (r: PlacementRow, p: Place) => void;
}) {
  if (!placement || !places) {
    return read ? <p className="readstate readstate-fail small">The machines could not be read: {read}. The job then uses its own proposal.</p> : <p className="muted small">Reading the machines…</p>;
  }
  const many = placement.nodes.length > 1;
  return (
    <>
      <h3>Machines</h3>
      <ul className="small">
        {placement.nodes.map((n) => (
          <li key={n.name}>
            <b>{n.name}</b>: {n.memoryGiB} GiB memory; {n.pools.map((p) => `${p.name} ${gib(p.sizeGiB)} (${gib(p.freeGiB)} free)${p.boot ? ", the boot pool" : ""}`).join("; ") || "no pool"}
          </li>
        ))}
      </ul>
      <h3>Foundation modules</h3>
      {placement.rows.map((r) => {
        const p = places[r.module];
        const action = rowAction(r, p);
        const c = r.choices[p.node];
        const where = (x: Place) => [x.node, x.storage].filter(Boolean).join(", ") + (x.ha ? `, HA on ${x.ha}` : "");
        return (
          <div key={r.module} className="setup-placement">
            <p className="small">
              <b>{r.module}</b> — {ACTION_LABEL[action]}
              {action === "move" && r.current ? `: ${where(r.current)} → ${where(p)}` : action === "stays" && r.current ? `: ${where(r.current)}` : ""}
            </p>
            {action === "placeholder" || action === "installed" ? null : (
              <div className="form">
                {many ? (
                  <label className="form-row">
                    <span>machine</span>
                    <select value={p.node} onChange={(e) => choose(r, { ...p, node: e.target.value })}>
                      {Object.keys(r.choices).map((n) => <option key={n} value={n}>{n}</option>)}
                    </select>
                  </label>
                ) : null}
                {many && c && c.ha.length ? (
                  <label className="form-row">
                    <span>HA machine</span>
                    <select value={p.ha} onChange={(e) => choose(r, { ...p, ha: e.target.value })}>
                      <option value="">none</option>
                      {c.ha.map((n) => <option key={n} value={n}>{n}</option>)}
                    </select>
                  </label>
                ) : null}
                <label className="form-row">
                  <span>pool</span>
                  <select value={p.storage} onChange={(e) => choose(r, { ...p, storage: e.target.value })}>
                    {(c?.pools[p.ha] ?? []).map((s) => <option key={s} value={s}>{s}</option>)}
                  </select>
                </label>
              </div>
            )}
            {r.note && (many || r.kind === "backup") ? <p className="muted small">{r.note}</p> : null}
            {(changed[r.module] ?? []).map((t) => <p key={t} className="muted small">Changed: {t}.</p>)}
          </div>
        );
      })}
    </>
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
