// wan-address.ts — the addresses the firewall's WAN held when the network
// module's update last read them (`opnsense-firewall wan --json`, written to
// /var/lib/tappaas/wan-address.json). What the site's public address is when
// site.json network.publicIp says "auto": the provider's, taken by DHCP.
// Run-time state, not config: the topology and the console show it beside
// "auto"; nothing configures anything from it.

import { readJsonObject } from "./config-io";

// Where it is kept: $TAPPAAS_WAN_ADDRESS_FILE (a test or a preview) or the default.
export function wanAddressFile(): string {
  return process.env.TAPPAAS_WAN_ADDRESS_FILE ?? "/var/lib/tappaas/wan-address.json";
}

export interface WanAddress {
  ipv4: string | null;
  prefix: number | null;
  ipv6: string[];
  private: boolean; // behind another router: the public address is that router's
  observed: string | null; // when the update read it (ISO time)
}

// The recorded addresses, or null when there is no record (the update has not
// run since, or the WAN held none). A malformed record throws.
export function readWanAddress(file: string = wanAddressFile()): WanAddress | null {
  const v = readJsonObject(file);
  if (!v) return null;
  const str = (x: unknown): string | null => (typeof x === "string" && x.trim() !== "" ? x.trim() : null);
  const ipv6 = Array.isArray(v.ipv6) ? v.ipv6.filter((a): a is string => typeof a === "string") : [];
  const ipv4 = str(v.ipv4);
  if (!ipv4 && ipv6.length === 0) return null;
  return { ipv4, prefix: typeof v.prefix === "number" ? v.prefix : null, ipv6, private: v.private === true, observed: str(v.observed) };
}
