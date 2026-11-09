// assistant-health.test.ts — health_graph, the assistant's read of the health
// graph (ADR-041 O5): the root causes, one object with what explains it, its
// neighbours and its last day; the bounds (objects, events, hours); names and
// conditions only; and the tool end to end over the fixture CMDB.

import { mkdirSync, mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { HEALTH_EVENTS, HEALTH_OBJECTS, HEALTH_RESULT_CHARS, ToolContext, healthObjectView, healthRootsView, resolveHealthObject, runTool, toolDefs } from "../../src/assistant-tools";
import { ConditionChange, HealthGraph, HealthNode, buildHealth } from "../../src/health";
import { Reads } from "../../src/reads";
import { check, done } from "./check";
import { FakeCmdb, healthSite, relationTypes } from "./fake-cmdb";
import { fakeSite } from "./fake-site";

const NOW = Date.parse("2026-10-30T09:00:00Z");
const site = healthSite();
const ids = site.ids;
const g = buildHealth({ objects: site.objects, relations: site.relations, relationTypes: relationTypes(), modules: ["nextcloud", "immich", "gitea", "backup", "logging"], now: NOW });
const node = (k: string): HealthNode => g.nodes.find((n) => n.id === ids[k])!;
// An object in one line: name (class, state[: issue][; marks]), nothing else.
const BRIEF = /^[^()]+ \([a-z][\w-]*, (ok|unknown|warning|critical)(: [^;()]*)?(; [a-z ,]+)?\)$/;

// Every object the view carries, wherever it sits.
function objectsIn(v: unknown): unknown[] {
  const out: unknown[] = [];
  const walk = (x: unknown, key: string): void => {
    if (Array.isArray(x)) {
      if (["causedBy", "objects"].includes(key)) out.push(...x);
      else x.forEach((y) => walk(y, key));
    } else if (x && typeof x === "object") for (const [k, y] of Object.entries(x as Record<string, unknown>)) walk(y, k);
  };
  walk(v, "");
  return out;
}

function pure(): void {
  // The roots, worst first.
  const roots = healthRootsView(g);
  const rc = (roots.view as { rootCauses: string[] }).rootCauses;
  check(rc[0]?.startsWith("tappaas2 (machine, critical") && / brings down [1-9]/.test(rc[0]), `the root causes, the worst first (${rc.join(" | ")})`);
  check(roots.read.some((r) => r.endsWith("tappaas2")) && roots.events === 0, "the roots list says what it read");

  // A name means its object; a miss says how to go on.
  const hit = resolveHealthObject(g, "TAPPAAS2");
  check("node" in hit && hit.node.id === ids.tappaas2, "a name, without regard to case");
  check("node" in resolveHealthObject(g, ids.nextcloud), "an id exactly");
  const miss = resolveHealthObject(g, "nosuch");
  check("error" in miss && /no object named 'nosuch'/.test(miss.error) && /health_graph\(\)/.test(miss.error), "a miss names the way on");

  // The root: what it explains, its neighbours, its last day only.
  const hist: ConditionChange[] = [
    { at: "2026-10-30T02:14:00Z", type: "operational", from: "ok", to: "critical", reason: "node-down", message: "tappaas2 does not answer", source: "health-manager" },
    { at: "2026-10-20T10:00:00Z", type: "capacity", from: "ok", to: "warning", reason: "old", message: null, source: "health-manager" },
  ];
  const jobs = [
    { id: 1, kind: "update", source: "console", job: "j1", verb: "module-manager modify", actor: "lars", time: "2026-10-30T07:00:00Z" },
    { id: 2, kind: "update", source: "console", job: "j0", verb: "old", actor: "lars", time: "2026-10-01T07:00:00Z" },
    { id: 3, kind: "observation", source: "health-manager", job: null, verb: null, actor: null, time: "2026-10-30T08:55:00Z" },
  ];
  const r = healthObjectView(g, node("tappaas2"), 1, { history: hist, changes: jobs }, NOW);
  const v = r.view as { object: { is: string; conditions: string[] }; bringsDown: { count: number; objects: string[] }; nearby: unknown[]; howToRead: string; lastDay: { events: string[] }; read: string };
  check(/critical/.test(v.object.is) && /^operational critical: node-down — tappaas2 does not answer \(since 2026-10-30 02:14\)$/.test(v.object.conditions[0] ?? ""), `the root's own conditions (${v.object.conditions[0]})`);
  check(v.bringsDown.count > 0 && v.bringsDown.objects.some((o) => o.startsWith("nextcloud (")), "what it brings down, listed as such (nextcloud), not only as nearby");
  check(/only these are its consequences/.test(v.howToRead) && /Read: …/.test(v.howToRead), "how to read it: nearby is not caused, end with what was read");
  check(v.nearby.length > 0 && !JSON.stringify(v.nearby).includes("nextcloud ("), "the rest one relation away, by relation; a symptom not repeated there");
  check(r.events === 2 && v.lastDay.events.every((e) => e.startsWith("2026-10-30")) && v.lastDay.events.some((e) => / by module-manager modify \(lars\)$/.test(e)), "the last 24 hours only: a change and a job; the older ones and a routine report left out");
  check(/health changes and jobs, last 24 h/.test(v.read) && r.read.length === r.objects + 1, `the read list: every object and the history (${v.read})`);

  // A symptom points at its root.
  const s = healthObjectView(g, node("nextcloud"), 1, null, NOW).view as { causedBy: string[]; bringsDown: unknown; lastDay: string };
  check(s.causedBy.some((o) => o.startsWith("tappaas2 (")) && s.bringsDown === "nothing", "a symptom names the root that causes it, and brings nothing down");
  check(s.lastDay === "its history was not read", "no record: said, not invented");
  const quiet = healthObjectView(g, node("nextcloud"), 1, { history: [], changes: [jobs[2]] }, NOW).view as { lastDay: string };
  check(/^no change of a condition's status and no job in the last 24 h$/.test(quiet.lastDay), "a manager's routine report is no event; a quiet day is said");
  const e = healthObjectView(g, node("nextcloud"), 1, new Error("cmdb down"), NOW).view as { lastDay: string };
  check(/could not be read: cmdb down/.test(e.lastDay), "a failed history read is said");

  // A second hop reads more, still bounded.
  const one = healthObjectView(g, node("nextcloud"), 1, null, NOW);
  const two = healthObjectView(g, node("nextcloud"), 2, null, NOW);
  check(two.objects > one.objects && two.objects <= HEALTH_OBJECTS, `a second hop on request (${one.objects} → ${two.objects})`);

  // Names and conditions only: an object is its id, name, class and state.
  const all = [...objectsIn(r.view), ...objectsIn(two.view)];
  const once = objectsIn(two.view);
  check(new Set(once).size === once.length, `each object once (${once.length})`);
  const odd = all.filter((o) => typeof o !== "string" || !BRIEF.test(o));
  check(all.length > 0 && odd.length === 0, `objects carry name, class and state only (${all.length} checked${odd.length ? `; odd: ${JSON.stringify(odd[0])}` : ""})`);
  check(!JSON.stringify(r.view).includes("attributes") && !JSON.stringify(r.view).includes("lastChecked"), "no attributes, no record fields");
}

// A root with far more neighbours and history than the bounds allow.
function bounds(): void {
  const mk = (i: number, status: HealthNode["status"]): HealthNode => ({
    id: `n${i}`, class: "vm", name: `g${i}`, label: `g${i}`, environment: null, module: null, rootCause: i === 0 ? [] : ["n0"], isRoot: i === 0,
    types: {}, issues: [], status, type: status === "ok" ? null : "impact", reason: null, since: null, acknowledged: false, maintenance: false, flapping: false,
  });
  const nodes = [mk(0, "critical"), ...Array.from({ length: 120 }, (_, i) => mk(i + 1, "warning"))];
  const doc = {
    generated: "2026-10-30T09:00:00Z", at: null, topology: "t", hasConditions: true, site: "s", nodes,
    edges: nodes.slice(1).map((n) => ({ id: `e${n.id}`, type: "runs-on", from: n.id, to: "n0" })),
    relationTypes: [{ name: "runs-on", dependant: "from", tree: null }],
    roots: [{ id: "n0", class: "vm", name: "g0", label: "g0", type: "operational", status: "critical", reason: null, message: null, since: null, acknowledged: false, flapping: false, impactedCount: 120, impacted: nodes.slice(1).map((n) => n.id), environments: [] }],
    counts: { ok: 0, unknown: 0, warning: 120, critical: 1, acknowledged: 0 },
  } as unknown as HealthGraph;
  const history: ConditionChange[] = Array.from({ length: 300 }, (_, i) => ({ at: new Date(NOW - i * 60_000).toISOString(), type: "operational", from: "ok", to: "critical", reason: null, message: null, source: "h" }));
  const r = healthObjectView(doc, nodes[0], 1, { history, changes: [] }, NOW);
  const v = r.view as { nearby: { notShown?: number }[]; bringsDown: { notShown?: number }; lastDay: { events: string[]; notShown?: number } };
  check(r.objects === HEALTH_OBJECTS, `at most ${HEALTH_OBJECTS} objects (${r.objects})`);
  check((v.bringsDown.notShown ?? 0) === 121 - HEALTH_OBJECTS && v.nearby.length === 0, `what did not fit is counted (${v.bringsDown.notShown}), nothing listed twice`);
  check(r.events === HEALTH_EVENTS && v.lastDay.events.length === HEALTH_EVENTS && v.lastDay.notShown === 300 - HEALTH_EVENTS, `at most ${HEALTH_EVENTS} events, the newest, the rest counted`);
  check(JSON.stringify(r.view).length <= HEALTH_RESULT_CHARS, `a full answer fits whole (${JSON.stringify(r.view).length} of ${HEALTH_RESULT_CHARS} characters)`);
  // Long names and messages: the oldest events give way, the objects stay.
  const long = (x: HealthNode): HealthNode => ({ ...x, label: `${x.label}-${"n".repeat(25)}`, reason: "r".repeat(200) });
  const doc2 = { ...doc, nodes: doc.nodes.map(long) } as HealthGraph;
  const msgs = history.map((c) => ({ ...c, message: "m".repeat(200) }));
  const r2 = healthObjectView(doc2, doc2.nodes[0], 1, { history: msgs, changes: [] }, NOW);
  const v2 = r2.view as { lastDay: { events: string[]; notShown?: number } };
  check(JSON.stringify(r2.view).length <= HEALTH_RESULT_CHARS && r2.objects === HEALTH_OBJECTS && r2.events < HEALTH_EVENTS && v2.lastDay.notShown === 300 - r2.events,
    `long text: still whole, ${r2.objects} objects, ${r2.events} newest events, ${v2.lastDay.notShown} counted`);
}

async function tool(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-ahealth-"));
  mkdirSync(join(dir, "state"), { recursive: true });
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: fakeSite().run, journalDays: 7, cmdb: new FakeCmdb().asCmdb(), now: () => NOW });
  const ctx: ToolContext = { reads, manifests: () => null, jobs: () => [], loki: null, repoRoot: dir, now: () => NOW };
  check(toolDefs(ctx).some((t) => t.function.name === "health_graph"), "health_graph is offered");
  const all = await runTool(ctx, "health_graph", "{}");
  check(all.ok && /tappaas2/.test(all.content) && /root cause/.test(all.summary), `the roots through the tool (${all.summary})`);
  const one = await runTool(ctx, "health_graph", '{"object":"nextcloud"}');
  check(one.ok && /"causedBy":\["tappaas2 \(/.test(one.content) && /"read":/.test(one.content), `one object through the tool (${one.summary})`);
  const deep = await runTool(ctx, "health_graph", '{"object":"nextcloud","depth":2}');
  check(deep.ok && /\(2 hops\)/.test(deep.summary), "a second hop when asked");
  const miss = await runTool(ctx, "health_graph", '{"object":"nosuch"}');
  check(!miss.ok && /no object named/.test(miss.content), "an unknown object is refused with the way on");
}

pure();
bounds();
void tool().then(() => done("assistant-health"));
