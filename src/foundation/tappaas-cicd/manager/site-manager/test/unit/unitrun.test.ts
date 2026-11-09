// unitrun.test.ts — pure helpers of `site-manager update` (ADR-017 D4).
import { FOLLOW_LOST_AFTER_MS, FollowIO, JournalPoll, REATTACHED_NOTE, UnitProbe, buildRequest, followRun, repoStatusLine, splitCursor, summaryLine } from "../../src/unitrun";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

const r = buildRequest(true, false, false, "lars", new Date("2026-09-15T12:00:00Z"));
check(r.force && !r.allowDisruption && !r.noGitPull && r.requestedBy === "lars" && r.at === "2026-09-15T12:00:00.000Z",
  "buildRequest records options, who and when");
check(buildRequest(false, true, false, "lars", new Date()).allowDisruption === true,
  "--allow-disruption travels on its own, without --force");

check(summaryLine(null).startsWith("no last-update-result.json"), "no result file is said plainly");
check(summaryLine({ stage: "rebuild", end_time: "t" }).includes("FAILED in the rebuild step"), "a run that stopped before the sweep names the step");
{
  const s = summaryLine({ result: "interrupted", end_time: "t", succeeded: 12, failed: 0, not_attempted: 27,
    interrupted: { requestedBy: "erik" } });
  check(s.includes("STOPPED on request of erik") && s.includes("not_attempted=27") && s.includes("next update takes the rest"),
    "an interrupted run says who stopped it and what is left");
}
const line = summaryLine({ end_time: "t", control_plane: "refreshed", total: 10, succeeded: 10, failed: 0, not_attempted: 0, skipped: 1, reboot: "ok" });
check(line === "update-tappaas completed: t | control_plane=refreshed total=10 succeeded=10 failed=0 not_attempted=0 skipped=1 reboot=ok",
  "the summary matches update-tappaas's own last line");

check(repoStatusLine("T", "main", "a1", "a1", 0, null) === "T (main): current", "same tip: current");
check(repoStatusLine("T", "main", "a1", "b2b2b2b2b2", 3, null) === "T (main): 3 commit(s) behind origin", "behind: counted");
check(repoStatusLine("T", "main", "a1", "b2b2b2b2b2", null, null).includes("not fetched yet"), "unfetched tip: said so");
check(repoStatusLine("T", "main", "a1", null, null, null).includes("origin not reachable"), "no origin: drift unknown");
check(repoStatusLine("T", "main", null, null, null, "HELD until x").includes("HELD"), "a hold is shown instead of a probe");

// ── followRun: the run outlives the mothership's own switch ───────────────
// A scripted run: each probe/poll pops the next scripted answer. The journal is
// a list of lines; a poll returns those after the cursor (an index here).
check(splitCursor("a\nb\n-- cursor: s=1;i=2\n").text === "a\nb\n" && splitCursor("a\nb\n-- cursor: s=1;i=2\n").cursor === "s=1;i=2",
  "splitCursor separates the run's lines from journalctl's cursor");
check(splitCursor("-- cursor: c9").text === "" && splitCursor("-- cursor: c9").cursor === "c9", "splitCursor: no new lines, cursor only");
check(splitCursor("").cursor === null && splitCursor("x\n").text === "x\n", "splitCursor: nothing read yet");

interface Script {
  probes: Array<Partial<UnitProbe>>; // one per probe; the last repeats
  journal: string[]; // lines in the journal, grown by `grow` per poll
  grow?: number[]; // how many lines the journal holds at each poll
  pollFails?: Set<number>; // poll numbers (0-based) that fail
  intAtSleep?: number; // the sleep (0-based) Ctrl-C reaches
  intAtPoll?: number;
  clockStep?: number; // ms per probe
}
function simulate(sc: Script, inv = "inv-1"): { end: string; out: string; notes: string[]; polls: Array<string | null> } {
  let probeN = 0, pollN = 0, sleepN = 0, clock = 0;
  let out = "";
  const notes: string[] = [];
  const polls: Array<string | null> = [];
  const io: FollowIO = {
    probe: () => {
      const p = sc.probes[Math.min(probeN++, sc.probes.length - 1)];
      clock += sc.clockStep ?? 1000;
      return { ok: true, state: "active", invocation: inv, ...p };
    },
    poll: (after): JournalPoll => {
      const n = pollN++;
      polls.push(after);
      if (sc.intAtPoll === n) return { ok: false, text: "", cursor: after, interrupted: true };
      if (sc.pollFails?.has(n)) return { ok: false, text: "", cursor: after };
      const have = sc.grow ? sc.grow[Math.min(n, sc.grow.length - 1)] : sc.journal.length;
      const from = after === null ? 0 : Number(after) + 1;
      const lines = sc.journal.slice(from, have);
      if (have === 0) return { ok: true, text: "", cursor: null };
      return { ok: true, text: lines.map((l) => l + "\n").join(""), cursor: String(have - 1) };
    },
    sleep: () => sc.intAtSleep === sleepN++,
    write: (t) => { out += t; },
    note: (l) => notes.push(l),
    now: () => clock,
  };
  return { end: followRun(inv, io), out, notes, polls };
}
const lines = (n: number): string[] => Array.from({ length: n }, (_, i) => `line ${i + 1}`);
const all = (n: number): string => lines(n).map((l) => l + "\n").join("");
{
  // The old follower ended here: one failed `systemctl show` while PID 1 re-executes.
  const r = simulate({
    probes: [{}, {}, { ok: false }, { ok: false }, {}, {}, { state: "inactive" }],
    journal: lines(9), grow: [1, 2, 3, 4, 6, 7, 8, 9],
  });
  check(r.end === "finished", "a failed systemd query mid-run is a hiccup, not the run's end");
  check(r.out === all(9), `every line is shown once, in order, across the hiccup (got ${JSON.stringify(r.out)})`);
  check(r.notes.length === 1 && r.notes[0] === REATTACHED_NOTE, "exactly one line says it is still following");
}
{
  const r = simulate({ probes: [{}, {}, {}, { state: "inactive" }], journal: lines(5), grow: [1, 3, 4, 4, 5] });
  check(r.end === "finished" && r.out === all(5), "a plain run: all lines, finished");
  check(r.notes.length === 0, "a plain run prints no re-attach line");
  check(r.polls[r.polls.length - 1] !== null && r.out.endsWith("line 5\n"), "the lines journald writes after the unit stops are drained");
}
{
  // journalctl fails while journald restarts: the next poll starts from the same cursor.
  const r = simulate({ probes: [{}, {}, {}, {}, { state: "inactive" }], journal: lines(6), grow: [2, 3, 4, 5, 6], pollFails: new Set([1, 2]) });
  check(r.out === all(6), "a failed journal read loses and repeats nothing");
  check(r.polls[1] === r.polls[2] && r.polls[2] === r.polls[3], "a failed read retries from the same cursor");
  check(r.notes.length === 1, "a failed journal read is noted once, when the run is seen again");
}
{
  const r = simulate({ probes: [{}, { ok: false }, {}, { ok: false }, {}, { state: "failed" }], journal: lines(3) });
  check(r.end === "finished" && r.notes.length === 1, "two hiccups: still one note");
}
{
  const r = simulate({ probes: [{}, { invocation: "inv-2" }], journal: lines(2) });
  check(r.end === "finished", "a newer invocation means ours is over");
}
{
  const r = simulate({ probes: [{}], journal: lines(2), intAtSleep: 1 });
  check(r.end === "detached" && r.out === all(2), "Ctrl-C during the wait detaches");
  const r2 = simulate({ probes: [{}], journal: lines(2), intAtPoll: 2 });
  check(r2.end === "detached", "Ctrl-C during a journal read detaches");
  const r3 = simulate({ probes: [{}, { ok: false, interrupted: true }], journal: lines(2) });
  check(r3.end === "detached", "Ctrl-C during a systemd query detaches");
}
{
  const r = simulate({ probes: [{}, { ok: false }], journal: lines(1), clockStep: 60 * 1000 });
  check(r.end === "lost", "systemd unreachable for minutes: the follower gives up, as 'lost'");
  const r2 = simulate({
    probes: [...Array.from({ length: 4 }, () => ({ ok: false })), {}, ...Array.from({ length: 4 }, () => ({ ok: false })), { state: "inactive" }],
    journal: lines(1), clockStep: FOLLOW_LOST_AFTER_MS / 5,
  });
  check(r2.end === "finished", "the unreachable clock restarts each time systemd answers");
}

console.log(`unitrun: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
