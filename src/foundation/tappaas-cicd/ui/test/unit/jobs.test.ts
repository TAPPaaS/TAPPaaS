// jobs.test.ts — the job model (ADR-034 D4): the state machine of a job,
// preview before apply (T3), the role table on every write (T1), the setup
// token's write (T6), the destructive confirmation, the sweep refusal, the one
// serial runner, Activity's jobs.jsonl, and the HTTP routes over them
// (application/json only, server-sent events).

import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig, Me, SetupState } from "../../src/access";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { Job, JobSummary, Jobs, RESTART_MARKER, parseUnitShow, previewStop, shellQuote, sweepBlocks, takeRestartMarker } from "../../src/jobs";
import { Manifests } from "../../src/manifest";
import { Reads } from "../../src/reads";
import { Runner, Streamer } from "../../src/run";
import { ConsoleServer } from "../../src/server";
import { gateHeaders, testGate } from "./gate-fixture";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

const SPEC: HelpSpec = {
  name: "module-manager",
  version: "1",
  tagline: "t",
  verbs: [
    { usage: "list [--json]" },
    { usage: "test <module> [--deep]", options: [["--deep", "The deep suite."]] },
    { usage: "modify <module> --set field=value... [--allow-disruption]", options: [["--set field=value", "A field."], ["--dry-run", "Pre-gate."], ["--allow-disruption", "Reboot it now."]] },
    { usage: "reconcile <module> [--apply]", options: [["--apply", "Apply."]] },
    { usage: "suspend <module>", effect: { noPreview: "stops the guest and keeps it stopped" } },
    { usage: "delete <module> [--remove]", effect: { noPreview: "destroys the guest" }, options: [["--remove", "Remove the config."]] },
    { usage: "remove-port <switch> <port>", effect: { noPreview: "parks the port" }, object: { positional: "port", within: ["switch"] } },
  ],
};

const me = (over: Partial<Me> = {}): Me => ({ user: "lars", name: "Lars", email: null, groups: ["installer"], role: "installer", via: "gate", route: "console", ...over });
const closed: SetupState = { active: false, identityInstalled: true, tokenPresent: false };
const open_: SetupState = { active: true, identityInstalled: false, tokenPresent: true };

async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise<void>((r) => setTimeout(r, 1));
}

async function main(): Promise<void> {
  // ── the sweep predicate and the unit's state read ───────────────────
  check(sweepBlocks("active") && sweepBlocks("activating") && sweepBlocks("deactivating\n"), "an active, starting or stopping sweep blocks jobs");
  check(!sweepBlocks("inactive") && !sweepBlocks("failed"), "an inactive or failed unit does not");
  const u = parseUnitShow("ActiveState=activating\nActiveEnterTimestamp=Sat 2026-10-17 03:00:01 CEST\n");
  check(u.state === "activating" && u.since === "Sat 2026-10-17 03:00:01 CEST", "systemctl show is read for state and since");
  check(parseUnitShow("ActiveState=inactive\nActiveEnterTimestamp=n/a\n").since === null, "n/a is no time");
  check(shellQuote(["switch-manager", "update-port", "USW Pro XG 10 PoE", "1"]) === "switch-manager update-port 'USW Pro XG 10 PoE' 1", "the argv as one types it, quoted where it must be");

  // ── a site to run against ───────────────────────────────────────────
  const dir = mkdtempSync(join(tmpdir(), "console-jobs-"));
  let unit = "inactive";
  const ran: string[] = [];
  let release: (() => void) | null = null; // hold a job running until released
  const stream: Streamer = async (bin, args, onOutput) => {
    ran.push([bin, ...args].join(" "));
    onOutput(`ran ${args[0]}\n`);
    if (args.includes("refuseme") && args.includes("--dry-run")) onOutput("[refused] memory=1 is below the module's floor\n");
    if (args.includes("hold")) await new Promise<void>((r) => (release = r));
    if (args[0] === "reconcile" && args.includes("pending") && !args.includes("--apply")) onOutput("1 change(s) pending. Re-run with --apply.\n");
    const rc = args.includes("--dry-run") && args.includes("vmid=1") ? 1 : args[0] === "reconcile" && args.includes("pending") && !args.includes("--apply") ? 2 : args[0] === "reconcile" && args.includes("stale") && !args.includes("--apply") ? 1 : 0;
    return { rc, ran: true, error: null };
  };
  const run: Runner = async (bin, args) =>
    bin === "systemctl" && args[0] === "show"
      ? { rc: 0, stdout: `ActiveState=${unit}\nActiveEnterTimestamp=Sat 2026-10-17 03:00:01 CEST\n`, stderr: "", ran: true }
      : { rc: 1, stdout: "", stderr: "", ran: false };
  const ms: Manifests = { byBin: new Map([["module-manager", renderManifest(SPEC)]]), errors: [], loadedAt: "" };
  let now = Date.parse("2026-10-17T12:00:00Z");
  const done_: JobSummary[] = [];
  let idle = 0;
  const finished: { argv: string; kind: string; tail: string }[] = [];
  const jobs = new Jobs({ stateDir: dir, configDir: dir, manifests: () => ms, stream, run, now: () => now, onWriteDone: (j) => done_.push(j), onIdle: () => idle++, onDone: (j, tail) => finished.push({ argv: j.argv.join(" "), kind: j.kind, tail }) });

  // ── T2 at the door, then T1 on every write ──────────────────────────
  let r = await jobs.create(me(), closed, { argv: ["module-manager", "frob"], preview: true });
  check(r.status === 400 && !r.job, "an undeclared verb never becomes a job (T2)");
  r = await jobs.create(me({ via: "local", user: null, role: "read" }), closed, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 403 && !r.job, "loopback without the gate starts no job");
  r = await jobs.create(me({ role: "read", groups: ["users"] }), closed, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 403, "a member of users starts no job (T1)");

  // ── preview before apply (T3) ───────────────────────────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "immich", "--apply"] });
  check(r.status === 409 && !r.job, "a write without a preview is refused (T3)");
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "immich", "--apply"], preview: true });
  check(r.status === 201 && r.job?.kind === "preview" && r.job.ran?.join(" ") === "module-manager reconcile immich", "the preview runs the verb without --apply");
  const p1 = r.job!;
  r = await jobs.applyPreview(me(), closed, p1.id, {});
  check(r.status === 409 && /not finished/.test(r.error ?? ""), "apply waits for its preview to finish");
  await settle();
  check(p1.state === "done" && p1.exit === 0 && jobs.get(p1.id)!.output.includes("ran reconcile"), "the preview ran and its output is kept");
  r = await jobs.applyPreview(me(), closed, p1.id, {});
  check(r.status === 201 && r.job?.ran?.join(" ") === "module-manager reconcile immich --apply" && r.job.previewOf === p1.id, "apply runs the previewed argv plus --apply (T3)");
  await settle();
  check(done_.length === 1 && done_[0].kind === "apply", "a finished apply asks for the reads to be refreshed");

  r = await jobs.create(me(), closed, { argv: ["module-manager", "modify", "deconz-test", "--set", "memory=2048"], preview: true });
  check(r.job?.ran?.join(" ") === "module-manager modify deconz-test --set memory=2048 --dry-run", "modify previews through its pre-gate (--dry-run)");
  await settle();
  r = await jobs.applyPreview(me(), closed, r.job!.id, {});
  check(r.job?.ran?.join(" ") === "module-manager modify deconz-test --set memory=2048", "…and applies without it");
  await settle();

  r = await jobs.create(me(), closed, { argv: ["module-manager", "suspend", "deconz-test"], preview: true });
  const ns = r.job!;
  const nsOut = jobs.get(ns.id)!.output;
  check(ns.state === "done" && ns.ran === null && /no dry run/.test(nsOut) && /stops the guest/.test(nsOut), "no dry run: the preview runs nothing, says what the verb touches and shows the command");
  check(!ran.some((x) => x.includes("suspend")), "…and nothing ran");

  now += 2 * 3600_000;
  r = await jobs.applyPreview(me(), closed, ns.id, {});
  check(r.status === 409 && /hour/.test(r.error ?? ""), "a preview older than an hour does not enable apply");

  // ── destructive: Installer and the typed name (D3) ──────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "delete", "deconz-test", "--remove"], preview: true });
  check(r.status === 201 && r.job?.destructive === true, "the installer previews a destructive verb");
  const del = r.job!;
  r = await jobs.applyPreview(me({ role: "read", groups: ["admin"] }), closed, del.id, { confirm: "deconz-test" });
  check(r.status === 403, "a caller outside installer may not apply it, name or no name (T1)");
  r = await jobs.applyPreview(me({ role: "installer" }), closed, del.id, { confirm: "deconz-te" });
  check(r.status === 400 && /type 'deconz-test'/.test(r.error ?? ""), "Installer with the wrong name: refused");
  r = await jobs.applyPreview(me({ role: "installer" }), closed, del.id, {});
  check(r.status === 400, "Installer without the name: refused");
  r = await jobs.applyPreview(me({ role: "installer" }), closed, del.id, { confirm: "deconz-test" });
  check(r.status === 201 && r.job?.ran?.join(" ") === "module-manager delete deconz-test --remove", "Installer with the typed name: applied");
  await settle();
  // #855: a verb that names its object is confirmed by it, not by its first positional.
  for (const typed of ["1", "USW Pro XG 10 PoE:1"]) {
    r = await jobs.create(me(), closed, { argv: ["module-manager", "remove-port", "USW Pro XG 10 PoE", "1"], preview: true });
    const rp = r.job!;
    check(rp.object === "1" && rp.objectLabel === "USW Pro XG 10 PoE:1", "the job names the port, shown within its switch");
    r = await jobs.applyPreview(me({ role: "installer" }), closed, rp.id, { confirm: "USW Pro XG 10 PoE" });
    check(r.status === 400 && /type '1' to confirm \(USW Pro XG 10 PoE:1\)/.test(r.error ?? ""), "the switch's name does not confirm a port's removal");
    r = await jobs.applyPreview(me({ role: "installer" }), closed, rp.id, { confirm: typed });
    check(r.status === 201, `typed '${typed}': applied`);
    await settle();
  }

  // ── the setup token (T6) ────────────────────────────────────────────
  const tok = me({ user: "setup", via: "setup-token", role: "installer", groups: [] });
  r = await jobs.create(tok, open_, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 201, "the setup token previews while setup is open");
  await settle();
  r = await jobs.applyPreview(tok, closed, r.job!.id, {});
  check(r.status === 401, "…and applies nothing once identity is installed (T6)");

  // ── reads run at once, beside the queue ─────────────────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "test", "immich"] });
  check(r.status === 201 && r.job?.kind === "read" && r.job.ran?.join(" ") === "module-manager test immich", "a reading verb runs as a read job, no preview");
  await settle();
  const f = finished.find((x) => x.argv === "module-manager test immich");
  check(f !== undefined && f.kind === "read" && f.tail === "ran test", "a finished read job is handed on with the end of its output (onDone)");
  // …but test --deep creates and removes guests: a write with no dry run (finding 3)
  r = await jobs.create(me(), closed, { argv: ["module-manager", "test", "immich", "--deep"] });
  check(r.status === 409 && !r.job, "test --deep is not a read: it needs a preview (T3)");
  r = await jobs.create(me(), closed, { argv: ["module-manager", "test", "immich", "--deep"], preview: true });
  const deep = r.job!;
  check(r.status === 201 && deep.kind === "preview" && deep.ran === null && deep.preview.kind === "none" && /runs the deep suite: creates and removes zztest guests/.test(jobs.get(deep.id)!.output), "…its preview runs nothing and says it creates and removes guests");
  r = await jobs.applyPreview(me(), closed, deep.id, {});
  check(r.status === 201 && r.job?.kind === "apply" && r.job.ran?.join(" ") === "module-manager test immich --deep", "…and its apply queues the deep suite as a change");
  await settle();

  // ── Apply straight from the form: the dry run, then the apply, one job ──
  let n0 = ran.length; // before the create: its runner may start at once
  r = await jobs.create(me(), closed, { argv: ["module-manager", "modify", "deconz-test", "--set", "memory=4096"], apply: true });
  const two = r.job!;
  check(r.status === 201 && two.kind === "apply" && two.previewPhase?.ran.join(" ") === "module-manager modify deconz-test --set memory=4096 --dry-run" && two.ran?.join(" ") === "module-manager modify deconz-test --set memory=4096", "Apply without a preview: one apply job that carries its dry run");
  await settle();
  check(two.state === "done" && two.exit === 0 && two.previewPhase?.exit === 0 && two.previewPhase.stopped === null, "a clean dry run goes straight on to the apply");
  check(ran.slice(n0).join("|") === "module-manager modify deconz-test --set memory=4096 --dry-run|module-manager modify deconz-test --set memory=4096", `…the dry run ran first, then the apply, nothing between (${ran.slice(n0).join("|")})`);
  const twoOut = jobs.get(two.id)!.output;
  check(twoOut === "ran modify\nran modify\n" && two.previewPhase!.outputLength === "ran modify\n".length, "…both outputs in the job's log, the dry run's length recorded");
  check(done_.at(-1)?.id === two.id, "…and the reads are refreshed after it");
  const twoRec = readFileSync(jobs.file, "utf8").trim().split("\n").map((l) => JSON.parse(l) as JobSummary).filter((l) => l.id === two.id).at(-1)!;
  check(twoRec.previewPhase?.exit === 0 && twoRec.exit === 0, "Activity's record holds both phases");

  n0 = ran.length;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "modify", "deconz-test", "--set", "vmid=1"], apply: true });
  const failed = r.job!;
  await settle();
  check(failed.state === "done" && failed.exit === 1 && /exit 1/.test(failed.previewPhase?.stopped ?? "") && ran.length === n0 + 1, "a failing dry run stops the job: the apply never runs");
  check(jobs.get(failed.id)!.output === "ran modify\n" && done_.at(-1)?.id !== failed.id, "…its output is the dry run's alone, and nothing was written");

  n0 = ran.length;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "modify", "refuseme", "--set", "memory=1"], apply: true });
  const ref_ = r.job!;
  await settle();
  check(ref_.exit === 0 && /refuses this change: memory=1 is below/.test(ref_.previewPhase?.stopped ?? "") && ran.length === n0 + 1, "a dry run that reports a refusal stops the job, even on exit 0");

  n0 = ran.length;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "pending"], apply: true });
  const pend = r.job!;
  await settle();
  check(pend.previewPhase?.kind === "apply-flag" && pend.previewPhase.exit === 2 && pend.previewPhase.stopped === null && pend.exit === 0 && ran.slice(n0).join("|") === "module-manager reconcile pending|module-manager reconcile pending --apply", "a reconcile preview that exits 2 (changes pending) goes on to the apply");
  n0 = ran.length;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "stale"], apply: true });
  const stale = r.job!;
  await settle();
  check(/exit 1/.test(stale.previewPhase?.stopped ?? "") && ran.length === n0 + 1, "…but one that exits 1 (a device could not be read) still stops the job");
  check(previewStop(true, 2, "", false) !== null && previewStop(true, 2, "", true) === null && previewStop(true, 1, "", true) !== null, "exit 2 is pending for an apply-flag preview only");

  n0 = ran.length;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "suspend", "deconz-test"], apply: true });
  const nodry = r.job!;
  await settle();
  check(nodry.previewPhase === undefined && nodry.exit === 0 && ran.slice(n0).join("|") === "module-manager suspend deconz-test", "a verb with no dry run applies at once, as after its preview");

  r = await jobs.create(me({ role: "read", groups: ["admin"] }), closed, { argv: ["module-manager", "delete", "deconz-test", "--remove"], apply: true, confirm: "deconz-test" });
  check(r.status === 403 && !r.job, "a destructive Apply is the installer's");
  r = await jobs.create(me({ role: "installer" }), closed, { argv: ["module-manager", "delete", "deconz-test", "--remove"], apply: true });
  check(r.status === 400 && /type 'deconz-test'/.test(r.error ?? "") && !r.job, "…with the name typed before anything runs");
  r = await jobs.create(me({ role: "installer" }), closed, { argv: ["module-manager", "delete", "deconz-test", "--remove"], apply: true, confirm: "deconz-test" });
  check(r.status === 201 && r.job?.ran?.join(" ") === "module-manager delete deconz-test --remove", "…and then applied");
  await settle();

  // ── the sweep (D4) ──────────────────────────────────────────────────
  unit = "active";
  writeFileSync(join(dir, ".update-stage"), "modules\n");
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 409 && r.job?.state === "refused" && /sweep is running/.test(r.job.refused ?? "") && /stage: modules/.test(r.job.refused ?? ""), "while update-tappaas.service runs, no job starts, and it says so");
  check(r.sweep?.active === true, "…with the sweep's state");
  unit = "inactive";

  // ── one at a time, in order ─────────────────────────────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "hold"], preview: true });
  const a = r.job!;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "second"], preview: true });
  const b = r.job!;
  await settle();
  check(a.state === "running" && b.state === "queued" && jobs.queued().join() === `${a.id},${b.id}`, "a second write queues behind the first, and the queue is visible");
  check(jobs.busy(), "…and the runner says it is busy");
  const lock = JSON.parse(readFileSync(jobs.lockFile, "utf8")) as { id: string; pid: number; argv: string[] };
  check(lock.id === a.id && lock.pid === process.pid && lock.argv.join(" ") === "module-manager reconcile hold", "the runner holds the job lock while a write runs: the job, its argv, the console's pid (for the sweep to wait on)");
  // the running record (finding 1): a job is in jobs.jsonl from the moment it starts…
  const running = readFileSync(jobs.file, "utf8").trim().split("\n").map((l) => JSON.parse(l) as JobSummary);
  check(running.some((l) => l.id === a.id && l.state === "running" && l.started !== null), "a job is recorded as running when it starts");
  // …so a console that stops on it reads it back as cut off (its own lock file: this
  // one's lock is held by the same pid, which a real restart never sees)
  const restarted = new Jobs({ stateDir: dir, configDir: dir, lockFile: join(dir, "restarted.lock"), manifests: () => ms, stream, run });
  const cut = restarted.get(a.id)!;
  check(cut.state === "done" && cut.interrupted === true && cut.exit === null && /cut off/.test(cut.output), "…and a console started while it ran shows it as cut off, with a note in its output");
  check(!restarted.busy(), "a fresh runner is idle");
  const idleBefore = idle;
  unit = "active"; // the sweep starts while b waits
  (release as unknown as () => void)();
  await settle();
  check(a.state === "done" && b.state === "refused" && /sweep/.test(b.refused ?? ""), "a queued job is refused if the sweep has started when its turn comes");
  check(!jobs.busy() && idle === idleBefore + 1, "when the last job ends the runner says so once (onIdle)");
  check(!existsSync(jobs.lockFile), "…and the lock is released");
  unit = "inactive";
  // a lock a dead console left (it stopped mid-job) is removed at start; a live console's is not
  const ldir = mkdtempSync(join(tmpdir(), "console-jobs-lock-"));
  writeFileSync(join(ldir, "console-job.lock"), JSON.stringify({ id: "x", pid: 4194305 }));
  new Jobs({ stateDir: ldir, configDir: ldir, manifests: () => ms, stream, run });
  check(!existsSync(join(ldir, "console-job.lock")), "a stale lock (its console gone) is removed at start");
  writeFileSync(join(ldir, "console-job.lock"), JSON.stringify({ id: "y", pid: process.ppid }));
  new Jobs({ stateDir: ldir, configDir: ldir, manifests: () => ms, stream, run });
  check(existsSync(join(ldir, "console-job.lock")), "a lock whose console runs is left alone");
  rmSync(ldir, { recursive: true, force: true });

  // ── a deferred restart: install.sh leaves the marker, the console takes it when idle ──
  check(!takeRestartMarker(dir), "no marker: nothing to take");
  writeFileSync(join(dir, RESTART_MARKER), "");
  check(takeRestartMarker(dir) && !existsSync(join(dir, RESTART_MARKER)) && !takeRestartMarker(dir), "the marker is taken once and removed");

  // ── Activity: jobs.jsonl and jobs/<id>.log ──────────────────────────
  const lines = readFileSync(jobs.file, "utf8").trim().split("\n").map((l) => JSON.parse(l) as JobSummary & { output?: string });
  const p1Lines = lines.filter((l) => l.id === p1.id);
  const first = p1Lines[p1Lines.length - 1]; // the last line of an id is its record (the first says "running")
  check(p1Lines.length === 2 && p1Lines[0].state === "running" && first.who.user === "lars" && first.who.via === "gate" && first.route === "console" && first.exit === 0 && typeof first.durationMs === "number" && !("output" in first), "every job is a summary line in jobs.jsonl when it starts and when it ends: who, via, route, argv, exit, duration — not its output");
  check(readFileSync(join(dir, "jobs", `${p1.id}.log`), "utf8").includes("ran reconcile"), "…the output is in jobs/<id>.log, read on demand");
  check(lines.some((l) => l.state === "refused"), "refused jobs are recorded too");
  const again = new Jobs({ stateDir: dir, configDir: dir, manifests: () => ms, stream, run });
  check(again.list().length === new Set(lines.map((l) => l.id)).size && again.get(p1.id)?.exit === 0 && again.get(p1.id)?.output.includes("ran reconcile") === true, "a restarted console reads its jobs back, each output from its log");

  // ── rotation: past the size limit, the last N summaries are kept ────
  const rdir = mkdtempSync(join(tmpdir(), "console-jobs-rot-"));
  const small = new Jobs({ stateDir: rdir, configDir: rdir, manifests: () => ms, stream, run, now: () => now, keep: 3, rotateAtBytes: 2000 });
  const ids: string[] = [];
  for (let i = 0; i < 8; i++) {
    const x = await small.create(me(), closed, { argv: ["module-manager", "suspend", `m${i}`], preview: true });
    ids.push(x.job!.id);
  }
  const left = readFileSync(small.file, "utf8").trim().split("\n").map((l) => (JSON.parse(l) as JobSummary).id);
  check(left.length <= 4 && left.includes(ids[7]) && !left.includes(ids[0]), `past the size limit jobs.jsonl is rewritten with the kept summaries (${left.length} lines)`);
  check(!existsSync(join(rdir, "jobs", `${ids[0]}.log`)) && existsSync(join(rdir, "jobs", `${ids[7]}.log`)), "…and the logs of the jobs no longer kept are removed");
  check(small.list().length === 3 && small.get(ids[7])!.output.includes("no dry run") && small.get(ids[0]) === null, "the console holds the kept summaries, each output from disk");
  rmSync(rdir, { recursive: true, force: true });

  // ── the HTTP routes ─────────────────────────────────────────────────
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "tok"), identityFile: join(dir, "identity.json"), trustLocalHeaders: false, gate: testGate() };
  writeFileSync(access.identityFile, "{}");
  const site = fakeSite();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7 });
  const srv = new ConsoleServer({ access, webDir: null, mgmtDomain: "mgmt.internal", version: "t", log: () => undefined }, reads, jobs);
  srv.manifests = ms;
  const call = async (method: string, url: string, body: unknown, headers: Record<string, string>, peer = "10.0.0.1") => {
    const h: Record<string, string> = {};
    let out = "";
    const res = {
      statusCode: 200,
      headersSent: false,
      setHeader: (n: string, v: string | number | string[]) => (h[n.toLowerCase()] = String(v)),
      write: (d: string) => ((out += d), true),
      end: (d?: string) => ((out += d ?? ""), (res.headersSent = true)),
      on: () => res,
    };
    const handlers: Record<string, ((x?: unknown) => void)[]> = {};
    const req = {
      method,
      url,
      headers: { host: "console.hrossen.dk", ...headers },
      socket: { remoteAddress: peer, destroy: () => undefined },
      on: (ev: string, cb: (x?: unknown) => void) => ((handlers[ev] ??= []).push(cb), req),
    };
    const p = srv.handle(req as unknown as IncomingMessage, res as unknown as ServerResponse);
    if (body !== undefined) for (const cb of handlers.data ?? []) cb(Buffer.from(JSON.stringify(body)));
    for (const cb of handlers.end ?? []) cb();
    await p;
    return { status: res.statusCode, body: out, headers: h };
  };
  const gateH = (groups: string, host = "console.hrossen.dk") => ({ ...gateHeaders("lars", groups, host), "content-type": "application/json" });
  let h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, { ...gateH("installer"), "content-type": "text/plain" });
  check(h.status === 415, "a job posted as anything but JSON is refused (no cross-site form)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, { "content-type": "application/json" }, "127.0.0.1");
  check(h.status === 403, "POST /jobs from loopback without the gate: 403");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, gateH("users"));
  check(h.status === 403, "POST /jobs as users: 403 (T1)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, gateH("installer", "status.hrossen.dk"));
  check(h.status === 403, "POST /jobs on the status route, even as Installer: 403 (T1)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich", "--purge"], preview: true }, gateH("installer"));
  check(h.status === 400 && /unknown option/.test(h.body), "an undeclared option: 400 before a job exists (T2)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, gateH("installer"));
  const pj = JSON.parse(h.body).data as Job;
  check(h.status === 201 && pj.kind === "preview" && pj.who.user === "lars", "POST /jobs as the installer through the gate: the preview starts");
  await settle();
  h = await call("GET", `/api/v1/jobs/${pj.id}`, undefined, { ...gateH("installer"), accept: "text/event-stream" });
  check(h.headers["content-type"]?.startsWith("text/event-stream") && /event: job/.test(h.body) && /event: end/.test(h.body), "GET /jobs/<id> as an event stream: the job, then its end");
  h = await call("POST", `/api/v1/jobs/${pj.id}/apply`, {}, gateH("installer"));
  check(h.status === 201 && (JSON.parse(h.body).data as Job).ran?.includes("--apply") === true, "POST /jobs/<id>/apply runs the preview's argv with --apply");
  await settle();
  h = await call("GET", "/api/v1/jobs", undefined, gateH("users"));
  check(h.status === 403, "GET /jobs as users: 403, the console is the installer's");
  h = await call("GET", "/api/v1/jobs", undefined, gateH("installer"));
  check(h.status === 200 && (JSON.parse(h.body).data.jobs as Job[]).length > 0, "GET /jobs is a read: the installer sees the jobs");
  h = await call("GET", "/api/v1/activity", undefined, gateH("installer"));
  check(Array.isArray(JSON.parse(h.body).jobs), "Activity lists the jobs beside the sweep's journal");
  check(existsSync(jobs.file), "jobs.jsonl is in the state directory");

  rmSync(dir, { recursive: true, force: true });
  done("jobs");
}

void main();
