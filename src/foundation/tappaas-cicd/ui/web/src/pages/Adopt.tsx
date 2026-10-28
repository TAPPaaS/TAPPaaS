// Adopt.tsx — Day 2's "Adopt a machine": a machine that already runs becomes a
// module of the site, at the location it is at (module-manager adopt).
// 1 the machine: its address, its name, its zone and location, whether its SSH
// turns key-only, and the switch port it is cabled to; 2 that port, when it is
// on a switch TAPPaaS programs: its record (switch-manager update-port) and the
// reconcile that programs the switch — on a self-managed switch, what to set by
// hand; 3 the adoption, previewed as the command, then applied; 4 the machine
// placed in its room and rack (position-manager place) or opened in the
// physical view.

import { useMemo, useState } from "react";
import { reloadAll, useJob, useRead } from "../api";
import { useSiteLocations } from "../locations";
import { Operate, Step, StepView } from "../operate";
import { useOpenedBy } from "../opener";
import { TargetValues } from "../consoletargets";
import { manualSwitches, switchPortChoices } from "../nodeadd";
import { placeSteps } from "../physical/rackops";
import { viewLink } from "../physical/views";
import { Topology } from "../types";
import { Link, canOperate, useMe } from "../ui";
import { StepRow } from "./Setup";

// What the activity is, on Day 2's card and at the top of the form.
export const ADOPT_TEXT = "A machine that already runs — a Debian host in a cupboard or a data centre — becomes a module of the site, at the location it is at. The mothership's key is added for root, its config is written and nothing else on it changes.";

interface Plan {
  address: string;
  instance: string;
  zone: string;
  location: string;
  keyOnly: boolean;
  port: { sw: string; port: string } | null;
}

const text = (v: unknown, d: string): string => (typeof v === "string" ? v : d);

// The instance adopt-module.sh names at its end: "<address> adopted as <name>
// (<module>)", or "… is already adopted as <name>" (its colours stripped).
export function adoptedName(output: string): string | null {
  const m = /adopted as (?:\x1b\[[0-9;]*m)*([A-Za-z0-9][A-Za-z0-9_.-]*)/.exec(output.replace(/\x1b\[[0-9;]*m/g, ""));
  return m ? m[1] : null;
}

// `prefill`: what the assistant opened it with (open_console adopt-machine):
// address, instance, zone, location, switch-port.
export function AdoptWizard({ onClose, prefill }: { onClose: () => void; prefill?: TargetValues | null }) {
  const me = useMe();
  const topo = useRead<Topology>("topology").env?.data ?? null;
  const locations = useSiteLocations();
  // The zones a machine lives in: on, with a VLAN of its own (not the overlays, not the WAN).
  const zones = (topo?.zones ?? []).filter((z) => (z.vlan ?? 0) > 0 && (z.state === "Active" || z.state === "Mandatory") && z.type !== "WAN");
  const ports = useMemo(() => switchPortChoices(topo?.switches ?? [], ""), [topo]);
  const manual = manualSwitches(topo?.switches ?? []);
  const [address, setAddress] = useState(text(prefill?.address, ""));
  const [instance, setInstance] = useState(text(prefill?.instance, ""));
  const [zone, setZone] = useState(text(prefill?.zone, ""));
  // The primary location until another is chosen (the site read may arrive after the form opened).
  const [chosenLocation, setLocation] = useState<string | null>(typeof prefill?.location === "string" ? prefill.location : null);
  const location = chosenLocation ?? locations.find((l) => l.primary)?.name ?? "";
  const [keyOnly, setKeyOnly] = useState(true);
  const [port, setPort] = useState(text(prefill?.["switch-port"], ""));
  const [plan, setPlan] = useState<Plan | null>(null);
  const [portSet, setPortSet] = useState(false);
  const [programmed, setProgrammed] = useState(false);
  const [job, setJob] = useState<string | null>(null);
  const [placing, setPlacing] = useState(false);
  const [placed, setPlaced] = useState(false);
  const running = useJob(job);
  const adopted = running && running.state === "done" && running.exit === 0 ? adoptedName(running.output) ?? plan?.instance ?? null : null;
  const zoneOf = zones.find((z) => z.name === zone) ?? null;
  const addr = address.trim();
  const problem = !addr ? "give the machine's address" : port && !zone ? "a zone is needed to configure the switch port" : null;

  const portStep: Step | null = useMemo(() => {
    if (!plan?.port) return null;
    const { sw, port: p } = plan.port;
    return {
      title: `switch-manager update-port '${sw}' ${p}`,
      bin: "switch-manager",
      verb: "update-port",
      fixed: [sw, p],
      only: [],
      initial: { "--type": "device", "--mode": "access", "--zone": plan.zone, "--description": plan.instance || plan.address },
      note: <>Records port {p} of {sw} as an access port in zone <b>{plan.zone}</b> for this machine (switch-configuration-actual.json) and nothing else: the switch is programmed in the reconcile that follows.</>,
    };
  }, [plan]);
  const reconcile: Step = useMemo(
    () => ({
      title: "switch-manager reconcile",
      bin: "switch-manager",
      verb: "reconcile",
      note: "The preview is the delta per port (interrogate, update-desired, delta — nothing applied). Apply programs every pending change on every switch, not only this port's: read the preview's list before you apply.",
    }),
    [],
  );
  const adopt: Step | null = useMemo(() => {
    if (!plan) return null;
    const initial: Step["initial"] = {};
    if (plan.instance) initial["--instance"] = plan.instance;
    if (plan.zone) initial["--zone"] = plan.zone;
    if (plan.location) initial["--location"] = plan.location;
    if (!plan.keyOnly) initial["--set"] = ["sshKeyOnly=false"];
    return {
      title: `module-manager adopt ${plan.address}`,
      bin: "module-manager",
      verb: "adopt",
      fixed: [plan.address],
      only: [],
      initial,
      note: (
        <>
          Reaches the machine as root with the mothership's key (if that fails it prints the one command that authorises the key and waits for it), learns its OS and hostname, and makes it a module: a Debian host becomes a debianhost, a Proxmox node of this cluster a pvehost. Its config is written and its SSH turns {plan.keyOnly ? "key-only" : "key-only — except that password logins stay allowed (sshKeyOnly=false)"}. There is no dry run: the preview is the command.
        </>
      ),
    };
  }, [plan]);

  const stages = [
    { id: "machine", title: "1 · The machine", required: true, done: plan !== null, detail: "Its address and name, its zone and location, its SSH, and the switch port it is cabled to." },
    { id: "port", title: "2 · The switch port", required: false, done: plan ? (plan.port ? programmed : true) : null, detail: plan?.port ? `Port ${plan.port.port} of ${plan.port.sw} as an access port in ${plan.zone}: its record, then the switch programmed.` : "On a switch TAPPaaS programs: the port's record, then the switch; on a self-managed switch, what to set by hand." },
    { id: "adopt", title: "3 · Adopt it", required: true, done: adopted !== null, detail: "module-manager adopt: the preview is the command; apply makes it a module." },
    { id: "place", title: "4 · Place it in the physical view", required: false, done: placed ? true : adopted ? false : null, detail: "Its room and rack: where the machine actually stands." },
  ];
  const current = !plan ? "machine" : plan.port && !programmed ? "port" : !adopted ? "adopt" : "place";

  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal modal-wide" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Adopt a machine">
        <header className="modal-head">
          <h2>Adopt a machine</h2>
          <button className="btn-x" onClick={onClose} aria-label="close">×</button>
        </header>
        <p className="small">{ADOPT_TEXT}</p>
        <ol className="setup">
          <StepRow s={stages[0]} open={current === "machine"}>
            <div className="form">
              <label className="form-row">
                <span>address *</span>
                <input type="text" value={address} disabled={plan !== null} placeholder="its IP address or DNS name" onChange={(e) => setAddress(e.target.value)} />
                <small className="muted">How the mothership reaches it today.</small>
              </label>
              <label className="form-row">
                <span>name</span>
                <input type="text" value={instance} disabled={plan !== null} placeholder="blank: the machine's own hostname" onChange={(e) => setInstance(e.target.value.trim())} />
                <small className="muted">The module's instance name; a name another machine has is refused.</small>
              </label>
              <label className="form-row">
                <span>zone{port ? " *" : ""}</span>
                <select value={zone} disabled={plan !== null} onChange={(e) => setZone(e.target.value)}>
                  <option value="">— blank: the zone whose subnet holds its address</option>
                  {zones.map((z) => (
                    <option key={z.name} value={z.name}>{z.name} ({z.type ?? "?"}, VLAN {z.vlan})</option>
                  ))}
                </select>
                <small className="muted">The zone it lives in{port ? "; the switch port is set to it" : ""}.</small>
              </label>
              <label className="form-row">
                <span>location</span>
                <select value={location} disabled={plan !== null} onChange={(e) => setLocation(e.target.value)}>
                  <option value="">— the primary location</option>
                  {locations.map((l) => (
                    <option key={l.name} value={l.name}>{l.name}{l.primary ? " (primary)" : ""}</option>
                  ))}
                </select>
                <small className="muted">One of the site's locations: where the machine stands.</small>
              </label>
              <label className="form-check">
                <input type="checkbox" checked={keyOnly} disabled={plan !== null} onChange={(e) => setKeyOnly(e.target.checked)} />
                <span>SSH key-only</span> <small className="muted">Root logs in with the mothership's key only; unticked, password logins stay allowed (sshKeyOnly=false).</small>
              </label>
              <label className="form-row">
                <span>switch port</span>
                <select value={port} disabled={plan !== null} onChange={(e) => setPort(e.target.value)}>
                  <option value="">— none: a self-managed switch, or not cabled yet</option>
                  {ports.map((c) => (
                    <option key={c.value} value={c.value}>{c.label}</option>
                  ))}
                </select>
                <small className="muted">The free ports on the switches TAPPaaS programs. The port becomes an access port in the machine's zone before the adoption.{manual.length ? ` Self-managed: ${manual.join(", ")} — set their ports by hand.` : ""}</small>
              </label>
            </div>
            <div className="actions">
              {plan ? (
                <button className="btn" disabled={portSet || job !== null} onClick={() => setPlan(null)}>Edit</button>
              ) : (
                <button
                  className="btn btn-primary"
                  disabled={problem !== null}
                  onClick={() => {
                    const [sw, ...rest] = port.split(":");
                    setPlan({ address: addr, instance, zone, location, keyOnly, port: port ? { sw, port: rest.join(":") } : null });
                  }}
                >
                  Continue
                </button>
              )}
              {!plan && problem ? <span className="muted small">{problem}</span> : null}
            </div>
          </StepRow>
          <StepRow s={stages[1]} open={current === "port"}>
            {!plan ? (
              <p className="muted small">Once the machine is described.</p>
            ) : portStep ? (
              <>
                <StepView key={`p-${plan.port!.sw}-${plan.port!.port}`} step={portStep} me={me} onDone={(ok) => ok && setPortSet(true)} />
                {portSet ? <StepView key="r" step={reconcile} me={me} onDone={(ok) => ok && setProgrammed(true)} /> : <p className="muted small">Next: switch-manager reconcile — once the port's record is written.</p>}
              </>
            ) : (
              <p className="small">
                No port on a switch TAPPaaS programs. On a self-managed switch set the machine's port as an access port in {zoneOf ? <>zone <b>{zoneOf.name}</b> (VLAN {zoneOf.vlan})</> : "the machine's zone"}; nothing to do here.
              </p>
            )}
          </StepRow>
          <StepRow s={stages[2]} open={current === "adopt"}>
            {adopt && (!plan?.port || programmed) ? <StepView key={`a-${JSON.stringify(plan)}`} step={adopt} me={me} onApplied={setJob} onDone={() => undefined} /> : <p className="muted small">{plan?.port ? "Once the switch port is programmed." : "Once the machine is described."}</p>}
          </StepRow>
          <StepRow s={stages[3]} open={current === "place"}>
            {adopted ? (
              <>
                <p className="small">
                  <b>{adopted}</b> is a module of the site now. Put it where it stands: a rack and its units, or loose in a room at its location. <Link to={viewLink("rack")}>Open the physical view →</Link>
                </p>
                <div className="actions">
                  <button className="btn btn-primary" onClick={() => setPlacing(true)}>Place {adopted}…</button>
                  {placing ? <Operate title={`Place ${adopted}`} steps={placeSteps(adopted, topo?.positions)} onClose={() => { setPlacing(false); setPlaced(true); reloadAll(); }} /> : null}
                </div>
              </>
            ) : (
              <p className="muted small">Once the machine is adopted.</p>
            )}
          </StepRow>
        </ol>
      </div>
    </div>
  );
}

export function AdoptButton() {
  const [open, setOpen] = useState(false);
  const [prefill, setPrefill] = useState<TargetValues | null>(null);
  const operator = canOperate(useMe());
  useOpenedBy("adopt-machine", undefined, (v) => {
    setPrefill(v);
    setOpen(true);
  }, operator);
  if (!operator) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Adopt a machine…</button>
      {open ? <AdoptWizard prefill={prefill} onClose={() => { setOpen(false); setPrefill(null); reloadAll(); }} /> : null}
    </>
  );
}
