// archetypes.ts — the ADR-014 trust lattice, the zone archetype catalog, and
// the tier-exemption rule. This is the operative copy of what
// `schemas/zones-fields.json` documents (`tier_model`, `archetypes.catalog`,
// `tier_exempt_types`).
//
// WHY A COPY: the nix builder (lib/nix/ts-manager.nix) narrows the build source
// to lib/ts + this component, so `foundation/schemas/` is not reachable at build
// time, and resolving it at RUN time would make `validate` depend on a deployed
// file that may be missing or stale on exactly the systems it is meant to audit.
// The catalog is therefore embedded here and pinned to the schema by a unit test
// (network.test.ts §17) that reads the JSON from the source tree and asserts the
// two agree field for field. Drift fails the build rather than shipping.

// The `internet` boundary token's rank in the lattice. Tier 5 is reserved for
// it and is never authored on a real zone.
export const TIER_INTERNET = 5;

// Zone types that carry no `tier` and are SKIPPED by I1/I3/I4:
//   Overlay — non-VLAN WireGuard segments with no meaningful trust rank; `admin`
//             legitimately carries access-to: ["mgmt"], an upward edge into T0.
//   WAN     — the switch-internal ISP hand-off; no interface, DHCP or rules.
export const TIER_EXEMPT_TYPES: ReadonlySet<string> = new Set(["Overlay", "WAN"]);

// The control plane is the single exception to both I1 and I2: it reaches every
// zone (including isolated ones) for operational visibility. Encoded here rather
// than inline so the two checks cannot disagree about who is exempt.
export const CONTROL_PLANE_ZONE = "mgmt";

export interface Archetype {
  name: string;
  type: string;
  typeId: number;
  tier: number;
  isolated: boolean;
  // The `access-to` seed stamped by `add --archetype`. NOT checked by I4 —
  // conformance is on the (type, tier, isolated) triple, because a zone's
  // reachability is expected to grow beyond its seed while its classification
  // is not.
  accessTo: string[];
  reference: string; // the template zone that is this archetype's instance
  description: string;
}

export const ARCHETYPES: readonly Archetype[] = [
  { name: "control",        type: "Management", typeId: 0, tier: 0, isolated: false, accessTo: ["all"],             reference: "mgmt",       description: "Control plane: hypervisors, backup, firewall, identity, cicd" },
  { name: "service",        type: "Service",    typeId: 2, tier: 1, isolated: false, accessTo: ["internet", "dmz"], reference: "srv",        description: "Application/service modules for one environment" },
  { name: "trusted-client", type: "Client",     typeId: 3, tier: 2, isolated: false, accessTo: ["internet"],        reference: "home",       description: "Trusted end-user devices; reaches its service zone by pinhole" },
  { name: "guest",          type: "Guest",      typeId: 5, tier: 3, isolated: false, accessTo: ["internet"],        reference: "guest",      description: "Visitors: internet only, fully isolated" },
  { name: "iot-cloud",      type: "IoT",        typeId: 4, tier: 3, isolated: false, accessTo: ["internet"],        reference: "iotCloud",   description: "Internet-dependent trusted IoT: appliances, media, monitoring" },
  { name: "iot-untrust",    type: "IoT",        typeId: 4, tier: 3, isolated: true,  accessTo: ["internet"],        reference: "iotUntrust", description: "Untrusted IoT: internet-only, fully quarantined" },
  { name: "dmz",            type: "DMZ",        typeId: 6, tier: 4, isolated: false, accessTo: ["internet"],        reference: "dmz",        description: "Public-facing: reverse proxy, internet-exposed services" },
  { name: "iot-local",      type: "IoT",        typeId: 4, tier: 6, isolated: false, accessTo: [],                  reference: "iotLocal",   description: "Local-only IoT: no internet, automation devices" },
  { name: "iot-cams",       type: "IoT",        typeId: 4, tier: 6, isolated: true,  accessTo: [],                  reference: "iotCams",    description: "Surveillance: cameras + NVR, fully isolated" },
];

export function archetypeByName(name: string): Archetype | undefined {
  return ARCHETYPES.find((a) => a.name === name);
}

export function archetypeNames(): string[] {
  return ARCHETYPES.map((a) => a.name);
}

// I4's lookup: does this (type, tier, isolated) triple match a defined archetype?
export function archetypeForTriple(
  type: string | undefined,
  tier: number,
  isolated: boolean,
): Archetype | undefined {
  return ARCHETYPES.find((a) => a.type === type && a.tier === tier && a.isolated === isolated);
}

// Is this zone outside the tier model entirely (Overlay / WAN)?
export function isTierExempt(type: unknown): boolean {
  return typeof type === "string" && TIER_EXEMPT_TYPES.has(type);
}

// A zone's authored tier, or undefined when it carries none. Tolerates the
// string-typed numerics that zones.json uses elsewhere (typeId/subId are
// strings in the shipped template, so a hand-edited tier may be too).
export function zoneTier(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isInteger(v)) return v;
  if (typeof v === "string" && /^[0-9]+$/.test(v)) return parseInt(v, 10);
  return undefined;
}

// `isolated` defaults to false when absent.
export function zoneIsolated(v: unknown): boolean {
  return v === true;
}
