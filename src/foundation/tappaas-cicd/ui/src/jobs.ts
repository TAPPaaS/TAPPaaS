// jobs.ts — every change the console makes is a job (ADR-034 D4): the exact
// argv of a manager verb, validated against its manifest (manifest.ts, T2),
// previewed with the verb's own dry run before it may be applied (T3), run by
// one runner that serializes them and never overlaps the sweep, and recorded in
// Activity (jobs.jsonl in the state directory: who, from where, the argv, the
// preview, the exit code, how long; each job's output in jobs/<id>.log beside
// it, read on demand — the summaries are what the console holds in memory).
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

import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync } from "fs";
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
  object: string; // what the typed confirmation names
  objectLabel?: string; // the object as shown, "<switch>:<port>" (#855); absent on older records
  created: string;
  started: string | null;
  ended: string | null;
  durationMs: number | null;
  exit: number | null;
  output: string;
  truncated: boolean;
  refused: string | null;
  // The console stopped (a restart) while this job ran or waited: cut off, no
  // exit code. Set when the records are read back; absent otherwise.
  interrupted?: boolean;
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
  lockFile?: string; // held while a write job runs (default <stateDir>/console-job.lock)
  manifests: () => Manifests | null;
  stream: Streamer;
  run: Runner; // for the unit's state
  now?: () => number;
  onWriteDone?: (job: JobSummary) => void; // refresh the read caches
  // A card's proposal in the caller's own conversation (assistant.ts).
  proposal?: (me: Me, conversation: string, proposal: string) => Proposal | null;
  log?: (line: string) => void;
  previewTtlMs?: number;
  // The runner has nothing left (no write running or queued, no read running):
  // the moment a deferred restart may happen (takeRestartMarker, main.ts).
  onIdle?: () => void;
  keep?: number; // summaries held in memory and kept at a rotation (default 500)
  rotateAtBytes?: number; // jobs.jsonl is rewritten with the kept summaries past this size (default 10 MiB)
}

export interface CreateRequest {
  argv: unknown;
  preview?: unknown;
  assistant?: unknown; // {conversation, proposal}: the card this came from
}

// The job as the runner holds it (its summary; the output is on disk, get()).
export type CreateResult = { status: number; job?: JobSummary; error?: string; sweep?: SweepState };

const MAX_OUTPUT = 1024 * 1024; // per job, on disk; the rest is dropped and the job marked truncated
const KEEP = 500; // summaries held in memory (and kept when jobs.jsonl is rotated)
const ROTATE_AT = 10 * 1024 * 1024;

// ui/install.sh, having linked a new build while a job runs, leaves this file
// in the state directory instead of restarting the service (which would kill
// the job — refresh-control-plane.sh runs from `module update tappaas-cicd`,
// a console job). The console takes it when the runner is idle and exits;
// the unit's Restart=always brings up the new build.
export const RESTART_MARKER = "restart-pending";

// The lock the runner holds while a write job runs: the sweep's prepare step
// (tappaas-self-prepare.sh) waits for it, the way the console waits for the
// sweep (D4, both directions). JSON: the job's id, argv and start, and the
// console's pid — a lock whose console is gone is stale and ignored.
export const JOB_LOCK = "console-job.lock";

export function takeRestartMarker(stateDir: string): boolean {
  const f = join(stateDir, RESTART_MARKER);
  if (!existsSync(f)) return false;
  try {
    unlinkSync(f);
  } catch {
    return false;
  }
  return true;
}

type Listener = (ev: { type: "output"; chunk: string } | { type: "state"; job: JobSummary } | { type: "end"; job: JobSummary }) => void;

export class Jobs {
  private readonly jobs: JobSummary[] = [];
  private readonly queue: JobSummary[] = [];
  private running: JobSummary | null = null;
  private readonly reads = new Set<string>(); // read jobs running beside the queue
  private readonly listeners = new Map<string, Set<Listener>>();
  private readonly keep: number;
  private readonly rotateAt: number;
  readonly file: string;
  readonly logDir: string; // jobs/<id>.log: each job's output
  readonly lockFile: string;

  constructor(private readonly cfg: JobsConfig) {
    this.file = join(cfg.stateDir, "jobs.jsonl");
    this.logDir = join(cfg.stateDir, "jobs");
    this.lockFile = cfg.lockFile ?? join(cfg.stateDir, JOB_LOCK);
    this.keep = cfg.keep ?? KEEP;
    this.rotateAt = cfg.rotateAtBytes ?? ROTATE_AT;
    this.load();
    this.clearStaleLock();
  }

  // ── the job lock the sweep waits for ────────────────────────────────

  private hold(job: JobSummary): void {
    try {
      mkdirSync(this.cfg.stateDir, { recursive: true });
      writeFileSync(this.lockFile, JSON.stringify({ id: job.id, kind: job.kind, argv: job.ran, started: job.started, pid: process.pid }) + "\n");
    } catch (e) {
      this.cfg.log?.(`could not write the job lock ${this.lockFile}: ${(e as Error).message}`);
    }
  }

  private release(): void {
    try {
      unlinkSync(this.lockFile);
    } catch {
      /* not held */
    }
  }

  // A lock left by a console that is gone (it stopped mid-job: that job is
  // recorded as cut off by load) is removed; one whose console still runs
  // (another console over this state directory) is left and said so.
  private clearStaleLock(): void {
    if (!existsSync(this.lockFile)) return;
    let pid = 0;
    try {
      pid = Number((JSON.parse(readFileSync(this.lockFile, "utf8")) as { pid?: unknown }).pid ?? 0);
    } catch {
      pid = 0;
    }
    if (pid > 0 && pid !== process.pid && alive(pid)) {
      this.cfg.log?.(`${this.lockFile} is held by pid ${pid}, which runs: left alone`);
      return;
    }
    this.release();
    this.cfg.log?.(`removed the stale job lock ${this.lockFile} (pid ${pid || "?"} is gone)`);
  }

  private now(): number {
    return (this.cfg.now ?? Date.now)();
  }

  // jobs.jsonl is append-only: a job is recorded when it starts and again
  // when it ends (older consoles wrote one line, with the output inline). The
  // last line of an id is its record. One still running or queued was cut off
  // by the console stopping: it is marked interrupted, said so in its log, and
  // recorded once more so the mark survives the next start too.
  private load(): void {
    if (!existsSync(this.file)) return;
    try {
      const byId = new Map<string, JobSummary>();
      for (const l of readFileSync(this.file, "utf8").split("\n")) {
        if (!l.trim()) continue;
        try {
          const { output: _o, ...rest } = JSON.parse(l) as Job;
          byId.delete(rest.id);
          byId.set(rest.id, rest);
        } catch {
          /* a torn line: skip it */
        }
      }
      this.jobs.push(...[...byId.values()].slice(-this.keep));
      for (const j of this.jobs) {
        if (j.state !== "running" && j.state !== "queued") continue;
        const was = j.state;
        Object.assign(j, { state: "done", interrupted: true });
        this.appendOutput(j.id, `\n[console] the console stopped while this job ${was === "running" ? "ran" : "waited"}: cut off, no exit code\n`);
        this.record(j);
        this.cfg.log?.(`job ${j.id} was ${was} when the console stopped: recorded as cut off`);
      }
    } catch (e) {
      this.cfg.log?.(`jobs.jsonl unreadable: ${(e as Error).message}`);
    }
  }

  private record(job: JobSummary): void {
    try {
      mkdirSync(this.cfg.stateDir, { recursive: true });
      appendFileSync(this.file, JSON.stringify(summary(job)) + "\n");
      this.rotate();
    } catch (e) {
      this.cfg.log?.(`could not record job ${job.id}: ${(e as Error).message}`);
    }
  }

  // Past rotateAt, jobs.jsonl is rewritten with the kept summaries (atomically:
  // a temp file renamed over it), and the logs of the jobs no longer kept go.
  private rotate(): void {
    let size = 0;
    try {
      size = statSync(this.file).size;
    } catch {
      return;
    }
    if (size <= this.rotateAt) return;
    const kept = this.jobs.slice(-this.keep);
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, kept.map((j) => JSON.stringify(j) + "\n").join(""));
    renameSync(tmp, this.file);
    const ids = new Set(kept.map((j) => j.id));
    try {
      for (const f of readdirSync(this.logDir)) {
        if (f.endsWith(".log") && !ids.has(f.slice(0, -4))) unlinkSync(join(this.logDir, f));
      }
    } catch {
      /* no log directory yet */
    }
    this.cfg.log?.(`jobs.jsonl rotated at ${size} bytes: the last ${kept.length} jobs kept`);
  }

  // ── a job's output: jobs/<id>.log, appended as it comes, read on demand ──

  private logFile(id: string): string {
    return join(this.logDir, `${id}.log`);
  }

  private appendOutput(id: string, chunk: string): void {
    try {
      mkdirSync(this.logDir, { recursive: true });
      appendFileSync(this.logFile(id), chunk);
    } catch (e) {
      this.cfg.log?.(`could not write the output of job ${id}: ${(e as Error).message}`);
    }
  }

  output(id: string): string {
    try {
      return readFileSync(this.logFile(id), "utf8");
    } catch {
      return "";
    }
  }

  // ── reads ───────────────────────────────────────────────────────────

  list(): JobSummary[] {
    return [...this.jobs].reverse();
  }

  // The job with its output (read from disk now, so a stale copy is never served).
  get(id: string): Job | null {
    const j = this.jobs.find((x) => x.id === id);
    return j ? { ...j, output: this.output(id) } : null;
  }

  queued(): string[] {
    return [...(this.running ? [this.running.id] : []), ...this.queue.map((j) => j.id)];
  }

  // Whether anything runs or waits: a restart now would cut a job off.
  busy(): boolean {
    return this.running !== null || this.queue.length > 0 || this.reads.size > 0;
  }

  private settle(): void {
    if (!this.busy()) this.cfg.onIdle?.();
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

  private emit(job: JobSummary, ev: Parameters<Listener>[0]): void {
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

  private newJob(me: Me, v: Validated, kind: JobKind, ran: string[] | null, previewOf: string | null, from: Job["assistant"] = null): JobSummary {
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
      preview: v.preview,
      previewOf,
      destructive: v.destructive,
      object: v.object,
      objectLabel: v.objectLabel,
      created: new Date(t).toISOString(),
      started: null,
      ended: null,
      durationMs: null,
      exit: null,
      truncated: false,
      refused: null,
    };
  }

  private add(job: JobSummary): void {
    this.jobs.push(job);
    if (this.jobs.length > this.keep) this.jobs.splice(0, this.jobs.length - this.keep);
  }

  private async refuseForSweep(job: JobSummary): Promise<SweepState | null> {
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
      this.reads.add(job.id);
      void this.execute(job).finally(() => {
        this.reads.delete(job.id);
        this.settle();
      });
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
      const touches = v.preview.kind === "none" ? v.preview.touches : "";
      this.appendOutput(
        job.id,
        `${v.bin} ${v.verb.verb} has no dry run.\n` +
          (touches ? `It ${touches}.\n` : "") +
          `Apply runs exactly:\n  ${shellQuote(applyArgv(v))}\n`,
      );
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
  // A destructive call needs `confirm` to be the object's name (or the object
  // as shown, within its container) and Installer.
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
    if (v.destructive && body.confirm !== v.object && body.confirm !== v.objectLabel) {
      return { status: 400, error: `a destructive verb: type '${v.object}' to confirm${v.objectLabel !== v.object ? ` (${v.objectLabel})` : ""}` };
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
    const job: JobSummary = {
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
      truncated: false,
      refused: null,
    };
    this.add(job);
    this.appendOutput(job.id, `wrote ${file}: ${keys.join(", ")} (values are never recorded or shown)\n`);
    this.record(job);
    return this.get(job.id)!;
  }

  // ── running ─────────────────────────────────────────────────────────

  private enqueue(job: JobSummary): void {
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
        this.hold(job);
        try {
          await this.execute(job);
        } finally {
          this.release();
        }
      }
    } finally {
      this.running = null;
      void this.pump(); // takes the next job synchronously, if there is one
      this.settle();
    }
  }

  private async execute(job: JobSummary): Promise<void> {
    const argv = job.ran ?? [];
    const t0 = this.now();
    job.state = "running";
    job.started = new Date(t0).toISOString();
    this.record(job); // the running record: a job the console stops on is visible as cut off
    this.emit(job, { type: "state", job: summary(job) });
    this.cfg.log?.(`job ${job.id} ${job.kind} by ${job.who.user ?? "?"} (${job.who.via}): ${argv.join(" ")}`);
    let written = 0;
    const r = await this.cfg.stream(argv[0], argv.slice(1), (chunk) => {
      if (written < MAX_OUTPUT) {
        const part = chunk.slice(0, MAX_OUTPUT - written);
        written += part.length;
        this.appendOutput(job.id, part);
        this.emit(job, { type: "output", chunk: part });
      } else job.truncated = true;
    });
    if (!r.ran) this.appendOutput(job.id, `\n[console] could not run ${argv[0]}: ${r.error ?? "not found"}\n`);
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

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as { code?: string }).code === "EPERM"; // exists, not ours
  }
}

export function summary(j: Job | JobSummary): JobSummary {
  const { output: _o, ...rest } = j as Job;
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
