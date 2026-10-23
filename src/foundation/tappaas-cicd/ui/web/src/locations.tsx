// locations.tsx — where a device is (ADR-036 D2): the site's locations by
// name, a link to one (the Site page's Locations card), a device's placement
// as a link to its room or rack in the Physical view, and the form that moves
// a switch or an access point to another. Every form that takes a location
// offers the site's as a dropdown, the primary preselected, with a link to the
// Site page's Locations section for one the site does not have yet.

import { ReactNode } from "react";
import { useRead } from "./api";
import { OperateButton, Step } from "./operate";
import { viewLink } from "./physical/views";
import { PositionsView, SiteRead } from "./types";
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

// The Site page's Locations section, where a location is added.
export const LOCATIONS_HREF = "/site#locations";

export function AddLocationHint() {
  return (
    <span className="muted">
      Not listed? <Link to={LOCATIONS_HREF}>Add the location</Link> in the Site page's Locations, then come back.
    </span>
  );
}

// The parts of a Step whose --location takes one of the site's locations:
// the dropdown, the value it starts at (the current one, else the primary,
// unless `preselect` is false), and the link to add one.
export function locationOption(locations: SiteLocation[], current?: string | null, preselect = true): Pick<Step, "choices" | "initial" | "asides"> {
  const start = current ?? (preselect ? locations.find((l) => l.primary)?.name : undefined);
  return {
    choices: locations.length ? { "--location": locations.map((l) => l.name) } : {},
    initial: start ? { "--location": start } : {},
    asides: { "--location": <AddLocationHint /> },
  };
}

// A device's placement (position-manager's): a rack and its units, or loose
// in a room, each a link to it in the Physical view; else placed nowhere —
// somewhere at its location when that has no room.
export function PlacementLine({ v, device, location }: { v: PositionsView | null | undefined; device: string; location: string | null }) {
  if (!v) return <span className="muted">—</span>;
  const room = (name: string) => <Link to={viewLink("rack", `room:${name}`)}>{v.rooms?.find((r) => r.name === name)?.displayName ?? name}</Link>;
  for (const r of v.racks) {
    const m = r.placements.find((x) => x.device === device);
    if (!m) continue;
    return (
      <>
        <Link to={viewLink("rack", `rack:${r.name}`)}>{r.displayName ?? r.name}</Link> U{m.u}{m.height > 1 ? `-U${m.u + m.height - 1}` : ""} · {m.face}
        {m.width === "full" ? "" : ` · ${m.width} width, slot ${m.slot}`}
        {r.room ? <> · in {room(r.room)}</> : null} · {m.faceplate ?? "no plate"}
        {m.suggested ? " (suggested)" : ""}
      </>
    );
  }
  for (const r of v.rooms ?? []) {
    const m = r.loose.find((x) => x.device === device);
    if (m) return <>loose in {room(r.name)} · {m.faceplate ?? "no plate"}</>;
  }
  const loc = v.locations?.find((l) => l.name === location);
  return loc && !loc.rooms.length ? <span className="muted">somewhere at this location (it has no room)</span> : <span className="muted">placed nowhere</span>;
}

// switch-manager modify-switch / ap-manager modify --location: the location
// it is at, one of the site's.
export function locationSteps(kind: "switch" | "ap", name: string, current: string | null, locations: SiteLocation[]): Step[] {
  const at = locationOption(locations, current);
  return [
    kind === "switch"
      ? {
          title: `switch-manager modify-switch '${name}' --location <location>`,
          bin: "switch-manager",
          verb: "modify-switch",
          fixed: [name],
          ...at,
          note: "Writes where the switch is (switch-configuration-actual.json and -desired.json); nothing on the switch changes. A location is one of the site's (the Site page's Locations); free text goes in --description.",
        }
      : {
          title: `ap-manager modify '${name}' --location <location>`,
          bin: "ap-manager",
          verb: "modify",
          fixed: [name],
          ...at,
          note: "Writes where the access point is (switch-configuration-desired.json); nothing on it changes. A location is one of the site's (the Site page's Locations); free text goes in --description.",
        },
  ];
}

export function DeviceLocationButton({ kind, name, current }: { kind: "switch" | "ap"; name: string; current: string | null }) {
  const locations = useSiteLocations();
  return <OperateButton label="Location…" title={`Where ${name} is`} disabled={locations.length === 0} hint={locations.length === 0 ? "the site has no locations yet" : undefined} steps={() => locationSteps(kind, name, current, locations)} />;
}
