// assets.test.ts — the Assets view: the tree the backend builds from the
// positions and the CMDB's allocations (src/assets.ts), the page's plain
// logic (web/src/assetview.ts), and where a side panel's Details link goes
// (web/src/details.ts).

import { AssetPositions, assetTree } from "../../src/assets";
import { CmdbRelationRow } from "../../src/cmdb";
import { allocatedSince, allocationHistory, assetsSelOf, assetsSelText, filterLocation, findAsset, freeWhere, itemsOf, stageCounts, unallocated } from "../../web/src/assetview";
import { assetPath, assetsSelectPath, ciDetails, portAnchor, selDetails } from "../../web/src/details";
import { AssetTree, CiHistoryRow } from "../../web/src/types";
import { check, done } from "./check";

// ── the tree ─────────────────────────────────────────────────────────────

const pos: AssetPositions = {
  assets: [
    { name: "srv-01", kind: "server", displayName: "Node one", vendor: "HP", model: "hp/z840", serial: "S1", stage: "operational", role: "tappaas1", location: "home", placed: true, ports: [{ name: "eth0", kind: "rj45", speed: "1g", mac: "aa:bb" }] },
    { name: "sw-01", kind: "switch", displayName: null, vendor: "Ubiquiti", model: "unifi/usw-24", serial: "S2", stage: "operational", role: "core", location: "home", placed: true, ports: [{ name: "1", kind: "rj45" }, { name: "2", kind: "rj45" }] },
    { name: "srv-02", kind: "server", displayName: null, vendor: null, model: null, serial: null, stage: "stock", role: null, location: "home", placed: false, ports: [] },
    { name: "srv-03", kind: "server", displayName: null, vendor: null, model: null, serial: null, stage: "ordered", role: null, location: "cabin", placed: false, ports: [] },
    { name: "dev-01", kind: "modem", displayName: "Modem", vendor: null, model: null, serial: null, stage: "disposed", role: null, location: "home", placed: false, ports: [] },
    { name: "dev-02", kind: "ups", displayName: null, vendor: null, model: null, serial: null, stage: "placed", role: null, location: "home", placed: true, ports: [] },
  ],
  locations: [
    { name: "home", displayName: "Home", primary: true, rooms: ["cellar"], unplaced: ["ap1", "seen-1"] },
    { name: "cabin", displayName: null, primary: false, rooms: [], unplaced: [] },
  ],
  racks: [
    { name: "r1", displayName: "Rack 1", units: 12, room: "cellar", placements: [{ device: "core", kind: "switch", u: 2, height: 1, face: "front" }, { device: "tappaas1", kind: "node", u: 5, height: 2, face: "front" }] },
    { name: "r9", displayName: null, units: 6, room: null, location: "home", placements: [] },
  ],
  rooms: [{ name: "cellar", displayName: "Cellar", location: "home", recorded: true, racks: ["r1"], loose: [{ device: "dev-02", kind: "device" }] }],
  unplaced: [{ device: "ap1", kind: "ap", location: "home" }, { device: "seen-1", kind: "device", seen: true, location: "home" }],
  cables: [
    { from: { device: "core", port: "1" }, to: { device: "tappaas1", port: "eth0" }, kind: "lan", source: "topology" },
    { from: { device: "core", port: "2" }, to: { device: "tappaas1", port: "eth1" }, kind: "patch", source: "recorded", label: "blue" },
  ],
};

const rel = (from: string, to: string, id = `id-${from}`): CmdbRelationRow => ({ id: 1, type: "allocated-to", from: { id, class: "server", name: from }, to: { id: `n-${to}`, class: "machine", name: to } });
const tree = assetTree(pos, [rel("srv-01", "tappaas1"), rel("sw-01", "old-core")]);
const home = tree.locations.find((l) => l.name === "home")!;
const cellar = home.rooms.find((r) => r.name === "cellar")!;

check(tree.locations.map((l) => l.name).join(",") === "home,cabin", "locations: the primary first, then by name");
check(cellar.racks.length === 1 && cellar.racks[0].items.map((i) => i.device).join(",") === "tappaas1,core", "a rack's devices from the top unit down");
check(cellar.racks[0].items[0].asset === "srv-01" && cellar.racks[0].items[0].at === "U5-6", "a placement by role is the asset that plays it, with its units");
check(cellar.loose.length === 1 && cellar.loose[0].asset === "dev-02" && cellar.loose[0].at === null, "loose in a room");
check(home.rooms.some((r) => r.name === "" && r.racks.some((k) => k.name === "r9")), "a rack in no room: under its location's no-room");
check(home.unplaced.map((i) => i.device).join(",") === "ap1,srv-02,seen-1", "not placed: the topology's unplaced, then stock assets; the seen ones last");
check(home.unplaced.find((i) => i.device === "ap1")!.asset === null && home.unplaced.find((i) => i.device === "seen-1")!.seen, "a device no asset records, and a seen one");
check(tree.locations.find((l) => l.name === "cabin")!.unplaced.map((i) => i.asset).join(",") === "srv-03", "an ordered asset under its own location");
check(home.disposed.map((i) => i.asset).join(",") === "dev-01", "a disposed asset apart");

const srv1 = tree.assets.find((a) => a.name === "srv-01")!;
check(srv1.placedAs === "tappaas1" && srv1.where.rack === "r1" && srv1.where.room === "cellar" && srv1.where.location === "home", "an asset's place, by the name it plays");
check(srv1.ports.length === 2 && srv1.ports[0].cables[0].to === "core:1" && srv1.ports[1].name === "eth1" && !srv1.ports[1].listed, "its ports with their cables; a port only a cable names is added");
check(srv1.cmdb?.allocatedTo === "tappaas1" && !srv1.allocationDrift, "the CMDB agrees on its role");
const sw = tree.assets.find((a) => a.name === "sw-01")!;
check(sw.allocationDrift && sw.cmdb?.allocatedTo === "old-core", "the CMDB disagrees: drift");
check(sw.ports.find((p) => p.name === "2")!.cables[0].label === "blue" && sw.ports.find((p) => p.name === "2")!.cables[0].source === "recorded", "a recorded cable with its label");
check(!tree.assets.find((a) => a.name === "srv-02")!.allocationDrift, "no role and no allocation: no drift");
const blind = assetTree(pos, new Error("down"));
check(blind.allocationsError === "down" && blind.assets.every((a) => a.cmdb === null && !a.allocationDrift), "the CMDB not read: no allocation, no drift, the error said");
check(assetTree(null, []).locations.length === 0 && assetTree(null, []).assets.length === 0, "no positions: an empty tree");

// A patch panel: the links through its ports.
const panel = assetTree(
  {
    assets: [{ name: "pp", kind: "patch-panel", displayName: null, vendor: null, model: null, serial: null, stage: "placed", role: null, placed: true, ports: [{ name: "1", kind: "rj45" }] }],
    racks: [],
    unplaced: [],
    cables: [{ from: { device: "a", port: "x" }, to: { device: "b", port: "y" }, kind: "patch", source: "recorded", via: [{ device: "pp", port: "1" }] }],
  },
  [],
);
check(panel.assets[0].ports[0].cables[0].to === "a:x — b:y", "a patch panel's port: the link through it");

// ── the page's logic ─────────────────────────────────────────────────────

const t = tree as unknown as AssetTree;
check(findAsset(t, "srv-01")?.name === "srv-01" && findAsset(t, "tappaas1")?.name === "srv-01" && findAsset(t, "nope") === null && findAsset(null, "x") === null, "an asset by its name or its role");
const hist: CiHistoryRow[] = [
  { at: "2026-01-01T00:00:00Z", what: "relation", name: "allocated-to", value: { id: "n1", class: "machine", name: "tappaas3" }, source: "asset-manager", until: "2026-05-01T00:00:00Z", detail: "out", drift: false },
  { at: "2026-05-02T00:00:00Z", what: "relation", name: "allocated-to", value: { id: "n2", class: "machine", name: "tappaas1" }, source: "asset-manager", until: null, detail: "out", drift: false },
  { at: "2026-05-02T00:00:00Z", what: "relation", name: "placed-in", value: { id: "r", class: "rack", name: "r1" }, source: "asset-manager", until: null, detail: "out", drift: false },
  { at: "2026-05-02T00:00:00Z", what: "attribute", name: "stage", value: "operational", source: "asset-manager", until: null, detail: null, drift: false },
];
const al = allocationHistory(hist);
check(al.length === 2 && al[0].role === "tappaas1" && al[0].until === null && al[1].role === "tappaas3" && al[1].id === "n1", "allocations: the allocated-to periods, the newest first");
check(allocatedSince(al, "tappaas1") === "2026-05-02T00:00:00Z" && allocatedSince(al, "tappaas3") === null && allocatedSince(al, null) === null, "since: the open period of the role it plays");
check(assetsSelOf("rack:r1")?.kind === "rack" && assetsSelOf("device:a:b")?.id === "a:b" && assetsSelOf("frob:x") === null && assetsSelOf(null) === null && assetsSelOf(":x") === null, "?select= on the Assets page");
check(assetsSelText({ kind: "room", id: "cellar" }) === "room:cellar", "a selection as text");
const f = filterLocation(t, t.locations[0], "z840");
check(f !== null && itemsOf(f).length === 1 && itemsOf(f)[0].asset === "srv-01" && f.rooms.length === 1, "a filter keeps the matching rows and their room and rack");
check(filterLocation(t, t.locations[0], "nothing-like-it") === null && filterLocation(t, t.locations[0], " ") === t.locations[0], "a filter that keeps nothing; an empty one keeps all");
const free = unallocated(t);
check(free.map((a) => `${a.name}:${a.stage}`).join(",") === "srv-03:ordered,srv-02:stock,dev-02:placed", `without a role: ordered, in stock, then placed — not the disposed, not one in a role (${free.map((a) => a.name).join(",")})`);
check(freeWhere(free[0]) === "ordered for cabin" && freeWhere(free[1], (n) => n.toUpperCase()) === "in stock at HOME", "an ordered and a stocked asset: where it is due or kept");
check(freeWhere(free[2]) === "home · cellar", `a placed one: where it stands (${freeWhere(free[2])})`);
const released = { ...t, assets: [...t.assets, { ...srv1, name: "srv-09", role: null, stage: "placed", faulty: true, in: undefined }] } as unknown as AssetTree;
check(unallocated(released).some((a) => a.name === "srv-09" && a.faulty) && freeWhere(unallocated(released).find((a) => a.name === "srv-09")!) === "home · cellar · rack r1 U5-6", "a released server still in its rack, faulty flag kept, with its rack and units");
const diskIn = { ...t, assets: [...t.assets, { ...srv1, name: "dsk-01", kind: "disk", role: null, stage: "placed", in: { asset: "srv-01", bay: "1" } }] } as unknown as AssetTree;
check(!unallocated(diskIn).some((a) => a.name === "dsk-01"), "a disk in another asset goes with it, not listed alone");
check(unallocated(null).length === 0, "no tree: none");
check(stageCounts(t).operational === 2 && stageCounts(t).disposed === 1 && stageCounts(t).ordered === 1, "the stages counted");

// ── the Details link ─────────────────────────────────────────────────────

const mods = new Set(["tappaas1", "nextcloud", "firewall"]);
const to = (xs: { to: string }[]) => xs.map((x) => x.to).join(" ");
check(assetPath("srv 01") === "/site/assets/srv%2001" && assetPath("core", "1/0") === "/site/assets/core#port-1_0" && portAnchor("eth0") === "port-eth0", "an asset's path, a port's anchor");
check(to(selDetails({ kind: "node", id: "tappaas1" }, { modules: mods })) === "/modules/tappaas1 /site/assets/tappaas1", "a node with a page: its page, then its asset");
check(to(selDetails({ kind: "node", id: "tappaas2" }, { modules: mods })) === "/site/assets/tappaas2", "a node without one: its asset");
check(to(selDetails({ kind: "switch", id: "core" }, { modules: mods })) === "/site/assets/core" && to(selDetails({ kind: "ap", id: "ap1" }, { modules: mods })) === "/site/assets/ap1", "a switch, an access point: the asset");
check(to(selDetails({ kind: "port", id: "7", switch: "core" }, { modules: mods })) === "/site/assets/core#port-7" && to(selDetails({ kind: "lag", id: "ae1", switch: "core" }, { modules: mods })) === "/site/assets/core", "a switch port: its row on the switch's page; a LAG the switch");
check(to(selDetails({ kind: "panelport", id: "3", panel: "pp" }, { modules: mods })) === "/site/assets/pp#port-3", "a patch panel's port");
check(to(selDetails({ kind: "guest", id: "nextcloud" }, { modules: mods })) === "/modules/nextcloud" && to(selDetails({ kind: "firewall", id: "x" }, { modules: mods, firewall: "firewall" })) === "/modules/firewall", "a guest, the firewall: the module's page");
check(to(selDetails({ kind: "rack", id: "r1" }, { modules: mods })) === assetsSelectPath("rack", "r1") && to(selDetails({ kind: "room", id: "cellar" }, { modules: mods })) === "/site/assets?select=room%3Acellar", "a rack, a room: the Assets page with it selected");
check(to(selDetails({ kind: "mount", id: "modem" }, { modules: mods })) === "/site/assets/modem" && to(selDetails({ kind: "mount", id: "x" }, { modules: mods, seen: true })) === "/site/assets?select=device%3Ax", "a recorded device its page; a seen one the Assets page");
check(to(selDetails({ kind: "disk", id: "sda", node: "tappaas2" }, { modules: mods })) === "/site/assets/tappaas2" && to(selDetails({ kind: "pool", id: "tank", node: "tappaas1" }, { modules: mods })).startsWith("/modules/tappaas1"), "a disk its node's asset; a pool its node");
const link = selDetails({ kind: "link", id: "l" }, { modules: mods, linkEnds: ["core", "tappaas1"] });
check(link.length === 2 && link[0].label === "Details · core" && link[1].to === "/site/assets/tappaas1" && selDetails({ kind: "link", id: "l" }, { modules: mods, linkEnds: ["core"] })[0].label === "Details", "a link: each end that is an asset");
check(to(selDetails({ kind: "outside", id: "b" }, { modules: mods, outsideKind: "buddy" })) === "/backup" && to(selDetails({ kind: "isp", id: "isp" }, { modules: mods })) === "/site", "a buddy the Backup page, the ISP the Site page");

const ci = (c: string, ancestors: string[], name: string, extra: Partial<Parameters<typeof ciDetails>[0]> = {}) => ciDetails({ class: c, ancestors, name, module: null, relations: [], ...extra });
check(to(ci("server", ["asset", "resource", "object"], "srv-01")) === "/site/assets/srv-01", "an asset CI: its page");
check(to(ci("port", ["resource", "object"], "eth0", { relations: [{ type: "part-of", direction: "out", other: { class: "server", name: "srv-01" } }] })) === "/site/assets/srv-01#port-eth0" && ci("port", [], "x").length === 0, "a port: its row on its asset's page");
check(to(ci("machine", ["node", "ci"], "tappaas1", { module: "tappaas1", relations: [{ type: "allocated-to", direction: "in", other: { class: "server", name: "srv-01" } }] })) === "/modules/tappaas1 /site/assets/srv-01", "a node with a module: its page, then the asset that plays it");
check(to(ci("machine", ["node", "ci"], "tappaas2")) === "/site/assets/tappaas2", "a node without: its asset by its name");
check(to(ci("vm", ["node", "ci"], "nextcloud", { module: "nextcloud" })) === "/modules/nextcloud", "a guest: its module");
check(to(ci("zone", ["network-element", "ci"], "home")) === "/environments/zones?zone=home" && to(ci("user", ["identity", "ci"], "lars")) === "/identity?select=user%3Alars" && to(ci("organization", ["identity"], "acme")) === "/identity?select=org%3Aacme", "a zone the Network page, a user or an organization Identity");
check(to(ci("rack", ["place"], "r1")) === "/site/assets?select=rack%3Ar1" && to(ci("environment", ["collection"], "prod")) === "/environments?env=prod" && ci("dns-name", ["network-element"], "x").length === 0, "a rack, an environment; a class with no page has none");

done("assets");
