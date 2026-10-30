// healthgraph.test.ts — the Health view's ego graph as data over the fixture
// site (web/src/healthgraph.ts): what the backend's reads become on the page,
// an expansion and its fold, what the filters keep, a live patch.

import { buildHealth, healthEgo, healthPath } from "../../src/health";
import { BIG_GROUP, Card, EgoState, NO_FILTERS, boundsOf, egoCards, expand, fold, kept, keptRollup, patchEgo, patchPaths, patchRows, rollup, shapeOf, statusClass, viewFor } from "../../web/src/healthgraph";
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

done("healthgraph");
