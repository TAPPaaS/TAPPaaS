// colors.ts — one colour per zone, everywhere a VLAN is drawn (the mockups'
// legend). Zones the mockups did not name take a colour from the same palette
// by their VLAN, so a site's colours are stable between page loads.

const NAMED: Record<string, string> = {
  wan: "#8e8e8e",
  mgmt: "#475569",
  test: "#9c6ade",
  home: "#2f9e44",
  work: "#15803d",
  iotLocal: "#e8a317",
  iotCloud: "#f08c3a",
  iotCams: "#c2410c",
  iotUntrust: "#a16207",
  guest: "#0ea5a4",
  dmz: "#d64545",
};
const PALETTE = ["#3b6fd4", "#7c3aed", "#0891b2", "#be185d", "#4d7c0f", "#b45309", "#1d4ed8", "#9333ea"];

export function zoneColor(zone: { name: string; type?: string | null; vlan?: number | null }): string {
  if (NAMED[zone.name]) return NAMED[zone.name];
  // The site's own service zone (rossen on hrossen) is the mockups' blue.
  if (zone.type === "Service") return zone.vlan === 200 || zone.vlan === undefined ? "#3b6fd4" : PALETTE[(zone.vlan ?? 0) % PALETTE.length];
  return PALETTE[(zone.vlan ?? zone.name.length) % PALETTE.length];
}
