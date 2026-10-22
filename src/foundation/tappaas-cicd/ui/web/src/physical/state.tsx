// state.tsx — the one legend of the Physical views' colours (states.ts).

export { STATE_COLOR, stateClass, stateOf } from "./states";
export type { CardState } from "./states";

export function StateLegend({ extra }: { extra?: string }) {
  return (
    <span className="state-legend">
      <span className="muted">State:</span>
      <span><i className="st-swatch st-ok" /> ok</span>
      <span><i className="st-swatch st-warn" /> warn</span>
      <span><i className="st-swatch st-fail" /> fail</span>
      <span className="muted">— the reason on hover, the findings on click{extra ? ` · ${extra}` : ""}</span>
    </span>
  );
}
