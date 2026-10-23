// A module's page (mockup ui-04): the badges, then the tabs — Overview (the
// gates that mention it and the operate column, every module-manager verb as a
// job), Config (the module and its services as a tree of cards, each with its
// Modify), Drift (module drift, on demand), Backup (its policy and PBS
// coverage), Activity (the console's jobs and the sweep's lines that name it) —
// and the Open-in links.

import { ReactNode, useEffect, useState } from "react";
import { useOpenRequest } from "../opener";
import { AskAbout } from "../assistant";
import { get, useRead } from "../api";
import { Envelope, ModuleDetail } from "../types";
import { Badge, Dot, KV, Link, OpenIn, ReadState, Section, Tag, levelOf, since, useMe, when } from "../ui";
import { ModuleBadges } from "./Modules";
import { JobList } from "../jobs";
import { ModuleConfig } from "./ModuleConfig";
import { ModuleOperate } from "./ModuleOperate";
import { LocationLine, useSiteLocations } from "../locations";

const TABS = ["Overview", "Config", "Drift", "Backup", "Activity"] as const;
type TabName = (typeof TABS)[number];

function show(v: unknown): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "string") return v === "" ? "\"\"" : v;
  return JSON.stringify(v);
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
  // The assistant opened this module's Modify: it is on the Config tab.
  const modify = useOpenRequest("modify-module", name);
  useEffect(() => {
    if (modify) setTab("Config");
  }, [modify?.n]);
  // The owner's route reads what the module is, not how it is configured.
  const owner = useMe()?.route === "status";
  const tabs = TABS.filter((t) => !owner || ["Overview", "Backup"].includes(t));
  const d = r.env?.data;
  const m = d?.summary;
  const show_ = d?.show.data ?? {};
  const locations = useSiteLocations();
  // A machine is at a location of the site (ADR-036 D2); a value with a '/' is
  // the module directory's old field, never a place.
  const machine = show_.kind === "machine" || m?.kind === "machine";
  const at = typeof show_.location === "string" && show_.location !== "" && !show_.location.includes("/") ? show_.location : null;
  return (
    <div className="page">
      <div className="page-head">
        <h1>{name}</h1>
        <span className="muted">
          <Link to="/modules">Modules</Link> › {m?.environment ?? "…"} › {m?.stack ?? "…"} stack
        </span>
        <span className="spacer" />
        <AskAbout question={`How is ${name} doing? Is anything wrong with it, and what would you change?`} focus={{ page: "module", kind: "module", name }} />
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
        {tabs.map((t) => (
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
          <ModuleOperate m={d.summary} onConfig={() => setTab("Config")} />
          <Section title="About">
            <KV
              rows={[
                ["description", show(show_.description)],
                ["version", `${show(show_.version)}${show_.releaseDate ? ` · released ${show(show_.releaseDate)}` : ""}`],
                ["maturity", show(show_.status)],
                ["maintainer", show(show_.maintainer)],
                ...(machine ? [["location", <LocationLine name={at} locations={locations} />] as [string, ReactNode]] : []),
                ["installed", show(show_.installTime)],
                ["updated", show(show_.updateTime)],
                ["source", <span className="mono">{show(show_.moduleSource)}</span>],
              ]}
            />
          </Section>
        </>
      ) : null}
      {d && tab === "Config" ? <ModuleConfig d={d} /> : null}
      {tab === "Drift" ? <Drift name={name} /> : null}
      {d && tab === "Backup" ? <Backup d={d} /> : null}
      {d && tab === "Activity" ? <ActivityTab d={d} /> : null}
    </div>
  );
}
