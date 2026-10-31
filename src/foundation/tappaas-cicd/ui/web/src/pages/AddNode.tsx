// AddNode.tsx — adding a node as a guided sequence (Setup's step rows): what
// each stage does is said before it runs, and what the operator must do by
// hand is said where it is needed (ADR-037 D4). 0 prepare the boot medium: the
// netboot assets and the installer stick image on the mothership, built when
// missing or stale (site-manager node media prepare); then, for a machine
// that cannot network-boot, the stick — written on a client machine from the
// image, or by a node into a stick plugged into it, the image streamed from
// the mothership (site-manager node usb write); 1 declare the node — where it
// is cabled first, then its MAC and boot disks, each blank its default
// (site-manager node add: one job that registers its install answer,
// opens the boot window and waits for it); 2 boot the machine from the network
// or the USB stick, by hand; 3 the install and the join, watched live (the provisioning
// registration, the PXE window, the cluster, the node's pvehost record, and the
// job's own output); 4 its data pools, proposed from its free disks (node
// storage add); 5a a second lan port — the bond, its switch port, then the
// failover test (node network set, node network test); 5b its WAN port, for a
// node that may carry the firewall (pages/NodeUplinks.tsx); 6 the node in the
// physical view. Stage 1 is the form and one button: the job's dry run, its
// status line with Stop and its output show there; once the change applies
// the stage is done and keeps one line saying where the job is.

import { useEffect, useMemo, useRef, useState } from "react";
import { applyNowJob, refreshRead, reloadAll, useJob, useRead, useVerb } from "../api";
import { buildArgv } from "../argv";
import { JobOutput, JobStatusLine, Output, phaseOutputs } from "../jobs";
import { OperateButton, Step, StepForm, StepView, Values, useStepValues } from "../operate";
import { useOpenedBy } from "../opener";
import { Job, JobSummary, SiteRead, StorageInventory, Topology } from "../types";
import { ZoneRead } from "./Zones";
import { viewLink } from "../physical/views";
import { AddNodeStage, KeyStore, NodeProgress, STAGE_NUMBER, addNodeJoined, addNodeStage, addNodeUnderway, declaredLine, dismissJob, dismissedJobs, latestNodeAdd, manualTrunkText, nodeAddOngoing, nodeTrunkVlans, setupFromOutput, switchPortChoices, writeProgress } from "../nodeadd";
import { Wizard, jobLabel, jobLive, useReportJob } from "../wizard";
import { NodePools } from "../physical/nodepools";
import { LanUplink, WanUplink } from "./NodeUplinks";
import { Dot, Link, Tag, canOperate, useMe } from "../ui";
import { UsbStickPicker, gb } from "../usbsticks";
import { StepRow } from "./Setup";

// site-manager node media --json (reads.ts BootMedia).
interface BootMedia {
  staged: boolean;
  current: boolean;
  source: string;
  sourcePresent: boolean;
  stickImage: { path: string; present: boolean; size: number; modified: string | null };
  xorriso: boolean;
  ready: boolean;
  problems: string[];
  prepare: { argv: string[]; minutes: string } | null;
}

// The installer stick image on the mothership (site-manager node media).
const IMAGE = "/var/lib/tappaas-pxe/tappaas-usb.iso";

// The firewall reserves a management address and a name for tappaas1..9 only:
// tappaasN is 10.0.0.(9+N).
const NAME = /^tappaas([1-9])$/;
export const nodeAddress = (name: string): string | null => {
  const m = NAME.exec(name);
  return m ? `10.0.0.${9 + Number(m[1])}` : null;
};
export function firstFreeNode(known: string[]): string {
  for (let i = 1; i <= 9; i++) if (!known.includes(`tappaas${i}`)) return `tappaas${i}`;
  return "";
}

// In the order the operator has the answers (ADR-037 D4): where it is cabled,
// its MAC, its boot disks; every one may stay blank, and says what blank does.
const DECLARE_OPTIONS = ["--asset", "--switch-port", "--mac", "--boot-disk", "--boot-mirror", "--ttl", "--no-reboot"];
// Each in the operator's words: no flags, no file names.
const DECLARE_LABELS: Record<string, string> = {
  "--asset": "the machine", "--switch-port": "switch port", "--mac": "MAC address", "--boot-disk": "boot disk",
  "--boot-mirror": "mirror disk", "--ttl": "boot window (seconds)", "--no-reboot": "no restart after its first update",
};
const DECLARE_TEXTS: Record<string, string> = {
  "--asset": "The machine as the asset register records it: a server in stock or placed, in no role. Its recorded cable and MAC fill in where it is cabled. Blank: recognised once it has joined, or recorded as new.",
  "--switch-port": "The switch and port the machine is cabled to. On a switch TAPPaaS manages, the port is set up for a node and the machine's MAC is learned there when it boots the installer. On a switch you manage yourself, leave it at none and set the port up by hand (above).",
  "--mac": "The MAC address of the cabled network card, from the machine's label, its BIOS or its BMC. Blank: learned on the switch port; with no switch port either, the first machine that asks for an install answer while the boot window is open gets this node's, so keep the window short.",
  "--boot-disk": "The disk Proxmox is installed on (wiped): its model, size or serial, when that names one disk. Blank: the smallest SSD or NVMe disk, and both when the smallest two are alike (mirrored). ask: chosen on the machine's own screen.",
  "--boot-mirror": "A second disk to mirror the boot disk onto, named the same way. Blank: a mirror only when the boot disk names two disks alike. none: one disk.",
  "--ttl": "How long the boot window stays open (default: two hours).",
  "--no-reboot": "Keep the node running on the installer's kernel. By default it restarts into its newest kernel after its first update, before it takes any guests, when the cluster can spare it.",
};

function Check({ ok, label, detail }: { ok: boolean | null; label: string; detail?: string }) {
  return (
    <li>
      <Dot level={ok === true ? "pass" : ok === false ? "skip" : "unknown"} /> {label}
      {detail ? <span className="muted small"> — {detail}</span> : null}
    </li>
  );
}

// The browser's storage for the dismissed adds, when it has one.
const storage = (): KeyStore | null => {
  try {
    return typeof window !== "undefined" ? window.localStorage : null;
  } catch {
    return null;
  }
};

// A node being added (nodeadd.ts nodeAddOngoing), found again from the
// records: the newest node add job, the node's progress, then — once it has
// joined — its pools. `stage` is where the wizard stands.
export interface AddNodeSession {
  name: string;
  job: JobSummary;
  stage: AddNodeStage;
  dataPool: boolean | null;
}

// `enabled`: false reads nothing (the wizard has its job attached already).
export function useAddNodeSession(enabled = true, dismissed: string[] = []): AddNodeSession | null {
  const jobs = useRead<{ jobs: JobSummary[] }>(enabled ? `jobs?bin=site-manager&verb=${encodeURIComponent("node add")}&limit=10` : null, 15_000).env?.data?.jobs ?? [];
  const run0 = latestNodeAdd(jobs);
  const run = run0 && dismissed.includes(run0.job.id) ? null : run0;
  const name = run?.name ?? null;
  const progress = useRead<NodeProgress>(name ? `nodes/${encodeURIComponent(name)}/progress` : null, 15_000).env?.data ?? null;
  const joined = addNodeJoined(progress);
  const inv = useRead<StorageInventory>(joined ? "storage" : null).env?.data;
  const dataPool = inv ? (inv.nodes.find((n) => n.name === name)?.pools ?? []).some((p) => p.name !== "rpool") : null;
  if (!run || !nodeAddOngoing(run.job, Date.now(), { progress, dataPool })) return null;
  const stage = addNodeStage({ job: true, jobLive: jobLive(run.job), progress, pooled: dataPool === true, lan: false, wan: false });
  return { name: run.name, job: run.job, stage, dataPool };
}

// "tappaas4 — stage 3, job 20261028… running": how a session is named where it is offered.
export function sessionText(s: AddNodeSession): string {
  return `${s.name} — stage ${STAGE_NUMBER[s.stage]}${jobLive(s.job) ? `, job ${s.job.id} ${s.job.state}` : ""}`;
}

// `prefill`: what the assistant opened it with (open_console add-node): the
// node's name, and node add's options by name (mac, boot-disk, …).
// `resume`: open straight into the node being added (Setup's Continue).
export function AddNodeWizard({ onClose, prefill, resume }: { onClose: () => void; prefill?: Values | null; resume?: boolean }) {
  const me = useMe();
  const site = useRead<SiteRead>("site").env?.data;
  const [typed, setName] = useState<string | null>(typeof prefill?.name === "string" ? prefill.name : null);
  const options = useMemo(() => {
    // The wizard installs; adopting a hand-installed Proxmox is the CLI's only.
    const { name: _n, adopt: _a, ...rest } = prefill ?? {};
    return Object.keys(rest).length ? rest : undefined;
  }, [prefill]);
  const [job, setJob] = useState<string | null>(null);
  const [ended, setEnded] = useState<boolean | null>(null);
  const [lanDone, setLanDone] = useState(false);
  const [wanDone, setWanDone] = useState(false);
  const [pooled, setPooled] = useState(false);
  const [skipPools, setSkipPools] = useState(false);
  // A node already being added (its job running, or joined and unfinished):
  // offered on open, restored on Continue. Looked for until a job is attached.
  const [dismissed, setDismissed] = useState<string[]>(() => dismissedJobs(storage()));
  const session = useAddNodeSession(job === null, dismissed);
  const [resumed, setResumed] = useState(false);
  const [declined, setDeclined] = useState(false);
  const restore = (s: AddNodeSession) => {
    setName(s.name);
    setJob(s.job.id);
    setResumed(true);
    if (s.dataPool) setPooled(true);
  };
  useEffect(() => {
    if (resume && session && job === null && !declined) restore(session);
  }, [resume, session?.job.id]);
  // The name proposed is the next free one: not a node of the site, nor the one being added.
  const known = (site?.nodes ?? []).map((n) => n.name);
  const name = typed ?? firstFreeNode(session ? [...known, session.name] : known);
  const busyName = session && jobLive(session.job) && job === null ? session.name : null;
  // Stage 0: the installer stick written by a node (site-manager node usb write).
  const [stickNode, setStickNode] = useState(known[0] ?? "tappaas1");
  const [stickDevice, setStickDevice] = useState("");
  const [stickWritten, setStickWritten] = useState(false);
  const [prepared, setPrepared] = useState(false);
  const [skipMedium, setSkipMedium] = useState(false); // Continue: a network boot, or a stick made earlier
  // The boot medium on the mothership, read again every ten seconds while the
  // wizard is open: a prepare that ran shows up without a reload.
  const mediaRead = useRead<BootMedia>("media", 10_000);
  const media = mediaRead.env?.data ?? null;
  const valid = NAME.test(name);
  // Read from the moment the name is valid: a wizard reopened while the job
  // runs (or for a node already joined) shows where it stands.
  const progress = useRead<NodeProgress>(valid ? `nodes/${encodeURIComponent(name)}/progress` : null, 10_000).env?.data ?? null;
  const underway = addNodeUnderway({ job: job !== null, progress });
  const running = useJob(job);
  // Stage 2 opens the moment the declare applies: until node add says the machine
  // can boot, it says it is getting ready, from the job's own output.
  const live = running?.state === "running" || running?.state === "queued";
  const setup = setupFromOutput(running?.output ?? "");
  // The records can say so first: registered, and the boot window open.
  const bootReady = setup.ready || (progress?.registration === "pending" && progress.pxe.enabled === true);
  const settingUp = live && !bootReady;
  const joined = addNodeJoined(progress);
  const endedOk = ended ?? (running?.state === "done" ? running.exit === 0 : null);

  const topo = useRead<Topology>("topology").env?.data;
  // The free ports and machines are read fresh: the cached topology is up to
  // five minutes old, and a verb run in a shell does not refresh it.
  useEffect(() => {
    void refreshRead("topology");
    const timers = [3000, 10000, 30000].map((ms) => setTimeout(reloadAll, ms));
    return () => timers.forEach(clearTimeout);
  }, []);
  const zones = useRead<ZoneRead[]>("zones").env?.data ?? [];
  const ports = useMemo(() => switchPortChoices(topo?.switches ?? [], name), [topo, name]);
  // The server assets the machine could be (ADR-040 D8): in stock or placed, in no role.
  const assets = useMemo(() => (topo?.positions?.assets ?? []).filter((a) => a.kind === "server" && !a.role && (a.stage === "stock" || a.stage === "placed")), [topo]);
  const trunk = manualTrunkText(nodeTrunkVlans(zones));
  const declare: Step = useMemo(
    () => ({
      title: `Declare ${name || "the node"}`,
      bin: "site-manager",
      verb: "node add",
      fixed: valid ? [name] : [],
      only: DECLARE_OPTIONS,
      labels: DECLARE_LABELS,
      descriptions: DECLARE_TEXTS,
      placeholders: {
        "--asset": "blank: recognised by its serial number or MAC once it has joined, or recorded as new",
        "--switch-port": "none: the port is configured by hand",
        "--mac": "e.g. 58:47:ca:7a:12:34 — blank: learned on the switch port; with none, the first machine that asks",
        "--boot-disk": "blank: the smallest SSD/NVMe",
        "--boot-mirror": "blank: mirrored only when two disks alike match · none: one disk",
        "--ttl": "7200",
      },
      // The free ports on the switches TAPPaaS programs (and this node's own).
      choices: { "--switch-port": ports.map((c) => c.value), "--asset": assets.map((a) => a.name) },
      suggestNotes: {
        "--switch-port": Object.fromEntries(ports.map((c) => [c.value, c.label])),
        "--asset": Object.fromEntries(assets.map((a) => [a.name, [a.displayName, a.model, a.serial ? `serial ${a.serial}` : null, a.stage].filter(Boolean).join(" · ")])),
      },
      // The node joins with no WAN port and its one detected lan port; stage 5
      // declares the lan ports and the WAN port (node network set). --yes only
      // skips node add's lan-port question, which --no-wan skips already.
      initial: { "--yes": true, "--no-wan": true },
      hide: ["--yes"],
      prefill: options,
      // A second node add for the node whose job runs could reinstall it.
      blocked: busyName === name ? `${name} is being added already (job ${session!.job.id}): reopen the wizard to continue it, or name another node` : job !== null || (valid && !known.includes(name)) ? undefined : "give the node a new name first",
      note: (
        <>
          <p><b>The machine</b> — as recorded in the asset register. Pick it when it was recorded before (bought, racked, cabled, or kept in stock when a node was removed): its recorded cable and MAC fill in below. Blank: once the node has joined, the machine is recognised among the free servers by its serial number or a network card's MAC, and when none matches a new record is made for it (srv-NN), to be placed in stage 6. Either way, what the machine says of itself — serial number, maker, model, its network cards' MACs — is added to its record where the record lacks it.</p>
          <p><b>Where it is cabled</b> — one of two:</p>
          <ul>
            <li><b>Connected to a TAPPaaS-managed switch:</b> pick its port (the free ones are listed). TAPPaaS makes it a node trunk and learns the machine's MAC there; the MAC field may stay blank.</li>
            <li><b>A self-managed switch:</b> set the port as {trunk} and leave the switch port at none. Give the MAC (from the machine's label, its BIOS or its BMC); left blank, the first machine that asks for an install answer while the boot window is open gets this node's, so keep other machines from booting the installer meanwhile.</li>
          </ul>
          <p><b>Boot disk:</b> specify the boot disk and optionally a mirror disk. Default: the installer takes the smallest SSD or NVMe disk, and both when the smallest two are the same model and size (mirrored); when nothing matches, the node's own screen asks.</p>
          <p>Its data pools come after the join (stage 4), from the disks it really has.</p>
          <p>When applied, TAPPaaS records the node's install answer on the mothership and opens its network-boot window; stage 2 says how to boot it, from the network or from the USB stick image (the same for every node).</p>
        </>
      ),
      render: () => (
        <label className="form-row">
          <span>node name *</span>
          <input type="text" value={name} onChange={(e) => setName(e.target.value.trim())} disabled={job !== null} />
          {name && !valid ? <small className="ff-error">tappaas1 to tappaas9: the firewall reserves a management address and name for exactly those</small> : null}
          {valid && known.includes(name) ? <small className="ff-error">{name} is already a node of this site</small> : null}
          <small className="muted">
            The Proxmox host name; {valid ? <>{name} gets the management address <span className="mono">{nodeAddress(name)}</span>. </> : null}Nodes today: {known.join(", ") || "—"}.
          </small>
        </label>
      ),
    }),
    [name, valid, options, ports, assets, trunk, known, job, busyName],
  );
  // Stage 0: the medium built on the mothership when it is missing or stale.
  const prepare: Step = useMemo(
    () => ({
      title: "Prepare the boot medium",
      bin: "site-manager",
      verb: "node media prepare",
      fixed: [],
      only: ["--force"],
      note: media?.prepare
        ? `Builds the network-boot files and the installer stick image on the mothership (${media.prepare.minutes}). There is nothing to try first: the preview shows what will run.`
        : "Builds the network-boot files and the installer stick image on the mothership. There is nothing to try first: the preview shows what will run.",
    }),
    [media?.prepare],
  );
  const writeStick: Step = useMemo(
    () => ({
      title: `Write the installer stick${stickDevice ? ` in ${stickDevice}` : ""} on ${stickNode}`,
      bin: "site-manager",
      verb: "node usb write",
      fixed: stickDevice ? [stickNode, stickDevice] : [stickNode],
      only: [],
      // The CLI's guard against erasing a stick by accident; here the preview
      // and Apply are that confirmation, so it is always given and not offered.
      initial: { "--yes": true },
      hide: ["--yes"],
      blocked: !stickDevice ? "pick the stick first" : media && !media.stickImage.present ? "the installer stick image is not built yet: prepare the medium first" : undefined,
      progress: writeProgress,
      note: `The mothership copies the installer stick image (the same for every node) onto ${stickDevice || "the stick"} in ${stickNode}, erasing it, then ejects it: a minute or two. The node needs nothing in advance. There is nothing to try first: the preview shows what will run.`,
    }),
    [stickNode, stickDevice, media?.stickImage.present],
  );
  const mediaReady = media?.ready ?? null;

  const steps = [
    // Optional, and open until the operator writes a stick or skips: a
    // machine that network-boots needs no stick (then the medium must only be
    // there, which stage 1's job checks again).
    { id: "medium", title: "0 · Prepare boot medium", required: false, done: stickWritten || skipMedium ? true : mediaReady === false && !prepared ? false : null, detail: "The network-boot files and the installer stick image on the mothership, built once per Proxmox version and checked here; then, for a machine that cannot network-boot, the stick. Continue when the machine network-boots or you have a stick already." },
    { id: "declare", title: "1 · Declare the node", required: true, done: job !== null, detail: "Its name, where it is cabled, its initial ethernet port and boot disks, and a few other options. Declare records its install answer on the mothership and opens the boot window; stage 2 says how to boot the machine." },
    { id: "boot", title: "2 · Boot the machine: from the network (PXE) or a USB stick (by hand)", required: true, done: progress && underway ? progress.registration === "answered" || progress.inCluster === true : null, detail: "Power it on and boot it once from the network or from the installer stick; the mothership answers with the installer either way." },
    { id: "wait", title: "3 · Install and join (automatic)", required: true, done: underway ? joined : null, detail: "Proxmox installs onto its boot disk(s), the node joins the cluster, is patched and restarted, and is recorded as a node of the site, its machine in the asset register." },
    { id: "storage", title: "4 · Define data pools", required: false, done: pooled ? true : null, detail: "Until it has one, its guests go on its boot disk. Proposed from its free disks." },
    { id: "lan", title: "5a · A second lan port (bond, then the failover test)", required: false, done: lanDone ? true : null, detail: "The lan carries management, the cluster link and every guest: a second port, paired with the first, keeps the node reachable when one fails. Its switch port is set up with it, and a test pulls one to prove it." },
    { id: "wan", title: "5b · The WAN port", required: false, done: wanDone ? true : null, detail: "Only for a node that may carry the firewall: the port, and optionally the switch port, for its WAN." },
    { id: "done", title: "6 · Place the machine correctly in the physical view", required: false, done: joined, detail: "Its machine — the one picked in stage 1, or the one recognised or recorded for it (srv-NN) — and its location, room and rack: where the machine actually stands." },
  ];
  const current = addNodeStage({ job: job !== null, jobLive: jobLive(running), progress, pooled: pooled || skipPools, lan: lanDone, wan: wanDone });
  // Closing mid-way: the install job keeps running, and reopening finds the
  // node again (useAddNodeSession) while it is unfinished.
  const left = underway && current !== "done" ? `${name} is at stage ${STAGE_NUMBER[current]}; reopen to continue.` : null;
  const offer = session && job === null && !declined && !resume ? session : null;

  return (
    <Wizard title="Add a node" onClose={onClose} running={running && jobLive(running) ? [jobLabel(running)] : []} progress={left} resumes>
      {offer ? (
        <div className="readstate readstate-warn wizard-resume">
          <span>A node is being added: <b>{sessionText(offer)}</b>.</span>
          <button className="btn btn-small btn-primary" onClick={() => restore(offer)}>Continue {offer.name}</button>
          <button className="btn btn-small" onClick={() => setDeclined(true)}>Add another node</button>
          <button className="btn btn-small" title="Forget this add: it is not offered again" onClick={() => setDismissed(dismissJob(storage(), offer.job.id))}>Done with it</button>
        </div>
      ) : null}
      <p className="small">
        Adding a new physical machine as a Proxmox node of this site. This includes defining its connectivity and its boot disk, configuring it in the cluster, and setting up its data pools. Nothing changes until you Declare the node in stage 1.
      </p>
      <ol className="setup">
        {/* Open while the medium is not ready; collapsed once it is (most machines network-boot and need nothing more). */}
        <StepRow s={steps[0]} open={!stickWritten && !skipMedium}>
          <p className="small">Every new node installs from one medium on the mothership: a machine that network-boots (PXE) fetches it from there, a machine that cannot boots the installer stick made from the same image. The cicd install built it once; it is built again here when it is missing, from before this version, or wanted for a new Proxmox version.</p>
          {media ? (
            <ul className="plain checks">
              <Check ok={media.staged && media.current} label="network-boot files on the mothership" detail={media.staged ? (media.current ? "in place, current" : "in place, but from before this version's installer") : "not in place"} />
              <Check ok={media.stickImage.present} label="installer stick image" detail={media.stickImage.present ? `${gb(media.stickImage.size)}, ${media.stickImage.modified ?? ""}` : "not built"} />
              {!media.xorriso ? <Check ok={false} label="the stick-image builder on the mothership" detail="not installed: the stick image cannot be built until the mothership's next OS update brings it" /> : null}
            </ul>
          ) : (
            <p className="muted small">{mediaRead.env?.error || mediaRead.failure ? <><Dot level="fail" /> the boot medium could not be read: {mediaRead.env?.error ?? mediaRead.failure}</> : "reading the boot medium…"}</p>
          )}
          {media && (!media.ready || prepared) ? (
            media.prepare || prepared ? (
              <StepView key={media.prepare?.argv.join(" ") ?? "ready"} step={prepare} me={me} onDone={(ok) => { if (ok) { setPrepared(true); mediaRead.reload(); } }} />
            ) : (
              <p className="small"><Dot level="warn" /> Nothing can be built here until the stick-image builder is on the mothership.</p>
            )
          ) : null}
          <p className="small" style={{ marginTop: "1em" }}><b>The installer stick</b> — only for a machine that cannot network-boot. One image for every node: the stick fetches the node's own answer from the mothership once stage 1's job runs. Two ways to write it:</p>
          <div className="two">
            <div className="explain">
              <p><b>By a TAPPaaS node</b> — a stick in a free USB port of an existing node; the mothership is a VM with no USB port, so it writes through the node</p>
              <div className="form">
                <UsbStickPicker nodes={known.length ? known : [stickNode]} node={stickNode} setNode={setStickNode} device={stickDevice} setDevice={setStickDevice} disabled={stickWritten} />
              </div>
              {stickWritten ? (
                <p className="small"><Dot level="pass" /> The installer stick is written and ejected: pull {stickDevice} out of {stickNode}. It boots the new machine in stage 2.</p>
              ) : null}
              <StepView key={`${stickNode}:${stickDevice}:${media?.stickImage.present ? 1 : 0}`} step={writeStick} me={me} onDone={(ok) => ok && setStickWritten(true)} />
            </div>
            <div className="explain">
              <p><b>On your own machine</b> — copy the image from the mothership, then write it to a stick (everything on the stick is erased).</p>
              <p><b>Linux</b></p>
              <ol>
                <li><span className="mono">scp tappaas@tappaas-cicd.mgmt.internal:{IMAGE} .</span></li>
                <li>Find the stick: <span className="mono">lsblk</span> (a disk of the stick's size, e.g. <span className="mono">sdb</span>; unmount anything mounted from it).</li>
                <li><span className="mono">sudo dd if=tappaas-usb.iso of=/dev/sdb bs=4M status=progress conv=fsync</span>, then <span className="mono">sudo eject /dev/sdb</span>.</li>
              </ol>
              <p><b>macOS</b></p>
              <ol>
                <li>In Terminal: <span className="mono">scp tappaas@tappaas-cicd.mgmt.internal:{IMAGE} .</span></li>
                <li>Find the stick: <span className="mono">diskutil list</span> (an external disk of the stick's size, e.g. <span className="mono">disk4</span>), then <span className="mono">diskutil unmountDisk /dev/disk4</span>.</li>
                <li><span className="mono">sudo dd if=tappaas-usb.iso of=/dev/rdisk4 bs=4m status=progress</span>, then <span className="mono">diskutil eject /dev/disk4</span>. Ignore "The disk you inserted was not readable" if macOS shows it.</li>
              </ol>
              <p><b>Windows</b></p>
              <ol>
                <li>In PowerShell: <span className="mono">scp tappaas@tappaas-cicd.mgmt.internal:{IMAGE} .</span> (scp comes with Windows 10 and later).</li>
                <li>Write it with <a href="https://rufus.ie" target="_blank" rel="noreferrer">Rufus</a> or <a href="https://etcher.balena.io" target="_blank" rel="noreferrer">balenaEtcher</a>: pick the stick and tappaas-usb.iso, and in Rufus choose <b>DD image mode</b> when asked.</li>
              </ol>
              <p className="small">balenaEtcher works the same way on Linux and macOS, for a stick without the terminal.</p>
            </div>
          </div>
          {!stickWritten && !skipMedium ? (
            <div className="actions">
              <button className="btn btn-primary" onClick={() => setSkipMedium(true)}>Continue →</button>
              <span className="muted small">For a network boot, or with a stick you already have, nothing more is needed here.</span>
            </div>
          ) : null}
        </StepRow>
        <StepRow s={steps[1]} open={current === "declare"}>
          {/* Continued: the job was applied before this pop-up; its form is not offered again. */}
          {resumed ? (
            running ? <DeclaredLine name={name} job={running} progress={progress} /> : <p className="muted small">reading job {job}…</p>
          ) : (
            <DeclareStep step={declare} name={name} progress={progress} onApplied={setJob} onDone={(ok) => setEnded(ok)} />
          )}
        </StepRow>
        <StepRow s={steps[2]} open={current === "boot"}>
          {settingUp ? <p className="readstate readstate-warn">Getting ready — do not boot yet. Stage 1's job is on: {setup.step ?? "starting"}…</p> : null}
          {live && bootReady && progress?.registration !== "answered" ? <p className="readstate">Ready: boot the machine now.{setup.port ? ` ${setup.port}.` : ""}</p> : null}
          <p className="small">Once stage 1's job is running, boot the machine one of two ways. Either way the installer asks the mothership for its answer over the network, so the machine must be cabled as stage 1 says; only if the boot-disk fields match no disk does the node's screen ask for one (from the network; a stick stops with the list of the machine's disks instead).</p>
          <div className="two">
            <div className="explain">
              <p><b>Network boot (PXE)</b></p>
              <ol>
                <li>In the firmware (BIOS/UEFI setup), enable <b>network boot (PXE) over IPv4, UEFI</b> on the cabled port.</li>
                <li>Power on and pick network boot once — the one-time boot menu (often F11 or F12) — or put network first in the boot order for this one boot.</li>
                <li>If you changed the boot order, set the disk first again after the install has started: the window closes on its own, and a second network boot finds nothing to install.</li>
              </ol>
            </div>
            <div className="explain">
              <p><b>USB stick</b> — for a machine that cannot network-boot</p>
              <ol>
                <li>The stick written in stage 0 (by a node, or from the image copied to your own machine).</li>
                <li>Power on and boot from the stick once — the one-time boot menu.</li>
              </ol>
            </div>
          </div>
          {progress && underway ? (
            <ul className="plain checks">
              <Check ok={progress.registration !== "none" ? true : settingUp ? null : false} label="registered for a network install" detail={progress.registration === "pending" ? "waiting for the machine to ask" : progress.registration === "answered" ? "the installer has fetched its answer" : settingUp ? "being registered…" : "no registration (the job has not reached it, or it ended)"} />
              <Check ok={progress.pxe.enabled || bootReady ? true : settingUp ? null : false} label="the network-boot window on the mothership" detail={progress.pxe.enabled || bootReady ? "open" : settingUp ? "being opened…" : "closed"} />
            </ul>
          ) : underway ? <p className="muted small">reading the provisioning state…</p> : null}
        </StepRow>
        <StepRow s={steps[3]} open={current === "wait"}>
          <div className="explain">
            <p>
              Nothing to do here but wait, typically 15–25 minutes: the installer writes Proxmox to the boot disk(s) and restarts, the job waits for the node at its address, checks it and joins it to the cluster, records it as a node of the site and its machine in the asset register (recognised, or recorded as new), brings it up to date with the other nodes and restarts it into its newest kernel. Watch the node's screen if it takes much longer.
            </p>
          </div>
          {progress ? (
            <ul className="plain checks">
              <Check ok={progress.registration === "answered"} label="the installer fetched its answer" />
              <Check ok={progress.inCluster} label="in the Proxmox cluster" detail={progress.cluster ? `members: ${progress.cluster.join(", ")}` : "no node answered the membership read"} />
              <Check ok={progress.inSite} label="recorded as a node of the site" />
            </ul>
          ) : null}
          {running ? (
            <>
              <JobStatusLine job={running} label="The job" />
              <JobOutput job={running} />
            </>
          ) : null}
          {progress?.inCluster && !progress.inSite && endedOk !== null ? (
            <p className="small">
              In the cluster but not recorded as a node: <OperateButton label="Register joined nodes…" title="Register joined nodes" steps={[{ title: "Register joined nodes", bin: "site-manager", verb: "node reconcile", note: "The preview lists the nodes that joined the cluster and are not recorded as nodes of the site; Apply records them, with their storage pools." }]} />
            </p>
          ) : null}
          {progress?.pxe.text ? (
            <details className="small">
              <summary>the network-install service's status</summary>
              <pre className="output">{progress.pxe.text}</pre>
            </details>
          ) : null}
        </StepRow>
        <StepRow s={steps[4]} open={current === "storage"}>
          {joined ? <NodePools node={name} onContinue={(n) => (n > 0 ? setPooled(true) : setSkipPools(true))} /> : <p className="muted small">Once the node has joined.</p>}
        </StepRow>
        <StepRow s={steps[5]} open={current === "lan"}>
          {joined ? <LanUplink node={name} onDone={() => setLanDone(true)} /> : <p className="muted small">Once the node has joined.</p>}
        </StepRow>
        <StepRow s={steps[6]} open={current === "wan"}>
          {joined ? <WanUplink node={name} onDone={() => setWanDone(true)} /> : <p className="muted small">Once the node has joined.</p>}
        </StepRow>
        <StepRow s={steps[7]} open={current === "done"}>
          {valid ? (
            <p className="small">
              <Link to={viewLink("rack", `node:${name}`)}>Open {name} in the physical view →</Link> — select it there and use <b>Place…</b> to put it in its room and rack. Its machine is on the <Link to="/assets">Assets</Link> page, under its own tag, playing {name}, with its serial number and its network cards' MACs. {joined ? "" : <span className="muted">(it appears there once it is recorded)</span>}
            </p>
          ) : null}
        </StepRow>
      </ol>
    </Wizard>
  );
}

// Stage 1 once the change applies: one line, where the job is, with its Stop.
function DeclaredLine({ name, job, progress }: { name: string; job: Job; progress: NodeProgress | null }) {
  const live = jobLive(job);
  const line = declaredLine(name, setupFromOutput(phaseOutputs(job).apply), { live, answered: progress?.registration === "answered", joined: addNodeJoined(progress) });
  return (
    <JobStatusLine job={job} label={line} level={live || job.exit === 0 ? "pass" : "warn"} />
  );
}

// Stage 1: the form, then one button. node add runs as one job, its dry run
// first: while it checks, its status line (with Stop) and its output; once the
// change applies the stage is done (onApplied) and keeps one line, the job's
// output watched in stage 3. A refusal shows the last lines and Try again,
// back to the form with its values.
function DeclareStep({ step, name, progress, onApplied, onDone }: { step: Step; name: string; progress: NodeProgress | null; onApplied: (id: string) => void; onDone: (ok: boolean) => void }) {
  const me = useMe();
  const verb = useVerb(step.bin, step.verb);
  const [values, setValues] = useStepValues(step, verb);
  const argv = useMemo(() => buildArgv(step, verb, values), [step, verb, values]);
  const [started, setStarted] = useState<string | null>(null);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const job = useJob(started);
  useReportJob(jobLive(job) ? job : null);
  const pp = job?.previewPhase ?? null;
  // Past its dry run, clean: the change is applying.
  const inApply = job !== null && job.state !== "refused" && (!pp || (pp.exit === 0 && !pp.stopped));
  const failed = job !== null && !inApply && (job.state === "done" || job.state === "refused");
  const told = useRef<string | null>(null);
  useEffect(() => {
    if (started && inApply && told.current !== started) {
      told.current = started;
      onApplied(started);
    }
  }, [started, inApply]);
  useEffect(() => {
    if (job?.state === "done" && inApply) onDone(job.exit === 0);
  }, [job?.state, job?.exit]);

  const declare = async () => {
    setError(null);
    setStarting(true);
    try {
      const r = await applyNowJob(argv);
      if (!r.data || r.status >= 400) return setError(`${name} was not declared: ${r.error ?? `HTTP ${r.status}`}`);
      setStarted(r.data.id);
    } catch (e) {
      setError(`${name} was not declared: ${(e as Error).message}`);
    } finally {
      setStarting(false);
    }
  };

  if (!verb) return <p className="muted">reading the {step.bin} manifest…</p>;
  if (started) {
    if (!job) return <p className="muted"><Tag level="skip" /> Starting the declare of {name}…</p>;
    if (inApply) {
      return (
        <div className="step">
          <DeclaredLine name={name} job={job} progress={progress} />
          <details className="small">
            <summary>What the check printed</summary>
            <Output text={phaseOutputs(job).preview ?? ""} />
          </details>
        </div>
      );
    }
    if (failed) {
      const why = job.state === "refused" ? `${name} was not declared: ${job.refused ?? "refused"}` : pp?.stopped ? `${name} was not declared: ${pp.stopped}.` : job.cancelled ? `${name} was not declared: the job was stopped.` : `${name} was not declared: the check ended with exit ${pp?.exit ?? job.exit}.`;
      return (
        <div className="step">
          <p className="readstate readstate-fail">{why}</p>
          <JobOutput job={job} fold="tail" tail={8} />
          <div className="actions">
            <button className="btn btn-primary" onClick={() => setStarted(null)}>Try again</button>
            <span className="muted small">back to the form, as filled in</span>
          </div>
        </div>
      );
    }
    return (
      <div className="step">
        <JobStatusLine job={job} label={`Declaring ${name}`} />
        <JobOutput job={job} />
      </div>
    );
  }
  const hint = !canOperate(me) ? "only an operator adds a node" : step.blocked ?? null;
  return (
    <div className="step">
      {step.note ? <div className="note">{step.note}</div> : null}
      <StepForm step={step} verb={verb} values={values} set={setValues} />
      {error ? <p className="readstate readstate-fail">{error}</p> : null}
      <div className="actions">
        <button className="btn btn-primary" disabled={!!hint || starting} onClick={() => void declare()}>{starting ? "Starting…" : `Declare ${name || "the node"}`}</button>
        {hint ? <span className="muted small">{hint}</span> : null}
      </div>
    </div>
  );
}

// The button, and beside it the node being added, if one is: "Adding
// tappaas4 — stage 3 · Continue →" opens the wizard at that stage. `session`:
// the caller has looked already (Setup's Nodes step); otherwise it looks.
export function AddNodeButton({ label = "Add a node…", session: given }: { label?: string; session?: AddNodeSession | null }) {
  const [open, setOpen] = useState<false | "new" | "resume">(false);
  const [prefill, setPrefill] = useState<Values | null>(null);
  const operator = canOperate(useMe());
  const [dismissed, setDismissed] = useState<string[]>(() => dismissedJobs(storage()));
  const looked = useAddNodeSession(operator && given === undefined && !open, dismissed);
  const session = given === undefined ? looked : given && !dismissed.includes(given.job.id) ? given : null;
  useOpenedBy("add-node", undefined, (v) => {
    setPrefill(v);
    setOpen("new");
  }, operator);
  if (!operator) return null;
  return (
    <>
      {session ? (
        <span className="toolbar">
          <span className="small"><Dot level="warn" /> Adding {sessionText(session)}</span>
          <button className="btn btn-primary" onClick={() => setOpen("resume")}>Continue {session.name} →</button>
          <button className="btn btn-small" title="Forget this add: it is not offered again" onClick={() => setDismissed(dismissJob(storage(), session.job.id))}>Done with it</button>
        </span>
      ) : null}
      <button className="btn" onClick={() => setOpen("new")}>{label}</button>
      {open ? <AddNodeWizard prefill={prefill} resume={open === "resume"} onClose={() => { setOpen(false); setPrefill(null); }} /> : null}
    </>
  );
}
