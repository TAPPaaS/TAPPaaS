// positions-cmdb.ts — the positions as the CMDB holds them (ADR-040 D3, D7, D9):
// the answer's shape, and the positions document drawn from it. asset-manager
// reports the document (manager/asset-manager/src/cmdb.ts); network-manager
// topology reads it back through positionsFromCmdb.

import { Asset, AssetKind, AssetPort, Cable, CableEnd, DiskRecord, Placement, PositionsDoc } from "./positions";

type Obj = Record<string, unknown>;

// An asset's kind → its D3 class, and the deviceType the class records.
export const CLASS_OF: Record<AssetKind, { class: string; deviceType?: string }> = {
  server: { class: "server" },
  switch: { class: "network-device", deviceType: "switch" },
  "access-point": { class: "network-device", deviceType: "access-point" },
  modem: { class: "appliance", deviceType: "modem" },
  ont: { class: "appliance", deviceType: "ont" },
  ups: { class: "appliance", deviceType: "ups" },
  "patch-panel": { class: "passive-device", deviceType: "patch-panel" },
  pdu: { class: "passive-device", deviceType: "pdu" },
  other: { class: "other-device" },
  // A disk is a resource beside the port, part of the asset it is in (ADR-042 D3).
  disk: { class: "disk" },
};
export const ASSET_CLASSES = ["server", "network-device", "appliance", "passive-device", "other-device"];

export interface CmdbAnswerObject {
  id: string;
  class: string;
  name: string;
  displayName: string | null;
  physical: true;
  recorded?: boolean; // the store's flag; false: another reporter's object
  attributes: Obj;
}
export interface CmdbAnswerEnd {
  id: string;
  class: string;
  name: string;
}
export interface CmdbAnswerRelation {
  type: string;
  from: CmdbAnswerEnd;
  to: CmdbAnswerEnd;
  attributes: Obj;
  recorded?: boolean; // the store's flag; false: another reporter's relation
}
export interface CmdbAnswer {
  objects: CmdbAnswerObject[];
  relations: CmdbAnswerRelation[];
}

const KIND_OF_CLASS = (cls: string, deviceType: unknown): AssetKind => {
  const hit = Object.entries(CLASS_OF).find(([, c]) => c.class === cls && (c.deviceType ?? null) === (typeof deviceType === "string" ? deviceType : null));
  return (hit?.[0] as AssetKind | undefined) ?? "other";
};

/** A positions document from the CMDB's answer: what network-manager
 *  topology would read once the CMDB is the record. Placements and cable ends
 *  are keyed by the role an asset plays, as positions.json keys them; an
 *  asset's ports are those it lists: not its plate's (`plate`), nor one only a
 *  cable names (no `kind`). */
export function positionsFromCmdb(ans: CmdbAnswer): PositionsDoc {
  const doc: PositionsDoc = { version: 1, rooms: {}, racks: {}, placements: {}, assets: {}, cables: [] };
  // What asset-manager recorded: the store holds the switches' own assets,
  // ports and cables beside them, and a Wi-Fi radio `connects` to its SSIDs.
  const objects = ans.objects.filter((o) => o.recorded !== false);
  const relations = ans.relations.filter((r) => r.recorded !== false);
  const byId = new Map(objects.map((o) => [o.id, o]));
  const rel = (type: string) => relations.filter((r) => r.type === type);
  const out = (type: string, id: string): CmdbAnswerRelation | undefined => rel(type).find((r) => r.from.id === id);
  const role = new Map(rel("allocated-to").map((r) => [r.from.id, r.to.name]));
  const portAsset = new Map(rel("part-of").map((r) => [r.from.id, r.to.id]));
  const nameOf = (assetId: string): string => role.get(assetId) ?? byId.get(assetId)?.name ?? assetId;
  // The store answers by class then name, so a server's ports ("port" < "server")
  // come before the server: the assets go first, whatever the order, then the
  // ports, in the natural order the record keeps them (1, 2, … 10; eno1, enp4s0).
  const ports: CmdbAnswerObject[] = [];
  const disks: CmdbAnswerObject[] = [];
  for (const o of objects) {
    const at = o.attributes;
    const text = (k: string): Obj => (typeof at[k] === "string" ? { [k]: at[k] } : {});
    const dn = o.displayName ? { displayName: o.displayName } : {};
    if (o.class === "room") {
      const loc = out("at", o.id)?.to.name;
      doc.rooms![o.name] = { ...dn, ...text("description"), ...(loc ? { location: loc } : {}) };
    } else if (o.class === "rack") {
      const room = out("placed-in", o.id)?.to.name;
      doc.racks![o.name] = {
        ...dn,
        units: Number(at.units),
        width: `${String(at.width)}in` as "19in" | "10in",
        numbering: at.numbering as "bottom-up" | "top-down",
        ...(room ? { room } : {}),
        ...text("description"),
      };
    } else if (ASSET_CLASSES.includes(o.class)) {
      // operational and placed are derived (D7): the record has placed.
      const stage = String(at.stage);
      const a: Asset = {
        kind: KIND_OF_CLASS(o.class, at.deviceType),
        ...dn,
        ...text("description"),
        ...text("vendor"),
        ...text("model"),
        ...text("serial"),
        ...text("assetTag"),
        stage: (stage === "operational" ? "placed" : stage) as Asset["stage"],
      };
      if (at.faulty === true) a.faulty = true;
      if (typeof at.faultNote === "string") a.faultNote = at.faultNote;
      if (at.procurement) a.procurement = at.procurement as Asset["procurement"];
      if (at.disposal) a.disposal = at.disposal as Asset["disposal"];
      if (role.has(o.id)) a.role = role.get(o.id);
      const location = out("at", o.id)?.to.name;
      if (location) a.location = location;
      doc.assets![o.name] = a;
    } else if (o.class === "port") ports.push(o);
    else if (o.class === "disk") disks.push(o);
  }
  // A disk: an asset of kind disk, placed in the asset it is part of.
  for (const o of disks) {
    const at = o.attributes;
    const text = (k: string): Obj => (typeof at[k] === "string" ? { [k]: at[k] } : {});
    const stage = String(at.stage ?? "placed");
    const a: Asset = {
      kind: "disk",
      ...(o.displayName ? { displayName: o.displayName } : {}),
      ...text("description"),
      ...text("vendor"),
      ...text("model"),
      ...text("serial"),
      ...text("assetTag"),
      stage: (stage === "operational" ? "placed" : stage) as Asset["stage"],
    };
    const dk: DiskRecord = {};
    if (typeof at.kind === "string") dk.kind = at.kind as DiskRecord["kind"];
    if (typeof at.size === "number") dk.size = at.size;
    for (const k of ["bus", "wwn", "firmware"] as const) if (typeof at[k] === "string") dk[k] = at[k] as string;
    if (Object.keys(dk).length) a.disk = dk;
    if (at.faulty === true) a.faulty = true;
    if (typeof at.faultNote === "string") a.faultNote = at.faultNote;
    if (at.procurement) a.procurement = at.procurement as Asset["procurement"];
    if (at.disposal) a.disposal = at.disposal as Asset["disposal"];
    doc.assets![o.name] = a;
    const host = byId.get(portAsset.get(o.id) ?? "");
    if (host) doc.placements![o.name] = { in: host.name, ...(typeof at.bay === "string" ? { bay: at.bay } : {}) };
  }
  for (const o of ports) {
    const at = o.attributes;
    const owner = byId.get(portAsset.get(o.id) ?? "");
    const a = owner ? doc.assets![owner.name] : undefined;
    if (!a || at.kind === undefined || at.plate === true) continue;
    const p = { name: o.name } as AssetPort & Obj;
    for (const k of ["kind", "speed", "standard", "bands", "module", "role", "mac", "side"]) if (at[k] !== undefined) p[k] = at[k];
    (a.ports ??= []).push(p);
  }
  for (const a of Object.values(doc.assets!)) a.ports?.sort((x, y) => x.name.localeCompare(y.name, "en", { numeric: true }));
  for (const r of rel("placed-in").filter((x) => ASSET_CLASSES.includes(x.from.class))) {
    const m: Placement = r.to.class === "rack" ? { rack: r.to.name } : { room: r.to.name };
    Object.assign(m, r.attributes);
    doc.placements![nameOf(r.from.id)] = m;
  }
  const isPanel = (id: string): boolean => byId.get(id)?.attributes.deviceType === "patch-panel";
  for (const r of rel("connects").filter((x) => x.to.class === "port")) {
    const e = (x: CmdbAnswerEnd): CableEnd => ({ device: nameOf(portAsset.get(x.id) ?? ""), port: x.name });
    const c: Cable = { from: e(r.from), to: e(r.to), kind: r.attributes.kind as Cable["kind"] };
    if (typeof r.attributes.label === "string") c.label = r.attributes.label;
    if (r.attributes.origin) c.origin = r.attributes.origin as Cable["origin"];
    if (r.attributes.linkSpeed) c.linkSpeed = String(r.attributes.linkSpeed);
    const side = r.attributes.side as CableEnd["side"] | undefined;
    if (r.attributes.toSide) {
      c.from.side = side;
      c.to.side = r.attributes.toSide as CableEnd["side"];
    } else if (side) {
      // The panel's end carries it.
      (isPanel(portAsset.get(r.to.id) ?? "") && !isPanel(portAsset.get(r.from.id) ?? "") ? c.to : c.from).side = side;
    }
    doc.cables!.push(c);
  }
  return doc;
}
