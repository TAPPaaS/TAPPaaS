// Setup — two tabs. Day 1: the rest of the installation after bootstrap.sh
// (ADR-034 D10, spike §5.12), an ordered checklist whose state the backend
// derives from the records each time (GET /setup), so it resumes wherever the
// install stands; each step is a form over its verbs, run as jobs with their
// previews, and the secrets the scripts read are entered here and never shown
// again. Day 2 (Day2.tsx): the guided sequences that grow the site afterwards.
// /setup opens Day 1 while the checklist is incomplete and Day 2 once it is
// complete; /setup/day1 and /setup/day2 open a tab.

import { ReactNode, useEffect, useState } from "react";
import { Read, post, useRead } from "../api";
import { JobOutput, JobStatusLine, quote, stripAnsi } from "../jobs";
import { OperateButton, Step } from "../operate";
import { fieldsStep } from "../fields";
import { useJobRun } from "../run";
import { JobSummary, SiteRead } from "../types";
import { Dot, Link, ReadState, canOperate, replacePath, since, useMe } from "../ui";
import { StageState, StepRow } from "../wizard";
import { AddNodeButton, sessionText, useAddNodeSession } from "./AddNode";
import { AddStackButton } from "./AddStack";
import { EnrolButton } from "./Enrol";
import { Day2 } from "./Day2";
import { PASSPHRASE_TEXT, SiteSsid, WIFI_ZONE_TYPES, broadcastText, passphraseOf } from "../wizards";

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

export function download(name: string, text: string): void {
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
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

export interface SetupStep extends StageState {
  id: string;
}

// The WiFi step's way on: the Day 2 button of each active Client zone with no
// SSID, and the site's SSIDs (ap-manager ssid list: each bridged to one zone,
// broadcast by every access point unless it names some) with how clients join
// and whether the passphrase is set — names only; a personal SSID without one
// cannot be created on the access points.
function WifiLinks({ doc }: { doc: SetupDoc | null }) {
  const ssids = useRead<SiteSsid[]>("ssids", 600_000);
  const w = doc?.inputs.wifi;
  if (!w) return null;
  const served = new Set((w.aps ?? []).flatMap((a) => a.ssids.map((s) => s.zone)));
  const missing = w.zones.filter((z) => WIFI_ZONE_TYPES.includes(z.type ?? "") && (z.state ?? "Active") === "Active" && !served.has(z.name));
  const day2 = new Set(w.zones.filter((z) => WIFI_ZONE_TYPES.includes(z.type ?? "") && (z.state ?? "Active") === "Active").map((z) => z.name));
  const rows = ssids.env?.data ?? [];
  const to = (zone: string) => (day2.has(zone) ? `/setup/day2#wifi-${zone}` : "/setup/day2#wifi");
  return (
    <>
      {ssids.env?.error || ssids.failure ? <p className="readstate readstate-fail">ap-manager ssid list could not be read: {ssids.env?.error ?? ssids.failure}</p> : null}
      {rows.length ? (
        <table className="table compact">
          <thead>
            <tr><th>SSID</th><th>zone</th><th>security</th><th>broadcast on</th><th>passphrase</th></tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const p = passphraseOf(r);
              return (
                <tr key={r.name}>
                  <td className="mono">{r.name}</td>
                  <td className="mono">{r.zone}{typeof r.vlan === "number" ? <span className="muted"> · VLAN {r.vlan}</span> : null}</td>
                  <td>{r.security}</td>
                  <td>{broadcastText(r)}</td>
                  <td>
                    {p === "not needed" ? <span className="muted">{PASSPHRASE_TEXT[p]}</span> : p === "set" ? <><Dot level="pass" /> set</> : p === "changed" ? <><Dot level="info" /> {PASSPHRASE_TEXT[p]}</> : (
                      <>
                        <Dot level="warn" /> not set{" "}
                        <Link to={to(r.zone)} className="btn">Set passphrase…</Link>
                      </>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : null}
      {missing.length === 0 ? (
        <p className="small">Change an SSID or its passphrase from <Link to="/setup/day2#wifi">Day 2</Link>.</p>
      ) : (
        <p className="small toolbar">
          {missing.map((z) => (
            <Link key={z.name} to={`/setup/day2#wifi-${z.name}`} className="btn">Add WiFi for {z.name} →</Link>
          ))}
          <span className="muted">on Day 2: the SSID, its passphrase, then the reconcile that programs every access point.</span>
        </p>
      )}
    </>
  );
}

// One module's test in the page's Check: its status, with Stop, and its output.
function CheckRun({ id, onEnd }: { id: string; onEnd: (id: string) => void }) {
  const run = useJobRun({ attach: id, onDone: () => onEnd(id) });
  const job = run.job;
  if (!job) return <p className="muted small">starting…</p>;
  return (
    <div className="jobview">
      <JobStatusLine job={job} label={quote(job.argv)} />
      <JobOutput job={job} fold={run.ok ? "closed" : "tail"} tail={8} />
    </div>
  );
}

const mm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "module-manager", verb, ...extra });

export type SetupTab = "Day 1" | "Day 2";
// Two menu entries, one page each (they were tabs of one Setup page).
export const SETUP_TITLE: Record<SetupTab, string> = { "Day 1": "Day 1 setup wizard", "Day 2": "Day 2 wizards" };
export const SETUP_PATH: Record<SetupTab, string> = { "Day 1": "/setup/day1", "Day 2": "/setup/day2" };

export function Setup({ tab }: { tab?: SetupTab }) {
  const r = useRead<SetupDoc>("setup", 600_000);
  const d = r.env?.data;
  // /setup (a link or bookmark): Day 1 until every required step is done,
  // then Day 2 — the address follows, so the menu shows which it is.
  const shown: SetupTab = tab ?? (d?.complete ? "Day 2" : "Day 1");
  useEffect(() => {
    if (!tab && d) replacePath(SETUP_PATH[shown]);
  }, [tab, d, shown]);
  const todo = d ? d.steps.filter((x) => x.required && x.done !== true).length : null;
  return (
    <div className="page">
      <div className="page-head">
        <h1>{SETUP_TITLE[shown]}</h1>
        <span className="muted">
          {shown === "Day 1"
            ? `the installation, derived from the records${todo === null ? "" : todo === 0 ? " · done" : ` · ${todo} to do`} · ${since(r.env?.at)}`
            : "the guided sequences that grow and run the site"}
        </span>
      </div>
      {shown === "Day 1" ? <Day1 r={r} /> : <Day2 doc={d ?? null} />}
    </div>
  );
}

function Day1({ r }: { r: Read<SetupDoc> }) {
  const secrets = useRead<SecretStatus[]>("secrets", 600_000);
  // A node being added (Add node closed mid-way): its Nodes step says so, open,
  // with the way back into the wizard at its stage.
  const adding = useAddNodeSession(canOperate(useMe()));
  const site = useRead<SiteRead>("site").env?.data?.site;
  // Check: a read job per installed foundation module, side by side; each
  // result lands on its step as its job ends (useJob re-reads the page).
  const [checks, setChecks] = useState<string[] | null>(null);
  const [ended, setEnded] = useState<string[]>([]);
  const [starting, setStarting] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const checking = starting || (checks ?? []).some((id) => !ended.includes(id));
  const d = r.env?.data;
  const sec = (n: string) => (secrets.env?.data ?? []).find((x) => x.name === n);
  const check = async () => {
    setStarting(true);
    setCheckError(null);
    const started = await post<JobSummary[]>("setup/check", {}).catch((e: Error) => ({ data: null, error: e.message }));
    setStarting(false);
    setEnded([]);
    setChecks(started.data?.map((j) => j.id) ?? null);
    if (!started.data) setCheckError(started.error);
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
    nodes: <AddNodeButton session={adding} />,
    switch: (
      <>
        <SecretForm name="unifi" status={sec("unifi")} onSaved={secrets.reload} fields={[{ key: "url", label: "controller URL", placeholder: "https://10.0.0.5:11443" }, { key: "username", label: "local admin" }, { key: "password", label: "password", secret: true }]} />
        <OperateButton
          label="Register the switch…"
          title="Register and interrogate the switch"
          steps={[
            { title: "1 · The controller: switch-manager add-controller", bin: "switch-manager", verb: "add-controller", initial: { "@name": "unifi-controller", "--vendor": "unifi" }, note: "--ip: the controller's address (as in the credentials above)." },
            { title: "2 · Read its switches and ports: switch-manager interrogate", bin: "switch-manager", verb: "interrogate", note: "Every port with no record and no link is recorded parked: an access port in iotLocal (tier 6, no internet, nothing else reachable). A port with a link is left as the switch has it and named — register the node uplinks (add-port) or park it." },
            { title: "3 · Program the trunks and park the free ports: switch-manager reconcile", bin: "switch-manager", verb: "reconcile", note: "The preview lists every port it would set, the parked ones included; apply pushes them." },
          ]}
        />
      </>
    ),
    vpn: <EnrolButton />,
    stacks: <AddStackButton opens={false} />,
    wifi: <WifiLinks doc={d ?? null} />,
    physical: (
      <p className="small toolbar">
        <Link to="/setup/day2#physical" className="btn">The physical site →</Link>
        <span className="muted">on Day 2: the rooms at each location, the racks, every node and switch placed, the modem and panels recorded.</span>
      </p>
    ),
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
        <button className="btn" disabled={checking} onClick={() => void check()} title="Runs module-manager test for backup, identity and logging, each a job, then reads the records again">{checking ? "Checking… (the module tests run)" : "Check: run the module tests"}</button>
      </div>
      <ReadState env={r.env} failure={r.failure} what="the setup checklist" />
      {d ? (
        <p className={`readstate ${d.complete ? "" : "readstate-warn"}`}>
          {d.complete ? (
            <>Every required step is done: the foundation is installed. <Link to="/">Overview</Link> is the site from here, and <Link to="/setup/day2">Day 2</Link> grows it.</>
          ) : (
            "The site is not complete yet: the steps below are what remains, in order."
          )}
          {d.token.active ? " The setup token stays active until your first sign-in through the gate." : d.token.identityInstalled ? " The setup token is closed: the console is reached through the gate." : ""}
        </p>
      ) : null}
      {r.env && !d && r.env.refreshing ? <p className="muted">Reading the records…</p> : null}
      {checkError ? <p className="readstate readstate-fail">Check did not start: {checkError}. The steps show the last results kept.</p> : null}
      {checks?.length === 0 ? <p className="muted">Nothing to test: backup, identity and logging are not installed yet.</p> : null}
      {checking ? <p className="muted">Running the foundation modules' tests — a few minutes; the checklist is read again after.</p> : null}
      {(checks ?? []).map((id) => <CheckRun key={id} id={id} onEnd={(j) => setEnded((e) => [...e, j])} />)}
      <ol className="setup">
        {(d?.steps ?? []).map((s) => (
          s.id === "nodes" && adding ? (
            <StepRow key={s.id} s={{ ...s, done: null, detail: `${s.detail} · Adding ${sessionText(adding)}` }} open>{body[s.id]}</StepRow>
          ) : (
            <StepRow key={s.id} s={s}>{body[s.id]}</StepRow>
          )
        ))}
      </ol>
    </>
  );
}
