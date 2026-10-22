// device.test.ts — the Device view as data (web/src/physical/devicegraph.ts)
// over hrossen's topology with its racks (test/fixtures/topology-racks.json,
// 2026-10-22): one node per physical device, one link per pair of devices a
// cable joins, the states from the findings.

import { readFileSync } from "fs";
import { join } from "path";
import { Topology } from "../../web/src/types";
import { ISP, deviceGraph, deviceState, linkId, selectedDevice } from "../../web/src/physical/devicegraph";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const t = JSON.parse(readFileSync(join(FIX, "topology-racks.json"), "utf8")) as Topology;
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
done("device");
