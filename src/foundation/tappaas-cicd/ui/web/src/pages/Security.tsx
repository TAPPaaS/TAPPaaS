// Security — the site's CVE risk, from the last security scan: the site's
// level and score, then each environment, its zones (with their multiplier)
// and the modules and platform targets in them; the zones in no environment
// sit directly under the site. Each row says its level, its score, what sets
// it, its CVEs by state and its last seven days. A module opens to the CVEs
// it counts, with state, category, package, version and the analysis.
// Whether a fix exists is not shown here.

import { useState } from "react";
import { useRead } from "../api";
import {
  STATE_WORD, SecurityCve, SecurityRow, SecurityUnit, SecurityView, SecurityZone, countsText, cveCategory, cveNote, riskText, riskTone, sparkPoints, sparkTitle, unitLabel,
} from "../security";
import { Badge, Link, ReadState, Section, since, when } from "../ui";

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
            <Badge level={c.state === "decided" ? "skip" : c.state === "risk" ? "info" : "warn"}>{STATE_WORD[c.state]}</Badge>
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
      <Row depth={depth} label={unitLabel(u)} row={u} counts={u.failed ? "the scan failed: not counted" : countsText(u.counts)} days={days} open={open} onToggle={() => setOpen(!open)} />
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

export function Security() {
  const r = useRead<SecurityView>("security", 300_000);
  const v = r.env?.data ?? null;
  return (
    <div className="page">
      <div className="page-head">
        <h1>Security</h1>
        <span className="muted">CVE risk · health-manager report security · read {since(r.env?.at)}</span>
      </div>
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
          </Section>
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
            A module counts only its highest category; each further CVE in it counts half the one before. A zone takes its highest module times its tier&apos;s
            multiplier; an environment and the site take their highest. Decided CVEs count nothing. Open: not analysed. Risk: analysed, counted at the rating given here.
            Carried: analysed for another version of the package.
          </p>
        </>
      ) : null}
    </div>
  );
}
