// AddNode.tsx — adding a node as a guided sequence (Setup's step rows): what
// each stage does is said before it runs, and what the operator must do by
// hand is said where it is needed (ADR-037 D4). 1 declare the node — where it
// is cabled first, then its MAC and boot disks, each blank its default
// (site-manager node add --pxe: one job that registers it for a network
// install, opens the PXE window and waits for it); 2 boot the machine from the
// network, by hand; 3 the install and the join, watched live (the provisioning
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
import { diskId, humanSize, manualSwitches, manualTrunkText, nodeTrunkVlans, poolDisks, proposedDisks, proposedLayout, proposedPoolName, switchPortChoices } from "../nodeadd";
import { Dot, Link, canOperate, useMe } from "../ui";
import { StepRow } from "./Setup";

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
const DECLARE_OPTIONS = ["--pxe", "--switch-port", "--mac", "--boot-disk", "--boot-mirror", "--wan-port", "--no-wan", "--lan-ports", "--lan-mode", "--ttl", "--no-reboot"];
const LABELS: Record<string, string> = {
  "--pxe": "--pxe (install it over the network)",
  "--switch-port": "--switch-port: the switch port it is cabled to",
  "--mac": "--mac: the MAC of the card that network-boots",
  "--boot-disk": "--boot-disk: the disk to install Proxmox on",
  "--boot-mirror": "--boot-mirror: a second disk, mirrored",
  "--wan-port": "--wan-port: the WAN port",
  "--no-wan": "--no-wan (no WAN port)",
  "--lan-ports": "--lan-ports: the lan port(s)",
  "--lan-mode": "--lan-mode",
  "--ttl": "--ttl: seconds the window stays open",
  "--no-reboot": "--no-reboot (keep the installer's kernel)",
};

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
    const { name: _n, ...rest } = prefill ?? {};
    return Object.keys(rest).length ? rest : undefined;
  }, [prefill]);
  const name = typed ?? firstFreeNode(known);
  const [job, setJob] = useState<string | null>(null);
  const [ended, setEnded] = useState<boolean | null>(null);
  const [uplinkSet, setUplinkSet] = useState(false);
  const [tested, setTested] = useState(false);
  const [pooled, setPooled] = useState(false);
  const [skipPools, setSkipPools] = useState(false);
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
  const byHand = manualSwitches(topo?.switches ?? []);
  const trunk = manualTrunkText(nodeTrunkVlans(zones));
  const declare: Step = useMemo(
    () => ({
      title: `site-manager node add ${name || "<name>"} --pxe`,
      bin: "site-manager",
      verb: "node add",
      fixed: valid ? [name] : [],
      only: DECLARE_OPTIONS,
      labels: LABELS,
      placeholders: {
        "--switch-port": "blank: the port is configured by hand, and the MAC is needed",
        "--mac": "blank with a switch port: learned there — e.g. 58:47:ca:7a:12:34",
        "--boot-disk": "blank: the smallest SSD/NVMe — both of an identical pair, mirrored · or 2TB, Samsung 990, a serial",
        "--boot-mirror": "blank: mirrored only when two disks alike match · none: one disk",
        "--wan-port": "e.g. enp1s0 — or tick --no-wan",
        "--lan-ports": "e.g. enp2s0f0,enp2s0f1 — empty: one port, detected",
        "--ttl": "7200",
      },
      choices: { "--lan-mode": ["active-backup", "lacp"] },
      suggest: { "--switch-port": ports.map((c) => c.value) },
      suggestNotes: { "--switch-port": Object.fromEntries(ports.map((c) => [c.value, c.label])) },
      asides: {
        "--switch-port": (
          <small className="muted">
            On a switch TAPPaaS programs, pick the port: it becomes a node trunk, and the machine's MAC is learned there while it network-boots.
            {byHand.length ? <> On {byHand.join(", ")} (configured by hand) set the port as {trunk}, leave this blank and give the MAC.</> : null}
          </small>
        ),
      },
      initial: { "--pxe": true, "--yes": true },
      prefill: options,
      note: "There is no dry run: the preview shows the exact command. Apply starts one job that runs until the node has joined: it makes the switch port a node trunk (with --switch-port), registers the node for a network install, opens the PXE window on the mothership (two hours unless --ttl says otherwise), waits for the machine to boot from the network and learns its MAC, waits for the install, then joins it to the cluster, brings it to the cluster baseline, reboots it into its new kernel and registers it as a pvehost instance. Its data pools are stage 4.",
    }),
    [name, valid, options, ports, byHand, trunk],
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
      note: "The preview writes the declaration into the node's config on the mothership (config/<node>.json) and checks it on the node, which it does not change. Apply moves lan onto the declared ports: the node is drained first (its HA guests move away), the change runs under a 45-second rollback, the mothership confirms it, and the node comes back.",
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

  const steps = [
    { id: "declare", title: "1 · Declare the node", required: true, done: job !== null, detail: "Where it is cabled, its MAC and boot disks — each blank its default — then start the job that adds it." },
    { id: "boot", title: "2 · Boot the machine from the network (by hand)", required: true, done: progress && underway ? progress.registration === "answered" || progress.inCluster === true : null, detail: "Power it on and choose network boot once; the mothership answers with the installer." },
    { id: "wait", title: "3 · Install and join (automatic)", required: true, done: underway ? joined : null, detail: "Proxmox installs onto a ZFS boot pool, the node joins the cluster, is patched and rebooted, and is registered as a pvehost instance." },
    { id: "storage", title: "4 · Its data pools", required: false, done: pooled ? true : null, detail: "Until it has one, its guests go to the boot pool. Proposed from its free disks." },
    { id: "uplink", title: "5 · The lan uplink", required: false, done: tested ? true : uplinkSet ? null : false, detail: "Which ports carry lan, then the failover test — each previewed first." },
    { id: "done", title: "6 · The node in the device view", required: false, done: joined, detail: "Its uplinks, its switch ports and its guests, as cabled." },
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
          A new machine becomes a Proxmox node of this site in one job that waits for you at the machine. The stages below say what each part does before it runs and what you do by hand. Nothing changes until you Apply in stage 1.
        </p>
        <ol className="setup">
          <StepRow s={steps[0]} open={current === "declare"}>
            <div className="explain">
              <p><b>What the form asks, in this order — every field may stay blank, and says what blank does:</b></p>
              <ul>
                <li><b>where it is cabled</b>: the switch port. On a switch TAPPaaS programs the port becomes a node trunk and the machine's <b>MAC</b> is learned there; on one configured by hand, set the port as {trunk}, and give the MAC (the machine's label, its BIOS or its BMC);</li>
                <li>its <b>boot disk</b>, and a second one to mirror it onto: a size (<span className="mono">2TB</span>), a model (<span className="mono">Samsung 990</span>) or a serial. Blank, the installer takes the smallest SSD or NVMe disk, and both when the smallest two are the same model and size (mirrored); when nothing matches, the node's own screen asks;</li>
                <li>which port is the <b>WAN</b> port (only a node that may carry the firewall needs one), or none;</li>
                <li>the <b>lan port(s)</b>: one, or two bonded (active-backup works with any switches; lacp needs a LAG on the switch side) — left out, one is detected.</li>
              </ul>
              <p className="muted small">Its data pools come after the join (stage 4), from the disks it really has.</p>
            </div>
            <label className="form-row">
              <span>node name *</span>
              <input type="text" value={name} onChange={(e) => setName(e.target.value.trim())} disabled={job !== null} />
              {name && !valid ? <small className="ff-error">tappaas1 to tappaas9: the firewall reserves a management address and name for exactly those</small> : null}
              {valid && known.includes(name) ? <small className="ff-error">{name} is already a node of this site</small> : null}
              <small className="muted">
                The Proxmox host name; {valid ? <>{name} gets the management address <span className="mono">{nodeAddress(name)}</span>. </> : null}Nodes today: {known.join(", ") || "—"}.
              </small>
            </label>
            {valid && !known.includes(name) ? <StepView key={topo ? "ports" : "no-ports"} step={declare} me={me} onApplied={setJob} onDone={(ok) => setEnded(ok)} /> : <p className="muted small">Give the node a new name to see the form.</p>}
          </StepRow>
          <StepRow s={steps[1]} open={current === "boot"}>
            <div className="explain">
              <p><b>At the machine, once stage 1's job is running:</b></p>
              <ol>
                <li>Cable the network-boot port to the management network.</li>
                <li>In the firmware (BIOS/UEFI setup), enable <b>network boot (PXE) over IPv4, UEFI</b> on that port.</li>
                <li>Power on and pick network boot once — the one-time boot menu (often F11 or F12) — or put network first in the boot order for this one boot.</li>
                <li>The mothership answers with the Proxmox installer. Only if the boot-disk fields match no disk does the node's screen ask for one.</li>
                <li>If you changed the boot order, set the disk first again after the install has started: the window closes on its own, and a second network boot finds nothing to install.</li>
              </ol>
            </div>
            {progress && underway ? (
              <ul className="plain checks">
                <Check ok={progress.registration !== "none"} label="registered for a network install" detail={progress.registration === "pending" ? "waiting for the machine to ask" : progress.registration === "answered" ? "the installer has fetched its answer" : "no registration (the job has not reached it, or it ended)"} />
                <Check ok={progress.pxe.enabled} label="the network-boot window on the mothership" detail={progress.pxe.enabled ? "open" : "closed"} />
              </ul>
            ) : underway ? <p className="muted small">reading the provisioning state…</p> : null}
          </StepRow>
          <StepRow s={steps[2]} open={current === "wait"}>
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
          <StepRow s={steps[3]} open={current === "storage"}>
            {joined ? <NodePools node={name} onAdded={() => setPooled(true)} onSkip={() => setSkipPools(true)} /> : <p className="muted small">Once the node has joined.</p>}
          </StepRow>
          <StepRow s={steps[4]} open={current === "uplink"}>
            <div className="explain">
              <p>
                The node carries the management network, the cluster link and every guest's VLANs on its lan uplink. Declare which ports form it (one port, or two bonded as <span className="mono">lanbond</span>), preview, then apply; the failover test after it proves that losing either port keeps the node reachable. For lacp, configure the LAG on the switch side first (Site › Device, the switch's ports).
              </p>
            </div>
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
          <StepRow s={steps[5]} open={current === "done"}>
            {valid ? (
              <p className="small">
                <Link to={`/site/device?select=node:${encodeURIComponent(name)}`}>Open {name} in the device view →</Link> {joined ? "" : <span className="muted">(it appears there once it is registered)</span>}
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
