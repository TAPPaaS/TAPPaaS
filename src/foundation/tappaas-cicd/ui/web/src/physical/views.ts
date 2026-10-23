// views.ts — the Site page's four views of the site as built and their
// addresses: Overview, Physical (the racks), Device and Storage. The addresses
// they had as sub-views of a Physical tab still open them. Plain data: the
// unit tests read it.

export const PHYSICAL_TABS = ["overview", "rack", "device", "storage"] as const;
export type PhysicalView = (typeof PHYSICAL_TABS)[number];

export const VIEW_NAME: Record<PhysicalView, string> = { overview: "Overview", rack: "Physical", device: "Device", storage: "Storage" };

export const VIEW_PATH: Record<PhysicalView, string> = { overview: "/site/overview", rack: "/site/physical", device: "/site/device", storage: "/site/storage" };

// The view an address shows (/site is the Overview), or null.
export function viewOfPath(path: string): PhysicalView | null {
  if (path === "/site") return "overview";
  return PHYSICAL_TABS.find((v) => VIEW_PATH[v] === path) ?? null;
}

// Earlier addresses and where they are now.
export const MOVED_PATHS: Record<string, string> = {
  "/physical": "/site/physical",
  "/site/physical/overview": "/site/overview",
  "/site/physical/rack": "/site/physical",
  "/site/physical/cabling": "/site/device",
  "/site/physical/device": "/site/device",
  "/site/physical/storage": "/site/storage",
};

// A link to a view, with the object to select there.
export const viewLink = (v: PhysicalView, select?: string | null): string => `${VIEW_PATH[v]}${select ? `?select=${encodeURIComponent(select)}` : ""}`;

// Where the site is, as the heading over its rooms: the address and the city
// of its primary location (a room names its own location; the Overview sums
// the site up under the primary one); a
// site.json migration 0019 has not reached has them under location.
type Place = { address?: unknown; building?: unknown; city?: unknown; country?: unknown };
export function sitePlace(site: { locations?: Record<string, Place>; primaryLocation?: unknown; location?: Place } | null | undefined): string | null {
  const primary = typeof site?.primaryLocation === "string" ? site?.locations?.[site.primaryLocation] : undefined;
  const l = primary ?? site?.location;
  const parts = [l?.address ?? l?.building, l?.city, l?.country].filter((x): x is string => typeof x === "string" && x.trim() !== "");
  return parts.length ? parts.join(" · ") : null;
}
