// Satellite.tsx — Day 2's "Add a satellite" (satellite/INSTALL.md): a machine
// with a public IPv4 that gives a site without one public ingress and the
// admin-VPN relay. 1 what the operator does first (the VPS, its SSH key);
// 2 the satellite: its address, its environment, the roles it carries, where
// it is; 3 module-manager add satellite, previewed then applied; 4 its test.

import { useMemo, useState } from "react";
import { reloadAll, useRead } from "../api";
import { Step, StepView } from "../operate";
import { EnvironmentRow } from "../types";
import { canOperate, useMe } from "../ui";
import { SATELLITE_ROLES, SatellitePlan, satelliteProblems, satelliteSpec } from "../wizards";
import { StepRow } from "./Setup";

export function SatelliteWizard({ onClose }: { onClose: () => void }) {
  const me = useMe();
  const envs = (useRead<EnvironmentRow[]>("environments").env?.data ?? []).map((e) => e.name);
  const [ready, setReady] = useState(false);
  const [p, setP] = useState<SatellitePlan>({ address: "", environment: "mgmt", roles: ["reverse-proxy", "admin-vpn"], country: "", city: "", instance: "" });
  const [plan, setPlan] = useState<SatellitePlan | null>(null);
  const [added, setAdded] = useState(false);
  const problems = satelliteProblems(p);
  const set = (o: Partial<SatellitePlan>) => setP({ ...p, ...o });
  const name = plan?.instance || "satellite";

  const steps = useMemo(() => {
    if (!plan) return null;
    const add: Step = {
      ...satelliteSpec(plan),
      title: `module-manager add satellite${plan.instance ? ` --instance ${plan.instance}` : ""}`,
      only: [],
      note: (
        <>
          There is no dry run: the preview is the command. Apply creates the home end of the tunnel on the firewall, provisions Debian on {plan.address} over your operator key (WireGuard, its firewall{plan.roles.includes("reverse-proxy") ? ", nginx for the ingress" : ""}{plan.roles.includes("admin-vpn") ? ", the VPN relay" : ""}), adds the firewall's peer and the edge rules, and authorizes the mothership's key so the nightly sweep patches it. A failed install removes the config it wrote.
        </>
      ),
    };
    const test: Step = { title: `module-manager test ${name}`, bin: "module-manager", verb: "test", fixed: [name], hide: ["--vmid", "--zone0"], note: "The tunnel's handshake, the mothership's login, nginx and the relay rules for the roles it carries." };
    return { add, test };
  }, [plan]);

  const stages = [
    { id: "first", title: "1 · Before you start (by hand)", required: true, done: ready, detail: "A host with a stable public IPv4, your SSH key on it." },
    { id: "what", title: "2 · The satellite", required: true, done: plan !== null, detail: "Its address, its environment, the roles it carries, where it is." },
    { id: "add", title: "3 · Install it: module-manager add satellite", required: true, done: added, detail: "Previewed, then applied." },
    { id: "test", title: "4 · The result: module-manager test", required: false, done: false, detail: "Read live." },
  ];
  const current = !ready ? "first" : !plan ? "what" : !added ? "add" : "test";

  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal modal-wide" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Add a satellite">
        <header className="modal-head">
          <h2>Add a satellite</h2>
          <button className="btn-x" onClick={onClose} aria-label="close">×</button>
        </header>
        <p className="small">
          Only for a site with no usable public IP (CGNAT, a dynamic address, no port forwarding): the satellite is a small rented machine that receives the public traffic and passes it home through a WireGuard tunnel the firewall dials. A site with a real public IP does not need one.
        </p>
        <ol className="setup">
          <StepRow s={stages[0]} open={current === "first"}>
            <div className="explain">
              <ol>
                <li>Create a server with a <b>stable public IPv4</b> — at Hetzner Cloud, for example: image <b>Debian 12 or 13</b>, type <span className="mono">cx23</span> (or <span className="mono">cax11</span>, ARM). Note its address and where it is (country, city).</li>
                <li><b>Attach your own SSH key</b> — the one on your workstation, not one of tappaas-cicd's. It is your way in when the site is down; the install authorizes the mothership's key itself.</li>
                <li>Ask the provider to allow <b>outbound mail (port 25)</b> from it (Hetzner: Limits → port 25, after the first invoice). The satellite mails you when the site goes dark; until then its mail waits in its queue.</li>
                <li>The install logs in to the new host with your key through a <b>forwarded agent</b>: run it from an <span className="mono">ssh -A</span> session to tappaas-cicd. A console job has no agent, so Apply in stage 3 stops with "no operator key" — copy its command into that session instead.</li>
              </ol>
            </div>
            <label className="form-check">
              <input type="checkbox" checked={ready} onChange={(e) => setReady(e.target.checked)} /> The host is running with my SSH key on it.
            </label>
          </StepRow>
          <StepRow s={stages[1]} open={current === "what"}>
            <div className="form">
              <label className="form-row">
                <span>address *</span>
                <input type="text" value={p.address} disabled={plan !== null} placeholder="its public IPv4, e.g. 203.0.113.7" onChange={(e) => set({ address: e.target.value.trim() })} />
                {p.address && problems.address ? <small className="ff-error">{problems.address}</small> : <small className="muted">Where its public traffic arrives; point your public DNS records at it yourself.</small>}
              </label>
              <label className="form-row">
                <span>environment *</span>
                <select value={p.environment} disabled={plan !== null} onChange={(e) => set({ environment: e.target.value })}>
                  {[...new Set(["mgmt", ...envs])].map((e) => (
                    <option key={e} value={e}>{e}</option>
                  ))}
                </select>
                <small className="muted">A foundation module, like the other site services: mgmt.</small>
              </label>
              <div className="form-row">
                <span>roles *</span>
                <div className="ff-checks">
                  {Object.entries(SATELLITE_ROLES).map(([r, what]) => (
                    <label key={r} className="ff-check" title={what}>
                      <input type="checkbox" disabled={plan !== null} checked={p.roles.includes(r)} onChange={(e) => set({ roles: e.target.checked ? [...p.roles, r] : p.roles.filter((x) => x !== r) })} /> <span className="mono">{r}</span> <small className="muted">{what}</small>
                    </label>
                  ))}
                </div>
                {problems.roles ? <small className="ff-error">{problems.roles}</small> : <small className="muted">Both by default. The backup role comes later, with locking it down as the off-site vault.</small>}
              </div>
              <label className="form-row">
                <span>country</span>
                <input type="text" value={p.country} disabled={plan !== null} placeholder="ISO code, e.g. FI" onChange={(e) => set({ country: e.target.value.trim().toUpperCase() })} />
                {problems.country ? <small className="ff-error">{problems.country}</small> : <small className="muted">Where it physically runs: a backup copy on it is only off-site if it is somewhere else, and only this record shows it.</small>}
              </label>
              <label className="form-row">
                <span>city</span>
                <input type="text" value={p.city} disabled={plan !== null} placeholder="e.g. Helsinki — needed when the site is in the same country" onChange={(e) => set({ city: e.target.value })} />
              </label>
              <label className="form-row">
                <span>instance</span>
                <input type="text" value={p.instance} disabled={plan !== null} placeholder="satellite" onChange={(e) => set({ instance: e.target.value.trim() })} />
                {problems.instance ? <small className="ff-error">{problems.instance}</small> : <small className="muted">Empty: satellite (config/satellite.json). A second one needs its own name, e.g. satellite-hel1.</small>}
              </label>
            </div>
            <div className="actions">
              {plan ? (
                <button className="btn" disabled={added} onClick={() => setPlan(null)}>Edit</button>
              ) : (
                <button className="btn btn-primary" disabled={Object.keys(problems).length > 0} onClick={() => setPlan({ ...p, city: p.city.trim() })}>Continue</button>
              )}
            </div>
          </StepRow>
          <StepRow s={stages[2]} open={current === "add"}>
            {steps ? <StepView key={JSON.stringify(plan)} step={steps.add} me={me} onDone={(ok) => ok && setAdded(true)} /> : <p className="muted small">Once the satellite is described.</p>}
          </StepRow>
          <StepRow s={stages[3]} open={current === "test"}>
            {steps && added ? <StepView step={steps.test} me={me} onDone={() => undefined} /> : <p className="muted small">Once it is installed.</p>}
          </StepRow>
        </ol>
      </div>
    </div>
  );
}

export function SatelliteButton() {
  const [open, setOpen] = useState(false);
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Add a satellite…</button>
      {open ? <SatelliteWizard onClose={() => { setOpen(false); reloadAll(); }} /> : null}
    </>
  );
}
