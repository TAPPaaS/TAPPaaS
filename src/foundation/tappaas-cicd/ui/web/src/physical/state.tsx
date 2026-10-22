// state.tsx — the colour language of the Physical views: every card coloured
// by its state, ok green, warn amber, fail red, the reason on hover, and the
// one legend that says so.

export type CardState = "ok" | "warn" | "fail";

export const STATE_COLOR: Record<CardState, string> = { ok: "var(--pass)", warn: "var(--warn)", fail: "var(--fail)" };

// A card's left border and tint.
export const stateClass = (s: CardState): string => `st st-${s}`;

// From a finding's level, the worst of a list.
export function stateOf(levels: ("warn" | "fail" | string)[]): CardState {
  return levels.includes("fail") ? "fail" : levels.includes("warn") ? "warn" : "ok";
}

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
