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
import { AddPoolButton } from "../physical/nodepools";
import { EnrolButton } from "./Enrol";
import { RestOfFoundationButton } from "./RestOfFoundation";
import { Day2 } from "./Day2";
import { PASSPHRASE_TEXT, SiteSsid, WIFI_ZONE_TYPES, ZoneIn, broadcastText, passphraseOf, wifiZones } from "../wizards";
import { AddSwitchButton } from "./AddSwitch";
import { FirstLanUplink } from "./FirstLan";
import { HealthChecks } from "./HealthChecks";
import { WifiButton } from "./Wifi";
import { AddRepositoryButton } from "./AddRepository";

export interface SetupDoc {
  steps: SetupStep[];
  complete: boolean;
  inputs: {
    defaultEnv: string | null;
    defaultDomain?: string | null;
    dnsMode: string | null;
    firstNode?: { name: string; pools: string[] } | null;
    repositories?: string[];
    siteNodes?: string[];
    answers?: Record<string, string>;
    modules?: Record<string, { config: boolean; test: { rc: number; at: string } | null }>;
    health?: {
      gates: { name: string; status: string; detail: string }[] | null;
      reach: { at: string; nodes: string[]; ok: boolean; error?: string; vlans: { vid: number; zone: string; missing: { from: string; to: string }[] }[]; lanPorts: Record<string, string[]> } | null;
    };
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
      {missing.length ? <p className="small">Without an SSID yet: {missing.map((z) => z.name).join(", ")}. Add WiFi below: the SSID, its passphrase, then the reconcile that programs every access point.</p> : null}
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

// A step's plain answer ("none", "no more machines"): recorded by the console, so
// an optional step reads as done with nothing installed. Again, it is withdrawn.
function AnswerButton({ step, answer, label, given, onChanged }: { step: string; answer: string; label: string; given: boolean; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  if (!canOperate(useMe())) return null;
  const send = async () => {
    setBusy(true);
    setMsg(null);
    const r = await post<unknown>("setup/answer", { step, answer: given ? null : answer });
    setBusy(false);
    if (!r.ok) return setMsg(r.error);
    onChanged();
  };
  return (
    <>
      <button className="btn" disabled={busy} onClick={() => void send()}>{given ? `Undo “${label}”` : label}</button>
      {msg ? <span className="ff-error small"> {msg}</span> : null}
    </>
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
  const domain = d?.inputs.defaultDomain ?? "";
  const ans = (step: string): boolean => !!d?.inputs.answers?.[step];
  // The zones that can have Wi-Fi, for the same wizard as Day 2's.
  const zonesRead = useRead<ZoneIn[]>("zones");
  const ssidsRead = useRead<SiteSsid[]>("ssids", 600_000);
  const wifi = wifiZones(zonesRead.env?.data ?? [], ssidsRead.env?.data ?? []);

  const body: Record<string, ReactNode> = {
    firstnode: d?.inputs.firstNode ? (
      <>
        <h3>Its LAN port</h3>
        <FirstLanUplink node={d.inputs.firstNode.name} answer={d.inputs.answers?.firstlan} onChanged={r.reload} />
        <h3>Its disks</h3>
        <p className="small toolbar">
          <AddPoolButton node={d.inputs.firstNode.name} />
          <AnswerButton step="firstnode" answer="boot-only" label="Boot pool only" given={ans("firstnode")} onChanged={r.reload} />
          <span className="muted">A data pool on the free disks holds the guests and lets HA replicate them; a machine with one disk keeps the boot pool.</span>
        </p>
      </>
    ) : null,
    repos: (
      <p className="small toolbar">
        <AddRepositoryButton installed={d?.inputs.repositories ?? []} />
        <AnswerButton step="repos" answer="tappaas-only" label="TAPPaaS only" given={ans("repos")} onChanged={r.reload} />
      </p>
    ),
    public: (
      <>
        {d?.inputs.dnsMode === "local" ? (
          <p className="small">The site's names are signed by its own CA, and each person imports it once. Going public gets them a certificate every device already trusts: a wildcard through a DNS provider's API (below), or one per name from public DNS records.</p>
        ) : (
          <p className="small">The site's names have public certificates. A wildcard through a DNS provider's API (below) serves every name of the domain with one certificate.</p>
        )}
        <SecretForm name="acme-dns" status={sec("acme-dns")} onSaved={secrets.reload} fields={[{ key: "provider", label: "DNS provider", placeholder: "cloudflare, gandi_livedns, …" }, { key: "@key", label: "its key name", placeholder: "dns_cf_token, dns_gandi_livedns_token, …" }, { key: "@value", label: "its value", secret: true }]} />
        <p className="small toolbar">
          <OperateButton label="Go public with the wildcard…" title={`environment-manager modify ${d?.inputs.defaultEnv ?? "<env>"} --dns-mode wildcard`} steps={[
            { title: `environment-manager modify ${d?.inputs.defaultEnv ?? "<env>"} --dns-mode wildcard`, bin: "environment-manager", verb: "modify", fixed: [d?.inputs.defaultEnv ?? ""], initial: { "--dns-mode": "wildcard" } },
            { title: `environment-manager reconcile ${d?.inputs.defaultEnv ?? "<env>"} --apply`, bin: "environment-manager", verb: "reconcile", fixed: [d?.inputs.defaultEnv ?? ""], note: "Gets *.<domain> from Let's Encrypt through the provider above, and moves every route onto it." },
          ]} />
          <AnswerButton step="public" answer="stay-local" label="Stay local" given={ans("public")} onChanged={r.reload} />
        </p>
      </>
    ),
    nodes: (
      <span className="toolbar">
        <AddNodeButton session={adding} />
        <AnswerButton step="nodes" answer="no-more" label="No more machines" given={ans("nodes")} onChanged={r.reload} />
      </span>
    ),
    switch: (
      <>
        <p className="small">Managing the switches lets TAPPaaS set each port for you. A switch managed outside TAPPaaS is recorded too, and TAPPaaS says which VLANs each of its ports needs. Add them one at a time.</p>
        <p className="small toolbar">
          <AddSwitchButton />
          <AnswerButton step="switch" answer="no-more" label="No more switches" given={ans("switch")} onChanged={r.reload} />
        </p>
      </>
    ),
    vpn: (
      <>
        <p className="small">After Rest of foundation you sign in from the site's LAN or over the admin VPN. Enrol this computer, or move it onto the site's LAN (a port of the first node's LAN, or a switch on it). Enrolling also gives you the way in from outside.</p>
        <p className="small toolbar">
          <EnrolButton />
          <AnswerButton step="vpn" answer="on-lan" label="This computer is on the LAN" given={ans("vpn")} onChanged={r.reload} />
        </p>
      </>
    ),
    blocking: (
      <p className="small toolbar">
        <OperateButton label="Change…" title="Blocking" steps={[
          fieldsStep({ title: "site-manager site modify (blocking)", bin: "site-manager", verb: "site modify", kind: "site", name: null, mode: "modify", fields: ["dnsBlocklists"], note: "Empty lists block nothing. Leave the service zones out: their modules download updates and models." }),
          mm("module-manager update network", "update", { fixed: ["network"], note: "Applies the blocklists on the firewall." }),
        ]} />
        <span className="muted">A threat list keeps the people's devices away from known malware and phishing names; it is maintained by its publisher.</span>
      </p>
    ),
    health: <HealthChecks doc={d ?? null} done={d ? (r.env?.data?.steps ?? []).find((x) => x.id === "health")?.done ?? null : null} />,
    stacks: <AddStackButton opens={false} />,
    wifi: (
      <>
        <WifiLinks doc={d ?? null} />
        <p className="small toolbar">
          <WifiButton zones={wifi} site={site?.name ?? ""} />
          <AnswerButton step="wifi" answer="no-more" label="No more Wi-Fi" given={ans("wifi")} onChanged={r.reload} />
        </p>
      </>
    ),
    physical: (
      <p className="small toolbar">
        <Link to="/setup/day2#physical" className="btn">The physical site →</Link>
        <span className="muted">on Day 2: the rooms at each location, the racks, every node and switch placed, the modem and panels recorded.</span>
      </p>
    ),
  };
  // Rest of foundation: one job installs what is missing; each part's state and
  // its test below it, and the console's publishing beside identity.
  const mods = d?.inputs.modules ?? {};
  const partText = (m: string): string => {
    const x = mods[m];
    if (!x || !x.config) return "not installed";
    if (!x.test) return "installed, not tested yet";
    return x.test.rc === 0 ? "test passed" : "test failed";
  };
  body.bootstrap = (
    <>
      <p className="small toolbar"><RestOfFoundationButton email={email} /><span className="muted">Installs what is missing of backup, identity and logging, then your organization and you.</span></p>
      <table className="table compact">
        <tbody>
          {["backup", "identity", "logging"].map((m) => (
            <tr key={m}>
              <td>{m}</td>
              <td className="muted">{partText(m)}</td>
              <td className="toolbar">
                {mods[m]?.config ? <OperateButton label="Test" title={`module-manager test ${m}`} steps={[mm(`module-manager test ${m}`, "test", { fixed: [m], hide: ["--vmid", "--zone0"] })]} /> : null}
                {m === "identity" && mods[m]?.config ? (
                  <OperateButton label="Publish the console…" title="module-manager add console" steps={[mm("module-manager add console --proxyDomain console.<domain>", "add", { fixed: ["console"], initial: { "@extra": [`--proxyDomain console.${domain}`] }, note: "The console's route through Caddy and the Authentik gate (the console module): mgmt and the admin VPN only." })]} />
                ) : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );

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
