// jobcancel.test.ts — a job's Cancel and Stop (jobs.ts cancel): a queued job
// leaves the queue and never runs; a running one gets SIGINT, then SIGTERM
// after the grace period; a stop during an Apply's dry run keeps the apply
// from running; only a writer may; and streamAsync signals the child's whole
// process group, its own children with it.

import { mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Me, SetupState } from "../../src/access";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { JobSummary, Jobs } from "../../src/jobs";
import { Manifests } from "../../src/manifest";
import { Runner, StopSignal, Streamer, streamAsync } from "../../src/run";
import { check, done } from "./check";

const SPEC: HelpSpec = {
  name: "module-manager",
  version: "1",
  tagline: "t",
  verbs: [
    { usage: "modify <module> --set field=value... [--allow-disruption]", options: [["--set field=value", "A field."], ["--dry-run", "Pre-gate."], ["--allow-disruption", "Reboot it now."]] },
    { usage: "reconcile <module> [--apply]", options: [["--apply", "Apply."]] },
    { usage: "suspend <module>", effect: { noPreview: "stops the guest and keeps it stopped" } },
  ],
};

const me = (over: Partial<Me> = {}): Me => ({ user: "lars", name: "Lars", email: null, groups: ["installer"], role: "installer", via: "gate", route: "console", ...over });
const closed: SetupState = { active: false, identityInstalled: true, tokenPresent: false };

async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise<void>((r) => setTimeout(r, 1));
}
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

async function main(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-jobcancel-"));
  const ran: string[] = [];
  const got: { argv: string; signal: StopSignal }[] = [];
  // A child that runs until signalled: "hold" ends on SIGINT (exit 130, as a
  // trap that cleaned up), "stubborn" only on SIGTERM.
  const stream: Streamer = (bin, args, onOutput, _t, ctl) =>
    new Promise((resolve) => {
      const argv = [bin, ...args].join(" ");
      ran.push(argv);
      onOutput(`ran ${args[0]}\n`);
      if (!args.includes("hold") && !args.includes("stubborn")) return resolve({ rc: 0, ran: true, error: null });
      ctl?.onSpawn?.((s) => {
        got.push({ argv, signal: s });
        if (s === "SIGINT" && args.includes("hold")) resolve({ rc: 130, ran: true, error: null });
        if (s === "SIGTERM") resolve({ rc: -1, ran: true, error: null });
        return true;
      });
    });
  const run: Runner = async (bin, args) =>
    bin === "systemctl" && args[0] === "show" ? { rc: 0, stdout: "ActiveState=inactive\n", stderr: "", ran: true } : { rc: 1, stdout: "", stderr: "", ran: false };
  const ms: Manifests = { byBin: new Map([["module-manager", renderManifest(SPEC)]]), errors: [], loadedAt: "" };
  const ended: string[] = [];
  const jobs = new Jobs({ stateDir: dir, configDir: dir, manifests: () => ms, stream, run, stopGraceMs: 30 });
  const record = (id: string) => readFileSync(jobs.file, "utf8").trim().split("\n").map((l) => JSON.parse(l) as JobSummary).filter((l) => l.id === id).at(-1)!;

  // ── a queued job: out of the queue, never run ───────────────────────
  let r = await jobs.create(me(), closed, { argv: ["module-manager", "suspend", "hold"], apply: true });
  const a = r.job!;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "suspend", "second"], apply: true });
  const b = r.job!;
  await settle();
  jobs.subscribe(b.id, (ev) => ev.type === "end" && ended.push(b.id));
  check(a.state === "running" && b.state === "queued", "a second write waits behind the first");
  r = jobs.cancel(me({ role: "read", groups: ["admin"] }), closed, b.id);
  check(r.status === 403 && b.state === "queued" && !b.cancelled, "a caller who may not write cancels nothing");
  r = jobs.cancel(me(), closed, "nope");
  check(r.status === 404, "an unknown job: 404");
  r = jobs.cancel(me(), closed, b.id);
  check(r.status === 200 && b.state === "done" && b.exit === null && b.cancelled?.was === "queued" && b.cancelled.by === "lars", "Cancel on a queued job: done, no exit code, recorded as cancelled by whom");
  check(jobs.queued().join() === a.id && ended.includes(b.id), "…out of the queue, and its watchers told it ended");
  check(record(b.id).cancelled?.was === "queued" && /cancelled by lars while queued/.test(jobs.get(b.id)!.output), "…in jobs.jsonl, and said in its output");

  // ── a running job: SIGINT, and it cleans up and ends ────────────────
  r = jobs.cancel(me(), closed, a.id);
  check(r.status === 202 && got.length === 1 && got[0].signal === "SIGINT" && got[0].argv.endsWith("suspend hold"), "Stop on a running job: SIGINT to its child (its process group)");
  await settle();
  check(a.state === "done" && a.exit === 130 && a.cancelled?.was === "running" && a.cancelled.signals.join() === "SIGINT", "…which ends on it: recorded as stopped, with its own exit code and the signal sent");
  check(!ran.some((x) => x.endsWith("suspend second")), "the cancelled queued job never ran");
  await sleep(60);
  check(got.length === 1, "a job that ended on SIGINT gets no SIGTERM after the grace period");
  r = jobs.cancel(me(), closed, a.id);
  check(r.status === 409, "an ended job: nothing to cancel (409)");
  check(!jobs.busy(), "the runner is idle again");

  // ── one that ignores SIGINT: SIGTERM after the grace period ─────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "suspend", "stubborn"], apply: true });
  const c = r.job!;
  await settle();
  jobs.cancel(me(), closed, c.id);
  r = jobs.cancel(me(), closed, c.id);
  check(r.status === 202 && got.filter((g) => g.argv.endsWith("stubborn")).length === 1, "asking twice sends nothing more");
  await settle();
  check(c.state === "running", "a child that ignores SIGINT is still running");
  await sleep(80);
  await settle();
  check(got.filter((g) => g.argv.endsWith("stubborn")).map((g) => g.signal).join() === "SIGINT,SIGTERM" && c.state === "done" && c.cancelled?.signals.join() === "SIGINT,SIGTERM", "…and gets SIGTERM after the grace period");
  check(/SIGTERM/.test(jobs.get(c.id)!.output), "…said in its output");

  // ── a stop during an Apply's dry run: the apply never runs ──────────
  const n0 = ran.length;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "modify", "hold", "--set", "memory=1"], apply: true });
  const d = r.job!;
  await settle();
  check(d.previewPhase?.exit === null && ran.at(-1)?.endsWith("--dry-run") === true, "an Apply runs its dry run first");
  jobs.cancel(me(), closed, d.id);
  await settle();
  check(d.state === "done" && /stopped by lars during the dry run/.test(d.previewPhase?.stopped ?? "") && ran.length === n0 + 1, "stopped in its dry run: the apply never runs");

  // ── streamAsync: the signal reaches the child's own children ────────
  let stop: ((s: StopSignal) => boolean) | null = null;
  let out = "";
  const p = streamAsync("sh", ["-c", "sleep 30 & echo $!; wait"], (c2) => (out += c2), 60_000, { onSpawn: (s) => (stop = s) });
  for (let i = 0; i < 100 && !/\d+/.test(out); i++) await sleep(20);
  const grandchild = Number(/(\d+)/.exec(out)?.[1] ?? 0);
  check(stop !== null && grandchild > 0, "streamAsync hands on the way to signal the child");
  const t0 = Date.now();
  (stop as unknown as (s: StopSignal) => boolean)("SIGTERM");
  const res = await p;
  await sleep(200); // the orphan is reaped by init
  let alive = true;
  try {
    process.kill(grandchild, 0);
  } catch {
    alive = false;
  }
  check(res.ran && Date.now() - t0 < 10_000 && !alive, `…to its whole process group: the shell's background sleep is gone too (rc ${res.rc})`);

  rmSync(dir, { recursive: true, force: true });
  done("jobcancel");
}

void main();
