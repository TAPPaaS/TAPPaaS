// AddSwitch.tsx — "Add a switch", on Day 1's Switch fabric step and Day 2's
// The site. Stage 1 chooses how the switch is managed; the stages after it
// follow from that:
//   an existing UniFi controller   its login, registered, its switches and APs
//                                  read, the node ports, the switches programmed
//   a UniFi controller installed   the unifi-os module, its owner set up in its
//                                  own page, then as above
//   a MikroTik RouterOS switch     the mikrotik module, the switch prepared in
//                                  RouterOS, its login and record, then as above
//   managed outside TAPPaaS        its record, the TAPPaaS machines on its
//                                  ports, and what to set on it by hand
// Every change is a manager verb run through its preview (StepView); the logins
// go to the secrets endpoint and are never shown again.

import { ReactNode, useState } from "react";
import { post, reloadAll, useRead } from "../api";
import { Command } from "../jobs";
import { Step, StepView } from "../operate";
import { ModuleSummary, Topology } from "../types";
import { canOperate, useMe } from "../ui";
import { DecideStep, StepRow, Wizard } from "../wizard";
import { AddRepositoryButton } from "./AddRepository";
import type { SecretStatus, SetupDoc } from "./Setup";
import { ADD_SWITCH_TEXT, SWITCH_KINDS, SwitchKind, hostOf } from "../switchadd";

interface ZoneRow {
  name: string;
  ip?: string;
}

const NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;

// What stays once the wizard is closed: the logins and the records written. Said
// at the top so a reopened wizard is not taken for a fresh one.
function Login({ title, fields, onSaved, saved, children }: { title: string; fields: { key: string; label: string; secret?: boolean; placeholder?: string; initial?: string }[]; onSaved: (values: Record<string, string>) => Promise<string | null>; saved: boolean; children?: ReactNode }) {
  const [v, setV] = useState<Record<string, string>>(Object.fromEntries(fields.filter((f) => f.initial).map((f) => [f.key, f.initial as string])));
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const missing = fields.find((f) => !(v[f.key] ?? "").trim());
  if (saved) return <p className="small">Saved: {title}. It is kept on the mothership and never shown again.</p>;
  return (
    <div className="form">
      {children}
      {fields.map((f) => (
        <label key={f.key} className="form-row">
          <span>{f.label} *</span>
          <input type={f.secret ? "password" : "text"} autoComplete={f.secret ? "new-password" : "off"} placeholder={f.placeholder} value={v[f.key] ?? ""} onChange={(e) => setV({ ...v, [f.key]: e.target.value })} />
        </label>
      ))}
      <div className="actions">
        <button
          className="btn btn-primary"
          disabled={busy || !!missing}
          onClick={async () => {
            setBusy(true);
            setMsg(null);
            const err = await onSaved(v);
            setBusy(false);
            if (err) setMsg(err);
            else setV({});
          }}
        >
          Save the login
        </button>
        {missing ? <span className="muted small">{missing.label} is missing</span> : null}
        {msg ? <span className="ff-error small">{msg}</span> : null}
      </div>
    </div>
  );
}

// The module a kind needs: installed already, installed here, or — when it
// lives in a repository the site does not have — that repository first.
function ModuleStage({ module, mods, repos, onDone }: { module: string; mods: ModuleSummary[] | null; repos: string[] | null; onDone: () => void }) {
  const me = useMe();
  const installed = (mods ?? []).some((m) => m.name === module);
  if (mods === null) return <p className="muted small">Reading the installed modules…</p>;
  if (installed) return <p className="small">The {module} module is installed.</p>;
  if (repos !== null && !repos.includes("Community")) {
    return (
      <p className="small toolbar">
        <span>The {module} module is in the Community repository, which this site does not have yet:</span>
        <AddRepositoryButton installed={repos} />
      </p>
    );
  }
  const step: Step = { title: `module-manager add ${module}`, bin: "module-manager", verb: "add", fixed: [module], button: `Install ${module}`, note: module === "unifi-os" ? "A Debian VM with UniFi OS Server, published inside the site as unifi-os.<domain>. It takes several minutes." : "Brings mikrotik-controller to the mothership; nothing is installed on a switch." };
  return <StepView step={step} me={me} onDone={(ok) => ok && onDone()} />;
}

// The node uplinks on the switch: one port record at a time, as many as there
// are machines on it. Optional: interrogate already names the ports with a link.
function NodePorts({ sw, nodes, onDone }: { sw: string; nodes: string[]; onDone: () => void }) {
  const me = useMe();
  const [n, setN] = useState(0);
  const [recorded, setRecorded] = useState<number>(0);
  const step: Step = {
    title: `switch-manager add-port ${sw}`,
    bin: "switch-manager",
    verb: "add-port",
    fixed: [sw],
    initial: { "--type": "node" },
    only: ["--type", "--target", "--target-port", "--description"],
    suggest: { "--target": nodes },
    labels: { "@port": "port", "--target": "machine", "--target-port": "its network port" },
    placeholders: { "@port": "the switch's port: 1, sfp-sfpplus1, …", "--target-port": "enp1s0, the bond's member, …" },
    button: "Record the port",
    note: "Which TAPPaaS machine is cabled to which port of the switch, so the port gets the trunk that machine needs.",
  };
  return (
    <>
      <StepView key={n} step={step} me={me} onDone={(ok) => ok && setRecorded((r) => r + 1)} />
      <div className="actions">
        {recorded > 0 ? <button className="btn" onClick={() => setN((x) => x + 1)}>Record another port</button> : null}
        <button className="btn btn-primary" onClick={onDone}>{recorded > 0 ? `Continue: ${recorded} port(s) recorded` : "Continue without recording a port"}</button>
      </div>
    </>
  );
}

export function AddSwitchWizard({ onClose }: { onClose: () => void }) {
  const me = useMe();
  const setup = useRead<SetupDoc>("setup").env?.data ?? null;
  const mods = useRead<ModuleSummary[]>("modules").env?.data ?? null;
  const zones = useRead<ZoneRow[]>("zones").env?.data ?? [];
  const nodes = setup?.inputs.siteNodes ?? [];
  const repos = setup?.inputs.repositories ?? null;
  const domain = setup?.inputs.defaultDomain ?? "";
  const mgmtNet = zones.find((z) => z.name === "mgmt")?.ip ?? "10.0.0.0/24";
  // The controllers registered already, as the switches behind them name them.
  const topo = useRead<Topology>("topology").env?.data ?? null;
  const secrets = useRead<SecretStatus[]>("secrets", 600_000).env?.data ?? [];
  const unifiSaved = secrets.find((x) => x.name === "unifi")?.present ?? false;
  const controllers = [...new Map((topo?.switches ?? []).filter((s) => s.controller).map((s) => [s.controller as string, s.controllerAddress ?? ""])).entries()].map(([name, address]) => ({ name, address }));

  const [choice, setChoice] = useState<SwitchKind | "">("");
  const [kind, setKind] = useState<SwitchKind | null>(null);
  const [moduleDone, setModuleDone] = useState(false);
  const [prepared, setPrepared] = useState(false); // the owner set up, or RouterOS prepared
  const [login, setLogin] = useState<{ url?: string; name?: string; ip?: string } | null>(null);
  const [registered, setRegistered] = useState(false);
  const [discovered, setDiscovered] = useState(false);
  const [ports, setPorts] = useState(false);
  const [programmed, setProgrammed] = useState(false);
  const [manualName, setManualName] = useState<string | null>(null);

  const unifi = kind === "unifi-existing" || kind === "unifi-install";
  const needsModule = kind === "unifi-install" || kind === "mikrotik";
  const moduleName = kind === "unifi-install" ? "unifi-os" : "mikrotik";
  // The controller this login is for: one registered already at its address or
  // under the name, else the name it gets.
  const known = login?.url ? controllers.find((c) => c.address === login.url || hostOf(c.address) === hostOf(login.url ?? "")) ?? null : null;
  const ctlName = known?.name ?? (kind === "unifi-install" ? "unifi-os" : "unifi-controller");
  const taken = !known && controllers.some((c) => c.name === ctlName);
  const swName = kind === "mikrotik" ? login?.name ?? "" : kind === "manual" ? manualName ?? "" : "";

  // ── the stages of each kind ──
  type Id = "kind" | "module" | "prepare" | "login" | "register" | "discover" | "ports" | "program" | "record" | "byhand";
  const plan: Id[] =
    kind === "unifi-existing" ? ["kind", "login", "register", "discover", "ports", "program"]
    : kind === "unifi-install" ? ["kind", "module", "prepare", "login", "register", "discover", "ports", "program"]
    : kind === "mikrotik" ? ["kind", "module", "prepare", "login", "discover", "ports", "program"]
    : kind === "manual" ? ["kind", "record", "ports", "byhand"]
    : ["kind"];
  const done: Record<Id, boolean> = {
    kind: kind !== null,
    module: moduleDone || (mods ?? []).some((m) => m.name === moduleName),
    prepare: prepared,
    login: kind === "mikrotik" ? login !== null && registered : login !== null,
    register: registered,
    discover: discovered,
    ports,
    program: programmed,
    record: manualName !== null,
    byhand: programmed,
  };
  const current = plan.find((id) => !done[id]) ?? null;
  const title: Record<Id, string> = {
    kind: "How the switch is managed",
    module: kind === "unifi-install" ? "Install UniFi OS Server" : "The MikroTik module",
    prepare: kind === "unifi-install" ? "Set up UniFi OS and adopt the switches" : "Prepare the switch in RouterOS",
    login: unifi ? "The controller's login" : "The switch: its address and login",
    register: "Register the controller",
    discover: unifi ? "Read the switches and access points" : "Read the switch's ports",
    ports: "The TAPPaaS machines on its ports",
    program: "Program the switches",
    record: "The switch",
    byhand: "What to set on it by hand",
  };
  const detail: Record<Id, string> = {
    kind: kind ? SWITCH_KINDS.find((k) => k.id === kind)!.label : "Four ways: choose the one that fits the switch.",
    module: kind === "unifi-install" ? "The unifi-os module: a VM running UniFi OS Server inside the site." : "Brings the controller TAPPaaS programs RouterOS with.",
    prepare: kind === "unifi-install" ? "Its owner account, then the switches and access points adopted, in UniFi OS's own page." : "Once on the switch: the bridge with VLAN filtering, a user for TAPPaaS, the API on.",
    login: unifi ? "A local admin of the controller (no Ubiquiti cloud login, no MFA)." : "Its name in TAPPaaS, its management address and the RouterOS user.",
    register: "switch-manager records the controller.",
    discover: unifi ? "Every switch and access point the controller has adopted; a free port is parked." : "Its ports; a free port is parked.",
    ports: "Optional: which machine is on which port, so its port gets the trunk it needs.",
    program: "switch-manager reconcile: preview, then apply.",
    record: "Its name, brand, model, address and location.",
    byhand: "The VLANs each recorded port needs: set them on the switch yourself.",
  };
  const stages = plan.map((id, i) => ({ id, title: `${i + 1} · ${title[id]}`, required: id !== "ports", done: done[id] ? true : id === current ? false : null, detail: detail[id] }));
  const row = (id: Id, body: ReactNode) => {
    const s = stages.find((x) => x.id === id);
    return s ? <StepRow key={id} s={s} open={current === id}>{body}</StepRow> : null;
  };

  const restart = () => {
    setKind(null);
    setModuleDone(false);
    setPrepared(false);
    setLogin(null);
    setRegistered(false);
    setDiscovered(false);
    setPorts(false);
    setProgrammed(false);
    setManualName(null);
  };
  const started = login !== null || registered || manualName !== null || moduleDone;

  const unifiUrl = kind === "unifi-install" && domain ? `https://unifi-os.${domain}` : "";

  return (
    <Wizard title="Add a switch" onClose={onClose} progress={started && current ? "what is saved and recorded stays; reopening starts again at the choice" : null}>
      <p className="small">{ADD_SWITCH_TEXT}</p>
      <ol className="setup">
        {row(
          "kind",
          <DecideStep decided={kind !== null} locked={started} ready={choice !== ""} hint={choice === "" ? "choose one" : null} onChange={restart} onContinue={() => setKind(choice as SwitchKind)}>
            <div className="form">
              {SWITCH_KINDS.map((k) => (
                <label key={k.id} className="form-check">
                  <input type="radio" name="switch-kind" checked={choice === k.id} onChange={() => setChoice(k.id)} />
                  <span><b>{k.label}</b><br /><small className="muted">{k.text}</small></span>
                </label>
              ))}
            </div>
          </DecideStep>,
        )}
        {row("module", needsModule ? <ModuleStage module={moduleName} mods={mods} repos={repos} onDone={() => setModuleDone(true)} /> : null)}
        {row(
          "prepare",
          kind === "unifi-install" ? (
            <>
              <ol className="small">
                <li>Open <a href={unifiUrl || undefined} target="_blank" rel="noreferrer">{unifiUrl || "https://unifi-os.<domain>"}</a> from mgmt or the admin VPN (or the VM's own address on port 11443) and create the owner account. Make it a local account: TAPPaaS logs in as it, and a Ubiquiti cloud login or MFA is refused.</li>
                <li>Adopt the switches and access points: they show up for adoption once they are cabled to the LAN.</li>
              </ol>
              <div className="actions"><button className="btn btn-primary" onClick={() => setPrepared(true)}>Done: the owner exists and the devices are adopted</button></div>
            </>
          ) : (
            <>
              <p className="small">On the switch, once, in its terminal (WinBox or SSH). Keep the switch's own management address on a port or VLAN TAPPaaS does not program.</p>
              <Command label="the bridge filters VLANs" line="/interface bridge set bridge vlan-filtering=yes" />
              <Command label="a group and a user for TAPPaaS" line="/user group add name=tappaas policy=read,write,api,test" />
              <Command label="its password: a long one" line="/user add name=tappaas group=tappaas password=<a long password>" />
              <Command label="the API, open to the mgmt network only" line={`/ip service set api address=${mgmtNet} disabled=no`} />
              <div className="actions"><button className="btn btn-primary" onClick={() => setPrepared(true)}>Done on the switch</button></div>
            </>
          ),
        )}
        {row(
          "login",
          unifi ? (
            <>
            {kind === "unifi-existing" && unifiSaved && controllers.length && login === null ? (
              <p className="small toolbar">
                <span>A UniFi login is saved already, for <b>{controllers[0].name}</b> ({controllers[0].address}).</span>
                <button className="btn" onClick={() => { setLogin({ url: controllers[0].address }); setRegistered(true); }}>Keep it, and read its switches again</button>
              </p>
            ) : null}
            <Login
              title={`the login to ${login?.url ?? "the controller"}`}
              saved={login !== null}
              fields={[
                { key: "url", label: "controller address", placeholder: "https://10.0.0.5:11443", initial: unifiUrl },
                { key: "username", label: "local admin" },
                { key: "password", label: "password", secret: true },
              ]}
              onSaved={async (v) => {
                const r = await post("secrets/unifi", { url: v.url.trim(), username: v.username, password: v.password });
                if (!r.ok) return r.error;
                setLogin({ url: v.url.trim() });
                return null;
              }}
            />
            </>
          ) : kind === "mikrotik" ? (
            login === null ? (
              <Login
                title="the RouterOS login"
                saved={false}
                fields={[
                  { key: "name", label: "its name in TAPPaaS", placeholder: "crs-a" },
                  { key: "ip", label: "its management address", placeholder: "10.0.0.5" },
                  { key: "username", label: "RouterOS user", initial: "tappaas" },
                  { key: "password", label: "its password", secret: true },
                ]}
                onSaved={async (v) => {
                  const name = v.name.trim();
                  if (!NAME.test(name)) return "the name: lower case letters, digits and -";
                  const r = await post("secrets/mikrotik", { switch: name, username: v.username, password: v.password });
                  if (!r.ok) return r.error;
                  setLogin({ name, ip: v.ip.trim() });
                  return null;
                }}
              />
            ) : (
              <>
                <p className="small">Saved: the RouterOS login of <b>{login.name}</b>. Now its record:</p>
                <StepView
                  step={{ title: `switch-manager add-switch ${login.name}`, bin: "switch-manager", verb: "add-switch", fixed: [login.name ?? ""], initial: { "--vendor": "mikrotik", "--managed": "auto", "--ip": login.ip ?? "" }, only: ["--model", "--location", "--description"], hide: ["--vendor", "--managed", "--ip", "--controller"], button: `Record ${login.name}` }}
                  me={me}
                  onDone={(ok) => ok && setRegistered(true)}
                />
              </>
            )
          ) : null,
        )}
        {row(
          "register",
          login?.url ? (
            known || taken ? (
              <>
                <p className="small">{known ? <>The controller at {known.address} is registered already, as <b>{known.name}</b>.</> : <>A controller named <b>{ctlName}</b> is registered already, at another address: its switches are read with the login just saved.</>}</p>
                <div className="actions"><button className="btn btn-primary" onClick={() => setRegistered(true)}>Continue</button></div>
              </>
            ) : (
              <StepView
                step={{ title: `switch-manager add-controller ${ctlName}`, bin: "switch-manager", verb: "add-controller", fixed: [ctlName], initial: { "--vendor": "unifi", "--ip": login.url }, hide: ["--vendor", "--managed"], button: `Register ${ctlName}`, note: "Its address is the URL the login above is for." }}
                me={me}
                onDone={(ok) => ok && setRegistered(true)}
              />
            )
          ) : (
            <p className="muted small">Once the login is saved.</p>
          ),
        )}
        {row(
          "discover",
          registered ? (
            <StepView
              step={{ title: "switch-manager interrogate", bin: "switch-manager", verb: "interrogate", button: unifi ? "Read the switches and access points" : `Read ${swName}'s ports`, note: "A port with no record and no link is parked: an access port in iotLocal, with no internet and nothing else reachable. A port with a link is left as it is." }}
              me={me}
              onDone={(ok) => ok && setDiscovered(true)}
            />
          ) : (
            <p className="muted small">Once it is registered.</p>
          ),
        )}
        {row(
          "record",
          kind === "manual" ? (
            manualName === null ? (
              <ManualRecord onDone={setManualName} />
            ) : (
              <p className="small"><b>{manualName}</b> is recorded, managed outside TAPPaaS.</p>
            )
          ) : null,
        )}
        {row(
          "ports",
          (kind === "manual" ? manualName !== null : discovered) ? (
            kind === "manual" || swName ? (
              <NodePorts sw={kind === "manual" ? manualName ?? "" : swName} nodes={nodes} onDone={() => setPorts(true)} />
            ) : (
              <>
                <p className="small">The switches are read. Which machine is on which port is recorded per switch: choose one, record its ports, and continue.</p>
                <SwitchPortsByName nodes={nodes} controller={ctlName} topo={topo} onDone={() => setPorts(true)} />
              </>
            )
          ) : (
            <p className="muted small">{kind === "manual" ? "Once the switch is recorded." : "Once the ports are read."}</p>
          ),
        )}
        {row(
          "program",
          ports ? (
            <StepView
              step={{ title: "switch-manager reconcile", bin: "switch-manager", verb: "reconcile", hide: ["--park-zone"], button: "Program the switches", note: "The preview lists every port it would set, the parked ones too; apply pushes them through the controller." }}
              me={me}
              onDone={(ok) => ok && setProgrammed(true)}
            />
          ) : (
            <p className="muted small">Once the ports are recorded, or skipped.</p>
          ),
        )}
        {row(
          "byhand",
          ports ? (
            <StepView
              step={{ title: "switch-manager reconcile", bin: "switch-manager", verb: "reconcile", hide: ["--park-zone"], button: "Show what to set", note: `For ${manualName}, reconcile programs nothing: it prints, port by port, the VLANs to set on the switch yourself.` }}
              me={me}
              onDone={(ok) => ok && setProgrammed(true)}
            />
          ) : (
            <p className="muted small">Once the ports are recorded, or skipped.</p>
          ),
        )}
      </ol>
      {current === null ? (
        <div className="actions">
          <span className="small">Done. Add the next switch with this wizard again; on Day 1, answer "No more switches" once they are all in.</span>
          <button className="btn btn-primary" onClick={onClose}>Close</button>
        </div>
      ) : null}
    </Wizard>
  );
}

// The record of a switch managed outside TAPPaaS: its name first, then its details.
function ManualRecord({ onDone }: { onDone: (name: string) => void }) {
  const me = useMe();
  const [name, setName] = useState("");
  const [decided, setDecided] = useState<string | null>(null);
  if (!decided) {
    return (
      <div className="form">
        <label className="form-row">
          <span>its name in TAPPaaS *</span>
          <input type="text" value={name} placeholder="office-switch" onChange={(e) => setName(e.target.value.trim())} />
          <small className="muted">Lower case letters, digits and -: how the physical view and the port records name it.</small>
        </label>
        <div className="actions">
          <button className="btn btn-primary" disabled={!NAME.test(name)} onClick={() => setDecided(name)}>Continue</button>
          {name && !NAME.test(name) ? <span className="ff-error small">lower case letters, digits and -</span> : null}
        </div>
      </div>
    );
  }
  const step: Step = {
    title: `switch-manager add-switch ${decided}`,
    bin: "switch-manager",
    verb: "add-switch",
    fixed: [decided],
    initial: { "--managed": "manual" },
    hide: ["--managed", "--controller"],
    labels: { "--vendor": "brand", "--ip": "management address" },
    placeholders: { "--vendor": "netgear, tp-link, cisco, …" },
    button: `Record ${decided}`,
    note: "TAPPaaS never logs in to it: it keeps its record, so the machines on it can be placed and its ports listed.",
  };
  return <StepView step={step} me={me} onDone={(ok) => ok && onDone(decided)} />;
}

// After a controller is read: the port records of one of the switches it has.
function SwitchPortsByName({ nodes, controller, topo, onDone }: { nodes: string[]; controller: string; topo: Topology | null; onDone: () => void }) {
  const names = (topo?.switches ?? []).filter((s) => !s.controller || s.controller === controller).map((s) => s.name);
  const [sw, setSw] = useState("");
  const [chosen, setChosen] = useState<string | null>(null);
  if (chosen) return <NodePorts sw={chosen} nodes={nodes} onDone={onDone} />;
  return (
    <div className="form">
      <label className="form-row">
        <span>switch</span>
        <select value={sw} onChange={(e) => setSw(e.target.value)}>
          <option value="">{topo ? (names.length ? "— choose a switch" : "— no switch read yet") : "reading the switches…"}</option>
          {names.map((n) => <option key={n} value={n}>{n}</option>)}
        </select>
      </label>
      <div className="actions">
        <button className="btn" disabled={!sw} onClick={() => setChosen(sw)}>Record its ports</button>
        <button className="btn btn-primary" onClick={onDone}>Continue without recording a port</button>
      </div>
    </div>
  );
}

export function AddSwitchButton({ label = "Add a switch…" }: { label?: string }) {
  const [open, setOpen] = useState(false);
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>{label}</button>
      {open ? <AddSwitchWizard onClose={() => { setOpen(false); reloadAll(); }} /> : null}
    </>
  );
}
