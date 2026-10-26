// zonenet.test.ts — a zone's /64 (web/src/zonenet.ts) against the network
// module's own arithmetic: each expected value is what
// opnsense-controller ipv6_plan.zone_network(prefix, subnet) prints.

import { formatV6, parseV6, zoneNetwork, zoneV6 } from "../../web/src/zonenet";
import { check, done } from "./check";

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

done("zonenet");
