// perfchart.tsx — the performance charts (ADR-046 D7): a sparkline for a list
// row and a chart for a CI's signal, both drawn from the console's own reads,
// with the static thresholds as dashed lines and the CI's changes as markers
// (D4.2). No chart library: an SVG stretched to its box, the labels in HTML so
// they keep their size on a phone. Colours are the tokens, by class.

import { PerfAnnotation, PerfPoint, PerfRange, PerfSeries, fmtValue } from "./perftypes";

const W = 1000;
const H = 100;

export interface Scale {
  t0: number;
  t1: number;
  min: number;
  max: number;
}

// The y range of a chart: from 0 to the highest point, or the warning line
// when that is higher (and not far above), with room above. A sparkline
// (tight) spans its own lowest to highest point, so a day's swing shows.
export function scaleOf(points: PerfPoint[], warning: number | null, t0?: number, t1?: number, tight = false): Scale {
  const vs = points.map((p) => p.v);
  const hi = Math.max(1e-9, ...vs);
  const t = { t0: t0 ?? points[0]?.t ?? 0, t1: t1 ?? points[points.length - 1]?.t ?? 1 };
  if (tight) {
    const lo = Math.min(...vs);
    const pad = Math.max((hi - lo) * 0.15, hi * 0.02, 1e-9);
    return { ...t, min: Math.max(0, lo - pad), max: hi + pad };
  }
  const top = Math.max(hi, warning !== null && vs.length && warning < hi * 3 ? warning : 0);
  return { ...t, min: 0, max: top * 1.15 };
}

const yOf = (v: number, s: Scale): number => H - ((v - s.min) / Math.max(1e-9, s.max - s.min)) * H;

export function pathOf(points: PerfPoint[], s: Scale): string {
  const span = Math.max(1, s.t1 - s.t0);
  return points.map((p, i) => `${i ? "L" : "M"}${(((p.t - s.t0) / span) * W).toFixed(1)},${yOf(p.v, s).toFixed(1)}`).join("");
}

const xOf = (t: number, s: Scale): number => ((t - s.t0) / Math.max(1, s.t1 - s.t0)) * W;

export function Sparkline({ points, warning, mark, label }: { points: PerfPoint[]; warning: number | null; mark?: PerfAnnotation | null; label: string }) {
  if (!points.length) return <span className="muted small">no numbers</span>;
  const s = scaleOf(points, warning, undefined, undefined, true);
  const m = mark ? Date.parse(mark.at) : null;
  return (
    <svg className="pc-spark" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label={label}>
      {warning !== null && warning < s.max && warning > s.min ? <line className="pc-warn" x1={0} x2={W} y1={yOf(warning, s)} y2={yOf(warning, s)} vectorEffect="non-scaling-stroke" /> : null}
      {m !== null && m >= s.t0 ? <line className="pc-mark" x1={xOf(m, s)} x2={xOf(m, s)} y1={0} y2={H} vectorEffect="non-scaling-stroke"><title>{`${mark!.label}${mark!.actor ? ` · ${mark!.actor}` : ""}`}</title></line> : null}
      <path className="pc-line" d={pathOf(points, s)} vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

const DAY = 86400_000;
function tick(t: number, range: PerfRange): string {
  const d = new Date(t);
  const hm = d.toISOString().slice(11, 16);
  if (range === "24h") return hm;
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
}

// The numbered markers under a chart: what changed, when, by whom.
export function Markers({ marks }: { marks: PerfAnnotation[] }) {
  if (!marks.length) return null;
  return (
    <ol className="pc-marks">
      {marks.map((a, i) => (
        <li key={`${a.at}${i}`}>
          <span className="pc-mark-n">{i + 1}</span> <span className="nowrap">{new Date(a.at).toISOString().slice(0, 16).replace("T", " ")}</span> {a.label}
          <span className="muted small">{a.actor ? ` · ${a.actor}` : ""}</span>
        </li>
      ))}
    </ol>
  );
}

export function Chart({ series, marks, range, now }: { series: PerfSeries; marks: PerfAnnotation[]; range: PerfRange; now: number }) {
  const spans: Record<PerfRange, number> = { "24h": DAY, "7d": 7 * DAY, "30d": 30 * DAY, "90d": 90 * DAY };
  const t1 = series.points[series.points.length - 1]?.t ?? now;
  const t0 = t1 - spans[range];
  const s = scaleOf(series.points, series.warning, t0, t1);
  const lines = [series.warning, series.critical].filter((v): v is number => v !== null && v < s.max);
  return (
    <figure className="pc-chart">
      <figcaption>
        <b>{series.label}</b> <span className={`pc-now pc-${series.status}`}>{fmtValue(series.now, series.unit)}</span>
        {series.warning !== null ? <span className="muted small"> · warning at {fmtValue(series.warning, series.unit)}</span> : null}
      </figcaption>
      {series.points.length ? (
        <div className="pc-plot">
          <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label={`${series.label} over ${range}`}>
            <line className="pc-grid" x1={0} x2={W} y1={H / 2} y2={H / 2} vectorEffect="non-scaling-stroke" />
            {lines.map((v) => <line key={v} className={v === series.critical ? "pc-crit" : "pc-warn"} x1={0} x2={W} y1={yOf(v, s)} y2={yOf(v, s)} vectorEffect="non-scaling-stroke" />)}
            {marks.map((a, i) => {
              const x = xOf(Date.parse(a.at), s);
              return <line key={i} className="pc-mark" x1={x} x2={x} y1={0} y2={H} vectorEffect="non-scaling-stroke"><title>{`${i + 1}: ${a.label}`}</title></line>;
            })}
            <path className="pc-line" d={pathOf(series.points, s)} vectorEffect="non-scaling-stroke" />
          </svg>
          <span className="pc-y pc-y-top">{fmtValue(s.max, series.unit)}</span>
          <span className="pc-y pc-y-mid">{fmtValue(s.max / 2, series.unit)}</span>
          {marks.map((a, i) => <span key={i} className="pc-mark-n pc-mark-at" style={{ left: `${(xOf(Date.parse(a.at), s) / W) * 100}%` }}>{i + 1}</span>)}
          <div className="pc-x">
            <span>{tick(t0, range)}</span>
            <span>{tick(t0 + (t1 - t0) / 2, range)}</span>
            <span>{tick(t1, range)}</span>
          </div>
        </div>
      ) : <p className="muted small">No numbers in this range.</p>}
    </figure>
  );
}
