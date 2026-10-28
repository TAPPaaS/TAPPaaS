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
// storage add); 5 its lan uplink (node network set, then node network test,
// each previewed); 6 the node in the physical view.

import { useMemo, useState } from "react";
import { useJob, useRead } from "../api";
import { Output } from "../jobs";
import { OperateButton, Step, StepView, Values } from "../operate";
import { useOpenedBy } from "../opener";
import { StorageInventory, SiteRead, Topology } from "../types";
import { ZoneRead } from "./Zones";
import { viewLink } from "../physical/views";
import { diskId, humanSize, manualTrunkText, nodeTrunkVlans, poolDisks, proposedDisks, proposedLayout, proposedPoolName, switchPortChoices } from "../nodeadd";
import { Dot, Link, canOperate, useMe } from "../ui";
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

interface NodeProgress {
  name: string;
  registration: "pending" | "answered" | "none";
  pxe: { enabled: boolean | null; text: string };
  inCluster: boolean | null;
  cluster: string[] | null;
  inSite: boolean;
  siteNodes: string[];
}

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
const DECLARE_OPTIONS = ["--switch-port", "--mac", "--boot-disk", "--boot-mirror", "--ttl", "--no-reboot"];

function Check({ ok, label, detail }: { ok: boolean | null; label: string; detail?: string }) {
  return (
    <li>
      <Dot level={ok === true ? "pass" : ok === false ? "skip" : "unknown"} /> {label}
      {detail ? <span className="muted small"> — {detail}</span> : null}
    </li>
  );
}

function tail(text: string, n: number): string {
  const lines = text.trimEnd().split("\n");
  return lines.slice(-n).join("\n");
}

// `prefill`: what the assistant opened it with (open_console add-node): the
// node's name, and node add's options by name (mac, boot-disk, …).
export function AddNodeWizard({ onClose, prefill }: { onClose: () => void; prefill?: Values | null }) {
  const me = useMe();
  const site = useRead<SiteRead>("site").env?.data;
  const known = (site?.nodes ?? []).map((n) => n.name);
  const [typed, setName] = useState<string | null>(typeof prefill?.name === "string" ? prefill.name : null);
  const options = useMemo(() => {
    // The wizard installs; adopting a hand-installed Proxmox is the CLI's only.
    const { name: _n, adopt: _a, ...rest } = prefill ?? {};
    return Object.keys(rest).length ? rest : undefined;
  }, [prefill]);
  const name = typed ?? firstFreeNode(known);
  const [job, setJob] = useState<string | null>(null);
  const [ended, setEnded] = useState<boolean | null>(null);
  const [uplinkSet, setUplinkSet] = useState(false);
  const [tested, setTested] = useState(false);
  const [pooled, setPooled] = useState(false);
  const [skipPools, setSkipPools] = useState(false);
  // Stage 0: the installer stick written by a node (site-manager node usb write).
  const [stickNode, setStickNode] = useState(known[0] ?? "tappaas1");
  const [stickDevice, setStickDevice] = useState("");
  const [stickWritten, setStickWritten] = useState(false);
  const [prepared, setPrepared] = useState(false);
  const [skipMedium, setSkipMedium] = useState(false); // the machine network-boots: no stick
  // The boot medium on the mothership, read again every ten seconds while the
  // wizard is open: a prepare that ran shows up without a reload.
  const mediaRead = useRead<BootMedia>("media", 10_000);
  const media = mediaRead.env?.data ?? null;
  const valid = NAME.test(name);
  // Read from the moment the name is valid: a wizard reopened while the job
  // runs (or for a node already joined) shows where it stands.
  const progress = useRead<NodeProgress>(valid ? `nodes/${encodeURIComponent(name)}/progress` : null, 10_000).env?.data ?? null;
  const underway = job !== null || (progress !== null && (progress.registration !== "none" || progress.inCluster === true));
  const running = useJob(job);
  const joined = progress !== null && progress.inCluster === true && progress.inSite;

  const topo = useRead<Topology>("topology").env?.data;
  const zones = useRead<ZoneRead[]>("zones").env?.data ?? [];
  const ports = useMemo(() => switchPortChoices(topo?.switches ?? [], name), [topo, name]);
  const trunk = manualTrunkText(nodeTrunkVlans(zones));
  const declare: Step = useMemo(
    () => ({
      title: `site-manager node add ${name || "<name>"}`,
      bin: "site-manager",
      verb: "node add",
      fixed: valid ? [name] : [],
      only: DECLARE_OPTIONS,
      placeholders: {
        "--switch-port": "none: the port is configured by hand",
        "--mac": "e.g. 58:47:ca:7a:12:34 — blank: learned on the switch port; with none, the first machine that asks",
        "--boot-disk": "blank: the smallest SSD/NVMe",
        "--boot-mirror": "blank: mirrored only when two disks alike match · none: one disk",
        "--ttl": "7200",
      },
      // The free ports on the switches TAPPaaS programs (and this node's own).
      choices: { "--switch-port": ports.map((c) => c.value) },
      suggestNotes: { "--switch-port": Object.fromEntries(ports.map((c) => [c.value, c.label])) },
      // The node joins with no WAN port and its one detected lan port; stage 5
      // declares the lan ports and the WAN port (node network set). --yes only
      // skips node add's lan-port question, which --no-wan skips already.
      initial: { "--yes": true, "--no-wan": true },
      hide: ["--yes"],
      prefill: options,
      blocked: job !== null || (valid && !known.includes(name)) ? undefined : "give the node a new name first",
      note: (
        <>
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
    [name, valid, options, ports, trunk, known, job],
  );
  const set: Step = useMemo(
    () => ({
      title: `site-manager node network set ${name}`,
      bin: "site-manager",
      verb: "node network set",
      fixed: [name],
      hide: ["--config-only"],
      choices: { "--lan-mode": ["active-backup", "lacp"] },
      placeholders: { "--lan-ports": "e.g. enp2s0f0,enp2s0f1 (names or MACs)", "--lan-primary": "e.g. enp2s0f0 — empty: the fastest", "--mtu": "e.g. 9000 — empty: as now", "--switch-wait": "seconds, 30–1800 (default 30)" },
      note: (
        <>
          <p>The node carries the management network, the cluster link and every guest's VLANs on its lan uplink. Declare which ports form it (one port, or two bonded as <span className="mono">lanbond</span>), preview, then apply; the failover test after it proves that losing either port keeps the node reachable. For lacp, configure the LAG on the switch side first (Site › Device, the switch's ports).</p>
          <p>The preview writes the declaration into the node's config on the mothership (<span className="mono">config/&lt;node&gt;.json</span>) and checks it on the node, which it does not change. Apply moves lan onto the declared ports: the node is drained first (its HA guests move away), the change runs under a 45-second rollback, the mothership confirms it, and the node comes back.</p>
        </>
      ),
    }),
    [name],
  );
  const test: Step = useMemo(
    () => ({
      title: `site-manager node network test ${name}`,
      bin: "site-manager",
      verb: "node network test",
      fixed: [name],
      note: "The preview says what the test will do. Apply drains the node, then takes each lan port down for ten seconds in turn: the management network and the cluster link must stay up. A timer on the node restores a port after 30 seconds whatever happens.",
    }),
    [name],
  );

  // Stage 0: the medium built on the mothership when it is missing or stale.
  const prepare: Step = useMemo(
    () => ({
      title: "site-manager node media prepare",
      bin: "site-manager",
      verb: "node media prepare",
      fixed: [],
      only: ["--force"],
      note: media?.prepare
        ? `Runs ${media.prepare.argv.join(" ")} on the mothership (${media.prepare.minutes}). There is no dry run: the preview is the command.`
        : "Stages the netboot assets and builds the installer stick image on the mothership. There is no dry run: the preview is the command.",
    }),
    [media?.prepare],
  );
  const writeStick: Step = useMemo(
    () => ({
      title: `site-manager node usb write ${stickNode} ${stickDevice || "<device>"}`,
      bin: "site-manager",
      verb: "node usb write",
      fixed: stickDevice ? [stickNode, stickDevice] : [stickNode],
      only: [],
      // The CLI's guard against erasing a stick by accident; here the preview
      // and Apply are that confirmation, so it is always given and not offered.
      initial: { "--yes": true },
      hide: ["--yes"],
      blocked: !stickDevice ? "pick the stick first" : media && !media.stickImage.present ? "the installer stick image is not built yet: prepare the medium first" : undefined,
      note: `The mothership streams the installer stick image (${media?.stickImage.path ?? "/var/lib/tappaas-pxe/tappaas-usb.iso"}, the same for every node) over ssh into ${stickDevice || "the stick"} in ${stickNode}, erasing it, then flushes and ejects it: a minute or two. The node needs nothing in advance. There is no dry run: the preview is the command.`,
    }),
    [stickNode, stickDevice, media?.stickImage.present, media?.stickImage.path],
  );
  const mediaReady = media?.ready ?? null;

  const steps = [
    // Optional, and open until the operator writes a stick or skips: a
    // machine that network-boots needs no stick (then the medium must only be
    // there, which stage 1's job checks again).
    { id: "medium", title: "0 · Prepare boot medium", required: false, done: stickWritten || skipMedium ? true : mediaReady === false && !prepared ? false : null, detail: "The netboot assets and the installer stick image on the mothership, built once per Proxmox version and checked here; then, for a machine that cannot network-boot, the stick. Skip it for a machine that network-boots." },
    { id: "declare", title: "1 · Declare the node", required: true, done: job !== null, detail: "Its name, where it is cabled, its initial ethernet port and boot disks, and a few other options. The outcome is either a boot USB disk is prepared or a PXE boot process is started." },
    { id: "boot", title: "2 · Boot the machine: from the network (PXE) or a USB stick (by hand)", required: true, done: progress && underway ? progress.registration === "answered" || progress.inCluster === true : null, detail: "Power it on and boot it once from the network or from the installer stick; the mothership answers with the installer either way." },
    { id: "wait", title: "3 · Install and join (automatic)", required: true, done: underway ? joined : null, detail: "Proxmox installs onto a ZFS boot pool, the node joins the cluster, is patched and rebooted, and is registered as a pvehost instance." },
    { id: "storage", title: "4 · Define data pools", required: false, done: pooled ? true : null, detail: "Until it has one, its guests go to the boot pool. Proposed from its free disks." },
    { id: "uplink", title: "5 · Define extra lan and WAN uplinks", required: false, done: tested ? true : uplinkSet ? null : false, detail: "Which ports carry lan, and the WAN port if the node may carry the firewall; then the failover test — each previewed first." },
    { id: "done", title: "6 · Place the machine correctly in the physical view", required: false, done: joined, detail: "Its location, room and rack: where the machine actually stands." },
  ];
  const current = !underway ? "declare" : !progress || progress.registration === "pending" ? "boot" : !joined ? "wait" : !pooled && !skipPools ? "storage" : !tested ? "uplink" : "done";

  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal modal-wide" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Add a node">
        <header className="modal-head">
          <h2>Add a node</h2>
          <button className="btn-x" onClick={onClose} aria-label="close">×</button>
        </header>
        <p className="small">
          Adding a new physical machine as a Proxmox node of this site. This includes defining its connectivity and its boot disk, configuring it in the cluster, and setting up its data pools. Nothing changes until you Apply in stage 1.
        </p>
        <ol className="setup">
          {/* Open while the medium is not ready; collapsed once it is (most machines network-boot and need nothing more). */}
          <StepRow s={steps[0]} open={!stickWritten && !skipMedium}>
            <p className="small">Every new node installs from one medium on the mothership: a machine that network-boots (PXE) fetches it from there, a machine that cannot boots the installer stick made from the same image. The cicd install built it once; it is built again here when it is missing, from before this version, or wanted for a new Proxmox version.</p>
            {media ? (
              <ul className="plain checks">
                <Check ok={media.staged && media.current} label="netboot assets on the mothership" detail={media.staged ? (media.current ? "staged, current" : "staged, but from before this version's installer hook") : "not staged"} />
                <Check ok={media.stickImage.present} label="installer stick image" detail={media.stickImage.present ? `${media.stickImage.path}, ${gb(media.stickImage.size)}, ${media.stickImage.modified ?? ""}` : "not built"} />
                {!media.xorriso ? <Check ok={false} label="xorriso on the mothership" detail="not installed: the stick image cannot be built until an OS update of tappaas-cicd brings it" /> : null}
              </ul>
            ) : (
              <p className="muted small">{mediaRead.env?.error || mediaRead.failure ? <><Dot level="fail" /> site-manager node media could not be read: {mediaRead.env?.error ?? mediaRead.failure}</> : "reading the boot medium…"}</p>
            )}
            {media && (!media.ready || prepared) ? (
              media.prepare || prepared ? (
                <StepView key={media.prepare?.argv.join(" ") ?? "ready"} step={prepare} me={me} onDone={(ok) => { if (ok) { setPrepared(true); mediaRead.reload(); } }} />
              ) : (
                <p className="small"><Dot level="warn" /> Nothing can be built here until xorriso is installed on the mothership.</p>
              )
            ) : null}
            <p className="small" style={{ marginTop: "1em" }}><b>The installer stick</b> — only for a machine that cannot network-boot. One image for every node: the stick fetches the node's own answer from the mothership once stage 1's job runs. Two ways to write it:</p>
            <div className="two">
              <div className="explain">
                <p><b>On your own machine</b></p>
                <ol>
                  <li>Get the image: <span className="mono">scp tappaas@tappaas-cicd.mgmt.internal:{media?.stickImage.path ?? "/var/lib/tappaas-pxe/tappaas-usb.iso"} .</span> — or, while stage 1's job runs, <a href="http://tappaas-cicd.mgmt.internal:8090/tappaas-usb.iso">tappaas-usb.iso</a> from the mothership on the management network.</li>
                  <li>Write it to a stick: <span className="mono">dd if=tappaas-usb.iso of=/dev/&lt;usb&gt; bs=4M</span>, or balenaEtcher.</li>
                </ol>
              </div>
              <div className="explain">
                <p><b>By a node</b> — a stick in a free USB port of an existing node; the mothership is a VM with no USB port, so it writes through the node</p>
                <div className="form">
                  <UsbStickPicker nodes={known.length ? known : [stickNode]} node={stickNode} setNode={setStickNode} device={stickDevice} setDevice={setStickDevice} disabled={stickWritten} />
                </div>
                {stickWritten ? (
                  <p className="small"><Dot level="pass" /> The installer stick is written and ejected: pull {stickDevice} out of {stickNode}. It boots the new machine in stage 2.</p>
                ) : null}
                <StepView key={`${stickNode}:${stickDevice}:${media?.stickImage.present ? 1 : 0}`} step={writeStick} me={me} onDone={(ok) => ok && setStickWritten(true)} />
              </div>
            </div>
            {!stickWritten && !skipMedium ? (
              <div className="actions">
                <button className="btn" onClick={() => setSkipMedium(true)}>Skip: the machine network-boots</button>
                <span className="muted small">No stick is needed then; stage 1 opens the network-boot window.</span>
              </div>
            ) : null}
          </StepRow>
          <StepRow s={steps[1]} open={current === "declare"}>
            <StepView key={topo ? "ports" : "no-ports"} step={declare} me={me} onApplied={setJob} onDone={(ok) => setEnded(ok)} />
          </StepRow>
          <StepRow s={steps[2]} open={current === "boot"}>
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
                <Check ok={progress.registration !== "none"} label="registered for a network install" detail={progress.registration === "pending" ? "waiting for the machine to ask" : progress.registration === "answered" ? "the installer has fetched its answer" : "no registration (the job has not reached it, or it ended)"} />
                <Check ok={progress.pxe.enabled} label="the network-boot window on the mothership" detail={progress.pxe.enabled ? "open" : "closed"} />
              </ul>
            ) : underway ? <p className="muted small">reading the provisioning state…</p> : null}
          </StepRow>
          <StepRow s={steps[3]} open={current === "wait"}>
            <div className="explain">
              <p>
                Nothing to do here but wait, typically 15–25 minutes: the installer writes Proxmox to the boot disk(s) and reboots, the job waits for the node at its address, checks it and joins it to the cluster, registers it as a pvehost instance, brings it to the cluster baseline and reboots it into the kernel that installed. Watch the node's screen if it takes much longer.
              </p>
            </div>
            {progress ? (
              <ul className="plain checks">
                <Check ok={progress.registration === "answered"} label="the installer fetched its answer" />
                <Check ok={progress.inCluster} label="in the Proxmox cluster" detail={progress.cluster ? `members: ${progress.cluster.join(", ")}` : "no node answered the membership read"} />
                <Check ok={progress.inSite} label="registered as a pvehost instance" />
              </ul>
            ) : null}
            {running ? (
              <>
                <p className="small">
                  The job: <b>{running.state === "done" ? (running.exit === 0 ? "finished" : `ended with exit ${running.exit}`) : running.state}</b> <span className="muted">(its full output is under stage 1)</span>
                </p>
                <Output text={tail(running.output, 14)} live={running.state === "running"} />
              </>
            ) : null}
            {progress?.inCluster && !progress.inSite && ended !== null ? (
              <p className="small">
                In the cluster but not registered: <OperateButton label="Register joined nodes…" title="site-manager node reconcile" steps={[{ title: "site-manager node reconcile", bin: "site-manager", verb: "node reconcile", note: "The preview lists the nodes that joined the cluster and have no pvehost instance; apply registers them, with their storage pools." }]} />
              </p>
            ) : null}
            {progress?.pxe.text ? (
              <details className="small">
                <summary>node-provisioner status</summary>
                <pre className="output">{progress.pxe.text}</pre>
              </details>
            ) : null}
          </StepRow>
          <StepRow s={steps[4]} open={current === "storage"}>
            {joined ? <NodePools node={name} onAdded={() => setPooled(true)} onSkip={() => setSkipPools(true)} /> : <p className="muted small">Once the node has joined.</p>}
          </StepRow>
          <StepRow s={steps[5]} open={current === "uplink"}>
            {joined || !underway ? (
              valid ? (
                <>
                  <StepView step={set} me={me} onDone={(ok) => ok && setUplinkSet(true)} />
                  <StepView step={test} me={me} onDone={(ok) => ok && setTested(true)} />
                </>
              ) : <p className="muted small">Name the node in stage 1 first.</p>
            ) : (
              <p className="muted small">Once the node has joined.</p>
            )}
          </StepRow>
          <StepRow s={steps[6]} open={current === "done"}>
            {valid ? (
              <p className="small">
                <Link to={viewLink("rack", `node:${name}`)}>Open {name} in the physical view →</Link> — select it there and use <b>Place…</b> to put it in its room and rack. {joined ? "" : <span className="muted">(it appears there once it is registered)</span>}
              </p>
            ) : null}
          </StepRow>
        </ol>
      </div>
    </div>
  );
}

// Stage 4: a data pool on the node's free disks. The inventory proposes; the
// operator ticks the disks, may rename the pool or change the layout, and
// node storage add — which refuses what is not precise — builds it.
function NodePools({ node, onAdded, onSkip }: { node: string; onAdded: () => void; onSkip: () => void }) {
  const me = useMe();
  const inv = useRead<StorageInventory>("storage").env?.data;
  const here = inv?.nodes.find((n) => n.name === node);
  const disks = useMemo(() => poolDisks(here?.otherDisks ?? []), [here]);
  const taken = (here?.pools ?? []).map((p) => p.name);
  const [ticked, setTicked] = useState<string[] | null>(null);
  const sel = ticked ?? proposedDisks(here?.otherDisks ?? []).map(diskId);
  const first = disks.find((d) => sel.includes(diskId(d)));
  const [pool, setPool] = useState<string | null>(null);
  const [layout, setLayout] = useState<string | null>(null);
  const poolName = pool ?? proposedPoolName(first?.type ?? "ssd", taken);
  const lay = layout ?? proposedLayout(sel.length);
  if (!inv) return <p className="muted small">reading the storage inventory…</p>;
  if (!here) return <p className="muted small">{node} is not in the storage inventory yet — it is read every few minutes.</p>;
  const step: Step = {
    title: `site-manager node storage add ${node} ${poolName}`,
    bin: "site-manager",
    verb: "node storage add",
    fixed: [node, poolName],
    only: ["--disks", "--layout", "--wipe"],
    initial: { "--disks": sel.join(","), "--layout": lay },
    choices: { "--layout": ["single", "mirror", "raidz1", "raidz2"] },
    note: "There is no dry run: the preview shows the command. Apply builds the pool on the node and registers it as its storage; a disk that carries data is refused unless --wipe is ticked, and nothing is erased then.",
  };
  return (
    <div>
      <p className="small">
        {here.pools.length ? <>Pools now: {here.pools.map((p) => p.name).join(", ")}. </> : <>No data pool yet: its guests go to the boot pool. </>}
        {disks.length ? "Its disks in no pool, healthy:" : "It has no healthy disk in no pool — nothing to propose."}
      </p>
      {disks.length ? (
        <ul className="plain">
          {disks.map((d) => (
            <li key={diskId(d)}>
              <label>
                <input type="checkbox" checked={sel.includes(diskId(d))}
                  onChange={(e) => setTicked(e.target.checked ? [...sel, diskId(d)] : sel.filter((x) => x !== diskId(d)))} />{" "}
                <span className="mono">{diskId(d)}</span> · {humanSize(d.size)} · {d.type} · {d.model ?? "?"}
                {d.exportedPool ? <span className="muted small"> — an old pool '{d.exportedPool.name}' on it: --wipe to reuse</span> : null}
              </label>
            </li>
          ))}
        </ul>
      ) : null}
      {disks.length ? (
        <>
          <label className="form-row">
            <span>pool name</span>
            <input type="text" value={poolName} onChange={(e) => setPool(e.target.value.trim())} />
            <small className="muted">tank&lt;class&gt;&lt;N&gt;: a for SSD/NVMe, b for spinning disks. A name other nodes have extends that storage to {node}.</small>
          </label>
          <label className="form-row">
            <span>layout</span>
            <select value={lay} onChange={(e) => setLayout(e.target.value)}>
              {["single", "mirror", "raidz1", "raidz2"].map((l) => <option key={l} value={l}>{l}</option>)}
            </select>
            <small className="muted">single: 1 disk, no redundancy · mirror: 2 or more · raidz1: 3 or more · raidz2: 4 or more</small>
          </label>
          {sel.length ? <StepView key={`${poolName}|${sel.join(",")}|${lay}`} step={step} me={me} onDone={(ok) => ok && onAdded()} /> : <p className="muted small">Tick the disks for the pool.</p>}
        </>
      ) : null}
      <p className="small"><button className="btn" onClick={onSkip}>No data pool now →</button> <span className="muted">(site-manager node storage add later)</span></p>
    </div>
  );
}

export function AddNodeButton({ label = "Add a node…" }: { label?: string }) {
  const [open, setOpen] = useState(false);
  const [prefill, setPrefill] = useState<Values | null>(null);
  const operator = canOperate(useMe());
  useOpenedBy("add-node", undefined, (v) => {
    setPrefill(v);
    setOpen(true);
  }, operator);
  if (!operator) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>{label}</button>
      {open ? <AddNodeWizard prefill={prefill} onClose={() => { setOpen(false); setPrefill(null); }} /> : null}
    </>
  );
}
