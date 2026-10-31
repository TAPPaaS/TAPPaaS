// health.test.ts — the Health view's backend over the fixture site
// (fake-cmdb.ts): the worst condition and what silences it, roots and their
// symptoms, the tree and its roll-ups, the ego graph and the derivation's
// chains, the summary the other pages read, the history, the client's stream,
// the live feed, the routes, and ack as a job.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig } from "../../src/access";
import { withConditions } from "../../src/badges";
import { Cached } from "../../src/cache";
import { Cmdb, CmdbChange, parseFrame, splitFrames } from "../../src/cmdb";
import { Condition, HealthGraph, HealthPath, buildHealth, conditionHistory, diffHealth, healthEgo, healthPath, healthSummary, healthTree, issueOf, moduleHealth, rollupOf, treeChildren, treePath, treeSearch, viewOf } from "../../src/health";
import { HealthLive } from "../../src/healthlive";
import { Manifests, normalize, validateArgv } from "../../src/manifest";
import { Reads } from "../../src/reads";
import { ConsoleServer } from "../../src/server";
import { check, done } from "./check";
import { FakeCmdb, healthSite, relationTypes } from "./fake-cmdb";
import { fakeSite } from "./fake-site";

const NOW = Date.parse("2026-10-30T09:00:00Z");
const MODULES = ["nextcloud", "immich", "gitea", "backup", "logging"];
const site = healthSite();
const ids = site.ids;
const graph = (s = site): HealthGraph => buildHealth({ objects: s.objects, relations: s.relations, relationTypes: relationTypes(), modules: MODULES, now: NOW });

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

  check(node("nextcloud").environment === "home" && node("nc-svc").environment === "home" && node("backup").environment === "mgmt", "an object knows its environment: its membership, its host's, its own word");
  check(g.edges.length === site.relations.length, "every relation is an edge");

  check(node("nc-svc").module === "nextcloud" && node("nextcloud").module === "nextcloud" && node("tappaas2").module === null, "the module an object belongs to");

  // The summary the pages read.
  const s = healthSummary(g);
  check(s.available && s.counts.critical === 6 && s.counts.acknowledged === 3, "the counts: silenced apart");
  check(s.byType.capacity.status === "ok" && s.byType.capacity.items.length === 1 && s.byType.capacity.items[0].silenced, "an acknowledged capacity condition does not colour its type");
  // Silenced is counted per condition: an ack beside an open condition on the
  // same object counts, and the object keeps the colour of the open one.
  const mixed = healthSite();
  const gitea = mixed.objects.find((o) => o.id === mixed.ids.gitea)!;
  gitea.attributes.conditions = [
    ...(gitea.attributes.conditions as Condition[]),
    { type: "drift", status: "critical", reason: "sweep-drift", acknowledged: { by: "lars", until: null } },
  ];
  const ms = healthSummary(graph(mixed));
  check(ms.counts.acknowledged === 4, "an acknowledged condition beside an open one is silenced too");
  check(ms.counts.warning === s.counts.warning && ms.counts.critical === s.counts.critical, "  and its object keeps the colour of the open one");
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

  // The roll-up of a colour under a live change.
  const fixed = healthSite();
  fixed.objects.find((o) => o.id === ids.gitea)!.attributes.conditions = [{ type: "operational", status: "ok" }];
  const up = diffHealth(g, graph(fixed))!;
  check(up.rollups[ids.gitea]?.status === "ok" && up.rollups[ids.tappaas1]?.notOk === 0 && up.rollups[ids.env]?.notOk === 3, "a colour moved: the roll-ups over it go with it");
  check(up.rollups[ids.tappaas2] === undefined, "and only those");

  tree(g);
  ego(g);

  // The SSE frames.
  check(parseFrame(": keepalive") === null, "a comment is no frame");
  check(parseFrame('event: change\ndata: {"id":1}')?.event === "change", "a frame's event");
  const parts = splitFrames("event: change\ndata: 1\n\nevent: ch");
  check(parts.frames.length === 1 && parts.rest === "event: ch", "a chunk ends mid-frame: the rest waits");
}

function tree(g: HealthGraph): void {
  const t = healthTree(g);
  const facet = (id: string) => t.facets.find((f) => f.id === id)!;
  const kids = (id: string) => treeChildren(g, id)!;
  const names = (id: string) => kids(id).map((n) => n.name).join(" ");
  check(t.facets.map((f) => f.label).join() === "Physical,Environments,Identity,Elsewhere", "three facets, and Elsewhere for what they do not reach");
  check(names("physical") === "HQ", "Physical starts at the location: the site, its rooms and racks are under it");
  check(names(ids.location) === "rossen Server room", "a location holds its rooms and the site that is at it");
  check(names(ids.room) === "Rack A" && names(ids.rack) === "srv-01", "a room its racks, a rack its assets");
  check(names(ids.site) === "srv-02", "an asset owned by the site hangs under it when it is placed nowhere");
  check(names(ids.srv1) === "eno1 eno2 tappaas1", "an asset: its ports and the node allocated to it");
  check(names(ids.tappaas2) === "immich nextcloud", "a machine: its guests");
  check(names(ids.nextcloud) === "nextcloud:nextcloud", "a guest: its software, once though it also provides it");
  check(names(ids.backup) === "tappaas_backup", "a guest: the datastore on it");
  check(names("environments") === "home" && names(ids.env) === "gitea home immich nextcloud", "an environment: its nodes and the zone that serves it");
  check(names(ids.zone) === "10.1.0.5 10.1.0.6", "a zone: its addresses");
  check(names("identity") === "erik rossen", "Identity: organizations, and a user in no group");
  check(names(ids.org) === "admins home" && names(ids.admins) === "lars", "an organization: its groups and environments; a group: its users");
  check(names("elsewhere") === "tappaas", "the cluster nothing places");
  check(kids(ids.tappaas2).find((n) => n.name === "nextcloud")?.children === 1, "a node says how many to open");
  const port = kids(ids.srv1).find((n) => n.id === ids.p1)!;
  check(port.children === 1 && names(ids.p1) === "eno1", "a port lists what it connects");
  check(kids(ids.p1)[0].children === 0, "the far end of a cable is a leaf: the tree does not run on through it");
  check(!treeChildren(g, "nope") && treeChildren(g, "elsewhere") !== null, "no such row: null");

  // Roll-ups: over the subtree, from the conditions.
  const r = g.tree.rollups;
  check(r.get(ids.tappaas2)?.status === "critical" && r.get(ids.tappaas2)?.notOk === 4, "the machine down: itself, its guests, their service");
  check(r.get(ids.tappaas1)?.status === "warning" && r.get(ids.tappaas1)?.notOk === 1, "the other machine: its silenced guests do not count, the flapping one does");
  check(r.get(ids.env)?.notOk === 4, "an environment's own roll-up condition is not one more object");
  check(r.get(ids.rack)?.notOk === 1 && r.get(ids.srv1)?.status === "warning", "up through the asset to the rack");
  check(r.get(ids.u1)?.status === "unknown" && r.get(ids.u1)?.notOk === 0 && r.get(ids.u1)?.unknown === 1, "unknown is grey, and not counted as not ok");
  check(r.get(ids["pbs-store"])?.status === "critical" && r.get(ids["pbs-store"])?.acknowledged === true, "only a silenced condition: hatched");
  check(r.get(ids.p2)?.status === "ok" && r.get(ids.p2)?.notOk === 0, "a healthy leaf");
  check(facet("physical").status === "critical" && facet("physical").notOk === 5, "a facet rolls up its whole walk");
  check(facet("identity").status === "critical", "Identity sees what the environments it owns hold");
  check(r.get(ids.env)?.types.operational === "critical" && r.get(ids.env)?.classes.includes("zone") === true && r.get(ids.env)?.environments.join() === "home", "what a filter asks of a subtree");
  const both = rollupOf([g.nodes.find((n) => n.id === ids.u1)!, g.nodes.find((n) => n.id === ids.tappaas2)!]);
  check(both.status === "critical" && both.notOk === 1 && both.unknown === 1, "worst of two");

  // Show in tree, and the search.
  const way = treePath(g, ids.nextcloud)!;
  check(way[0] === "physical" && way.at(-2) === ids.tappaas2 && way.at(-1) === ids.nextcloud, "the way down to a guest runs through its machine");
  check(treePath(g, ids.cluster)?.join() === `elsewhere,${ids.cluster}`, "an object elsewhere is found there");
  check(treePath(g, ids.p3)?.at(-1) === ids.p3, "a port");
  check(treePath(g, "nope") === null, "no such object");
  const found = treeSearch(g, "NEXT");
  check(found[0].name === "nextcloud" && found.length === 2 && found[0].where.startsWith("Physical › HQ"), "a search: by name, any case, and where it is");
  check(treeSearch(g, "zone")[0].id === ids.zone, "by class");
  check(treeSearch(g, "  ").length === 0, "nothing asked: nothing found");

  // A CMDB that does not say what contains what: nothing is lost.
  const flat = buildHealth({ objects: site.objects, relations: site.relations, now: NOW });
  check(flat.tree.facets.flatMap((f) => f.roots).length >= flat.nodes.length - 2 && treePath(flat, ids.cluster) !== null, "no containment declared: flat, and every object still found");
  check(healthTree(buildHealth({ objects: [], relations: [], relationTypes: relationTypes(), now: NOW })).facets.length === 3, "an empty CMDB: the facets, no Elsewhere");
}

function ego(g: HealthGraph): void {
  const e = healthEgo(g, ids.tappaas2)!;
  const group = (label: string) => e.groups.find((x) => x.label === label);
  check(e.center.id === ids.tappaas2 && e.center.isRoot, "the object in the middle");
  check(e.nodes.length === 4, "its neighbours and nothing further");
  check(group("contains · runs-on")?.neighbours.length === 2 && group("contains · runs-on")?.side === "down", "what runs on it: one group, below it");
  check(group("member-of")?.side === "up", "what it needs, above it");
  check(healthEgo(g, ids.srv2)!.groups.some((x) => x.label === "contains · allocated-to"), "seen from the asset, the node is what it contains");
  const asset = e.groups.find((x) => x.type === "allocated-to")!;
  check(asset.direction === "in" && asset.side === "up" && asset.neighbours.join() === ids.srv2, "the box it runs on, above it");
  const n = (id: string) => e.nodes.find((x) => x.id === id)!;
  check(n(ids.nextcloud).more && n(ids.cluster).more, "a neighbour with further neighbours has a plus");
  check(!healthEgo(g, ids.u2)!.nodes.length, "an object with no relation stands alone");
  const leaf = healthEgo(g, ids.a1)!;
  check(leaf.nodes.length === 1 && leaf.nodes[0].id === ids.zone && leaf.nodes[0].more, "the zone of an address: more behind it");
  const a2 = healthEgo(g, ids.zone)!.nodes.find((x) => x.id === ids.a2)!;
  check(!a2.more, "an address with nothing but this zone has no plus");
  check(n(ids.nextcloud).status === "critical" && n(ids.nextcloud).reason === "node tappaas2 down", "colours as the graph has them");
  const two = healthEgo(g, ids.tappaas2, 2)!;
  check(two.nodes.some((x) => x.id === ids["nc-svc"]) && two.groups.some((x) => x.anchor === ids.nextcloud), "two hops: grouped from each anchor");
  check(healthEgo(g, "nope") === null, "no such object");

  // The chains of the derivation.
  const has = (p: HealthPath, a: string, b: string) => p.edges.some((x) => x.provider === ids[a] && x.dependant === ids[b]);
  const up = healthPath(g, ids["nc-svc"], "root")!;
  check(up.edges.length === 2 && has(up, "tappaas2", "nextcloud") && has(up, "nextcloud", "nc-svc") && !up.edges.some((x) => x.virtual), "to the root: the service, its guest, the machine");
  check(up.nodes.length === 3 && up.nodes.some((x) => x.id === ids.tappaas2 && x.isRoot), "the chain's objects, the root marked");
  const down = healthPath(g, ids.tappaas2, "impact")!;
  check(down.nodes.length === 4 && has(down, "nextcloud", "nc-svc") && has(down, "tappaas2", "immich"), "what it impacts: along the relations, every symptom");
  check(!down.edges.some((x) => x.virtual), "no line assess alone must vouch for");
  const part = healthPath(g, ids.nextcloud, "impact")!;
  check(part.edges.length === 2 && has(part, "nextcloud", "nc-svc") && has(part, "nc-svc", "immich"), "from a symptom: what fails through it");
  check(healthPath(g, ids.immich, "impact")!.edges.length === 0, "and nothing for the last in the chain");
  const quiet = healthPath(g, ids["pbs-store"], "impact")!;
  check(quiet.edges.length === 1 && quiet.edges[0].virtual && quiet.edges[0].dependant === ids.backup, "no relation shows the way: assess's word, as a virtual line");
  const self = healthPath(g, ids.tappaas2, "root")!;
  check(self.edges.length === 0 && self.nodes.length === 1, "a root is its own root cause");
  check(healthPath(g, ids.u1, "root")!.edges.length === 0 && healthPath(g, ids.u1, "impact")!.edges.length === 0, "a healthy object: no chain either way");
  check(healthPath(g, "nope", "root") === null, "no such object");
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

  const t = await call("/api/v1/health/tree");
  check(t.status === 200 && (t.json.data?.facets as unknown[]).length === 4 && (t.json.data?.roots as unknown[]).length === 2, "health/tree: the facets and the roots");
  check(cmdb.calls.includes("rules") && cmdb.calls.includes("relations "), "it reads the metamodel's relation types and every relation");
  const n = cmdb.calls.filter((c) => c === "query").length;
  await call("/api/v1/health/tree");
  check(cmdb.calls.filter((c) => c === "query").length === n, "the document is cached");
  const kids = await call("/api/v1/health/tree/physical/children");
  check(kids.status === 200 && (kids.json.data as unknown as { name: string }[])[0].name === "HQ", "health/tree/<facet>/children");
  check(((await call(`/api/v1/health/tree/${ids.tappaas2}/children`)).json.data as unknown as unknown[]).length === 2, "health/tree/<id>/children: one level");
  check(((await call(`/api/v1/health/tree/${ids.u2}/path`)).json.data as unknown as string[])[0] === "identity", "health/tree/<id>/path");
  check(((await call("/api/v1/health/tree?q=nextcloud")).json.data as unknown as unknown[]).length === 2, "health/tree?q= searches");
  check((await call("/api/v1/health/tree/not-an-id/children")).status === 400, "a tree id that is no id");
  check((await call("/api/v1/health/tree/00000000-0000-4000-8000-0000000000ff/children")).status === 404, "a tree id the CMDB does not hold");

  const eg = await call(`/api/v1/health/ego/${ids.tappaas2}`);
  check(eg.status === 200 && (eg.json.data?.nodes as unknown[]).length === 4, "health/ego/<id>");
  check(((await call(`/api/v1/health/ego/${ids.tappaas2}?depth=2`)).json.data?.nodes as unknown[]).length > 4, "?depth=2");
  check((await call(`/api/v1/health/ego/${ids.tappaas2}?depth=9`)).status === 400, "a depth out of bounds");
  const past = await call(`/api/v1/health/ego/${ids.tappaas2}?at=2026-10-29T00:00:00Z`);
  check(past.status === 200 && cmdb.at[0] === "2026-10-29T00:00:00.000Z" && past.json.data?.at === "2026-10-29T00:00:00.000Z", "health/ego?at= reads the CMDB as of a moment");
  check((await call(`/api/v1/health/ego/${ids.tappaas2}?at=soon`)).status === 400, "a time that is no date is refused");
  check((await call("/api/v1/health/ego/not-an-id")).status === 400, "an ego id that is no id");
  check((await call("/api/v1/health/ego/00000000-0000-4000-8000-0000000000ff")).status === 404, "an ego of nothing");
  const chain = await call(`/api/v1/health/ego/${ids["nc-svc"]}/path?to=root`);
  check((chain.json.data?.edges as unknown[]).length === 2, "health/ego/<id>/path?to=root");
  check(((await call(`/api/v1/health/ego/${ids.tappaas2}/path?to=impact`)).json.data?.nodes as unknown[]).length === 4, "?to=impact");
  check((await call(`/api/v1/health/ego/${ids.tappaas2}/path?to=sideways`)).status === 400, "a chain to nowhere");
  check((await call("/api/v1/health/graph")).status === 404, "the whole-site graph is gone");

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
  const g2 = await bareCall("/api/v1/health/tree");
  check(g2.data === null && !!g2.error, "no CMDB: the tree says why");
  check((await bareCall(`/api/v1/health/ego/${ids.tappaas2}`)).data === null, "and the ego graph");
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
