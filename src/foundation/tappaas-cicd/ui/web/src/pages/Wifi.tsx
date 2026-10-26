// Wifi.tsx — Day 2's "Add WiFi for <zone>": one SSID that puts clients on a
// zone's VLAN. 1 the network: the access point, the SSID's name, how clients
// join, and the WPA passphrase, written to ~/.wlan-secrets.txt through the
// secrets endpoint and never shown back or put in a command; 2 the mapping
// (ap-manager ssid <ap> add, after `ssid <ap> remove` of the SSID the zone
// had when it is a change); 3 the reconcile that programs the access point,
// previewed first; 4 the SSID on its zone, read back from ap-manager list.

import { useMemo, useState } from "react";
import { post, reloadAll, useRead, useVerb } from "../api";
import { Step, StepView } from "../operate";
import { TargetValue, TargetValues } from "../consoletargets";
import { useOpenedBy } from "../opener";
import { Dot, canOperate, useMe } from "../ui";
import { ApIn, StepSpec, WifiPlan, WifiZone, defaultAp, defaultSsid, needsPassphrase, ssidProblem, wifiSpecs, wifiVerb } from "../wizards";
import { SecretStatus, StepRow } from "./Setup";

const asStep = (spec: StepSpec, title: string, note: Step["note"]): Step => ({ ...spec, title, note, only: [], hide: ["@ssid"] });

function zoneSsids(zone: string, aps: ApIn[]) {
  return aps.flatMap((a) => (a.ssids ?? []).filter((s) => s.zone === zone).map((s) => ({ ap: a.name, ...s })));
}

const str = (v: TargetValue | undefined): string | null => (typeof v === "string" ? v : null);

// `prefill`: what the assistant opened it with (open_console add-wifi <zone>): ssid, ap, security.
export function WifiWizard({ z, aps, site, onClose, prefill }: { z: WifiZone; aps: ApIn[]; site: string; onClose: () => void; prefill?: TargetValues | null }) {
  const me = useMe();
  const verb = useVerb("ap-manager", "ssid <ap> add");
  const securities = verb?.options.find((o) => o.flag === "--security")?.choices ?? ["wpa2-personal"];
  const secrets = useRead<SecretStatus[]>("secrets", 600_000);
  const kept = (secrets.env?.data ?? []).find((x) => x.name === "wlan")?.keys ?? [];
  const change = wifiVerb(z) === "Change";
  const old = z.ssids[0] ?? null;
  const [ap, setAp] = useState(str(prefill?.ap) ?? defaultAp(z, aps));
  const [name, setName] = useState(str(prefill?.ssid) ?? defaultSsid(site, z));
  const [security, setSecurity] = useState(str(prefill?.security) ?? old?.security ?? "wpa2-personal");
  const [pass, setPass] = useState("");
  const [savedFor, setSavedFor] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [plan, setPlan] = useState<WifiPlan | null>(null);
  const [removed, setRemoved] = useState(false);
  const [added, setAdded] = useState(false);
  const [reconciled, setReconciled] = useState(false);
  const ssid = name.trim();
  const problem = ssidProblem(ssid);
  const personal = needsPassphrase(security);
  const passKept = savedFor === ssid || kept.includes(ssid);
  const ready = ap !== "" && problem === null && (!personal || passKept);
  const sameName = old !== null && old.name === ssid && old.ap === ap;
  // Read again while the result is awaited: the job's end re-reads it behind the console.
  const live = useRead<ApIn[]>("aps", added ? 5_000 : 300_000).env?.data ?? aps;
  const now = zoneSsids(z.zone, live);

  const savePass = async () => {
    setMsg(null);
    const r = await post<SecretStatus>("secrets/wlan", { ssid, passphrase: pass });
    if (!r.ok) return setMsg(r.error);
    setPass("");
    setSavedFor(ssid);
    setMsg(`kept for ${ssid} in ${r.data?.file ?? "~/.wlan-secrets.txt"} — never shown again`);
    secrets.reload();
  };

  const steps = useMemo(() => {
    if (!plan) return null;
    const s = wifiSpecs(plan);
    const disruption = plan.replace ? <> Clients on <b>{plan.replace.ssid}</b> lose the WiFi when the reconcile below programs the access point, and join <b>{plan.ssid}</b> with its passphrase.</> : null;
    return {
      remove: s.remove ? asStep(s.remove, `ap-manager ssid ${plan.replace!.ap} remove ${plan.replace!.ssid}`, <>Takes <b>{plan.replace!.ssid}</b> off {plan.replace!.ap} in the declared state (switch-configuration-desired.json); the AP keeps broadcasting it until the reconcile.{disruption}</>) : null,
      add: asStep(s.add, `ap-manager ssid ${plan.ap} add ${plan.ssid}`, <>Maps <b>{plan.ssid}</b> on {plan.ap} to zone <b>{plan.zone}</b>{plan.vlan !== null ? <> (VLAN {plan.vlan})</> : null}, {plan.security}, in the declared state. There is no dry run: the preview is the command; nothing reaches the access point until the reconcile.</>),
      reconcile: asStep(s.reconcile, "ap-manager reconcile", <>The preview reads the access points and lists what would change (the delta); apply programs them with the passphrase from ~/.wlan-secrets.txt.{disruption}</>),
    };
  }, [plan]);

  const stages = [
    { id: "network", title: "1 · The network", required: true, done: plan !== null, detail: "Which access point broadcasts it, the SSID's name, how clients join." },
    { id: "map", title: change ? `2 · Replace ${old!.name} with the new SSID` : `2 · Map the SSID to ${z.zone}`, required: true, done: added, detail: change ? "Remove the old mapping, then add the new one — each previewed." : `The SSID on the zone's VLAN${z.vlan !== null ? ` (${z.vlan})` : ""}, in the declared state.` },
    { id: "reconcile", title: "3 · Program the access point", required: true, done: reconciled, detail: "ap-manager reconcile: the delta first, then apply." },
    { id: "result", title: `4 · The WiFi on ${z.zone}`, required: false, done: reconciled && now.some((s) => s.name === plan?.ssid), detail: "What ap-manager now maps to the zone." },
  ];
  const current = !plan ? "network" : !added ? "map" : !reconciled ? "reconcile" : "result";

  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal modal-wide" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={`${change ? "Change" : "Add"} WiFi for ${z.zone}`}>
        <header className="modal-head">
          <h2>{change ? "Change" : "Add"} WiFi for {z.zone}</h2>
          <button className="btn-x" onClick={onClose} aria-label="close">×</button>
        </header>
        <p className="small">
          Devices that join this SSID land in zone <b>{z.zone}</b> ({z.type}{z.vlan !== null ? `, VLAN ${z.vlan}` : ""}) with its rules. {change ? <>Today it is <b>{old!.name}</b> on {old!.ap}{old!.security ? ` (${old!.security})` : ""}.</> : "It has no SSID yet."} Nothing reaches the access point until you apply the reconcile in stage 3.
        </p>
        <ol className="setup">
          <StepRow s={stages[0]} open={current === "network"}>
            <div className="form">
              <label className="form-row">
                <span>access point *</span>
                <select value={ap} disabled={plan !== null} onChange={(e) => setAp(e.target.value)}>
                  <option value="">—</option>
                  {aps.map((a) => (
                    <option key={a.name} value={a.name}>{a.name}{a.model ? ` (${a.model})` : ""} · {(a.ssids ?? []).length} SSID(s)</option>
                  ))}
                </select>
              </label>
              <label className="form-row">
                <span>SSID *</span>
                <input type="text" value={name} disabled={plan !== null} onChange={(e) => setName(e.target.value)} />
                {problem ? <small className="ff-error">{problem}</small> : <small className="muted">The network's name as devices see it.{z.declared && z.declared !== ssid ? ` zones.json names ${z.declared} for this zone.` : ""}</small>}
              </label>
              <label className="form-row">
                <span>security *</span>
                <select value={security} disabled={plan !== null} onChange={(e) => setSecurity(e.target.value)}>
                  {securities.map((c) => (
                    <option key={c} value={c}>{c}</option>
                  ))}
                </select>
                <small className="muted">{personal ? "A WPA passphrase every device types." : /enterprise/.test(security) ? "Each user logs in through RADIUS (the access point's RADIUS profile)." : "Open: anyone in range joins the zone."}</small>
              </label>
              {personal ? (
                <label className="form-row">
                  <span>passphrase *</span>
                  <span className="toolbar">
                    <input type="password" autoComplete="new-password" placeholder={passKept ? "kept — type a new one to replace it" : "8 to 63 characters"} value={pass} disabled={plan !== null || problem !== null} onChange={(e) => setPass(e.target.value)} />
                    <button className="btn" disabled={plan !== null || problem !== null || pass.length < 8 || pass.length > 63 || me?.role !== "installer"} onClick={() => void savePass()}>Save the passphrase</button>
                  </span>
                  <small className="muted">
                    {passKept ? <><Dot level="pass" /> a passphrase for {ssid} is kept in ~/.wlan-secrets.txt. </> : null}
                    Written to ~/.wlan-secrets.txt, where the access point plugin reads it; never shown again and never in a command.{me?.role !== "installer" ? " Saving it needs the Installer role." : ""}
                  </small>
                  {msg ? <small className="small">{msg}</small> : null}
                </label>
              ) : null}
            </div>
            <div className="actions">
              {plan ? (
                <button className="btn" disabled={removed || added} onClick={() => setPlan(null)}>Edit</button>
              ) : (
                <button className="btn btn-primary" disabled={!ready} onClick={() => setPlan({ ap, ssid, zone: z.zone, vlan: z.vlan, security, replace: old ? { ap: old.ap, ssid: old.name } : null })}>
                  Continue
                </button>
              )}
              {!plan && !ready ? <span className="muted small">{ap === "" ? "choose the access point" : problem ? "name the SSID" : "save the passphrase first"}</span> : null}
            </div>
            {sameName ? <p className="readstate readstate-warn">Same name on the same access point: the reconcile programs a new SSID or a new VLAN, not a new passphrase or security on one the access point already broadcasts. Give it a new name to have the change reach the devices.</p> : null}
          </StepRow>
          <StepRow s={stages[1]} open={current === "map"}>
            {steps ? (
              <>
                {steps.remove ? <StepView key={`r-${JSON.stringify(plan)}`} step={steps.remove} me={me} onDone={(ok) => ok && setRemoved(true)} /> : null}
                {!steps.remove || removed ? <StepView key={`a-${JSON.stringify(plan)}`} step={steps.add} me={me} onDone={(ok) => ok && setAdded(true)} /> : <p className="muted small">Next: ap-manager ssid {plan!.ap} add {plan!.ssid} — once the old mapping is removed.</p>}
              </>
            ) : (
              <p className="muted small">Once the network is chosen.</p>
            )}
          </StepRow>
          <StepRow s={stages[2]} open={current === "reconcile"}>
            {steps && added ? <StepView step={steps.reconcile} me={me} onDone={(ok) => ok && setReconciled(true)} /> : <p className="muted small">Once the SSID is mapped.</p>}
          </StepRow>
          <StepRow s={stages[3]} open={current === "result"}>
            {now.length ? (
              <ul className="plain checks">
                {now.map((s) => (
                  <li key={`${s.ap}/${s.name}`}>
                    <Dot level={s.enabled === false ? "skip" : "pass"} /> <b>{s.name}</b> on {s.ap} → zone {z.zone}{typeof s.vlan === "number" ? ` (VLAN ${s.vlan})` : ""}{s.security ? ` · ${s.security}` : ""}{s.enabled === false ? " · declared, off" : ""}
                  </li>
                ))}
              </ul>
            ) : (
              <p className="muted small">No SSID maps to {z.zone} yet.</p>
            )}
          </StepRow>
        </ol>
      </div>
    </div>
  );
}

export function WifiButton({ z, aps, site }: { z: WifiZone; aps: ApIn[]; site: string }) {
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
      <button className="btn" disabled={aps.length === 0} title={aps.length === 0 ? "No access point is registered (ap-manager add)" : undefined} onClick={() => setOpen(true)}>{label}</button>
      {/* Closing it re-reads the page: the zone may have its SSID now. */}
      {open ? <WifiWizard z={z} aps={aps} site={site} prefill={prefill} onClose={() => { setOpen(false); setPrefill(null); reloadAll(); }} /> : null}
    </>
  );
}
