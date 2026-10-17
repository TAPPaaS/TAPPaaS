// A module's page (mockup ui-04): the badges, then the read tabs — Overview
// (the gates that mention it), Config (module resolve), Drift (module drift, on
// demand), Services (the fields each service it depends on carries), Backup
// (its policy and PBS coverage), Activity (the sweep's lines that name it) —
// and the Open-in links. Read-only: the operate column arrives with P2.

import { useState } from "react";
import { get, useRead } from "../api";
import { Envelope, ModuleDetail } from "../types";
import { Badge, Dot, KV, Link, OpenIn, ReadState, Section, Tag, levelOf, since, when } from "../ui";
import { ModuleBadges } from "./Modules";
import { JobList } from "../jobs";

const TABS = ["Overview", "Config", "Drift", "Services", "Backup", "Activity"] as const;
type TabName = (typeof TABS)[number];

function show(v: unknown): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "string") return v === "" ? "\"\"" : v;
  return JSON.stringify(v);
}

function Config({ d }: { d: ModuleDetail }) {
  const fields = d.resolve.data?.fields ?? {};
  const names = Object.keys(fields).sort();
  return (
    <Section title="Config — the desired state, defaults resolved" aside={`module-manager resolve ${d.summary.name} · ${since(d.resolve.at)}`}>
      <ReadState env={d.resolve} failure={null} what="resolve" />
      <table className="table compact">
        <thead>
          <tr><th>field</th><th>value</th><th /></tr>
        </thead>
        <tbody>
          {names.map((n) => (
            <tr key={n}>
              <td className="mono">{n}</td>
              <td className="mono wrap">{show(fields[n].value)}</td>
              <td>{fields[n].defaulted ? <span className="muted">default</span> : null}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Section>
  );
}

interface DriftDoc {
  module: string;
  services?: Record<string, { inSync?: unknown[]; unreconciled?: { field: string; desired?: unknown; actual?: unknown; class?: string }[]; adopt?: unknown[]; error?: string; notReported?: unknown[] }>;
}

function Drift({ name }: { name: string }) {
  const [env, setEnv] = useState<Envelope<DriftDoc> | null>(null);
  const [busy, setBusy] = useState(false);
  const [fail, setFail] = useState<string | null>(null);
  const run = (refresh: boolean) => {
    setBusy(true);
    setFail(null);
    get<DriftDoc>(`modules/${encodeURIComponent(name)}/drift${refresh ? "?refresh=1" : ""}`)
      .then(setEnv)
      .catch((e: Error) => setFail(e.message))
      .finally(() => setBusy(false));
  };
  const services = Object.entries(env?.data?.services ?? {});
  return (
    <Section
      title="Drift — the declared state against the running one"
      aside={
        <button className="btn" disabled={busy} onClick={() => run(env !== null)}>
          {busy ? "Reading drift…" : env ? "Read again" : `Read drift (module-manager drift ${name})`}
        </button>
      }
    >
      {fail ? <div className="readstate readstate-fail">{fail}</div> : null}
      {!env && !busy ? <p className="muted">Drift is read on demand: it asks every service of the module for its live state.</p> : null}
      {env ? <ReadState env={env} failure={null} what="drift" /> : null}
      {services.length ? (
        <table className="table compact">
          <thead>
            <tr><th>service</th><th>in sync</th><th>to reconcile</th><th /></tr>
          </thead>
          <tbody>
            {services.map(([svc, r]) => (
              <tr key={svc}>
                <td className="mono">{svc}</td>
                <td>{r.inSync?.length ?? 0}</td>
                <td>
                  {(r.unreconciled ?? []).length === 0 ? (
                    <Badge level="pass">none</Badge>
                  ) : (
                    (r.unreconciled ?? []).map((u) => (
                      <div key={u.field} className="mono">
                        {u.field}: {show(u.actual)} → {show(u.desired)} {u.class ? <span className="muted">({u.class})</span> : null}
                      </div>
                    ))
                  )}
                </td>
                <td className="muted">{r.error ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : null}
    </Section>
  );
}

function Services({ d }: { d: ModuleDetail }) {
  const show_ = d.show.data ?? {};
  const config = (show_.config ?? {}) as Record<string, Record<string, unknown>>;
  const deps = (d.resolve.data?.dependsOn ?? (show_.dependsOn as string[] | undefined) ?? []) as string[];
  const integ = (d.resolve.data?.integratesWith ?? (show_.integratesWith as string[] | undefined) ?? []) as string[];
  const rows = [...deps.map((s) => ({ s, how: "depends on" })), ...integ.map((s) => ({ s, how: "integrates with" }))];
  return (
    <Section title="Services — what the module uses, and the fields it declares for each" aside="module-manager show">
      <table className="table compact">
        <thead>
          <tr><th>service</th><th /><th>declared</th></tr>
        </thead>
        <tbody>
          {rows.map(({ s, how }) => (
            <tr key={s}>
              <td className="mono">{s}</td>
              <td className="muted">{how}</td>
              <td className="mono wrap">
                {config[s] ? Object.entries(config[s]).map(([k, v]) => `${k} ${show(v)}`).join(" · ") : <span className="muted">defaults</span>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </Section>
  );
}

function Backup({ d }: { d: ModuleDetail }) {
  if (!d.backup) return <Section title="Backup"><p className="muted">This module has no guest of its own to back up.</p></Section>;
  const p = d.backup.data?.policy ?? {};
  const c = (d.backup.data?.coverage ?? {}) as { jobs?: { jobId: string; how: string; storage: string; schedule: string; enabled: boolean }[]; reachable?: boolean; error?: string };
  return (
    <Section title="Backup — the policy and where PBS has it" aside={`backup-manager show / coverage · ${since(d.backup.at)}`}>
      <ReadState env={d.backup} failure={null} what="backup" />
      <KV
        rows={[
          ["enabled", show(p.enabled)],
          ["opted in", show(p.optedIn)],
          ["in the PBS job", show(p.inPbsJob)],
          ["schedule", show(p.schedule)],
          ["retention", show(p.retention)],
          ["residency", show(p.residency)],
          ["target", show(p.target)],
          ["off-site", show(p.offsite)],
        ]}
      />
      <h3>PBS jobs</h3>
      {c.error ? <p className="muted">{c.error}</p> : null}
      <ul className="plain">
        {(c.jobs ?? []).map((j) => (
          <li key={j.jobId} className="mono">
            {j.storage} · {j.schedule} · {j.how}
            {j.enabled ? "" : " · disabled"}
          </li>
        ))}
        {c.jobs && c.jobs.length === 0 ? <li className="muted">in no PBS job</li> : null}
      </ul>
    </Section>
  );
}

function ActivityTab({ d }: { d: ModuleDetail }) {
  const lines = d.activity ?? [];
  return (
    <>
    <Section title="Activity — the console's jobs on this module" aside="jobs.jsonl">
      <JobList jobs={d.jobs ?? []} empty={`No console job has named ${d.summary.name} yet.`} />
    </Section>
    <Section title="The sweep's errors and warnings that name this module" aside="update-tappaas journal">
      {lines.length === 0 ? <p className="muted">Nothing in the sweep's recent runs names {d.summary.name}.</p> : null}
      <table className="table compact">
        <tbody>
          {lines.map((l, i) => (
            <tr key={i}>
              <td className="nowrap">{when(l.line.at)}</td>
              <td><Tag level={l.line.level === "error" ? "fail" : "warn"} /></td>
              <td className="mono wrap">{l.line.text}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Section>
    </>
  );
}

export function ModulePage({ name }: { name: string }) {
  const r = useRead<ModuleDetail>(`modules/${encodeURIComponent(name)}`);
  const [tab, setTab] = useState<TabName>("Overview");
  const d = r.env?.data;
  const m = d?.summary;
  const show_ = d?.show.data ?? {};
  return (
    <div className="page">
      <div className="page-head">
        <h1>{name}</h1>
        <span className="muted">
          <Link to="/modules">Modules</Link> › {m?.environment ?? "…"} › {m?.stack ?? "…"} stack
        </span>
        <span className="spacer" />
        <OpenIn kind="module" id={name} />
      </div>
      <ReadState env={r.env} failure={r.failure} what={`module ${name}`} />
      {m ? (
        <div className="module-head">
          <Dot level={m.badges.run === "running" ? "pass" : m.badges.run === "stopped" ? "fail" : "skip"} />
          <span>
            {m.badges.run === "none" ? `${m.kind}${m.node ? ` on ${m.node}` : ""}` : `${m.badges.run} · ${m.actualNode ?? m.node ?? "?"} · ${m.kind === "lxc" ? "CT" : "VM"} ${m.vmid}`}
          </span>
          <ModuleBadges m={m} />
          <span className="muted">env {m.environment ?? "—"} · zone {m.zone0 ?? "—"}</span>
        </div>
      ) : null}
      <div className="tabs" role="tablist">
        {TABS.map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? "tab tab-on" : "tab"} onClick={() => setTab(t)}>
            {t}
          </button>
        ))}
      </div>
      {d && tab === "Overview" ? (
        <>
          <Section title="Health — the gates that mention this module" aside="health-manager validate">
            {d.findings.length === 0 ? <p className="muted">No gate names {name}: every gate that looks at it passes.</p> : null}
            <ul className="attention">
              {d.findings.map((f, i) => (
                <li key={i} className={`att att-${levelOf(f.status)}`}>
                  <Tag level={f.status} />
                  <span className="att-gate">{f.gate}</span>
                  <span className="att-text mono">{f.text.replace(/\s+/g, " ")}</span>
                </li>
              ))}
            </ul>
          </Section>
          <Section title="About">
            <KV
              rows={[
                ["description", show(show_.description)],
                ["version", `${show(show_.version)}${show_.releaseDate ? ` · released ${show(show_.releaseDate)}` : ""}`],
                ["maturity", show(show_.status)],
                ["maintainer", show(show_.maintainer)],
                ["installed", show(show_.installTime)],
                ["updated", show(show_.updateTime)],
                ["source", <span className="mono">{show(show_.moduleSource)}</span>],
              ]}
            />
          </Section>
        </>
      ) : null}
      {d && tab === "Config" ? <Config d={d} /> : null}
      {tab === "Drift" ? <Drift name={name} /> : null}
      {d && tab === "Services" ? <Services d={d} /> : null}
      {d && tab === "Backup" ? <Backup d={d} /> : null}
      {d && tab === "Activity" ? <ActivityTab d={d} /> : null}
    </div>
  );
}
