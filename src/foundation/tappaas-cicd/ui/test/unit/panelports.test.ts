// panelports.test.ts — a patch panel's ports as the console reads them
// (web/src/physical/devicegraph.ts panelPortUse, freePanelPorts, panelPortSel)
// over hrossen's positions.json: two seen links split through patchpanel1,
// USW Pro XG 10 PoE:2 → 9 front, 9 rear → tappaas2:enp97s0, and USW:3 → 6
// front, 6 rear → tappaas3:eno1. The topology hands them over as two links,
// the panel only in their segments (lib/ts chainSegments), which is why a
// panel's ports must be read from the segments.

import { CableView, PositionsDoc, chainSegments } from "../../../lib/ts/src/positions";
import { freePanelPorts, linkId, panelPortSel, panelPortUse, splittable } from "../../web/src/physical/devicegraph";
import { RackCable, Topology } from "../../web/src/types";
import { check, done } from "./check";

const USW = "USW Pro XG 10 PoE";
const PP = "patchpanel1";
const ports = Array.from({ length: 24 }, (_, i) => String(i + 1));
// hrossen's positions.json: the panel and the four segments (kind patch, origin seen),
// and a wire on port 12's front only.
const doc: PositionsDoc = {
  devices: { [PP]: { kind: "patch-panel", ports } },
  cables: [
    { from: { device: USW, port: "2" }, to: { device: PP, port: "9", side: "front" }, kind: "patch", origin: "seen" },
    { from: { device: PP, port: "9", side: "rear" }, to: { device: "tappaas2", port: "enp97s0" }, kind: "patch", origin: "seen" },
    { from: { device: USW, port: "3" }, to: { device: PP, port: "6", side: "front" }, kind: "patch", origin: "seen" },
    { from: { device: PP, port: "6", side: "rear" }, to: { device: "tappaas3", port: "eno1" }, kind: "patch", origin: "seen" },
    { from: { device: "crs-a", port: "ether1" }, to: { device: PP, port: "12", side: "front" }, kind: "patch" },
  ],
};
const seen = (a: [string, string], b: [string, string]): CableView => ({ from: { device: a[0], port: a[1] }, to: { device: b[0], port: b[1] }, kind: "lan", source: "topology", zones: [], lag: null, up: true, label: null });
// What resolvePositions hands the chaining: the links the topology sees, then the recorded wires.
const views: CableView[] = [
  seen([USW, "2"], ["tappaas2", "enp97s0"]),
  seen([USW, "3"], ["tappaas3", "eno1"]),
  seen([USW, "5"], ["tappaas1", "nic2"]),
  ...doc.cables!.map((c): CableView => ({ from: { ...c.from }, to: { ...c.to }, kind: c.kind, source: "recorded", zones: [], lag: null, up: null, label: null })),
];
const cables = chainSegments(doc, views) as unknown as RackCable[];
const t = { positions: { cables }, devices: [{ name: PP, kind: "patch-panel", recorded: true, ports }] } as unknown as Topology;

const split = cables.filter((c) => c.via?.length);
check(split.length === 2 && split.every((c) => c.from.device !== PP && c.to.device !== PP && c.segments?.length === 2), "the two split links name the panel only in their segments (the shape the port table missed)");
const use = panelPortUse(cables, PP);
const u9 = use.get("9");
const u6 = use.get("6");
check(u9?.front?.device === USW && u9.front.port === "2" && u9?.rear?.device === "tappaas2" && u9.rear.port === "enp97s0", "port 9: front to USW:2, rear to tappaas2:enp97s0");
check(u6?.front?.device === USW && u6.front.port === "3" && u6?.rear?.device === "tappaas3" && u6.rear.port === "eno1", "port 6: front to USW:3, rear to tappaas3:eno1");
check(use.get("12")?.front?.device === "crs-a" && !use.get("12")?.rear, "port 12: its front only (half used)");
check([...use.keys()].sort().join() === "12,6,9", "no other port is cabled");
const free = freePanelPorts(t);
check(free.length === 21 && !free.includes(`${PP}:9`) && !free.includes(`${PP}:6`) && !free.includes(`${PP}:12`) && free.includes(`${PP}:1`), `the free ports (Attach to patch panel…): 21, not 6, 9 or the half-used 12 (${free.length})`);
const s9 = panelPortSel(t, PP, "9");
check(s9.kind === "link" && s9.id === linkId(USW, "tappaas2") && s9.port === `${PP}:9`, "a click on port 9 selects the USW ↔ tappaas2 link through it");
const s1 = panelPortSel(t, PP, "1");
check(s1.kind === "panelport" && s1.id === "1" && s1.panel === PP, "a click on a free port selects the port");
const sp = splittable(t).map((x) => x.end);
check(sp.includes(`${USW}:5`) && !sp.includes(`${USW}:2`) && !sp.some((e) => e.startsWith("crs-a")), `a free port offers the links not yet through a panel (${sp.join(", ")})`);
done("panelports");
