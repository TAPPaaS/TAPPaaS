// zoneverbs.ts — the verbs a zone's card offers, as network-manager accepts
// them for the zone's state and type (zoneverbs.test.ts holds it to the
// manager's own rules).

export interface ZoneVerbZone {
  name: string;
  type?: string;
  state?: string;
}

export interface CardVerbs {
  states: string[]; // enable | disable | manual
  bind: boolean;
  addLike: boolean;
  delete: boolean;
  // A Manual zone is outside the enable/disable lifecycle: its own module
  // keeps it (an overlay, the WAN, mgmt); the card says so.
  manual: boolean;
}

// The zone types `network-manager bind` takes (network-manager types.ts ENVIRONMENT_TYPES).
export const BIND_TYPES: ReadonlySet<string> = new Set(["Service", "Management", "Client", "IoT", "Guest", "DMZ"]);

export function cardVerbs(z: ZoneVerbZone): CardVerbs {
  // The WAN and the overlays are always Manual, whatever the record says.
  const manual = z.state === "Manual" || z.type === "WAN" || z.type === "Overlay";
  const fixed = manual || z.state === "Mandatory";
  return {
    states: fixed ? [] : z.state === "Active" ? ["disable", "manual"] : ["enable"],
    bind: BIND_TYPES.has(z.type ?? ""),
    addLike: !manual,
    delete: !fixed,
    manual,
  };
}
