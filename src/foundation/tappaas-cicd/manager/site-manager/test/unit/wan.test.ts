// wan.test.ts — the WAN's IPv6 through `site modify` (network.wan.ipv6).
//
// A site whose ISP routes it a static prefix declares it here, and the network
// update configures the firewall from it. site.json may have no network.wan at
// all yet, so the fields are created; a static WAN must be complete, and a
// prefix smaller than a /56 cannot number the zones.

// Verbs run here report changes: never to a live CMDB (test.sh sets this too).
process.env.TAPPAAS_CMDB = "off";

import { mkdtempSync, writeFileSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { run } from "../../src/main";
import { FakeSiteClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const c = new FakeSiteClient();
const dir = mkdtempSync(join(tmpdir(), "wan-"));
const siteFile = join(dir, "site.json");
const fresh = (): void => writeFileSync(siteFile, JSON.stringify({ name: "s", ipv6: true, network: { isp: "x" } }));
const wan = (): Record<string, unknown> | undefined =>
  (JSON.parse(readFileSync(siteFile, "utf8")).network ?? {}).wan?.ipv6;
const modify = (...a: string[]): number => run(["site", "modify", ...a, "--config-dir", dir], c);

fresh();
check(modify("--set", "network.wan.ipv6.mode=static", "--set", "network.wan.ipv6.address=2a13:e740:292:978c::2/64",
  "--set", "network.wan.ipv6.gateway=2a13:e740:292:978c::1", "--set", "network.wan.ipv6.prefix=2a13:e747:a210::/48") === 0,
  "a static WAN is set where site.json has no network.wan yet");
check(JSON.stringify(wan()) === '{"mode":"static","address":"2a13:e740:292:978c::2/64","gateway":"2a13:e740:292:978c::1","prefix":"2a13:e747:a210::/48"}',
  "…with all four fields");
check(JSON.parse(readFileSync(siteFile, "utf8")).network.isp === "x", "…and the rest of network kept");

fresh();
check(modify("--wanIpv6Mode", "static", "--wanIpv6Address", "2a13:e740:292:978c::2/64") !== 0 && wan() === undefined,
  "a static WAN without gateway and prefix is refused, nothing written");
check(modify("--wanIpv6Prefix", "2a13:e747:a210::/60") !== 0 && wan() === undefined, "a prefix smaller than a /56 is refused");
check(modify("--wanIpv6Address", "10.0.0.2/24") !== 0, "an IPv4 address is refused as the IPv6 WAN address");
check(modify("--wanIpv6Gateway", "2a13:e740::1::1") !== 0, "an address with two :: is refused");
check(modify("--wanIpv6Mode", "auto") !== 0, "a mode other than dynamic, static or none is refused");
check(modify("--wanIpv6PrefixLength", "60") !== 0, "a dynamic prefix length outside 48-56 is refused");
check(modify("--wanIpv6Mode", "dynamic", "--wanIpv6PrefixLength", "48") === 0 && JSON.stringify(wan()) === '{"mode":"dynamic","prefixLength":48}',
  "a dynamic WAN takes its prefix length");

console.log(`wan: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
