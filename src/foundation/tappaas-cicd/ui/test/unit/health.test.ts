// health.test.ts — the Health view's backend over the fixture site
// (fake-cmdb.ts): the worst condition and what silences it, roots and their
// symptoms, groups and tiers, the summary the other pages read, the history,
// the client's stream, the live feed, the routes, and ack as a job.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig } from "../../src/access";
import { withConditions } from "../../src/badges";
import { Cached } from "../../src/cache";
import { Cmdb, CmdbChange, parseFrame, splitFrames } from "../../src/cmdb";
import { Condition, HealthGraph, buildHealth, conditionHistory, diffHealth, healthSummary, issueOf, moduleHealth, tierOf, viewOf } from "../../src/health";
import { HealthLive } from "../../src/healthlive";
import { Manifests, normalize, validateArgv } from "../../src/manifest";
import { Reads } from "../../src/reads";
import { ConsoleServer } from "../../src/server";
import { check, done } from "./check";
import { FakeCmdb, healthSite } from "./fake-cmdb";
import { fakeSite } from "./fake-site";

const NOW = Date.parse("2026-10-30T09:00:00Z");
const MODULES = ["nextcloud", "immich", "gitea", "backup", "logging"];
const site = healthSite();
const ids = site.ids;
const graph = (s = site): HealthGraph => buildHealth({ objects: s.objects, relations: s.relations, modules: MODULES, now: NOW });

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

function pure(): void {
  const g = graph();
  const node = (k: string) => g.nodes.find((n) => n.id === ids[k])!;

  // The worst condition (D1), and what is left of it when silenced (D4).
  const iss = (c: Partial<Condition>) => issueOf({ type: "operational", status: "ok", ...c }, new Set(), NOW);
  check(viewOf([iss({ status: "warning" }), iss({ status: "unknown" }), iss({})]).status === "warning", "warning outranks unknown");
  check(viewOf([iss({ status: "unknown" }), iss({})]).status === "unknown", "unknown outranks ok");
  check(viewOf([iss({ status: "critical", acknowledged: { by: "l" } }), iss({ type: "drift", status: "warning" })]).status === "warning", "an acknowledged critical stops counting beside a warning");
  const acked = viewOf([iss({ status: "critical", acknowledged: { by: "l" } })]);
  check(acked.status === "critical" && acked.acknowledged, "nothing else counting: the acknowledged status, hatched");
  check(!viewOf([iss({ status: "critical", acknowledged: { by: "l", until: "2026-10-01T00:00:00Z" } })]).acknowledged, "an acknowledgement past its until no longer holds");
  check(viewOf([iss({ status: "warning", maintenance: { until: "2099-01-01T00:00:00Z" } })]).maintenance, "a window holds: dotted");
  check(viewOf([]).status === "ok", "no bad condition: ok");

  check(g.hasConditions && g.nodes.length === site.objects.length, "every object is a node");
  check(node("tappaas2").status === "critical" && node("tappaas2").reason === "tappaas2 does not answer", "the node down: its own reason");
  check(node("nextcloud").reason === "node tappaas2 down", "a symptom says the impact, not its derived check");
  check(node("gitea").flapping && node("gitea").status === "warning", "the flapping condition is held and marked");
  check(node("logging").maintenance && !node("logging").acknowledged, "the guest in its window");
  check(node("u1").status === "unknown", "no condition at all: unknown, not hidden");

  // Roots first (D3): ordered by impact, the acknowledged one's symptom quiet.
  check(g.roots.map((r) => r.name).join(" ") === "tappaas2 tappaas_backup", "the roots, most impacted first");
  const r = g.roots[0];
  check(r.impactedCount === 4 && r.impacted.length === 3 && r.environments.join() === "home", "the root says what it impacts and where");
  check(node("tappaas2").isRoot && !node("nextcloud").isRoot, "the root is marked, the symptom is not");
  check(node("nextcloud").rootCause.join() === ids.tappaas2, "the symptom names its root");
  check(g.roots[1].acknowledged && node("pbs-store").acknowledged, "the acknowledged root");
  check(node("backup").acknowledged && node("backup").status === "critical", "its symptom is silenced with it (D4)");

  // Tiers: the hardware at the bottom, the site on top.
  check(node("srv1").tier < node("tappaas1").tier && node("tappaas1").tier < node("nextcloud").tier, "assets below machines below guests");
  check(node("nextcloud").tier < node("nc-svc").tier && node("nc-svc").tier < node("env").tier && node("env").tier < node("site").tier, "services, then environments, then the site");
  check(tierOf("gadget", new Map([["gadget", "device"]])) === node("tappaas1").tier, "a contributed class sits with its parent");

  // Groups.
  check(node("nextcloud").group === "environment:home" && node("nc-svc").group === "environment:home", "an environment's guests and their software are one group");
  check(node("p1").group === `ports:${ids.srv1}`, "an asset's ports collapse into it");
  check(node("p3").group === null, "a group of one is no group");
  check(node("a1").group === `addresses:${ids.zone}`, "addresses collapse by zone");
  check(node("u1").group === "class:user", "users collapse by class");
  check(g.groups.find((x) => x.id === "environment:home")?.members === 4, "the group counts its members");
  check(node("nextcloud").environment === "home", "a member knows its environment");

  // Edges: what carries impact, nothing else.
  check(g.edges.length === site.relations.filter((x) => x.type !== "part-of").length, "part-of groups but draws no edge");

  check(node("nc-svc").module === "nextcloud" && node("nextcloud").module === "nextcloud" && node("tappaas2").module === null, "the module an object belongs to");

  // The summary the pages read.
  const s = healthSummary(g);
  check(s.available && s.counts.critical === 6 && s.counts.acknowledged === 3, "the counts: silenced apart");
  check(s.byType.capacity.status === "ok" && s.byType.capacity.items.length === 1 && s.byType.capacity.items[0].silenced, "an acknowledged capacity condition does not colour its type");
  check(s.attention[0].label === "tappaas2" && s.attention[0].root, "Attention starts with the root");
  check(!s.attention.some((a) => a.label === "immich" || a.label === "nextcloud"), "a symptom is not a line of its own");
  check(!healthSummary(null).available, "no graph: not available, a page keeps `health`");
  const none = buildHealth({ objects: site.objects.map((o) => ({ ...o, attributes: {} })), relations: site.relations, now: NOW });
  check(!none.hasConditions && !healthSummary(none).available, "a site that has not run assess: not available");
  check(none.roots.length === 0 && none.nodes.every((n) => n.status === "unknown"), "its graph still draws, grey");

  // A module's worst condition.
  const mh = moduleHealth(g);
  check(mh.get("nextcloud")?.status === "critical" && mh.get("nextcloud")?.objects === 2, "a module: the worst of its node and services");
  check(mh.get("backup")?.acknowledged === true, "a module whose only trouble is silenced");
  const row = (name: string) => ({ name, badges: { health: "pass", run: "running", backup: "covered", cve: "ok", maturity: null }, findings: [] }) as never;
  const list = withConditions([row("nextcloud"), row("backup"), row("elsewhere")], mh);
  check(list[0].badges.health === "fail" && list[0].condition?.status === "critical", "the badge follows the condition");
  check(list[1].badges.health === "pass", "a silenced condition does not count");
  check(list[2].badges.health === "pass" && !list[2].condition, "a module with no conditions keeps the gates' badge");

  // History is a walk through the attribute's periods.
  const h = conditionHistory(site.history);
  check(h.length === 1 && h[0].from === "ok" && h[0].to === "critical" && h[0].reason === "node-down", "one transition, from ok to critical");

  // A patch names what moved.
  const after = healthSite();
  after.objects.find((o) => o.id === ids.gitea)!.attributes.conditions = [{ type: "operational", status: "ok" }];
  const p = diffHealth(g, graph(after));
  check(!!p && !p.relayout && p.patches.length === 1 && p.patches[0].id === ids.gitea, "a colour moved: one patch, no layout");
  check(diffHealth(g, graph()) === null, "nothing moved: nothing sent");
  const moved = healthSite();
  moved.relations.pop();
  check(diffHealth(g, graph(moved))?.relayout === true, "an edge went: the graph is laid out again");

  // The SSE frames.
  check(parseFrame(": keepalive") === null, "a comment is no frame");
  check(parseFrame('event: change\ndata: {"id":1}')?.event === "change", "a frame's event");
  const parts = splitFrames("event: change\ndata: 1\n\nevent: ch");
  check(parts.frames.length === 1 && parts.rest === "event: ch", "a chunk ends mid-frame: the rest waits");
}

async function client(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-cmdb-"));
  const token = join(dir, "token");
  writeFileSync(token, "s3cret\n", { encoding: "utf8" });
  const g = globalThis as unknown as { fetch: unknown };
  const real = g.fetch;
  const seen: { url: string; auth?: string }[] = [];
  const answer = (status: number, body: unknown) => ({ ok: status < 400, status, json: async () => body, text: async () => JSON.stringify(body), body: null });
  g.fetch = async (url: string, init: { headers: Record<string, string> }) => {
    seen.push({ url, auth: init.headers.Authorization });
    if (url.endsWith("/v1/query")) return answer(200, { ok: true, data: [{ id: "x" }] });
    if (url.includes("/v1/stream")) {
      const enc = new Uint8Array([...Buffer.from('event: change\ndata: {"id":9,"objects":[]}\n\n') as unknown as number[]]);
      return { ok: true, status: 200, body: (async function* () { yield enc; })() };
    }
    return answer(404, { ok: false, error: "no object" });
  };
  const c = new Cmdb({ url: "http://cmdb:1/", tokenFile: token, retryMs: 5 });
  const rows = await c.query({});
  check(rows.length === 1 && seen[0].auth === "Bearer s3cret" && seen[0].url === "http://cmdb:1/v1/query", "a read carries the token from its file");
  const bad = await c.show("nope").catch((e: Error) => e.message);
  check(bad === "no object", "a refusal is the CMDB's words");
  const none = await new Cmdb({ url: "http://cmdb:1", tokenFile: join(dir, "absent") }).query().catch((e: Error) => e.message);
  check(String(none).startsWith("no token at"), "no token file: says so");
  const got: CmdbChange[] = [];
  const links: boolean[] = [];
  const stop = c.subscribe((x) => got.push(x), (u) => links.push(u));
  await sleep(40);
  stop();
  check(got.length >= 1 && got[0].id === 9, "the stream's change reaches the subscriber");
  check(links[0] === true && links[1] === false && links.length >= 3, "a stream that ended reconnects");
  g.fetch = real;
}

async function live(): Promise<void> {
  const cmdb = new FakeCmdb();
  let reads = 0;
  const cached = new Cached<HealthGraph>("g", 0, async () => {
    reads++;
    return graph(cmdb.site);
  });
  const hl = new HealthLive(cached, cmdb, () => undefined, 5);
  const patches: { relayout: boolean; n: number }[] = [];
  hl.subscribe((p) => patches.push({ relayout: p.relayout, n: p.patches.length }));
  hl.start();
  await hl.read();
  check(reads === 1, "the read is cached");
  await hl.read();
  check(reads === 1, "and stays cached with no change");
  cmdb.link(true);
  await sleep(30);
  check(hl.linked && reads === 2 && patches.length === 1 && patches[0].relayout, "linked: read again, the first document is a layout");
  cmdb.set("gitea", [{ type: "operational", status: "ok" }]);
  for (let i = 0; i < 5; i++) cmdb.tell();
  await sleep(30);
  check(reads === 3, "a burst of changes is one read");
  check(patches.length === 2 && patches[1].n === 1 && !patches[1].relayout, "the colour goes out as a patch");
  cmdb.tell();
  await sleep(30);
  check(patches.length === 2, "a change that moved nothing sends nothing");
  hl.stop();
}

async function routes(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-health-"));
  mkdirSync(join(dir, "state"), { recursive: true });
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "t"), identityFile: join(dir, "i"), trustLocalHeaders: false, gate: null as never };
  const cmdb = new FakeCmdb();
  const fs = fakeSite();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: fs.run, journalDays: 7, cmdb: cmdb.asCmdb(), now: () => NOW });
  const srv = new ConsoleServer({ access, webDir: null, mgmtDomain: "m", version: "t", log: () => undefined }, reads);
  const call = async (url: string): Promise<{ status: number; json: { data?: Record<string, unknown> | null; error?: string | null } }> => {
    let body = "";
    const res = { statusCode: 200, headersSent: false, setHeader() {}, end(d?: string) { body = d ?? ""; } };
    await srv.handle({ method: "GET", url, headers: { host: "c" }, socket: { remoteAddress: "127.0.0.1", destroy() {} } } as unknown as IncomingMessage, res as unknown as ServerResponse);
    return { status: res.statusCode, json: JSON.parse(body) };
  };

  const g = await call("/api/v1/health/graph");
  check(g.status === 200 && (g.json.data?.nodes as unknown[]).length === 22 && (g.json.data?.roots as unknown[]).length === 2, "health/graph: the objects and the roots");
  check(cmdb.calls.includes("relations part-of") && cmdb.calls.includes("relations serves"), "it reads the impact relations and part-of");
  const n = cmdb.calls.filter((c) => c === "query").length;
  await call("/api/v1/health/graph");
  check(cmdb.calls.filter((c) => c === "query").length === n, "the graph is cached");

  const past = await call("/api/v1/health/graph?at=2026-10-29T00:00:00Z");
  check(past.status === 200 && cmdb.at[0] === "2026-10-29T00:00:00.000Z" && past.json.data?.at === "2026-10-29T00:00:00.000Z", "health/graph?at= reads the CMDB as of a moment");
  check((await call("/api/v1/health/graph?at=soon")).status === 400, "a time that is no date is refused");

  const o = await call(`/api/v1/health/object/${ids.nextcloud}`);
  const d = o.json.data!;
  check((d.conditions as unknown[]).length === 2 && (d.rootCauses as { label: string }[])[0].label === "tappaas2", "health/object: the conditions and the root cause");
  check((d.relations as { direction: string }[]).some((r) => r.direction === "in") && (d.relations as { direction: string }[]).some((r) => r.direction === "out"), "relations both ways");
  check((d.history as unknown[]).length === 1 && (d.changes as unknown[]).length === 1, "its history and its changes");
  const root = await call(`/api/v1/health/object/${ids.tappaas2}`);
  check((root.json.data?.impacts as unknown[]).length === 3, "a root's panel lists what it impacts");
  const ackd = await call(`/api/v1/health/object/${ids["pbs-store"]}`);
  check((ackd.json.data?.conditions as { ack: { by: string } }[])[0].ack.by === "lars", "the acknowledgement: by whom");
  check((await call("/api/v1/health/object/not-an-id")).status === 400, "an id that is no id never reaches the CMDB");

  const r = await call("/api/v1/health/roots");
  check(r.json.data?.from === "health-manager", "health/roots: the verb's answer");
  const s = await call("/api/v1/health/summary");
  check(s.json.data?.available === true, "health/summary");
  check((await call("/api/v1/health/nothing")).status === 404, "an unknown health route");
  check(typeof ((await call("/api/v1/health")).json.data as { gates?: unknown } | null)?.gates === "object", "health itself is still validate's document");

  // The CMDB down, or no client: the console keeps working.
  cmdb.down = true;
  const r2 = await call("/api/v1/health/roots");
  check(r2.json.data?.from === "graph" && !!r2.json.data?.error, "health/roots falls back on the graph's");
  const bare = new ConsoleServer({ access, webDir: null, mgmtDomain: "m", version: "t", log: () => undefined }, new Reads({ configDir: dir, stateDir: join(dir, "state"), run: fs.run, journalDays: 7 }));
  const bareCall = async (url: string): Promise<{ data?: Record<string, unknown> | null; error?: string | null }> => {
    let body = "";
    const res = { statusCode: 200, headersSent: false, setHeader() {}, end(d?: string) { body = d ?? ""; } };
    await bare.handle({ method: "GET", url, headers: { host: "c" }, socket: { remoteAddress: "127.0.0.1", destroy() {} } } as unknown as IncomingMessage, res as unknown as ServerResponse);
    return JSON.parse(body);
  };
  check((await bareCall("/api/v1/health/summary")).data?.available === false, "no CMDB: the summary says not available");
  const g2 = await bareCall("/api/v1/health/graph");
  check(g2.data === null && !!g2.error, "no CMDB: the graph says why");
  check(Array.isArray((await bareCall("/api/v1/modules")).data), "no CMDB: the modules still read");
}

// ack, unack and maintenance are health-manager's verbs: the job model takes
// them from its manifest, so a job is what the manifest says it is.
function verbs(): void {
  const v = (verb: string, positionals: string[], options: string[]) => ({
    verb, keys: [[verb]], summary: "", usage: verb, details: "", open: false, effect: "write", preview: { kind: "none", touches: "the CMDB" },
    positionals: positionals.map((name) => ({ name, optional: false, repeatable: false })),
    options: options.map((flag) => ({ flag, arg: "x", takesValue: true, repeatable: false, choices: null, description: "" })),
  });
  const m = normalize({ manifest: 1, name: "health-manager", version: "1", common: [], verbs: [v("ack", ["ci"], ["--type", "--until", "--note"]), v("unack", ["ci"], ["--type"]), v("maintenance", ["ci"], ["--until", "--note"])] } as never);
  const ms: Manifests = { byBin: new Map([["health-manager", m]]), errors: [], loadedAt: "" };
  const a = validateArgv(ms, ["health-manager", "ack", ids.tappaas2, "--type", "operational", "--note", "replacing the PSU"]);
  check(a.ok && !a.read, "ack is a write the job model accepts");
  check(validateArgv(ms, ["health-manager", "unack", ids.tappaas2]).ok && validateArgv(ms, ["health-manager", "maintenance", ids.tappaas2, "--until", "2026-11-01"]).ok, "unack and maintenance too");
  check(!validateArgv(ms, ["health-manager", "ack", ids.tappaas2, "--force"]).ok, "an option its help does not declare is refused");
}

async function main(): Promise<void> {
  pure();
  await client();
  await live();
  await routes();
  verbs();
  done("health");
}

void main();
