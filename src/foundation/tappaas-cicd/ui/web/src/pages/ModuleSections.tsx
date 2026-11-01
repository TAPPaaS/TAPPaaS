// ModuleSections.tsx — a section of a module's page as the backend composed it
// (sections.ts): one renderer per block, whatever layer contributed it. An error
// stands in the section's place; the page around it is never blank.

import { ReactNode } from "react";
import { OperateButton } from "../operate";
import { binaryBytes } from "../overview";
import { gaugeLevel, gaugePct, valueText } from "../sectionview";
import { ModuleSection, SectionBlock, SectionFormat } from "../types";
import { Badge, KV, Link, Section, levelOf, since } from "../ui";

const GAUGE_COLOR = { pass: "var(--gauge-pass)", warn: "var(--gauge-warn)", fail: "var(--gauge-fail)", skip: "var(--steel)" };

function Value({ v, format }: { v: unknown; format?: SectionFormat }): ReactNode {
  const text = valueText(v, format);
  if (text === "—") return <span className="muted">—</span>;
  if (format === "module") return <Link to={`/modules/${encodeURIComponent(text)}`}>{text}</Link>;
  if (format === "status") return <Badge level={levelOf(text)}>{text}</Badge>;
  return text;
}

function Block({ b }: { b: SectionBlock }) {
  const head = "title" in b && b.title ? <h3>{b.title}</h3> : null;
  switch (b.kind) {
    case "note":
      return <p className="muted">{b.text}</p>;
    case "text":
      return <>{head}<pre className="mono small">{b.text}</pre></>;
    case "kv":
      return <>{head}<KV rows={b.rows.filter((r) => r.value !== null && r.value !== undefined && r.value !== "").map((r) => [r.label, <Value v={r.value} format={r.format} />])} /></>;
    case "table":
      return (
        <>
          {head}
          {b.rows.length === 0 ? <p className="muted">{b.empty ?? "nothing to show"}</p> : (
            <table className="table compact">
              <thead><tr>{b.columns.map((c) => <th key={c.key}>{c.label}</th>)}</tr></thead>
              <tbody>
                {b.rows.map((r, i) => <tr key={i}>{b.columns.map((c) => <td key={c.key}><Value v={r[c.key]} format={c.format} /></td>)}</tr>)}
              </tbody>
            </table>
          )}
        </>
      );
    case "gauges":
      return (
        <>
          {head}
          {b.gauges.length === 0 ? <p className="muted">{b.empty ?? "nothing to show"}</p> : null}
          {b.gauges.map((g) => (
            <div key={g.label} className="section-gauge">
              <span>{g.label}</span>
              <span className="fillbar"><i style={{ width: `${gaugePct(g)}%`, background: GAUGE_COLOR[gaugeLevel(g)] }} /></span>
              <span className="muted small">{valueText(g.value, g.format)} of {valueText(g.max, g.format)} · {gaugePct(g).toFixed(0)}%</span>
            </div>
          ))}
        </>
      );
  }
}

// A section's summary, in powers of 1024 as the Site card has a node's memory.
const summaryText = (g: NonNullable<ModuleSection["summary"]>): string => {
  const v = (n: number): string => (g.format === "bytes" ? binaryBytes(n) : valueText(n, g.format));
  return `${v(g.value)} of ${v(g.max)}${g.label ? ` ${g.label}` : ""}`;
};

export function SectionView({ s }: { s: ModuleSection }) {
  const aside = [s.source, s.at ? since(s.at) : null].filter(Boolean).join(" · ");
  return (
    <Section title={<>{s.title}{s.summary ? " " : null}{s.summary ? <span className="section-summary">{summaryText(s.summary)}</span> : null}</>} aside={aside || undefined}>
      {s.error ? <div className="readstate readstate-fail">{s.error}</div> : null}
      {s.blocks.map((b, i) => <Block key={i} b={b} />)}
      {s.operations.length || s.operationErrors.length ? (
        <div className="operate">
          {s.operations.map((o) => (
            <div key={`${o.bin} ${o.verb}`} className="op">
              <OperateButton label={o.label} kind={o.kind ?? undefined} title={o.label} steps={[{ title: [o.bin, o.verb, ...o.fixed].join(" "), bin: o.bin, verb: o.verb, fixed: o.fixed }]} />
              {o.note ? <small>{o.note}</small> : null}
            </div>
          ))}
          {s.operationErrors.map((e) => <div key={e} className="readstate readstate-fail">{e}</div>)}
        </div>
      ) : null}
    </Section>
  );
}
