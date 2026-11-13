// details.ts — where a side panel's Details link goes: the page where the
// selected object is shown in full and changed. An asset (a server, a switch,
// an access point, any recorded device, a rack's or a room's) its page under
// Assets; a node its module page when it has one, else its asset; a guest or
// the firewall its module page; a zone Environments' Zones tab; a user or a group
// the Identity page. Plain data: the unit tests read it.

import { Sel } from "./physical/layout";

export interface DetailTarget {
  label: string;
  to: string;
}

const enc = encodeURIComponent;

// An asset's page, by its own name or the role it plays; a port's row on it.
export const assetPath = (name: string, port?: string | null): string => `/site/assets/${enc(name)}${port ? `#${portAnchor(port)}` : ""}`;
export const portAnchor = (port: string): string => `port-${port.replace(/[^A-Za-z0-9_-]+/g, "_")}`;
// The Assets page with a location, a room, a rack or an unrecorded device selected.
export const assetsSelectPath = (kind: "location" | "room" | "rack" | "device", name: string): string => `/site/assets?select=${enc(`${kind}:${name}`)}`;
export const modulePath = (name: string): string => `/modules/${enc(name)}`;

const details = (to: string): DetailTarget => ({ label: "Details", to });

// A node: its page (a module of kind machine) when there is one, then its asset.
function nodeTargets(name: string, modules: ReadonlySet<string>): DetailTarget[] {
  return modules.has(name) ? [details(modulePath(name)), { label: "Asset", to: assetPath(name) }] : [details(assetPath(name))];
}

export interface SelContext {
  modules: ReadonlySet<string>; // the site's module names
  linkEnds?: string[]; // a link: the devices at its ends that are assets
  firewall?: string | null; // the firewall's module
  outsideKind?: "buddy" | "satellite" | null; // an outside peer's kind
  seen?: boolean; // a mount: a device a switch port sees that nobody recorded
  diskAsset?: string | null; // a disk: the asset that records it (by its serial)
}

/** The Details targets of a selection in the Physical, Assets or Storage
 *  view; the first is the Details link, any after it a second way. */
export function selDetails(sel: Sel, ctx: SelContext): DetailTarget[] {
  switch (sel.kind) {
    case "node":
      return nodeTargets(sel.id, ctx.modules);
    case "switch":
    case "ap":
      return [details(assetPath(sel.id))];
    case "mount":
      return [details(ctx.seen ? assetsSelectPath("device", sel.id) : assetPath(sel.id))];
    case "port":
    case "lag":
      return [details(assetPath(sel.switch, sel.kind === "port" ? sel.id : null))];
    case "panelport":
      return [details(assetPath(sel.panel, sel.id))];
    case "guest":
      return [details(modulePath(sel.id))];
    case "firewall":
      return [details(modulePath(ctx.firewall ?? sel.id))];
    case "rack":
    case "room":
      return [details(assetsSelectPath(sel.kind, sel.id))];
    case "disk":
      // The disk's own page when an asset records it, the node's as the second way.
      return ctx.diskAsset ? [details(assetPath(ctx.diskAsset)), { label: "Node", to: assetPath(sel.node) }] : [details(assetPath(sel.node))];
    case "pool":
      return nodeTargets(sel.node, ctx.modules);
    case "link":
      // Each end that is an asset: named when there are two.
      return (ctx.linkEnds ?? []).map((d, _i, all) => ({ label: all.length > 1 ? `Details · ${d}` : "Details", to: assetPath(d) }));
    case "outside":
      return ctx.outsideKind === "buddy" ? [details("/backup")] : [details("/site")];
    case "isp":
      return [details("/site")];
  }
}

// A CI as the Health and Threats panels show it.
export interface CiLike {
  class: string;
  ancestors: string[];
  name: string;
  module?: string | null;
  relations: { type: string; direction: "in" | "out"; other: { class: string; name: string } }[];
}

const IDENTITY: Record<string, string> = { user: "user", group: "group", role: "role", organization: "org" };

/** The Details targets of a CI in the Health and Threats views: the page
 *  that shows it in full; empty when the console has none for its class. */
export function ciDetails(o: CiLike): DetailTarget[] {
  const is = (c: string) => o.class === c || o.ancestors.includes(c);
  if (is("asset")) return [details(assetPath(o.name))];
  // A disk's CI is named by its asset's tag (dsk-NN): its own page.
  if (o.class === "disk") return [details(assetPath(o.name))];
  if (o.class === "port") {
    const owner = o.relations.find((r) => r.type === "part-of" && r.direction === "out");
    return owner ? [details(assetPath(owner.other.name, o.name))] : [];
  }
  if (o.class === "room" || o.class === "rack" || o.class === "location") return [details(assetsSelectPath(o.class, o.name))];
  if (o.class === "machine" || o.class === "device") {
    // A node the asset plays: its asset as the second way, or the only one.
    const asset = o.relations.find((r) => r.type === "allocated-to" && r.direction === "in")?.other.name ?? null;
    const assetTo = assetPath(asset ?? o.name);
    return o.module ? [details(modulePath(o.module)), { label: "Asset", to: assetTo }] : [details(assetTo)];
  }
  if (o.module) return [details(modulePath(o.module))];
  if (o.class === "zone") return [details(`/environments/zones?zone=${enc(o.name)}`)];
  if (o.class === "ssid") return [details("/setup/day2#wifi")];
  if (IDENTITY[o.class]) return [details(`/identity?select=${enc(`${IDENTITY[o.class]}:${o.name}`)}`)];
  if (o.class === "environment") return [details(`/environments?env=${enc(o.name)}`)];
  if (o.class === "site" || o.class === "cluster") return [details("/site")];
  if (o.class === "datastore" || o.class === "backup-peer") return [details("/backup")];
  return [];
}
