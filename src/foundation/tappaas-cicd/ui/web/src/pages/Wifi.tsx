// Wifi.tsx — Day 2's "Add WiFi for <zone>": one site-wide SSID that puts
// clients on a zone's VLAN, broadcast by every access point (#889). 1 the
// network: the SSID's name and how clients join; 2 declaring it (ap-manager ssid
// add — after `ssid remove` of the zone's old SSID when the name changes, or
// `ssid modify` when only its security does); 3 the WPA passphrase, handed to
// `ap-manager ssid set-passphrase` on stdin through the secrets endpoint, never
// shown back or put in a command; 4 the reconcile that programs every access
// point, previewed first; 5 the SSID on its zone, read back from ap-manager.

import { useMemo, useState } from "react";
import { post, reloadAll, useRead, useVerb } from "../api";
import { Step, StepView } from "../operate";
import { TargetValue, TargetValues } from "../consoletargets";
import { useOpenedBy } from "../opener";
import { Dot, canOperate, useMe } from "../ui";
import { PASSPHRASE_TEXT, SiteSsid, StepSpec, WifiPlan, WifiZone, broadcastText, defaultSsid, needsPassphrase, passphraseOf, passphraseProblem, ssidProblem, wifiSpecs, wifiVerb } from "../wizards";
import { SecretStatus, StepRow } from "./Setup";

const asStep = (spec: StepSpec, title: string, note: Step["note"]): Step => ({ ...spec, title, note, only: [], hide: ["@ssid"] });

const str = (v: TargetValue | undefined): string | null => (typeof v === "string" ? v : null);

// `prefill`: what the assistant opened it with (open_console add-wifi <zone>): ssid, security.
export function WifiWizard({ z, apCount, site, onClose, prefill }: { z: WifiZone; apCount: number; site: string; onClose: () => void; prefill?: TargetValues | null }) {
  const me = useMe();
  const verb = useVerb("ap-manager", "ssid add");
  const securities = verb?.options.find((o) => o.flag === "--security")?.choices ?? ["wpa2-personal"];
  // What the zone had when the form opened: the reads refresh behind it as its
  // steps run, and the form keeps saying what it is changing.
  const [old] = useState(z.ssid);
  const change = old !== null;
  const [name, setName] = useState(str(prefill?.ssid) ?? defaultSsid(site, z));
  const [security, setSecurity] = useState(str(prefill?.security) ?? old?.security ?? "wpa2-personal");
  const [pass, setPass] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const [plan, setPlan] = useState<WifiPlan | null>(null);
  const [removed, setRemoved] = useState(false);
  const [declared, setDeclared] = useState(false);
  const [passDone, setPassDone] = useState(false);
  const [reconciled, setReconciled] = useState(false);
  const ssid = name.trim();
  const problem = ssidProblem(ssid);
  const personal = needsPassphrase(security);
  // Read again while a step is awaited: the job's end re-reads it behind the console.
  const ssidsRead = useRead<SiteSsid[]>("ssids", declared ? 5_000 : 300_000);
  const live = (ssidsRead.env?.data ?? []).find((s) => s.name === (plan?.ssid ?? ssid)) ?? null;
  const state = live ? passphraseOf(live) : null;

  const steps = useMemo(() => {
    if (!plan) return null;
    const s = wifiSpecs(plan);
    const disruption = s.remove ? <> Clients on <b>{plan.old!.name}</b> lose the WiFi when the reconcile programs the access points, and join <b>{plan.ssid}</b> with its passphrase.</> : null;
    return {
      remove: s.remove ? asStep(s.remove, `ap-manager ssid remove ${plan.old!.name}`, <>Removes <b>{plan.old!.name}</b> from the declared state (switch-configuration-desired.json), with its passphrase and the zone's SSID; the access points keep broadcasting it until the reconcile.{disruption}</>) : null,
      declare: s.declare
        ? asStep(s.declare, `ap-manager ${s.declare.verb} ${plan.ssid}`, s.declare.verb === "ssid add"
          ? <>Declares <b>{plan.ssid}</b> for the whole site: zone <b>{plan.zone}</b>{plan.vlan !== null ? <> (VLAN {plan.vlan})</> : null}, {plan.security}, broadcast by every access point; the zone shows it as its SSID. There is no dry run: the preview is the command; nothing reaches an access point until the reconcile.</>
          : <>Changes <b>{plan.ssid}</b> in the declared state{s.declare.initial["--security"] ? <> to {plan.security}</> : null}{s.declare.initial["--enabled"] ? <>, broadcast again</> : null}; nothing reaches an access point until the reconcile.</>)
        : null,
      reconcile: asStep(s.reconcile, "ap-manager reconcile", <>The preview reads the access points and lists what would change on each (the delta); apply programs every one of them, with the passphrase from ~/.wlan-secrets.txt.{disruption}</>),
    };
  }, [plan]);
  const declareDone = !!steps && (!steps.declare || declared) && (!steps.remove || removed);

  const savePass = async () => {
    setMsg(null);
    const r = await post<SecretStatus>("secrets/wlan", { ssid: plan!.ssid, passphrase: pass });
    if (!r.ok) return setMsg(r.error);
    setPass("");
    setPassDone(true);
    setMsg(`kept for ${plan!.ssid} — the next reconcile pushes it to every access point; never shown again`);
    ssidsRead.reload();
  };

  const passRequired = needsPassphrase(plan?.security ?? security);
  const passOk = !passRequired || passDone || state === "set" || state === "changed";
  const stages = [
    { id: "network", title: "1 · The network", required: true, done: plan !== null, detail: "The SSID's name and how clients join; every access point broadcasts it." },
    { id: "declare", title: change && plan && plan.old && plan.old.name !== plan.ssid ? `2 · Replace ${plan.old.name} with ${plan.ssid}` : "2 · Declare the SSID", required: true, done: declareDone, detail: steps && !steps.declare && !steps.remove ? "Nothing to declare: the same SSID, the same security." : "In the declared state, each previewed." },
    { id: "passphrase", title: "3 · The passphrase", required: passRequired, done: plan !== null && declareDone && passOk, detail: passRequired ? "Handed to ap-manager on stdin; never shown again and never in a command." : `None: ${plan?.security ?? security} takes no passphrase.` },
    { id: "reconcile", title: "4 · Program the access points", required: true, done: reconciled, detail: "ap-manager reconcile: the delta per access point first, then apply." },
    { id: "result", title: `5 · The WiFi on ${z.zone}`, required: false, done: reconciled && !!live && live.zone === z.zone, detail: "What ap-manager now declares for the zone." },
  ];
  const current = !plan ? "network" : !declareDone ? "declare" : !passOk ? "passphrase" : !reconciled ? "reconcile" : "result";
  const passProblem = pass ? passphraseProblem(pass) : null;

  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal modal-wide" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={`${change ? "Change" : "Add"} WiFi for ${z.zone}`}>
        <header className="modal-head">
          <h2>{change ? "Change" : "Add"} WiFi for {z.zone}</h2>
          <button className="btn-x" onClick={onClose} aria-label="close">×</button>
        </header>
        <p className="small">
          Devices that join this SSID land in zone <b>{z.zone}</b> ({z.type}{z.vlan !== null ? `, VLAN ${z.vlan}` : ""}) with its rules. {old ? <>Today it is <b>{old.name}</b> ({old.security}), on {broadcastText(old)}.</> : "It has no SSID yet."} An SSID is site-wide: every access point ({apCount}) broadcasts it. Nothing reaches an access point until you apply the reconcile in stage 4.
        </p>
        <ol className="setup">
          <StepRow s={stages[0]} open={current === "network"}>
            <div className="form">
              <label className="form-row">
                <span>SSID *</span>
                <input type="text" value={name} disabled={plan !== null} onChange={(e) => setName(e.target.value)} />
                {problem ? <small className="ff-error">{problem}</small> : <small className="muted">The network's name as devices see it.{!old && !prefill?.ssid && ssid === defaultSsid(site, z) ? ` Proposed as ${site ? "<site>-" : ""}<zone>; name it as you like.` : ""}{z.declared && z.declared !== ssid && z.declared !== old?.name ? ` zones.json names ${z.declared} for this zone.` : ""}{old && old.name !== ssid ? ` Replaces ${old.name}: one SSID per zone.` : ""}</small>}
              </label>
              <label className="form-row">
                <span>security *</span>
                <select value={security} disabled={plan !== null} onChange={(e) => setSecurity(e.target.value)}>
                  {securities.map((c) => (
                    <option key={c} value={c}>{c}</option>
                  ))}
                </select>
                <small className="muted">{personal ? "A WPA passphrase every device types (stage 3)." : /enterprise/.test(security) ? "Each user logs in through RADIUS (the access point's RADIUS profile)." : "Open: anyone in range joins the zone."}</small>
              </label>
            </div>
            <div className="actions">
              {plan ? (
                <button className="btn" disabled={removed || declared || passDone} onClick={() => setPlan(null)}>Edit</button>
              ) : (
                <button className="btn btn-primary" disabled={problem !== null} onClick={() => setPlan({ ssid, zone: z.zone, vlan: z.vlan, security, old })}>
                  Continue
                </button>
              )}
              {!plan && problem ? <span className="muted small">name the SSID</span> : null}
            </div>
          </StepRow>
          <StepRow s={stages[1]} open={current === "declare"}>
            {steps ? (
              <>
                {steps.remove ? <StepView key={`r-${JSON.stringify(plan)}`} step={steps.remove} me={me} onDone={(ok) => ok && setRemoved(true)} /> : null}
                {steps.declare && (!steps.remove || removed) ? <StepView key={`d-${JSON.stringify(plan)}`} step={steps.declare} me={me} onDone={(ok) => ok && setDeclared(true)} /> : null}
                {steps.declare && steps.remove && !removed ? <p className="muted small">Next: ap-manager ssid add {plan!.ssid} — once {plan!.old!.name} is removed.</p> : null}
                {!steps.declare && !steps.remove ? <p className="muted small">{plan!.ssid} stays as it is; go on to its passphrase or the reconcile.</p> : null}
              </>
            ) : (
              <p className="muted small">Once the network is chosen.</p>
            )}
          </StepRow>
          <StepRow s={stages[2]} open={current === "passphrase"}>
            {!plan || !declareDone ? (
              <p className="muted small">Once the SSID is declared.</p>
            ) : !passRequired ? (
              <p className="muted small">{plan.security} takes no passphrase.</p>
            ) : (
              <div className="form">
                <label className="form-row">
                  <span>passphrase {state === "set" || state === "changed" ? "" : "*"}</span>
                  <span className="toolbar">
                    <input type="password" autoComplete="new-password" placeholder={state === "set" || state === "changed" ? "kept — type a new one to replace it" : "8 to 63 characters"} value={pass} onChange={(e) => setPass(e.target.value)} />
                    <button className="btn btn-primary" disabled={!pass || passProblem !== null || !canOperate(me)} onClick={() => void savePass()}>Save the passphrase</button>
                  </span>
                  <small className="muted">
                    {state ? <><Dot level={state === "not set" ? "warn" : "pass"} /> {plan.ssid}: {PASSPHRASE_TEXT[state]}. </> : null}
                    {passProblem ? <span className="ff-error">{passProblem}. </span> : null}
                    ap-manager stores it in ~/.wlan-secrets.txt (mode 600) and the reconcile pushes it to every access point that broadcasts {plan.ssid}; never shown again and never in a command.
                  </small>
                  {msg ? <small className="small">{msg}</small> : null}
                </label>
              </div>
            )}
          </StepRow>
          <StepRow s={stages[3]} open={current === "reconcile"}>
            {steps && declareDone && passOk ? <StepView step={steps.reconcile} me={me} onDone={(ok) => ok && setReconciled(true)} /> : <p className="muted small">Once the SSID is declared{passRequired ? " and its passphrase kept" : ""}.</p>}
          </StepRow>
          <StepRow s={stages[4]} open={current === "result"}>
            {live && live.zone === z.zone ? (
              <ul className="plain checks">
                <li>
                  <Dot level={live.disabled ? "skip" : "pass"} /> <b>{live.name}</b> → zone {live.zone}{typeof live.vlan === "number" ? ` (VLAN ${live.vlan})` : ""} · {live.security} · on {broadcastText(live)} · passphrase {PASSPHRASE_TEXT[passphraseOf(live)]}
                </li>
              </ul>
            ) : (
              <p className="muted small">No SSID bridges to {z.zone} yet.</p>
            )}
          </StepRow>
        </ol>
      </div>
    </div>
  );
}

export function WifiButton({ z, apCount, site }: { z: WifiZone; apCount: number; site: string }) {
  const [open, setOpen] = useState(false);
  const [prefill, setPrefill] = useState<TargetValues | null>(null);
  const operator = canOperate(useMe());
  useOpenedBy("add-wifi", z.zone, (v) => {
    setPrefill(v);
    setOpen(true);
  }, operator);
  if (!operator) return null;
  const label = `${wifiVerb(z)} WiFi for ${z.zone}…`;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>{label}</button>
      {/* Closing it re-reads the page: the zone may have its SSID now. */}
      {open ? <WifiWizard z={z} apCount={apCount} site={site} prefill={prefill} onClose={() => { setOpen(false); setPrefill(null); reloadAll(); }} /> : null}
    </>
  );
}
