// zonenet.test.ts — a zone's numbers (web/src/zonenet.ts) against the network
// module's own: its /64, each expected value what opnsense-controller
// ipv6_plan.zone_network(prefix, subnet) prints; its typeId's type.

import { readFileSync } from "fs";
import { join } from "path";
import { ARCHETYPES } from "../../../manager/network-manager/src/archetypes";
import { ZONE_TYPE_IDS, formatV6, parseV6, typeIdText, zoneNetwork, zoneV6 } from "../../web/src/zonenet";
import { check, done } from "./check";
import { FIX } from "./fake-site";

// [site prefix, ipv6Subnet, zone_network(prefix, subnet)]
const PLAN: [string, number, string][] = [
  ["2a13:e747:a210:4500::/56", 32, "2a13:e747:a210:4520::/64"],
  ["2a13:e747:a210:4500::/56", 0, "2a13:e747:a210:4500::/64"],
  ["2a13:e747:a210:4500::/56", 255, "2a13:e747:a210:45ff::/64"],
  ["2a13:e747:a210:4500::/56", 1, "2a13:e747:a210:4501::/64"],
  ["2001:db8:6648::/48", 97, "2001:db8:6648:61::/64"],
  ["2001:db8:6648::/48", 0, "2001:db8:6648::/64"],
  ["2001:db8:0:ab00::/56", 16, "2001:db8:0:ab10::/64"],
  ["2a13:e747:a210:4500::/55", 3, "2a13:e747:a210:4403::/64"],
  ["2001:db8:0:0:1::/56", 5, "2001:db8:0:5::/64"],
  ["2001:db8::/32", 0, "2001:db8::/64"],
  ["2a13:e747:a210:45ff::/56", 2, "2a13:e747:a210:4502::/64"],
];
for (const [p, n, want] of PLAN) check(zoneNetwork(p, n) === want, `${p} index ${n} → ${want}`);

// Out of the plan's reach: no /64.
check(zoneNetwork("2a13:e747:a210:4500::/60", 1) === null, "a prefix smaller than /56: none");
check(zoneNetwork("2a13:e747:a210:4500::/56", 256) === null && zoneNetwork("2a13:e747:a210:4500::/56", -1) === null && zoneNetwork("2a13:e747:a210:4500::/56", 1.5) === null, "an index outside 0-255: none");
check(zoneNetwork("not-an-address/56", 1) === null && zoneNetwork("1:2:3::4::/56", 1) === null && zoneNetwork("12345::/56", 1) === null, "not an IPv6 network: none");

// The text form, as Python's ipaddress prints it.
const round = (s: string): string => formatV6(parseV6(s)!);
check(round("::") === "::" && round("::1") === "::1" && round("fe80::") === "fe80::", "all zero, leading and trailing runs");
check(round("2001:db8:0:0:1:0:0:1") === "2001:db8::1:0:0:1", "the first of two equal runs");
check(round("2001:db8:0:1:1:1:1:1") === "2001:db8:0:1:1:1:1:1", "one zero group stays");
check(round("2001:0DB8:0000::0001") === "2001:db8::1", "leading zeros and capitals");

// zoneV6: "-" (null) when the site has IPv6 off, the zone has no index, or no prefix is learned.
const on = { on: true, mode: "dynamic", prefix: "2a13:e747:a210:4500::/56", source: "delegated" as const };
check(zoneV6({ ipv6Subnet: 32 }, on) === "2a13:e747:a210:4520::/64", "a zone with an index on a site with a prefix");
check(zoneV6({ ipv6Subnet: 32 }, { ...on, on: false }) === null, "IPv6 off: none");
check(zoneV6({}, on) === null, "no ipv6Subnet: none");
check(zoneV6({ ipv6Subnet: 32 }, { ...on, prefix: null, source: null }) === null && zoneV6({ ipv6Subnet: 32 }, null) === null, "no prefix learned, or not read: none");

// The typeId table against the network module's: zones-fields.json (each
// type's typeId, and typeId's own values) and network-manager's archetypes.
const fields = (JSON.parse(readFileSync(join(FIX, "..", "..", "..", "..", "schemas", "zones-fields.json"), "utf8")) as { fields: { type: { values: Record<string, { typeId: number }> }; typeId: { values: Record<string, string> } } }).fields;
const fromTypes = Object.fromEntries(Object.entries(fields.type.values).map(([t, v]) => [v.typeId, t]));
const same = (a: Record<string | number, string>, b: Record<string | number, string>): boolean => JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b).sort());
check(same(ZONE_TYPE_IDS, fromTypes), "the typeIds are zones-fields.json's: every type, its number");
check(same(ZONE_TYPE_IDS, fields.typeId.values), "…and typeId's own list of values");
check(ARCHETYPES.every((a) => ZONE_TYPE_IDS[a.typeId] === a.type), "every network-manager archetype's typeId names its type");
check(typeIdText("2") === "2 · Service" && typeIdText(0) === "0 · Management" && typeIdText(7) === "7 · Overlay", "typeId shown with its type, from the string or the number");
check(typeIdText(9) === "9" && typeIdText(undefined) === null, "an unknown typeId is its number; none is none");

done("zonenet");
