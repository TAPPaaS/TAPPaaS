// zonenet.ts — a zone's numbers as the network module reads them: the /64 a
// zone's ipv6Subnet stands for within the site's IPv6 prefix (the arithmetic
// of opnsense-controller ipv6_plan.zone_network).

// What GET /api/v1/ipv6 answers (src/reads.ts Ipv6Read).
export interface Ipv6Read {
  on: boolean;
  mode: string;
  prefix: string | null;
  source: "delegated" | "site.json" | null;
  error?: string;
}

// Zones are numbered within the site prefix's first /56 (ipv6_plan ZONE_PREFIX_LENGTH).
export const ZONE_PREFIX_LENGTH = 56;

// An IPv6 address as a 128-bit number; null when it is not one.
export function parseV6(text: string): bigint | null {
  const s = text.trim().toLowerCase();
  if (!/^[0-9a-f:]+$/.test(s) || s.split("::").length > 2) return null;
  const [head, tail] = s.includes("::") ? s.split("::") : [s, null];
  const groups = (g: string): string[] => (g === "" ? [] : g.split(":"));
  const h = groups(head);
  const t = tail === null ? [] : groups(tail);
  const fill = tail === null ? 0 : 8 - h.length - t.length;
  if ((tail === null && h.length !== 8) || fill < 0 || (tail !== null && fill < 1)) return null;
  const all = [...h, ...Array<string>(fill).fill("0"), ...t];
  if (all.some((g) => g.length < 1 || g.length > 4)) return null;
  return all.reduce((n, g) => (n << 16n) | BigInt(parseInt(g, 16)), 0n);
}

// A 128-bit number as RFC 5952 text (the longest run of two or more zero
// groups as ::, the first of equal runs), as Python's ipaddress prints it.
export function formatV6(n: bigint): string {
  const g = Array.from({ length: 8 }, (_, i) => Number((n >> BigInt(112 - 16 * i)) & 0xffffn));
  let best = -1;
  let len = 0;
  for (let i = 0; i < 8; ) {
    if (g[i] !== 0) {
      i++;
      continue;
    }
    let j = i;
    while (j < 8 && g[j] === 0) j++;
    if (j - i > len && j - i > 1) [best, len] = [i, j - i];
    i = j;
  }
  const hex = g.map((x) => x.toString(16));
  if (best < 0) return hex.join(":");
  return `${hex.slice(0, best).join(":")}::${hex.slice(best + len).join(":")}`;
}

// The zone's /64: number `subnet` (0-255) within the first /56 of the site
// prefix. null when the prefix is not an IPv6 network, is smaller than /56
// (the plan gives no zone IPv6 then), or the index is out of range.
export function zoneNetwork(sitePrefix: string, subnet: number): string | null {
  const [addr, len] = sitePrefix.trim().split("/");
  const plen = len === undefined ? 128 : Number(len);
  const a = parseV6(addr ?? "");
  if (a === null || !Number.isInteger(plen) || plen < 0 || plen > ZONE_PREFIX_LENGTH) return null;
  if (!Number.isInteger(subnet) || subnet < 0 || subnet > 255) return null;
  // The network of the prefix (host bits cleared), then its first /56.
  const net = plen === 0 ? 0n : (a >> BigInt(128 - plen)) << BigInt(128 - plen);
  const drop = BigInt(128 - ZONE_PREFIX_LENGTH);
  const base = (net >> drop) << drop;
  return `${formatV6(base + (BigInt(subnet) << 64n))}/64`;
}

// A zone's /64 on this site, or null: IPv6 off, no ipv6Subnet, or no prefix learned.
export function zoneV6(z: { ipv6Subnet?: unknown }, v6: Ipv6Read | null | undefined): string | null {
  if (!v6?.on || !v6.prefix || typeof z.ipv6Subnet !== "number") return null;
  return zoneNetwork(v6.prefix, z.ipv6Subnet);
}

// A zone's typeId: the number of its type, the VLAN band (vlantag = typeId *
// 100 + subId), as zones-fields.json and network-manager's archetypes number
// them (zonenet.test.ts holds this table to both).
export const ZONE_TYPE_IDS: Record<number, string> = {
  0: "Management",
  1: "WAN",
  2: "Service",
  3: "Client",
  4: "IoT",
  5: "Guest",
  6: "DMZ",
  7: "Overlay",
};

// "2 · Service"; the bare number when it names no type, null when there is none.
export function typeIdText(v: unknown): string | null {
  if (v === undefined || v === null || v === "") return null;
  const n = Number(v);
  const t = Number.isInteger(n) ? ZONE_TYPE_IDS[n] : undefined;
  return t ? `${n} · ${t}` : String(v);
}

// The ipv6Subnet row of a zone's card: "32 → 2a13:e747:a210:4520::/64";
// "32 → -" when the site has no prefix to number it in (IPv6 off, none
// learned); "-" when the zone has no index.
export function ipv6SubnetText(z: { ipv6Subnet?: unknown }, v6: Ipv6Read | null | undefined): string {
  if (typeof z.ipv6Subnet !== "number") return "-";
  return `${z.ipv6Subnet} → ${zoneV6(z, v6) ?? "-"}`;
}
