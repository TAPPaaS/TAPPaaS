// occupancy.ts — what the firewall already carries per L2 segment, and whether
// a zone about to be authored collides with it (#862).
//
// Every authoring path (add, zones init, zones merge) checked a VLAN tag
// against zones.json only. A segment built by hand in OPNsense (a NAS VLAN), or
// one a deleted zone left behind, was invisible: the template's `wan` (VLAN
// 100) landed beside a site's own VLAN 100, and zone-manager then adopted that
// interface by tag. The firewall's listing (`opnsense-firewall segments
// --json`, read by firewall-occupancy.ts) is turned into an Occupancy here;
// the three paths ask it for the tag and the subnet they are about to use.
//
// DETECT ONLY, NEVER REALLOCATE (operator, 2026-10-20): a hit is refused with
// the holder named, and the operator moves the site's own segment to a free
// tag. TAPPaaS's numbers — the template's and the band allocation — stay as
// they are, so every site keeps the same numbers for the same zones.
//
// Dependency-free TS: the reading (a spawn) lives in firewall-occupancy.ts.

export interface Holder {
  kind: "vlan" | "interface";
  name: string; // the interface's label, or the VLAN device's description
  identifier?: string; // interface only: lan, wan, optN
  device?: string;
  tag?: number;
  ipv4?: string; // interface only: the network it holds, e.g. 10.1.0.0/24
}

export interface Occupancy {
  // The segment that holds this VLAN tag, an assigned interface before a bare
  // VLAN device (the interface carries the label and the subnet).
  tag(tag: number): Holder | undefined;
  // The interface whose IPv4 network overlaps this one.
  subnet(cidr: string): Holder | undefined;
}

// What `opnsense-firewall segments --json` prints.
export interface Segments {
  vlans?: { tag?: unknown; device?: unknown; parent?: unknown; description?: unknown }[];
  interfaces?: {
    identifier?: unknown;
    description?: unknown;
    device?: unknown;
    tag?: unknown;
    ipv4?: unknown;
  }[];
}

export const NO_OCCUPANCY: Occupancy = { tag: () => undefined, subnet: () => undefined };

function str(v: unknown): string | undefined {
  return typeof v === "string" && v !== "" ? v : undefined;
}
function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isInteger(v) && v > 0 ? v : undefined;
}

export function occupancyFrom(seg: Segments): Occupancy {
  const holders: Holder[] = [];
  for (const i of seg.interfaces ?? []) {
    const identifier = str(i.identifier);
    if (!identifier) continue;
    holders.push({
      kind: "interface",
      name: str(i.description) ?? identifier,
      identifier,
      device: str(i.device),
      tag: num(i.tag),
      ipv4: str(i.ipv4),
    });
  }
  for (const v of seg.vlans ?? []) {
    const tag = num(v.tag);
    if (tag === undefined) continue;
    holders.push({ kind: "vlan", name: str(v.description) ?? str(v.device) ?? `VLAN ${tag}`, device: str(v.device), tag });
  }
  return {
    tag: (t) => holders.find((h) => h.kind === "interface" && h.tag === t) ?? holders.find((h) => h.tag === t),
    subnet: (c) => holders.find((h) => h.ipv4 !== undefined && ipv4Overlaps(h.ipv4, c)),
  };
}

// IPv4 only: a zone's `ip` is always 10.<typeId>.<sub>.0/24. Unparseable
// input never overlaps (so a bad listing cannot refuse everything).
function ipv4Net(cidr: string): { net: number; bits: number } | undefined {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/.exec(cidr.trim());
  if (!m) return undefined;
  const o = m.slice(1, 5).map(Number);
  const bits = Number(m[5]);
  if (o.some((x) => x > 255) || bits > 32) return undefined;
  const addr = ((o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]) >>> 0;
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return { net: (addr & mask) >>> 0, bits };
}

export function ipv4Overlaps(a: string, b: string): boolean {
  const x = ipv4Net(a);
  const y = ipv4Net(b);
  if (!x || !y) return false;
  const bits = Math.min(x.bits, y.bits);
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return ((x.net & mask) >>> 0) === ((y.net & mask) >>> 0);
}

export function describeHolder(h: Holder): string {
  if (h.kind === "interface") {
    const parts = [h.identifier, h.tag !== undefined ? `VLAN ${h.tag}` : "untagged", h.ipv4].filter(Boolean);
    return `interface '${h.name}' (${parts.join(", ")})`;
  }
  return `VLAN device '${h.name}'${h.device ? ` (${h.device})` : ""}, no interface assigned`;
}

export interface Collision {
  holder: Holder;
  reason: string;
}

// The first collision of a zone's tag or subnet with what the firewall carries.
export function collisionOf(zone: { vlantag?: unknown; ip?: unknown }, occ: Occupancy): Collision | undefined {
  const vt = zone.vlantag;
  if (typeof vt === "number" && vt > 0) {
    const h = occ.tag(vt);
    if (h) return { holder: h, reason: `VLAN ${vt} is already on the firewall: ${describeHolder(h)}` };
  }
  const ip = zone.ip;
  if (typeof ip === "string" && ip) {
    const h = occ.subnet(ip);
    if (h) return { holder: h, reason: `${ip} overlaps the firewall's ${describeHolder(h)}` };
  }
  return undefined;
}

export const MOVE_ADVICE = "move that segment to a free tag or subnet (TAPPaaS's own numbers stay)";
