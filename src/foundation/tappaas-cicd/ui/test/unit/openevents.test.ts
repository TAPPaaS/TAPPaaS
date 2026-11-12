// operations.test.ts — the Operations view's shaping (src/operations.ts): which
// conditions are open events, the grouping by root cause and its order, the
// impact, what changed in an object's history within the window, the sweep
// record as the page shows it, the console's sweep runner, and `cmdb sweep`
// through the runner.

import { Cmdb, CmdbError, CmdbHistory, CmdbObject } from "../../src/cmdb";
import { HealthGraph, buildHealth } from "../../src/health";
import { SweepApi, SweepRunner, changeTargets, groupEvents, openEvents, operationsDoc, recentChanges, sweepRecord } from "../../src/openevents";
import { check, done } from "./check";
import { healthSite, relationTypes } from "./fake-cmdb";

const NOW = Date.parse("2026-10-30T09:00:00Z");
const site = healthSite();
const ids = site.ids;
const fixture = (): HealthGraph => buildHealth({ objects: site.objects, relations: site.relations, relationTypes: relationTypes(), modules: ["nextcloud", "immich", "gitea", "backup", "logging"], now: NOW });

// A condition as assess writes one.
const cond = (type: string, status: string, extra: Record<string, unknown> = {}) => ({
  type, status, reason: `${type}-${status}`, message: null, since: "2026-10-30T08:00:00Z", lastChecked: "2026-10-30T08:55:00Z",
  source: "health-manager", derived: false, rootCause: null, acknowledged: null, maintenance: null, ...extra,
});
const obj = (id: string, cls: string, name: string, conditions: unknown[]): CmdbObject => ({ id, class: cls, name, attributes: { conditions } });
const doc = (objects: CmdbObject[]): HealthGraph => buildHealth({ objects, relations: [], now: NOW });

function events(): void {
  const g = fixture();
  const ev = openEvents(g);
  const has = (k: string) => ev.some((e) => e.id === ids[k]);
  check(has("tappaas2"), "a node's own critical is an open event");
  check(has("gitea"), "a warning is an open event");
  check(!has("pbs-store"), "an acknowledged critical is not");
  check(!has("logging"), "a warning in a maintenance window is not");
  check(!has("site"), "a derived condition is not");
  check(!has("immich") && !has("nc-svc"), "an impact condition is not: it is its root's impact");
  check(!has("nextcloud"), "derived operational and impact on a guest: no event of its own");
  check(ev.find((e) => e.id === ids.tappaas2)?.isRoot === true, "the node is flagged a root cause");
  check(ev.find((e) => e.id === ids.gitea)?.isRoot === false, "a failure nothing depends on is no root cause");

  // An acknowledgement whose `until` has passed no longer silences.
  const lapsed = doc([obj("a", "vm", "a", [cond("operational", "critical", { acknowledged: { by: "l", until: "2026-10-29T00:00:00Z" } })])]);
  check(openEvents(lapsed).length === 1, "an acknowledgement that has run out does not silence");
  const windowed = doc([obj("a", "vm", "a", [cond("operational", "critical", { maintenance: { until: "2026-10-31T00:00:00Z" } })])]);
  check(openEvents(windowed).length === 0, "a window that holds silences");

  // Several own conditions: the worst first, all of them listed.
  const two = openEvents(doc([obj("a", "vm", "a", [cond("drift", "warning"), cond("capacity", "critical"), cond("operational", "ok")])]))[0];
  check(two.type === "capacity" && two.status === "critical", "the event shows its worst condition");
  check(two.conditions.length === 2 && two.conditions[1].type === "drift", "and lists the other failing ones");
}

function grouping(): void {
  const g = fixture();
  const groups = groupEvents(g, openEvents(g));
  check(groups.length === 2, "two groups: the node, and gitea on its own");
  check(groups[0].root === ids.tappaas2 && groups[0].status === "critical", "the critical group first");
  check(groups[1].root === ids.gitea && groups[1].status === "warning", "the warning after it");
  const impacted = groups[0].impact.objects.map((o) => o.id);
  check(impacted.includes(ids.nextcloud) && impacted.includes(ids.immich), "the node's impact: its guests, from their rootCause");
  check(!impacted.includes(ids.tappaas2), "a root is not its own impact");
  check(groups[0].impact.count >= impacted.length, "the impact count covers the objects listed");
  check(groups[1].impact.count === 0, "a failure nothing depends on impacts nothing");

  // A chain: the host explains the VM, the VM the app; each has its own failure.
  const chain = doc([
    obj("h", "machine", "host", [cond("operational", "critical")]),
    obj("v", "vm", "guest", [cond("operational", "warning", { rootCause: "h" })]),
    obj("a", "app", "app", [cond("operational", "critical", { rootCause: "v" })]),
    obj("w", "vm", "alone", [cond("drift", "warning", { since: "2026-10-29T00:00:00Z" })]),
  ]);
  const cg = groupEvents(chain, openEvents(chain));
  check(cg.length === 2, "a chain is one group");
  check(cg[0].root === "h" && cg[0].events.map((e) => e.id).join() === "h,a,v", "headed by the top root; then critical before warning");
  check(cg[0].since === "2026-10-30T08:00:00Z", "a group's since is its earliest event's");
  check(cg[1].root === "w", "the lone warning after the critical group, older or not");

  // Causes that name each other end where the walk closes.
  const loop = doc([
    obj("x", "vm", "x", [cond("operational", "critical", { rootCause: "y" })]),
    obj("y", "vm", "y", [cond("operational", "critical", { rootCause: "x" })]),
  ]);
  const lg = groupEvents(loop, openEvents(loop));
  check(lg.reduce((n, gr) => n + gr.events.length, 0) === 2, "a cycle of causes loses no event and does not loop");

  // A cause that is silenced is no group head: the symptom stands alone.
  const quiet = doc([
    obj("h", "machine", "host", [cond("operational", "critical", { acknowledged: { by: "l" } })]),
    obj("v", "vm", "guest", [cond("operational", "critical", { rootCause: "h" })]),
  ]);
  const qg = groupEvents(quiet, openEvents(quiet));
  check(qg.length === 1 && qg[0].root === "v", "a symptom of a silenced root heads its own group");

  // Among two critical groups the one that impacts more comes first.
  const two = doc([
    obj("s", "machine", "small", [cond("operational", "critical")]),
    obj("b", "machine", "big", [cond("operational", "critical")]),
    obj("s1", "vm", "s1", [cond("impact", "critical", { derived: true, rootCause: "s" })]),
    obj("b1", "vm", "b1", [cond("impact", "critical", { derived: true, rootCause: "b" })]),
    obj("b2", "vm", "b2", [cond("impact", "critical", { derived: true, rootCause: "b" })]),
    // health-manager's root causes, as the site records them: the console computes none.
    { ...obj("site", "site", "home", []), attributes: { rootCauses: [{ id: "b", type: "operational", impactedCount: 2 }, { id: "s", type: "operational", impactedCount: 1 }] } },
  ]);
  const tg = groupEvents(two, openEvents(two));
  check(tg[0].root === "b" && tg[0].impact.count === 2 && tg[1].root === "s", "more impact first among equals");

  const t = changeTargets(cg, 2);
  check(t.read.join() === "h,a" && t.skipped.join() === "v,w", "the histories read follow the page's order, up to the cap");
}

function changes(): void {
  const h: CmdbHistory = {
    id: "v",
    attributes: [
      { name: "conditions", value: [], source: "health-manager", from: "2026-10-30T08:00:00Z", to: null, change: 10 },
      { name: "memory", value: 8192, source: "module-manager", from: "2026-10-30T07:00:00Z", to: null, change: 11 },
      { name: "lastSeen", value: "x", source: "module-manager", from: "2026-10-30T07:00:00Z", to: null, change: 11 },
      { name: "state", value: "stopped", source: "site-manager", from: "2026-10-30T06:00:00Z", to: null, change: 12 },
      { name: "memory", value: 4096, source: "module-manager", from: "2026-10-01T00:00:00Z", to: "2026-10-30T07:00:00Z", change: 3 },
    ],
    relations: [
      { id: 1, type: "runs-on", direction: "out", other: { id: "n2", class: "machine", name: "tappaas2" }, source: "site-manager", change: 13, from: "2026-10-30T05:00:00Z", to: null },
      { id: 2, type: "runs-on", direction: "out", other: { id: "n1", class: "machine", name: "tappaas1" }, source: "site-manager", change: 2, from: "2026-10-01T00:00:00Z", to: "2026-10-30T05:00:00Z" },
    ],
    changes: [
      { id: 3, kind: "change", source: "module-manager", job: null, verb: "modify", actor: null, time: "2026-10-01T00:00:00Z", drift: false },
      { id: 10, kind: "observation", source: "health-manager", job: null, verb: null, actor: null, time: "2026-10-30T08:00:00Z", drift: false },
      { id: 11, kind: "change", source: "module-manager", job: "j-1", verb: "modify", actor: "lars", time: "2026-10-30T07:00:00Z", drift: false },
      { id: 12, kind: "observation", source: "site-manager", job: null, verb: null, actor: null, time: "2026-10-30T06:00:00Z", drift: true },
      { id: 13, kind: "change", source: "site-manager", job: null, verb: "migrate", actor: null, time: "2026-10-30T05:00:00Z", drift: false },
      { id: 14, kind: "observation", source: "controller", job: null, verb: "sweep", actor: null, time: "2026-10-30T04:00:00Z", drift: true },
    ],
  };
  const from = NOW - 24 * 3600_000;
  const list = recentChanges(h, from, NOW);
  check(list.map((c) => c.id).join() === "11,12,13,14", "the window's changes, newest first; assess's heartbeat and older ones left out");
  const c11 = list.find((c) => c.id === 11)!;
  check(c11.what.join() === "memory" && c11.actor === "lars" && c11.job === "j-1", "a verb's change: what it set, who, which job; lastSeen left out");
  check(list.find((c) => c.id === 12)!.what.join() === "state" && list.find((c) => c.id === 12)!.drift, "an observation that changed the state stays, with its drift");
  const c13 = list.find((c) => c.id === 13)!;
  check(c13.what.includes("+runs-on → machine/tappaas2") && c13.what.includes("−runs-on → machine/tappaas1"), "a move: the relation made and the one ended");
  check(list.find((c) => c.id === 14)!.verb === "sweep", "a sweep's record stays");

  // No change id on the periods (an older controller): matched by time.
  const old: CmdbHistory = {
    id: "v",
    attributes: [{ name: "cores", value: 4, source: "module-manager", from: "2026-10-30T07:00:00Z", to: null }],
    changes: [{ id: 1, kind: "change", source: "module-manager", job: null, verb: "modify", actor: null, time: "2026-10-30T07:00:00Z", drift: false }],
  };
  check(recentChanges(old, from, NOW)[0]?.what.join() === "cores", "periods without a change id are matched by time");

  const g = fixture();
  const histories = new Map<string, CmdbHistory | Error>([[ids.tappaas2, h], [ids.gitea, new Error("the CMDB did not answer")]]);
  const d = operationsDoc(g, histories, ["z"], NOW);
  check(d.counts.critical === 1 && d.counts.warning === 1 && d.counts.groups === 2, "the document counts the events and groups");
  check(d.counts.silenced === 2, "and what is silenced: the acknowledged store, the window on logging");
  check(d.changes[ids.tappaas2]?.length === 4 && d.changesError[ids.gitea] === "the CMDB did not answer", "each event's changes, or why not");
  check(d.changesSkipped.join() === "z" && d.windowHours === 24, "the skipped ones and the window");
  const none = operationsDoc(null, new Map(), [], NOW);
  check(none.groups.length === 0 && none.hasConditions === false && none.generated === null, "no health document: an empty page, not an error");
}

function sweeps(): void {
  const rec = sweepRecord({
    id: "42", time: "2026-10-30T01:00:00Z", since: "2026-10-29T01:00:00Z", status: "warning", exitCode: 1,
    counts: { expected: 1, drift: 1, desired: 0, unmanaged: 1, missing: 0, unread: 0, sourcesFailed: 1, bogus: "x" },
    sources: [{ source: "site-manager", ok: true, exitCode: 0, seconds: 3 }, { source: "ap-manager", ok: false, exitCode: 1, seconds: 1, error: "no controller" }, { source: "switch-manager", ok: true, exitCode: 0, seconds: 2, fallback: true }],
    differences: [
      { kind: "changed", class: "vm", name: "a", id: "a", source: "module-manager", attribute: "memory", before: 1, after: 2, expected: true, verb: "modify" },
      { kind: "changed", class: "vm", name: "b", source: "module-manager", attribute: "cores", before: 1, after: 2, expected: false },
      { kind: "unmanaged", class: "vm", name: "c", source: "sweep", attribute: null, before: null, after: null, expected: false },
    ],
  });
  check(rec.id === 42 && rec.status === "warning" && rec.since === "2026-10-29T01:00:00Z", "the record's id, status and the sweep before");
  check(rec.findings.length === 2 && rec.findings.every((x) => !x.expected) && rec.expectedTotal === 1 && rec.findingsTotal === 2, "findings are what no change explains; the expected only counted");
  check(rec.findings[0].id === null && rec.findings[1].attribute === null, "a finding without an id or an attribute");
  check(rec.counts.drift === 1 && !("bogus" in rec.counts), "the numeric counts only");
  check(rec.sources[1].ok === false && rec.sources[1].error === "no controller" && rec.sources[2].fallback, "the sources: the failed one with why, the one asked plainly");
  const base = sweepRecord({ id: 1, time: "2026-10-30T01:00:00Z", since: null, status: "healthy", counts: {}, sources: [], differences: [] });
  check(base.since === null && base.findings.length === 0, "the baseline: nothing to compare");
}

async function runner(): Promise<void> {
  let finish: (v: Record<string, unknown>) => void = () => undefined;
  let calls = 0;
  const api: SweepApi = {
    sweep: () => {
      calls++;
      return new Promise((r) => (finish = r));
    },
    lastSweep: async () => null,
  };
  const s = new SweepRunner(api, () => undefined, () => NOW, 20);
  const a = await s.start("lars");
  check(a.status === 202 && a.running?.by === "lars" && s.busy, "a sweep starts behind the request");
  const b = await s.start("erik");
  check(b.status === 409 && calls === 1, "a second one is refused while it runs, and never reaches the CMDB");
  check((await s.state()).running?.by === "lars" && (await s.state()).last === null, "the state: running, no record yet");
  finish({ status: "healthy" });
  await new Promise<void>((r) => setTimeout(() => r(), 5));
  check(!s.busy, "it is done when the sweep answers");

  const refused = new SweepRunner({ sweep: async () => { throw new CmdbError("a sweep is already running", 409); }, lastSweep: async () => null }, () => undefined, () => NOW, 20);
  const r1 = await refused.start(null);
  check(r1.status === 409 && !refused.busy && (await refused.state()).failed === null, "the controller's 409 is passed on and is no failure");

  const down = new SweepRunner({ sweep: async () => { throw new CmdbError("cmdb-controller is not running"); }, lastSweep: async () => { throw new Error("no answer"); } }, () => undefined, () => NOW, 20);
  const r2 = await down.start(null);
  const st = await down.state();
  check(r2.status === 502 && st.failed?.error === "cmdb-controller is not running" && st.lastError === "no answer", "a CMDB that does not answer: said at once, and kept");

  const rec = new SweepRunner({ sweep: async () => ({}), lastSweep: async () => ({ id: 3, time: "2026-10-30T01:00:00Z", status: "healthy", counts: {}, sources: [], differences: [] }) }, () => undefined, () => NOW, 20);
  check((await rec.state()).last?.id === 3, "the last record, shaped");
}

async function cli(): Promise<void> {
  const out = (rc: number, stdout: string, stderr = "") => async () => ({ rc, stdout, stderr, ran: true });
  const asked: string[][] = [];
  const warn = new Cmdb({
    tokenFile: "/nonexistent",
    run: async (bin, args, timeoutMs) => {
      asked.push([bin, ...args, String(timeoutMs)]);
      return out(1, JSON.stringify({ id: 9, status: "warning", exitCode: 1 }))();
    },
  });
  const d = await warn.sweep();
  check(d.id === 9 && asked[0].slice(0, 3).join(" ") === "cmdb sweep --json" && Number(asked[0][3]) >= 4 * 3600_000, "cmdb sweep --json, waiting hours; exit 1 with a record is a warning, not a failure");
  const busy = new Cmdb({ tokenFile: "/nonexistent", run: out(4, "", "cmdb: a sweep is already running\n") });
  const e1 = await busy.sweep().then(() => null, (e: CmdbError) => e);
  check(e1 instanceof CmdbError && e1.status === 409 && e1.message === "a sweep is already running", "exit 4, already running: the 409");
  const gone = new Cmdb({ tokenFile: "/nonexistent", run: out(5, "", "cmdb: cmdb-controller is not running (no /run/cmdb/cmdb.sock)\n") });
  const e2 = await gone.sweep().then(() => null, (e: CmdbError) => e);
  check(e2 instanceof CmdbError && e2.status === null && /not running/.test(e2.message), "exit 5: the CLI's reason");
  const none = new Cmdb({ tokenFile: "/nonexistent" });
  check((await none.sweep().then(() => null, (e: Error) => e)) instanceof CmdbError, "no runner: refused, not thrown past the caller");
}

async function main(): Promise<void> {
  events();
  grouping();
  changes();
  sweeps();
  await runner();
  await cli();
  done("operations");
}

void main();
