// healthgraph.test.ts — the Health view's graph as data over the fixture site
// (web/src/healthgraph.ts, tiers.ts): what the backend's document becomes on the
// page. The console has no DOM in its tests; every decision the page takes
// about a card or a line is here, the drawing is React Flow's.

import { buildHealth } from "../../src/health";
import { Card, NO_FILTERS, applyPatch, boundsOf, centreCards, collapse, groupsOf, hotSet, kept, replay, rollup, statusClass, viewFor } from "../../web/src/healthgraph";
import { tierPositions } from "../../web/src/tiers";
import { HealthGraph } from "../../web/src/types";
import { check, done } from "./check";
import { healthSite } from "./fake-cmdb";

const NOW = Date.parse("2026-10-30T09:00:00Z");
const site = healthSite();
const ids = site.ids;
// The backend's document is the front end's type: tsc holds the two together.
const doc: HealthGraph = buildHealth({ objects: site.objects, relations: site.relations, modules: ["nextcloud"], now: NOW });

const closed = collapse(doc, new Set());
const card = (cs: Card[], id: string) => cs.find((c) => c.id === id);
const home = card(closed.cards, "environment:home")!;
check(home.kind === "group" && home.members.length === 4, "collapsed by default: an environment's objects are one card");
check(!card(closed.cards, ids.nextcloud), "a member has no card of its own");
check(rollup(home.members).status === "critical", "the group's colour is its worst member");
check(closed.lines.every((l) => l.source !== l.target), "no line inside a collapsed group");
const down = closed.lines.find((l) => l.source === "environment:home" && l.target === ids.tappaas2);
check(!!down && down.ids.length === 2 && down.types.join() === "runs-on", "two guests on one machine are one line, standing for both");
check(closed.lines.every((l) => (card(closed.cards, l.source)?.tier ?? 0) >= (card(closed.cards, l.target)?.tier ?? 0)), "every line runs downward, from what depends");
const zoneLine = closed.lines.find((l) => l.types.includes("serves"));
check(zoneLine?.source === ids.env && zoneLine.target === ids.zone, "a zone serves the environment above it");

const opened = collapse(doc, new Set(["environment:home"]));
const parent = card(opened.cards, "environment:home")!;
const child = card(opened.cards, ids.nextcloud)!;
check(parent.kind === "open" && child.parent === "environment:home" && !!child.at, "opened: a sub-flow with its members inside");
check(parent.w > child.w && parent.h > child.h && child.at!.x + child.w <= parent.w && child.at!.y + child.h <= parent.h, "the parent holds its cards");
check(opened.lines.some((l) => l.source === ids.nextcloud && l.target === ids.tappaas2), "a member's line ends on the member");
check(opened.lines.some((l) => l.from.includes(ids["nc-svc"]) && l.to.includes(ids.nextcloud)), "a line inside an open group");

// Root causes first.
const hot = hotSet(doc, null)!;
check(hot.has(ids.tappaas2) && hot.has(ids.nextcloud) && !hot.has(ids["pbs-store"]), "the page lights the open roots and their symptoms, not an acknowledged one");
check(hotSet(doc, ids["pbs-store"])!.has(ids.backup), "chosen from the side list, an acknowledged root lights too");
const healthy = { ...doc, roots: [] };
check(hotSet(healthy, null) === null, "a healthy site dims nothing");
check(centreCards(healthy, closed.cards, null).join() === ids.site, "a healthy site opens on the site card");
check(centreCards(doc, closed.cards, null).join() === `${ids.tappaas2},${ids["pbs-store"]}`, "the page opens on the roots");
const inGroup = { ...doc, roots: [{ ...doc.roots[0], id: ids.gitea }] };
check(centreCards(inGroup, closed.cards, null).join() === "environment:home", "a root in a collapsed group centres on its group");
check(groupsOf(doc, [ids.gitea, ids.tappaas2]).join() === "environment:home", "the groups to open for a root");

const placed = [
  { id: "p", position: { x: 100, y: 100 }, data: { g: { w: 500, h: 300 } } },
  { id: "k", position: { x: 20, y: 40 }, parentId: "p", data: { g: { w: 200, h: 60 } } },
  { id: "far", position: { x: 2000, y: 900 }, data: { g: { w: 200, h: 60 } } },
];
const one = boundsOf(placed, ["k"])!;
check(one.width === 760 && one.x + one.width / 2 === 220 && one.y + one.height / 2 === 170, "one card: a box around it, in the parent's coordinates");
check(boundsOf(placed, ["k", "far"])!.width === 2080, "two cards: both in the box");
check(boundsOf(placed, ["nope"]) === null, "nothing to fit: nothing moves");

// Colours.
const node = (k: string) => doc.nodes.find((n) => n.id === ids[k])!;
check(statusClass(node("pbs-store")) === "hc-critical hc-ack", "acknowledged: hatched over its status");
check(statusClass(node("logging")) === "hc-warning hc-maint", "maintenance: dotted");
check(statusClass(node("u1")) === "hc-unknown", "unknown: grey");
check(rollup([node("pbs-store"), node("logging")]).status === "critical" && rollup([node("pbs-store"), node("logging")]).acknowledged, "a group with only silenced trouble is silenced");
check(rollup([node("pbs-store"), node("gitea")]).status === "warning", "a counting warning beats a silenced critical");
check(rollup([node("gitea")]).flapping, "a group shows flapping");

// Filters keep the layout; they dim, and a type recolours.
check(kept(node("pbs-store"), { ...NO_FILTERS, type: "capacity" }) && !kept(node("tappaas2"), { ...NO_FILTERS, type: "capacity" }), "a condition type keeps what has it");
check(kept(node("gitea"), { ...NO_FILTERS, environment: "home" }) && !kept(node("backup"), { ...NO_FILTERS, environment: "home" }), "an environment keeps its own");
check(kept(node("gitea"), { ...NO_FILTERS, class: "vm" }) && !kept(node("tappaas2"), { ...NO_FILTERS, class: "vm" }), "a class keeps its own");
check(viewFor(node("nextcloud"), { ...NO_FILTERS, type: "drift" }).status === "ok", "under a type filter the colour is that type's");

// Live.
const after = buildHealth({ objects: site.objects.map((o) => (o.id === ids.gitea ? { ...o, attributes: { ...o.attributes, conditions: [{ type: "operational", status: "ok" }] } } : o)), relations: site.relations, modules: ["nextcloud"], now: NOW });
const patched = applyPatch(doc, { topology: doc.topology, relayout: false, generated: "later", patches: after.nodes.filter((n) => n.id === ids.gitea), roots: after.roots, counts: after.counts, hasConditions: true });
check(patched.nodes.find((n) => n.id === ids.gitea)!.status === "ok" && patched.nodes !== doc.nodes, "a patch moves the colour");
check(patched.topology === doc.topology, "and leaves the layout's key");

// The slider.
const past = { ...doc, nodes: doc.nodes.filter((n) => n.id !== ids.gitea).map((n) => ({ ...n, status: "ok" as const })), roots: [] };
const then = replay(doc, past);
check(then.nodes.length === doc.nodes.length && then.nodes.find((n) => n.id === ids.tappaas2)!.status === "ok", "the past's colours on the graph of now");
check(then.nodes.find((n) => n.id === ids.gitea)!.reason === "not in the CMDB then", "what did not exist then says so");
check(replay(doc, null) === doc, "no moment: now");

// The rows.
const pos = tierPositions([
  { id: "site", w: 100, h: 50, tier: 9, x: 400 },
  { id: "a", w: 100, h: 50, tier: 4, x: 100 },
  { id: "b", w: 100, h: 50, tier: 4, x: 100 },
  { id: "c", w: 100, h: 50, tier: 4, x: 700 },
  { id: "m", w: 100, h: 50, tier: 2, x: 100 },
], 20, 70);
check(pos.get("site")!.y === 0 && pos.get("a")!.y === 120 && pos.get("m")!.y === 240, "the higher tier on top, one row each, empty tiers leave no gap");
check(pos.get("b")!.x >= pos.get("a")!.x + 120 && pos.get("c")!.x >= pos.get("b")!.x + 120, "cards in a row do not overlap");
check(pos.get("a")!.x + 50 < pos.get("c")!.x + 50, "dagre's order is kept");

done("healthgraph");
