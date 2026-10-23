// locations.tsx — where a device is (ADR-036 D2): the site's locations by
// name, a link to one (the Site page's Locations card), and the form that
// moves a switch or an access point to another.

import { ReactNode } from "react";
import { useRead } from "./api";
import { OperateButton, Step } from "./operate";
import { SiteRead } from "./types";
import { Link } from "./ui";

export interface SiteLocation {
  name: string;
  displayName: string | null;
  place: string;
  primary: boolean;
}

// The site's locations from site.json, the primary first.
export function siteLocations(site: SiteRead["site"] | undefined): SiteLocation[] {
  const all = (site?.locations ?? {}) as Record<string, { displayName?: string; address?: string; city?: string; country?: string }>;
  const primary = typeof site?.primaryLocation === "string" ? site.primaryLocation : null;
  return Object.entries(all)
    .map(([name, l]) => ({ name, displayName: l.displayName ?? null, place: [l.address, l.city, l.country].filter(Boolean).join(", "), primary: name === primary }))
    .sort((a, b) => Number(b.primary) - Number(a.primary) || a.name.localeCompare(b.name));
}

export function useSiteLocations(): SiteLocation[] {
  return siteLocations(useRead<SiteRead>("site").env?.data?.site);
}

// The Site page's row for a location: /site#location-<name>.
export const locationAnchor = (name: string): string => `location-${name}`;

export const locationHref = (name: string): string => `/site#${locationAnchor(name)}`;

export function LocationLink({ name, children }: { name: string; children?: ReactNode }) {
  return <Link to={locationHref(name)}>{children ?? name}</Link>;
}

// A location by name, linked, with its place: "Hareskov · Hareskov, DK".
export function LocationLine({ name, locations }: { name: string | null; locations: SiteLocation[] }) {
  const primary = locations.find((l) => l.primary);
  const at = name ?? primary?.name ?? null;
  if (!at) return <span className="muted">—</span>;
  const l = locations.find((x) => x.name === at);
  if (!l) return <span className="ff-error">{at} — not one of the site's locations</span>;
  return (
    <>
      <LocationLink name={l.name}>{l.displayName ?? l.name}</LocationLink>
      {l.place ? <span className="muted"> · {l.place}</span> : null}
      {l.primary ? <span className="muted"> · primary{name === null ? " (it names none)" : ""}</span> : null}
    </>
  );
}

// switch-manager modify-switch / ap-manager modify --location: the location
// it is at, one of the site's.
export function locationSteps(kind: "switch" | "ap", name: string, current: string | null, locations: SiteLocation[]): Step[] {
  const names = locations.map((l) => l.name);
  return [
    kind === "switch"
      ? {
          title: `switch-manager modify-switch '${name}' --location <location>`,
          bin: "switch-manager",
          verb: "modify-switch",
          fixed: [name],
          initial: { "--location": current ?? "" },
          choices: { "--location": names },
          note: "Writes where the switch is (switch-configuration-actual.json and -desired.json); nothing on the switch changes. A location is one of the site's (the Site page's Locations); free text goes in --description.",
        }
      : {
          title: `ap-manager modify '${name}' --location <location>`,
          bin: "ap-manager",
          verb: "modify",
          fixed: [name],
          initial: { "--location": current ?? "" },
          choices: { "--location": names },
          note: "Writes where the access point is (switch-configuration-desired.json); nothing on it changes. A location is one of the site's (the Site page's Locations); free text goes in --description.",
        },
  ];
}

export function DeviceLocationButton({ kind, name, current }: { kind: "switch" | "ap"; name: string; current: string | null }) {
  const locations = useSiteLocations();
  return <OperateButton label="Location…" title={`Where ${name} is`} disabled={locations.length === 0} hint={locations.length === 0 ? "the site has no locations yet" : undefined} steps={() => locationSteps(kind, name, current, locations)} />;
}
