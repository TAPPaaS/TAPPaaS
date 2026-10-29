// RemoveNode.tsx — Day 2's "Remove a node": a Proxmox node leaves the site
// for good. 1 which node, and how: powered off first (Proxmox removes a node
// only once it is off), wiped first, or lost (down for good); 2 the removal —
// site-manager node delete, whose preview lists every blocker (a guest on it,
// a replication job touching it, an HA rule naming it, the site's PBS) and
// the plan, and whose apply takes it out of the cluster and archives its
// pvehost instance; the node's name typed before Apply is the confirmation
// (--yes to the verb, which would otherwise ask on a terminal); 3 afterwards.

import { useEffect, useMemo, useState } from "react";
import { useJob, useRead } from "../api";
import { JobView, Step, StepView } from "../operate";
import { useOpenedBy } from "../opener";
import { JobSummary, SiteRead } from "../types";
import { Link, canOperate, useMe } from "../ui";
import { ResumeOffer, Wizard, jobLabel, jobLive, useJobSession } from "../wizard";
import { viewLink } from "../physical/views";
import { StepRow } from "./Setup";

// What the activity is, on Day 2's card and at the top of the form.
export const REMOVE_NODE_TEXT = "Takes a physical machine out of the cluster for good: refused while it still holds a guest, a replication job, an HA rule or the site's PBS; then it is removed from Proxmox and its node record archived. The other nodes are untouched.";

export type How = "shutdown" | "erase" | "lost";
export const HOWS: { id: How; label: string; detail: string }[] = [
  { id: "shutdown", label: "power it off, then remove it", detail: "The usual way: Proxmox removes a node only once it is off. Its disks keep their data." },
  { id: "erase", label: "wipe its disks, power it off, then remove it", detail: "Every ZFS pool destroyed, every disk and the boot disk wiped, its boot entry deleted: the machine keeps nothing. For a machine that leaves the building." },
  { id: "lost", label: "it is down for good", detail: "A dead machine: the guests the cluster still places on it are lost with it (their configs are saved on the mothership first), replication jobs touching it are removed, HA rules naming it stay for a replacement under the same name." },
];

export function RemoveNodeWizard({ onClose, node: preset }: { onClose: () => void; node?: string | null }) {
  const me = useMe();
  const site = useRead<SiteRead>("site").env?.data;
  const nodes = (site?.nodes ?? []).map((n) => n.name);
  const [node, setNode] = useState(preset ?? "");
  const [how, setHow] = useState<How>("shutdown");
  const [job, setJob] = useState<string | null>(null);
  const [done, setDone] = useState<boolean | null>(null);
  // Closed while node delete ran, or within the hour after: its job is found
  // again (the node may be gone from the site by then: it is the job's).
  const [resumed, setResumed] = useState(false);
  const [declined, setDeclined] = useState(false);
  const session = useJobSession("site-manager", "node delete", () => true, job === null && !declined);
  const followed = useJob(resumed ? job : null);
  useEffect(() => {
    if (followed?.state === "done") setDone(followed.exit === 0);
  }, [followed?.state]);
  const restore = (j: JobSummary) => {
    setNode(j.argv[3] ?? "");
    setHow(HOWS.find((h) => j.argv.includes(`--${h.id}`))?.id ?? "shutdown");
    setJob(j.id);
    setResumed(true);
  };
  const chosen = nodes.includes(node) || resumed ? node : "";

  const remove: Step = useMemo(
    () => ({
      title: `site-manager node delete ${chosen || "<node>"} --${how}`,
      bin: "site-manager",
      verb: "node delete",
      fixed: chosen ? [chosen] : [],
      // Offered: --remove (the record deleted rather than archived). The way
      // (--shutdown, --erase, --lost) is stage 1's choice, set below.
      only: ["--remove"],
      // The console's typed name before Apply is the confirmation the script
      // would otherwise ask for on a terminal: --yes is always given, not offered.
      initial: { [`--${how}`]: true, "--yes": true },
      hide: ["--yes", "--shutdown", "--erase", "--lost", "--config-only"],
      blocked: chosen ? undefined : "pick the node first",
      note: (
        <>
          <p>The preview says what still holds {chosen || "the node"} — a guest, a replication job, an HA rule, the site's PBS — with what moves each, and the plan. Nothing changes until Apply, and Apply is refused while anything holds it.</p>
          <p>Apply {how === "lost" ? "removes the dead node from the cluster" : how === "erase" ? "wipes the node's disks, powers it off and removes it from the cluster" : "powers the node off and removes it from the cluster"}: pvecm delnode, its directory under /etc/pve, its storage entries and known_hosts; then its pvehost instance is archived (listed as archived on the Modules page, its config kept under config/archived) and it leaves site.json. Tick --remove to delete that record instead, so the node disappears from the list.</p>
        </>
      ),
    }),
    [chosen, how],
  );

  const stages = [
    { id: "node", title: "1 · The node, and how", required: true, done: chosen ? true : false, detail: "Which node leaves, and whether it is powered off first, wiped first, or already dead." },
    { id: "remove", title: "2 · Remove it", required: true, done: done ?? (job ? null : false), detail: "The preview lists every blocker and the plan; Apply, with the node's name typed, takes it out of the cluster." },
    { id: "after", title: "3 · Afterwards", required: false, done: done ? null : null, detail: "HA and replication re-folded, the machine taken out of the physical view." },
  ];
  const current = !chosen ? "node" : !done ? "remove" : "after";

  return (
    <Wizard title="Remove a node" onClose={onClose} running={followed && jobLive(followed) ? [jobLabel(followed)] : []} resumes>
      {session ? <ResumeOffer what={<>A node is being removed: <b>{session.argv[3] ?? "?"}</b></>} job={session} onContinue={() => restore(session)} onDecline={() => setDeclined(true)} decline="Remove another node" /> : null}
      <p className="small">{REMOVE_NODE_TEXT}</p>
      <ol className="setup">
        <StepRow s={stages[0]} open={current === "node"}>
          <div className="form">
            <label className="form-row">
              <span>node *</span>
              <select value={chosen} disabled={job !== null} onChange={(e) => setNode(e.target.value)}>
                <option value="">{nodes.length ? "— pick the node" : "— reading the nodes…"}</option>
                {nodes.map((n) => (
                  <option key={n} value={n}>{n}</option>
                ))}
                {chosen && !nodes.includes(chosen) ? <option value={chosen}>{chosen} (removed)</option> : null}
              </select>
              <small className="muted">The site's nodes. Move what runs on it first (a module's node or HANode; the PBS with backup-manager placement): the preview in stage 2 lists what is left.</small>
            </label>
            {HOWS.map((h) => (
              <label key={h.id} className="form-check">
                <input type="radio" name="how" checked={how === h.id} disabled={job !== null} onChange={() => setHow(h.id)} />
                <span>{h.label}</span> <small className="muted">{h.detail}</small>
              </label>
            ))}
          </div>
        </StepRow>
        <StepRow s={stages[1]} open={current === "remove"}>
          {!chosen ? (
            <p className="muted small">Once the node is picked.</p>
          ) : resumed && job ? (
            <JobView id={job} label="site-manager node delete" />
          ) : (
            <StepView key={`${chosen}:${how}`} step={remove} me={me} onApplied={setJob} onDone={(ok) => setDone(ok)} />
          )}
        </StepRow>
        <StepRow s={stages[2]} open={current === "after"}>
          {done ? (
            <ol>
              <li>Run the site update (Setup › Update, or <span className="mono">site-manager update</span>) so HA and replication are folded over the nodes that remain.</li>
              <li>Take the machine out of the physical view: <Link to={viewLink("rack")}>the rack view</Link>, where its device record is removed or the machine moved elsewhere.</li>
              {how !== "erase" ? <li>Its disks still hold data: wipe them before the machine leaves your hands.</li> : null}
            </ol>
          ) : (
            <p className="muted small">Once the node is removed.</p>
          )}
        </StepRow>
      </ol>
    </Wizard>
  );
}

export function RemoveNodeButton({ node }: { node?: string }) {
  const [open, setOpen] = useState<string | null | false>(false);
  useOpenedBy("remove-node", undefined, (v) => setOpen(typeof v.node === "string" ? v.node : null));
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn btn-danger" onClick={() => setOpen(node ?? null)}>Remove a node…</button>
      {open !== false ? <RemoveNodeWizard onClose={() => setOpen(false)} node={open} /> : null}
    </>
  );
}
