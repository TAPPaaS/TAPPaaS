// states.ts — the colour language of the Physical views: every card coloured
// by its state, ok green, warn amber, fail red, the reason on hover (the
// legend that says so is state.tsx). Plain data: the unit tests read it.

export type CardState = "ok" | "warn" | "fail";

export const STATE_COLOR: Record<CardState, string> = { ok: "var(--pass)", warn: "var(--warn)", fail: "var(--fail)" };

// A card's left border and tint.
export const stateClass = (s: CardState): string => `st st-${s}`;

// From a finding's level, the worst of a list.
export function stateOf(levels: ("warn" | "fail" | string)[]): CardState {
  return levels.includes("fail") ? "fail" : levels.includes("warn") ? "warn" : "ok";
}

