// Enrol.tsx — Day 2's "Enrol a device for mgmt access": a laptop or phone
// running WireGuard becomes a peer of the admin VPN, which terminates on the
// firewall and reaches the management zone (ADMIN-VPN.md). 0 the four steps in
// plain words; 1 a key pair made on the device, whose public half is all the
// site needs; 2 the device registered (network-manager wgvpn add-peer, which
// prints the device's WireGuard file, the site's address and key in it); 3 that
// file completed with the private key, here in the browser or with one command,
// never sent anywhere; 4 the tunnel up, checked, and down.

import { useEffect, useMemo, useState } from "react";
import { useJob } from "../api";
import { Job, JobSummary } from "../types";
import { Command } from "../jobs";
import { ActStep } from "../flows";
import { JobView, Step } from "../operate";
import { useOpenedBy } from "../opener";
import { canOperate, useMe } from "../ui";
import { ResumeOffer, StepRow, Wizard, jobLabel, jobLive, useJobSession } from "../wizard";
import { argOf } from "../wizards";
import { download, wgConfig } from "./Setup";

// What the activity is, on Day 2's card and at the top of the form.
export const ENROL_TEXT = "Register a laptop or other device running WireGuard to be able to connect to the TAPPaaS management zone.";

const NAME = /^[a-z0-9][a-z0-9-]{0,30}$/;
const PUBKEY = /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/;
const PRIVKEY = /^[A-Za-z0-9+/]{43}=$/;
const ADDRESS = /^10\.255\.1\.(\d{1,3})$/;
const ENDPOINT = /^[A-Za-z0-9.-]+:\d{2,5}$/;

export function nameProblem(n: string): string | null {
  return !n ? "a name is needed" : !NAME.test(n) ? "letters, digits and dashes only (lars-laptop)" : null;
}
export function pubkeyProblem(k: string): string | null {
  return !k ? "the device's public key is needed" : !PUBKEY.test(k) ? "a WireGuard public key is 44 characters ending in =" : null;
}

export function EnrolWizard({ onClose, prefill }: { onClose: () => void; prefill?: Record<string, unknown> | null }) {
  const str = (k: string) => (typeof prefill?.[k] === "string" ? (prefill[k] as string) : "");
  const [name, setName] = useState(str("name"));
  const [pubkey, setPubkey] = useState(str("pubkey"));
  const [address, setAddress] = useState(str("ip"));
  const [endpoint, setEndpoint] = useState(str("endpoint"));
  const [more, setMore] = useState(!!(str("ip") || str("endpoint")));
  const [job, setJob] = useState<string | null>(null);
  const [done, setDone] = useState<boolean | null>(null);
  // Closed while the device was registered, or within the hour after: its
  // add-peer job is found again, and with it the WireGuard file to download.
  const [resumed, setResumed] = useState(false);
  const [declined, setDeclined] = useState(false);
  const session = useJobSession("network-manager", "wgvpn", (j) => j.argv.includes("add-peer"), job === null && !declined);
  // The registration's job: its output is the device's WireGuard file.
  const followed = useJob(job);
  const [installed, setInstalled] = useState(false);
  const [privkey, setPrivkey] = useState("");
  const [fill, setFill] = useState("");
  useEffect(() => {
    if (resumed && followed?.state === "done") setDone(followed.exit === 0);
  }, [followed?.state]);
  const restore = (j: JobSummary) => {
    setName(argOf(j.argv, "--name") ?? "");
    setPubkey(argOf(j.argv, "--pubkey") ?? "");
    setAddress(argOf(j.argv, "--ip") ?? "");
    setEndpoint(argOf(j.argv, "--endpoint") ?? "");
    setJob(j.id);
    setResumed(true);
  };
  const problem = nameProblem(name) ?? pubkeyProblem(pubkey.trim()) ?? (address && !ADDRESS.test(address) ? "the address is 10.255.1.x" : null) ?? (endpoint && !ENDPOINT.test(endpoint) ? "the endpoint is host:port" : null);
  const busy = job !== null;

  const register: Step = useMemo(
    () => ({
      title: `network-manager wgvpn add-peer --name ${name || "<device>"}`,
      button: `Register ${name || "the device"}`,
      bin: "network-manager",
      verb: "wgvpn",
      words: ["wgvpn", "add-peer"],
      fixed: [...(name ? ["--name", name] : []), ...(pubkey ? ["--pubkey", pubkey.trim()] : []), ...(address ? ["--ip", address] : []), ...(endpoint ? ["--endpoint", endpoint] : [])],
      hide: ["@setup|add-peer|remove-peer|list|config", "@options"],
      only: [],
      blocked: problem ?? undefined,
      note: "Registers the device as a peer of the admin VPN on the firewall and prints its WireGuard file: the tunnel address it was given, the site's DNS, and what it may reach (the management zone, and the published names).",
      // The form is this wizard's own: the fields above the step.
      render: () => (
        <>
          <label className="form-row">
            <span>device name *</span>
            <input type="text" placeholder="lars-laptop" value={name} disabled={busy} onChange={(e) => setName(e.target.value.trim().toLowerCase())} />
            <small className="muted">{name && nameProblem(name) ? <span className="ff-error">{nameProblem(name)}. </span> : null}How the site lists it, and the name of the file you get.</small>
          </label>
          <label className="form-row">
            <span>public key *</span>
            <input type="text" className="mono" placeholder="the 44 characters from stage 1" value={pubkey} disabled={busy} onChange={(e) => setPubkey(e.target.value.trim())} />
            <small className="muted">{pubkey && pubkeyProblem(pubkey) ? <span className="ff-error">{pubkeyProblem(pubkey)}. </span> : null}The public key from stage 1, not an IP address. The private key stays on the device.</small>
          </label>
          {more ? (
            <>
              <label className="form-row">
                <span>tunnel address</span>
                <input type="text" placeholder="blank: the next free 10.255.1.x" value={address} disabled={busy} onChange={(e) => setAddress(e.target.value.trim())} />
              </label>
              <label className="form-row">
                <span>endpoint</span>
                <input type="text" placeholder="blank: the site's own public address — host:port" value={endpoint} disabled={busy} onChange={(e) => setEndpoint(e.target.value.trim())} />
                <small className="muted">Where the device connects to: the satellite's or the site's public address, port 51821. Found on its own for a site with a satellite or a public address; given here otherwise.</small>
              </label>
            </>
          ) : (
            <p className="small"><button type="button" className="btn" onClick={() => setMore(true)}>More: a fixed tunnel address, another endpoint…</button></p>
          )}
        </>
      ),
      after: (j: Job) => (wgConfig(j.output) ? <p className="small">Registered. Its WireGuard file is in step 3.</p> : null),
    }),
    [name, pubkey, address, endpoint, more, busy, problem],
  );

  const file = `${name || "tappaas-admin"}.conf`;
  const conf = followed?.state === "done" && followed.exit === 0 ? wgConfig(followed.output) : null;
  const ENDPOINT_HOLE = /<[^>\n]*public-ip>(:\d+)/;
  const hole = conf ? ENDPOINT_HOLE.exec(conf) : null;
  const keyOk = PRIVKEY.test(privkey.trim());
  const endpointOk = !hole || ENDPOINT.test(fill.trim());
  // The file as downloaded: the site's address where add-peer could not find it,
  // and the private key when it was given here. Neither leaves this browser.
  const finished = conf
    ? conf.replace(ENDPOINT_HOLE, fill.trim() && endpointOk ? fill.trim() : "$&").replace("<PASTE-YOUR-PRIVATE-KEY>", keyOk ? privkey.trim() : "<PASTE-YOUR-PRIVATE-KEY>")
    : null;

  const stages = [
    { id: "how", title: "0 · How the tunnel is made", required: false, done: true, detail: "Four steps: a key pair on this device, the device registered with the site, its WireGuard file, the tunnel." },
    { id: "key", title: "1 · Make a key pair on the device", required: true, done: PUBKEY.test(pubkey) ? true : null, detail: "WireGuard identifies the device by a key pair made on the device itself. Only its public half is given to the site." },
    { id: "register", title: "2 · Register the device", required: true, done: done ?? (job ? null : false), detail: "The site records the device's public key and gives it a tunnel address. Its answer is the device's WireGuard file, with the site's address and key in it." },
    { id: "install", title: "3 · The WireGuard file", required: true, done: installed ? true : null, detail: "The file from step 2, completed with the device's private key. That key never leaves the device." },
    { id: "tunnel", title: "4 · The tunnel: up, check, down", required: true, done: null, detail: "Switch it on, see that it connected, switch it off when you are done." },
  ];
  const current = !done ? "register" : !installed ? "install" : "tunnel";

  return (
    <Wizard title="Enrol a device for mgmt access" onClose={onClose} running={followed && jobLive(followed) ? [jobLabel(followed)] : []} progress={done ? `${name || "the device"} is registered; its file can be downloaded again here within the hour.` : null} resumes>
      {session ? <ResumeOffer what={<>A device is being enrolled: <b>{argOf(session.argv, "--name") ?? "?"}</b></>} job={session} onContinue={() => restore(session)} onDecline={() => setDeclined(true)} decline="Enrol another device" /> : null}
      <p className="small">{ENROL_TEXT}</p>
      <ol className="setup">
        <StepRow s={stages[0]} open={!PUBKEY.test(pubkey) && !job}>
          <ol className="small">
            <li><b>A key pair on this device.</b> A private key that never leaves it, and its public half.</li>
            <li><b>Register the device.</b> The site takes the public key, gives the device a tunnel address, and answers with its own public key and address.</li>
            <li><b>The WireGuard file.</b> Your private key together with the site's address and public key: everything WireGuard needs to connect.</li>
            <li><b>The tunnel.</b> Switch it on, check it connected, and switch it off when you are done.</li>
          </ol>
        </StepRow>
        <StepRow s={stages[1]} open={!PUBKEY.test(pubkey)}>
          <div className="two">
            <div className="explain">
              <p><b>With the WireGuard app</b> (macOS, Windows, iOS, Android)</p>
              <ol>
                <li>Install WireGuard from the app store, open it.</li>
                <li>Add a tunnel: <b>Add empty tunnel</b> (on a phone: <b>Create from scratch</b>). The app makes the key pair and shows the <b>public key</b>, and the private key under it.</li>
                <li>Copy the public key into step 2.</li>
              </ol>
            </div>
            <div className="explain">
              <p><b>On a Linux or Mac terminal</b> (<span className="mono">brew install wireguard-tools</span> or <span className="mono">apt install wireguard-tools</span> first)</p>
              <p className="small">In the folder you will keep the tunnel in, run this. It prints the public key and keeps the private key in <span className="mono">tappaas-admin.key</span>:</p>
              <Command line="wg genkey | tee tappaas-admin.key | wg pubkey" />
              <p className="small">Copy the public key it printed into step 2.</p>
            </div>
          </div>
        </StepRow>
        <StepRow s={stages[2]} open={current === "register"}>
          {resumed && job ? (
            <JobView id={job} label="network-manager wgvpn add-peer" />
          ) : (
            <ActStep step={register} onApplied={setJob} onDone={(ok) => { setDone(ok); if (!ok) setJob(null); }} />
          )}
        </StepRow>
        <StepRow s={stages[3]} open={current === "install"}>
          {!done || !finished ? (
            <p className="muted small">Once the device is registered.</p>
          ) : (
            <div className="form">
              {hole ? (
                <label className="form-row">
                  <span>the site's address *</span>
                  <input type="text" placeholder="host:port — e.g. 203.0.113.5:51821" value={fill} onChange={(e) => setFill(e.target.value.trim())} />
                  <small className="muted">{fill && !endpointOk ? <span className="ff-error">host:port. </span> : null}The site could not tell its own public address: give the address this device reaches it at, port 51821.</small>
                </label>
              ) : null}
              <label className="form-row">
                <span>private key</span>
                <input type="password" autoComplete="off" spellCheck={false} placeholder="the private key from step 1" value={privkey} onChange={(e) => setPrivkey(e.target.value)} />
                <small className="muted">{privkey && !keyOk ? <span className="ff-error">a WireGuard key is 44 characters ending in =. </span> : null}Optional. Pasted here, the file you download is complete. It stays in this browser: nothing is sent.</small>
              </label>
              <div className="actions">
                <button className="btn btn-primary" disabled={!endpointOk} onClick={() => finished && download(file, finished)}>Download {file}{keyOk ? " (complete)" : ""}</button>
                {!endpointOk ? <span className="muted small">the site's address first</span> : null}
              </div>
              {!keyOk ? (
                <>
                  <p className="small">Without the key here: in the folder with both files, this puts it in and makes the file readable by you alone.</p>
                  <Command line={`sed -i.bak "s|<PASTE-YOUR-PRIVATE-KEY>|$(cat tappaas-admin.key)|" ${file} && rm ${file}.bak && chmod 600 ${file}`} />
                  <p className="small">With the app: open the tunnel from step 1, and paste everything in the file below its <span className="mono">PrivateKey</span> line.</p>
                </>
              ) : (
                <p className="small">The file holds the private key now: keep it like a password.</p>
              )}
              <div className="actions">
                <button className="btn" onClick={() => setInstalled(true)}>Continue</button>
              </div>
            </div>
          )}
        </StepRow>
        <StepRow s={stages[4]} open={current === "tunnel"}>
          {!installed ? (
            <p className="muted small">Once the file is ready.</p>
          ) : (
            <>
              <div className="two">
                <div className="explain">
                  <p><b>With the WireGuard app</b></p>
                  <ol>
                    <li><b>Import tunnel(s) from file</b>: {file}. On a phone, send the file to it.</li>
                    <li><b>Activate</b> it. It has connected once <b>Latest handshake</b> shows a time: <b>Active</b> alone is no proof.</li>
                    <li><b>Deactivate</b> it when you are done.</li>
                  </ol>
                </div>
                <div className="explain">
                  <p><b>On a terminal</b>, in the folder with {file}</p>
                  <Command label="up" line={`sudo wg-quick up ./${file}`} />
                  <Command label="check" line="sudo wg show" />
                  <p className="small">Connected once it shows a <b>latest handshake</b>.</p>
                  <Command label="down" line={`sudo wg-quick down ./${file}`} />
                </div>
              </div>
              <p className="small">Connected, the device reaches the management zone: this console, the Proxmox and firewall UIs, and ssh to every host, by their names. While the tunnel is on, the device asks the site for every name, so a tunnel with no handshake looks like losing the internet: switch it off.</p>
              <div className="actions">
                <button className="btn btn-primary" onClick={onClose}>Close</button>
              </div>
            </>
          )}
        </StepRow>
      </ol>
    </Wizard>
  );
}

export function EnrolButton() {
  const [open, setOpen] = useState(false);
  const [prefill, setPrefill] = useState<Record<string, unknown> | null>(null);
  useOpenedBy("enrol-device", undefined, (v) => {
    setPrefill(v);
    setOpen(true);
  });
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => { setPrefill(null); setOpen(true); }}>Enrol a device…</button>
      {open ? <EnrolWizard onClose={() => setOpen(false)} prefill={prefill} /> : null}
    </>
  );
}
