// testrun.ts — `site-manager test` in short: one line per module, the whole
// output of each module test in a log file of its own.
//
// A deep run prints tens of thousands of lines, most of them passing checks
// and the noise of the tools under test, so a failure scrolled out of reach
// before anyone saw it. The verdict needs only which module failed and on
// which checks; the rest is in the log, which outlives the terminal.

const ANSI = /\x1b\[[0-9;]*m/g;

// The lines of a module test's output that name a failed check: a ✗ (the
// test-module.sh and pass/fail helpers), `FAIL:` (the tabletop suites) and
// `[FAIL]` (the module test.sh files). A passing check whose text mentions a
// failure ("✓ … is SCAN FAILED, never clean", "ok: … never FAIL") is not one.
export function failingLines(text: string, max = 15): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.replace(ANSI, "").trim();
    if (!line) continue;
    if (/(^|\s)(✓|ok:)\s/.test(line) || line.startsWith("[PASS]")) continue;
    if (!/✗|\bFAIL:|\[FAIL\]/.test(line)) continue;
    if (seen.has(line)) continue;
    seen.add(line);
    out.push(line);
    if (out.length >= max) break;
  }
  return out;
}

// A run's directory name: site-test-<yyyymmdd>-<hhmmss>, local time, so it
// sorts and reads like the other logs beside it.
export function runDirName(now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `site-test-${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}` +
    `-${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
}

// 75 s → "1m15s", 9 s → "9s".
export function duration(ms: number): string {
  const s = Math.round(ms / 1000);
  return s >= 60 ? `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s` : `${s}s`;
}
