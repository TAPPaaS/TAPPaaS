// colors.ts — one colour per zone, everywhere a VLAN is drawn (the mockups'
// legend). The colours are tokens in styles.css (--zone-*); this only picks one.
// Zones the mockups did not name take a colour from the same palette by their
// VLAN, so a site's colours are stable between page loads.

const NAMED = new Set(["wan", "mgmt", "test", "home", "work", "iotLocal", "iotCloud", "iotCams", "iotUntrust", "guest", "dmz"]);
const palette = (n: number): string => `var(--zone-p${n % 8})`;

export function zoneColor(zone: { name: string; type?: string | null; vlan?: number | null }): string {
  if (NAMED.has(zone.name)) return `var(--zone-${zone.name})`;
  // The site's own service zone (rossen on hrossen) is the mockups' blue.
  if (zone.type === "Service") return zone.vlan === 200 || zone.vlan === undefined ? palette(0) : palette(zone.vlan ?? 0);
  return palette(zone.vlan ?? zone.name.length);
}
