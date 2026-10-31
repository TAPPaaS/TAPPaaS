// emit-verbs.ts — the emitting half's verbs (ADR-041 D2, D4): their help and
// their dispatch, in one place so main.ts carries one line of each.

import { HelpVerb } from "../../../lib/ts/src/help";
import { die, info, warn } from "../../../lib/ts/src/cli";
import { CmdbUnavailable } from "../../../lib/ts/src/cmdb";
import { currentJob } from "../../../lib/ts/src/job";
import { VerbContext, ack, maintenanceStart, maintenanceStop, unack } from "./ack";
import { HealthCmdb, LiveHealthCmdb, rootsOfSite } from "./emit-cmdb";
import { runEmit, withEmitLock } from "./emit";
import { historyLines, historyRows, listLines, listRows, rootDocs, rootLines, showDoc, showLines } from "./emit-read";
import { HealthEvent, Journal, systemJournal } from "./events";

const WHEN = "An ISO time, or from now: 30m, 2h, 7d.";

export const EMIT_HELP: HelpVerb[] = [
  {
    usage: "emit [--since <time>] [--json]", effect: { noPreview: "writes health events to the journal" },
    options: [
      ["--since <time>", `Tell every transition after this time again, whatever the cursor says (mails too). ${WHEN.replace("from now", "back from now")}`],
      ["--json", "Print the events as a JSON array as well."],
    ],
    details:
      "One event per condition transition since the last run (ADR-041 D4), as a JSON line in the\n" +
      "journal, identifier tappaas-health; the ack, maintenance and rootcause events beside them.\n" +
      "Tracks flapping, and ends acks and maintenance windows when they expire. Runs after every\n" +
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
    details: "The condition keeps its status and stops counting for validate, mails and the Overview. On a\nroot cause its impact conditions are silenced with it, while the root's ack holds.",
  },
  {
    usage: "unack <ci> [--type <t>]", effect: { noPreview: "ends acknowledgements in the CMDB" },
    options: [["--type <t>", "This condition only (default: all of the object's)."]],
  },
  {
    usage: "maintenance <ci> --until <time> --note <n>", effect: { noPreview: "opens a maintenance window in the CMDB" },
    options: [
      ["--until <time>", `When the window ends (required). ${WHEN}`],
      ["--note <n>", "Why (required)."],
    ],
    details: "Transitions on the object are recorded and told, never mailed or counted.",
  },
  { usage: "maintenance end <ci>", effect: { noPreview: "ends a maintenance window" }, details: "The work is done: the window closes early." },
  { usage: "maintenance cancel <ci>", effect: { noPreview: "cancels a maintenance window" }, details: "The work did not happen: the window is withdrawn." },
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
    usage: "roots [--json]", effect: "read",
    options: [["--json", "Print the root causes as JSON."]],
    details: "The current root causes (the site object's rootCauses), most impact first, each with what it impacts.",
  },
  {
    usage: "history <ci> [--since <time>] [--json]", effect: "read",
    options: [
      ["--since <time>", `Only what came after. ${WHEN.replace("from now", "back from now")}`],
      ["--json", "Print the transitions as JSON."],
    ],
    details: "An object's condition transitions, from the CMDB's attribute history.",
  },
];

const VERBS = new Set(["emit", "ack", "unack", "maintenance", "show", "list", "roots", "history"]);

export interface EmitContext {
  cmdb: HealthCmdb;
  journal: Journal;
  configDir: string;
  now: Date;
  actor: string;
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
  const takes = new Set(["--type", "--note", "--until", "--since", "--status", "--class"]);
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
      const d = rootDocs(objects, rootsOfSite(objects));
      return print(json, d, () => rootLines(d));
    }
    default: {
      const s = a.val("--since");
      const rows = historyRows(ctx.cmdb.periods(ctx.cmdb.resolve(one()).id), s ? parseWhen(s, ctx.now, -1) : undefined);
      return print(json, rows, () => historyLines(rows));
    }
  }
}

export function liveEmitContext(configDir: string): EmitContext {
  return { cmdb: new LiveHealthCmdb(), journal: systemJournal, configDir, now: new Date(), actor: currentJob().actor };
}
