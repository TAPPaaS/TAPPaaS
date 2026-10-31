// Operations — the open events of the site by root cause, critical first, each
// with what it impacts and, beside it, what changed on that object in the last
// day: the first question about an incident. A row opens the object's panel
// (HealthPanel, as on the Health page). And the discovery sweep: run it, and
// what the last one found.

import { useEffect, useRef, useState } from "react";
import { post, useHealthStream, useRead } from "../api";
import { DiscoverySweep, DiscoverySweepState, Operations as OpsDoc, OpsChange, OpsEvent, OpsGroup } from "../types";
import { Badge, Dot, Level, ReadState, Section, Tag, canOperate, navigate, replacePath, since, useMe, when } from "../ui";
import { HealthPanel } from "./HealthPanel";

const LEVEL: Record<string, Level> = { ok: "pass", warning: "warn", critical: "fail", unknown: "skip" };

function age(iso: string | null): string {
  if (!iso) return "";
  const m = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60_000));
  return m < 60 ? `${m} min` : m < 48 * 60 ? `${Math.round(m / 60)} h` : `${Math.round(m / 1440)} d`;
}

function Changes({ list, error, skipped, hours }: { list: OpsChange[] | undefined; error: string | undefined; skipped: boolean; hours: number }) {
  if (error) return <p className="muted small">its history did not answer: {error}</p>;
  if (skipped) return <p className="muted small">not read: past the first events</p>;
  if (!list) return <p className="muted small">…</p>;
  if (list.length === 0) return <p className="muted small">nothing changed in the last {hours} h</p>;
  return (
    <ul className="findings ops-changes">
      {list.slice(0, 8).map((c) => (
        <li key={c.id}>
          <span className="nowrap">{when(c.time)}</span> <b>{c.verb ?? c.kind}</b>
          {c.drift ? <> <Badge level="warn">drift</Badge></> : null}
          <span className="muted small"> · {c.source}{c.actor ? ` · ${c.actor}` : ""}{c.job ? ` · job ${c.job}` : ""}</span>
          {c.what.length ? <div className="mono small ops-what">{c.what.slice(0, 6).join(", ")}{c.what.length > 6 ? ` +${c.what.length - 6}` : ""}</div> : null}
        </li>
      ))}
      {list.length > 8 ? <li className="muted small">… {list.length - 8} more: the object's panel has them all</li> : null}
    </ul>
  );
}

function EventRow({ e, doc, open, selected }: { e: OpsEvent; doc: OpsDoc; open: (id: string) => void; selected: boolean }) {
  return (
    <li className={`ops-event${selected ? " ops-event-on" : ""}`}>
      <button className="ops-event-head" onClick={() => open(e.id)} title="Open its panel">
        <Tag level={e.status} />
        <span className="ops-event-name">
          <b>{e.label}</b> <span className="muted small">{e.class}{e.environment ? ` · ${e.environment}` : ""}</span>
          {e.isRoot ? <span className="ops-root" title="Other objects fail because of it"> root cause</span> : null}
          {e.flapping ? <span className="muted" title="flapping"> ↯</span> : null}
        </span>
        <span className="ops-event-text">
          <span className="att-gate">{e.type}</span> {e.message ?? e.reason ?? e.status}
          <span className="muted small">{e.since ? ` · since ${when(e.since)} (${age(e.since)})` : ""}</span>
          {e.conditions.length > 1 ? <span className="muted small"> · and {e.conditions.slice(1).map((c) => `${c.type} ${c.status}`).join(", ")}</span> : null}
        </span>
      </button>
      <div className="ops-event-changes">
        <Changes list={doc.changes[e.id]} error={doc.changesError[e.id]} skipped={doc.changesSkipped.includes(e.id)} hours={doc.windowHours} />
      </div>
    </li>
  );
}

function Group({ g, doc, open, selected }: { g: OpsGroup; doc: OpsDoc; open: (id: string) => void; selected: string | null }) {
  const [all, setAll] = useState(false);
  const shown = all ? g.impact.objects : g.impact.objects.slice(0, 12);
  return (
    <section className={`ops-group ops-${g.status}`}>
      <ul className="ops-events">
        {g.events.map((e) => <EventRow key={e.id} e={e} doc={doc} open={open} selected={selected === e.id} />)}
      </ul>
      {g.impact.count ? (
        <div className="ops-impact">
          <span className="muted small">impacts {g.impact.count}:</span>{" "}
          {shown.map((o) => (
            <button key={o.id} className="hlink ops-impacted" onClick={() => open(o.id)} title={o.class}>
              <Dot level={LEVEL[o.status] ?? "skip"} title={o.status} /> {o.label}
            </button>
          ))}
          {g.impact.objects.length > shown.length ? <button className="hlink" onClick={() => setAll(true)}>+{g.impact.objects.length - shown.length} more</button> : null}
        </div>
      ) : null}
    </section>
  );
}

function SweepRecord({ s, open }: { s: DiscoverySweep; open: (id: string) => void }) {
  const [all, setAll] = useState(false);
  const c = s.counts;
  const failed = s.sources.filter((x) => !x.ok);
  const plain = s.sources.filter((x) => x.ok && x.fallback);
  const rows = all ? s.findings : s.findings.slice(0, 25);
  const cell = (v: unknown): string => (v === null || v === undefined ? "—" : typeof v === "string" ? v : JSON.stringify(v));
  return (
    <>
      <p>
        <Tag level={s.status} /> {when(s.time)} ({age(s.time)} ago)
        <span className="muted"> · {s.since ? `against the sweep of ${when(s.since)}` : "the baseline: the next one lists what changed"}</span>
      </p>
      <p className="muted small">
        {c.drift ?? 0} drift · {c.desired ?? 0} from desired · {c.unmanaged ?? 0} unmanaged · {c.missing ?? 0} missing · {c.unread ?? 0} not compared · {c.expected ?? 0} expected ({c.new ?? 0} new) · {s.sources.length} source(s), {c.sourcesFailed ?? failed.length} failed
      </p>
      {failed.length ? <div className="readstate readstate-fail">Sources that failed: {failed.map((x) => `${x.source}${x.error ? ` (${x.error})` : ""}`).join(", ")}</div> : null}
      {plain.length ? <p className="muted small">Asked without --discover (they do not know it yet): {plain.map((x) => x.source).join(", ")}</p> : null}
      {s.findings.length ? (
        <table className="table compact">
          <thead>
            <tr><th>found</th><th>object</th><th>what</th><th>source</th></tr>
          </thead>
          <tbody>
            {rows.map((x, i) => (
              <tr key={i}>
                <td className="nowrap">{x.kind}</td>
                <td className="nowrap">
                  {x.id ? <button className="hlink" onClick={() => open(x.id!)}>{x.class}/{x.name}</button> : `${x.class}/${x.name}`}
                </td>
                <td className="mono wrap">{x.attribute ?? ""}{x.kind === "changed" || x.kind === "desired" ? `: ${cell(x.before)} → ${cell(x.after)}` : x.kind === "appeared" && x.attribute ? `: ${cell(x.after)}` : x.kind === "gone" && x.attribute ? `: ${cell(x.before)}` : ""}</td>
                <td className="muted">{x.source}</td>
              </tr>
            ))}
            {s.findingsTotal > rows.length ? (
              <tr><td colSpan={4}>{!all && s.findings.length > rows.length ? <button className="hlink" onClick={() => setAll(true)}>show {s.findings.length - rows.length} more</button> : null}{s.findingsTotal > s.findings.length ? <span className="muted"> · {s.findingsTotal - s.findings.length} more in the record (cmdb sweep --last)</span> : null}</td></tr>
            ) : null}
          </tbody>
        </table>
      ) : <p className="muted">Nothing found that a change does not explain.</p>}
    </>
  );
}

function Sweep({ onDone, open }: { onDone: () => void; open: (id: string) => void }) {
  const me = useMe();
  const [poll, setPoll] = useState(60_000);
  const r = useRead<DiscoverySweepState>("operations/sweep", poll);
  const st = r.env?.data ?? null;
  const running = st?.running ?? null;
  const [posting, setPosting] = useState(false);
  const [refused, setRefused] = useState<string | null>(null);
  const was = useRef(false);
  useEffect(() => {
    setPoll(running ? 5_000 : 60_000);
    // It has finished: the record is new, and assess has set drift since.
    if (was.current && !running) onDone();
    was.current = !!running;
  }, [!!running]);
  const may = canOperate(me);
  const start = () => {
    setPosting(true);
    setRefused(null);
    void post<{ running: DiscoverySweepState["running"] }>("operations/sweep", {})
      .then((p) => {
        if (!p.ok) setRefused(p.error);
        r.reload();
      })
      .finally(() => setPosting(false));
  };
  return (
    <Section
      title="Discovery sweep"
      aside={
        <button className="btn btn-primary" disabled={!may || !!running || posting || !st} onClick={start} title={may ? "Ask every source for everything and compare with the last sweep and with config/; it changes nothing on the site" : "Running a sweep is the installer's"}>
          {running || posting ? "Sweeping…" : "Run discovery sweep"}
        </button>
      }
    >
      <ReadState env={r.env} failure={r.failure} what="the last sweep" />
      {running ? <div className="readstate">A sweep started {when(running.started)}{running.by ? ` by ${running.by}` : ""} is running; it asks every source in turn and can take a while.</div> : null}
      {refused ? <div className="readstate readstate-warn">{refused}</div> : null}
      {st?.failed ? <div className="readstate readstate-fail">The sweep started here at {when(st.failed.at)} failed: {st.failed.error}</div> : null}
      {st?.lastError ? <div className="readstate readstate-warn">The last record could not be read: {st.lastError}</div> : null}
      {st && !st.last && !st.lastError ? <p className="muted">No sweep has run yet. The first one is the baseline; it runs every night before the update window.</p> : null}
      {st?.last ? <SweepRecord s={st.last} open={open} /> : null}
    </Section>
  );
}

export function Operations() {
  const r = useRead<OpsDoc>("operations", 30_000);
  const doc = r.env?.data ?? null;
  const [sel, setSel] = useState<string | null>(() => new URLSearchParams(window.location.search).get("select"));
  // What moved in the CMDB: read again (the server reads the histories at most once a minute).
  useHealthStream(() => r.reload(), () => undefined);
  const open = (id: string) => {
    setSel(id);
    replacePath(`/operations?select=${encodeURIComponent(id)}`);
  };
  const close = () => {
    setSel(null);
    replacePath("/operations");
  };
  const c = doc?.counts;
  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Operations</h1>
        <span className="muted">
          {c ? `${c.critical} critical · ${c.warning} warning · ${c.groups} root cause(s) · ${c.silenced} silenced` : "…"}
          {doc?.generated ? ` · read ${since(doc.generated)}` : ""}
        </span>
      </div>
      <div className="ops-view">
        <div className="ops-main">
          <ReadState env={r.env} failure={r.failure} what="the open events" />
          {doc && !doc.hasConditions ? <p className="readstate readstate-warn">No object carries a condition yet: this site has not run <span className="mono">health-manager assess</span>, so there is nothing to list.</p> : null}
          <Section title="Open events" aside={doc ? `by root cause · what changed: the last ${doc.windowHours} h` : undefined}>
            {doc && doc.hasConditions && doc.groups.length === 0 ? <p className="muted">Nothing is failing that is not acknowledged or in maintenance.</p> : null}
            {doc ? doc.groups.map((g) => <Group key={g.root} g={g} doc={doc} open={open} selected={sel} />) : null}
          </Section>
          <Sweep onDone={() => r.reload()} open={open} />
        </div>
        {sel ? <HealthPanel id={sel} close={close} pick={open} showInTree={() => navigate(`/health?select=${encodeURIComponent(sel)}`)} /> : null}
      </div>
    </div>
  );
}
