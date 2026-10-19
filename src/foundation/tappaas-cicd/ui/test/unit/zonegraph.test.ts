// zonegraph.test.ts — the zones graph as data (web/src/zonegraph.ts) over
// hrossen's zones (test/fixtures/zones.json): the trust column of each zone,
// the WAN zone's card standing for the internet, and its public address.

import { readFileSync } from "fs";
import { join } from "path";
import { COLUMN_TITLES, ZoneLike, publicAddress, wanZone, zoneColumn, zoneEdges } from "../../web/src/zonegraph";
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

const both = zoneEdges([{ name: "wan", type: "WAN" }, { name: "home", type: "Client", "access-to": ["internet", "wan"] }]);
check(both.edges.length === 1, "internet and wan in one access-to: one line");
const none = zoneEdges([{ name: "home", type: "Client", "access-to": ["internet"] }]);
check(none.pseudo.join() === "internet" && none.edges[0].target === "internet" && wanZone([]) === null, "no WAN zone: the internet keeps its own card");

// The public address: from site.json's network.publicIp, never the zone's ip.
check(publicAddress({ network: { publicIp: "auto" } }).auto && publicAddress({ network: { publicIp: "auto" } }).address === null, "auto: the provider's, no address to show");
check(publicAddress({ network: { publicIp: " 198.51.100.7 " } }).address === "198.51.100.7", "a recorded address is shown");
check(publicAddress({}).address === null && !publicAddress(null).auto && !publicAddress({ network: { publicIp: null } }).auto, "nothing recorded: nothing shown");

done("zonegraph");
