// healthgraph.test.ts — the Health view's ego graph as data over the fixture
// site (web/src/healthgraph.ts): what the backend's reads become on the page,
// an expansion and its fold, what the filters keep, a live patch.

import { buildHealth, healthEgo, healthPath } from "../../src/health";
import { BIG_GROUP, Card, EgoState, NO_FILTERS, boundsOf, egoCards, expand, fold, hubsOf, kept, keptRollup, patchEgo, patchPaths, patchRows, rollup, shapeOf, statusClass, viewFor, wrapRanks } from "../../web/src/healthgraph";
import { HealthEgo, HealthPatch, HealthPath, TreeNode } from "../../web/src/types";
import { check, done } from "./check";
import { healthSite, relationTypes } from "./fake-cmdb";

const NOW = Date.parse("2026-10-30T09:00:00Z");
const site = healthSite();
const ids = site.ids;
const g = buildHealth({ objects: site.objects, relations: site.relations, relationTypes: relationTypes(), modules: ["nextcloud"], now: NOW });
const read = (id: string): HealthEgo => healthEgo(g, id)! as unknown as HealthEgo;
const chain = (id: string, to: "root" | "impact"): HealthPath => healthPath(g, id, to)! as unknown as HealthPath;
const state = (center: string, more: Partial<EgoState> = {}): EgoState => ({ center, anchors: [{ id: center, parent: null }], reads: new Map([[center, read(center)]]), paths: [], openGroups: new Set(), ...more });
const card = (cards: Card[], id: string) => cards.find((c) => c.id === id);
const nodes = (cards: Card[]) => cards.filter((c) => c.node);
const pills = (cards: Card[]) => cards.filter((c) => c.group);

// One hop: the object, a pill per relation type, its neighbours through them.
const one = egoCards(state(ids.tappaas2));
check(nodes(one.cards).length === 5 && card(one.cards, ids.tappaas2)?.minus === false, "the object and its four neighbours");
check(pills(one.cards).length === 3, "grouped: guests, cluster, asset");
const guests = pills(one.cards).find((c) => c.group!.type === "runs-on")!;
check(one.lines.some((l) => l.source === ids.tappaas2 && l.target === guests.id), "what runs on it hangs below it");
check(one.lines.some((l) => l.source === guests.id && l.target === ids.nextcloud), "and each guest below the pill");
const up = pills(one.cards).find((c) => c.group!.type === "member-of")!;
check(one.lines.some((l) => l.target === ids.tappaas2 && l.source === up.id) && one.lines.some((l) => l.source === ids.cluster && l.target === up.id), "what it needs stands above it");
check(card(one.cards, ids.nextcloud)?.plus === true && card(one.cards, ids.nextcloud)?.via === ids.tappaas2, "a neighbour with more behind it has a plus");
check(one.lines.every((l) => card(one.cards, l.source) && card(one.cards, l.target)), "every line has a card at both ends");
check(egoCards({ ...state(ids.tappaas2), reads: new Map() }).cards.length === 0, "nothing read yet: nothing drawn");

const twice = egoCards(state(ids.nextcloud));
check(pills(twice.cards).filter((c) => c.members.some((m) => m.id === ids["nc-svc"])).length === 2 && !twice.lines.some((l) => l.source === ids.nextcloud && l.target === ids["nc-svc"]), "a neighbour by two relations: under both pills, no third line");

// Plus and minus.
let anchors = expand([{ id: ids.tappaas2, parent: null }], ids.nextcloud, ids.tappaas2);
const two = egoCards(state(ids.tappaas2, { anchors, reads: new Map([[ids.tappaas2, read(ids.tappaas2)], [ids.nextcloud, read(ids.nextcloud)]]) }));
check(!!card(two.cards, ids["nc-svc"]) && card(two.cards, ids.nextcloud)?.minus === true && card(two.cards, ids.nextcloud)?.plus === false, "a plus opens one hop, and is a minus now");
check(two.cards.filter((c) => c.id === ids.tappaas2).length === 1 && two.lines.filter((l) => l.source === ids.tappaas2 && l.target === ids.nextcloud).length === 0, "the way back is not drawn again");
check(card(two.cards, ids["nc-svc"])?.via === ids.nextcloud, "what it opened knows where from");
anchors = expand(anchors, ids["nc-svc"], ids.nextcloud);
check(expand(anchors, ids.nextcloud, ids.tappaas2).length === 3, "expanding twice is once");
check(fold(anchors, ids.nextcloud).map((a) => a.id).join() === ids.tappaas2, "a fold takes what was opened through it along");
check(fold(anchors, ids["nc-svc"]).length === 2, "and leaves the rest");
check(shapeOf(one.cards, one.lines) !== shapeOf(two.cards, two.lines) && shapeOf(one.cards, one.lines) === shapeOf(egoCards(state(ids.tappaas2)).cards, egoCards(state(ids.tappaas2)).lines), "the shape moves with the cards, and only then");

// The two shortcuts.
const down = egoCards(state(ids.tappaas2, { paths: [chain(ids.tappaas2, "impact")] }));
check(!!card(down.cards, ids["nc-svc"]), "what this impacts reaches past one hop");
const strong = down.lines.filter((l) => l.strong);
check(strong.length === 3 && strong.every((l) => !l.dashed), "its lines are strong");
check(strong.some((l) => l.source === ids.tappaas2 && l.target === ids.immich) && !pills(down.cards).some((c) => c.members.some((m) => m.id === ids.immich)), "a symptom on the chain is out of its pill");
const toRoot = egoCards(state(ids["nc-svc"], { paths: [chain(ids["nc-svc"], "root")] }));
check(!!card(toRoot.cards, ids.tappaas2) && toRoot.lines.some((l) => l.source === ids.tappaas2 && l.target === ids.nextcloud && l.strong), "to the root: up the chain");
check(egoCards(state(ids["pbs-store"], { paths: [chain(ids["pbs-store"], "impact")] })).lines.some((l) => l.dashed && l.strong && l.target === ids.backup), "assess's word alone is dashed");
check(card(toRoot.cards, ids.tappaas2)?.node?.isRoot === true, "the root is marked");

// A big group stands folded, what needs a look still out.
const crowd: HealthEgo = JSON.parse(JSON.stringify(read(ids.tappaas2)));
const many = Array.from({ length: BIG_GROUP + 4 }, (_, i) => ({ ...crowd.nodes[0], id: `n${i}`, status: "ok" as "ok" | "critical", label: `n${i}`, issues: [], rootCause: [], acknowledged: false, maintenance: false }));
many[2] = { ...many[2], status: "critical" };
const key = crowd.groups.find((x) => x.type === "runs-on")!.key;
crowd.nodes = [...crowd.nodes, ...many];
crowd.groups.find((x) => x.key === key)!.neighbours = many.map((n) => n.id);
const closed = egoCards(state(ids.tappaas2, { reads: new Map([[ids.tappaas2, crowd]]) }));
const pill = pills(closed.cards).find((c) => c.group!.key === key)!;
check(pill.members.length === many.length && pill.folded === many.length - 1 && !!card(closed.cards, "n2") && !card(closed.cards, "n3"), "folded: the pill, and the one in trouble");
check(!!card(egoCards(state(ids.tappaas2, { reads: new Map([[ids.tappaas2, crowd]]), openGroups: new Set([key]) })).cards, "n3"), "a click opens it");

// Filters dim; the status of a type recolours.
const node = (k: string) => g.nodes.find((n) => n.id === ids[k])! as never;
check(kept(node("nextcloud"), { ...NO_FILTERS, type: "impact" }) && !kept(node("gitea"), { ...NO_FILTERS, type: "impact" }), "a type keeps what has it not ok");
check(kept(node("nextcloud"), { ...NO_FILTERS, class: "vm", environment: "home" }) && !kept(node("tappaas1"), { ...NO_FILTERS, class: "vm" }), "class and environment");
check(viewFor(node("gitea"), { ...NO_FILTERS, type: "operational" }).status === "warning" && viewFor(node("nextcloud"), { ...NO_FILTERS, type: "backup" }).status === "ok", "the colour under a type filter is that type's");
const row = g.tree.rollups.get(ids.env)! as never;
check(keptRollup(row, NO_FILTERS) && keptRollup(row, { ...NO_FILTERS, class: "zone" }) && !keptRollup(row, { ...NO_FILTERS, class: "user" }), "a tree row stays lit when something under it is kept");
check(keptRollup(row, { ...NO_FILTERS, environment: "home", type: "operational" }) && !keptRollup(row, { ...NO_FILTERS, type: "drift" }), "by environment and type too");
check(statusClass(rollup([{ status: "critical", type: null, reason: null, since: null, acknowledged: true, maintenance: false, flapping: false }])) === "hc-critical hc-ack", "a silenced one is hatched");

// The box to fit.
const box = boundsOf([{ position: { x: 0, y: 0 }, data: { g: { w: 100, h: 50 } } }, { position: { x: 1000, y: 0 }, data: { g: { w: 100, h: 50 } } }])!;
check(box.width === 1100 && box.height === 320 && box.x === 0 && box.y === -135, "the box holds every card, and is never tiny");
check(boundsOf([]) === null, "no cards: no box");

// The stream: colours over what is shown, nothing moved.
const patch: HealthPatch = { topology: g.topology, relayout: false, generated: "2026-10-30T10:00:00Z", patches: [{ ...read(ids.tappaas2).center, status: "ok", reason: null } as never], rollups: { [ids.tappaas2]: { ...g.tree.rollups.get(ids.tappaas2)!, status: "ok", notOk: 0 } as never }, roots: [], counts: g.counts as never, hasConditions: true };
const reads = patchEgo(new Map([[ids.nextcloud, read(ids.nextcloud)]]), patch);
const was = read(ids.nextcloud).nodes.find((n) => n.id === ids.tappaas2)!;
const now = reads.get(ids.nextcloud)!.nodes.find((n) => n.id === ids.tappaas2)!;
check(now.status === "ok" && now.more === was.more, "a colour moved: the card keeps its plus");
check(patchPaths([chain(ids["nc-svc"], "root")], patch)[0].nodes.find((n) => n.id === ids.tappaas2)?.status === "ok", "a chain is patched too");
const rows = [{ id: ids.tappaas2, status: "critical", notOk: 4, label: "tappaas2" }, { id: ids.tappaas1, status: "warning", notOk: 1, label: "tappaas1" }] as unknown as TreeNode[];
const after = patchRows(rows, patch.rollups);
check(after[0].status === "ok" && after[0].notOk === 0 && after[0].label === "tappaas2" && after[1].status === "warning", "a tree row takes the roll-up, the rest stay");

// A wide rank wraps to use the canvas's height: one object over 30 neighbours,
// as dagre lays it out on one line, on a 1000×600 canvas.
const fan = [{ id: "c", x: 3405, y: 0, w: 210, h: 62 }, ...Array.from({ length: 30 }, (_, i) => ({ id: `n${i}`, x: i * 232, y: 114, w: 210, h: 62 }))];
const wrapped = wrapRanks(fan, { width: 1000, height: 600 }, 22, 52);
const at = (id: string) => wrapped.get(id) ?? fan.find((b) => b.id === id)!;
const rowsY = new Set(fan.slice(1).map((b) => at(b.id).y));
const wide = Math.max(...fan.map((b) => at(b.id).x + b.w)) - Math.min(...fan.map((b) => at(b.id).x));
const tall = Math.max(...fan.map((b) => at(b.id).y + b.h)) - Math.min(...fan.map((b) => at(b.id).y));
check(rowsY.size > 1 && wide < 30 * 232 && tall > 176, "a wide rank wraps into rows");
check(Math.min(1000 / wide, 600 / tall) > 2 * Math.min(1000 / (30 * 232), 600 / 176), "  and fits the canvas at more than twice the scale");
check(fan.slice(1).every((b) => at(b.id).y > at("c").y + 62), "  every row below its parent");
check(wrapRanks(fan.slice(0, 4), { width: 1000, height: 600 }, 22, 52).size === 0, "a narrow graph keeps dagre's places");

// A hub's members stand as its own cluster: the environment "Rossen" as dagre
// lays it out, five zones and an organisation in one rank above, 16 members below.
const hubbed = hubsOf(one.cards, one.lines);
check(hubbed.length === 3 && hubbed.find((h) => h.id === guests.id)?.up === false && hubbed.find((h) => h.id === up.id)?.members.join() === ids.cluster, "a hub knows its side and its members");
check(hubsOf(twice.cards, twice.lines).flatMap((h) => h.members).filter((m) => m === ids["nc-svc"]).length === 1, "a neighbour by two relations belongs to one of them");

const upper = [...Array.from({ length: 5 }, (_, i) => `z${i}`), "org"];
const lower = Array.from({ length: 16 }, (_, i) => `m${i}`);
const row0 = (names: string[], y: number, w = 232) => names.map((id, i) => ({ id, x: i * w, y, w: 210, h: 62 }));
const env = (below: boolean): typeof fan => [
  ...row0(upper, 0),
  { id: "serves", x: 469, y: 127, w: 200, h: 36 },
  { id: "owned", x: 1165, y: 127, w: 200, h: 36 },
  { id: "c", x: 700, y: 228, w: 210, h: 62 },
  ...(below ? [{ id: "members", x: 705, y: 355, w: 200, h: 36 }, ...row0(lower, 456).map((b) => ({ ...b, x: b.x - 1040 }))] : []),
];
const envHubs = (below: boolean) => [
  { id: "serves", anchor: "c", up: true, members: upper.slice(0, 5) },
  { id: "owned", anchor: "c", up: true, members: ["org"] },
  ...(below ? [{ id: "members", anchor: "c", up: false, members: lower }] : []),
];
const pos = (b: typeof fan, m: Map<string, { x: number; y: number }>) => (id: string) => ({ ...b.find((x) => x.id === id)!, ...m.get(id) });
const mid = (p: { x: number; w: number }) => p.x + p.w / 2;
const clear = (b: typeof fan, m: Map<string, { x: number; y: number }>) => {
  const all = b.map((x) => pos(b, m)(x.id));
  return all.every((p, i) => all.slice(i + 1).every((q) => p.x + p.w <= q.x || q.x + q.w <= p.x || p.y + p.h <= q.y || q.y + q.h <= p.y));
};

const sparse = env(false);
const roomy = wrapRanks(sparse, { width: 2400, height: 900 }, 22, 52, 1.25, envHubs(false));
const p1 = pos(sparse, roomy);
const zones = upper.slice(0, 5).map(p1);
check(Math.abs(mid(p1("serves")) - (zones[0].x + zones[4].x + 210) / 2) < 1e-6 && mid(p1("org")) === mid(p1("owned")), "two hubs: each centred under its own");
check(zones[4].x + 210 + 22 < p1("org").x && p1("serves").x + 200 < p1("owned").x, "  two separated clusters");
check(p1("org").y === zones[0].y && p1("org").y + 62 < p1("owned").y, "  side by side, above their pills");
check(p1("c").x === 700 && Math.abs((zones[0].x + p1("org").x + 210) / 2 - mid(p1("c"))) < 1e-6, "  and the selected card stays, centred under them");

const full = env(true);
const tight = wrapRanks(full, { width: 1000, height: 800 }, 22, 52, 1.25, envHubs(true));
const p2 = pos(full, tight);
const zs = upper.slice(0, 5).map(p2);
check(new Set(zs.map((z) => z.y)).size > 1 && new Set(lower.map((id) => p2(id).y)).size > 1, "a wide cluster wraps within itself");
check(Math.max(...zs.map((z) => z.x + 210)) < p2("org").x, "  and never across clusters");
check(p2("org").y === Math.max(...zs.map((z) => z.y)) && p2("org").y < p2("owned").y, "  a short cluster sits on the row next to its pill");
check(Math.abs(mid(p2("org")) - mid(p2("owned"))) < 1e-6 && Math.abs(mid(p2("serves")) - (Math.min(...zs.map((z) => z.x)) + Math.max(...zs.map((z) => z.x)) + 210) / 2) < 1e-6, "  each hub still centred on its own");
check(p2("c").x === 700 && Math.max(...zs.map((z) => z.y)) < p2("serves").y && lower.every((id) => p2(id).y > p2("members").y), "  above stays above, below below");
check(clear(full, tight), "  no two cards overlap");

const oneHub = [{ id: "pill", x: 3410, y: 114, w: 200, h: 36 }, { id: "c", x: 3405, y: 0, w: 210, h: 62 }, ...Array.from({ length: 30 }, (_, i) => ({ id: `n${i}`, x: i * 232, y: 202, w: 210, h: 62 }))];
const lone = [{ id: "pill", anchor: "c", up: false, members: oneHub.slice(2).map((b) => b.id) }];
const same = (a: Map<string, { x: number; y: number }>, b: Map<string, { x: number; y: number }>) => a.size === b.size && [...a].every(([id, m]) => b.get(id)?.x === m.x && b.get(id)?.y === m.y);
check(same(wrapRanks(oneHub, { width: 1000, height: 600 }, 22, 52, 1.25, lone), wrapRanks(oneHub, { width: 1000, height: 600 }, 22, 52)), "a single hub: today's places, wrapped");
check(wrapRanks(oneHub.slice(0, 5), { width: 3000, height: 900 }, 22, 52, 1.25, [{ ...lone[0], members: ["n0", "n1", "n2"] }]).size === 0, "  and unwrapped");

// Opening a member: its hubs hang from where it now stands, nothing overlaps.
const opened = [...full, { id: "under", x: 300, y: 583, w: 200, h: 36 }, { id: "under2", x: 900, y: 583, w: 200, h: 36 }, ...row0(["u0", "u1"], 684), { id: "u2", x: 900, y: 684, w: 210, h: 62 }];
const openHubs = [...envHubs(true), { id: "under", anchor: "m3", up: false, members: ["u0", "u1"] }, { id: "under2", anchor: "m3", up: false, members: ["u2"] }];
const grown = wrapRanks(opened, { width: 1000, height: 800 }, 22, 52, 1.25, openHubs);
const p3 = pos(opened, grown);
check(clear(opened, grown) && p3("u0").y > p3("under").y && Math.abs((mid(p3("under")) + mid(p3("under2"))) / 2 - mid(p3("m3"))) < 120, "an opened member: its clusters under it, nothing overlapping");

done("healthgraph");
