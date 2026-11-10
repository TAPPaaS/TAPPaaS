// perf.test.ts — timed raises of a CI's performance level (ADR-046 D3, P2):
// --until is required, trace only this way, a raise replaces one in force,
// stop and expiry end it, each is recorded on the CI, the pipeline rewritten,
// and `perf list --json` keeps the console's contract.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { PerfContext, PerfError, perfExpire, perfList, perfRaise, perfStop } from "../../src/perf";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}
function throws(f: () => unknown, re: RegExp, msg: string): void {
  try {
    f();
    check(false, `${msg} (did not throw)`);
  } catch (e) {
    check(e instanceof PerfError && re.test(e.message), `${msg} (${e instanceof Error ? e.message : String(e)})`);
  }
}

const IDENTITY = { id: "7fa7910d-f316-43b7-8660-7ec3e5a27831", class: "vm", name: "identity", attributes: {} };
const POOL = { id: "0a7d1804-da8c-415e-879c-b077276ae2cd", class: "storage-pool", name: "tankc1", attributes: {} };

function fake(now: Date): PerfContext & { tracesCalls: number; records: { verb: string; inv: unknown }[]; applied: string[]; purged: string[]; lines: string[] } {
  const dir = mkdtempSync(join(tmpdir(), "perf-test-"));
  writeFileSync(join(dir, "identity.json"), JSON.stringify({ kind: "vm", environment: "mgmt" }));
  let change = 1900;
  const c = {
    configDir: dir,
    now,
    actor: "lars",
    records: [] as { verb: string; inv: unknown }[],
    applied: [] as string[],
    purged: [] as string[],
    lines: [] as string[],
    resolve: (ref: string) => {
      if (ref === "identity" || ref === IDENTITY.id) return IDENTITY;
      if (ref === "tankc1") return POOL;
      throw new Error(`${ref} is not a live object`);
    },
    record: (_ci: unknown, inv: Record<string, unknown> | null, verb: string) => {
      c.records.push({ verb, inv });
      return ++change;
    },
    cascade: () => ({ from: "basic", source: "site" }),
    apply: (m: string) => {
      c.applied.push(m);
      return { ok: true, lines: ["changed", `${m}: level x`] };
    },
    tracesCalls: 0,
    traces: () => {
      c.tracesCalls++;
      return { ok: true, lines: ["traces: Tempo on, Grafana's spans off"] };
    },
    purge: (id: string) => {
      c.purged.push(id);
      return { ok: true, lines: ["deleted"] };
    },
    say: (l: string) => void c.lines.push(l),
    warn: (l: string) => void c.lines.push(`WARN ${l}`),
  };
  return c;
}

const T0 = new Date("2026-11-01T07:40:12Z");
const at = (min: number): Date => new Date(T0.getTime() + min * 60000);

// The refusals.
{
  const c = fake(T0);
  throws(() => perfRaise(c, { ref: "identity", level: "trace", until: undefined }), /--until is required/, "a raise without --until is refused");
  throws(() => perfRaise(c, { ref: "identity", level: "off", until: at(60).toISOString() }), /basic, service or trace/, "--level off is not a raise");
  throws(() => perfRaise(c, { ref: "identity", level: "basic", until: at(-5).toISOString() }), /already passed/, "an --until in the past is refused");
  throws(() => perfRaise(c, { ref: "identity", level: "basic", resolution: "coarse", until: at(60).toISOString() }), /takes fine/, "--resolution takes fine only");
  throws(() => perfStop(c, "identity"), /no investigation/, "stop with nothing raised says so");
  check(c.records.length === 0 && c.applied.length === 0, "a refusal records and applies nothing");
}

// A raise, an extend, a stop.
{
  const c = fake(T0);
  const r = perfRaise(c, { ref: "identity", level: "trace", resolution: "fine", until: at(180).toISOString(), note: "logins slow since the update" });
  check(r.module === "identity" && c.applied[0] === "identity", "the guest's pipeline is rewritten");
  check(r.from === "basic" && r.level === "trace" && r.resolution === "fine", "from, level and resolution are recorded");
  check(c.records[0].verb === "perf identity --level trace --resolution fine --until 2026-11-01T10:40:12Z", `the change's verb names it (${c.records[0].verb})`);
  check((c.records[0].inv as { level?: string }).level === "trace", "the CI's investigation is set");
  check(c.lines.some((l) => /raised to trace, every 15 seconds, until 2026-11-01T10:40:12Z \(it was basic\)/.test(l)), "it says what it did");
  let d = perfList(c.configDir, at(1));
  check(d.investigations.length === 1 && d.investigations[0].change === 1901 && d.investigations[0].ci.name === "identity", "list shows it with its change");
  check(!("module" in d.investigations[0]), "the contract carries no module field");
  // Extend: the same level, later; started and the note stay.
  c.now = at(30);
  perfRaise(c, { ref: "identity", level: "trace", resolution: "fine", until: at(300).toISOString() });
  d = perfList(c.configDir, at(31));
  check(d.investigations.length === 1 && d.investigations[0].until === "2026-11-01T12:40:12Z" && d.investigations[0].started === "2026-11-01T07:40:12Z", "extend replaces the raise, keeps its start");
  check(d.investigations[0].note === "logins slow since the update", "extend keeps the note");
  c.now = at(60);
  perfStop(c, "identity");
  d = perfList(c.configDir, at(61));
  check(d.investigations.length === 0 && d.history.length === 1, "stop moves it to history");
  check(d.history[0].endedHow === "stopped" && d.history[0].endedBy === "lars" && d.history[0].ended === "2026-11-01T08:40:12Z", "how, who and when it ended");
  check(c.records[c.records.length - 1].inv === null && c.records[c.records.length - 1].verb === "perf stop identity", "the CI's investigation is unset");
  check(c.applied.length === 3, "every change rewrites the pipeline");
}

// Expiry: by itself, past its time; list reads a lapsed one as expired before emit ran.
{
  const c = fake(T0);
  perfRaise(c, { ref: "identity", level: "service", until: at(30).toISOString() });
  check(perfExpire({ ...c, now: at(29) }).length === 0, "nothing expires before its time");
  const d0 = perfList(c.configDir, at(31));
  check(d0.investigations.length === 0 && d0.history[0]?.endedHow === "expired", "list shows a lapsed raise as expired");
  const ended = perfExpire({ ...c, now: at(31) });
  check(ended.length === 1, "emit's expiry ends it");
  const d = perfList(c.configDir, at(32));
  check(d.history.length === 1 && d.history[0].ended === "2026-11-01T08:10:12Z" && d.history[0].endedBy === null, "expired at its until, by nobody");
  check(c.records[c.records.length - 1].verb === "perf identity expired" && c.applied.length === 2, "recorded, and the pipeline back at the cascade");
  check(perfExpire({ ...c, now: at(40) }).length === 0, "an ended raise does not end twice");
  // 90 days on, it is gone from history.
  check(perfList(c.configDir, at(91 * 1440)).history.length === 0, "history keeps 90 days");
}

// A CI with no collector of its own (a pool): recorded, nothing to rewrite. Purge.
{
  const c = fake(T0);
  const r = perfRaise(c, { ref: "tankc1", level: "basic", resolution: "fine", until: at(1440).toISOString() });
  check(r.module === null && c.applied.length === 0 && c.records.length === 1, "a pool's raise is recorded, no pipeline rewritten");
  check(c.lines.some((l) => /no collector of its own/.test(l)), "and it says why");
  perfStop(c, "tankc1", true);
  check(c.purged[0] === POOL.id, "stop --purge deletes its series");
  const c2 = fake(T0);
  perfStop(c2, "identity", true);
  check(c2.purged[0] === IDENTITY.id && c2.records.length === 0, "stop --purge with nothing raised only purges");
}


// The trace store follows every raise and every end, a pool's too (ADR-046 P6).
{
  const c = fake(T0);
  perfRaise(c, { ref: "tankc1", level: "trace", until: at(30).toISOString() });
  check(c.tracesCalls === 1 && c.lines.some((l) => /^traces: Tempo on/.test(l)), "a raise to trace switches the trace store, even with no pipeline");
  perfExpire({ ...c, now: at(31) });
  check(c.tracesCalls === 2, "its expiry switches it again");
}

console.log(`perf.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
