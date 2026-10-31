// Buddy.tsx — Day 2's "Add a backup buddy": another site's PBS that keeps an
// off-site copy, one pull through one WireGuard tunnel (backup/BUDDY.md).
// 1 which side this site is (pull or remote) and the buddy's name; 2 peer add,
// with the options of its manifest; 3 peer check, the tunnel's live state.

import { useEffect, useMemo, useState } from "react";
import { reloadAll, useJob } from "../api";
import { ActStep } from "../flows";
import { JobView, Step, StepView } from "../operate";
import { TargetValues } from "../consoletargets";
import { useOpenedBy } from "../opener";
import { JobSummary } from "../types";
import { canOperate, useMe } from "../ui";
import { ResumeOffer, Wizard, jobLabel, jobLive, useJobSession } from "../wizard";
import { locationOption, useSiteLocations } from "../locations";
import { BUDDY_KINDS, BuddyKind, buddyNameProblem, buddySpecs } from "../wizards";
import { StepRow } from "./Setup";

const LABELS: Record<string, string> = {
  "--host": "--host: the buddy's PBS",
  "--contact": "--contact: its operator's email",
  "--tunnel": "--tunnel: this side of it",
  "--endpoint": "--endpoint: where to dial",
  "--peer-key": "--peer-key: their WireGuard key",
  "--namespace": "--namespace",
  "--config-only": "--config-only (onboard by hand)",
};

// Onboarding prompts on a terminal; a job has none.
const ONBOARD = (kind: BuddyKind, name: string) => (
  <p className="readstate readstate-warn">
    Onboarding asks for a credential on a terminal — {kind === "pull" ? "the login, password and fingerprint the buddy sent" : "the password of the buddy's new login"} — and is never stored, so the console cannot answer it. With <span className="mono">--config-only</span> ticked the peer is written here; then onboard it in an ssh session to tappaas-cicd: <span className="mono">backup-manager peer add {kind} {name} …</span> with the same options.
  </p>
);

// `prefill`: what the assistant opened it with (open_console add-buddy): kind, name.
export function BuddyWizard({ onClose, prefill }: { onClose: () => void; prefill?: TargetValues | null }) {
  const me = useMe();
  const [kind, setKind] = useState<BuddyKind>(prefill?.kind === "remote" ? "remote" : "pull");
  const [name, setName] = useState(typeof prefill?.name === "string" ? prefill.name : "");
  const [chosen, setChosen] = useState<{ kind: BuddyKind; name: string } | null>(null);
  const [added, setAdded] = useState(false);
  // Closed while peer add ran, or within the hour after: its job is found
  // again, with what it printed for the buddy.
  const [job, setJob] = useState<string | null>(null); // the job continued (set by restore only)
  const [declined, setDeclined] = useState(false);
  const session = useJobSession("backup-manager", "peer add", (j) => (j.argv[3] ?? "") in BUDDY_KINDS, job === null && !declined);
  const followed = useJob(job);
  useEffect(() => {
    if (followed?.state === "done" && followed.exit === 0) setAdded(true);
  }, [followed?.state]);
  const restore = (j: JobSummary) => {
    const k = j.argv[3] as BuddyKind;
    setKind(k);
    setName(j.argv[4] ?? "");
    setChosen({ kind: k, name: j.argv[4] ?? "" });
    setJob(j.id);
  };
  const problem = buddyNameProblem(name.trim());
  // A buddy is another site: one of the site's remote locations, or a place
  // (--country, --city) peer add records as one — never the primary preselected.
  const locations = useSiteLocations();
  const steps = useMemo(() => {
    if (!chosen) return null;
    const s = buddySpecs(chosen.kind, chosen.name);
    const at = locationOption(locations, null, false);
    const add: Step = {
      ...s.add,
      title: `backup-manager peer add ${chosen.kind} ${chosen.name}`,
      button: `Add ${chosen.name}`,
      labels: LABELS,
      choices: { "--tunnel": ["serve", "dial"], ...at.choices },
      asides: at.asides,
      placeholders: chosen.kind === "pull" ? { "--host": "its PBS through the tunnel, e.g. 10.255.2.1", "--endpoint": "e.g. buddy.example.org:51830", "--namespace": "where the copy lands here, e.g. buddy/<their site>" } : { "--namespace": "what they may read — empty: the root (this site's VM backups)" },
      note:
        chosen.kind === "pull" ? (
          <>This site keeps the copy. The buddy runs <span className="mono">peer add remote</span> first and sends its PBS address, the tunnel's /30, its endpoint and public key; this side dials. Onboarding creates the tunnel on the firewall and the pull job on the PBS, and prints this side's public key for the buddy.</>
        ) : (
          <>The buddy keeps the copy. This side serves the tunnel and creates a read-only login for the buddy on the PBS (the root namespace, not propagated: config and other peers' data stay out of reach). Onboarding prints what to send the buddy — the address, the /30, the port and this side's public key; their key can come later (run it again with it and --force).</>
        ),
    };
    const check: Step = { ...s.check, runOnOpen: true, title: `backup-manager peer check ${chosen.kind} ${chosen.name}`, note: "The tunnel's live state: the WireGuard instance, the keys, the last handshake, and whether the PBS answers through it. Until the buddy has its side in place the handshake is missing." };
    return { add, check };
  }, [chosen, locations]);

  const stages = [
    { id: "who", title: "1 · Which side, and the buddy's name", required: true, done: chosen !== null, detail: "Who keeps the copy decides who serves the tunnel." },
    { id: "add", title: "2 · The peer: backup-manager peer add", required: true, done: added, detail: "Its address, its operator, the tunnel." },
    { id: "check", title: "3 · The result: peer check", required: false, done: false, detail: "The tunnel and the PBS through it, read live." },
  ];
  const current = !chosen ? "who" : !added ? "add" : "check";

  return (
    <Wizard title="Add a backup buddy" onClose={onClose} running={followed && jobLive(followed) ? [jobLabel(followed)] : []} progress={added && chosen ? `${chosen.name} is added; what peer add printed for the buddy is in its job in Activity.` : null} resumes={job !== null}>
      {session ? <ResumeOffer what={<>A backup buddy is being added: <b>{session.argv[3]} {session.argv[4] ?? "?"}</b></>} job={session} onContinue={() => restore(session)} onDecline={() => setDeclined(true)} decline="Add another buddy" /> : null}
      <p className="small">A buddy is another site's PBS that keeps an off-site copy of backups. The copy is always pulled, through its own WireGuard tunnel that carries the pull and nothing else; two sites holding each other's copy are two pulls, one in each direction.</p>
      <ol className="setup">
        <StepRow s={stages[0]} open={current === "who"}>
          <div className="form">
            {(Object.keys(BUDDY_KINDS) as BuddyKind[]).map((k) => (
              <label key={k} className="form-check">
                <input type="radio" name="buddy-kind" checked={kind === k} disabled={chosen !== null} onChange={() => setKind(k)} />
                <b className="mono">{k}</b> <small>{BUDDY_KINDS[k]}</small>
              </label>
            ))}
            <label className="form-row">
              <span>the buddy's name *</span>
              <input type="text" value={name} disabled={chosen !== null} placeholder="e.g. their site's name" onChange={(e) => setName(e.target.value)} />
              {name && problem ? <small className="ff-error">{problem}</small> : <small className="muted">Names the peer here: its config, its PBS remote or login, its tunnel.</small>}
            </label>
          </div>
          <div className="actions">
            {chosen ? (
              <button className="btn" disabled={added || job !== null} onClick={() => setChosen(null)}>Edit</button>
            ) : (
              <button className="btn btn-primary" disabled={problem !== null} onClick={() => setChosen({ kind, name: name.trim() })}>Continue</button>
            )}
          </div>
        </StepRow>
        <StepRow s={stages[1]} open={current === "add"}>
          {steps ? (
            <>
              {ONBOARD(chosen!.kind, chosen!.name)}
              {job ? <JobView id={job} label="backup-manager peer add" /> : <ActStep key={JSON.stringify(chosen)} step={steps.add} onDone={(ok) => ok && setAdded(true)} />}
            </>
          ) : <p className="muted small">Once the side and the name are chosen.</p>}
        </StepRow>
        <StepRow s={stages[2]} open={current === "check"}>
          {steps && added ? <StepView step={steps.check} me={me} onDone={() => undefined} /> : <p className="muted small">Once the peer is added.</p>}
        </StepRow>
      </ol>
    </Wizard>
  );
}

export function BuddyButton() {
  const [open, setOpen] = useState(false);
  const [prefill, setPrefill] = useState<TargetValues | null>(null);
  const operator = canOperate(useMe());
  useOpenedBy("add-buddy", undefined, (v) => {
    setPrefill(v);
    setOpen(true);
  }, operator);
  if (!operator) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Add a backup buddy…</button>
      {open ? <BuddyWizard prefill={prefill} onClose={() => { setOpen(false); setPrefill(null); reloadAll(); }} /> : null}
    </>
  );
}
