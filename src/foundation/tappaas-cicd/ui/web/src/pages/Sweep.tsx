// Sweep.tsx — the discovery sweep on the Assets page (ADR-040 D15): run it,
// and what the last one found against the sweep before and against config/.
// An object it names opens on the Health page.

import { useEffect, useRef, useState } from "react";
import { post, useRead } from "../api";
import { ago } from "../healthwords";
import { DiscoverySweep, DiscoverySweepState, SiteRead } from "../types";
import { Link, ReadState, Section, Tag, canOperate, navigate, useMe, when } from "../ui";

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
        <Tag level={s.status} /> {when(s.time)} ({ago(s.time)} ago)
        <span className="muted"> · {s.since ? `against the sweep of ${when(s.since)}` : "the baseline: the next one lists what changed"}</span>
      </p>
      <p className="muted small">
        {c.drift ?? 0} drift · {c.desired ?? 0} from desired · {c.unmanaged ?? 0} unmanaged · {c.missing ?? 0} missing · {c.unread ?? 0} not compared · {c.expected ?? 0} expected ({c.new ?? 0} new) · {s.sources.length} source(s), {c.sourcesFailed ?? failed.length} failed
      </p>
      {failed.length ? <div className="readstate readstate-fail">Sources that failed: {failed.map((x) => `${x.source}${x.error ? ` (${x.error})` : ""}`).join(", ")}</div> : null}
      {plain.length ? <p className="muted small">Asked without --discover (they do not know it yet): {plain.map((x) => x.source).join(", ")}</p> : null}
      {s.findings.length ? (
        <div className="sweep-findings">
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
        </div>
      ) : <p className="muted">Nothing found that a change does not explain.</p>}
    </>
  );
}

export function Sweep({ onDone = () => undefined, open = (id: string) => navigate(`/health?select=${encodeURIComponent(id)}`) }: { onDone?: () => void; open?: (id: string) => void }) {
  const me = useMe();
  const [poll, setPoll] = useState(60_000);
  const r = useRead<DiscoverySweepState>("assets/sweep", poll);
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
    void post<{ running: DiscoverySweepState["running"] }>("assets/sweep", {})
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


// The nightly update sweep's last run (update-tappaas), beside the discovery
// sweep that runs before it: when, whether it succeeded, how many modules.
export function LastUpdateSweep() {
  const site = useRead<SiteRead>("site");
  const s = site.env?.data?.lastSweep;
  return (
    <Section title="Last update sweep" aside={<Link to="/activity">Activity</Link>}>
      <ReadState env={site.env} failure={site.failure} what="the last update sweep" />
      {s ? (
        <p>
          <Tag level={s.ok ? "pass" : "fail"} /> {when(s.end_time?.replace(" ", "T"))} · {s.ok ? "succeeded" : "failed"}
          <span className="muted"> · {s.total ?? "?"} modules · {s.failed ?? 0} failed · reboot {s.reboot ?? "?"}</span>
        </p>
      ) : site.env ? <p className="muted">No update sweep has run yet.</p> : null}
    </Section>
  );
}
