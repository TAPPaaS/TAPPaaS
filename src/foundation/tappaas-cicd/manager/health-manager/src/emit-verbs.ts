// emit-verbs.ts — the emitting half's verbs (ADR-041 D2, D4): their help and
// their dispatch, in one place so main.ts carries one line of each.

import { HelpVerb } from "../../../lib/ts/src/help";
import { die, info, warn } from "../../../lib/ts/src/cli";
import { readFileSync } from "fs";
import { CmdbUnavailable } from "../../../lib/ts/src/cmdb";
import { currentJob } from "../../../lib/ts/src/job";
import { VerbContext, ack, maintenanceStart, maintenanceStop, unack } from "./ack";
import { SweepRecord, readLastSweep } from "./cmdbsweep";
import { buildDigest, readSeen, writeSeen } from "./digest";
import { HealthCmdb, LiveHealthCmdb, rootsOfSite } from "./emit-cmdb";
import { runEmit, withEmitLock } from "./emit";
import { historyLines, historyRows, listLines, listRows, rootDocs, rootLines, showDoc, showLines } from "./emit-read";
import { HealthEvent, Journal, systemJournal } from "./events";
import { STATUS_FILE, readStatus, sbomDir } from "./security";
import { SiteSecurity, loadSiteSecurity } from "./site-score";
import { join } from "path";
import { CmdbReport, cmdbReport } from "../../../lib/ts/src/cmdb";
import { captureResult } from "../../../lib/ts/src/exec";
import { changeJob } from "../../../lib/ts/src/job";
import { PerfContext, PerfError, perfExpire, perfList, perfListLines, perfPurge, perfRaise, perfStop } from "./perf";

const WHEN = "An ISO time, or from now: 30m, 2h, 7d.";

export const EMIT_HELP: HelpVerb[] = [
  {
    usage: "emit [--since <time>] [--json]", effect: { noPreview: "writes health events to the journal" },
    options: [
      ["--since <time>", `Tell every transition after this time again, whatever the cursor says (mails too). ${WHEN.replace("from now", "back from now")}`],
      ["--json", "Print the events as a JSON array as well."],
    ],
    details:
      "One event per condition transition since the last run, as a JSON line in the\n" +
      "journal, identifier tappaas-health; the ack and maintenance events beside them. Mails a\n" +
      "critical root cause itself (site-notify.sh): one notice when it becomes one, one RESOLVED\n" +
      "when it stops being one, saying why.\n" +
      "Tracks flapping, and ends acks, maintenance windows and performance investigations when they\n" +
      "expire. Runs after every\n" +
      "assess (health-assess.timer). The cursor is config/.health-emit-cursor.",
  },
  {
    usage: "ack <ci> [--type <t>] --note <n> [--until <time>] [--sticky]", effect: { noPreview: "acknowledges conditions in the CMDB" },
    options: [
      ["--type <t>", "This condition only (default: every one that is not ok)."],
      ["--note <n>", "Why (required)."],
      ["--until <time>", `When it ends (default: when the condition recovers). ${WHEN}`],
      ["--sticky", "Keep it through status changes, until the condition is ok; without this the next status change ends it."],
    ],
    details: "The condition keeps its status and stops counting for validate, mails and the Overview. On a\nroot cause its impact conditions are silenced with it, while the root's ack holds. Written to the\nobject's acknowledgements; the conditions show it from the next assess.",
  },
  {
    usage: "unack <ci> [--type <t>]", effect: { noPreview: "ends acknowledgements in the CMDB" },
    options: [["--type <t>", "This condition only (default: all of the object's)."]],
  },
  {
    usage: "maintenance <ci> --until <time> --note <n>", effect: { noPreview: "opens a maintenance window (a file the alert receiver reads too)" },
    options: [
      ["--until <time>", `When the window ends (required). ${WHEN}`],
      ["--note <n>", "Why (required)."],
    ],
    details: "From the next assess, transitions on the object and on what runs on it are recorded and told,\nnever mailed or counted. The window is a file in /var/lib/tappaas/maintenance.",
  },
  { usage: "maintenance end <ci>", effect: { noPreview: "ends a maintenance window" }, details: "The work is done: the window closes early." },
  { usage: "maintenance cancel <ci>", effect: { noPreview: "cancels a maintenance window" }, details: "The work did not happen: the window is withdrawn." },
  {
    usage: "perf <ci> --level basic|service|trace [--resolution fine] --until <time> [--note <n>]",
    effect: { noPreview: "raises the CI's performance level until the given time and records it in the CMDB" },
    options: [
      ["--level basic|service|trace", "What to collect for it until then: basic, service or trace (trace only this way)."],
      ["--resolution fine", "Every 15 seconds instead of every minute: four times the samples."],
      ["--until <time>", `When it ends (required). ${WHEN}`],
      ["--note <n>", "Why, for the record."],
    ],
    details:
      "Raises one CI's performance level for a time: an investigation. When it ends the CI falls back to the level its module, environment or site sets. On a CI already raised it replaces the raise (Extend is the same level with a later --until). Recorded as a change on the CI.",
  },
  {
    usage: "perf stop <ci> [--purge]", effect: { noPreview: "ends the CI's performance raise and records it in the CMDB" },
    options: [["--purge", "Also delete the CI's series from the metrics store and its trends."]],
    details: "Ends the CI's investigation now: it falls back to its cascaded level at once. What was collected ages out with the retention.",
  },
  {
    usage: "perf purge <ci>", effect: { noPreview: "deletes the CI's series from the metrics store" },
    details: "Deletes everything the metrics store and its 90-day trends hold of the CI, for numbers that should not be kept. Its level is unchanged: what it collects from now on is stored again.",
  },
  {
    usage: "perf list [--json]", effect: "read",
    options: [["--json", "The investigations as JSON."]],
    details: "The investigations in force and those of the last 90 days: CI, level, who, until when, how each ended.",
  },
  {
    usage: "show <ci> [--json]", effect: "read",
    options: [["--json", "Print the object's conditions, root causes and impacts as JSON."]],
    details: "An object's conditions, since when, its root cause or what it impacts, and its acks. <ci> is an id, a name or <class>/<name>.",
  },
  {
    usage: "list [--type <t>] [--status <s>] [--class <c>] [--root-causes] [--json]", effect: "read",
    options: [
      ["--type <t>", "This condition type."],
      ["--status <s>", "This status (default: everything that is not ok)."],
      ["--class <c>", "This class and its subclasses."],
      ["--root-causes", "Only the root causes' conditions."],
      ["--json", "Print the rows as JSON."],
    ],
  },
  {
    usage: "roots [--all] [--json]", effect: "read",
    options: [["--all", "Also the acknowledged ones and those in maintenance."], ["--json", "Print the root causes as JSON."]],
    details: "The current root causes (the site object's rootCauses): critical first, operational before the other kinds, then most impact; each with what it impacts. A silenced one is left out without --all.",
  },
  {
    usage: "history <ci> [--since <time>] [--json]", effect: "read",
    options: [
      ["--since <time>", `Only what came after. ${WHEN.replace("from now", "back from now")}`],
      ["--json", "Print the transitions as JSON."],
    ],
    details: "An object's condition transitions, from the CMDB's attribute history.",
  },
  {
    usage: "digest [--json] [--mark]", effect: { noPreview: "with --mark, records what the last digest told" },
    options: [
      ["--json", "Print the mail as JSON, with the keys --mark takes."],
      ["--mark", "Read {\"keys\": [...]} on stdin: the digest that went out. The next one compares with these."],
    ],
    details:
      "The daily digest's mail: what is new since the last one, what is still open, what cleared. An\n" +
      "ALERT with something new, else a STATUS. tappaas-alert-receiver asks for it when\n" +
      "HealthDailyDigest fires. Without --mark it changes nothing. The record is config/.health-digest-seen.json.",
  },
];

const VERBS = new Set(["emit", "ack", "unack", "maintenance", "perf", "show", "list", "roots", "history", "digest"]);

export interface EmitContext {
  cmdb: HealthCmdb;
  journal: Journal;
  configDir: string;
  now: Date;
  actor: string;
  sweep?: () => SweepRecord | null;
  security?: (configDir: string) => SiteSecurity | null;
  perf?: PerfContext;
}

// The last scan's risk scores; null before the first scan.
function readSecurity(configDir: string): SiteSecurity | null {
  const s = readStatus(join(sbomDir(configDir), STATUS_FILE));
  return s ? loadSiteSecurity(configDir, s) : null;
}

/** An ISO time, or a span: forward for --until, back for --since. */
export function parseWhen(v: string, now: Date, sign: 1 | -1): string {
  const m = /^(\d+)([mhd])$/.exec(v);
  if (m) return new Date(now.getTime() + sign * Number(m[1]) * { m: 60000, h: 3600000, d: 86400000 }[m[2] as "m" | "h" | "d"]).toISOString();
  const t = Date.parse(v);
  if (Number.isNaN(t)) die(`'${v}' is not a time: an ISO time, or 30m, 2h, 7d`);
  return new Date(t).toISOString();
}

function args(rest: string[]): { val: (f: string) => string | undefined; has: (f: string) => boolean; positional: string[] } {
  const takes = new Set(["--type", "--note", "--until", "--since", "--status", "--class", "--level", "--resolution"]);
  const positional: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    if (takes.has(rest[i])) i++;
    else if (!rest[i].startsWith("--")) positional.push(rest[i]);
  }
  return {
    val: (f) => {
      const i = rest.indexOf(f);
      if (i < 0) return undefined;
      const v = rest[i + 1];
      if (v === undefined) die(`${f} needs a value`);
      return v;
    },
    has: (f) => rest.includes(f),
    positional,
  };
}

function print(json: boolean, doc: unknown, lines: () => string[]): number {
  if (json) info(JSON.stringify(doc, null, 2));
  else for (const l of lines()) info(l);
  return 0;
}

const told = (events: HealthEvent[]): number => {
  for (const e of events) info(`${e.event}${"phase" in e && e.phase ? ` ${e.phase}` : ""}: ${"class" in e ? `${e.class}/${e.name}` : ""}${"type" in e && e.type ? ` ${e.type}` : ""}`);
  return 0;
};

function cmdEmit(ctx: EmitContext, rest: string[]): number {
  if ((process.env.TAPPAAS_CMDB ?? "").toLowerCase() === "off") return 0;
  const a = args(rest);
  const s = a.val("--since");
  let events: HealthEvent[] = [];
  try {
    const ran = withEmitLock(ctx.configDir, () => {
      events = runEmit(ctx.cmdb, ctx.journal, ctx.configDir, { now: ctx.now, ...(s ? { since: parseWhen(s, ctx.now, -1) } : {}) });
    });
    if (!ran) {
      info("emit: another run holds the lock");
      return 0;
    }
  } catch (e) {
    // The CMDB is a record, never a gate: the next run tells it.
    if (!(e instanceof CmdbUnavailable)) throw e;
    warn(`emit: nothing told: ${e.message}`);
    return 0;
  }
  if (a.has("--json")) info(JSON.stringify(events, null, 2));
  else info(`emit: ${events.length} event(s)`);
  // Investigations past their time end here too, as acks do (ADR-046 D3).
  if (ctx.perf) {
    try {
      perfExpire(ctx.perf);
    } catch (e) {
      warn(`emit: an expired investigation was not ended: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  return 0;
}

function cmdPerf(ctx: EmitContext, rest: string[]): number {
  const p = ctx.perf ?? livePerfContext(ctx);
  const a = args(rest);
  const [first, second] = a.positional;
  try {
    if (first === "list" && !second) {
      const d = perfList(ctx.configDir, ctx.now, ctx.cmdb.investigations ? (since) => ctx.cmdb.investigations!(since) : undefined);
      return print(a.has("--json"), d, () => perfListLines(d));
    }
    if (first === "stop" && second && a.positional.length === 2) {
      perfStop(p, second, a.has("--purge"));
      return 0;
    }
    if (first === "purge" && second && a.positional.length === 2) {
      const o = p.resolve(second);
      perfPurge(p, o.id, o.name);
      return 0;
    }
    if (!first || a.positional.length !== 1) die("perf: expected <ci> --level <l> --until <time>, stop <ci>, purge <ci> or list");
    const until = a.val("--until");
    perfRaise(p, { ref: first, level: a.val("--level") ?? "", resolution: a.val("--resolution"), until: until ? parseWhen(until, ctx.now, 1) : undefined, note: a.val("--note") });
    return 0;
  } catch (e) {
    if (e instanceof PerfError) die(e.message);
    throw e;
  }
}

const METRICS_TARGET = (): string => process.env.HEALTH_METRICS_TARGET_BIN ?? "tappaas-metrics-target.sh";
const outLines = (r: { stdout: string; stderr: string }): string[] =>
  (r.stdout + "\n" + r.stderr).replace(/\x1b\[[0-9;]*m/g, "").split("\n").map((l) => l.trim()).filter(Boolean);

/** The perf verbs against the live CMDB and the mothership's metrics script. */
export function livePerfContext(ctx: EmitContext): PerfContext {
  return {
    configDir: ctx.configDir,
    now: ctx.now,
    actor: ctx.actor,
    resolve: (ref) => ctx.cmdb.resolve(ref),
    record: (ci, investigation, verb) => {
      const report: CmdbReport = {
        source: "health-manager",
        kind: "change",
        assessment: true,
        verb,
        ...changeJob(),
        objects: [{ id: ci.id, class: ci.class, name: ci.name, attributes: { investigation } }],
      };
      const r = cmdbReport(report);
      const change = r.delivered ? (r.result as { change?: unknown } | undefined)?.change : null;
      if (!r.delivered && !r.off) warn(`the CMDB did not take the change now; it is spooled and recorded when the CMDB answers`);
      return typeof change === "number" ? change : null;
    },
    cascade: (module) => {
      const r = captureResult(METRICS_TARGET(), ["guest", module, "status"]);
      if (!r.ran || r.rc !== 0) return null;
      try {
        const d = JSON.parse(r.stdout) as { from?: string; source?: string };
        return d.from ? { from: d.from, source: d.source ?? "" } : null;
      } catch {
        return null;
      }
    },
    apply: (module) => {
      const r = captureResult(METRICS_TARGET(), ["guest", module, "apply"]);
      return { ok: r.ran && r.rc === 0, lines: r.ran ? outLines(r) : [`${METRICS_TARGET()} not found`] };
    },
    traces: () => {
      const r = captureResult(METRICS_TARGET(), ["traces", "apply"]);
      return { ok: r.ran && r.rc === 0, lines: r.ran ? outLines(r) : [`${METRICS_TARGET()} not found`] };
    },
    purge: (id) => {
      const r = captureResult(METRICS_TARGET(), ["purge", id]);
      return { ok: r.ran && r.rc === 0, lines: r.ran ? outLines(r) : [`${METRICS_TARGET()} not found`] };
    },
    say: (l) => info(l),
    warn: (l) => warn(l),
  };
}

function cmdDigest(ctx: EmitContext, rest: string[]): number {
  if (rest.includes("--mark")) {
    const { keys } = JSON.parse(readFileSync(0, "utf8")) as { keys: string[] };
    if (!Array.isArray(keys)) die("digest --mark: expected {\"keys\": [...]} on stdin");
    writeSeen(ctx.configDir, { at: ctx.now.toISOString(), keys });
    return 0;
  }
  const objects = ctx.cmdb.objects();
  const rows = listRows(objects, rootsOfSite(objects), {});
  const doc = buildDigest(rows, (ctx.sweep ?? readLastSweep)(), readSeen(ctx.configDir), (ctx.security ?? readSecurity)(ctx.configDir));
  info(rest.includes("--json") ? JSON.stringify(doc, null, 2) : `Subject: ${doc.subject}\n\n${doc.body}`);
  return 0;
}

function cmdMaintenance(v: VerbContext, rest: string[]): number {
  const a = args(rest);
  const [first, second] = a.positional;
  if ((first === "end" || first === "cancel") && second) return told(maintenanceStop(v, second, first));
  if (!first || a.positional.length !== 1) die("maintenance: expected <ci> --until <time> --note <n>, or end|cancel <ci>");
  const until = a.val("--until");
  const note = a.val("--note");
  if (!until || !note) die("maintenance: --until and --note are required");
  return told(maintenanceStart(v, first, parseWhen(until, v.now, 1), note));
}

/** The verb's exit code, or undefined when it is not one of these. */
export function runEmitVerb(cmd: string, rest: string[], ctx: EmitContext): number | undefined {
  if (!VERBS.has(cmd)) return undefined;
  const a = args(rest);
  const json = a.has("--json");
  const one = (): string => {
    if (a.positional.length !== 1) die(`${cmd}: expected <ci>`);
    return a.positional[0];
  };
  const v: VerbContext = { cmdb: ctx.cmdb, journal: ctx.journal, now: ctx.now, actor: ctx.actor };
  switch (cmd) {
    case "emit":
      return cmdEmit(ctx, rest);
    case "ack": {
      const note = a.val("--note");
      if (!note) die("ack: --note is required");
      const until = a.val("--until");
      return told(ack(v, { ref: one(), type: a.val("--type"), note, until: until ? parseWhen(until, ctx.now, 1) : undefined, sticky: a.has("--sticky") }));
    }
    case "unack":
      return told(unack(v, one(), a.val("--type")));
    case "maintenance":
      return cmdMaintenance(v, rest);
    case "perf":
      return cmdPerf(ctx, rest);
    case "show": {
      const objects = ctx.cmdb.objects();
      const o = ctx.cmdb.resolve(one());
      const d = showDoc(o, objects, rootsOfSite(objects));
      return print(json, d, () => showLines(d, objects, ctx.now));
    }
    case "list": {
      const cls = a.val("--class");
      const objects = ctx.cmdb.objects();
      const within = cls ? new Set(ctx.cmdb.objectsOfClass(cls).map((o) => o.id)) : null;
      const rows = listRows(within ? objects.filter((o) => within.has(o.id)) : objects, rootsOfSite(objects), { type: a.val("--type"), status: a.val("--status"), rootCauses: a.has("--root-causes") });
      return print(json, rows, () => listLines(rows, ctx.now));
    }
    case "roots": {
      const objects = ctx.cmdb.objects();
      const d = rootDocs(objects, rootsOfSite(objects), ctx.now, a.has("--all"));
      return print(json, d, () => rootLines(d));
    }
    case "digest":
      return cmdDigest(ctx, rest);
    default: {
      const s = a.val("--since");
      const rows = historyRows(ctx.cmdb.periods(ctx.cmdb.resolve(one()).id), s ? parseWhen(s, ctx.now, -1) : undefined);
      return print(json, rows, () => historyLines(rows));
    }
  }
}

export function liveEmitContext(configDir: string): EmitContext {
  const ctx: EmitContext = { cmdb: new LiveHealthCmdb(), journal: systemJournal, configDir, now: new Date(), actor: currentJob().actor };
  ctx.perf = livePerfContext(ctx);
  return ctx;
}
