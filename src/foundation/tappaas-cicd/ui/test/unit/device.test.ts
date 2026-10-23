// device.test.ts — the Device view as data (web/src/physical/devicegraph.ts)
// over hrossen's topology with its positions (test/fixtures/topology-positions.json,
// 2026-10-22): one node per physical device, one link per pair of devices a
// cable joins, the states from the findings.

import { readFileSync } from "fs";
import { join } from "path";
import { Topology } from "../../web/src/types";
import { ISP, depths, deviceGraph, deviceState, forceLayout, freePanelPorts, linkId, selectedDevice } from "../../web/src/physical/devicegraph";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const t = JSON.parse(readFileSync(join(FIX, "topology-positions.json"), "utf8")) as Topology;
const g = deviceGraph(t);
const ids = g.nodes.map((n) => n.id).sort();
const link = (a: string, b: string) => g.links.find((l) => l.id === linkId(a, b));

check(["tappaas1", "tappaas2", "tappaas3", "USW Pro XG 10 PoE", "crs-a", "crs-b", "Nano HD", "ISP modem", ISP, "buddy rasmus"].every((x) => ids.includes(x)) && ids.length === 10, `every physical device once (${ids.join(", ")})`);
check(!ids.some((x) => /network|opnsense|vm/i.test(x)), "no guest is a device (the firewall is a VM)");
check(g.nodes.find((n) => n.id === "tappaas1")?.sel.kind === "node" && g.nodes.find((n) => n.id === "crs-a")?.sel.kind === "switch" && g.nodes.find((n) => n.id === "ISP modem")?.sel.kind === "mount" && g.nodes.find((n) => n.id === ISP)?.sel.kind === "isp", "each device selects its own side card");
const usw1 = link("USW Pro XG 10 PoE", "tappaas1");
check(usw1?.kind === "wan" && usw1.cables.length === 1 && usw1.cables[0].to.port === "nic4", "tappaas1's WAN cable: one link, port 6 to nic4");
const peer = link("crs-a", "crs-b");
check(peer?.kind === "peer-link" && peer.cables.length === 2 && peer.cables.every((c) => c.to.port !== "peer-link"), "the MLAG peer link: two cables port to port, though each switch lists only its own end");
check(link("USW Pro XG 10 PoE", "crs-a")?.cables[0].lag === "crs-uplink" && link("crs-a", "tappaas1")?.kind === "lan", "the LAG to the CRS pair, tappaas1's lan bond legs");
check(link(ISP, "ISP modem")?.kind === "hand-off" && !link(ISP, "USW Pro XG 10 PoE"), "the internet ends in the recorded modem, not at the switch");
check(link("buddy rasmus", "tappaas1")?.kind === "tunnel" && link("buddy rasmus", "tappaas1")?.cables.length === 0, "a buddy hangs off the firewall's node by its tunnel");
check(new Set(g.links.map((l) => l.id)).size === g.links.length && g.links.every((l) => l.a < l.b), "one link per pair, ends in order");

const st = (id: string) => deviceState(t, g.nodes.find((n) => n.id === id)!);
check(st("Nano HD").state === "warn" && /mounted in no rack/.test(st("Nano HD").reasons.join()), "the unplaced AP is amber, with its reason");
check(st("buddy rasmus").state === "warn" && st("tappaas2").state === "ok", "a buddy down is amber; a node without a finding is green");
check(selectedDevice(g, { kind: "port", id: "5", switch: "USW Pro XG 10 PoE" }) === "USW Pro XG 10 PoE" && selectedDevice(g, { kind: "outside", id: "rasmus" }) === "buddy rasmus" && selectedDevice(g, null) === null, "a selection names its device");

// A device position-manager records: a device like the others, its kind kept.
{
  const t2 = { ...t, devices: [...(t.devices ?? []), { name: "ISP modem", kind: "modem" as const, vendor: null, model: "generic/isp-modem", recorded: true as const, ports: ["WAN", "LAN 1"] }, { name: "ups1", kind: "ups" as const, vendor: null, model: null, recorded: true as const, ports: ["1", "2"] }] };
  const g2 = deviceGraph(t2);
  const m = g2.nodes.find((n) => n.id === "ISP modem");
  check(m?.kind === "device" && m.recorded === "modem" && m.sel.kind === "mount" && g2.nodes.find((n) => n.id === "ups1")?.recorded === "ups", "recorded devices are devices of the graph, their kind kept");
  check(g2.links.some((l) => l.id === linkId(ISP, "ISP modem") && l.kind === "hand-off") && g2.links.some((l) => l.id === linkId("ISP modem", "USW Pro XG 10 PoE")), "the recorded modem keeps its hand-off and its cable");
}

// A device a switch port sees and nobody recorded: a device of the graph,
// shown by what LLDP calls it, on its port's link.
{
  const USW = "USW Pro XG 10 PoE";
  const mac = "aa:bb:cc:00:11:22";
  const seenDev = { name: mac, kind: "device" as const, vendor: null, model: null, ports: ["eth0"], displayName: "printer-1", source: "seen" as const, location: "knudanchersvej95", placement: null, seen: { switch: USW, port: "8", mac, lldp: { name: "printer-1", port: "eth0" }, lease: null } };
  const wire = { from: { device: USW, port: "8" }, to: { device: mac, port: "eth0" }, kind: "device", source: "topology" as const, zones: [], lag: null, up: true, label: null };
  const t4 = { ...t, devices: [...(t.devices ?? []), seenDev], positions: { ...t.positions!, cables: [...t.positions!.cables, wire] } };
  const g4 = deviceGraph(t4);
  const n = g4.nodes.find((x) => x.id === mac);
  check(n?.seen === true && n.name === "printer-1" && n.sel.kind === "mount" && !n.recorded, "a seen device: a node of the graph, named as LLDP calls it, marked seen");
  check(g4.links.some((l) => l.id === linkId(USW, mac)), "…on the link from its switch port");
}

// A link split at a patch panel: one link in the graph, its two wires listed;
// the panel's other ports are free to split another.
{
  const USW = "USW Pro XG 10 PoE";
  const seg = { from: { device: USW, port: "2" }, to: { device: "tappaas2", port: "enp97s0" }, kind: "lan", source: "topology" as const, zones: [], lag: null, up: true, label: null, segments: [{ from: { device: USW, port: "2" }, to: { device: "patch1", port: "1", side: "front" as const } }, { from: { device: "patch1", port: "1", side: "rear" as const }, to: { device: "tappaas2", port: "enp97s0" } }], via: [{ device: "patch1", port: "1" }] };
  const cables = t.positions!.cables.filter((c) => !(c.to.device === "tappaas2" && c.to.port === "enp97s0"));
  const t3 = { ...t, devices: [...(t.devices ?? []), { name: "patch1", kind: "patch-panel" as const, vendor: null, model: null, recorded: true as const, ports: ["1", "2", "3"] }], positions: { ...t.positions!, cables: [...cables, seg] } };
  const g3 = deviceGraph(t3);
  const l = g3.links.find((x) => x.id === linkId(USW, "tappaas2"))!;
  check(l.cables.length === 1 && l.cables[0].segments?.length === 2 && !g3.links.some((x) => x.a === "patch1" || x.b === "patch1"), "a split link: one link between the two devices, its segments with it, no link to the panel");
  check(freePanelPorts(t3).join() === "patch1:2,patch1:3", "the panel's free ports: the ones neither side of which is cabled");
}

// ── the layout ────────────────────────────────────────────────────────
const nodeIds = g.nodes.map((n) => n.id);
const L = forceLayout(nodeIds, g.links, "tappaas1");
const r = (id: string) => Math.hypot(L.get(id)!.x, L.get(id)!.y);
const dep = depths(nodeIds, g.links, "tappaas1");
const ring = (k: number) => nodeIds.filter((i) => dep.get(i) === k).map(r);
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / Math.max(1, xs.length);
check(L.get("tappaas1")!.x === 0 && L.get("tappaas1")!.y === 0, "the selected device sits in the middle");
check(dep.get("crs-a") === 1 && dep.get("buddy rasmus") === 1 && dep.get(ISP) === 3, "rings by links: the CRS pair and the buddy next to tappaas1, the internet three away");
check(mean(ring(1)) < mean(ring(2)) && mean(ring(2)) < mean(ring(3)), `neighbours closest, the rest further out (${[1, 2, 3].map((k) => mean(ring(k)).toFixed(0)).join(" < ")})`);
check(nodeIds.every((a) => nodeIds.every((b) => a === b || Math.hypot(L.get(a)!.x - L.get(b)!.x, L.get(a)!.y - L.get(b)!.y) > 60)), "no two devices on top of each other");
const again = forceLayout(nodeIds, g.links, "tappaas1");
check(nodeIds.every((i) => again.get(i)!.x === L.get(i)!.x && again.get(i)!.y === L.get(i)!.y), "the same graph gives the same picture");
const moved = forceLayout(nodeIds, g.links, "crs-a", L);
check(moved.get("crs-a")!.x === 0 && moved.get("crs-a")!.y === 0 && Math.hypot(moved.get("tappaas1")!.x, moved.get("tappaas1")!.y) < mean(ring(2)), "a new selection moves to the middle from where it was, its neighbours with it");
const none = forceLayout(nodeIds, g.links, null);
check(none.size === nodeIds.length && [...none.values()].every((p) => Number.isFinite(p.x) && Number.isFinite(p.y)), "without a selection every device is placed");
done("device");
