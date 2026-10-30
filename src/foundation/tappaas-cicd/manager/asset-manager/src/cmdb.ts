// cmdb.ts — what asset-manager records, as the CMDB holds it (ADR-040 D3, D7,
// D9, step 3): config/positions.json stays the record for now, and everything
// in it is reported to cmdb-controller — the rooms and racks (place CIs), each
// asset as its D3 subclass with its ports, each placement as placed-in, each
// recorded cable as connects, each role as allocated-to. Pure functions over
// the document; delivering them (lib/ts cmdb.ts, which spools) is main.ts's.
//
// One view of the document serves three things: `report` sends all of it (an
// observation), a changing verb sends the difference between the view before
// and after it (a change), and `export --cmdb` prints it the way the CMDB
// would answer a query for it, with positionsFromCmdb turning that back into a
// document — the reference for the step that draws the topology from the CMDB.
//
// What the controller cannot take yet, worked around here:
// - a reference it cannot resolve refuses the whole batch, so the allocations
//   (to a node CI another manager reports) go in reports of their own, and a
//   refusal of one is a node not reported yet, not an error;
// - there is no field that marks an object as recorded: every object and
//   relation carries `recorded: true` beside its class (ignored by the
//   controller today), and the source is asset-manager;
// - a room is `at` a location site-manager reports: the location is named in
//   the batch by name only (no attributes), so the reference resolves whether
//   or not site-manager has reported it yet.

import type { CmdbObject, CmdbRef, CmdbRelation, CmdbReport } from "../../../lib/ts/src/cmdb";
import {
  Asset,
  AssetKind,
  AssetPort,
  Cable,
  CableEnd,
  Faceplate,
  Placement,
  PositionsDoc,
  assetNamed,
  assetPorts,
  assetsOf,
  cablesOf,
  currentName,
  faceOf,
  heightOf,
  placementsOf,
  racksOf,
  roomsOf,
  stageOf,
  widthOf,
} from "../../../lib/ts/src/positions";

export const SOURCE = "asset-manager";

type Obj = Record<string, unknown>;
export type Recorded<T> = T & { recorded: true };
export type ViewObject = Recorded<CmdbObject & { ref: string; attributes: Obj }>;
export type ViewRelation = Recorded<CmdbRelation & { attributes: Obj }>;

// The CMDB's view of positions.json: the objects in the order they must be
// reported (what a reference names comes first), the relations between them,
// the allocations (sent apart), and what could not be expressed.
export interface View {
  objects: ViewObject[];
  relations: ViewRelation[];
  allocations: ViewRelation[];
  skipped: string[];
}

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
};
export const ASSET_CLASSES = ["server", "network-device", "appliance", "passive-device", "other-device"];

export const refOf = {
  location: (n: string) => `location:${n}`,
  room: (n: string) => `room:${n}`,
  rack: (n: string) => `rack:${n}`,
  asset: (n: string) => `asset:${n}`,
  port: (asset: string, port: string) => `port:${asset}:${port}`,
};

// Optional values as the report spells them: absent is null, so a value the
// record no longer has is unset in the CMDB too.
const orNull = (v: unknown): unknown => (v === undefined || v === "" ? null : v);

// The plate an asset's ports come from: its model where that is a catalog
// key, else the faceplate it is placed with, else one a cable end draws it by.
function plateOf(doc: PositionsDoc, key: string, a: Asset, catalog: Faceplate[]): string | undefined {
  const known = (k: string | undefined): string | undefined => (k && catalog.some((f) => f.key === k) ? k : undefined);
  const at = currentName(key, a);
  return (
    known(a.model) ??
    known(placementsOf(doc)[at]?.faceplate) ??
    known(cablesOf(doc).flatMap((c) => [c.from, c.to]).find((e) => e.device === at && e.faceplate)?.faceplate)
  );
}

export function portsOfAsset(doc: PositionsDoc, key: string, a: Asset, catalog: Faceplate[]): AssetPort[] {
  return assetPorts({ model: plateOf(doc, key, a, catalog), ports: a.ports }, catalog);
}

function placementAttributes(m: Placement): Obj {
  const out: Obj = m.rack ? { u: m.u ?? null, height: heightOf(m), width: widthOf(m), slot: m.slot ?? 0, face: faceOf(m) } : {};
  for (const k of ["faceplate", "label", "description"] as const) if (m[k]) out[k] = m[k];
  return out;
}

function cableAttributes(c: Cable): Obj {
  const out: Obj = { kind: c.kind };
  if (c.label) out.label = c.label;
  if (c.origin) out.origin = c.origin;
  // The side of the patch panel's end; both ends on a panel: the from end's,
  // and the to end's apart.
  if (c.from.side || c.to.side) out.side = c.from.side ?? c.to.side;
  if (c.from.side && c.to.side) out.toSide = c.to.side;
  if (c.linkSpeed) out.linkSpeed = c.linkSpeed;
  return out;
}

/** The CMDB's view of a positions document. primary: site.json's primary
 *  location, where a room that names none is. */
export function cmdbView(doc: PositionsDoc, catalog: Faceplate[], primary: string | null): View {
  const objects: ViewObject[] = [];
  const relations: ViewRelation[] = [];
  const allocations: ViewRelation[] = [];
  const skipped: string[] = [];
  const has = new Set<string>();
  const add = (o: Omit<ViewObject, "recorded">): void => {
    objects.push({ ...o, recorded: true });
    has.add(o.ref);
  };

  // Places: the locations the rooms are at (by name), the rooms, the racks.
  const rooms = roomsOf(doc);
  for (const name of Object.keys(rooms).sort()) {
    const r = rooms[name];
    const loc = r.location ?? primary;
    if (!loc) {
      skipped.push(`room ${name}: it names no location and site.json has no primary one`);
      continue;
    }
    if (!has.has(refOf.location(loc))) add({ ref: refOf.location(loc), class: "location", name: loc, attributes: {} });
    add({
      ref: refOf.room(name),
      class: "room",
      name,
      attributes: { location: { ref: refOf.location(loc) }, displayName: orNull(r.displayName), description: orNull(r.description) },
    });
  }
  const racks = racksOf(doc);
  for (const name of Object.keys(racks).sort()) {
    const r = racks[name];
    if (!r.room || !has.has(refOf.room(r.room))) {
      skipped.push(`rack ${name}: ${r.room ? `its room ${r.room} is not recorded (room add ${r.room})` : "it stands in no room (rack modify --set room=…)"}`);
      continue;
    }
    add({
      ref: refOf.rack(name),
      class: "rack",
      name,
      attributes: {
        room: { ref: refOf.room(r.room) },
        units: r.units,
        width: Number.parseInt(r.width, 10),
        numbering: r.numbering,
        displayName: orNull(r.displayName),
        description: orNull(r.description),
      },
    });
  }

  // Assets, each with its ports; where it stands; what it plays.
  const assets = assetsOf(doc);
  const placements = placementsOf(doc);
  const portRefs = new Map<string, Map<string, string>>(); // asset key → port name → ref
  for (const key of Object.keys(assets).sort()) {
    const a = assets[key];
    const cls = CLASS_OF[a.kind] ?? CLASS_OF.other;
    const attributes: Obj = {};
    if (cls.deviceType) attributes.deviceType = cls.deviceType;
    // vendor and serial are the asset's key and immutable: never unset.
    if (a.vendor) attributes.vendor = a.vendor;
    if (a.serial) attributes.serial = a.serial;
    Object.assign(attributes, {
      model: orNull(a.model),
      assetTag: orNull(a.assetTag),
      displayName: orNull(a.displayName),
      description: orNull(a.description),
      stage: stageOf(doc, key, a),
      faulty: a.faulty === true,
      faultNote: orNull(a.faultNote),
      procurement: a.procurement && Object.keys(a.procurement).length ? a.procurement : null,
      disposal: orNull(a.disposal),
    });
    const m = placements[currentName(key, a)];
    const where = m ? (m.rack ? refOf.rack(m.rack) : m.room ? refOf.room(m.room) : null) : null;
    if (m && (!where || !has.has(where))) skipped.push(`placement of ${key}: ${m.rack ? `rack ${m.rack}` : `room ${m.room ?? "?"}`} is not reported`);
    // Placed: the placed-in relation below carries it; else none.
    if (!where || !has.has(where)) attributes.location = null;
    if (!a.role) attributes.allocatedTo = null;
    const ref = refOf.asset(key);
    add({ ref, class: cls.class, name: key, attributes });
    if (where && has.has(where)) relations.push({ type: "placed-in", from: { ref }, to: { ref: where }, attributes: placementAttributes(m!), recorded: true });
    // A recorded device plays itself: no CI stands for it.
    if (a.role && a.role !== key) allocations.push({ type: "allocated-to", from: { ref }, to: { class: "node", name: a.role }, attributes: {}, recorded: true });
    const refs = new Map<string, string>();
    for (const p of portsOfAsset(doc, key, a, catalog)) {
      const pref = refOf.port(key, p.name);
      refs.set(p.name, pref);
      add({
        ref: pref,
        class: "port",
        name: p.name,
        attributes: {
          asset: { ref },
          kind: p.kind,
          speed: orNull(p.speed),
          standard: orNull(p.standard),
          bands: p.bands?.length ? p.bands : null,
          module: orNull(p.module),
          role: orNull(p.role),
          mac: orNull(p.mac),
          side: orNull(p.side),
        },
      });
    }
    portRefs.set(key, refs);
  }
  for (const name of Object.keys(placements).sort()) {
    if (!assetNamed(doc, name)) skipped.push(`placement of ${name}: no asset is recorded for it`);
  }

  // Recorded cables: port to port, both ends an asset's port.
  const endRef = (e: CableEnd): string | null => {
    const a = assetNamed(doc, e.device);
    return a ? portRefs.get(a.key)?.get(e.port) ?? null : null;
  };
  for (const c of cablesOf(doc)) {
    const from = endRef(c.from);
    const to = endRef(c.to);
    if (!from || !to) {
      const bad = [!from ? c.from : null, !to ? c.to : null].filter((e): e is CableEnd => !!e).map((e) => `${e.device}:${e.port}`);
      skipped.push(`cable ${c.from.device}:${c.from.port} — ${c.to.device}:${c.to.port}: ${bad.join(", ")} is no recorded asset's port`);
      continue;
    }
    relations.push({ type: "connects", from: { ref: from }, to: { ref: to }, attributes: cableAttributes(c), recorded: true });
  }
  return { objects, relations, allocations, skipped };
}

// ── reports ─────────────────────────────────────────────────────────────

export interface Ctx {
  verb?: string;
  job?: string;
  actor?: string;
  time?: string;
}

// A reference as it stands outside the report that defines it: by class and
// name (an asset's, a room's and a location's name is unique in its class).
function standalone(v: View, r: CmdbRef): CmdbRef {
  if (typeof r !== "object" || !r.ref) return r;
  const o = v.objects.find((x) => x.ref === r.ref);
  return o ? { class: o.class, name: o.name } : r;
}

// The allocations as reports of their own: one each, so a node the CMDB does
// not have yet refuses only its own.
function allocationReports(v: View, rels: ViewRelation[], kind: "observation" | "change", ctx: Ctx): CmdbReport[] {
  return rels.map((r) => ({
    source: SOURCE,
    kind,
    ...(ctx.verb ? { verb: ctx.verb } : {}),
    ...(ctx.job ? { job: ctx.job } : {}),
    ...(ctx.actor ? { actor: ctx.actor } : {}),
    ...(ctx.time ? { time: ctx.time } : {}),
    relations: [{ ...r, from: standalone(v, r.from), to: standalone(v, r.to) }],
  }));
}

/** Everything recorded: one batch, and the allocations apart. */
export function fullReport(v: View, ctx: Ctx = {}): { report: CmdbReport; allocations: CmdbReport[] } {
  return {
    report: { source: SOURCE, kind: "observation", ...(ctx.time ? { time: ctx.time } : {}), objects: v.objects, relations: v.relations },
    allocations: allocationReports(v, v.allocations, "observation", ctx),
  };
}

const relKey = (r: CmdbRelation): string => `${r.type}|${JSON.stringify(r.from)}|${JSON.stringify(r.to)}`;
const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);

/** What a verb changed: the objects and relations that differ between the
 *  view before it and after it, with what they name; what it removed, ended;
 *  the new allocations apart. null report: nothing the CMDB holds changed (a
 *  faceplate verb). */
export function changeReport(before: View, after: View, ctx: Ctx): { report: CmdbReport | null; allocations: CmdbReport[] } {
  const was = new Map(before.objects.map((o) => [o.ref, o]));
  const now = new Map(after.objects.map((o) => [o.ref, o]));
  const need = new Set<string>(after.objects.filter((o) => !same(was.get(o.ref), o)).map((o) => o.ref));
  const wasRel = new Map(before.relations.map((r) => [relKey(r), r]));
  const nowRel = new Map(after.relations.map((r) => [relKey(r), r]));
  const put = after.relations.filter((r) => !same(wasRel.get(relKey(r))?.attributes, r.attributes) || !wasRel.has(relKey(r)));
  const refOfEnd = (e: CmdbRef): string | null => (typeof e === "object" && e.ref ? e.ref : null);
  // A relation that ended between objects still recorded; one that ended with
  // its object ends with it.
  const gone = before.relations.filter((r) => !nowRel.has(relKey(r)) && [r.from, r.to].every((e) => { const x = refOfEnd(e); return !x || now.has(x); }));
  for (const r of [...put, ...gone]) for (const e of [r.from, r.to]) { const x = refOfEnd(e); if (x) need.add(x); }
  // With what each one names (a port its asset, a rack its room …).
  const close = (ref: string): void => {
    const o = now.get(ref);
    if (!o) return;
    for (const v of Object.values(o.attributes)) {
      const x = v && typeof v === "object" && !Array.isArray(v) ? (v as { ref?: unknown }).ref : undefined;
      if (typeof x === "string" && !need.has(x)) {
        need.add(x);
        close(x);
      }
    }
  };
  for (const ref of [...need]) close(ref);

  const objects: CmdbObject[] = after.objects.filter((o) => need.has(o.ref));
  // Removed from the record: ended, what is part of another before it, each
  // naming what it is in by class and name.
  for (const o of [...before.objects].reverse()) {
    if (now.has(o.ref) || o.class === "location") continue;
    const attributes: Obj = {};
    for (const [k, v] of Object.entries(o.attributes)) attributes[k] = v && typeof v === "object" && "ref" in (v as Obj) ? standalone(before, v as CmdbRef) : v;
    objects.push({ ...o, attributes, end: true });
  }
  const relations: CmdbRelation[] = [...gone.map((r) => ({ ...r, end: true })), ...put];

  const wasAlloc = new Set(before.allocations.map(relKey));
  const allocations = allocationReports(after, after.allocations.filter((r) => !wasAlloc.has(relKey(r))), "change", ctx);
  if (!objects.length && !relations.length) return { report: null, allocations };
  return {
    report: {
      source: SOURCE,
      kind: "change",
      ...(ctx.verb ? { verb: ctx.verb } : {}),
      ...(ctx.job ? { job: ctx.job } : {}),
      ...(ctx.actor ? { actor: ctx.actor } : {}),
      ...(ctx.time ? { time: ctx.time } : {}),
      objects,
      relations,
    },
    allocations,
  };
}

// ── read-back: the CMDB's answer, and a document from it ─────────────────

// An object as cmdb-controller's query answers it (POST /v1/query): an id,
// and its attributes without the relation fields, which are relation rows
// (`cmdb show` lists them). Here the id is the view's ref.
export interface CmdbAnswerObject {
  id: string;
  class: string;
  name: string;
  displayName: string | null;
  physical: true;
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
}
export interface CmdbAnswer {
  objects: CmdbAnswerObject[];
  relations: CmdbAnswerRelation[];
}

const RELATION_FIELDS: Record<string, string> = { location: "at", room: "placed-in", asset: "part-of" };

/** The view as the CMDB would answer `query --physical` and the current
 *  relations of what it returns: what network-manager topology needs for the
 *  positions (the faceplate catalog stays asset-manager's, the locations are
 *  site-manager's). An allocation's node is named by class and name: it is
 *  another manager's object. */
export function cmdbAnswer(v: View): CmdbAnswer {
  const byRef = new Map(v.objects.map((o) => [o.ref, o]));
  const end = (r: CmdbRef): CmdbAnswerEnd => {
    const o = typeof r === "object" && r.ref ? byRef.get(r.ref) : undefined;
    if (o) return { id: o.ref, class: o.class, name: o.name };
    const c = typeof r === "object" ? r.class ?? "object" : "object";
    const n = typeof r === "object" ? r.name ?? "" : r;
    return { id: `${c}:${n}`, class: c, name: n };
  };
  const objects: CmdbAnswerObject[] = [];
  const relations: CmdbAnswerRelation[] = [];
  for (const o of v.objects) {
    const attributes: Obj = {};
    for (const [k, val] of Object.entries(o.attributes)) {
      if (val === null) continue; // unset: the CMDB has no row
      const isRef = val && typeof val === "object" && !Array.isArray(val) && "ref" in (val as Obj);
      if (isRef && RELATION_FIELDS[k]) relations.push({ type: RELATION_FIELDS[k], from: end({ ref: o.ref }), to: end(val as CmdbRef), attributes: {} });
      else if (k !== "displayName") attributes[k] = val;
    }
    if (o.class === "location") continue; // site-manager's object; its rooms' relations are above
    objects.push({ id: o.ref, class: o.class, name: o.name, displayName: typeof o.attributes.displayName === "string" ? o.attributes.displayName : null, physical: true, attributes });
  }
  for (const r of [...v.relations, ...v.allocations]) relations.push({ type: r.type, from: end(r.from), to: end(r.to), attributes: r.attributes });
  return { objects, relations };
}

const KIND_OF_CLASS = (cls: string, deviceType: unknown): AssetKind => {
  const hit = Object.entries(CLASS_OF).find(([, c]) => c.class === cls && (c.deviceType ?? null) === (typeof deviceType === "string" ? deviceType : null));
  return (hit?.[0] as AssetKind | undefined) ?? "other";
};

/** A positions document from the CMDB's answer: what network-manager
 *  topology would read once the CMDB is the record. Placements and cable ends
 *  are keyed by the role an asset plays, as positions.json keys them; an
 *  asset's ports are its own, its plate's included. */
export function positionsFromCmdb(ans: CmdbAnswer): PositionsDoc {
  const doc: PositionsDoc = { version: 1, rooms: {}, racks: {}, placements: {}, assets: {}, cables: [] };
  const byId = new Map(ans.objects.map((o) => [o.id, o]));
  const rel = (type: string) => ans.relations.filter((r) => r.type === type);
  const out = (type: string, id: string): CmdbAnswerRelation | undefined => rel(type).find((r) => r.from.id === id);
  const role = new Map(rel("allocated-to").map((r) => [r.from.id, r.to.name]));
  const portAsset = new Map(rel("part-of").map((r) => [r.from.id, r.to.id]));
  const nameOf = (assetId: string): string => role.get(assetId) ?? byId.get(assetId)?.name ?? assetId;
  for (const o of ans.objects) {
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
      doc.assets![o.name] = a;
    } else if (o.class === "port") {
      const owner = byId.get(portAsset.get(o.id) ?? "");
      const a = owner ? doc.assets![owner.name] : undefined;
      if (!a) continue;
      const p = { name: o.name } as AssetPort & Obj;
      for (const k of ["kind", "speed", "standard", "bands", "module", "role", "mac", "side"]) if (at[k] !== undefined) p[k] = at[k];
      (a.ports ??= []).push(p);
    }
  }
  for (const r of rel("placed-in").filter((x) => ASSET_CLASSES.includes(x.from.class))) {
    const m: Placement = r.to.class === "rack" ? { rack: r.to.name } : { room: r.to.name };
    Object.assign(m, r.attributes);
    doc.placements![nameOf(r.from.id)] = m;
  }
  const isPanel = (id: string): boolean => byId.get(id)?.attributes.deviceType === "patch-panel";
  for (const r of rel("connects")) {
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
