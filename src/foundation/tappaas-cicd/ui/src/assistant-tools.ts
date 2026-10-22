// assistant-tools.ts — what the assistant may do (ADR-034 D7): read the site
// through the console's own reads (the same caches a page is drawn from), read
// a host's logs in Loki, read a manager's manifest and README, propose a job,
// and open a page or a wizard of the console for the operator. Nothing else.
// There is no apply tool and no write: a tool name outside TOOLS is refused,
// propose_job creates no job — it validates the argv against the manifests and
// returns a card for the operator, whose click runs it through the job model
// (jobs.ts) under the operator's own role — and open_console only moves the
// operator's console to a form (web/src/consoletargets.ts), filled in.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { attention, findingsFor, moduleSummaries } from "./badges";
import { JobSummary, shellQuote } from "./jobs";
import { ManifestVerb, Manifests, applyArgv, findVerb, previewArgv, validateArgv } from "./manifest";
import { MODULE_NAME, Reads } from "./reads";
import { HealthDoc } from "./model";
import { ToolDef } from "./litellm";
import { Opened } from "./conversations";
import { resolveTarget, wizardForVerb } from "../web/src/consoletargets";

export interface LokiConfig {
  url: string; // e.g. http://logging.mgmt.internal:3100
  user: string;
  passwordFile: string; // ~/.loki-admin-password (lib/log-shipping.sh)
}

// Loki through the logging module's API (:3100, the admin credential the
// mothership holds, lib/log-shipping.sh), when logging is installed here.
export function lokiConfig(configDir: string, home: string, env: Record<string, string | undefined> = process.env): LokiConfig | null {
  const passwordFile = env.CONSOLE_LOKI_PASSWORD_FILE ?? join(home, ".loki-admin-password");
  if (!existsSync(join(configDir, "logging.json")) || !existsSync(passwordFile)) return null;
  return { url: env.CONSOLE_LOKI_URL ?? "http://logging.mgmt.internal:3100", user: "tappaas", passwordFile };
}

export interface ToolContext {
  reads: Reads;
  manifests: () => Manifests | null;
  jobs: () => JobSummary[]; // Activity's list: read only
  loki: LokiConfig | null; // null: the logging module is not installed or its credential is absent
  repoRoot: string; // the release checkout, for the managers' READMEs
  fetch?: typeof fetch;
  now?: () => number;
  shell?: boolean; // the caller is tappaas ask: open_console gives an address, opens nothing
}

export interface ProposedJob {
  argv: string[];
  rationale: string;
  verb: string;
  read: boolean;
  destructive: boolean;
  preview: string;
  previewArgv: string[] | null; // what its preview runs (null: no dry run, or a read)
  applyArgv: string[]; // what its Run runs
}

export interface ToolOutcome {
  ok: boolean;
  content: string; // what the model is told
  summary: string; // the line the drawer shows ("read: health guest-memory")
  proposal?: ProposedJob;
  navigate?: Opened; // where open_console moved the operator's console
  refused?: boolean;
}

// What a result may weigh: the model's context is small (hrossen's model: 32k tokens).
export const RESULT_CHARS = 7000;

const obj = (properties: Record<string, unknown>, required: string[] = []): Record<string, unknown> => ({ type: "object", properties, required, additionalProperties: false });
const str = (description: string): Record<string, unknown> => ({ type: "string", description });

// Every tool the assistant has. Nothing writes; propose_job only proposes.
// `line` is how the system prompt lists it: its exact name and arguments.
export const TOOLS: Record<string, { line: string; description: string; parameters: Record<string, unknown> }> = {
  modules_list: {
    line: "modules_list(): every deployed module, its node, state and badges",
    description: "Every deployed module: node, vmid, zone, environment, running state, badges (health, backup, cve) and how many health findings name it.",
    parameters: obj({}),
  },
  module_show: {
    line: "module_show(module): one module: its findings, config, resolved fields, and the fields modify --set may change",
    description: "One module: its summary, every health finding that names it, its config as module-manager shows it, its resolved fields, and the fields `modify --set` may change with their ADR-020 change class.",
    parameters: obj({ module: str("the module's name") }, ["module"]),
  },
  module_drift: {
    line: "module_drift(module): where the running guest differs from its config",
    description: "One module's drift: where the running guest and its services differ from the config (module-manager drift; can take a minute).",
    parameters: obj({ module: str("the module's name") }, ["module"]),
  },
  zones: { line: "zones(): the network zones", description: "The network zones: VLAN, network, type, state, access-to and pinholes.", parameters: obj({}) },
  environments: { line: "environments(): the environments, their zones and domains", description: "The environments: their zones and domains.", parameters: obj({}) },
  topology: {
    line: "topology(object?): the site as cabled; a node or switch in full",
    description: "The site as cabled (network-manager topology): nodes with their guests and uplinks, switches, LAGs, access points, the outside. Give `object` (a node or switch name) for that object in full.",
    parameters: obj({ object: str("a node or switch name (optional)") }),
  },
  health: {
    line: "health(gate?, subject?): the health gates and their findings",
    description: "The health gates (health-manager validate): each gate's status and its findings. Give `gate` for one gate in full (e.g. guest-memory, memory-commitment, pulse, backup-status), or `subject` for every finding naming a module or node.",
    parameters: obj({ gate: str("a gate name (optional)"), subject: str("a module or node name (optional)") }),
  },
  backup: {
    line: "backup(module?): backup policies and restore points",
    description: "Backups: every module's policy and whether it is in the PBS job; with `module`, its policy and restore points (backup-manager show and coverage).",
    parameters: obj({ module: str("a module name (optional)") }),
  },
  pulse: { line: "pulse(): the off-site buddies and the satellite", description: "The pulse: the off-site buddies and the satellite, whether each answers (the pulse gate and backup-manager peers).", parameters: obj({}) },
  activity: {
    line: "activity(module?): the console's jobs and the sweep's runs",
    description: "What was done to the site: the console's jobs (who, the command, the result) and the sweep's runs with their errors; with `module`, only what names it.",
    parameters: obj({ module: str("a module name (optional)") }),
  },
  logs: {
    line: "logs(host, since?, until?, contains?, limit?): a host's log lines from Loki",
    description: "A host's log lines from Loki (the logging module): newest first. `host` is a guest or node name (immich, tappaas1). `since` and `until` are relative (30m, 2h, 7d) or ISO times; `contains` filters the lines.",
    parameters: obj({ host: str("the host label"), since: str("default 1h"), until: str("default now"), contains: str("a text the line contains (optional)"), limit: { type: "integer", description: "at most 200, default 50" } }, ["host"]),
  },
  help: {
    line: "help(manager): a manager's verbs, their options and its README",
    description: "A manager's verbs as its --help declares them (each verb's usage, options, whether it changes the site and how it previews) and its README.",
    parameters: obj({ manager: str("e.g. module-manager, network-manager, switch-manager") }, ["manager"]),
  },
  propose_job: {
    line: "propose_job(argv, rationale): a command as a card the operator previews and runs; argv is an array of words, the manager first",
    description: "Propose a change as a job card the operator previews and runs. You never run it: only the operator's Run does. `argv` is the exact command, the manager first, e.g. [\"module-manager\",\"modify\",\"immich\",\"--set\",\"memory=10240\"], without --apply, --dry-run or --json (the job model adds them). It must be a verb a manifest declares.",
    parameters: obj({ argv: { type: "array", items: { type: "string" }, description: "the command line as an array of words" }, rationale: str("one sentence: why, and its consequence") }, ["argv", "rationale"]),
  },
  open_console: {
    line: "open_console(target, values?): open a page, or a wizard or Modify form with values filled in, in the operator's console; it changes nothing",
    description:
      "Move the operator's console to a page or open a wizard there, its form filled in with `values`; the operator previews and applies it. Changes nothing. `target` is a page (\"/modules/immich\", \"/site/physical\", \"/setup/day2\") or a wizard: add-node, add-environment, add-stack, enrol-device, add-wifi <zone>, add-buddy, add-satellite, add-user, add-rack, mount-device, modify-module <module>, modify-zone <zone>; \"rack-view\" is the physical view's racks. For mount-device, `values` name the device as the physical view does, e.g. {\"device\": \"tappaas2\", \"rack\": \"rack1\", \"u\": \"12\"}. For modify-module, `values` are the module's fields by name (module_show lists them), e.g. {\"memory\": \"10240\"}.",
    parameters: obj({ target: str("a page path or a wizard, e.g. \"add-node\" or \"modify-module immich\""), values: { type: "object", description: "the form's values by name (optional)", additionalProperties: true } }, ["target"]),
  },
};

// The tools this console offers: logs only with Loki.
export function toolNames(ctx: ToolContext): string[] {
  return Object.keys(TOOLS).filter((name) => name !== "logs" || ctx.loki !== null);
}

export function toolDefs(ctx: ToolContext): ToolDef[] {
  return toolNames(ctx).map((name) => ({ type: "function", function: { name, description: TOOLS[name].description, parameters: TOOLS[name].parameters } }));
}

// The system prompt's list: one line per tool, by its exact name.
export function toolLines(ctx: ToolContext): string {
  return toolNames(ctx).map((name) => `- ${TOOLS[name].line}`).join("\n");
}

export function cap(text: string, max = RESULT_CHARS): string {
  return text.length <= max ? text : `${text.slice(0, max)}\n… (cut at ${max} characters of ${text.length})`;
}

const j = (v: unknown): string => cap(JSON.stringify(v));

function arg(args: Record<string, unknown>, k: string): string | null {
  const v = args[k];
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

// The README beside a manager or controller, in the release checkout.
export function readmeOf(repoRoot: string, bin: string): string | null {
  const base = join(repoRoot, "src", "foundation", "tappaas-cicd");
  for (const rel of [join("manager", bin), join("controller", bin)]) {
    const f = join(base, rel, "README.md");
    if (existsSync(f)) {
      try {
        return readFileSync(f, "utf8");
      } catch {
        return null;
      }
    }
  }
  return null;
}

// A relative or absolute time: 30m, 2h, 7d, or an ISO date.
export function timeOf(v: string | null, now: number, dflt: number): number | null {
  if (!v) return dflt;
  const m = /^(\d+)\s*([smhd])$/.exec(v);
  if (m) return now - Number(m[1]) * { s: 1000, m: 60_000, h: 3600_000, d: 86400_000 }[m[2] as "s" | "m" | "h" | "d"];
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

export function logql(host: string, contains: string | null): string {
  const sel = `{host="${host}"}`;
  return contains ? `${sel} |= "${contains.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"` : sel;
}

function compactTopology(t: Record<string, unknown>): unknown {
  const nodes = (t.nodes as { name: string; roles?: unknown; guests?: { module: string; vmid: number | null; state?: string; zone?: string }[]; uplinks?: { name: string; mode?: string; legs?: { nic: string; up?: boolean; speed?: string; peer?: { switch?: string; port?: string } | null }[] }[] }[] | undefined) ?? [];
  return {
    site: t.site,
    nodes: nodes.map((n) => ({
      name: n.name,
      roles: n.roles,
      guests: (n.guests ?? []).map((g) => `${g.module}(${g.vmid ?? "-"}, ${g.state ?? "?"}, ${g.zone ?? "?"})`),
      uplinks: (n.uplinks ?? []).map((u) => `${u.name} ${u.mode ?? ""}: ${(u.legs ?? []).map((l) => `${l.nic} ${l.speed ?? ""} ${l.up ? "up" : "down"}${l.peer?.switch ? ` → ${l.peer.switch}:${l.peer.port}` : ""}`).join(", ")}`),
    })),
    switches: ((t.switches as { name: string; ports?: unknown[]; lags?: { name: string }[] }[] | undefined) ?? []).map((s) => ({ name: s.name, ports: s.ports?.length ?? 0, lags: (s.lags ?? []).map((l) => l.name) })),
    accessPoints: ((t.accessPoints as { name: string }[] | undefined) ?? []).map((a) => a.name),
    outside: t.outside,
    findings: (t.findings as unknown[] | undefined)?.length ?? 0,
  };
}

function healthView(h: HealthDoc, gate: string | null, subject: string | null): unknown {
  if (gate) {
    const g = h.gates.find((x) => x.name === gate);
    return g ?? { error: `no gate '${gate}' (gates: ${h.gates.map((x) => x.name).join(", ")})` };
  }
  if (subject) {
    return h.gates.flatMap((g) => g.findings.filter((f) => f.subject?.name === subject).map((f) => ({ gate: g.name, status: f.status, text: f.text })));
  }
  return {
    generated: h.generated,
    status: h.status,
    gates: h.gates.map((g) => ({ name: g.name, status: g.status, detail: g.detail, findings: g.findings.length })),
    attention: attention(h).map((a) => `${a.level} ${a.gate}: ${a.text}`),
  };
}

// The manifest of one manager, as the model needs it.
function manifestView(ms: Manifests, bin: string): unknown {
  const m = ms.byBin.get(bin);
  if (!m) return null;
  return {
    name: m.name,
    tagline: m.tagline,
    verbs: m.verbs.map((v) => ({
      usage: v.usage,
      note: v.note ?? undefined,
      changes: v.effect === "write",
      changesWith: v.writeWhen.length ? v.writeWhen.map((w) => `${w.flag}: ${w.touches}`) : undefined,
      preview: v.preview.kind === "none" ? `no dry run: ${v.preview.touches}` : v.preview.kind,
      destructive: v.destructive || v.destructiveWhen.length > 0 ? (v.destructive ? true : v.destructiveWhen) : undefined,
      options: v.options.map((o) => `${o.flag}${o.arg ? ` ${o.arg}` : ""}${o.description ? ` — ${o.description}` : ""}`),
    })),
  };
}

// The keys of an invented tool's arguments that are a verb's positionals.
const POSITIONAL_KEYS = ["module", "node", "name", "zone", "environment", "env", "object", "target", "host", "stack", "peer", "kind", "ap"];

// What a model probably meant by a tool named after a verb (site_manager_add_node,
// module_manager_modify): the manager, the verb's words in either order, its
// positionals from the arguments, the rest as options (a field as --set f=v).
export function guessArgv(ms: Manifests, name: string, rawArgs: string): string[] | null {
  const tokens = name.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t !== "");
  let best: { bin: string; rest: string[] } | null = null;
  for (const bin of ms.byBin.keys()) {
    const bt = bin.split("-");
    const rest = bt.every((w, i) => tokens[i] === w) ? tokens.slice(bt.length) : ["manager", "controller"].includes(bt[1]) && tokens[0] === bt[0] && tokens[1] !== bt[1] ? tokens.slice(1) : null;
    if (rest && (!best || rest.length < best.rest.length)) best = { bin, rest };
  }
  if (!best) return null;
  const m = ms.byBin.get(best.bin)!;
  const orders = best.rest.length === 2 ? [best.rest, [best.rest[1], best.rest[0]]] : [best.rest];
  let hit: { verb: ManifestVerb; used: number; words: string[] } | null = null;
  for (const words of orders) {
    const f = findVerb(m, words);
    if (f && f.used === words.length && (!hit || f.used > hit.used)) hit = { ...f, words };
  }
  if (!hit) return null;
  let args: Record<string, unknown> = {};
  try {
    const v = JSON.parse(rawArgs || "{}") as unknown;
    if (v && typeof v === "object" && !Array.isArray(v)) args = v as Record<string, unknown>;
  } catch {
    /* no arguments to use */
  }
  const flags = new Set(hit.verb.options.map((o) => o.flag));
  const pos: string[] = [];
  const opts: string[] = [];
  for (const [k, v] of Object.entries(args)) {
    const text = Array.isArray(v) ? v.join(",") : typeof v === "string" || typeof v === "number" ? String(v) : null;
    if (POSITIONAL_KEYS.includes(k) && text !== null) pos.push(text);
    else if (flags.has(`--${k}`)) opts.push(...(v === true ? [`--${k}`] : text !== null ? [`--${k}`, text] : []));
    else if (flags.has("--set") && text !== null) opts.push("--set", `${k}=${text}`);
  }
  const wanted = hit.verb.positionals.filter((p) => !p.optional);
  while (pos.length < wanted.length) pos.push(`<${wanted[pos.length].name}>`);
  return [best.bin, ...hit.words, ...pos, ...opts];
}

// The console's form for a guessed command, as open_console's arguments:
// the wizard that runs its verb, its object, and its --set fields as values.
export function consoleFormFor(ms: Manifests, argv: string[]): { target: string; values?: Record<string, string> } | null {
  const m = ms.byBin.get(argv[0]);
  const found = m ? findVerb(m, argv.slice(1)) : null;
  if (!found) return null;
  const w = wizardForVerb(argv[0], argv.slice(1, 1 + found.used).join(" "));
  if (!w) return null;
  const rest = argv.slice(1 + found.used);
  const object = rest[0] !== undefined && !rest[0].startsWith("-") && !/^<.*>$/.test(rest[0]) ? rest[0] : null;
  if (w.arg && !object) return null;
  const values: Record<string, string> = {};
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--set" && rest[i + 1]?.includes("=")) {
      const [k, ...v] = rest[++i].split("=");
      values[k] = v.join("=");
    }
  }
  if (!w.arg && object && w.keys?.includes("name")) values.name = object;
  return { target: w.arg ? `${w.name} ${object}` : w.name, ...(Object.keys(values).length ? { values } : {}) };
}

// The refusal of a tool that does not exist: the tools that do, and the call
// the model probably meant.
export function refusal(ctx: ToolContext, name: string, rawArgs: string): string {
  const ms = ctx.manifests();
  const argv = ms ? guessArgv(ms, name, rawArgs) : null;
  const lines = [
    `Refused: there is no tool '${name}'. Your only tools are ${toolNames(ctx).join(", ")}; there is no tool per manager or per verb, and you cannot run, apply or change anything.`,
    "A manager's verb is only ever proposed: call propose_job with the command as an array, the manager first, and the operator's Run button runs it. When the console has a wizard or form for it, call open_console instead. To look a verb up first, call help with the manager's name.",
  ];
  if (argv) {
    const form = ms ? consoleFormFor(ms, argv) : null;
    if (form) lines.push(`The console has a form for this: you probably meant open_console(${JSON.stringify(form)}), which opens it filled in for the operator; or else propose_job({"argv": ${JSON.stringify(argv)}, "rationale": "…"}).`);
    else lines.push(`You probably meant: propose_job({"argv": ${JSON.stringify(argv)}, "rationale": "<why, and its consequence>"})${argv.some((a) => /^<.*>$/.test(a)) ? " with the <…> filled in" : ""}; check its options with help({"manager": "${argv[0]}"}) if unsure.`);
  }
  return lines.join("\n");
}

// Run one tool call. Unknown names are refused: the assistant has no other tool.
export async function runTool(ctx: ToolContext, name: string, rawArgs: string): Promise<ToolOutcome> {
  if (!toolNames(ctx).includes(name)) {
    return { ok: false, refused: true, summary: `refused: ${name} (no such tool)`, content: refusal(ctx, name, rawArgs) };
  }
  let args: Record<string, unknown>;
  try {
    const v = rawArgs.trim() ? (JSON.parse(rawArgs) as unknown) : {};
    if (v === null || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object");
    args = v as Record<string, unknown>;
  } catch {
    return { ok: false, summary: `${name}: arguments not JSON`, content: `The arguments of ${name} are not a JSON object: ${rawArgs.slice(0, 200)}` };
  }
  try {
    return await call(ctx, name, args);
  } catch (e) {
    return { ok: false, summary: `${name}: ${(e as Error).message.slice(0, 120)}`, content: `${name} failed: ${(e as Error).message}` };
  }
}

async function call(ctx: ToolContext, name: string, args: Record<string, unknown>): Promise<ToolOutcome> {
  const r = ctx.reads;
  const ok = (summary: string, v: unknown): ToolOutcome => ({ ok: true, summary, content: typeof v === "string" ? cap(v) : j(v) });
  const failed = (summary: string, why: string): ToolOutcome => ({ ok: false, summary, content: why });
  const moduleArg = (): string => {
    const m = arg(args, "module");
    if (!m || !MODULE_NAME.test(m)) throw new Error("`module` must be a module's name");
    return m;
  };

  switch (name) {
    case "modules_list": {
      const [m, h, b] = await Promise.all([r.modules.get(), r.health.get(), r.backup.get()]);
      if (!m.value) return failed("modules", `the module list could not be read: ${m.error ?? "not yet"}`);
      const list = moduleSummaries(m.value.modules, h.value, b.value).map((x) => ({
        name: x.name, kind: x.kind, node: x.node, vmid: x.vmid, zone: x.zone0, environment: x.environment, stack: x.stack, running: x.running,
        health: x.badges.health, backup: x.badges.backup, cve: x.badges.cve, findings: x.findings.length,
      }));
      return ok("modules list", list);
    }
    case "module_show": {
      const name_ = moduleArg();
      const [m, h] = await Promise.all([r.modules.get(), r.health.get()]);
      const row = m.value?.modules.find((x) => x.name === name_);
      if (!row) return failed(`module ${name_}`, `no deployed module '${name_}' (modules: ${(m.value?.modules ?? []).map((x) => x.name).join(", ")})`);
      const [show, resolve, fields] = await Promise.all([r.moduleShow.of(name_).get(), r.moduleResolve.of(name_).get(), r.moduleFields.of(name_).get()]);
      const shown = ok(`module show ${name_}`, {
        module: row,
        findings: findingsFor(h.value, name_),
        show: show.value ?? { error: show.error },
        resolved: resolve.value ?? { error: resolve.error },
        modifiable: fields.value ?? { error: fields.error },
      });
      // The next step a small model needs spelled out: the form for a change.
      return { ...shown, content: `${shown.content}\nTo change one of these fields, call open_console({"target": "modify-module ${name_}", "values": {"<field>": "<value>"}}) now; it changes nothing until the operator applies it.` };
    }
    case "module_drift": {
      const name_ = moduleArg();
      const d = await r.moduleDrift.of(name_).get();
      return d.value ? ok(`module drift ${name_}`, d.value) : failed(`drift ${name_}`, `drift of ${name_} could not be read: ${d.error}`);
    }
    case "zones": {
      const z = await r.zones.get();
      return z.value ? ok("zones", z.value) : failed("zones", `zones could not be read: ${z.error}`);
    }
    case "environments": {
      const e = await r.environments.get();
      return e.value ? ok("environments", e.value) : failed("environments", `environments could not be read: ${e.error}`);
    }
    case "topology": {
      const t = await r.topology.get();
      if (!t.value) return failed("topology", `the topology could not be read: ${t.error}`);
      const o = arg(args, "object");
      if (o) {
        const doc = t.value as unknown as { nodes?: { name: string }[]; switches?: { name: string }[] };
        const hit = [...(doc.nodes ?? []), ...(doc.switches ?? [])].find((x) => x.name === o);
        return hit ? ok(`topology ${o}`, hit) : failed(`topology ${o}`, `no node or switch '${o}'`);
      }
      return ok("topology", compactTopology(t.value));
    }
    case "health": {
      const h = await r.health.get();
      if (!h.value) return failed("health", `the health gates could not be read: ${h.error ?? "not yet"}`);
      const gate = arg(args, "gate");
      const subject = arg(args, "subject");
      return ok(`health${gate ? ` ${gate}` : ""}${subject ? ` ${subject}` : ""} (validate ${h.at ? new Date(h.at).toISOString().slice(11, 16) : "?"})`, healthView(h.value, gate, subject));
    }
    case "backup": {
      const m = arg(args, "module");
      if (m) {
        if (!MODULE_NAME.test(m)) throw new Error("`module` must be a module's name");
        const b = await r.moduleBackup.of(m).get();
        return b.value ? ok(`backup ${m}`, b.value) : failed(`backup ${m}`, `backup of ${m} could not be read: ${b.error}`);
      }
      const b = await r.backup.get();
      return b.value ? ok("backup", b.value) : failed("backup", `backups could not be read: ${b.error}`);
    }
    case "pulse": {
      const [h, p] = await Promise.all([r.health.get(), r.peers.get()]);
      return ok("pulse", { gate: h.value?.gates.find((g) => g.name === "pulse") ?? null, peers: p.value ?? { error: p.error } });
    }
    case "activity": {
      const m = arg(args, "module");
      const a = await r.activity.get();
      const jobs = ctx.jobs().filter((x) => !m || x.argv.slice(1).includes(m)).slice(0, 15).map((x) => ({
        at: x.created, who: x.who.user, via: x.origin === "ui" ? x.who.via : x.origin, kind: x.kind, command: shellQuote(x.ran ?? x.argv),
        result: x.state === "done" ? `exit ${x.exit}` : x.state,
      }));
      const runs = (a.value?.runs ?? []).slice(0, 5).map((s) => ({
        start: s.start, end: s.end, result: s.result,
        lines: s.lines.filter((l) => !m || l.text.includes(m)).slice(0, 15).map((l) => `${l.level}: ${l.text}`),
      }));
      return ok(`activity${m ? ` ${m}` : ""}`, { jobs, sweeps: runs, ledger: (a.value?.ledger ?? []).slice(0, 10), sweepActive: a.value?.sweepActive ?? null });
    }
    case "logs":
      return logs(ctx, args);
    case "help": {
      const bin = arg(args, "manager") ?? "";
      const ms = ctx.manifests();
      if (!ms) return failed(`help ${bin}`, "the verb manifests are still loading");
      const man = manifestView(ms, bin);
      if (!man) return failed(`help ${bin}`, `no manager '${bin}' (managers: ${[...ms.byBin.keys()].join(", ")})`);
      const readme = readmeOf(ctx.repoRoot, bin);
      const text = JSON.stringify(man);
      return ok(`help ${bin}`, cap(`${text}\n\nREADME:\n${readme ? readme.slice(0, Math.max(1500, RESULT_CHARS - text.length - 100)) : "(none)"}`, RESULT_CHARS + 2000));
    }
    case "propose_job":
      return propose(ctx, args);
    case "open_console":
      return openConsole(ctx, args);
  }
  return failed(name, `no tool ${name}`);
}

async function logs(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolOutcome> {
  const l = ctx.loki!;
  const host = arg(args, "host") ?? "";
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(host)) return { ok: false, summary: "logs: bad host", content: "`host` must be a host name (a guest or node), e.g. immich" };
  const now = (ctx.now ?? Date.now)();
  const start = timeOf(arg(args, "since"), now, now - 3600_000);
  const end = timeOf(arg(args, "until"), now, now);
  if (start === null || end === null || start >= end) return { ok: false, summary: "logs: bad times", content: "`since` and `until` are 30m, 2h, 7d or ISO times, since before until" };
  if (end - start > 7 * 86400_000) return { ok: false, summary: "logs: range too long", content: "the range may span at most 7 days" };
  const limit = Math.min(200, Math.max(1, Number(args.limit) || 50));
  const contains = arg(args, "contains");
  let pw: string;
  try {
    pw = readFileSync(l.passwordFile, "utf8").trim();
  } catch {
    return { ok: false, summary: "logs: no credential", content: `Loki's credential (${l.passwordFile}) cannot be read` };
  }
  const q = `${l.url.replace(/\/+$/, "")}/loki/api/v1/query_range`;
  const params = [
    ["query", logql(host, contains)],
    ["start", `${start}000000`],
    ["end", `${end}000000`],
    ["limit", String(limit)],
    ["direction", "backward"],
  ].map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
  const f = ctx.fetch ?? fetch;
  const auth = Buffer.from(`${l.user}:${pw}`).toString("base64");
  const r = await f(`${q}?${params}`, { headers: { Authorization: `Basic ${auth}` }, signal: AbortSignal.timeout(30_000) });
  if (!r.ok) return { ok: false, summary: `logs ${host}: HTTP ${r.status}`, content: `Loki answered HTTP ${r.status}: ${(await r.text()).slice(0, 200)}` };
  const doc = (await r.json()) as { data?: { result?: { stream?: Record<string, string>; values?: [string, string][] }[] } };
  const lines: [number, string][] = [];
  for (const s of doc.data?.result ?? []) {
    const unit = s.stream?.unit ?? s.stream?.service_name ?? s.stream?.job ?? "";
    for (const [ns, line] of s.values ?? []) lines.push([Number(ns.slice(0, -6)), `${new Date(Number(ns.slice(0, -6))).toISOString().slice(0, 19)} ${unit}: ${line.slice(0, 300)}`]);
  }
  lines.sort((a, b) => b[0] - a[0]);
  const range = `${new Date(start).toISOString().slice(0, 16)}–${new Date(end).toISOString().slice(11, 16)}`;
  return {
    ok: true,
    summary: `logs host=${host}${contains ? ` "${contains}"` : ""} ${range}`,
    content: cap(lines.length ? lines.slice(0, limit).map((x) => x[1]).join("\n") : `no lines for host=${host} in ${range}`),
  };
}

function propose(ctx: ToolContext, args: Record<string, unknown>): ToolOutcome {
  const ms = ctx.manifests();
  if (!ms) return { ok: false, summary: "propose: manifests loading", content: "The verb manifests are still loading; try again in a moment." };
  const argv = args.argv;
  const rationale = typeof args.rationale === "string" ? args.rationale.trim().slice(0, 500) : "";
  if (!Array.isArray(argv) || !argv.every((a) => typeof a === "string")) {
    return { ok: false, summary: "propose: argv not a list", content: "`argv` must be an array of strings, the manager first." };
  }
  const words = (argv as string[]).map((a) => a.trim()).filter((a) => a.length > 0);
  // The job model adds the applying and dry-run flags itself; a proposal
  // never carries them, or the card would claim to be its own apply.
  const stray = words.filter((w) => ["--apply", "--dry-run", "--check", "--json"].includes(w));
  if (stray.length) {
    return { ok: false, summary: `propose: ${stray.join(" ")} not allowed`, content: `Leave out ${stray.join(", ")}: the card previews first, and the operator's Run adds the applying flag.` };
  }
  const v = validateArgv(ms, words);
  if (!v.ok) return { ok: false, summary: `propose refused: ${v.reason.slice(0, 100)}`, content: `Not a valid job: ${v.reason}. Check the verb with help(manager) and propose again.` };
  const preview = v.read ? "read" : v.preview.kind;
  const proposal: ProposedJob = {
    argv: words, rationale, verb: `${v.bin} ${v.verb.verb}`, read: v.read, destructive: v.destructive, preview,
    previewArgv: v.read ? null : previewArgv(v), applyArgv: v.read ? [v.bin, ...v.args] : applyArgv(v),
  };
  return {
    ok: true,
    summary: `proposed: ${shellQuote(words)}`,
    proposal,
    content:
      `Proposed as a card: ${shellQuote(words)}. ` +
      (v.read ? "It is a read: the operator's Run shows its result. " : v.preview.kind === "none" ? `It has no dry run (${v.preview.touches}); its preview shows the command. ` : "Its Preview runs the manager's own dry run. ") +
      (v.destructive ? "It is destructive: Installer only, with the object's name typed. " : "") +
      "You have not run it and cannot: tell the operator the card is there and that its Run button runs it.",
  };
}

// The console's public address: console.<domain of the console's environment>.
async function consoleUrl(r: Reads, path: string): Promise<string | null> {
  const [m, e, s] = await Promise.all([r.modules.get(), r.environments.get(), r.site.get()]);
  const envs = (e.value ?? []) as { name: string; domains?: { primary?: string } }[];
  const own = m.value?.modules.find((x) => x.name === "tappaas-cicd")?.environment;
  const dflt = (s.value?.site as { defaultEnvironment?: string } | undefined)?.defaultEnvironment;
  const domain = [own, "mgmt", dflt].map((n) => envs.find((x) => x.name === n)?.domains?.primary).find((d) => d);
  return domain ? `https://console.${domain}${path}` : null;
}

async function openConsole(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolOutcome> {
  const r = ctx.reads;
  const res = resolveTarget(args.target, args.values);
  const no = (why: string): ToolOutcome => ({ ok: false, summary: `open refused: ${why.slice(0, 100)}`, content: `Not opened: ${why}. Nothing changed.` });
  if (!res.ok) return no(res.reason);
  // The object it names must exist here, and a Modify's values be its fields.
  if (res.arg && (res.wizard === "modify-module" || res.kind === "page")) {
    const m = await r.modules.get();
    const names = (m.value?.modules ?? []).map((x) => x.name);
    if (m.value && !names.includes(res.arg)) return no(`no deployed module '${res.arg}' (modules: ${names.join(", ")})`);
  }
  if (res.wizard === "modify-module" && Object.keys(res.values).length) {
    const f = await r.moduleFields.of(res.arg!).get();
    const fields = ((f.value as { fields?: { field: string; settable?: boolean }[] } | null)?.fields ?? []);
    if (fields.length) {
      const unknown = Object.keys(res.values).filter((k) => !fields.some((x) => x.field === k));
      if (unknown.length) return no(`${res.arg} has no field ${unknown.join(", ")} (its fields: ${fields.map((x) => x.field).join(", ")})`);
      const fixed = Object.keys(res.values).filter((k) => fields.some((x) => x.field === k && x.settable === false));
      if (fixed.length) return no(`${fixed.join(", ")} of ${res.arg} cannot be changed with modify`);
    }
  }
  if (res.wizard === "modify-zone" || res.wizard === "add-wifi") {
    const z = await r.zones.get();
    const zones = (z.value ?? []) as { name: string; type?: string; state?: string }[];
    const zone = zones.find((x) => x.name === res.arg);
    if (z.value && !zone) return no(`no zone '${res.arg}' (zones: ${zones.map((x) => x.name).join(", ")})`);
    if (zone && res.wizard === "add-wifi" && (!["Client", "Guest"].includes(zone.type ?? "") || (zone.state ?? "Active") !== "Active")) {
      return no(`WiFi is offered for active Client and Guest zones; ${res.arg} is ${zone.type ?? "?"}, ${zone.state ?? "Active"}`);
    }
  }
  const nav: Opened = { target: res.target, values: res.values, path: res.path, title: res.title, url: await consoleUrl(r, res.path) };
  const filled = Object.keys(res.values).length ? ` with ${Object.entries(res.values).map(([k, v]) => `${k}=${Array.isArray(v) ? v.join(",") : v}`).join(", ")} filled in` : "";
  return {
    ok: true,
    summary: `opened: ${res.title}${filled ? ` (${Object.keys(res.values).join(", ")})` : ""}`,
    navigate: nav,
    content: ctx.shell
      ? `The operator is in a shell (tappaas ask): they were given the address of ${res.title}, ${nav.url ?? res.path}${filled}. Nothing changed. Tell them to open it in the console to fill in the rest, preview and apply it.`
      : `Opened ${res.title} in the operator's console (${res.path})${filled}. Nothing changed: ` +
      (res.kind === "wizard" ? "the operator fills in the rest there, previews and applies it. " : "") +
      "Tell them in a sentence what is open and what to check before they apply; do not propose the same change as a job as well.",
  };
}
