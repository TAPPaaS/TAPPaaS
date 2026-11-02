// Enrol.tsx — Day 2's "Enrol a device for mgmt access": a laptop or phone
// running WireGuard becomes a peer of the admin VPN, which terminates on the
// firewall and reaches the management zone (ADMIN-VPN.md). 1 a key pair made
// on the device, whose public half is all the site needs; 2 the device
// registered (network-manager wgvpn add-peer, which prints the device's
// WireGuard file); 3 the file on the device, its private key pasted in, the
// tunnel activated.

import { useEffect, useMemo, useState } from "react";
import { useJob } from "../api";
import { Job, JobSummary } from "../types";
import { Output } from "../jobs";
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
  const followed = useJob(resumed ? job : null);
  useEffect(() => {
    if (followed?.state === "done") setDone(followed.exit === 0);
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
      after: (j: Job) => {
        const conf = wgConfig(j.output);
        if (!conf) return null;
        return (
          <div>
            <Output text={conf} />
            <button className="btn btn-primary" onClick={() => download(`${name || "tappaas-admin"}.conf`, conf)}>Download {name || "tappaas-admin"}.conf</button>
          </div>
        );
      },
    }),
    [name, pubkey, address, endpoint, more, busy, problem],
  );

  const stages = [
    { id: "key", title: "1 · Make a key pair on the device", required: true, done: PUBKEY.test(pubkey) ? true : null, detail: "WireGuard identifies the device by a key pair made on the device itself. Only its public half is given to the site." },
    { id: "register", title: "2 · Register the device", required: true, done: done ?? (job ? null : false), detail: "The site records the device and gives it a tunnel address. You download the device's WireGuard file: everything but the private key, which the site never sees." },
    { id: "install", title: "3 · Put the file on the device and connect", required: true, done: null, detail: "The file gets its private key on the device and goes into WireGuard. The tunnel is switched on and checked for a handshake." },
  ];
  // Stages 1 and 2 are open together: the key made in 1 is typed into 2.
  const current = !done ? "register" : "install";

  return (
    <Wizard title="Enrol a device for mgmt access" onClose={onClose} running={followed && jobLive(followed) ? [jobLabel(followed)] : []} progress={done ? `${name || "the device"} is registered; its file can be downloaded again here within the hour.` : null} resumes>
      {session ? <ResumeOffer what={<>A device is being enrolled: <b>{argOf(session.argv, "--name") ?? "?"}</b></>} job={session} onContinue={() => restore(session)} onDecline={() => setDeclined(true)} decline="Enrol another device" /> : null}
      <p className="small">{ENROL_TEXT}</p>
      <ol className="setup">
        <StepRow s={stages[0]} open={!PUBKEY.test(pubkey)}>
          <div className="two">
            <div className="explain">
              <p><b>With the WireGuard app</b> (macOS, Windows, iOS, Android)</p>
              <ol>
                <li>Install WireGuard from the app store, open it.</li>
                <li>Add a tunnel: <b>Add empty tunnel</b> (on a phone: <b>Create from scratch</b>). The app makes the key pair and shows the <b>public key</b>.</li>
                <li>Copy the public key into stage 2. Leave the tunnel open: its file comes in stage 3.</li>
              </ol>
            </div>
            <div className="explain">
              <p><b>On a Linux or Mac terminal</b></p>
              <ol>
                <li>Install the tools: <span className="mono">apt install wireguard-tools</span> or <span className="mono">brew install wireguard-tools</span>.</li>
                <li><span className="mono">wg genkey | tee tappaas-admin.key | wg pubkey</span> — prints the public key; the private key is in <span className="mono">tappaas-admin.key</span>.</li>
                <li>Copy the public key into stage 2. Keep <span className="mono">tappaas-admin.key</span>: the key pair alone opens no tunnel. Stage 2 gives you the <span className="mono">.conf</span> file with a blank for the private key, and stage 3 fills it in here on the device.</li>
              </ol>
            </div>
          </div>
        </StepRow>
        <StepRow s={stages[1]} open={current === "register"}>
          {resumed && job ? (
            <>
              <JobView id={job} label="network-manager wgvpn add-peer" />
              {followed?.state === "done" && followed.exit === 0 ? register.after?.(followed) : null}
            </>
          ) : (
            <ActStep step={register} onApplied={setJob} onDone={(ok) => { setDone(ok); if (!ok) setJob(null); }} />
          )}
        </StepRow>
        <StepRow s={stages[2]} open={current === "install"}>
          {done ? (
            <ol>
              <li>Download the file from stage 2 ({name || "tappaas-admin"}.conf). Open it in a text editor and put the device's <b>private key</b> where it says <span className="mono">PrivateKey = &lt;PASTE-YOUR-PRIVATE-KEY&gt;</span>. If the <span className="mono">Endpoint</span> line is a placeholder, put the site's public address there, port 51821.</li>
              <li><b>WireGuard app:</b> import the file (<b>Import tunnel(s) from file</b>; on a phone, send the file to it or scan it as a QR code), or paste its contents into the tunnel from stage 1 under the key the app made. <b>Terminal:</b> in the folder with both files, run <span className="mono">sed -i.bak "s|&lt;PASTE-YOUR-PRIVATE-KEY&gt;|$(cat tappaas-admin.key)|" {name || "tappaas-admin"}.conf</span>, then <span className="mono">chmod 600 {name || "tappaas-admin"}.conf</span> and <span className="mono">sudo wg-quick up ./{name || "tappaas-admin"}.conf</span>. The file now holds the private key, so keep it private.</li>
              <li>Switch the tunnel on, then check that it connected: the app's <b>latest handshake</b> shows a time, or <span className="mono">sudo wg show</span> prints it. <b>Active alone proves nothing:</b> the app shows it with no connection. With a handshake, the device reaches the management zone: this console, the Proxmox and firewall UIs, and ssh to every host, by their names.</li>
              <li>No handshake? Switch the tunnel off. While it is on, the device asks the site for every name, so a dead tunnel looks like losing the internet.</li>
            </ol>
          ) : (
            <p className="muted small">Once the device is registered.</p>
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
