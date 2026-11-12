// digest.test.ts — the daily digest's mail: new against still open, what is left
// out of it, and the verb's --mark.

import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { SweepRecord } from "../../src/cmdbsweep";
import { buildDigest, readSeen, writeSeen } from "../../src/digest";
import { ListRow } from "../../src/emit-read";

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

const row = (name: string, over: Partial<ListRow> = {}): ListRow =>
  ({ id: name, class: "vm", name, type: "security", status: "warning", reason: "cve-act", message: `${name} has a CVE`, since: "2026-10-30T09:40:04Z", derived: false, rootCause: null, acknowledged: null, maintenance: null, ...over }) as unknown as ListRow;
const sweep = (differences: SweepRecord["differences"]): SweepRecord => ({
  time: "2026-11-02T00:02:02.651Z",
  counts: { expected: 0, drift: 0, desired: 0, unmanaged: 0, missing: 0, unread: 0, sourcesFailed: 0 },
  differences,
});
const diff = (kind: string, cls: string, name: string, attribute: string | null = null, after: unknown = null) => ({ kind, class: cls, name, attribute, after, expected: false });
const AT = "2026-11-01T13:12:31.000Z";

const first = buildDigest([row("a")], null, null);
check(first.word === "ALERT" && first.new === 1 && first.body.includes("The first digest"), "the first digest: everything is new");

const same = buildDigest([row("a"), row("b")], null, { at: AT, keys: buildDigest([row("a"), row("b")], null, null).keys });
check(same.word === "STATUS" && same.subject === "STATUS: daily digest, nothing new, 2 still open", "nothing new: a STATUS, with what is still open");
check(same.body.includes("security cve-act (2): vm/a, vm/b") && !same.body.includes("NEW\n"), "…grouped by reason, with no NEW section");
check(same.body.includes("since the last digest (2026-11-01 13:12 UTC)"), "…saying when the last one was");

const one = buildDigest([row("a"), row("b")], null, { at: AT, keys: buildDigest([row("a")], null, null).keys });
check(one.word === "ALERT" && one.subject === "ALERT: daily digest, 1 new, 1 still open", "something new: an ALERT, counted");
check(/NEW\n {2}vm\/b {2}b has a CVE\n/.test(one.body), "…the new one by name and message");

const back = buildDigest([row("a")], null, { at: AT, keys: buildDigest([row("a"), row("b")], null, null).keys });
check(back.word === "STATUS" && back.body.includes("CLEARED (1)") && back.body.includes("vm/b security cve-act"), "what cleared is told, and is no ALERT");

const none = buildDigest([], null, { at: AT, keys: [] });
check(none.subject === "STATUS: daily digest, all clear", "nothing open: all clear");

const left = buildDigest(
  [
    row("acked", { acknowledged: { by: "lars" } as never }),
    row("window", { maintenance: { until: "x" } as never }),
    row("rollup", { derived: true }),
    row("symptom", { rootCause: "other" }),
    row("self", { rootCause: "self" }),
    row("info", { status: "unknown" as never }),
    row("drift", { type: "drift", reason: "sweep-changed" }),
  ],
  null,
  null,
);
check(left.new === 1 && left.body.includes("vm/self"), "acks, maintenance, roll-ups, symptoms and a sweep's own conditions are left out; a root is not");
const stale = buildDigest([row("rossen", { class: "site", type: "drift", status: "critical", reason: "sweep-stale", message: "the last sweep is old" })], null, null);
check(stale.new === 1 && stale.body.includes("CRITICAL the last sweep is old"), "a sweep that did not run stays a finding");

const leases = sweep([diff("gone", "address", "10.0.0.1"), diff("gone", "address", "10.0.0.1", "→member-of zone/mgmt"), diff("gone", "address", "10.0.0.2"), diff("appeared", "address", "10.0.0.3")]);
const quiet = buildDigest([], leases, { at: AT, keys: [] });
check(quiet.word === "STATUS" && quiet.body.includes("1 appeared, 2 gone"), "addresses are one count and no finding");

const moved = sweep([diff("appeared", "vm", "x"), diff("appeared", "vm", "x", "→runs-on machine/tappaas1"), diff("changed", "vm", "y", "→runs-on machine/tappaas3"), { ...diff("changed", "vm", "z", "cores"), expected: true }]);
const mv = buildDigest([], moved, null);
check(mv.new === 2 && !mv.body.includes("→runs-on machine/tappaas1") && mv.body.includes("→runs-on machine/tappaas3"), "an object's relations go with it; a relation alone stays; expected is left out");

const a1 = sweep([diff("changed", "vm", "network", "nat", { n: 1 })]);
const a2 = sweep([diff("changed", "vm", "network", "nat", { n: 2 })]);
const seen1 = { at: AT, keys: buildDigest([], a1, null).keys };
check(buildDigest([], a1, seen1).word === "STATUS", "the same difference again: not new");
check(buildDigest([], a2, seen1).word === "ALERT", "the same attribute changed again: new");
check(!buildDigest([], sweep([]), seen1).body.includes("CLEARED"), "a difference the next sweep does not repeat has not cleared");

const many = buildDigest(Array.from({ length: 35 }, (_, i) => row(`v${i}`)), null, null);
check(many.body.includes("… and 5 more") && many.subject.includes("35 new"), "a long list is cut, the count is not");

const dir = mkdtempSync(join(tmpdir(), "digest-"));
check(readSeen(dir) === null, "no record: null");
writeSeen(dir, { at: AT, keys: ["k"] });
check(readSeen(dir)?.keys[0] === "k", "the record reads back");

// The health rules: told once each, recorded silently the first time.
{
  const r0 = buildDigest([], null, null, null, { records: { "core.a": "h1", "core.b": "h2" }, pending: [], held: [] });
  check(!r0.body.includes("HEALTH RULES") && r0.keys.includes("rule:core.a@h1"), "the first digest that knows the rules records them, telling nothing");
  const seen = { at: "2026-11-12T06:00:00.000Z", keys: r0.keys };
  const r1 = buildDigest([], null, seen, null, { records: { "core.a": "h9", "site.c": "h3" }, pending: ["core.a"], held: ["mod.x"] });
  check(r1.body.includes("HEALTH RULES") && r1.body.includes("changed: core.a") && r1.body.includes("added: site.c") && r1.body.includes("removed or off: core.b"), "a change, an addition and a removal are told under their own heading");
  check(r1.body.includes("pending (edited here, changed upstream): core.a") && r1.body.includes("held: mod.x") && r1.word === "STATUS", "…pending and held rules once, and none of it makes an ALERT");
  const r2 = buildDigest([], null, { at: "2026-11-13T06:00:00.000Z", keys: r1.keys }, null, { records: { "core.a": "h9", "site.c": "h3" }, pending: ["core.a"], held: ["mod.x"] });
  check(!r2.body.includes("HEALTH RULES") && !r2.body.includes("CLEARED"), "the next day: nothing repeated, nothing cleared");
}

console.log(`\n── ${pass} passed, ${fail} failed ──`);
process.exit(fail ? 1 : 0);
