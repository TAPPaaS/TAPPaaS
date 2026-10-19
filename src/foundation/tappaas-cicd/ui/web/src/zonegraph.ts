// zonegraph.ts — what the zones graph draws, as plain data (Zones.tsx gives
// each card its look): the trust column of every zone, the lines of
// access-to and pinhole-allowed-from, and the cards for targets that are not
// zones. The WAN zone's card stands for the internet as well: a line to or
// from `internet` ends on it.

export interface ZoneLike {
  name: string;
  type?: string;
  tier?: number | null;
  vlantag?: number;
  "access-to"?: string[];
  "pinhole-allowed-from"?: string[];
}

// Words in access-to that are not zones.
export const PSEUDO: Record<string, string> = { internet: "the internet", all: "every zone" };

// The columns of the zones graph: trust runs left to right. Overlays (no
// tier) first, then tier 0 to 4, the internet (which counts as tier 5, with
// the WAN), and the tier-6 zones that reach nothing last.
export const COLUMN_TITLES: Record<number, string> = { 0: "overlays", 1: "tier 0 · management", 2: "tier 1 · services", 3: "tier 2 · trusted clients", 4: "tier 3", 5: "tier 4 · DMZ", 6: "internet · tier 5", 7: "tier 6 · no egress" };
export const INTERNET_COLUMN = 6;
// A zone with no tier recorded (an inactive one, or one authored the low-level
// way) takes its type's usual tier, as the archetypes give it.
const TYPE_TIER: Record<string, number> = { Management: 0, Service: 1, Client: 2, Guest: 3, IoT: 3, DMZ: 4 };
export function zoneColumn(z: Pick<ZoneLike, "type" | "tier">): number {
  if (z.type === "WAN") return INTERNET_COLUMN;
  if (z.type === "Overlay") return 0;
  const tier = typeof z.tier === "number" ? z.tier : TYPE_TIER[z.type ?? ""];
  if (tier === undefined) return 0;
  return tier >= 6 ? 7 : tier + 1;
}

// The zone that stands for the internet: the WAN zone (the one named `wan`
// when there are several), or none.
export function wanZone(zones: ZoneLike[]): string | null {
  const wans = zones.filter((z) => z.type === "WAN");
  return (wans.find((z) => z.name === "wan") ?? wans[0])?.name ?? null;
}

export interface ZoneEdge {
  source: string;
  target: string;
  kind: "access" | "pinhole";
}

// The lines and the cards for words that are not zones. `internet` becomes
// the WAN zone when there is one; a line drawn twice that way is drawn once.
export function zoneEdges(zones: ZoneLike[]): { edges: ZoneEdge[]; pseudo: string[] } {
  const names = new Set(zones.map((z) => z.name));
  const wan = wanZone(zones);
  const as = (t: string): string => (t === "internet" && wan ? wan : t);
  const edges: ZoneEdge[] = [];
  const seen = new Set<string>();
  const pseudo = new Set<string>();
  const add = (e: ZoneEdge): void => {
    const k = `${e.kind}|${e.source}|${e.target}`;
    if (e.source === e.target || seen.has(k)) return;
    seen.add(k);
    edges.push(e);
    for (const end of [e.source, e.target]) if (!names.has(end)) pseudo.add(end);
  };
  for (const z of zones) {
    for (const t of z["access-to"] ?? []) add({ source: z.name, target: as(t), kind: "access" });
    for (const f of z["pinhole-allowed-from"] ?? []) add({ source: as(f), target: z.name, kind: "pinhole" });
  }
  return { edges, pseudo: [...pseudo] };
}

// Where a card for a word that is not a zone goes: the internet column.
export function pseudoPlace(p: string): { col: number; order: number } {
  return { col: INTERNET_COLUMN, order: p === "internet" ? 0 : 1 };
}

// The site's public address as site.json records it (network.publicIp):
// the address itself, or "auto" (the provider's, found at run time and not
// recorded), or nothing. The WAN zone's own ip is a placeholder the schema
// asks for; nothing is built from it, so it is not shown as the WAN's address.
export interface PublicAddress {
  address: string | null;
  auto: boolean;
}
export function publicAddress(site: { network?: { publicIp?: string | null } } | null | undefined): PublicAddress {
  const ip = site?.network?.publicIp?.trim() ?? "";
  if (ip === "") return { address: null, auto: false };
  return ip === "auto" ? { address: null, auto: true } : { address: ip, auto: false };
}
