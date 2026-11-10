// perfverbs.tsx — the performance changes as steps of the console's one way to
// change the site (operate.tsx, ADR-046 D3/D7): a timed raise on one CI
// (health-manager perf: Investigate, Extend, Stop) and a standing level at the
// site, an environment or a module (`--set performance.level=…` through the
// record's own manager). Each is a job previewed and applied like any other.

import { useVerb } from "./api";
import { Step } from "./operate";
import { PerfInvestigation, PerfLevel, PerfLevelRow, PerfResolution, STANDING_LEVELS } from "./perftypes";
import { Values } from "./argv";

export const UNTIL_SUGGEST = ["30m", "2h", "8h", "1d", "7d"];

const LEVEL_WORDS: Record<PerfLevel, string> = {
  off: "off — nothing is collected",
  basic: "basic — CPU, memory, disk and network, once a minute",
  service: "service — basic, and the published services' requests",
  trace: "trace — service, and request traces (timed only)",
};

// Investigate: raise one CI for a time. trace needs --until (the verb's usage
// makes it required for every raise: a raise at CI scope is always timed).
export function investigateStep(ci: { id: string; label: string }, cascaded: PerfLevel, current?: PerfInvestigation | null): Step {
  return {
    title: current ? `Extend the investigation of ${ci.label}` : `Investigate ${ci.label}`,
    bin: "health-manager",
    verb: "perf",
    fixed: [ci.id],
    initial: { "--level": current?.level ?? "trace", "--until": "2h", ...(current?.resolution === "fine" ? { "--resolution": "fine" } : {}), ...(current?.note ? { "--note": current.note } : {}) },
    choices: { "--level": ["basic", "service", "trace"], "--resolution": ["fine"] },
    suggest: { "--until": UNTIL_SUGGEST },
    labels: { "--level": "level", "--until": "until", "--resolution": "every 15 seconds", "--note": "note" },
    placeholders: { "--until": "2h", "--note": "why, for the record" },
    descriptions: {
      "--level": `Its level now: ${cascaded}. basic: CPU, memory, disk and network; service: also the published services' requests; trace: also request traces.`,
      "--until": "Required. From now (30m, 2h, 1d) or a date and time. It falls back to its level by itself then.",
      "--resolution": "Four times the samples while it holds.",
    },
    note: current
      ? `Running it again replaces the raise: same level and a later end extends it.`
      : `The raise ends by itself at the time given; Investigations lists it until then, and afterwards as history.`,
  };
}

export function stopStep(ci: { id: string; label: string }, cascaded: PerfLevel): Step {
  return {
    title: `Stop the investigation of ${ci.label}`,
    bin: "health-manager",
    verb: "perf stop",
    words: ["perf", "stop"],
    fixed: [ci.id],
    note: `It falls back to ${cascaded} at once. What was collected stays until the retention ages it out.`,
  };
}

// The level form: what changed of the level and the resolution, as one
// --set/--unset list; nothing when nothing changed.
export function levelTokens(level: string, resolution: string, row: PerfLevelRow, unsettable: boolean): string[] {
  const out: string[] = [];
  const was = row.set || row.scope === "site" ? row.level : "inherit";
  if (level !== was) {
    if (level !== "inherit") out.push("--set", `performance.level=${level}`);
    else if (unsettable) out.push("--unset", "performance.level");
  }
  if (resolution !== row.resolution || (resolution === "normal" && row.resolutionSet && !unsettable)) {
    if (resolution === "fine") out.push("--set", "performance.resolution=fine");
    else if (unsettable) out.push("--unset", "performance.resolution");
    else out.push("--set", "performance.resolution=normal");
  }
  return out;
}

function LevelForm({ values, set, row, unsettable }: { values: Values; set: (v: Values) => void; row: PerfLevelRow; unsettable: boolean }) {
  const level = typeof values["@level"] === "string" ? values["@level"] : row.set ? row.level : "inherit";
  const resolution = typeof values["@resolution"] === "string" ? values["@resolution"] : row.resolution;
  const put = (l: string, r: string) => set({ ...values, "@level": l, "@resolution": r, "@fields": levelTokens(l, r, row, unsettable) });
  const inheritFrom = row.scope === "module" ? (row.environment ? `its environment (${row.environment})` : "the site") : row.scope === "environment" ? "the site" : "";
  return (
    <div className="form">
      <label className="form-row">
        <span>Level</span>
        <select value={level} onChange={(e) => put(e.target.value, resolution)} aria-label="performance level">
          {unsettable && row.scope !== "site" ? <option value="inherit">as {inheritFrom}</option> : null}
          {STANDING_LEVELS.map((l) => <option key={l} value={l}>{LEVEL_WORDS[l]}</option>)}
        </select>
      </label>
      <label className="form-row">
        <span>Resolution</span>
        <select value={resolution} onChange={(e) => put(level, e.target.value)} aria-label="resolution">
          <option value="normal">every minute (every 30 seconds for services)</option>
          <option value="fine">every 15 seconds — four times the samples</option>
        </select>
      </label>
      <p className="muted small">Tracing is never standing: start it on one object with Investigate.</p>
    </div>
  );
}

// A standing level, through the record's own manager.
export function levelStep(row: PerfLevelRow, propose?: PerfLevel): Step {
  const start = (l: PerfLevel | "inherit", r: PerfResolution): Values => ({ "@level": l, "@resolution": r, "@fields": levelTokens(l, r, row, row.scope !== "environment") });
  const initial = start(propose ?? (row.set || row.scope === "site" ? row.level : "inherit"), row.resolution);
  // The preview waits for a change in the form, unless the step proposes one.
  const base = { initial, only: [], hide: ["--force", "--allow-disruption", "--no-snapshot", "--lockdown"], previewOnOpen: propose !== undefined && propose !== row.level, render: (values: Values, set: (v: Values) => void) => <LevelForm values={values} set={set} row={row} unsettable={row.scope !== "environment"} /> };
  if (row.scope === "site") return { ...base, title: `The site's performance level`, bin: "site-manager", verb: "site modify", words: ["site", "modify"], note: "Applied by logging's update and the nodes' and backup server's reconcile: the metric servers are set or removed." };
  if (row.scope === "environment") return { ...base, title: `Performance level of environment ${row.name}`, bin: "environment-manager", verb: "modify", fixed: [row.name], note: "Every module in it that sets no level of its own follows it." };
  return { ...base, title: `Performance level of ${row.name}`, bin: "module-manager", verb: "modify", fixed: [row.name], note: "A declared field of the module: drift-checked like its other fields. No reinstall and no OS rebuild." };
}

export function usePerfVerbs(): { perf: boolean; stop: boolean } {
  return { perf: !!useVerb("health-manager", "perf"), stop: !!useVerb("health-manager", "perf stop") };
}
