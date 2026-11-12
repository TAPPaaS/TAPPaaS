// Security — the security workspace, two tabs (?tab=threats). Threats
// (Threats.tsx): what is happening on the running systems. Vulnerabilities:
// the site's CVE risk, from the last security scan. First what to
// do, one card per component or update: for you (update, coming, your
// decision), waiting (with TAPPaaS, with upstream) and, where the release train
// runs, for the maintainers. Then the site's level and score, each
// environment, its zones (with their multiplier) and the modules and platform
// targets in them. A module opens to its CVEs: the mark (unread, by rule,
// confirmed, deferred, to review, accepted), upstream → effective level,
// package, version and why.

import { useState } from "react";
import { useRead } from "../api";
import {
  MAINTAINER_QUEUES, OPERATOR_QUEUES, QueueCard, SecurityCve, SecurityQueues, SecurityRow, SecurityUnit, SecurityView, SecurityZone, cardTone, countsText, cveCategory, cveNote,
  levelsText, markTone, markWord, riskText, riskTone, sparkPoints, sparkTitle, unitLabel,
} from "../security";
import { Badge, Link, ReadState, Section, replacePath, since, when } from "../ui";
import { Threats } from "./Threats";

const W = 84;
const H = 20;

function Spark({ days, values }: { days: string[]; values: (number | null)[] }) {
  const runs = sparkPoints(values, W, H);
  return (
    <svg className="sec-spark" width={W} height={H} viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`last 7 days: ${values.map((v) => v ?? "no scan").join(", ")}`}>
      <title>{sparkTitle(days, values)}</title>
      <line x1={0} y1={H - 1} x2={W} y2={H - 1} className="sec-spark-floor" />
      {runs.map((p) => (p.includes(" ") ? <polyline key={p} points={p} className="sec-spark-line" /> : <circle key={p} cx={p.split(",")[0]} cy={p.split(",")[1]} r={1.5} className="sec-spark-dot" />))}
    </svg>
  );
}

function Level({ r }: { r: { level: SecurityRow["level"]; score: number } }) {
  return <Badge level={riskTone(r.level)}>{riskText(r)}</Badge>;
}

function Row({ depth, label, row, counts, days, open, onToggle }: {
  depth: number; label: string; row: SecurityRow; counts?: string; days: string[]; open?: boolean; onToggle?: () => void;
}) {
  const name = onToggle ? (
    <button className="sec-toggle" onClick={onToggle} aria-expanded={open}>
      <span className="sec-caret" aria-hidden>{open ? "▾" : "▸"}</span> {label}
    </button>
  ) : label;
  return (
    <div className={`sec-row sec-d${depth}`}>
      <span className="sec-name">{name}</span>
      <span className="sec-level"><Level r={row} /></span>
      <span className="sec-by muted">{row.setBy ?? ""}</span>
      <span className="sec-counts muted">{counts ?? ""}</span>
      <span className="sec-trend"><Spark days={days} values={row.spark} /></span>
    </div>
  );
}

function Cves({ cves }: { cves: SecurityCve[] }) {
  if (cves.length === 0) return <p className="muted small sec-cves">No CVE counts here.</p>;
  return (
    <ul className="sec-cves">
      {cves.map((c) => (
        <li key={`${c.id}-${c.state}`} className="sec-cve">
          <div className="sec-cve-head">
            <Badge level={markTone(c)}>{markWord(c)}</Badge>
            <span className="mono">{c.id}</span>
            <span className="muted">{cveCategory(c)}</span>
            <span><span className="mono">{c.pkg}</span> <span className="muted mono">{c.version}</span></span>
          </div>
          {cveNote(c) ? <div className="sec-cve-note small">{cveNote(c)}</div> : null}
        </li>
      ))}
    </ul>
  );
}

function Unit({ u, depth, days }: { u: SecurityUnit; depth: number; days: string[] }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Row depth={depth} label={unitLabel(u)} row={u} counts={u.failed ? "the scan failed: not counted" : countsText(u.counts, u.marks)} days={days} open={open} onToggle={() => setOpen(!open)} />
      {open ? <div className={`sec-d${depth + 1}`}><Cves cves={u.cves} /></div> : null}
    </>
  );
}

function Zone({ z, depth, days }: { z: SecurityZone; depth: number; days: string[] }) {
  return (
    <>
      <Row depth={depth} label={`zone ${z.name} ×${z.multiplier}`} row={z} days={days} />
      {z.units.map((u) => <Unit key={u.key} u={u} depth={depth + 1} days={days} />)}
      {z.units.length === 0 ? <div className={`sec-row sec-d${depth + 1} muted small`}>nothing scanned runs here</div> : null}
    </>
  );
}

function Card({ c }: { c: QueueCard }) {
  return (
    <li className="sec-card">
      <div className="sec-card-head">
        <Badge level={cardTone(c)}>{c.worst || "low"}</Badge>
        <b>{c.title}</b>
        {c.baseline ? <span className="muted small">NixOS baseline, shown once</span> : null}
      </div>
      <div className="small">{c.text}</div>
      {c.action ? <div className="sec-card-action mono small muted">{c.action}</div> : null}
    </li>
  );
}

function Queue({ title, empty, cards }: { title: string; empty: string; cards: QueueCard[] }) {
  const [all, setAll] = useState(false);
  const shown = all ? cards : cards.slice(0, 5);
  return (
    <div className="sec-queue">
      <h3 className="sec-queue-title">{title}{cards.length ? <span className="muted small"> · {cards.length}</span> : null}</h3>
      {cards.length === 0 ? <p className="muted small">{empty}</p> : (
        <ul className="sec-cards">{shown.map((c) => <Card key={`${c.title}-${c.text}`} c={c} />)}</ul>
      )}
      {cards.length > 5 ? <button className="sec-toggle small" onClick={() => setAll(!all)}>{all ? "Show the first five" : `Show all ${cards.length}`}</button> : null}
    </div>
  );
}

function Queues({ q }: { q: SecurityQueues }) {
  const ops = (keys: string[]) => OPERATOR_QUEUES.filter((x) => keys.includes(x.key));
  return (
    <>
      <Section title="For you" aside="what this site's operator can do">
        {ops(["update", "coming", "decision"]).map((x) => <Queue key={x.key} title={x.title} empty={x.empty} cards={q.operator[x.key] ?? []} />)}
      </Section>
      <Section title="Waiting" aside="nothing for you to do: counted until it is decided or fixed">
        {ops(["tappaas", "upstream"]).map((x) => <Queue key={x.key} title={x.title} empty={x.empty} cards={q.operator[x.key] ?? []} />)}
      </Section>
      {q.maintainer ? (
        <Section title="For the maintainers" aside="where the release train runs">
          {MAINTAINER_QUEUES.map((x) => <Queue key={x.key} title={x.title} empty={x.empty} cards={q.maintainer?.[x.key] ?? []} />)}
        </Section>
      ) : null}
    </>
  );
}

const TABS = [
  { id: "vulnerabilities", name: "Vulnerabilities" },
  { id: "threats", name: "Threats" },
] as const;
type Tab = (typeof TABS)[number]["id"];
const tabOf = (search: string): Tab => (new URLSearchParams(search).get("tab") === "threats" ? "threats" : "vulnerabilities");

export function Security() {
  const [tab, setTab] = useState<Tab>(() => tabOf(window.location.search));
  const go = (t: Tab): void => {
    setTab(t);
    replacePath(t === "vulnerabilities" ? "/security" : `/security?tab=${t}`);
  };
  return (
    <div className={`page${tab === "threats" ? " page-wide" : ""}`}>
      <div className="page-head">
        <h1>Security</h1>
        <span className="muted">{tab === "threats" ? "what is happening on the running systems" : "what could be attacked: the CVEs of what runs"}</span>
      </div>
      <div className="tabs" role="tablist">
        {TABS.map((t) => (
          <button key={t.id} role="tab" aria-selected={tab === t.id} className={tab === t.id ? "tab tab-on" : "tab"} onClick={() => go(t.id)}>
            {t.name}
          </button>
        ))}
      </div>
      {tab === "threats" ? <Threats /> : <Vulnerabilities />}
    </div>
  );
}

function Vulnerabilities() {
  const r = useRead<SecurityView>("security", 300_000);
  const v = r.env?.data ?? null;
  return (
    <>
      <p className="muted small">CVE risk · health-manager report security · read {since(r.env?.at)}</p>
      <ReadState env={r.env} failure={r.failure} what="the security scan" />
      {r.env && !r.env.error && !v ? (
        <p className="readstate">No security scan yet. The first runs after the next sweep, or with health-manager scan security.</p>
      ) : null}
      {v ? (
        <>
          <Section title="Site" aside={`scanned ${when(v.generated)}${v.inventory ? ` · inventory of ${when(v.inventory)}, matched again` : ""}`}>
            <div className="sec-site">
              <span className="sec-site-level"><Level r={v.site} /></span>
              <span>{v.site.setBy ? <>set by <b>{v.site.setBy}</b></> : "nothing counts"}</span>
              <Spark days={v.days} values={v.site.spark} />
            </div>
            {v.levels?.length ? <p className="muted small">Score per level: {levelsText(v.levels)}.</p> : null}
          </Section>
          {v.queues ? <Queues q={v.queues} /> : null}
          <Section title="Environments, zones and modules" aside="open a module for its CVEs">
            <div className="sec-head sec-row">
              <span className="sec-name">name</span>
              <span className="sec-level">level, score</span>
              <span className="sec-by">set by</span>
              <span className="sec-counts">CVEs</span>
              <span className="sec-trend">7 days</span>
            </div>
            {v.environments.map((e) => (
              <div key={e.key} className="sec-group">
                <Row depth={0} label={`environment ${e.name}`} row={e} days={v.days} />
                {e.zones.map((z) => <Zone key={z.key} z={z} depth={1} days={v.days} />)}
                {e.zones.length === 0 ? <div className="sec-row sec-d1 muted small">nothing scanned runs here</div> : null}
              </div>
            ))}
            {v.outside.length ? (
              <div className="sec-group">
                <div className="sec-row sec-d0 muted small">zones in no environment</div>
                {v.outside.map((z) => <Zone key={z.key} z={z} depth={0} days={v.days} />)}
              </div>
            ) : null}
            {v.failed.length ? <p className="muted small">The scan failed for {v.failed.join(", ")}: not counted. <Link to="/health">Health</Link> has the reason.</p> : null}
          </Section>
          <p className="muted small">
            Each CVE counts at its effective level: critical 20, high 8, medium 3, low 1; one decided not to affect this site counts nothing. A module counts only
            its highest level; each further CVE in it counts half the one before. A zone takes its highest module times its tier&apos;s multiplier; an environment
            and the site take their highest. Unread: nobody has decided it. By rule: a rule lowered it and nobody has read it yet. To review: a decision no longer
            holds. Accepted: this site accepted it until a date; it counts nothing here.
          </p>
        </>
      ) : null}
    </>
  );
}
