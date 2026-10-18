// jobs.ts — every change the console makes is a job (ADR-034 D4): the exact
// argv of a manager verb, validated against its manifest (manifest.ts, T2),
// previewed with the verb's own dry run before it may be applied (T3), run by
// one runner that serializes them and never overlaps the sweep, and recorded in
// Activity (jobs.jsonl in the state directory: who, from where, the argv, the
// preview, the output, the exit code, how long).
//
//   preview  the dry-run form (--check, --dry-run, reconcile without --apply,
//            the modify pre-gate); a verb with no dry run gets a preview that
//            runs nothing and says what the verb touches
//   apply    only from a finished preview of the same argv, within the hour;
//            a destructive call needs the object's name typed and Installer
//   read     a verb that changes nothing (module test, node network show):
//            runs at once, beside the queue
//
// Who may: access.ts mayWrite — the gate's Admin or Installer, or the setup
// token while setup is open; never loopback without the gate, never the status
// route.
//
// From the assistant (ADR-034 D7): a proposed-job card posts its preview (or
// read) with {conversation, proposal}; the proposal must be in the caller's
// own conversation with the same argv. The job then carries origin
// "assistant" and the turn that proposed it, and so does its apply. The
// assistant itself never reaches this file: only the operator's click does.

import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync } from "fs";
import { randomBytes } from "crypto";
import { join } from "path";
import { Me, SetupState, mayWrite } from "./access";
import { Proposal } from "./conversations";
import { Manifests, Validated, applyArgv, baseArgv, previewArgv, sameArgv, validateArgv } from "./manifest";
import { ManifestVerb } from "../../lib/ts/src/help";
import { Runner, Streamer } from "./run";

export type JobKind = "preview" | "apply" | "read";
export type JobState = "queued" | "running" | "done" | "refused";

export interface Job {
  id: string;
  kind: JobKind;
  state: JobState;
  who: { user: string | null; name: string | null; role: string; via: string };
  route: string;
  origin: "ui" | "assistant";
  assistant: { conversation: string; turn: number; proposal: string } | null; // the card's turn
  bin: string;
  verb: string;
  argv: string[]; // the change as asked (its base, without preview or apply flag)
  ran: string[] | null; // what ran: the dry run, the apply; null when the preview runs nothing
  preview: ManifestVerb["preview"];
  previewOf: string | null; // an apply: the preview it follows
  destructive: boolean;
  object: string;
  created: string;
  started: string | null;
  ended: string | null;
  durationMs: number | null;
  exit: number | null;
  output: string;
  truncated: boolean;
  refused: string | null;
}

export type JobSummary = Omit<Job, "output">;

export interface SweepState {
  active: boolean;
  state: string; // systemd ActiveState
  since: string | null;
  stage: string | null; // config/.update-stage, the stage it is in
}

// The sweep (update-tappaas.service) owns the site while it runs: no job may
// start then (D4). Anything but a settled unit counts as running.
export function sweepBlocks(activeState: string): boolean {
  return ["active", "activating", "deactivating", "reloading", "refreshing"].includes(activeState.trim());
}

export function parseUnitShow(out: string): { state: string; since: string | null } {
  const kv = new Map<string, string>();
  for (const line of out.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) kv.set(line.slice(0, i), line.slice(i + 1).trim());
  }
  const since = kv.get("ActiveEnterTimestamp") ?? "";
  return { state: kv.get("ActiveState") ?? "unknown", since: since && since !== "n/a" ? since : null };
}

export function sweepMessage(s: SweepState): string {
  return `the sweep is running (update-tappaas.service ${s.state}${s.since ? ` since ${s.since}` : ""}${s.stage ? `, stage: ${s.stage}` : ""}): no job starts until it has finished`;
}

export interface JobsConfig {
  stateDir: string;
  configDir: string;
  manifests: () => Manifests | null;
  stream: Streamer;
  run: Runner; // for the unit's state
  now?: () => number;
  onWriteDone?: (job: Job) => void; // refresh the read caches
  // A card's proposal in the caller's own conversation (assistant.ts).
  proposal?: (me: Me, conversation: string, proposal: string) => Proposal | null;
  log?: (line: string) => void;
  previewTtlMs?: number;
}

export interface CreateRequest {
  argv: unknown;
  preview?: unknown;
  assistant?: unknown; // {conversation, proposal}: the card this came from
}

export type CreateResult = { status: number; job?: Job; error?: string; sweep?: SweepState };

const MAX_OUTPUT = 1024 * 1024;
const KEEP = 500; // jobs held in memory (and read back from jobs.jsonl at start)

type Listener = (ev: { type: "output"; chunk: string } | { type: "state"; job: JobSummary } | { type: "end"; job: JobSummary }) => void;

export class Jobs {
  private readonly jobs: Job[] = [];
  private readonly queue: Job[] = [];
  private running: Job | null = null;
  private readonly listeners = new Map<string, Set<Listener>>();
  readonly file: string;

  constructor(private readonly cfg: JobsConfig) {
    this.file = join(cfg.stateDir, "jobs.jsonl");
    this.load();
  }

  private now(): number {
    return (this.cfg.now ?? Date.now)();
  }

  private load(): void {
    if (!existsSync(this.file)) return;
    try {
      const lines = readFileSync(this.file, "utf8").split("\n").filter((l) => l.trim().length > 0);
      for (const l of lines.slice(-KEEP)) {
        try {
          this.jobs.push(JSON.parse(l) as Job);
        } catch {
          /* a torn line: skip it */
        }
      }
    } catch (e) {
      this.cfg.log?.(`jobs.jsonl unreadable: ${(e as Error).message}`);
    }
  }

  private record(job: Job): void {
    try {
      mkdirSync(this.cfg.stateDir, { recursive: true });
      appendFileSync(this.file, JSON.stringify(job) + "\n");
    } catch (e) {
      this.cfg.log?.(`could not record job ${job.id}: ${(e as Error).message}`);
    }
  }

  // ── reads ───────────────────────────────────────────────────────────

  list(): JobSummary[] {
    return [...this.jobs].reverse().map(summary);
  }

  get(id: string): Job | null {
    return this.jobs.find((j) => j.id === id) ?? null;
  }

  queued(): string[] {
    return [...(this.running ? [this.running.id] : []), ...this.queue.map((j) => j.id)];
  }

  subscribe(id: string, l: Listener): () => void {
    let set = this.listeners.get(id);
    if (!set) {
      set = new Set();
      this.listeners.set(id, set);
    }
    set.add(l);
    return () => set?.delete(l);
  }

  private emit(job: Job, ev: Parameters<Listener>[0]): void {
    for (const l of this.listeners.get(job.id) ?? []) l(ev);
    if (ev.type === "end") this.listeners.delete(job.id);
  }

  async sweep(): Promise<SweepState> {
    const r = await this.cfg.run("systemctl", ["show", "update-tappaas.service", "--property=ActiveState,ActiveEnterTimestamp"], 10_000);
    const { state, since } = r.ran ? parseUnitShow(r.stdout) : { state: "unknown", since: null };
    let stage: string | null = null;
    const f = join(this.cfg.configDir, ".update-stage");
    try {
      if (existsSync(f) && statSync(f).isFile()) stage = readFileSync(f, "utf8").trim() || null;
    } catch {
      stage = null;
    }
    return { active: sweepBlocks(state), state, since, stage };
  }

  // ── creating ────────────────────────────────────────────────────────

  private newJob(me: Me, v: Validated, kind: JobKind, ran: string[] | null, previewOf: string | null, from: Job["assistant"] = null): Job {
    const t = this.now();
    return {
      id: `${new Date(t).toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}-${randomBytes(3).toString("hex")}`,
      kind,
      state: "queued",
      who: { user: me.user, name: me.name, role: me.role, via: me.via },
      route: me.route,
      origin: from ? "assistant" : "ui",
      assistant: from,
      bin: v.bin,
      verb: v.verb.verb,
      argv: baseArgv(v),
      ran,
      preview: v.verb.preview,
      previewOf,
      destructive: v.destructive,
      object: v.object,
      created: new Date(t).toISOString(),
      started: null,
      ended: null,
      durationMs: null,
      exit: null,
      output: "",
      truncated: false,
      refused: null,
    };
  }

  private add(job: Job): void {
    this.jobs.push(job);
    if (this.jobs.length > KEEP) this.jobs.splice(0, this.jobs.length - KEEP);
  }

  private async refuseForSweep(job: Job): Promise<SweepState | null> {
    const s = await this.sweep();
    if (!s.active) return null;
    job.state = "refused";
    job.refused = sweepMessage(s);
    job.ended = new Date(this.now()).toISOString();
    this.record(job);
    return s;
  }

  // POST /jobs: a preview of a change, or a read. A write without a preview
  // is refused (T3): its apply goes through applyPreview.
  async create(me: Me, setup: SetupState, req: CreateRequest): Promise<CreateResult> {
    // Who first: a caller who may not write is refused whatever it sent (T1).
    const w = mayWrite(me, setup, false);
    if (!w.ok) return { status: w.status, error: w.reason };
    const ms = this.cfg.manifests();
    if (!ms) return { status: 503, error: "the verb manifests are still loading" };
    const v = validateArgv(ms, req.argv);
    if (!v.ok) return { status: 400, error: v.reason };
    const card = this.card(me, req.assistant, baseArgv(v));
    if (typeof card === "string") return { status: 400, error: card };
    if (v.read) {
      const job = this.newJob(me, v, "read", [v.bin, ...v.args], null, card);
      this.add(job);
      void this.execute(job);
      return { status: 201, job };
    }
    if (req.preview !== true) {
      return { status: 409, error: "a change is previewed first (ADR-034 T3): POST /jobs {argv, preview: true}, then POST /jobs/<id>/apply" };
    }
    const job = this.newJob(me, v, "preview", previewArgv(v), null, card);
    this.add(job);
    const s = await this.refuseForSweep(job);
    if (s) return { status: 409, job, error: job.refused ?? "", sweep: s };
    if (job.ran === null) {
      // No dry run: the preview is the command and what the verb touches.
      const t = new Date(this.now()).toISOString();
      const touches = v.verb.preview.kind === "none" ? v.verb.preview.touches : "";
      job.output =
        `${v.bin} ${v.verb.verb} has no dry run.\n` +
        (touches ? `It ${touches}.\n` : "") +
        `Apply runs exactly:\n  ${shellQuote(applyArgv(v))}\n`;
      Object.assign(job, { state: "done", started: t, ended: t, durationMs: 0, exit: 0 });
      this.record(job);
      return { status: 201, job };
    }
    this.enqueue(job);
    return { status: 201, job };
  }

  // The card a job came from, checked: the proposal is in the caller's own
  // conversation and proposed exactly this argv. A string is the refusal.
  private card(me: Me, ref: unknown, argv: string[]): Job["assistant"] | string {
    if (ref === undefined || ref === null) return null;
    const r = ref as { conversation?: unknown; proposal?: unknown };
    if (typeof r !== "object" || typeof r.conversation !== "string" || typeof r.proposal !== "string") return "assistant: {conversation, proposal}";
    const p = this.cfg.proposal?.(me, r.conversation, r.proposal) ?? null;
    if (!p) return `no proposal ${r.proposal} in your conversation ${r.conversation}`;
    if (!sameArgv(p.argv, argv)) return `the job's argv is not the one proposal ${p.id} proposed`;
    return { conversation: r.conversation, turn: p.turn, proposal: p.id };
  }

  // POST /jobs/<id>/apply: the preview's own argv with the applying flag (T3).
  // A destructive call needs `confirm` to be the object's name and Installer.
  async applyPreview(me: Me, setup: SetupState, previewId: string, body: { confirm?: unknown }): Promise<CreateResult> {
    const ms = this.cfg.manifests();
    if (!ms) return { status: 503, error: "the verb manifests are still loading" };
    const p = this.get(previewId);
    if (!p || p.kind !== "preview") return { status: 404, error: `no preview ${previewId}` };
    if (p.state !== "done") return { status: 409, error: p.state === "refused" ? `the preview was refused: ${p.refused}` : "the preview has not finished" };
    if (this.now() - Date.parse(p.ended ?? p.created) > (this.cfg.previewTtlMs ?? 3600_000)) {
      return { status: 409, error: "the preview is more than an hour old: preview again" };
    }
    const v = validateArgv(ms, p.argv);
    if (!v.ok) return { status: 400, error: v.reason };
    if (!sameArgv(baseArgv(v), p.argv)) return { status: 409, error: "the preview's argv no longer validates as the same change" };
    const w = mayWrite(me, setup, v.destructive);
    if (!w.ok) return { status: w.status, error: w.reason };
    if (v.destructive && body.confirm !== v.object) {
      return { status: 400, error: `a destructive verb: type '${v.object}' to confirm` };
    }
    const job = this.newJob(me, v, "apply", applyArgv(v), p.id, p.assistant ?? null);
    this.add(job);
    const s = await this.refuseForSweep(job);
    if (s) return { status: 409, job, error: job.refused ?? "", sweep: s };
    this.enqueue(job);
    return { status: 201, job };
  }

  // A secret the Setup wizard wrote (secrets.ts): in Activity like any change,
  // with the keys it set and never their values.
  recordSecret(me: Me, name: string, file: string, keys: string[]): Job {
    const t = new Date(this.now()).toISOString();
    const job: Job = {
      id: `${t.replace(/[-:.TZ]/g, "").slice(0, 14)}-${randomBytes(3).toString("hex")}`,
      kind: "apply",
      state: "done",
      who: { user: me.user, name: me.name, role: me.role, via: me.via },
      route: me.route,
      origin: "ui",
      assistant: null,
      bin: "console",
      verb: `secret ${name}`,
      argv: ["console", "secret", name],
      ran: null,
      preview: { kind: "none", touches: `writes ${file} (mode 0600)` },
      previewOf: null,
      destructive: false,
      object: name,
      created: t,
      started: t,
      ended: t,
      durationMs: 0,
      exit: 0,
      output: `wrote ${file}: ${keys.join(", ")} (values are never recorded or shown)\n`,
      truncated: false,
      refused: null,
    };
    this.add(job);
    this.record(job);
    return job;
  }

  // ── running ─────────────────────────────────────────────────────────

  private enqueue(job: Job): void {
    this.queue.push(job);
    void this.pump();
  }

  // One write at a time, in order; the sweep is checked again as each starts.
  private async pump(): Promise<void> {
    if (this.running) return;
    const job = this.queue.shift();
    if (!job) return;
    this.running = job;
    try {
      const s = await this.sweep();
      if (s.active) {
        job.state = "refused";
        job.refused = sweepMessage(s);
        job.ended = new Date(this.now()).toISOString();
        this.record(job);
        this.emit(job, { type: "end", job: summary(job) });
      } else {
        await this.execute(job);
      }
    } finally {
      this.running = null;
      void this.pump();
    }
  }

  private async execute(job: Job): Promise<void> {
    const argv = job.ran ?? [];
    const t0 = this.now();
    job.state = "running";
    job.started = new Date(t0).toISOString();
    this.emit(job, { type: "state", job: summary(job) });
    this.cfg.log?.(`job ${job.id} ${job.kind} by ${job.who.user ?? "?"} (${job.who.via}): ${argv.join(" ")}`);
    const r = await this.cfg.stream(argv[0], argv.slice(1), (chunk) => {
      if (job.output.length < MAX_OUTPUT) {
        job.output += chunk.slice(0, MAX_OUTPUT - job.output.length);
        this.emit(job, { type: "output", chunk });
      } else job.truncated = true;
    });
    if (!r.ran) job.output += `\n[console] could not run ${argv[0]}: ${r.error ?? "not found"}\n`;
    const t1 = this.now();
    job.state = "done";
    job.exit = r.rc;
    job.ended = new Date(t1).toISOString();
    job.durationMs = t1 - t0;
    this.record(job);
    this.emit(job, { type: "end", job: summary(job) });
    if (job.kind === "apply") this.cfg.onWriteDone?.(job);
  }
}

export function summary(j: Job): JobSummary {
  const { output: _o, ...rest } = j;
  return rest;
}

// The argv as one would type it on tappaas-cicd (shown and copied, never run by a shell).
export function shellQuote(argv: string[]): string {
  return argv.map((a) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)).join(" ");
}

// Jobs that concern a module (its name as an argument), for its Activity tab.
export function jobsNaming(list: JobSummary[], name: string): JobSummary[] {
  return list.filter((j) => j.argv.slice(1).includes(name));
}
