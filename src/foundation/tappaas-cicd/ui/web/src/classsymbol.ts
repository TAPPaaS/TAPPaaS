// classsymbol.ts — a CMDB class as the console draws it: one symbol per class
// (no two alike), a family whose colour is the tile's, and the class's name in
// the operator's words. moduleicon.tsx draws it; nothing else picks a symbol.
// A TAPPaaS node (machine, compute) and its physical asset (server, assets)
// differ in both shape and colour. The asset glyphs are the Physical view's.

export type Family = "compute" | "assets" | "network" | "storage" | "software" | "identity" | "places" | "collections" | "other";

// Drawing palette tokens only (.interface-design/system.md, Drawing palette).
export const FAMILY_COLOR: Record<Family, string> = {
  compute: "var(--blue-700)",
  assets: "var(--orange-700)",
  network: "var(--teal-700)",
  storage: "var(--amber-700)",
  software: "var(--violet-600)",
  identity: "var(--pink-700)",
  places: "var(--lime-700)",
  collections: "var(--cyan-600)",
  other: "var(--slate-500)",
};

export interface ClassSymbol {
  symbol: string;
  family: Family;
  word: string;
}

const S = (symbol: string, family: Family, word: string): ClassSymbol => ({ symbol, family, word });

export const CLASS_SYMBOL: Record<string, ClassSymbol> = {
  // compute: what runs software
  machine: S("▣", "compute", "TAPPaaS node"),
  vm: S("◫", "compute", "virtual machine"),
  lxc: S("◧", "compute", "container"),
  device: S("▭", "compute", "managed device"),
  node: S("▢", "compute", "node"),
  // assets: physical things and what they are made of
  server: S("▤", "assets", "server"),
  "network-device": S("⇄", "assets", "switch or access point"),
  appliance: S("ϟ", "assets", "modem, ONT or UPS"),
  "passive-device": S("▦", "assets", "patch panel or PDU"),
  "other-device": S("▱", "assets", "other device"),
  port: S("•", "assets", "port"),
  disk: S("◍", "assets", "disk"),
  asset: S("▮", "assets", "asset"),
  resource: S("▪", "assets", "resource"),
  pool: S("◔", "assets", "consumable pool"),
  // network
  zone: S("⬡", "network", "zone"),
  ssid: S("≋", "network", "wireless network"),
  address: S("⌖", "network", "IP address"),
  "dns-name": S("@", "network", "DNS name"),
  "proxy-route": S("↪", "network", "proxy route"),
  "certificate-authority": S("✦", "network", "certificate authority"),
  "vpn-peer": S("⇌", "network", "VPN peer"),
  "network-element": S("⋈", "network", "network element"),
  // storage
  "storage-pool": S("◒", "storage", "storage pool"),
  share: S("⋔", "storage", "share"),
  datastore: S("↺", "storage", "backup datastore"),
  "backup-peer": S("⇆", "storage", "backup buddy"),
  "storage-element": S("⊟", "storage", "storage element"),
  // software
  app: S("◈", "software", "application"),
  service: S("⊙", "software", "service"),
  controller: S("⟳", "software", "controller"),
  manager: S("☰", "software", "manager"),
  software: S("◇", "software", "software"),
  // identity
  user: S("U", "identity", "user"),
  group: S("G", "identity", "group"),
  role: S("R", "identity", "role"),
  organization: S("O", "identity", "organization"),
  identity: S("I", "identity", "identity"),
  // places
  location: S("⌂", "places", "location"),
  room: S("□", "places", "room"),
  rack: S("▯", "places", "rack"),
  place: S("⊕", "places", "place"),
  // collections
  site: S("◆", "collections", "site"),
  cluster: S("⁂", "collections", "cluster"),
  environment: S("E", "collections", "environment"),
  collection: S("◌", "collections", "collection"),
  // the roots
  ci: S("●", "other", "configuration item"),
  object: S("○", "other", "CMDB object"),
};

// A class the table does not know yet: its first letter on the neutral tile.
export function classSymbol(cls: string): ClassSymbol {
  return CLASS_SYMBOL[cls] ?? S(cls.charAt(0).toUpperCase() || "?", "other", cls);
}

// An asset's kind (the asset record's) as its CMDB class.
const KIND_CLASS: Record<string, string> = { server: "server", switch: "network-device", "access-point": "network-device", modem: "appliance", ont: "appliance", ups: "appliance", "patch-panel": "passive-device", pdu: "passive-device", other: "other-device", disk: "disk" };
export const assetClassOf = (kind: string): string => KIND_CLASS[kind] ?? "asset";
