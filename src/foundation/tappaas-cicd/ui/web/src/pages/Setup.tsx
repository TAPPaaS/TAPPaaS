// Setup — the rest of the installation after bootstrap.sh (ADR-034 D10, spike
// §5.12). An ordered checklist whose state the backend derives from the
// records each time (GET /setup), so it resumes wherever the install stands;
// each step is a form over its verbs, run as jobs with their previews, and the
// secrets the scripts read are entered here and never shown again. The same
// flows serve day 2: add a node, an environment, a stack; enrol a device.

import { ReactNode, useState } from "react";
import { get, post, useRead } from "../api";
import { Output, stripAnsi } from "../jobs";
import { OperateButton, Step } from "../operate";
import { Job, SiteRead } from "../types";
import { Dot, Link, ReadState, Section, since } from "../ui";
import { addEnvironmentSteps } from "./Environments";

interface SetupStep {
  id: string;
  title: string;
  required: boolean;
  done: boolean | null;
  detail: string;
}
interface SetupDoc {
  steps: SetupStep[];
  complete: boolean;
  inputs: { defaultEnv: string | null; dnsMode: string | null };
  token: { active: boolean; present: boolean; identityInstalled: boolean };
}
interface SecretStatus {
  name: string;
  file: string;
  what: string;
  present: boolean;
  keys: string[];
  modified: string | null;
}

// ── the day-2 wizards, shared with the pages ──────────────────────────

export function addNodeSteps(): Step[] {
  return [
    {
      title: "1 · Join the node: site-manager node add <N> --pxe",
      bin: "site-manager",
      verb: "node add",
      initial: { "--pxe": true, "--yes": true },
      note: "Boot the new machine from the network (PXE) once this runs. Give the boot disk, the WAN port (or --no-wan) and the LAN ports here: the console cannot answer the manager's questions on a terminal. There is no dry run; --config-only only declares it in site.json.",
    },
    { title: "2 · Register it: site-manager node reconcile", bin: "site-manager", verb: "node reconcile", note: "The preview lists the nodes that joined the cluster and are not in site.json; apply registers them." },
  ];
}

export function addStackSteps(stack?: string): Step[] {
  return [
    {
      title: "Add a stack: module-manager add-stack <stack>",
      bin: "module-manager",
      verb: "add-stack",
      fixed: stack ? [stack] : [],
      note: "The preview is the plan (add-stack --dry-run): the modules in dependsOn order, what is skipped, what is missing outside the stack, the hand steps. Apply installs them one by one; the first failure stops it, and running it again resumes.",
    },
  ];
}

// The wg-quick file add-peer prints (status lines go to stderr, mixed in the output).
export function wgConfig(output: string): string | null {
  const text = stripAnsi(output);
  const at = text.indexOf("[Interface]");
  if (at < 0) return null;
  const lines = text.slice(at).split("\n");
  const out: string[] = [];
  for (const l of lines) {
    if (/^\[(Interface|Peer)\]$/.test(l.trim()) || /^[A-Za-z]+\s*=/.test(l.trim()) || l.trim() === "" || l.trim().startsWith("#")) out.push(l);
    else break;
  }
  return out.join("\n").trim() + "\n";
}

function download(name: string, text: string): void {
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function enrolSteps(): Step[] {
  return [
    {
      title: "Enrol a device in the admin VPN: network-manager wgvpn add-peer",
      bin: "network-manager",
      verb: "wgvpn",
      words: ["wgvpn", "add-peer"],
      hide: ["@setup|add-peer|remove-peer|list|config", "@options"],
      note: (
        <>
          On the device: <span className="mono">wg genkey | tee private.key | wg pubkey</span> — give its public key here (the private key never leaves it). Under "more options" give, one per line:
          <span className="mono"> --name &lt;device&gt;</span>, <span className="mono">--pubkey &lt;key&gt;</span>, optionally <span className="mono">--ip 10.255.1.x</span> and <span className="mono">--endpoint host:port</span>. The result is a wg-quick file to download; paste the private key into it.
        </>
      ),
      after: (job: Job) => {
        const conf = wgConfig(job.output);
        if (!conf) return null;
        const name = /--name\s+(\S+)/.exec((job.ran ?? []).join(" "))?.[1] ?? "tappaas-admin";
        return (
          <div>
            <Output text={conf} />
            <button className="btn btn-primary" onClick={() => download(`${name}.conf`, conf)}>Download {name}.conf</button>
          </div>
        );
      },
    },
  ];
}

// ── secrets ───────────────────────────────────────────────────────────

function SecretForm({ name, fields, status, onSaved }: { name: string; fields: { key: string; label: string; secret?: boolean; placeholder?: string }[]; status: SecretStatus | undefined; onSaved: () => void }) {
  const [v, setV] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<string | null>(null);
  const save = async () => {
    setMsg(null);
    const body: Record<string, unknown> = {};
    const keys: Record<string, string> = {};
    for (const f of fields) {
      if (f.key.startsWith("dns_") || f.key === "@key") continue;
      body[f.key] = v[f.key] ?? "";
    }
    if (name === "acme-dns" && v["@key"]) keys[v["@key"]] = v["@value"] ?? "";
    if (name === "acme-dns") body.keys = keys;
    const r = await post<SecretStatus>(`secrets/${name}`, body);
    if (!r.ok) return setMsg(r.error);
    setV({});
    setMsg(`saved: ${(r.data?.keys ?? []).join(", ")}`);
    onSaved();
  };
  return (
    <div className="secret">
      <p className="small muted">
        {status?.what} · <span className="mono">{status?.file}</span> · {status?.present ? `set (${status.keys.join(", ")}) ${since(status.modified)}` : "not set"}
      </p>
      <div className="form">
        {fields.map((f) => (
          <label key={f.key} className="form-row">
            <span>{f.label}</span>
            <input type={f.secret ? "password" : "text"} autoComplete="off" placeholder={f.placeholder} value={v[f.key] ?? ""} onChange={(e) => setV({ ...v, [f.key]: e.target.value })} />
          </label>
        ))}
      </div>
      <div className="actions">
        <button className="btn btn-primary" onClick={() => void save()}>Save (never shown again)</button>
        {msg ? <span className="small">{msg}</span> : null}
      </div>
    </div>
  );
}

// ── the checklist ─────────────────────────────────────────────────────

function StepRow({ s, children }: { s: SetupStep; children?: ReactNode }) {
  const [open, setOpen] = useState(s.done !== true);
  return (
    <li className={`setup-step setup-${s.done === true ? "done" : s.done === false ? "todo" : "unknown"}`}>
      <button className="setup-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <Dot level={s.done === true ? "pass" : s.done === false ? (s.required ? "fail" : "skip") : "warn"} />
        <b>{s.title}</b>
        <span className="muted small">{s.done === true ? "done" : s.done === false ? (s.required ? "to do" : "optional") : "unknown"}</span>
        <span className="spacer" />
        <span className="muted">{open ? "▾" : "▸"}</span>
      </button>
      <p className="small setup-detail">{s.detail}</p>
      {open && children ? <div className="setup-body">{children}</div> : null}
    </li>
  );
}

const mm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "module-manager", verb, ...extra });

export function Setup() {
  const r = useRead<SetupDoc>("setup", 600_000);
  const secrets = useRead<SecretStatus[]>("secrets", 600_000);
  const site = useRead<SiteRead>("site").env?.data?.site;
  const [checking, setChecking] = useState(false);
  const d = r.env?.data;
  const sec = (n: string) => (secrets.env?.data ?? []).find((x) => x.name === n);
  const check = () => {
    setChecking(true);
    void get("setup?refresh=1").finally(() => {
      setChecking(false);
      r.reload();
    });
  };
  const email = typeof site?.email === "string" ? site.email : "";
  const org = (site?.defaultEnvironment as string | undefined) ?? site?.name ?? "";
  const domain = d?.inputs.defaultEnv ?? "";

  const body: Record<string, ReactNode> = {
    tls:
      d?.inputs.dnsMode === "wildcard" ? (
        <>
          <SecretForm name="acme-dns" status={sec("acme-dns")} onSaved={secrets.reload} fields={[{ key: "provider", label: "DNS provider", placeholder: "cloudflare, gandi_livedns, …" }, { key: "@key", label: "its key name", placeholder: "dns_cf_token, dns_gandi_livedns_token, …" }, { key: "@value", label: "its value", secret: true }]} />
          <OperateButton label="Issue the certificate…" title="acme-setup.sh" steps={[{ title: "acme-setup.sh --no-save-creds", bin: "acme-setup.sh", verb: "acme-setup", initial: { "--no-save-creds": true }, note: "Reads the credential saved above; issues *.<domain> on the firewall and records its refid in config/cert-refids.json." }]} />
        </>
      ) : (
        <p className="small">Nothing to do: with dnsMode per-service Caddy gets each published route's certificate itself.</p>
      ),
    bootstrap: (
      <OperateButton
        label="Bootstrap identities…"
        title="identity-manager bootstrap"
        steps={[
          { title: "1 · Seed config/identities: identity-manager bootstrap", bin: "identity-manager", verb: "bootstrap", initial: { "--org": org, "--email": email, "--user": email.split("@")[0]?.toLowerCase().replace(/[^a-z0-9-]/g, "-") ?? "" }, hide: ["--minimal-org", "--skip-validate"] },
          { title: "2 · Push to Authentik: identity-manager reconcile", bin: "identity-manager", verb: "reconcile", hide: ["--dry-run"] },
        ]}
      />
    ),
    nodes: <OperateButton label="Add a node…" title="Add a node" steps={addNodeSteps()} />,
    switch: (
      <>
        <SecretForm name="unifi" status={sec("unifi")} onSaved={secrets.reload} fields={[{ key: "url", label: "controller URL", placeholder: "https://10.0.0.5:11443" }, { key: "username", label: "local admin" }, { key: "password", label: "password", secret: true }]} />
        <OperateButton
          label="Register the switch…"
          title="Register and interrogate the switch"
          steps={[
            { title: "1 · The controller: switch-controller add-controller", bin: "switch-controller", verb: "add-controller", initial: { "@name": "unifi-controller", "--vendor": "unifi" }, note: "--ip: the controller's address (as in the credentials above)." },
            { title: "2 · Read its switches and ports: switch-controller interrogate", bin: "switch-controller", verb: "interrogate", note: "Every port with no record and no link is recorded parked: an access port in iotLocal (tier 6, no internet, nothing else reachable). A port with a link is left as the switch has it and named — register the node uplinks (add-port) or park it." },
            { title: "3 · Program the trunks and park the free ports: switch-controller reconcile", bin: "switch-controller", verb: "reconcile", note: "The preview lists every port it would set, the parked ones included; apply pushes them." },
          ]}
        />
      </>
    ),
    vpn: <OperateButton label="Enrol a device…" title="Enrol a device in the admin VPN" steps={enrolSteps()} />,
    stacks: <OperateButton label="Add a stack…" title="Add a stack" steps={addStackSteps()} />,
  };
  for (const m of ["backup", "identity", "logging"]) {
    body[m] = (
      <span className="toolbar">
        <OperateButton label={`Install ${m}…`} title={`module-manager add ${m}`} steps={[mm(`module-manager add ${m} --environment mgmt`, "add", { fixed: [m], initial: { "--environment": "mgmt" }, note: m === "identity" ? "Once identity is installed the console deletes the setup token: from then on it is reached through console.<domain> behind the gate (publish it below)." : undefined })]} />
        <OperateButton label="Test" title={`module-manager test ${m}`} steps={[mm(`module-manager test ${m}`, "test", { fixed: [m], hide: ["--vmid", "--zone0"] })]} />
        {m === "identity" ? (
          <OperateButton label="Publish the console…" title="module-manager add console" steps={[mm("module-manager add console --proxyDomain console.<domain>", "add", { fixed: ["console"], initial: { "@extra": [`--proxyDomain console.${domain}`] }, note: "The console's route through Caddy and the Authentik gate (the console module): mgmt and the admin VPN only." })]} />
        ) : null}
      </span>
    );
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1>Setup</h1>
        <span className="muted">derived from the records · {since(r.env?.at)}</span>
        <span className="spacer" />
        <button className="btn" disabled={checking} onClick={check}>{checking ? "Checking… (the module tests run)" : "Check again"}</button>
      </div>
      <ReadState env={r.env} failure={r.failure} what="the setup checklist" />
      {d ? (
        <p className={`readstate ${d.complete ? "" : "readstate-warn"}`}>
          {d.complete ? (
            <>Every required step is done: the foundation is installed. <Link to="/">Overview</Link> is the site from here.</>
          ) : (
            "The site is not complete yet: the steps below are what remains, in order."
          )}
          {d.token.active ? " The setup token is active until identity is installed." : ""}
        </p>
      ) : null}
      {r.env && !d && r.env.refreshing ? <p className="muted">Reading the records and running the foundation modules' tests — this takes a few minutes the first time.</p> : null}
      <ol className="setup">
        {(d?.steps ?? []).map((s) => (
          <StepRow key={s.id} s={s}>{body[s.id]}</StepRow>
        ))}
      </ol>
      <Section title="Day 2 — the same wizards">
        <div className="toolbar">
          <OperateButton label="Add a node…" title="Add a node" steps={addNodeSteps()} />
          <OperateButton label="Add an environment…" title="Add an environment" steps={addEnvironmentSteps()} />
          <OperateButton label="Add a stack…" title="Add a stack" steps={addStackSteps()} />
          <OperateButton label="Enrol a device…" title="Enrol a device in the admin VPN" steps={enrolSteps()} />
        </div>
        <SecretForm name="wlan" status={sec("wlan")} onSaved={secrets.reload} fields={[{ key: "ssid", label: "SSID" }, { key: "passphrase", label: "WPA passphrase", secret: true }]} />
      </Section>
    </div>
  );
}
