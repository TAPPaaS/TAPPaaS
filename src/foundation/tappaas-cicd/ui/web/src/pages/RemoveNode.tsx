// RemoveNode.tsx — Day 2's "Remove a node": a machine leaves the cluster for
// good. 1 which node, and how: powered off first, wiped first, or down for
// good; 2 remove it — the console checks at once (site-manager node delete
// <node> --<how>, its dry run) and shows what still holds the node as
// findings with where to act (noderemove.ts reads the output); once nothing
// does, the machine's record is kept or removed (a lost machine's is
// removed), the node's name is typed, and one button runs the removal
// (--apply --yes --asset <choice>; the typed name is the confirmation the
// script would otherwise ask for on a terminal); its result is shown here,
// the output under a fold; 3 afterwards: what is true now, with links.

import { useState } from "react";
import { reloadAll, useRead } from "../api";
import { confirmMatches } from "../argv";
import { CheckStep } from "../flows";
import { phaseOutputs } from "../jobs";
import { AssetChoice, ASSET_CHOICES, CheckOutcome, HOWS, How, RemovalOutcome, assetFor, assetTarget, checkArgv, parseCheck, parseRemoval, removeArgv, switchTarget } from "../noderemove";
import { useOpenedBy, requestOpen } from "../opener";
import { Job, JobSummary, SiteRead } from "../types";
import { Link, Tag, TypedConfirm, canOperate, useMe } from "../ui";
import { DecideStep, ResumeOffer, StepRow, Wizard, useJobSession } from "../wizard";

export { HOWS } from "../noderemove";
export type { How } from "../noderemove";

// What the activity is, on Day 2's card and at the top of the form.
export const REMOVE_NODE_TEXT = "Takes a machine out of the cluster for good. The console first checks that nothing still needs it (something running on it, a copy kept on it, the site's backup server) and says where to move each; then the machine leaves the cluster, its switch ports are parked and the node is gone from the site. The other nodes are untouched.";

export function RemoveNodeWizard({ onClose, node: preset }: { onClose: () => void; node?: string | null }) {
  const site = useRead<SiteRead>("site").env?.data;
  const nodes = (site?.nodes ?? []).map((n) => n.name);
  const [node, setNode] = useState(preset ?? "");
  const [how, setHow] = useState<How>("shutdown");
  const [asset, setAsset] = useState<AssetChoice>("keep");
  const [job, setJob] = useState<string | null>(null);
  const [result, setResult] = useState<RemovalOutcome | null>(null);
  // Closed while the removal ran, or within the hour after: its job is found
  // again (the node may be gone from the site by then: it is the job's).
  const [resumed, setResumed] = useState(false);
  const [declined, setDeclined] = useState(false);
  // Step 1 is done when the operator says so: the node and the way are chosen
  // together, and the check of step 2 runs on what was decided.
  const [decided, setDecided] = useState(false);
  const session = useJobSession("site-manager", "node delete", (j) => j.kind === "apply", job === null && !declined);
  const restore = (j: JobSummary) => {
    setNode(j.argv[3] ?? "");
    setHow(HOWS.find((h) => j.argv.includes(`--${h.id}`))?.id ?? "shutdown");
    const a = j.argv[j.argv.indexOf("--asset") + 1];
    if (a === "keep" || a === "remove") setAsset(a);
    setJob(j.id);
    setResumed(true);
    setDecided(true);
  };
  // Once a removal runs the node is the job's: it leaves the site's list.
  const chosen = nodes.includes(node) || resumed || job !== null ? node : "";
  // Set only when the removal job ended clean (RemoveStep).
  const removed = result !== null;

  const stages = [
    { id: "node", title: "1 · The node, and how", required: true, done: chosen && decided ? true : false, detail: "Which node leaves, and whether it is powered off first, wiped first, or already dead." },
    { id: "remove", title: "2 · Remove it", required: true, done: removed ? true : false, detail: "The console checks what still needs the node and says where to move it; then, with the node's name typed, it is removed." },
    { id: "after", title: "3 · Afterwards", required: false, done: null, detail: "What is true now, and how to replace the machine." },
  ];
  const current = !chosen || !decided ? "node" : !removed ? "remove" : "after";

  return (
    <Wizard title="Remove a node" onClose={onClose} resumes>
      {session ? <ResumeOffer what={<>A node is being removed: <b>{session.argv[3] ?? "?"}</b></>} job={session} onContinue={() => restore(session)} onDecline={() => setDeclined(true)} decline="Remove another node" /> : null}
      <p className="small">{REMOVE_NODE_TEXT}</p>
      <ol className="setup">
        <StepRow s={stages[0]} open={current === "node"}>
          <DecideStep decided={decided} locked={job !== null} ready={!!chosen} hint="pick the node first" onContinue={() => setDecided(true)} onChange={() => setDecided(false)}>
            <div className="form">
            <label className="form-row">
              <span>node *</span>
              <select value={chosen} onChange={(e) => setNode(e.target.value)}>
                <option value="">{nodes.length ? "— pick the node" : "— reading the nodes…"}</option>
                {nodes.map((n) => (
                  <option key={n} value={n}>{n}</option>
                ))}
                {chosen && !nodes.includes(chosen) ? <option value={chosen}>{chosen} (removed)</option> : null}
              </select>
              <small className="muted">The site's nodes. Move what runs on it to another node first; the next step checks what is left and says where.</small>
            </label>
            {HOWS.map((h) => (
              <label key={h.id} className="form-check">
                <input type="radio" name="how" checked={how === h.id} onChange={() => setHow(h.id)} />
                <span>{h.label}</span> <small className="muted">{h.detail}</small>
              </label>
            ))}
            </div>
          </DecideStep>
        </StepRow>
        <StepRow s={stages[1]} open={current === "remove"}>
          {!chosen || !decided ? (
            <p className="muted small">Once the node and the way are chosen.</p>
          ) : (
            <RemoveStep key={`${chosen}:${how}`} node={chosen} how={how} asset={asset} setAsset={setAsset} job={job} setJob={setJob} resumed={resumed} onResult={setResult} />
          )}
        </StepRow>
        <StepRow s={stages[2]} open={current === "after"}>
          {removed && result ? <Afterwards node={chosen} how={how} result={result} onClose={onClose} /> : <p className="muted small">Once the node is removed.</p>}
        </StepRow>
      </ol>
    </Wizard>
  );
}

// The check as CheckStep reads it: noderemove.ts's findings in its output.
const readCheck = (node: string) => (job: Job): CheckOutcome =>
  job.state === "refused"
    ? { state: "failed", blockers: [], losses: [], ports: [], asset: null, record: null, retire: null, tail: [] }
    : parseCheck(job.output, node, job.state === "done" ? { exit: job.exit } : null);

// What the removal did, in the operator's words.
function Removed({ node, result }: { node: string; result: RemovalOutcome }) {
  return (
    <>
      <p><Tag level="pass" /> {node} is removed.</p>
      <ul className="findings">
        <li>It is out of the cluster{result.record === "archived" ? "; its node record is kept, archived" : " and gone from the site's nodes"}.</li>
        {result.parked.map((p) => (
          <li key={`${p.sw}:${p.port}`}>Switch port {p.port} on <Link to={switchTarget(p.sw).to}>{p.sw}</Link> is parked.</li>
        ))}
        {result.notParked.map((p) => (
          <li key={`${p.sw}:${p.port}`} className="readstate-warn">Switch port {p.port} on <Link to={switchTarget(p.sw).to}>{p.sw}</Link> could not be parked: park it there.</li>
        ))}
        {result.asset ? (
          <li>
            The machine's asset record <Link to={assetTarget(result.asset.key).to}>{result.asset.key}</Link>{" "}
            {result.asset.fate === "kept" ? (result.asset.where ? `is kept, still placed in ${result.asset.where}.` : "is kept, in stock.") : "is removed, with its place and cables."}
          </li>
        ) : null}
        {result.retired ? <li>Retired in the CMDB: {result.retired}.</li> : null}
        {result.assetTrouble ? <li className="readstate-warn">{result.assetTrouble}</li> : null}
        {result.warnings.map((w, i) => (
          <li key={i} className="muted">{w}</li>
        ))}
      </ul>
    </>
  );
}

// Stage 2: the check runs as the stage opens; then the machine's record, the
// typed name and the one button; then the removal's result.
function RemoveStep({ node, how, asset, setAsset, job, setJob, resumed, onResult }: {
  node: string; how: How; asset: AssetChoice; setAsset: (a: AssetChoice) => void;
  job: string | null; setJob: (id: string | null) => void; resumed: boolean; onResult: (r: RemovalOutcome | null) => void;
}) {
  const me = useMe();
  const [confirm, setConfirm] = useState("");
  const removal = (j: Job) => parseRemoval(phaseOutputs(j).apply);
  return (
    <div className="step">
    <CheckStep<CheckOutcome>
      argv={checkArgv(node, how)}
      applyArgv={removeArgv(node, how, assetFor(how, asset))}
      auto={!resumed}
      attach={job}
      parse={readCheck(node)}
      title={`Checking whether ${node} can be removed`}
      applying={`Removing ${node}${how === "erase" ? ": wiping its disks, powering it off" : how === "shutdown" ? ": powering it off" : ""}, then taking it out of the cluster. This takes a few minutes`}
      okLine={() => <>{node} can be removed{how === "lost" ? "" : ": nothing runs on it, nothing is kept on it"}. {how === "erase" ? "Its disks are wiped first, then it is powered off and removed." : how === "shutdown" ? "It is powered off, then removed; its disks keep their data." : "It is taken out of the cluster as a dead machine."}</>}
      blockedLine={<>{node} cannot be removed yet:</>}
      lossesLine={<p>Lost with it:</p>}
      choices={(outcome) => (<>{outcome.retire ? <p className="small">Retired in the CMDB: {outcome.retire}.</p> : null}{how === "lost" ? (
        <p className="small">The machine is gone for good, so its record is removed as well, with its place in the rack and its cables. Its history stays.</p>
      ) : outcome.asset ? (
        <>
          <p className="small">The machine's asset record, <Link to={assetTarget(outcome.asset.key).to}>{outcome.asset.key}</Link>:</p>
          {ASSET_CHOICES.map((c) => (
            <label key={c.id} className="form-check">
              <input type="radio" name="asset" checked={asset === c.id} onChange={() => setAsset(c.id)} />
              <span>{c.label}</span> <small className="muted">{c.detail}</small>
            </label>
          ))}
        </>
      ) : (
        <p className="small muted">No machine record is kept for {node}: nothing to keep or remove.</p>
      )}</>)}
      confirm={<TypedConfirm object={node} value={confirm} set={setConfirm} />}
      typed={confirm}
      confirmed={confirmMatches(confirm, node, node)}
      button={`Remove ${node}`}
      danger
      hint={!confirmMatches(confirm, node, node) ? `type ${node} exactly to enable the button` : null}
      me={me}
      onStarted={(id) => { setJob(id); if (!id) { onResult(null); setConfirm(""); } }}
      onDone={(ok, j) => {
        onResult(ok ? removal(j) : null);
        if (ok) reloadAll();
      }}
      result={(j) => <Removed node={node} result={removal(j)} />}
      failed={(j) => (j.state === "refused" ? `The removal was not started: ${j.refused}` : j.previewPhase?.stopped ? `${node} cannot be removed: something still needs it.` : `The removal of ${node} did not finish.`)}
      summary="What the removal printed"
    />
    </div>
  );
}

// Stage 3: what is true now, and where to go from here.
function Afterwards({ node, how, result, onClose }: { node: string; how: How; result: RemovalOutcome; onClose: () => void }) {
  const addNode = () => {
    onClose();
    requestOpen("add-node", null, {});
  };
  return (
    <ul className="findings">
      <li>{node} is gone from the cluster and from <Link to="/modules">Modules</Link>{result.record === "archived" ? " (listed as archived)" : ""}.</li>
      {result.parked.length ? (
        <li>
          Its switch {result.parked.length > 1 ? "ports are" : "port is"} parked:{" "}
          {result.parked.map((p, i) => (
            <span key={`${p.sw}:${p.port}`}>{i ? ", " : ""}port {p.port} on <Link to={switchTarget(p.sw).to}>{p.sw}</Link></span>
          ))}
          . Nothing plugged in there reaches the site's networks.
        </li>
      ) : (
        <li className="muted">No switch port was recorded for it, so none was parked.</li>
      )}
      {result.asset?.fate === "kept" ? (
        <li>The machine is <Link to={assetTarget(result.asset.key).to}>{result.asset.key}</Link>, {result.asset.where ? `still placed in ${result.asset.where}` : "in stock"}: its place and cables stay recorded, ready for its next role.</li>
      ) : result.asset?.fate === "removed" ? (
        <li>The machine's asset record {result.asset.key} is removed, with its place and cables: it has left the site. Its history stays.</li>
      ) : null}
      <li>
        To replace it, <button className="btn btn-small" onClick={addNode}>Add node</button>: a machine is recognised by its serial number or a network card, and a machine kept in stock is taken from there.
      </li>
      <li>Run the site update (<Link to="/setup">Setup</Link> › Update) so the modules' standby copies and fail-over spread over the nodes that remain.</li>
      {how === "shutdown" ? <li>It was powered off, not wiped: its disks still hold data. Wipe them before the machine leaves your hands.</li> : null}
      {how === "erase" ? <li>Its disks were wiped before it was removed: nothing of the site is on the machine.</li> : null}
      {how === "lost" ? <li>Restore what was lost with it from its backups, on the nodes that remain.</li> : null}
    </ul>
  );
}

export function RemoveNodeButton({ node }: { node?: string }) {
  const [open, setOpen] = useState<string | null | false>(false);
  useOpenedBy("remove-node", undefined, (v) => setOpen(typeof v.node === "string" ? v.node : null));
  if (!canOperate(useMe())) return null;
  return (
    <>
      {/* A plain button: the wizard itself carries the warnings (blockers,
          the typed name), and a red one on Day 2 drew the eye every visit. */}
      <button className="btn" onClick={() => setOpen(node ?? null)}>Remove a node…</button>
      {open !== false ? <RemoveNodeWizard onClose={() => setOpen(false)} node={open} /> : null}
    </>
  );
}
