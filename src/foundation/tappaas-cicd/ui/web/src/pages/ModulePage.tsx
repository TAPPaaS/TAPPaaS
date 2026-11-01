// A module's page (mockup ui-04): the badges, then the tabs — Overview (its
// sections: generic, by kind and from its console.json, composed by the backend
// and drawn in that order; Health, Operate and About are drawn here), Config (the module and its services as a tree of cards, each with its
// Modify), Drift (module drift, on demand), Backup (its policy and PBS
// coverage), Activity (the console's jobs and the sweep's lines that name it) —
// and the Open-in links.

import { ReactNode, useEffect, useState } from "react";
import { useOpenRequest } from "../opener";
import { AskAbout } from "../assistant";
import { get, useRead } from "../api";
import { Envelope, ModuleDetail, ModuleSection as ModuleSectionDoc, Topology } from "../types";
import { Badge, Dot, KV, Link, OpenIn, ReadState, Section, Tag, canOperate, levelOf, since, useMe, when } from "../ui";
import { ModuleBadges } from "./Modules";
import { JobList } from "../jobs";
import { ModuleConfig } from "./ModuleConfig";
import { ModuleOperate } from "./ModuleOperate";
import { SectionView } from "./ModuleSections";
import { LocationLine, PlacementLine, useSiteLocations } from "../locations";
import { PlaceActions } from "../physical/rackops";

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

function HealthSection({ d }: { d: ModuleDetail }) {
  const c = d.summary.condition;
  if (c) {
    return (
      <Section title="Health — the conditions of this module's objects" aside={<Link to="/health">the Health view</Link>}>
        {c.issues.length === 0 ? <p className="muted">Every condition on its {c.objects} object{c.objects === 1 ? "" : "s"} is ok.</p> : null}
        <ul className="attention">
          {[...c.issues].sort((a, b) => Number(!!a.acknowledged) - Number(!!b.acknowledged)).map((i) => (
            <li key={`${i.object}-${i.type}`} className={`att att-${levelOf(i.status)}${i.acknowledged ? " att-ack" : ""}`}>
              {i.acknowledged ? <span className="tag tag-ack" title="acknowledged">{levelOf(i.status).toUpperCase()}</span> : <Tag level={levelOf(i.status)} />}
              <span className="att-gate">{i.type}</span>
              <span className="att-text"><b>{i.label}</b> {i.message ?? i.reason ?? ""}{i.since ? <span className="muted small"> · since {when(i.since)}</span> : null}{i.acknowledged ? <span className="muted small"> · acknowledged</span> : null}{i.maintenance ? <span className="muted small"> · maintenance</span> : null}</span>
              <span className="att-where"><Link to={`/health?select=${encodeURIComponent(i.object)}`} className="jump jump-in">Health</Link></span>
            </li>
          ))}
        </ul>
      </Section>
    );
  }
  return (
    <Section title="Health — the gates that mention this module" aside="health-manager validate">
      {d.findings.length === 0 ? <p className="muted">No gate names {d.summary.name}: every gate that looks at it passes.</p> : null}
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
  );
}

function About({ d }: { d: ModuleDetail }) {
  const name = d.summary.name;
  const m = d.summary;
  const show_ = d.show.data ?? {};
  const locations = useSiteLocations();
  // A machine is at a location of the site (ADR-036 D2); a value with a '/' is
  // the module directory's old field, never a place.
  const machine = show_.kind === "machine" || m.kind === "machine";
  const at = typeof show_.location === "string" && show_.location !== "" && !show_.location.includes("/") ? show_.location : null;
  // A machine's placement is asset-manager's, read from the topology.
  const positions = useRead<Topology>(machine ? "topology" : null).env?.data?.positions;
  const operator = canOperate(useMe());
  return (
    <Section title="About the Module template">
      <KV
        rows={[
          ["description", show(show_.description)],
          ["version", `${show(show_.version)}${show_.releaseDate ? ` · released ${show(show_.releaseDate)}` : ""}`],
          ["maturity", show(show_.status)],
          ["maintainer", show(show_.maintainer)],
          ...(machine
            ? ([
                ["location", <LocationLine name={at} locations={locations} />],
                ["placement", <span className="kv-with-actions"><span><PlacementLine v={positions} device={name} location={at ?? locations.find((l) => l.primary)?.name ?? null} /></span>{operator && positions ? <span className="toolbar"><PlaceActions device={name} v={positions} /></span> : null}</span>],
              ] as [string, ReactNode][])
            : []),
          ["installed", show(show_.installTime)],
          ["updated", show(show_.updateTime)],
          ["source", <span className="mono">{show(show_.moduleSource)}</span>],
        ]}
      />
    </Section>
  );
}

// While the sections are read, and if they cannot be: the generic ones.
const GENERIC_SECTIONS = ["health", "operate", "about"].map((id): ModuleSectionDoc => ({ id, title: id, layer: "generic", generic: true, source: null, at: null, error: null, blocks: [], operations: [], operationErrors: [] }));

export function ModulePage({ name }: { name: string }) {
  const r = useRead<ModuleDetail>(`modules/${encodeURIComponent(name)}`);
  const [tab, setTab] = useState<TabName>("Overview");
  // The assistant opened this module's Modify: it is on the Config tab.
  const modify = useOpenRequest("modify-module", name);
  useEffect(() => {
    if (modify) setTab("Config");
  }, [modify?.n]);
  const d = r.env?.data;
  const m = d?.summary;
  const sections = useRead<ModuleSectionDoc[]>(`modules/${encodeURIComponent(name)}/sections`);
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
        {TABS.map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? "tab tab-on" : "tab"} onClick={() => setTab(t)}>
            {t}
          </button>
        ))}
      </div>
      {d && tab === "Overview" ? (
        <>
          {sections.failure ? <ReadState env={null} failure={sections.failure} what="this module's sections" /> : null}
          {(sections.env?.data ?? GENERIC_SECTIONS).map((sec) => {
            if (!sec.generic) return <SectionView key={sec.id} s={sec} />;
            if (sec.id === "health") return <HealthSection key={sec.id} d={d} />;
            if (sec.id === "operate") return <ModuleOperate key={sec.id} m={d.summary} onConfig={() => setTab("Config")} />;
            return <About key={sec.id} d={d} />;
          })}
        </>
      ) : null}
      {d && tab === "Config" ? <ModuleConfig d={d} /> : null}
      {tab === "Drift" ? <Drift name={name} /> : null}
      {d && tab === "Backup" ? <Backup d={d} /> : null}
      {d && tab === "Activity" ? <ActivityTab d={d} /> : null}
    </div>
  );
}
