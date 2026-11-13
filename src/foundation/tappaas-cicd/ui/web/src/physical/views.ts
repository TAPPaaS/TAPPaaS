// views.ts — the Site page's four views of the site as built and their
// addresses: Overview, Physical (the racks), Devices (the assets that are
// physical devices, as cabled) and Storage. The addresses
// they had as sub-views of a Physical tab still open them. Plain data: the
// unit tests read it.

export const PHYSICAL_TABS = ["overview", "rack", "device", "storage"] as const;
export type PhysicalView = (typeof PHYSICAL_TABS)[number];

export const VIEW_NAME: Record<PhysicalView, string> = { overview: "Overview", rack: "Physical", device: "Devices", storage: "Storage" };

export const VIEW_PATH: Record<PhysicalView, string> = { overview: "/site/overview", rack: "/site/physical", device: "/site/devices", storage: "/site/storage" };

// The Site page's tabs: the views, then every asset (/site/assets, Assets.tsx).
export const SITE_PAGE_TABS: { name: string; to: string }[] = [...PHYSICAL_TABS.map((v) => ({ name: VIEW_NAME[v], to: VIEW_PATH[v] })), { name: "Assets", to: "/site/assets" }];

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
  "/site/physical/cabling": "/site/devices",
  "/site/physical/device": "/site/devices",
  "/site/device": "/site/devices",
  "/assets": "/site/assets",
  "/zones": "/environments/zones",
  "/site/physical/storage": "/site/storage",
};

// A link to a view, with the object to select there.
export const viewLink = (v: PhysicalView, select?: string | null): string => `${VIEW_PATH[v]}${select ? `?select=${encodeURIComponent(select)}` : ""}`;
