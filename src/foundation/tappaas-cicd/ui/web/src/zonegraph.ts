// zonegraph.ts — what the zones graph draws, as plain data (Zones.tsx gives
// each card its look): the trust column of every zone, the lines of
// access-to and pinhole-allowed-from (authored, and derived from the
// environments a zone serves), and the cards for targets that are not zones. The WAN zone's card stands for the internet as well: a line to or
// from `internet` ends on it.

export interface ZoneLike {
  name: string;
  type?: string;
  tier?: number | null;
  vlantag?: number;
  "access-to"?: string[];
  "pinhole-allowed-from"?: string[];
  // The environment(s) the zone names: a Service zone's own, or the ones a
  // client or IoT zone serves.
  environment?: string | string[];
}

// Every environment a zone names (one, or a list).
export const environmentsOf = (z: { environment?: unknown }): string[] =>
  (Array.isArray(z.environment) ? z.environment : [z.environment]).filter((e): e is string => typeof e === "string" && e.length > 0);

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
  // Set on an edge the zone's environment link derives: the environment it serves.
  via?: string;
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
  // One edge per environment a client or IoT zone serves, to that environment's
  // zone (the Service or Management zone naming it), as the render derives it.
  const ownZone = new Map<string, string>();
  for (const z of zones) {
    if ((z.type === "Service" || z.type === "Management") && typeof z.environment === "string") ownZone.set(z.environment, z.name);
  }
  for (const z of zones) {
    if (!["Client", "Guest", "IoT"].includes(z.type ?? "")) continue;
    for (const env of environmentsOf(z)) {
      const svc = ownZone.get(env);
      if (!svc) continue;
      add(z.type === "IoT" ? { source: svc, target: z.name, kind: "pinhole", via: env } : { source: z.name, target: svc, kind: "access", via: env });
    }
  }
  return { edges, pseudo: [...pseudo] };
}

// Where a card for a word that is not a zone goes. Every zone (`all`) is
// reached from the management tier: it sits in the tier-0 column, directly
// below the zone that reaches it (mgmt). The rest go in the internet column.
export function pseudoPlace(p: string, zones: ZoneLike[] = []): { col: number; order: number; after?: string } {
  if (p === "all") {
    const tier0 = zones.filter((z) => zoneColumn(z) === 1);
    const anchor = tier0.find((z) => (z["access-to"] ?? []).includes("all")) ?? tier0.find((z) => z.type === "Management");
    return anchor ? { col: 1, order: 0, after: anchor.name } : { col: 1, order: 0 };
  }
  return { col: INTERNET_COLUMN, order: p === "internet" ? 0 : 1 };
}

// The site's public address: site.json's network.publicIp when it names one;
// when it says "auto" (the provider's), the address the firewall's WAN held at
// the last network update, unless that is private (the WAN is behind another
// router, whose address the firewall cannot see). The WAN zone's own ip is a
// placeholder the schema asks for; nothing is built from it, so it is never
// shown as the WAN's address.
export interface PublicAddress {
  address: string | null;
  auto: boolean; // site.json says auto
  wan: string | null; // the WAN's own address, when it is private
  observed: string | null; // when the WAN's address was read
}
export interface HeldAddress {
  ipv4?: string | null;
  private?: boolean;
  observed?: string | null;
}
export function publicAddress(site: { network?: { publicIp?: string | null } } | null | undefined, held?: HeldAddress | null): PublicAddress {
  const ip = site?.network?.publicIp?.trim() ?? "";
  if (ip !== "" && ip !== "auto") return { address: ip, auto: false, wan: null, observed: null };
  const auto = ip === "auto";
  const v4 = auto ? held?.ipv4?.trim() || null : null;
  if (!v4) return { address: null, auto, wan: null, observed: null };
  const observed = held?.observed ?? null;
  return held?.private ? { address: null, auto, wan: v4, observed } : { address: v4, auto, wan: null, observed };
}

// The address in words: short on a card, in full on a detail card.
export function publicText(p: PublicAddress, short = false): string {
  const when = p.observed ? ` on ${p.observed.slice(0, 10)}` : "";
  if (p.address) return short ? `public ${p.address}` : p.auto ? `public address ${p.address} (auto: what the WAN held${when})` : `public address ${p.address}`;
  if (p.wan) return short ? `WAN ${p.wan} (private)` : `public address: the router's in front of the WAN (the WAN holds ${p.wan}${when})`;
  if (p.auto) return short ? "public address auto" : "public address: the provider's (auto), not read yet";
  return short ? "" : "public address not recorded";
}
