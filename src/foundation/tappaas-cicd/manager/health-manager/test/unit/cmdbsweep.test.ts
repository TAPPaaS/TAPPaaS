// cmdbsweep.test.ts — the `cmdb` gate over a sweep record (ADR-040 D15):
// healthy, warning, critical by the sweep's own thresholds; nothing but the
// record is read.

import { CmdbUnavailable } from "../../../../lib/ts/src/cmdb";
import { SweepRecord, checkCmdb, checkCmdbSweep } from "../../src/cmdbsweep";

let pass = 0;
let fail = 0;
function check(c: boolean, what: string): void {
  if (c) {
    pass++;
    console.log(`  ✓ ${what}`);
  } else {
    fail++;
    console.log(`  ✗ ${what}`);
  }
}

const NOW = Date.parse("2026-10-30T12:00:00Z");
const rec = (over: Partial<SweepRecord["counts"]>, more: Partial<SweepRecord> = {}): SweepRecord => ({
  time: "2026-10-30T01:00:00.000Z",
  counts: { expected: 0, drift: 0, desired: 0, unmanaged: 0, missing: 0, unread: 0, sourcesFailed: 0, ...over },
  ...more,
});

check(checkCmdbSweep(rec({ expected: 3 }), NOW).status === "pass", "only expected changes: healthy");
const w = checkCmdbSweep(
  rec({ drift: 1 }, { differences: [{ kind: "changed", class: "vm", name: "x", attribute: "cores", expected: false }, { kind: "changed", class: "vm", name: "y", attribute: "cores", expected: true }] }),
  NOW,
);
check(w.status === "warn" && w.rows!.length === 1 && w.rows![0].text.includes("vm/x"), "drift: a warning, with the unexplained difference and not the expected one");
check(checkCmdbSweep(rec({ unmanaged: 1 }), NOW).status === "warn", "unmanaged: a warning");
check(checkCmdbSweep(rec({ desired: 2 }), NOW).status === "warn", "a difference from desired: a warning");
const m = checkCmdbSweep(
  rec({ missing: 1, drift: 1 }, { differences: [{ kind: "changed", class: "vm", name: "a", attribute: "c", expected: false }, { kind: "missing", class: "zone", name: "dmz", attribute: null, expected: false }] }),
  NOW,
);
check(m.status === "fail" && m.rows![0].text.includes("desired without actual"), "desired without actual: critical, listed first");
const s = checkCmdbSweep(rec({ sourcesFailed: 1 }, { sources: [{ source: "switch-manager", ok: false }, { source: "site-manager", ok: true }] }), NOW);
check(s.status === "fail" && s.rows!.length === 1 && s.rows![0].text.includes("switch-manager"), "a failed source: critical, named");
check(checkCmdbSweep(rec({}, { time: "2026-10-28T11:00:00.000Z" }), NOW).status === "fail", "no sweep in 48 h: critical");
check(checkCmdbSweep(rec({}, { time: "2026-10-28T13:00:00.000Z" }), NOW).status === "pass", "47 hours old is still a sweep");
check(checkCmdbSweep(null, NOW).status === "fail", "no record at all: critical");
const many = Array.from({ length: 30 }, (_, i) => ({ kind: "unmanaged", class: "vm", name: `v${i}`, attribute: null, expected: false }));
check(checkCmdbSweep(rec({ unmanaged: 30 }, { differences: many }), NOW).rows!.length === 21, "a long list is cut, and says so");
check(
  checkCmdb(NOW, () => {
    throw new CmdbUnavailable("not running");
  }).status === "warn",
  "the CMDB down is a warning, not a crash",
);

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exitCode = 1;
