// zonegraph.test.ts — the zones graph as data (web/src/zonegraph.ts) over
// hrossen's zones (test/fixtures/zones.json): the trust column of each zone,
// the WAN zone's card standing for the internet, and its public address.

import { readFileSync } from "fs";
import { join } from "path";
import { COLUMN_TITLES, ZoneLike, pseudoPlace, publicAddress, publicText, wanZone, zoneColumn, zoneEdges } from "../../web/src/zonegraph";
import { check, done } from "./check";

const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";
const zones = JSON.parse(readFileSync(join(FIX, "zones.json"), "utf8")) as ZoneLike[];
const col = (n: string): number => zoneColumn(zones.find((z) => z.name === n)!);

// zoneColumn: overlays, tier 0..4, the WAN with the internet, tier 6 last.
check(["netbird", "edge", "admin", "buddy"].every((n) => col(n) === 0), "overlays: column 0");
check(col("mgmt") === 1 && col("rossen") === 2 && col("test") === 2, "tier 0 and tier 1 zones: columns 1 and 2");
check(col("home") === 3 && col("iotCloud") === 4 && col("guest") === 4 && col("dmz") === 5, "tier 2, 3 and 4: columns 3, 4 and 5");
check(col("wan") === 6 && COLUMN_TITLES[6].startsWith("internet"), "the WAN sits in the internet column");
check(col("iotLocal") === 7 && col("iotCams") === 7, "tier 6 (no egress): the last column");
check(col("work") === 3 && col("iotUntrust") === 4, "no tier recorded: the type's usual tier");
check(zoneColumn({ type: "Service", tier: 9 }) === 7 && zoneColumn({ type: "Nonsense" }) === 0, "beyond tier 6, and an unknown type");

// The WAN merge.
check(wanZone(zones) === "wan", "the WAN zone is found");
const { edges, pseudo } = zoneEdges(zones);
check(!pseudo.includes("internet"), "no card for the internet when there is a WAN zone");
check(pseudo.length === 1 && pseudo[0] === "all", "the other words keep their card (every zone)");
check(!edges.some((e) => e.source === "internet" || e.target === "internet"), "no line ends on the internet");
const toWan = edges.filter((e) => e.kind === "access" && e.target === "wan").map((e) => e.source).sort();
check(toWan.join(" ") === "dmz guest home iotCloud iotUntrust mgmt rossen test work", "every access-to internet points at the WAN card");
check(edges.some((e) => e.kind === "pinhole" && e.source === "wan" && e.target === "dmz"), "a pinhole from the internet comes from the WAN card");
check(edges.some((e) => e.kind === "access" && e.source === "mgmt" && e.target === "all"), "mgmt still reaches every zone");

// The edges a zone's environment link derives: one per environment it serves.
check(edges.some((e) => e.kind === "access" && e.source === "home" && e.target === "rossen" && e.via === "rossen"), "home serves rossen: a line to rossen's zone");
check(edges.some((e) => e.kind === "pinhole" && e.source === "rossen" && e.target === "iotCams" && e.via === "rossen"), "an IoT zone serving rossen: a pinhole line from rossen's zone");
const multi = zoneEdges([
  { name: "acme", type: "Service", environment: "acme" }, { name: "lab", type: "Service", environment: "lab" },
  { name: "work", type: "Client", environment: ["acme", "lab"], "access-to": ["internet"] },
]);
check(multi.edges.filter((e) => e.source === "work" && e.via).map((e) => e.target).sort().join() === "acme,lab", "a zone serving two environments: a line to each one's zone");

const both = zoneEdges([{ name: "wan", type: "WAN" }, { name: "home", type: "Client", "access-to": ["internet", "wan"] }]);
check(both.edges.length === 1, "internet and wan in one access-to: one line");
const none = zoneEdges([{ name: "home", type: "Client", "access-to": ["internet"] }]);
check(none.pseudo.join() === "internet" && none.edges[0].target === "internet" && wanZone([]) === null, "no WAN zone: the internet keeps its own card");

// Every zone (all) in the tier-0 column, below the zone that reaches it.
const all = pseudoPlace("all", zones);
check(all.col === 1 && all.after === "mgmt" && COLUMN_TITLES[all.col].startsWith("tier 0"), "every zone: tier 0, directly below mgmt");
check(pseudoPlace("all").after === undefined && pseudoPlace("internet").col === 6 && pseudoPlace("vpn-peers").col === 6, "no zones: no anchor; the other words in the internet column");

// The public address: from site.json's network.publicIp, never the zone's ip.
check(publicAddress({ network: { publicIp: "auto" } }).auto && publicAddress({ network: { publicIp: "auto" } }).address === null, "auto: the provider's, no address to show");
check(publicAddress({ network: { publicIp: " 198.51.100.7 " } }).address === "198.51.100.7", "a recorded address is shown");
check(publicAddress({}).address === null && !publicAddress(null).auto && !publicAddress({ network: { publicIp: null } }).auto, "nothing recorded: nothing shown");

// auto: what the firewall's WAN held at the last network update.
const auto = { network: { publicIp: "auto" } };
const held = { ipv4: "8.8.4.4", private: false, observed: "2026-10-19T03:12:00+02:00" };
const seen = publicAddress(auto, held);
check(seen.address === "8.8.4.4" && seen.auto && seen.wan === null, "auto: the WAN's address is the public one");
check(publicText(seen, true) === "public 8.8.4.4" && publicText(seen) === "public address 8.8.4.4 (auto: what the WAN held on 2026-10-19)", "…in words, short and in full");
const behind = publicAddress(auto, { ...held, ipv4: "192.168.1.20", private: true });
check(behind.address === null && behind.wan === "192.168.1.20" && publicText(behind, true) === "WAN 192.168.1.20 (private)", "a private WAN address is not called public");
check(/router's in front of the WAN/.test(publicText(behind)), "…the router in front of it holds the public one");
check(publicAddress({ network: { publicIp: "203.0.113.9" } }, held).address === "203.0.113.9", "a recorded address wins over what the WAN held");
check(publicAddress(auto, null).address === null && publicText(publicAddress(auto, null), true) === "public address auto", "auto, nothing read yet: says auto");
check(publicAddress({}, held).address === null, "no publicIp at all: the WAN's address is not shown as public");

done("zonegraph");
