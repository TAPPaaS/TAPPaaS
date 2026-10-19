// Setup — two tabs. Day 1: the rest of the installation after bootstrap.sh
// (ADR-034 D10, spike §5.12), an ordered checklist whose state the backend
// derives from the records each time (GET /setup), so it resumes wherever the
// install stands; each step is a form over its verbs, run as jobs with their
// previews, and the secrets the scripts read are entered here and never shown
// again. Day 2 (Day2.tsx): the guided sequences that grow the site afterwards.
// /setup opens Day 1 while the checklist is incomplete and Day 2 once it is
// complete; /setup/day1 and /setup/day2 open a tab.

import { ReactNode, useState } from "react";
import { Read, get, post, useRead } from "../api";
import { Output, stripAnsi } from "../jobs";
import { OperateButton, Step } from "../operate";
import { fieldsStep } from "../fields";
import { Job, SiteRead } from "../types";
import { Dot, Link, ReadState, navigate, since } from "../ui";
import { AddNodeButton } from "./AddNode";
import { Day2 } from "./Day2";

export interface SetupDoc {
  steps: SetupStep[];
  complete: boolean;
  inputs: {
    defaultEnv: string | null;
    dnsMode: string | null;
    wifi?: { zones: { name: string; type: string | null; state: string | null; ssid: string | null }[]; aps: { name: string; ssids: { name: string; zone: string | null }[] }[] | null };
  };
  token: { active: boolean; present: boolean; identityInstalled: boolean };
}
export interface SecretStatus {
  name: string;
  file: string;
  what: string;
  present: boolean;
  keys: string[];
  modified: string | null;
}

// ── the day-2 wizards, shared with the pages ──────────────────────────

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

export function SecretForm({ name, fields, status, onSaved }: { name: string; fields: { key: string; label: string; secret?: boolean; placeholder?: string }[]; status: SecretStatus | undefined; onSaved: () => void }) {
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

export interface SetupStep {
  id: string;
  title: string;
  required: boolean;
  done: boolean | null;
  detail: string;
}

// One step of a checklist (Setup's, Add node's): its state, its title and
// detail, and its body while open.
export function StepRow({ s, children, open: forced }: { s: SetupStep; children?: ReactNode; open?: boolean }) {
  const [userOpen, setOpen] = useState<boolean | null>(null);
  const open = userOpen ?? forced ?? s.done !== true;
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

// The WiFi step's way on: the Day 2 button of each active Client zone with no SSID.
function WifiLinks({ doc }: { doc: SetupDoc | null }) {
  const w = doc?.inputs.wifi;
  if (!w) return null;
  const served = new Set((w.aps ?? []).flatMap((a) => a.ssids.map((s) => s.zone)));
  const missing = w.zones.filter((z) => z.type === "Client" && (z.state ?? "Active") === "Active" && !served.has(z.name));
  if (missing.length === 0) return <p className="small">Change an SSID from <Link to="/setup/day2#wifi">Day 2</Link>.</p>;
  return (
    <p className="small toolbar">
      {missing.map((z) => (
        <Link key={z.name} to={`/setup/day2#wifi-${z.name}`} className="btn">Add WiFi for {z.name} →</Link>
      ))}
      <span className="muted">on Day 2: the access point, the SSID, its passphrase, then the reconcile.</span>
    </p>
  );
}

const mm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "module-manager", verb, ...extra });

export type SetupTab = "Day 1" | "Day 2";
const SETUP_TABS: { name: SetupTab; path: string; what: string }[] = [
  { name: "Day 1", path: "/setup/day1", what: "the installation" },
  { name: "Day 2", path: "/setup/day2", what: "growing the site" },
];

export function Setup({ tab }: { tab?: SetupTab }) {
  const r = useRead<SetupDoc>("setup", 600_000);
  const d = r.env?.data;
  // /setup: Day 1 until every required step is done, then Day 2.
  const shown: SetupTab = tab ?? (d?.complete ? "Day 2" : "Day 1");
  return (
    <div className="page">
      <div className="page-head">
        <h1>Setup</h1>
        <span className="muted">{shown === "Day 1" ? `derived from the records · ${since(r.env?.at)}` : "the guided sequences that grow the site"}</span>
      </div>
      <div className="tabs" role="tablist">
        {SETUP_TABS.map((t) => (
          <button key={t.name} role="tab" aria-selected={shown === t.name} className={shown === t.name ? "tab tab-on" : "tab"} onClick={() => navigate(t.path)} title={t.what}>
            {t.name}
            {t.name === "Day 1" && d ? <span className="muted small"> {d.complete ? "· done" : `· ${d.steps.filter((x) => x.required && x.done !== true).length} to do`}</span> : null}
          </button>
        ))}
      </div>
      {shown === "Day 1" ? <Day1 r={r} /> : <Day2 doc={d ?? null} />}
    </div>
  );
}

function Day1({ r }: { r: Read<SetupDoc> }) {
  const secrets = useRead<SecretStatus[]>("secrets", 600_000);
  const site = useRead<SiteRead>("site").env?.data?.site;
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const d = r.env?.data;
  const sec = (n: string) => (secrets.env?.data ?? []).find((x) => x.name === n);
  const check = () => {
    setChecking(true);
    setCheckError(null);
    void get("setup?refresh=1").catch((e: Error) => setCheckError(e.message)).finally(() => {
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
    nodes: <AddNodeButton />,
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
    wifi: <WifiLinks doc={d ?? null} />,
  };
  for (const m of ["backup", "identity", "logging"]) {
    body[m] = (
      <span className="toolbar">
        <OperateButton label={`Install ${m}…`} title={`module-manager add ${m}`} steps={() => [fieldsStep({ title: `module-manager add ${m} --environment mgmt`, bin: "module-manager", verb: "add", fixed: [m], kind: "module", name: m, mode: "add", keep: ["--environment"], initial: { "--environment": "mgmt" }, choices: { "--environment": ["mgmt"] }, note: m === "identity" ? "Once identity is installed the console deletes the setup token: from then on it is reached through console.<domain> behind the gate (publish it below)." : undefined })]} />
        <OperateButton label="Test" title={`module-manager test ${m}`} steps={[mm(`module-manager test ${m}`, "test", { fixed: [m], hide: ["--vmid", "--zone0"] })]} />
        {m === "identity" ? (
          <OperateButton label="Publish the console…" title="module-manager add console" steps={[mm("module-manager add console --proxyDomain console.<domain>", "add", { fixed: ["console"], initial: { "@extra": [`--proxyDomain console.${domain}`] }, note: "The console's route through Caddy and the Authentik gate (the console module): mgmt and the admin VPN only." })]} />
        ) : null}
      </span>
    );
  }

  return (
    <>
      <div className="toolbar setup-check">
        <button className="btn" disabled={checking} onClick={check} title="Runs module-manager test for backup, identity and logging, then reads the records again">{checking ? "Checking… (the module tests run)" : "Check: run the module tests"}</button>
      </div>
      <ReadState env={r.env} failure={r.failure} what="the setup checklist" />
      {d ? (
        <p className={`readstate ${d.complete ? "" : "readstate-warn"}`}>
          {d.complete ? (
            <>Every required step is done: the foundation is installed. <Link to="/">Overview</Link> is the site from here, and <Link to="/setup/day2">Day 2</Link> grows it.</>
          ) : (
            "The site is not complete yet: the steps below are what remains, in order."
          )}
          {d.token.active ? " The setup token is active until identity is installed." : d.token.identityInstalled ? " The setup token is closed: identity is installed, so the console is reached through the gate." : ""}
        </p>
      ) : null}
      {r.env && !d && r.env.refreshing ? <p className="muted">Reading the records…</p> : null}
      {checkError ? <p className="readstate readstate-fail">Check did not finish: {checkError}. The steps show the last results kept.</p> : null}
      {checking ? <p className="muted">Running the foundation modules' tests (backup, identity, logging) — a few minutes; the checklist is read again after.</p> : null}
      <ol className="setup">
        {(d?.steps ?? []).map((s) => (
          <StepRow key={s.id} s={s}>{body[s.id]}</StepRow>
        ))}
      </ol>
    </>
  );
}
