// assistant-tools.ts — what the assistant may do (ADR-034 D7): read the site
// through the console's own reads (the same caches a page is drawn from), read
// a host's logs in Loki, read a manager's manifest and README, and propose a
// job. Nothing else. There is no apply tool and no write: a tool name outside
// TOOLS is refused, and propose_job creates no job — it validates the argv
// against the manifests and returns a card for the operator, whose click runs
// it through the job model (jobs.ts) under the operator's own role.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { attention, findingsFor, moduleSummaries } from "./badges";
import { JobSummary, shellQuote } from "./jobs";
import { Manifests, validateArgv } from "./manifest";
import { MODULE_NAME, Reads } from "./reads";
import { HealthDoc } from "./model";
import { ToolDef } from "./litellm";

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
}

export interface ProposedJob {
  argv: string[];
  rationale: string;
  verb: string;
  read: boolean;
  destructive: boolean;
  preview: string;
}

export interface ToolOutcome {
  ok: boolean;
  content: string; // what the model is told
  summary: string; // the line the drawer shows ("read: health guest-memory")
  proposal?: ProposedJob;
  refused?: boolean;
}

// What a result may weigh: the model's context is small (hrossen's model: 32k tokens).
export const RESULT_CHARS = 7000;

const obj = (properties: Record<string, unknown>, required: string[] = []): Record<string, unknown> => ({ type: "object", properties, required, additionalProperties: false });
const str = (description: string): Record<string, unknown> => ({ type: "string", description });

// Every tool the assistant has. Nothing writes; propose_job only proposes.
export const TOOLS: Record<string, { description: string; parameters: Record<string, unknown> }> = {
  modules_list: {
    description: "Every deployed module: node, vmid, zone, environment, running state, badges (health, backup, cve) and how many health findings name it.",
    parameters: obj({}),
  },
  module_show: {
    description: "One module: its summary, every health finding that names it, its config as module-manager shows it, its resolved fields, and the fields `modify --set` may change with their ADR-020 change class.",
    parameters: obj({ module: str("the module's name") }, ["module"]),
  },
  module_drift: {
    description: "One module's drift: where the running guest and its services differ from the config (module-manager drift; can take a minute).",
    parameters: obj({ module: str("the module's name") }, ["module"]),
  },
  zones: { description: "The network zones: VLAN, network, type, state, access-to and pinholes.", parameters: obj({}) },
  environments: { description: "The environments: their zones and domains.", parameters: obj({}) },
  topology: {
    description: "The site as cabled (network-manager topology): nodes with their guests and uplinks, switches, LAGs, access points, the outside. Give `object` (a node or switch name) for that object in full.",
    parameters: obj({ object: str("a node or switch name (optional)") }),
  },
  health: {
    description: "The health gates (health-manager validate): each gate's status and its findings. Give `gate` for one gate in full (e.g. guest-memory, memory-commitment, pulse, backup-status), or `subject` for every finding naming a module or node.",
    parameters: obj({ gate: str("a gate name (optional)"), subject: str("a module or node name (optional)") }),
  },
  backup: {
    description: "Backups: every module's policy and whether it is in the PBS job; with `module`, its policy and restore points (backup-manager show and coverage).",
    parameters: obj({ module: str("a module name (optional)") }),
  },
  pulse: { description: "The pulse: the off-site buddies and the satellite, whether each answers (the pulse gate and backup-manager peers).", parameters: obj({}) },
  activity: {
    description: "What was done to the site: the console's jobs (who, the command, the result) and the sweep's runs with their errors; with `module`, only what names it.",
    parameters: obj({ module: str("a module name (optional)") }),
  },
  logs: {
    description: "A host's log lines from Loki (the logging module): newest first. `host` is a guest or node name (immich, tappaas1). `since` and `until` are relative (30m, 2h, 7d) or ISO times; `contains` filters the lines.",
    parameters: obj({ host: str("the host label"), since: str("default 1h"), until: str("default now"), contains: str("a text the line contains (optional)"), limit: { type: "integer", description: "at most 200, default 50" } }, ["host"]),
  },
  help: {
    description: "A manager's verbs as its --help declares them (each verb's usage, options, whether it changes the site and how it previews) and its README.",
    parameters: obj({ manager: str("e.g. module-manager, network-manager, switch-controller") }, ["manager"]),
  },
  propose_job: {
    description: "Propose a change as a job card the operator previews and runs. You never run it: only the operator's Run does. `argv` is the exact command, the manager first, e.g. [\"module-manager\",\"modify\",\"immich\",\"--set\",\"memory=10240\"], without --apply, --dry-run or --json (the job model adds them). It must be a verb a manifest declares.",
    parameters: obj({ argv: { type: "array", items: { type: "string" }, description: "the command line as an array of words" }, rationale: str("one sentence: why, and its consequence") }, ["argv", "rationale"]),
  },
};

export function toolDefs(ctx: ToolContext): ToolDef[] {
  return Object.entries(TOOLS)
    .filter(([name]) => name !== "logs" || ctx.loki !== null)
    .map(([name, t]) => ({ type: "function", function: { name, description: t.description, parameters: t.parameters } }));
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
      preview: v.preview.kind === "none" ? `no dry run: ${v.preview.touches}` : v.preview.kind,
      destructive: v.destructive || v.destructiveWhen.length > 0 ? (v.destructive ? true : v.destructiveWhen) : undefined,
      options: v.options.map((o) => `${o.flag}${o.arg ? ` ${o.arg}` : ""}${o.description ? ` — ${o.description}` : ""}`),
    })),
  };
}

// Run one tool call. Unknown names are refused: the assistant has no other tool.
export async function runTool(ctx: ToolContext, name: string, rawArgs: string): Promise<ToolOutcome> {
  if (!Object.prototype.hasOwnProperty.call(TOOLS, name) || (name === "logs" && !ctx.loki)) {
    return {
      ok: false,
      refused: true,
      summary: `refused: ${name} (no such tool)`,
      content:
        `Refused: there is no tool '${name}'. You cannot run, apply or change anything; nothing here does. ` +
        "To change the site, call propose_job: it puts a card in front of the operator, and only their Run button runs it.",
    };
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
      return ok(`module show ${name_}`, {
        module: row,
        findings: findingsFor(h.value, name_),
        show: show.value ?? { error: show.error },
        resolved: resolve.value ?? { error: resolve.error },
        modifiable: fields.value ?? { error: fields.error },
      });
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
  const preview = v.read ? "read" : v.verb.preview.kind;
  const proposal: ProposedJob = { argv: words, rationale, verb: `${v.bin} ${v.verb.verb}`, read: v.read, destructive: v.destructive, preview };
  return {
    ok: true,
    summary: `proposed: ${shellQuote(words)}`,
    proposal,
    content:
      `Proposed as a card: ${shellQuote(words)}. ` +
      (v.read ? "It is a read: the operator's Run shows its result. " : v.verb.preview.kind === "none" ? `It has no dry run (${v.verb.preview.touches}); its preview shows the command. ` : "Its Preview runs the manager's own dry run. ") +
      (v.destructive ? "It is destructive: Installer only, with the object's name typed. " : "") +
      "You have not run it and cannot: tell the operator the card is there and that its Run button runs it.",
  };
}
