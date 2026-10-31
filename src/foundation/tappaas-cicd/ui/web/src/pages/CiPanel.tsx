// CiPanel.tsx — a CI's record (ADR-040 D10): its attributes with their source
// and since, its open events, its relations both ways, its drift, its history
// (the newest first) and its trace up the backbone — what it runs on, its
// desired record, release and module, the module's open issues and ADRs. Each
// CI named in it opens its own record here; Back walks the way returned.
// Opened from the Health view's panel and from a device on the Site page;
// embedded on an asset's page (AssetPage.tsx).

import { useEffect, useState } from "react";
import { useRead } from "../api";
import { CiHistoryRow, CiRecord, CiTraceStep } from "../types";
import { Link, ReadState, Section, Tag, when } from "../ui";

export type CiRef = { id: string } | { name: string; cls?: string };

const keyOf = (r: CiRef): string => ("id" in r ? r.id : `${r.cls ?? ""}/${r.name}`);
const pathOf = (r: CiRef): string =>
  "id" in r ? `cmdb/ci/${encodeURIComponent(r.id)}` : `cmdb/ci?name=${encodeURIComponent(r.name)}${r.cls ? `&class=${encodeURIComponent(r.cls)}` : ""}`;

// A value as one short line; an object or a list as JSON, cut.
function show(v: unknown, max = 160): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "string") return v.length > max ? `${v.slice(0, max)}…` : v;
  const s = JSON.stringify(v);
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

function Value({ v }: { v: unknown }) {
  if (v !== null && typeof v === "object" && JSON.stringify(v).length > 60) {
    return (
      <details className="ff-shut">
        <summary>{show(v, 60)}</summary>
        <pre className="output">{JSON.stringify(v, null, 2)}</pre>
      </details>
    );
  }
  return <span>{show(v)}</span>;
}

function Pick({ id, label, open }: { id: string; label: string; open: (r: CiRef) => void }) {
  return (
    <button className="hlink" onClick={() => open({ id })}>
      {label}
    </button>
  );
}

function TraceRow({ s, open }: { s: CiTraceStep; open: (r: CiRef) => void }) {
  const label = s.id ? <Pick id={s.id} label={s.name} open={open} /> : s.link?.startsWith("/") ? <Link to={s.link}>{s.name}</Link> : s.link ? <a href={s.link} target="_blank" rel="noreferrer">{s.name}</a> : <span>{s.name}</span>;
  return (
    <li>
      {s.relation ? <span className="muted small">{s.relation} ↑ </span> : null}
      {label} <span className="muted small">{s.class}</span>
    </li>
  );
}

function HistoryRow({ h, open }: { h: CiHistoryRow; open: (r: CiRef) => void }) {
  const end = h.until ? <span className="muted small"> · until {when(h.until)}</span> : null;
  const other = h.what === "relation" && h.value && typeof h.value === "object" ? (h.value as { id: string; name: string }) : null;
  return (
    <li>
      <span className="nowrap">{when(h.at)}</span>{" "}
      {h.what === "change" ? (
        <>
          {h.drift ? <Tag level="warning" /> : null} {h.name} <span className="muted small">{h.source}{h.detail ? ` · ${h.detail}` : ""}</span>
        </>
      ) : h.what === "relation" ? (
        <>
          <span className="muted small">{h.name} {h.detail === "in" ? "←" : "→"}</span> {other ? <Pick id={other.id} label={other.name} open={open} /> : show(h.value)}
          <span className="muted small"> · {h.source ?? "?"}</span>
          {end}
        </>
      ) : (
        <>
          <b>{h.name}</b> = <Value v={h.value} /> <span className="muted small">· {h.source ?? "?"}</span>
          {end}
        </>
      )}
    </li>
  );
}

const HISTORY_FIRST = 25;

// embedded: on a page (an asset's), not a side panel: no header and no close;
// only: the sections shown there (the page shows the attributes its own way).
export function CiPanel({ start, close, back, embedded, only }: { start: CiRef; close?: () => void; back?: { label: string; go: () => void }; embedded?: boolean; only?: ("events" | "trace" | "attributes" | "drift" | "relations" | "history")[] }) {
  const shows = (x: NonNullable<typeof only>[number]): boolean => !only || only.includes(x);
  // The way here: the start, then each CI opened from within.
  const [trail, setTrail] = useState<CiRef[]>([start]);
  const [more, setMore] = useState(false);
  useEffect(() => setTrail([start]), [keyOf(start)]); // eslint-disable-line react-hooks/exhaustive-deps
  const here = trail[trail.length - 1];
  useEffect(() => setMore(false), [keyOf(here)]); // eslint-disable-line react-hooks/exhaustive-deps
  const open = (r: CiRef): void => setTrail((t) => (keyOf(t[t.length - 1]) === keyOf(r) ? t : [...t, r]));
  const rec = useRead<CiRecord>(pathOf(here));
  const o = rec.env?.data ?? null;
  const id = o && (!("id" in here) || o.id === here.id) ? o.id : null;
  const hist = useRead<CiHistoryRow[]>(id ? `cmdb/ci/${encodeURIComponent(id)}/history` : null, 60_000);
  const trace = useRead<CiTraceStep[]>(id ? `cmdb/ci/${encodeURIComponent(id)}/trace` : null, 300_000);
  const rows = hist.env?.data ?? [];
  const steps = trace.env?.data ?? [];
  const out = (o?.relations ?? []).filter((x) => x.direction === "out");
  const inc = (o?.relations ?? []).filter((x) => x.direction === "in");
  const Shell = embedded ? "div" : "aside";
  return (
    <Shell className={embedded ? "ci-embedded" : "sidepanel health-panel ci-panel"}>
      {embedded ? (
        trail.length > 1 ? (
          <p>
            <button className="hlink" onClick={() => setTrail((t) => t.slice(0, -1))}>← Back</button> <span className="muted small">{o ? `${o.label} · ${o.class}` : ""}</span>
          </p>
        ) : null
      ) : (
        <>
          <header>
            <div>
              <b>{o?.label ?? ("name" in here ? here.name : "…")}</b>
              <div className="muted small">{o ? `${o.class}${o.ancestors.length ? ` · ${o.ancestors.filter((a) => a !== o.class && a !== "object").join(" › ")}` : ""} · CMDB record` : "CMDB record"}</div>
            </div>
            {close ? <button className="btn-x" onClick={close} aria-label="Close">×</button> : null}
          </header>
          <p>
            {trail.length > 1 ? <button className="hlink" onClick={() => setTrail((t) => t.slice(0, -1))}>← Back</button> : back ? <button className="hlink" onClick={back.go}>← {back.label}</button> : null}
          </p>
        </>
      )}
      <ReadState env={rec.env} failure={rec.failure} what="this CI's record (the CMDB)" />
      {o ? (
        <>
          {shows("events") ? (
          <Section title="Open events" aside={`${o.events.length}`}>
            {o.events.length === 0 ? <p className="muted">None: every condition on it is ok, or nothing has assessed it.</p> : null}
            <ul className="attention">
              {o.events.map((e) => (
                <li key={e.type} className="att">
                  <Tag level={e.status} /> <span className="att-gate">{e.type}</span>
                  <span className="att-text">
                    {e.message ?? e.reason ?? e.status}
                    <span className="muted small">
                      {e.since ? ` · since ${when(e.since)}` : ""}
                      {e.source ? ` · ${e.source}` : ""}
                      {e.derived ? " · derived" : ""}
                      {e.acknowledged ? " · acknowledged" : ""}
                      {e.maintenance ? " · in maintenance" : ""}
                    </span>
                  </span>
                </li>
              ))}
            </ul>
          </Section>
          ) : null}
          {shows("trace") ? (
          <Section title="Trace" aside="up the backbone">
            <ReadState env={trace.env} failure={trace.failure} what="the trace" />
            <ul className="plain">
              {steps.map((s, i) => <TraceRow key={`${i}:${s.class}:${s.name}`} s={s} open={open} />)}
            </ul>
            {trace.env?.data && !steps.some((s) => s.class === "desired" || s.class === "module") ? <p className="muted small">No desired record or module is recorded on it or on what it runs on.</p> : null}
          </Section>
          ) : null}
          {shows("attributes") ? (
          <Section title="Attributes" aside={`${o.attributes.length}`}>
            <table className="table small">
              <thead>
                <tr>
                  <th>attribute</th>
                  <th>value</th>
                  <th>source</th>
                  <th>since</th>
                </tr>
              </thead>
              <tbody>
                {o.attributes.map((a) => (
                  <tr key={a.name}>
                    <td>{a.name}</td>
                    <td><Value v={a.value} /></td>
                    <td className="muted">{a.source}</td>
                    <td className="nowrap muted">{when(a.since)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>
          ) : null}
          {o.drift && shows("drift") ? (
            <Section title="Drift — against its record">
              <pre className="output">{typeof o.drift === "string" ? o.drift : JSON.stringify(o.drift, null, 2)}</pre>
            </Section>
          ) : null}
          {shows("relations") ? (
          <Section title="Relations" aside={`${o.relations.length}`}>
            {o.relations.length === 0 ? <p className="muted">None.</p> : null}
            <ul className="plain">
              {[...out, ...inc].map((x) => (
                <li key={`${x.direction}${x.id}`}>
                  <span className="muted small">{x.type} {x.direction === "out" ? "→" : "←"}</span> <Pick id={x.other.id} label={x.other.name} open={open} /> <span className="muted small">{x.other.class}{x.source ? ` · ${x.source}` : ""}{x.since ? ` · since ${when(x.since)}` : ""}</span>
                </li>
              ))}
            </ul>
          </Section>
          ) : null}
          {shows("history") ? (
          <Section title="History" aside="the newest first">
            <ReadState env={hist.env} failure={hist.failure} what="the history" />
            <details className="ff-shut">
              <summary>{rows.length} {rows.length === 1 ? "entry" : "entries"}: attributes, relations and the changes that wrote them</summary>
              <ul className="findings">
                {(more ? rows : rows.slice(0, HISTORY_FIRST)).map((h, i) => <HistoryRow key={i} h={h} open={open} />)}
              </ul>
              {!more && rows.length > HISTORY_FIRST ? <button className="hlink" onClick={() => setMore(true)}>Show all {rows.length}</button> : null}
            </details>
          </Section>
          ) : null}
        </>
      ) : null}
    </Shell>
  );
}
